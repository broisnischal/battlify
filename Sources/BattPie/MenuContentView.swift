import SwiftUI
import AppKit
import BattPieKit

struct MenuContentView: View {
    @EnvironmentObject private var battery: BatteryStore
    @EnvironmentObject private var chargeLimit: ChargeLimitStore
    @EnvironmentObject private var automation: AutomationStore
    @Environment(\.openWindow) private var openWindow
    @State private var installError: String?
    @State private var contentHeight: CGFloat = 360

    private let popoverWidth: CGFloat = 300

    var body: some View {
        let snap = battery.snapshot

        // Adaptive height: as tall as the content, but never taller than the
        // screen — past that it scrolls.
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(snap)
                Divider()
                modeSection
                Divider()
                chargeLimitSection
                Divider()
                sleepSection
                Divider()
                powerSection
                Divider()
                footer
            }
            .padding(16)
            .background(GeometryReader { g in
                Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
            })
        }
        .frame(width: popoverWidth, height: min(contentHeight, maxPopoverHeight))
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
    }

    private var maxPopoverHeight: CGFloat {
        let usable = NSScreen.main?.visibleFrame.height ?? 800
        return max(360, usable - 24)
    }

    // MARK: - Header

    private func header(_ snap: BatterySnapshot) -> some View {
        HStack(spacing: 12) {
            Image(systemName: snap.menuBarSymbol)
                .font(.largeTitle)
                .foregroundStyle(headerTint(snap))
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(snap.percentage)%")
                    .font(.title.weight(.semibold))
                    .monospacedDigit()
                Text(statusLine(snap))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let eta = etaLine(snap) {
                Text(eta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private func headerTint(_ snap: BatterySnapshot) -> Color {
        if snap.isCharging || (snap.isPluggedIn && !snap.isFullyCharged) { return .green }
        if snap.percentage <= 20 { return .red }
        if snap.percentage <= 40 { return .yellow }
        return .primary
    }

    // MARK: - Save mode

    @ViewBuilder
    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Save Mode")
            if chargeLimit.daemonAvailable {
                Picker("", selection: Binding(
                    get: { chargeLimit.mode },
                    set: { applyMode($0) }
                )) {
                    ForEach(SaveMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(chargeLimit.mode.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Install the helper to use save modes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func applyMode(_ mode: SaveMode) {
        automation.apply(mode.profile)
        chargeLimit.applyMode(mode)
    }

    // MARK: - Charge limit

    @ViewBuilder
    private var chargeLimitSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Charge Limit")

            if chargeLimit.daemonAvailable {
                switchRow("Limit charging", Binding(
                    get: { chargeLimit.limitEnabled },
                    set: { chargeLimit.limitEnabled = $0; chargeLimit.apply() }
                ))

                if chargeLimit.limitEnabled {
                    HStack {
                        Text("Stop at").foregroundStyle(.secondary)
                        Spacer()
                        Text("\(chargeLimit.limit)%").fontWeight(.semibold).monospacedDigit()
                    }
                    .font(.callout)

                    Slider(
                        value: Binding(
                            get: { Double(chargeLimit.limit) },
                            set: { chargeLimit.limit = Int($0) }
                        ),
                        in: 50...100, step: 5,
                        onEditingChanged: { if !$0 { chargeLimit.apply() } }
                    )
                    .controlSize(.small)
                }

                // Heat-aware charging (independent of the % limit).
                switchRow("Pause charging when hot", Binding(
                    get: { chargeLimit.heatAwareEnabled },
                    set: { chargeLimit.heatAwareEnabled = $0; chargeLimit.apply() }
                ))
                if chargeLimit.heatAwareEnabled {
                    Stepper(value: Binding(
                        get: { chargeLimit.maxChargeTempC },
                        set: { chargeLimit.maxChargeTempC = $0; chargeLimit.apply() }
                    ), in: 30...45, step: 1) {
                        HStack {
                            Text("Max temp").foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(chargeLimit.maxChargeTempC)) °C")
                                .fontWeight(.semibold).monospacedDigit()
                        }
                        .font(.callout)
                    }
                    .controlSize(.small)
                }

                // Why charging is paused, if it is.
                if !chargeLimit.chargingEnabled, let reason = chargeLimit.pauseReason {
                    if reason == "heat" {
                        hintLabel("Charging paused — battery is warm", systemImage: "thermometer.high")
                    } else {
                        hintLabel("Charging paused to hold limit", systemImage: "pause.circle.fill")
                    }
                }
            } else {
                helperMissingView
            }
        }
    }

    @ViewBuilder
    private var helperMissingView: some View {
        Label("Helper not installed", systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
        Text("Charge limiting, Low Power Mode, and sleep settings need the root helper.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if HelperInstaller.canInstall {
            Button("Install Helper…") {
                let result = HelperInstaller.install()
                if result.ok {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { chargeLimit.refresh() }
                } else {
                    installError = result.message
                }
            }
            .controlSize(.small)
        } else {
            Text("Or run scripts/install-helper.sh")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let installError {
            Text(installError).font(.caption).foregroundStyle(.red).lineLimit(3)
        }
    }

    // MARK: - Sleep & idle

    @ViewBuilder
    private var sleepSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Sleep & Idle")

            switchRow("Turn off Wi-Fi on lid close", $automation.wifiOffOnLidClose)
            switchRow("Turn off Bluetooth on lid close", $automation.bluetoothOffOnLidClose)
            switchRow("Restore Wi-Fi/Bluetooth on wake", $automation.restoreOnWake)

            if chargeLimit.daemonAvailable {
                ForEach(PowerToggle.allCases, id: \.self) { toggle in
                    switchRowWithHint(toggle.title, hint: toggle.hint, Binding(
                        get: { chargeLimit.isPowerToggleOn(toggle) },
                        set: { chargeLimit.setPowerToggle(toggle, $0) }
                    ))
                }
                hintLabel("Turn these off to stop the Mac waking while the lid is closed.",
                          systemImage: "moon.zzz.fill")
            }
        }
    }

    // MARK: - Power

    @ViewBuilder
    private var powerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Power")
            if chargeLimit.daemonAvailable {
                switchRow("Low Power Mode", Binding(
                    get: { chargeLimit.lowPowerMode },
                    set: { chargeLimit.setLowPowerMode($0) }
                ))
            } else {
                Text("Low Power Mode needs the helper.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Button("Details…") { openDetached("details") }
            Button("History…") { openDetached("history") }
            Spacer()
            Button { battery.refresh(); chargeLimit.refresh() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
            Button { NSApplication.shared.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .help("Quit")
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }

    private func openDetached(_ id: String) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }

    // MARK: - Reusable bits

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    private func switchRow(_ title: String, _ value: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.callout)
            Spacer(minLength: 6)
            Toggle("", isOn: value)
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

    private func switchRowWithHint(_ title: String, hint: String,
                                   _ value: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                Text(hint).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Toggle("", isOn: value)
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

    private func hintLabel(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Formatting

    private func statusLine(_ snap: BatterySnapshot) -> String {
        if snap.isFullyCharged { return "Fully charged" }
        if snap.isCharging { return "Charging" }
        if snap.isPluggedIn { return "Plugged in, not charging" }
        return "On battery"
    }

    private func etaLine(_ snap: BatterySnapshot) -> String? {
        if snap.isCharging, let m = snap.timeToFull { return "\(formatMinutes(m))\nto full" }
        if !snap.isPluggedIn, let m = snap.timeToEmpty { return "\(formatMinutes(m))\nleft" }
        return nil
    }

    private func formatMinutes(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

/// Reports the natural height of the menu content so the popover can size to it.
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
