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
        case unsupportedByDevice
    }

    /// User-selectable capture targets. `.auto` uses the original
    /// best-effort fallback chain (4K60 -> 4K30 -> 1080p60 -> 1080p30);
    /// the rest lock to one specific resolution/frame-rate so you can e.g.
    /// deliberately drop to 1080p30 if 4K60 is too heavy for your use case
    /// (MJPEG preview streaming in particular is CPU-bound per frame and
    /// can lag well before the native capture pipeline itself struggles).
    enum QualityPreset: CaseIterable, Identifiable {
        case auto
        case uhd60
        case uhd30
        case fullHD60
        case fullHD30
        case hd30

        var id: Self { self }

        var target: (width: Int32, height: Int32, fps: Double)? {
            switch self {
            case .auto: return nil
            case .uhd60: return (3840, 2160, 60)
            case .uhd30: return (3840, 2160, 30)
            case .fullHD60: return (1920, 1080, 60)
            case .fullHD30: return (1920, 1080, 30)
            case .hd30: return (1280, 720, 30)
            }
        }

        var label: String {
            switch self {
            case .auto: return "Auto (best available)"
            case .uhd60: return "4K @ 60fps"
            case .uhd30: return "4K @ 30fps"
            case .fullHD60: return "1080p @ 60fps"
            case .fullHD30: return "1080p @ 30fps"
            case .hd30: return "720p @ 30fps"
            }
        }
    }

    @Published var isSessionRunning = false
    @Published var activeFormatDescription: String = "Not configured"
    @Published var lastError: String?
    @Published var selectedQualityPreset: QualityPreset = .auto

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
    /// Re-applies whatever quality preset is currently selected.
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

                try self.lockFormat(on: device, preset: self.selectedQualityPreset)

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

    /// User-driven resolution/frame-rate change on the currently active
    /// camera. Falls back to leaving the previous format in place (with an
    /// error message) if the device doesn't support the requested preset.
    func setQualityPreset(_ preset: QualityPreset) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            self.session.beginConfiguration()
            defer { self.session.commitConfiguration() }

            do {
                try self.lockFormat(on: device, preset: preset)
                DispatchQueue.main.async { self.selectedQualityPreset = preset }
            } catch {
                self.publishError("\(preset.label) isn't supported on \(device.localizedName) -- keeping the previous setting.")
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

        try lockFormat(on: device, preset: selectedQualityPreset)
        DispatchQueue.main.async { self.currentCameraID = device.uniqueID }
    }

    /// Applies a specific quality preset, or (for `.auto`) the best-effort
    /// fallback chain: 4K60 -> 4K30 -> 1080p60 -> 1080p30 -> device default.
    private func lockFormat(on device: AVCaptureDevice, preset: QualityPreset) throws {
        if let target = preset.target {
            guard let match = bestFormat(for: device, width: target.width, height: target.height, fps: target.fps) else {
                throw CaptureError.unsupportedByDevice
            }
            try apply(format: match.format, fps: target.fps, to: device)
            DispatchQueue.main.async {
                self.activeFormatDescription = "\(target.width)x\(target.height) @ \(Int(target.fps))fps"
            }
            return
        }

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
