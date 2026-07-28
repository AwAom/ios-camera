import AVFoundation
import Combine
import UIKit

/// Owns the AVCaptureSession and configures the rear wide-angle camera for
/// the highest-performance format available: 4K30/60 first, degrading
/// gracefully to 1080p60 and finally to whatever the device supports.
final class CameraManager: NSObject, ObservableObject {

    enum CaptureError: Error {
        case noCameraAvailable
        case cannotAddInput
        case cannotAddOutput
        case lockFailed(Error)
    }

    @Published var isSessionRunning = false
    @Published var activeFormatDescription: String = "Not configured"
    @Published var lastError: String?

    /// All physical/virtual cameras this device exposes (ultra-wide, wide,
    /// telephoto, front, and any multi-camera combos), populated on launch.
    @Published var availableCameras: [AVCaptureDevice] = []
    @Published var currentCameraID: String?

    let session = AVCaptureSession()

    /// Enable/disable microphone capture alongside video.
    var audioEnabled: Bool = true

    private let sessionQueue = DispatchQueue(label: "com.example.usbcam.sessionQueue")
    private var videoDevice: AVCaptureDevice?
    private var videoDeviceInput: AVCaptureDeviceInput?

    /// Raw frame output, consumed by the optional MJPEG server.
    let videoDataOutput = AVCaptureVideoDataOutput()
    private let videoDataOutputQueue = DispatchQueue(label: "com.example.usbcam.videoDataOutputQueue")

    weak var frameConsumer: FrameConsuming?

    // MARK: - Public API

    func requestPermissionsAndConfigure() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] videoGranted in
            guard let self else { return }
            guard videoGranted else {
                self.publishError("Camera access denied.")
                return
            }
            if self.audioEnabled {
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    self.sessionQueue.async { self.configureSession() }
                }
            } else {
                self.sessionQueue.async { self.configureSession() }
            }
        }
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.session.isRunning {
                self.session.startRunning()
                DispatchQueue.main.async { self.isSessionRunning = self.session.isRunning }
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
                DispatchQueue.main.async { self.isSessionRunning = self.session.isRunning }
            }
        }
    }

    /// Switches the live capture input to a different physical/virtual
    /// camera (e.g. ultra-wide -> telephoto -> front) without tearing down
    /// the rest of the session (audio input, outputs, MJPEG consumers).
    func selectCamera(_ device: AVCaptureDevice) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            defer { self.session.commitConfiguration() }

            if let currentInput = self.videoDeviceInput {
                self.session.removeInput(currentInput)
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else {
                    self.publishError("Cannot switch to \(device.localizedName).")
                    return
                }
                self.session.addInput(input)
                self.videoDeviceInput = input
                self.videoDevice = device

                try self.lockBestAvailableFormat(on: device)

                if let connection = self.videoDataOutput.connection(with: .video), connection.isVideoOrientationSupported {
                    connection.videoOrientation = .landscapeRight
                    connection.isVideoMirrored = (device.position == .front)
                }

                DispatchQueue.main.async { self.currentCameraID = device.uniqueID }
            } catch {
                self.publishError("Failed to switch camera: \(error)")
            }
        }
    }

    // MARK: - Session configuration

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .inputPriority

        do {
            discoverCameras()
            try configureVideoInput()
            try configureAudioInputIfNeeded()
            try configureVideoOutput()
        } catch {
            publishError("\(error)")
            session.commitConfiguration()
            return
        }

        session.commitConfiguration()
        start()
    }

    /// Cameras discovered on the session queue; `availableCameras` mirrors
    /// this on the main queue for SwiftUI binding.
    private var discoveredCameras: [AVCaptureDevice] = []

    /// Enumerates every camera this device exposes: front/back wide-angle,
    /// ultra-wide, telephoto, and virtual dual/triple cameras where present.
    private func discoverCameras() {
        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera,
            .builtInDualCamera,
            .builtInDualWideCamera,
            .builtInTripleCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        discoveredCameras = discovery.devices
        let cameras = discoveredCameras
        DispatchQueue.main.async { self.availableCameras = cameras }
    }

    private func configureVideoInput() throws {
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? discoveredCameras.first(where: { $0.position == .back })
            ?? AVCaptureDevice.default(for: .video)
        guard let device else {
            throw CaptureError.noCameraAvailable
        }
        self.videoDevice = device

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.cannotAddInput }
        session.addInput(input)
        self.videoDeviceInput = input

        try lockBestAvailableFormat(on: device)
        DispatchQueue.main.async { self.currentCameraID = device.uniqueID }
    }

    /// Locks hardware format to 4K (3840x2160) @ 60fps when available.
    /// Falls back to 4K @ 30fps, then 1080p @ 60fps, then the device's
    /// highest available frame rate for its default format.
    private func lockBestAvailableFormat(on device: AVCaptureDevice) throws {
        let targets: [(width: Int32, height: Int32, fps: Double)] = [
            (3840, 2160, 60),
            (3840, 2160, 30),
            (1920, 1080, 60),
            (1920, 1080, 30)
        ]

        for target in targets {
            if let match = bestFormat(for: device, width: target.width, height: target.height, fps: target.fps) {
                try apply(format: match.format, fps: target.fps, to: device)
                DispatchQueue.main.async {
                    self.activeFormatDescription = "\(target.width)x\(target.height) @ \(Int(target.fps))fps"
                }
                return
            }
        }

        // Last resort: leave the device on its default active format but
        // still report what we ended up with.
        DispatchQueue.main.async {
            let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            self.activeFormatDescription = "\(dims.width)x\(dims.height) (fallback default format)"
        }
    }

    private func bestFormat(for device: AVCaptureDevice, width: Int32, height: Int32, fps: Double) -> (format: AVCaptureDevice.Format, range: AVFrameRateRange)? {
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width == width, dims.height == height else { continue }

            for range in format.videoSupportedFrameRateRanges {
                if range.maxFrameRate >= fps && range.minFrameRate <= fps {
                    return (format, range)
                }
            }
        }
        return nil
    }

    private func apply(format: AVCaptureDevice.Format, fps: Double, to device: AVCaptureDevice) throws {
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let duration = CMTimeMake(value: 1, timescale: Int32(fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {
            throw CaptureError.lockFailed(error)
        }
    }

    private func configureAudioInputIfNeeded() throws {
        guard audioEnabled else { return }
        guard let mic = AVCaptureDevice.default(for: .audio) else { return }
        let input = try AVCaptureDeviceInput(device: mic)
        if session.canAddInput(input) {
            session.addInput(input)
        }
    }

    private func configureVideoOutput() throws {
        videoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(self, queue: videoDataOutputQueue)

        guard session.canAddOutput(videoDataOutput) else { throw CaptureError.cannotAddOutput }
        session.addOutput(videoDataOutput)

        if let connection = videoDataOutput.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = .landscapeRight
        }
    }

    private func publishError(_ message: String) {
        DispatchQueue.main.async { self.lastError = message }
    }
}

// MARK: - Frame delegate

protocol FrameConsuming: AnyObject {
    func cameraManager(_ manager: CameraManager, didOutput sampleBuffer: CMSampleBuffer)
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameConsumer?.cameraManager(self, didOutput: sampleBuffer)
    }
}
