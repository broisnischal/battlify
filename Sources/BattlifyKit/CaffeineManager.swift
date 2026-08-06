import Foundation
import Combine
import IOKit.pwr_mgt

/// How far a keep-awake hold reaches.
public enum KeepAwakeHold: String, Sendable, Equatable {
    /// The screen stays lit too (what `caffeinate -d` holds).
    case displayOn
    /// Work keeps running but the screen may sleep (`caffeinate -i`). On battery this
    /// is the difference between several watts and a few tenths of one.
    case systemOnly

    public var title: String {
        switch self {
        case .displayOn:  return "Screen stays on"
        case .systemOnly: return "Tasks keep running, screen may sleep"
        }
    }
}

/// The OS "keep awake" primitive, abstracted so `CaffeineManager` can be unit-tested
/// without touching IOKit.
public protocol KeepAwakeAsserting: Sendable {
    /// Acquire a hold that stops idle-sleep. Returns a non-zero token, or 0 on failure.
    func acquire(kind: KeepAwakeHold, reason: String) -> UInt32
    func release(_ token: UInt32)
}

/// Real backend: an IOPM idle-sleep assertion, display-wide or system-only. Needs no
/// root; auto-released on process exit, so it can't strand the Mac awake.
public struct IOKitKeepAwake: KeepAwakeAsserting {
    public init() {}

    public func acquire(kind: KeepAwakeHold, reason: String) -> UInt32 {
        var id: IOPMAssertionID = 0
        let type = kind == .displayOn
            ? kIOPMAssertPreventUserIdleDisplaySleep
            : kIOPMAssertPreventUserIdleSystemSleep
        let result = IOPMAssertionCreateWithName(
            type as CFString,
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
    /// What the live hold currently covers (nil = nothing held).
    @Published public private(set) var hold: KeepAwakeHold?

    /// Keep the screen lit on battery too. Off by default: an idle Mac with its display
    /// on is the most expensive thing this app can do to a battery (several watts, so
    /// percents per hour), while holding only the system awake still finishes the work
    /// for almost nothing.
    public private(set) var keepDisplayOnBattery = false
    /// End the session outright when unplugged — for a Mac that should never lose charge
    /// while left alone.
    public private(set) var endOnBattery = false
    /// Assume AC until the app says otherwise, so a hold is never silently weakened.
    public private(set) var onExternalPower = true

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
            token = backend.acquire(kind: desiredHold, reason: reason)
            guard token != 0 else { active = false; expiresAt = nil; hold = nil; return }
            hold = desiredHold
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
        hold = nil
    }

    /// Push the policy and the current power source in one idempotent call, so the app
    /// can hand it over on every render instead of wiring up another observer.
    public func applyPolicy(keepDisplayOnBattery: Bool,
                            endOnBattery: Bool,
                            onExternalPower: Bool) {
        guard keepDisplayOnBattery != self.keepDisplayOnBattery
                || endOnBattery != self.endOnBattery
                || onExternalPower != self.onExternalPower else { return }
        self.keepDisplayOnBattery = keepDisplayOnBattery
        self.endOnBattery = endOnBattery
        self.onExternalPower = onExternalPower
        reconcileHold()
    }

    private var desiredHold: KeepAwakeHold {
        (onExternalPower || keepDisplayOnBattery) ? .displayOn : .systemOnly
    }

    /// Bring the live hold in line with the policy: end the session on battery if asked,
    /// otherwise swap the assertion for the right kind. The replacement is acquired
    /// before the old one is released, so there's never a gap the display can sleep in,
    /// and the expiry timer keeps running — the session continues, only its reach changes.
    private func reconcileHold() {
        guard active, token != 0 else { return }
        if endOnBattery, !onExternalPower { deactivate(); return }
        guard hold != desiredHold else { return }
        let replacement = backend.acquire(kind: desiredHold, reason: reason)
        guard replacement != 0 else { return }   // keep what we have if the swap fails
        backend.release(token)
        token = replacement
        hold = desiredHold
    }

    deinit {
        if token != 0 { backend.release(token) }
    }
}
