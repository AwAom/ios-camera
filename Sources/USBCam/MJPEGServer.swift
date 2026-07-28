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

    private let stats: StreamStats
    private var statsWindowStart: TimeInterval = CACurrentMediaTime()
    private var framesInWindow: Int = 0
    private var bytesInWindow: Int = 0

    /// Downscale + throttle to keep CPU/battery usage low while streaming.
    private var lastFrameSentAt: TimeInterval = 0
    private let minFrameInterval: TimeInterval = 1.0 / 15.0 // cap MJPEG preview at 15fps

    /// Encoding a full 4K frame to JPEG on every tick is the actual
    /// bottleneck behind MJPEG "lag" -- it's expensive regardless of what
    /// resolution the native capture pipeline is running at. Downscale
    /// before encoding so the preview stream stays smooth even when the
    /// main capture is locked to 4K60; this has no effect on the native
    /// AVFoundation capture quality itself, only this convenience stream.
    private let maxStreamWidth: CGFloat = 1280

    init(port: UInt16 = 8080, stats: StreamStats) {
        self.port = NWEndpoint.Port(rawValue: port) ?? 8080
        self.stats = stats
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
        DispatchQueue.main.async { self.stats.reset() }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        publishConnectionCount()
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state {
                self?.connections.removeValue(forKey: id)
                self?.publishConnectionCount()
            }
            if case .failed = state {
                self?.connections.removeValue(forKey: id)
                self?.publishConnectionCount()
            }
        }
        connection.start(queue: queue)
        sendHeaders(on: connection)
        readAndDiscardRequest(on: connection)
    }

    private func publishConnectionCount() {
        let count = connections.count
        DispatchQueue.main.async { self.stats.connectedClients = count }
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

        recordStatsSample(byteCount: payload.count)
    }

    /// Called on `queue` for every frame actually broadcast; flushes a
    /// fps/kbps sample to the (main-queue) StreamStats once per second.
    private func recordStatsSample(byteCount: Int) {
        framesInWindow += 1
        bytesInWindow += byteCount

        let now = CACurrentMediaTime()
        let elapsed = now - statsWindowStart
        guard elapsed >= 1.0 else { return }

        let fps = Double(framesInWindow) / elapsed
        let kbps = (Double(bytesInWindow) * 8.0 / 1000.0) / elapsed
        framesInWindow = 0
        bytesInWindow = 0
        statsWindowStart = now

        DispatchQueue.main.async {
            self.stats.fps = fps
            self.stats.kbps = kbps
        }
    }

    // MARK: - FrameConsuming

    func cameraManager(_ manager: CameraManager, didOutput sampleBuffer: CMSampleBuffer) {
        guard !connections.isEmpty else { return }

        let now = CACurrentMediaTime()
        guard now - lastFrameSentAt >= minFrameInterval else { return }
        lastFrameSentAt = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        let scale = min(1.0, maxStreamWidth / ciImage.extent.width)
        if scale < 1.0 {
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        let uiImage = UIImage(cgImage: cgImage)
        guard let jpeg = uiImage.jpegData(compressionQuality: 0.6) else { return }

        queue.async { [weak self] in
            self?.broadcast(jpeg: jpeg)
        }
    }
}
