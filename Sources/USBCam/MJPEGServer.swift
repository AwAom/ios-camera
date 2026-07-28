import Foundation
import Network
import AVFoundation
import UIKit
import CoreImage

/// Minimal MJPEG-over-HTTP server (multipart/x-mixed-replace) so a desktop
/// application such as OBS can add "USB Camera" as a Video Capture Device
/// via a Browser Source / Media Source pointed at http://<device-ip>:8080/stream
/// while the iPhone is tethered over USB (with USB-to-Ethernet / personal
/// hotspot style local networking) or over the same Wi-Fi network.
///
/// This is intentionally lightweight: no external dependencies, built on
/// Network.framework, and only keeps the single most recent JPEG frame in
/// memory to minimize battery/CPU overhead.
final class MJPEGServer: FrameConsuming {

    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "com.example.usbcam.mjpegServer")
    private let ciContext = CIContext()

    private var latestJPEG: Data?
    private let boundary = "usbcamboundary"

    /// Downscale + throttle to keep CPU/battery usage low while streaming.
    private var lastFrameSentAt: TimeInterval = 0
    private let minFrameInterval: TimeInterval = 1.0 / 15.0 // cap MJPEG preview at 15fps

    init(port: UInt16 = 8080) {
        self.port = NWEndpoint.Port(rawValue: port) ?? 8080
    }

    func start() {
        do {
            let params = NWParameters.tcp
            let listener = try NWListener(using: params, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            print("MJPEGServer failed to start: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.connections.removeValue(forKey: id) }
            if case .failed = state { self?.connections.removeValue(forKey: id) }
        }
        connection.start(queue: queue)
        sendHeaders(on: connection)
        readAndDiscardRequest(on: connection)
    }

    private func readAndDiscardRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, isComplete, error in
            if isComplete || error != nil { return }
        }
    }

    private func sendHeaders(on connection: NWConnection) {
        let headers = "HTTP/1.1 200 OK\r\n" +
            "Content-Type: multipart/x-mixed-replace; boundary=\(boundary)\r\n" +
            "Cache-Control: no-cache\r\n" +
            "Connection: close\r\n\r\n"
        connection.send(content: headers.data(using: .utf8), completion: .contentProcessed { _ in })
    }

    private func broadcast(jpeg: Data) {
        var payload = Data()
        payload.append("--\(boundary)\r\n".data(using: .utf8)!)
        payload.append("Content-Type: image/jpeg\r\n".data(using: .utf8)!)
        payload.append("Content-Length: \(jpeg.count)\r\n\r\n".data(using: .utf8)!)
        payload.append(jpeg)
        payload.append("\r\n".data(using: .utf8)!)

        for connection in connections.values {
            connection.send(content: payload, completion: .contentProcessed { _ in })
        }
    }

    // MARK: - FrameConsuming

    func cameraManager(_ manager: CameraManager, didOutput sampleBuffer: CMSampleBuffer) {
        guard !connections.isEmpty else { return }

        let now = CACurrentMediaTime()
        guard now - lastFrameSentAt >= minFrameInterval else { return }
        lastFrameSentAt = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        let uiImage = UIImage(cgImage: cgImage)
        guard let jpeg = uiImage.jpegData(compressionQuality: 0.6) else { return }

        queue.async { [weak self] in
            self?.broadcast(jpeg: jpeg)
        }
    }
}
