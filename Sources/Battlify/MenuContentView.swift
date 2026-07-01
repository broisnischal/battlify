import SwiftUI
import AppKit
import BattlifyKit

struct MenuContentView: View {
    @EnvironmentObject private var battery: BatteryStore
    @EnvironmentObject private var chargeLimit: ChargeLimitStore
    @EnvironmentObject private var automation: AutomationStore
    @EnvironmentObject private var license: LicenseManager
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
                }
                .disabled(!license.isPro)
                .opacity(license.isPro ? 1 : 0.45)
                Divider()
                quickActionsSection
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
    }

    private var maxPopoverHeight: CGFloat {
        // The popover opens on whichever display's menu bar was clicked — i.e. the
        // screen under the cursor — which isn't necessarily `NSScreen.main` (the
        // screen holding keyboard focus). On a multi-monitor setup, sizing to the
        // wrong screen's height clips the popover off the bottom or forces needless
        // scrolling, so resolve the actual screen first.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let usable = screen?.visibleFrame.height ?? 800
        return max(360, usable - 24)
    }

    // MARK: - Update banner

    private func updateBanner(_ update: AppUpdate) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Update available — v\(update.version)")
                    .font(.callout.weight(.medium))
                Text("You have v\(updater.currentVersion)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(updater.installing ? "Installing…" : "Update") { updater.installUpdate() }
                .controlSize(.small)
                .disabled(updater.installing)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - License banner

    @ViewBuilder
    private var licenseBanner: some View {
        let expired = !license.isPro
        HStack(spacing: 10) {
            Image(systemName: expired ? "lock.fill" : "sparkles")
                .foregroundStyle(.secondary)
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
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                Capsule().fill(chargeColor(snap))
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
        .help(chargeLimit.limitEnabled
              ? "Charge \(snap.percentage)%. The marker shows your \(chargeLimit.limit)% limit."
              : "Charge \(snap.percentage)%.")
    }

    private func limitCaption(_ snap: BatterySnapshot) -> String {
        if chargeLimit.isPaused { return "Charging paused" }
        if !chargeLimit.chargingEnabled { return "Holding at \(chargeLimit.limit)%" }
        if snap.isCharging { return "Charging to \(chargeLimit.limit)%" }
        return "Limit \(chargeLimit.limit)%"
    }

    // Green while charging, red at a critical level on battery, otherwise neutral.
    private func chargeColor(_ snap: BatterySnapshot) -> Color {
        if snap.isCharging { return .green }
        if snap.percentage <= 20 && !snap.isPluggedIn { return .red }
        return .primary
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

    // MARK: - Pause charging (idle / resume after N hours)

    @ViewBuilder
    private var pauseChargingControl: some View {
        if chargeLimit.isPaused {
            HStack(spacing: 8) {
                Image(systemName: "pause.circle").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Charging paused").font(.callout)
                    Text(pauseCaption()).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button("Resume") { chargeLimit.resumeCharging() }.controlSize(.small)
            }
        } else {
            Menu {
                Button("Pause 1 hour") { chargeLimit.pauseCharging(minutes: 60) }
                Button("Pause 3 hours") { chargeLimit.pauseCharging(minutes: 180) }
                Button("Pause 5 hours") { chargeLimit.pauseCharging(minutes: 300) }
                Divider()
                Button("Pause until I resume") { chargeLimit.pauseCharging(minutes: -1) }
            } label: {
                Label("Pause charging…", systemImage: "pause.circle")
            }
            .menuStyle(.borderlessButton)
            .font(.callout)
            .fixedSize()
        }
    }

    // One-shot "charge to 100% once" calibration.
    @ViewBuilder
    private var calibrationControl: some View {
        if chargeLimit.calibrating {
            HStack(spacing: 8) {
                Image(systemName: "bolt.badge.clock").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Charging to 100%").font(.callout)
                    Text("Limit resumes automatically once full.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button("Cancel") { chargeLimit.cancelCalibration() }.controlSize(.small)
            }
        } else {
            Button {
                chargeLimit.startCalibration()
            } label: {
                Label("Charge to 100% once", systemImage: "bolt.badge.clock")
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .help("Temporarily ignore the limit for a full charge, then revert.")
        }
    }

    private func pauseCaption() -> String {
        guard let until = chargeLimit.pauseUntil else { return "" }
        if chargeLimit.isPausedIndefinitely { return "Until you resume" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return "Resumes \(f.localizedString(for: until, relativeTo: Date()))"
    }

    // MARK: - Charge limit

    @ViewBuilder
    private var chargeLimitSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Charge Limit", "bolt.batteryblock.fill")

            if chargeLimit.daemonAvailable {
                pauseChargingControl

                if chargeLimit.daemonOutdated {
                    hintLabel("Helper is outdated — reinstall it from Settings.",
                              systemImage: "exclamationmark.triangle.fill")
                }

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

                    calibrationControl
                }

                // Live state: why charging is currently paused. Rare + useful, so
                // it stays in the menu; everything configurable moved to Settings.
                if chargeLimit.discharging {
                    hintLabel("Discharging to reach the limit…", systemImage: "battery.25")
                } else if !chargeLimit.chargingEnabled, let reason = chargeLimit.pauseReason {
                    switch reason {
                    case "heat":     hintLabel("Charging paused — battery is warm", systemImage: "thermometer.high")
                    case "limit":    hintLabel("Charging paused to hold limit", systemImage: "pause.circle.fill")
                    case "settling": hintLabel("Settling after wake — charging resumes shortly", systemImage: "moon.zzz")
                    default:         EmptyView()
                    }
                }
            } else {
                helperMissingView
            }
        }
    }

    @ViewBuilder
    private var helperMissingView: some View {
        Label("Helper not installed", systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.secondary)
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

    // MARK: - Quick actions

    @ViewBuilder
    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Quick Actions", "wand.and.rays")
            HStack(spacing: 8) {
                actionButton(actions.dimmed ? "Brighten" : "Dim",
                             systemImage: actions.dimmed ? "sun.max" : "sun.min",
                             help: actions.dimmed ? "Restore the previous brightness"
                                                  : "Dim the display to save power") {
                    actions.toggleDim()
                }
                actionButton("Display Off", systemImage: "moon",
                             help: "Turn the display off now (the Mac stays awake)") {
                    actions.turnDisplayOff()
                }
                actionButton("Sleep", systemImage: "powersleep",
                             help: "Put the Mac to sleep now") {
                    actions.sleepNow()
                }
            }
        }
    }

    private func actionButton(_ title: String, systemImage: String, help: String,
                              _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 15))
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Button("Settings…") { openDetached("settings") }
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
                .foregroundStyle(.secondary)
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
