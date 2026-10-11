import Foundation
import AppKit
import CoreGraphics

/// Observes the interactive console lock. The distributed notification names and
/// CGSSessionScreenIsLocked dictionary key are not public API guarantees; therefore
/// GUI delivery is never considered verified solely from an osascript exit status.
@MainActor
final class ScreenLockMonitor {
    private var notificationLocked: Bool?
    private var observers: [NSObjectProtocol] = []
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let center = DistributedNotificationCenter.default()
        for (event, locked) in [("com.apple.screenIsLocked", true),
                                ("com.apple.screenIsUnlocked", false)] {
            let token = center.addObserver(
                forName: Notification.Name(event), object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.notificationLocked = locked
                    self?.onChange()
                }
            }
            observers.append(token)
        }
    }

    var isLocked: Bool {
        Self.isSessionLocked(notificationLocked: notificationLocked)
    }

    nonisolated static func isSessionLocked(notificationLocked: Bool? = nil) -> Bool {
        // If the WindowServer session is not available, GUI input is unsafe.
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return true
        }
        if let locked = session["CGSSessionScreenIsLocked"] as? Bool, locked {
            return true
        }
        // Explicit lock notifications take precedence when this undocumented
        // session key is unavailable on a particular macOS release.
        if notificationLocked == true { return true }
        if let onConsole = session["kCGSessionOnConsoleKey"] as? Bool,
           !onConsole { return true }
        return false
    }

    deinit {
        for token in observers {
            DistributedNotificationCenter.default().removeObserver(token)
        }
    }
}
