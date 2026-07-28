import SwiftUI

@main
struct USBCamApp: App {

    init() {
        // Disabled here at process start too; ContentView also manages this
        // dynamically so it survives view lifecycle changes.
        UIApplication.shared.isIdleTimerDisabled = true
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .statusBar(hidden: true)
        }
    }
}
