import Foundation
import IOKit.ps
import Combine
import AppKit
import BattlifyKit

extension Notification.Name {
    /// Posted when charging toggles so views can re-read without waiting for the slow poll.
    static let battlifyChargeStateChanged = Notification.Name("BattlifyChargeStateChanged")
}

/// Observable wrapper around BatteryMonitor: instant updates via an IOKit run-loop
/// source, plus a slow fallback timer for values IOKit doesn't notify (temp, cycles).
@MainActor
final class BatteryStore: ObservableObject {
    @Published private(set) var snapshot: BatterySnapshot = .unknown
    /// Live power flow (adapter/battery/system watts).
    @Published private(set) var powerFlow: PowerFlow = .unknown

    private var timer: Timer?
    private var powerTimer: Timer?
    private var powerViewers = 0
    private var runLoopSource: CFRunLoopSource?

    init() {
        refresh()
        startPolling()
        startPowerSourceNotifications()
        // Refresh right after the Mac wakes so the menu isn't stale.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // SMC change takes a moment to surface in IOKit, so poll a few times over a few seconds.
        NotificationCenter.default.addObserver(
            forName: .battlifyChargeStateChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshSoon() }
        }
    }

    /// Refresh now and again shortly after, to catch a change once IOKit reflects it.
    func refreshSoon() {
        refresh()
        for delay in [0.3, 1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refresh()
            }
        }
    }

    // No deinit cleanup: owned by the App for the process lifetime.

    func refresh() {
        snapshot = BatteryMonitor.read()
        powerFlow = PowerMonitor.read()
    }

    private func startPolling() {
        // Fallback for values IOKit doesn't notify (temp, cycles); IOPS handles instant changes.
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = 15   // this is only a fallback poll; let the OS coalesce it
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Live watts only show in the open popover and the Details window, so poll for
    /// them only while one is visible (call from `.onAppear`). Off-screen this saves
    /// a 5s IOKit read + publish + menu-bar re-render for the app's whole lifetime.
    func beginPowerFlowObserving() {
        powerViewers += 1
        guard powerTimer == nil else { return }
        powerFlow = PowerMonitor.read()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.powerFlow = PowerMonitor.read() }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        powerTimer = t
    }

    /// Call from `.onDisappear`.
    func endPowerFlowObserving() {
        powerViewers = max(0, powerViewers - 1)
        if powerViewers == 0 {
            powerTimer?.invalidate()
            powerTimer = nil
        }
    }

    private func startPowerSourceNotifications() {
        // Pass `self` through an opaque pointer so the C callback can call back in.
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let store = Unmanaged<BatteryStore>.fromOpaque(ctx).takeUnretainedValue()
            // IOKit's charging/plugged flags can trail the actual plug/unplug, so read a few times.
            Task { @MainActor in store.refreshSoon() }
        }, context)?.takeRetainedValue() else { return }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
    }
}
