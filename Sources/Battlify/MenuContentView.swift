import SwiftUI
import AppKit
import BattlifyKit

struct MenuContentView: View {
    @EnvironmentObject private var battery: BatteryStore
    @EnvironmentObject private var chargeLimit: ChargeLimitStore
    @EnvironmentObject private var automation: AutomationStore
    @EnvironmentObject private var license: LicenseManager
    @EnvironmentObject private var startup: StartupManager
    @EnvironmentObject private var updater: UpdaterManager
    @EnvironmentObject private var actions: SystemActions
    @Environment(\.openWindow) private var openWindow
    @State private var installError: String?
    // Start near the typical full height so the popover doesn't visibly grow on
    // first open (the measured height then fine-tunes it).
    @State private var contentHeight: CGFloat = 600

    private let popoverWidth: CGFloat = 300

    var body: some View {
        let snap = battery.snapshot

        // Adaptive height: as tall as the content, but never taller than the
        // screen — past that it scrolls.
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(snap)
                Divider()
                if let update = updater.available { updateBanner(update); Divider() }
                if !license.isLicensed { licenseBanner; Divider() }
                Group {
                    modeSection
                    Divider()
                    chargeLimitSection
                    Divider()
                    sleepSection
                    Divider()
                    powerSection
                }
                .disabled(!license.isPro)
                .opacity(license.isPro ? 1 : 0.45)
                Divider()
                quickActionsSection
                Divider()
                generalSection
                Divider()
                footer
            }
            .padding(16)
            .background(GeometryReader { g in
                Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
            })
        }
        .scrollIndicators(.hidden)
        .frame(width: popoverWidth, height: min(contentHeight, maxPopoverHeight))
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        .tint(.green)
    }

    private var maxPopoverHeight: CGFloat {
        let usable = NSScreen.main?.visibleFrame.height ?? 800
        return max(360, usable - 24)
    }

    // MARK: - Update banner

    private func updateBanner(_ update: AppUpdate) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text("Update available — v\(update.version)")
                    .font(.callout.weight(.medium))
                Text("You have v\(updater.currentVersion)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Download") { updater.downloadAvailable() }
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - License banner

    @ViewBuilder
    private var licenseBanner: some View {
        let expired = !license.isPro
        HStack(spacing: 10) {
            Image(systemName: expired ? "lock.fill" : "sparkles")
                .foregroundStyle(expired ? .orange : .green)
            VStack(alignment: .leading, spacing: 1) {
                Text(expired ? "Trial ended — controls locked" : license.statusText)
                    .font(.callout.weight(.medium))
                Text(expired ? "Activate to keep using Battlify."
                             : "Activate any time to unlock permanently.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Activate") { openDetached("license") }
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((expired ? Color.orange : Color.green).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Header

    private func header(_ snap: BatterySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: snap.menuBarSymbol)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(chargeColor(snap))
                    .frame(width: 24)
                (Text("\(snap.percentage)")
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                 + Text("%")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary))
                    .monospacedDigit()
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(statusLine(snap)).font(.caption)
                    if let eta = etaLine(snap) {
                        Text(eta).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.secondary)
            }

            chargeGauge(snap)

            if chargeLimit.limitEnabled {
                Text(limitCaption(snap))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// Signature element: a charge bar that also marks where the limit sits.
    private func chargeGauge(_ snap: BatterySnapshot) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let frac = max(0, min(1, CGFloat(snap.percentage) / 100))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10)).frame(height: 8)
                Capsule().fill(chargeColor(snap).gradient)
                    .frame(width: max(8, w * frac), height: 8)
                if chargeLimit.limitEnabled {
                    let x = w * CGFloat(chargeLimit.limit) / 100
                    Rectangle()
                        .fill(Color.primary.opacity(0.65))
                        .frame(width: 2, height: 15)
                        .position(x: min(max(1, x), w - 1), y: 7.5)
                }
            }
            .frame(height: 15)
        }
        .frame(height: 15)
    }

    private func limitCaption(_ snap: BatterySnapshot) -> String {
        if !chargeLimit.chargingEnabled { return "Holding at \(chargeLimit.limit)%" }
        if snap.isCharging { return "Charging to \(chargeLimit.limit)%" }
        return "Limit \(chargeLimit.limit)%"
    }

    private func chargeColor(_ snap: BatterySnapshot) -> Color {
        if snap.isCharging || (snap.isPluggedIn && !snap.isFullyCharged) { return .green }
        if snap.percentage <= 20 { return .red }
        if snap.percentage <= 40 { return .orange }
        return .green
    }

    // MARK: - Save mode

    @ViewBuilder
    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Save Mode", "gauge.with.dots.needle.50percent")
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
            sectionHeader("Charge Limit", "bolt.batteryblock.fill")

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

                // Force-discharge down to the limit when plugged in above it.
                if chargeLimit.dischargeSupported {
                    switchRowWithHint(
                        "Discharge to limit",
                        hint: "If you plug in above the limit, run off battery until it drops back down.",
                        Binding(
                            get: { chargeLimit.dischargeEnabled },
                            set: { chargeLimit.dischargeEnabled = $0; chargeLimit.apply() }
                        ))
                    if chargeLimit.discharging {
                        hintLabel("Discharging to reach the limit…", systemImage: "battery.25")
                    }
                }

                // MagSafe LED reflects charge status (only if the Mac has one).
                if chargeLimit.magSafeSupported {
                    switchRowWithHint(
                        "MagSafe LED shows status",
                        hint: "Orange while charging, green when holding the limit.",
                        Binding(
                            get: { chargeLimit.magSafeLedEnabled },
                            set: { chargeLimit.magSafeLedEnabled = $0; chargeLimit.apply() }
                        ))
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
            sectionHeader("Sleep & Idle", "moon.zzz.fill")

            // Headline lid automation.
            switchRowWithHint(
                "Super Save when lid closed",
                hint: "Maximizes battery while closed, restores when you open it.",
                $automation.superSaveOnLidClose)

            // Manual radio controls only matter when Super Save isn't driving them.
            Group {
                switchRow("Turn off Wi-Fi on lid close", $automation.wifiOffOnLidClose)
                switchRow("Turn off Bluetooth on lid close", $automation.bluetoothOffOnLidClose)
                switchRow("Restore Wi-Fi/Bluetooth on wake", $automation.restoreOnWake)
            }
            .disabled(automation.superSaveOnLidClose)
            .opacity(automation.superSaveOnLidClose ? 0.45 : 1)

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
            sectionHeader("Power", "powerplug.fill")
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

    // MARK: - Quick actions

    @ViewBuilder
    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Quick Actions", "wand.and.rays")
            HStack(spacing: 8) {
                actionButton(actions.dimmed ? "Brighten" : "Dim",
                             systemImage: actions.dimmed ? "sun.max" : "sun.min") {
                    actions.toggleDim()
                }
                actionButton("Display Off", systemImage: "moon") {
                    actions.turnDisplayOff()
                }
                actionButton("Sleep", systemImage: "powersleep") {
                    actions.sleepNow()
                }
            }
        }
    }

    private func actionButton(_ title: String, systemImage: String,
                              _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 15))
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - General (login item + lid sensor)

    @ViewBuilder
    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("General", "gearshape.fill")

            switchRow("Launch at login", Binding(
                get: { startup.launchAtLogin },
                set: { startup.setLaunchAtLogin($0) }
            ))
            if startup.requiresApproval {
                hintLabel("Approve Battlify in System Settings › General › Login Items.",
                          systemImage: "exclamationmark.triangle.fill")
            }

            HStack(spacing: 8) {
                Image(systemName: automation.isLidClosed
                      ? "macbook.and.iphone" : "macbook")
                    .foregroundStyle(automation.isLidClosed ? .orange : .secondary)
                Text("Lid").foregroundStyle(.secondary)
                Spacer()
                Text(automation.isLidClosed ? "Closed · clamshell" : "Open")
                    .fontWeight(.medium)
                    .foregroundStyle(automation.isLidClosed ? .orange : .primary)
            }
            .font(.callout)

            if automation.isLidClosed {
                hintLabel("Docked & closed runs hot at 100% — keep a charge limit + heat pause on.",
                          systemImage: "thermometer.high")
            }

            HStack {
                Button(updater.checking ? "Checking…" : "Check for Updates…") {
                    updater.check(userInitiated: true)
                }
                .disabled(updater.checking)
                Spacer()
                Text("v\(updater.currentVersion)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .font(.callout)
            .buttonStyle(.borderless)
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

    private func sectionHeader(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tint)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.6)
        }
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
        if snap.isCharging, let m = snap.timeToFull { return "\(formatMinutes(m)) to full" }
        if !snap.isPluggedIn, let m = snap.timeToEmpty { return "\(formatMinutes(m)) left" }
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
