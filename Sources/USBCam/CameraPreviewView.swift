import SwiftUI
import AVFoundation

/// UIKit bridge exposing an AVCaptureVideoPreviewLayer inside SwiftUI.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    /// When false, detaches the layer's session entirely rather than just
    /// hiding it visually -- so disabling the preview actually stops the
    /// layer doing rendering work instead of just making it invisible.
    var isEnabled: Bool = true

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = isEnabled ? session : nil
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
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
    }

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
