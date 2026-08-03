import Foundation
import Combine
import AppKit
import BattlifyKit

/// Owns the global-shortcut bindings: persistence, registration, and running the
/// action when one fires. The stores it drives are the same ones the menu uses, so a
/// shortcut and a click take exactly the same path.
@MainActor
final class HotkeyStore: ObservableObject {
    /// Master switch — off unregisters everything without discarding the bindings.
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Keys.enabled)
            reregister()
        }
    }

    @Published var bindings: HotkeyBindings {
        didSet {
            persist()
            reregister()
        }
    }

    /// Shortcuts the window server refused because another app already owns the
    /// combination. Shown in Settings — a shortcut that does nothing needs a reason.
    @Published private(set) var unavailable: Set<HotkeyAction> = []

    private let monitor = HotkeyMonitor()
    private let defaults = UserDefaults.standard
    private enum Keys {
        static let enabled = "hotkeys.enabled"
        static let bindings = "hotkeys.bindings"
    }

    // Weak: the app owns these for its whole lifetime, and a strong ref here would
    // be a retain cycle once a store wants to call back into shortcuts.
    private weak var chargeLimit: ChargeLimitStore?
    private weak var caffeine: CaffeineManager?
    private weak var systemActions: SystemActions?
    private weak var license: LicenseManager?
    /// SwiftUI's `openWindow` only exists inside a View, so it's injected.
    private var openWindow: ((String) -> Void)?

    init() {
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        if let data = defaults.data(forKey: Keys.bindings),
           let saved = try? JSONDecoder().decode(HotkeyBindings.self, from: data) {
            bindings = saved
        } else {
            // First launch: ship the defaults rather than nothing, so the feature is
            // discoverable without a trip to Settings.
            bindings = .default
        }
        monitor.onFire = { [weak self] action in self?.perform(action) }
    }

    /// Wire up the targets and start listening. Called once from the menu bar label,
    /// which is the one view guaranteed to exist from launch.
    func attach(chargeLimit: ChargeLimitStore,
                caffeine: CaffeineManager,
                systemActions: SystemActions,
                license: LicenseManager,
                openWindow: @escaping (String) -> Void) {
        guard self.chargeLimit == nil else { return }
        self.chargeLimit = chargeLimit
        self.caffeine = caffeine
        self.systemActions = systemActions
        self.license = license
        self.openWindow = openWindow
        reregister()
    }

    /// Re-supply the window opener from a view that definitely has it. The menu bar
    /// label attaches at launch, but its environment is the less-tested one — the
    /// dropdown's `openWindow` is the same closure the Settings/Details buttons use.
    func setOpenWindow(_ open: @escaping (String) -> Void) { openWindow = open }

    // MARK: - Editing

    /// Assign a combination, moving it off whatever held it before. Returns the
    /// action that lost its shortcut, so the UI can say so.
    @discardableResult
    func set(_ hotkey: Hotkey, for action: HotkeyAction) -> HotkeyAction? {
        var next = bindings
        let displaced = next.set(hotkey, for: action)
        bindings = next
        return displaced
    }

    func clear(_ action: HotkeyAction) {
        var next = bindings
        next.clear(action)
        bindings = next
    }

    func resetToDefaults() { bindings = .default }

    // MARK: - Registration

    private func persist() {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        defaults.set(data, forKey: Keys.bindings)
    }

    private func reregister() {
        monitor.apply(bindings, enabled: enabled)
        // Only publish a real change: `attach()` runs from a view's `onAppear`, and an
        // unconditional assignment there would notify SwiftUI mid-update for nothing.
        let rejected = monitor.rejected
        if rejected != unavailable { unavailable = rejected }
    }

    // MARK: - Dispatch

    private func perform(_ action: HotkeyAction) {
        if action.requiresPro, license?.isPro != true {
            HotkeyHUD.shared.show("Battlify Pro", detail: "\(action.title) needs a licence.",
                                  icon: "lock")
            return
        }

        switch action {
        case .toggleChargeLimit:   toggleChargeLimit()
        case .chargeLimitUp:       nudgeChargeLimit(by: 5)
        case .chargeLimitDown:     nudgeChargeLimit(by: -5)
        case .togglePauseCharging: togglePauseCharging()
        case .cycleSaveMode:       cycleSaveMode()
        case .toggleLowPowerMode:  toggleLowPowerMode()
        case .toggleDischarge:     toggleDischarge()

        case .toggleCaffeine:
            guard let caffeine else { return }
            caffeine.toggle()
            hud(action, caffeine.active ? "On" : "Off",
                detail: caffeine.active ? "Display and system won't sleep" : nil)

        case .toggleKeepAwake:
            guard let charge = requireDaemon() else { return }
            charge.keepAwake.toggle()
            charge.apply()
            hud(action, charge.keepAwake ? "On" : "Off",
                detail: charge.keepAwake ? "Stays awake with the lid closed, on AC" : nil)

        case .toggleDimDisplay:
            guard let systemActions else { return }
            systemActions.toggleDim()
            hud(action, systemActions.dimmed ? "Display Dimmed" : "Brightness Restored")

        case .displayOff:
            systemActions?.turnDisplayOff()

        case .sleepNow:
            systemActions?.sleepNow()

        case .openSettings: open("settings")
        case .openDetails:  open("details")
        case .openHistory:  open("history")
        }
    }

    /// The charging actions all go through the root helper; without it they'd fail
    /// silently, so say so instead.
    private func requireDaemon() -> ChargeLimitStore? {
        guard let chargeLimit else { return nil }
        guard chargeLimit.daemonAvailable else {
            HotkeyHUD.shared.show("Helper Not Running",
                                  detail: "Install it in Settings › General.",
                                  icon: "alert")
            return nil
        }
        return chargeLimit
    }

    private func toggleChargeLimit() {
        guard let charge = requireDaemon() else { return }
        charge.limitEnabled.toggle()
        charge.apply()
        hud(.toggleChargeLimit,
            charge.limitEnabled ? "Charge Limit On" : "Charge Limit Off",
            detail: charge.limitEnabled ? "Holding at \(charge.limit)%" : "Charges to 100%")
    }

    /// Steps within the same 50–100% range the sliders allow, and turns the limit on
    /// if it was off — pressing "lower the limit" should limit something.
    private func nudgeChargeLimit(by delta: Int) {
        guard let charge = requireDaemon() else { return }
        let next = min(100, max(50, charge.limit + delta))
        guard next != charge.limit || !charge.limitEnabled else {
            hud(delta > 0 ? .chargeLimitUp : .chargeLimitDown,
                "Charge Limit \(charge.limit)%", detail: delta > 0 ? "Already at the top"
                                                                  : "Already at the bottom")
            return
        }
        charge.limit = next
        charge.limitEnabled = true
        charge.apply()
        hud(delta > 0 ? .chargeLimitUp : .chargeLimitDown, "Charge Limit \(next)%")
    }

    private func togglePauseCharging() {
        guard let charge = requireDaemon() else { return }
        if charge.isPaused {
            charge.resumeCharging()
            hud(.togglePauseCharging, "Charging Resumed")
        } else {
            charge.pauseCharging(minutes: -1)   // -1 = until resumed
            hud(.togglePauseCharging, "Charging Paused", detail: "Until you resume")
        }
    }

    private func cycleSaveMode() {
        guard let charge = requireDaemon() else { return }
        let all = SaveMode.allCases
        let index = all.firstIndex(of: charge.mode) ?? 0
        let next = all[(index + 1) % all.count]
        charge.applyMode(next)
        hud(.cycleSaveMode, next.title, detail: next.summary)
    }

    private func toggleLowPowerMode() {
        guard let charge = requireDaemon() else { return }
        let next = !charge.lowPowerMode
        charge.setLowPowerMode(next)
        hud(.toggleLowPowerMode, next ? "Low Power Mode On" : "Low Power Mode Off")
    }

    private func toggleDischarge() {
        guard let charge = requireDaemon() else { return }
        guard charge.dischargeSupported else {
            hud(.toggleDischarge, "Not Supported", detail: "This Mac has no adapter control.")
            return
        }
        charge.dischargeEnabled.toggle()
        charge.apply()
        hud(.toggleDischarge,
            charge.dischargeEnabled ? "Force Discharge On" : "Force Discharge Off",
            detail: charge.dischargeEnabled ? "Running off the battery while plugged in" : nil)
    }

    private func open(_ id: String) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow?(id)
    }

    private func hud(_ action: HotkeyAction, _ title: String, detail: String? = nil) {
        HotkeyHUD.shared.show(title, detail: detail, icon: action.icon)
    }
}
