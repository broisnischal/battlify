import Foundation
import Combine
import IOKit.pwr_mgt

/// The OS "keep awake" primitive, abstracted so `CaffeineManager` can be unit-tested
/// without touching IOKit.
public protocol KeepAwakeAsserting: Sendable {
    /// Acquire a hold that stops idle-sleep. Returns a non-zero token, or 0 on failure.
    func acquire(reason: String) -> UInt32
    func release(_ token: UInt32)
}

/// Real backend: a `PreventUserIdleDisplaySleep` assertion (what `caffeinate -d`
/// holds). Needs no root; auto-released on process exit, so it can't strand the Mac awake.
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

/// "Caffeine" mode: keep the Mac awake (display on, no idle-sleep) until turned off
/// or a timer ends. Holds one user-space assertion — no root, works on battery and AC.
/// Intentionally does *not* stop lid-close sleep, matching Caffeine/Amphetamine.
@MainActor
public final class CaffeineManager: ObservableObject {
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
        // Runs on the main actor; the cancel + isCancelled check drops it if state changes.
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
        if token != 0 { backend.release(token) }
    }
}
