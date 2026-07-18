import Foundation
import Combine
import IOKit.pwr_mgt

/// "Caffeine" mode: keep the Mac awake — the display never turns off and the
/// system never idle-sleeps — until you turn it off (or an optional timer ends).
///
/// This holds a user-space `PreventUserIdleDisplaySleep` power assertion (the same
/// thing `caffeinate -d` does). Because it's an assertion, it needs no root and no
/// helper daemon, works on battery *and* wall power, and is released the instant the
/// app quits — so it can never strand the Mac awake. It intentionally does **not**
/// stop lid-close (clamshell) sleep: closing the lid still sleeps, matching how the
/// classic Caffeine/Amphetamine apps behave.
@MainActor
final class CaffeineManager: ObservableObject {
    /// Whether keep-awake is currently held.
    @Published private(set) var active = false
    /// When a timed session auto-releases (nil = indefinite or inactive).
    @Published private(set) var expiresAt: Date?

    private var assertionID: IOPMAssertionID = 0
    private var expiryTask: Task<Void, Never>?

    /// Preset keep-awake durations offered in the menu.
    enum Duration: String, Identifiable, CaseIterable {
        case indefinite, min30, hour1, hours2, hours5

        var id: String { rawValue }

        /// Seconds to hold, or nil for "until turned off".
        var seconds: TimeInterval? {
            switch self {
            case .indefinite: return nil
            case .min30:      return 30 * 60
            case .hour1:      return 60 * 60
            case .hours2:     return 2 * 3600
            case .hours5:     return 5 * 3600
            }
        }

        var title: String {
            switch self {
            case .indefinite: return "Until I turn it off"
            case .min30:      return "For 30 minutes"
            case .hour1:      return "For 1 hour"
            case .hours2:     return "For 2 hours"
            case .hours5:     return "For 5 hours"
            }
        }
    }

    /// Toggle indefinite keep-awake on/off.
    func toggle() { active ? deactivate() : activate(.indefinite) }

    /// Start keep-awake (or re-arm the timer with a new duration if already on).
    func activate(_ duration: Duration = .indefinite) {
        expiryTask?.cancel(); expiryTask = nil

        if assertionID == 0 {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Battlify: Caffeine (keep awake)" as CFString,
                &id)
            guard result == kIOReturnSuccess else {
                active = false; expiresAt = nil; return
            }
            assertionID = id
        }
        active = true

        guard let secs = duration.seconds else { expiresAt = nil; return }
        expiresAt = Date().addingTimeInterval(secs)
        // Created in a @MainActor context, so the task body runs on the main actor;
        // the cancel + isCancelled check drops it cleanly if state changes first.
        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.deactivate()
        }
    }

    /// Release keep-awake and let the Mac sleep/dim normally again.
    func deactivate() {
        expiryTask?.cancel(); expiryTask = nil
        if assertionID != 0 { IOPMAssertionRelease(assertionID); assertionID = 0 }
        active = false
        expiresAt = nil
    }

    deinit {
        // The assertion is process-scoped; drop it if this ever tears down.
        if assertionID != 0 { IOPMAssertionRelease(assertionID) }
    }
}
