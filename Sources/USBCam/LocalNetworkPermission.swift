import Foundation
import Network

/// `NWListener`-based local servers (like our MJPEGServer) never
/// automatically trigger iOS's "Local Network" privacy prompt -- that
/// prompt only fires for APIs that actively browse/advertise on the LAN.
/// Without it, incoming connections are silently dropped and the app never
/// even appears under Settings -> Privacy & Security -> Local Network.
///
/// The fix is a well-known workaround: briefly run a Bonjour browse (using
/// the legacy NetServiceBrowser API, which reliably surfaces the system
/// prompt) for the service type declared in Info.plist's NSBonjourServices.
final class LocalNetworkPermission: NSObject {
    static let shared = LocalNetworkPermission()

    private var browser: NWBrowser?
    private var netServiceBrowser: NetServiceBrowser?

    /// Call once, early (e.g. app launch), before relying on any inbound
    /// local-network connections such as the MJPEG server.
    func requestIfNeeded() {
        guard browser == nil else { return }

        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let browser = NWBrowser(for: .bonjour(type: "_usbcam._tcp", domain: nil), using: parameters)
        self.browser = browser
        browser.start(queue: .main)

        let netServiceBrowser = NetServiceBrowser()
        netServiceBrowser.delegate = self
        self.netServiceBrowser = netServiceBrowser
        netServiceBrowser.searchForServices(ofType: "_usbcam._tcp.", inDomain: "")

        // The prompt (if needed) appears almost immediately; tear the
        // probes down shortly after so they don't keep running forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.stop()
        }
    }

    private func stop() {
        browser?.cancel()
        browser = nil
        netServiceBrowser?.stop()
        netServiceBrowser = nil
    }
}

extension LocalNetworkPermission: NetServiceBrowserDelegate {
    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        stop()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        stop()
    }
}
