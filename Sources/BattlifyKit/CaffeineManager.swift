import Foundation
import Combine
import IOKit.pwr_mgt

/// The OS "keep awake" primitive, abstracted so `CaffeineManager`'s logic can be
/// unit-tested without touching IOKit. Production uses `IOKitKeepAwake`; tests use
/// a fake that records calls.
public protocol KeepAwakeAsserting: Sendable {
    /// Acquire a hold that stops the display *and* system from idle-sleeping.
    /// Returns an opaque non-zero token, or 0 on failure.
    func acquire(reason: String) -> UInt32
    /// Release a token previously returned by `acquire`.
    func release(_ token: UInt32)
}

/// Real backend: a `PreventUserIdleDisplaySleep` power assertion — exactly what
/// `caffeinate -d` holds. Needs no root; released automatically when the process
/// exits, so it can never strand the Mac awake.
public struct IOKitKeepAwake: KeepAwakeAsserting {
    public init() {}

    public func acquire(reason: String) -> UInt32 {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id)
        return result == kIOReturnSuccess ? id : 0
    }

    public func release(_ token: UInt32) {
        if token != 0 { IOPMAssertionRelease(token) }
    }
}

/// "Caffeine" mode: keep the Mac awake — the display never turns off and the system
/// never idle-sleeps — until turned off (or an optional timer ends).
///
/// Holds a single user-space keep-awake assertion (`caffeinate -d`). It needs no
/// root and no helper daemon, works on battery *and* wall power, and is released the
/// instant the app quits. It intentionally does **not** stop lid-close (clamshell)
/// sleep: closing the lid still sleeps, matching Caffeine/Amphetamine.
@MainActor
public final class CaffeineManager: ObservableObject {
    /// Whether keep-awake is currently held.
    @Published public private(set) var active = false
    /// When a timed session auto-releases (nil = indefinite or inactive).
    @Published public private(set) var expiresAt: Date?

    private let backend: KeepAwakeAsserting
    private let reason: String
    /// Injectable delay so timed-expiry can be driven deterministically in tests.
    private let sleepFor: @Sendable (TimeInterval) async -> Void
    private var token: UInt32 = 0
    private var expiryTask: Task<Void, Never>?

    public init(backend: KeepAwakeAsserting = IOKitKeepAwake(),
                reason: String = "Battlify: Caffeine (keep awake)",
                sleepFor: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }) {
        self.backend = backend
        self.reason = reason
        self.sleepFor = sleepFor
    }

    /// Preset keep-awake durations offered in the menu.
    public enum Duration: String, Identifiable, CaseIterable, Sendable {
        case indefinite, min30, hour1, hours2, hours5

        public var id: String { rawValue }

        /// Seconds to hold, or nil for "until turned off".
        public var seconds: TimeInterval? {
            switch self {
            case .indefinite: return nil
            case .min30:      return 30 * 60
            case .hour1:      return 60 * 60
            case .hours2:     return 2 * 3600
            case .hours5:     return 5 * 3600
            }
        }

        public var title: String {
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
    public func toggle() { active ? deactivate() : activate(.indefinite) }

    /// Start keep-awake (or re-arm the timer with a new duration if already on).
    /// Idempotent: never stacks more than one assertion.
    public func activate(_ duration: Duration = .indefinite) {
        expiryTask?.cancel(); expiryTask = nil

        if token == 0 {
            token = backend.acquire(reason: reason)
            guard token != 0 else { active = false; expiresAt = nil; return }
        }
        active = true

        guard let secs = duration.seconds else { expiresAt = nil; return }
        expiresAt = Date().addingTimeInterval(secs)
        // Created in a @MainActor context, so the task body runs on the main actor;
        // the cancel + isCancelled check drops it cleanly if state changes first.
        expiryTask = Task { [weak self, sleepFor] in
            await sleepFor(secs)
            guard !Task.isCancelled else { return }
            self?.deactivate()
        }
    }

    /// Release keep-awake and let the Mac sleep/dim normally again. No-op if inactive.
    public func deactivate() {
        expiryTask?.cancel(); expiryTask = nil
        if token != 0 { backend.release(token); token = 0 }
        active = false
        expiresAt = nil
    }

    deinit {
        // The assertion is process-scoped; drop it if this ever tears down.
        if token != 0 { backend.release(token) }
    }
}
