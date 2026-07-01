import Foundation
import Combine
import AppKit
import UserNotifications
import BattlifyKit

/// Posts macOS notifications on charge-state transitions (limit reached, heat
/// pause, low battery, fully charged). Edge-triggered — it tracks the last state
/// and only fires when something actually changes, so it never spams.
@MainActor
final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var authRequested = false
    private var started = false
    private var cancellables = Set<AnyCancellable>()
    private weak var settingsRef: AppSettings?
    private weak var batteryRef: BatteryStore?
    private weak var chargeLimitRef: ChargeLimitStore?

    override init() {
        super.init()
        // Present banners even when a Battlify window happens to be frontmost.
        center.delegate = self
    }

    /// Subscribe to the stores so transitions are detected via Combine — reliably,
    /// unlike SwiftUI `onChange`/`onAppear` on a status-item label, which don't
    /// fire dependably. Idempotent; call it once from the always-rendered label.
    func startIfNeeded(settings: AppSettings, battery: BatteryStore, chargeLimit: ChargeLimitStore) {
        guard !started else { return }
        started = true
        settingsRef = settings; batteryRef = battery; chargeLimitRef = chargeLimit
        // Capture the current state as the baseline so pre-existing conditions
        // don't fire retroactively.
        evaluate(settings: settings, battery: battery, chargeLimit: chargeLimit)
        // `objectWillChange` fires *before* the value updates (on whatever thread
        // mutates it), so hop onto the main actor with a Task — that both reads the
        // settled values and is isolation-safe (unlike `assumeIsolated`, which traps
        // on macOS 26 when the callback isn't on the main actor's executor).
        Publishers.Merge(
            battery.objectWillChange.map { _ in () },
            chargeLimit.objectWillChange.map { _ in () }
        )
        .sink { [weak self] in
            Task { @MainActor in self?.reevaluate() }
        }
        .store(in: &cancellables)
    }

    private func reevaluate() {
        guard let settings = settingsRef, let battery = batteryRef, let chargeLimit = chargeLimitRef else { return }
        evaluate(settings: settings, battery: battery, chargeLimit: chargeLimit)
    }

    /// Post an immediate test notification so the user can confirm permission works.
    /// Resolves authorization first (posting before the prompt is answered drops
    /// the notification), and explains how to fix it if permission is off.
    func sendTest() {
        center.getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .authorized, .provisional:
                    self.post("test", "Battlify", "Notifications are working. 🔋")
                case .notDetermined:
                    self.center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                        Task { @MainActor in
                            if granted { self.post("test", "Battlify", "Notifications are working. 🔋") }
                            else { self.showDeniedAlert() }
                        }
                    }
                default:   // .denied
                    self.showDeniedAlert()
                }
            }
        }
    }

    /// Guide the user to enable notifications when the system has them turned off.
    private func showDeniedAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Notifications are turned off"
        alert.informativeText = "Turn on notifications for Battlify in System Settings › Notifications to receive charge alerts."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    // Last-seen state, for edge detection.
    private var initialized = false
    private var lastReason: String?
    private var lastLow = false
    private var lastFull = false

    /// Battery %, at or below which (on battery) we warn about low charge.
    private let lowThreshold = 20

    /// Ask for notification permission (once). Call when the user turns the
    /// setting on so the system prompt appears at an expected moment.
    func requestAuthorization() {
        guard !authRequested else { return }
        authRequested = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Evaluate current state and fire notifications for any new transitions.
    /// Safe to call on every relevant state change — it's idempotent.
    func evaluate(settings: AppSettings, battery: BatteryStore, chargeLimit: ChargeLimitStore) {
        let snap = battery.snapshot
        // Only treat charging as "paused" when it's actually off, and surface the
        // reason the daemon reported.
        let reason = chargeLimit.chargingEnabled ? nil : chargeLimit.pauseReason
        let low = !snap.isPluggedIn && snap.percentage <= lowThreshold
        let full = snap.isFullyCharged

        // Always advance the baseline so events that happen while notifications are
        // off (or before the first evaluation) don't fire retroactively when re-enabled.
        defer {
            lastReason = reason
            lastLow = low
            lastFull = full
            initialized = true
        }

        guard settings.notificationsEnabled, initialized else { return }
        requestAuthorization()

        if reason != lastReason {
            switch reason {
            case "heat":
                post("heat", "Charging paused",
                     "Your battery is warm — charging paused to protect it.")
            case "limit":
                post("limit", "Charge limit reached",
                     "Holding at \(chargeLimit.limit)% to reduce battery wear.")
            default:
                break   // "paused"/"settling"/"sleep" are user- or system-driven
            }
        }

        if low && !lastLow {
            post("low", "Low battery", "\(snap.percentage)% remaining — plug in soon.")
        }
        if full && !lastFull {
            post("full", "Battery full", "Charged to 100%.")
        }
    }

    /// Deliver a notification, replacing any prior one of the same category so
    /// they don't stack up.
    private func post(_ id: String, _ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.removePendingNotificationRequests(withIdentifiers: ["battlify.\(id)"])
        let request = UNNotificationRequest(
            identifier: "battlify.\(id)", content: content, trigger: nil)
        center.add(request)
    }
}
