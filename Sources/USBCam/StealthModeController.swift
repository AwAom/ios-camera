import UIKit
import Combine

/// Handles the OLED "black screen" battery saver: disables the idle timer,
/// drops screen brightness to zero and shows a pure-black overlay so OLED
/// panels switch those pixels off entirely, restoring the previous state
/// when toggled back off.
final class StealthModeController: ObservableObject {
    @Published private(set) var isActive = false

    private var savedBrightness: CGFloat = UIScreen.main.brightness
    private var savedIdleTimerDisabled: Bool = UIApplication.shared.isIdleTimerDisabled

    func toggle() {
        isActive ? deactivate() : activate()
    }

    func activate() {
        guard !isActive else { return }
        savedBrightness = UIScreen.main.brightness
        savedIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled

        UIApplication.shared.isIdleTimerDisabled = true
        UIScreen.main.brightness = 0.0
        isActive = true
    }

    func deactivate() {
        guard isActive else { return }
        UIScreen.main.brightness = max(savedBrightness, 0.2)
        UIApplication.shared.isIdleTimerDisabled = savedIdleTimerDisabled
        isActive = false
    }
}
