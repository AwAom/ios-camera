import SwiftUI
import AVFoundation

/// UIKit bridge exposing an AVCaptureVideoPreviewLayer inside SwiftUI.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    /// When false, detaches the layer's session entirely rather than just
    /// hiding it visually -- so disabling the preview actually stops the
    /// layer doing rendering work instead of just making it invisible.
    var isEnabled: Bool = true
    /// True when the active camera is front-facing (needs a mirrored preview).
    var isMirrored: Bool = false

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = isEnabled ? session : nil
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        applyConnectionSettings(to: view)
        // This view never needs its own touch handling; leaving interaction
        // enabled lets it swallow taps meant for the SwiftUI double-tap
        // gesture on the containing ZStack (most noticeable when the view
        // is invisible under the stealth-mode black overlay, which then
        // silently blocks toggling stealth mode back off).
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.videoPreviewLayer.session = isEnabled ? session : nil
        applyConnectionSettings(to: uiView)
    }

    /// The app is landscape-only (see Info.plist), but nothing was ever
    /// pinning the *preview layer's own* connection orientation -- only
    /// videoDataOutput's separate connection got `.landscapeRight` in
    /// CameraManager. Left on defaults, the preview layer could end up
    /// rotated relative to its actual frame, which reads as the feed not
    /// filling the screen (letterboxed/cropped instead of edge-to-edge).
    /// Pin it explicitly every update instead of relying on automatic
    /// orientation inference.
    private func applyConnectionSettings(to view: PreviewUIView) {
        guard let connection = view.videoPreviewLayer.connection else { return }
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = .landscapeRight
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = isMirrored
        }
    }

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
