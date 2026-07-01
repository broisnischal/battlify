import Foundation
import IOKit.ps
import Combine
import AppKit
import BattlifyKit

extension Notification.Name {
    /// Posted when charging is enabled/disabled so views reading live battery
    /// state can re-read without waiting for the next slow poll.
    static let battlifyChargeStateChanged = Notification.Name("BattlifyChargeStateChanged")
}

/// Observable wrapper around `BatteryMonitor`. Updates immediately on power-source
/// changes (via an IOKit run-loop source) and on a slow timer as a fallback for
/// values IOKit doesn't push notifications for (temperature, cycle count).
@MainActor
final class BatteryStore: ObservableObject {
    @Published private(set) var snapshot: BatterySnapshot = .unknown

    private var timer: Timer?
    private var runLoopSource: CFRunLoopSource?

    init() {
        refresh()
        startPolling()
        startPowerSourceNotifications()
        // Refresh right after the Mac wakes so the menu isn't stale.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Re-read when charging is toggled by the daemon (limit change, pause,
        // calibrate, …). The SMC change takes a moment to surface in IOKit, so we
        // poll a couple of times over the next few seconds.
        NotificationCenter.default.addObserver(
            forName: .battlifyChargeStateChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSoon() }
        }
    }

    /// Refresh now and again shortly after, to catch a just-applied charge change
    /// once IOKit reflects it.
    func refreshSoon() {
        refresh()
        for delay in [1.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refresh()
            }
        }
    }

    // No deinit cleanup: this store is owned by the App for the process lifetime,
    // so the run-loop source and timer live as long as the app does.

    func refresh() {
        snapshot = BatteryMonitor.read()
    }

    private func startPolling() {
        // IOPS notifications handle instant %/charging changes; this slow timer
        // is just a fallback for values without notifications (temp, cycles).
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = 15   // this is only a fallback poll; let the OS coalesce it
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func startPowerSourceNotifications() {
        // Pass `self` through an opaque pointer so the C callback can call back in.
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let store = Unmanaged<BatteryStore>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in store.refresh() }
        }, context)?.takeRetainedValue() else { return }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
    }
}
