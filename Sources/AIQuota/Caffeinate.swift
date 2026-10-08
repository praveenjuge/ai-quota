import Foundation
import IOKit.pwr_mgt

/// Keeps the display awake while on, like `caffeinate -d`: no dimming,
/// no idle sleep, so no idle lock. Power assertions never block Shut Down
/// or Restart, and closing the lid still sleeps the Mac as usual.
@MainActor
final class Caffeinate {
    private var assertionID: IOPMAssertionID?

    var isOn: Bool { assertionID != nil }

    func toggle() {
        if let assertionID {
            IOPMAssertionRelease(assertionID)
            self.assertionID = nil
        } else {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "AIQuota Caffeinate" as CFString,
                &id
            )
            if result == kIOReturnSuccess { assertionID = id }
        }
    }
}
