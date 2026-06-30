import Foundation
import IOKit.ps
import Combine
import BattlifyKit

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
    }

    // No deinit cleanup: this store is owned by the App for the process lifetime,
    // so the run-loop source and timer live as long as the app does.

    func refresh() {
        snapshot = BatteryMonitor.read()
    }

    private func startPolling() {
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
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
