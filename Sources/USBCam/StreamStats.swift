import Foundation

/// Live MJPEG stream throughput, sampled once per second by MJPEGServer
/// and observed by the HUD.
final class StreamStats: ObservableObject {
    @Published var fps: Double = 0
    @Published var kbps: Double = 0
    @Published var connectedClients: Int = 0

    func reset() {
        fps = 0
        kbps = 0
        connectedClients = 0
    }
}
