import Foundation
import IOKit.pwr_mgt

/// A pure, testable policy for the experimental display assertion.
enum ScreenLockPreventionPolicy {
    static func shouldKeepDisplayAwake(enabled: Bool, workPending: Bool, locked: Bool) -> Bool {
        enabled && workPending && !locked
    }
}

/// An explicit opt-in, per-task attempt to postpone *automatic* screen locking.
/// macOS does not expose a universal public "disable lock" assertion.
/// Keeping the display awake plus renewing user activity helps with inactivity
/// timeouts, but cannot override screensavers, MDM policy, or explicit locking.
@MainActor
final class ScreenLockPreventionManager {
    private var displayActivity: NSObjectProtocol?
    private var userActivityAssertion: IOPMAssertionID = 0

    var isActive: Bool { displayActivity != nil }

    @discardableResult
    func setActive(_ enabled: Bool) -> Bool {
        if enabled {
            guard displayActivity == nil else { return false }
            displayActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                reason: "CodexReset: selected Codex task requires unlocked GUI fallback"
            )
            renewUserActivity()
            return true
        }
        guard let displayActivity else { return false }
        ProcessInfo.processInfo.endActivity(displayActivity)
        self.displayActivity = nil
        if userActivityAssertion != 0 {
            IOPMAssertionRelease(userActivityAssertion)
            userActivityAssertion = 0
        }
        return true
    }

    /// Refresh during polling (normally every 30 seconds), but never wake a
    /// manually locked display: the caller must check the lock state first.
    func renewUserActivity() {
        guard isActive else { return }
        let result = IOPMAssertionDeclareUserActivity(
            "CodexReset: selected task still requires GUI automation" as CFString,
            kIOPMUserActiveLocal,
            &userActivityAssertion
        )
        if result != kIOReturnSuccess {
            NSLog("CodexReset: unable to declare user activity (code %d)", result)
        }
    }

    func stop() {
        setActive(false)
    }
}
