import SwiftUI
import AppKit
import BattlifyKit

/// Detached preferences window for the "set once and forget" controls.
struct SettingsView: View {
    @EnvironmentObject private var battery: BatteryStore
    @EnvironmentObject private var chargeLimit: ChargeLimitStore
    @EnvironmentObject private var automation: AutomationStore
    @EnvironmentObject private var license: LicenseManager
    @EnvironmentObject private var startup: StartupManager
    @EnvironmentObject private var updater: UpdaterManager
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var notifier: NotificationManager
    @EnvironmentObject private var network: NetworkProfileStore
    @EnvironmentObject private var endurance: EnduranceStore
    @EnvironmentObject private var triggers: TriggerStore
    @Environment(\.openWindow) private var openWindow
    @State private var installError: String?
    @State private var selection: Tab = .charging
    /// Schedule being edited/added in the sheet (nil = sheet closed).
    @State private var editingSchedule: ChargeSchedule?
    @State private var editingIsNew = false
    /// Automation rule being edited/added in the sheet (nil = sheet closed).
    @State private var editingRule: TriggerRule?
    @State private var editingRuleIsNew = false
    /// Whether the "pick running processes" sheet for keep-awake is open.
    @State private var showingProcessPicker = false

    /// Hand-rolled tab bar instead of `TabView`, which on recent macOS collapses
    /// into an overflow popup instead of showing real tabs.
    private enum Tab: String, CaseIterable, Identifiable {
        case charging, schedule, automation, sleepPower, general, about
        var id: String { rawValue }

        var title: String {
            switch self {
            case .charging: return "Charging"
            case .schedule: return "Schedule"
            case .automation: return "Automation"
            case .sleepPower: return "Sleep & Power"
            case .general: return "General"
            case .about: return "About"
            }
        }
        var icon: String {
            switch self {
            case .charging: return "charging"
            case .schedule: return "clock"
            case .automation: return "wand"
            case .sleepPower: return "sleep"
            case .general: return "settings"
            case .about: return "info"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            Group {
                switch selection {
                case .charging:   chargingTab
                case .schedule:   scheduleTab
                case .automation: automationTab
                case .sleepPower: sleepPowerTab
                case .general:    generalTab
                case .about:      aboutTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Wide enough for six tabs to sit on one row without crowding.
        .frame(width: 560, height: 580)
        .sheet(item: $editingSchedule) { schedule in
            ScheduleEditorView(
                schedule: schedule,
                isNew: editingIsNew,
                onSave: { chargeLimit.updateOrAddSchedule($0) },
                onDelete: editingIsNew ? nil : { chargeLimit.removeSchedule(schedule) })
        }
        .sheet(item: $editingRule) { rule in
            TriggerRuleEditorView(
                store: triggers,
                rule: rule,
                isNew: editingRuleIsNew,
                onSave: { triggers.updateOrAddRule($0) },
                onDelete: editingRuleIsNew ? nil : { triggers.removeRule(rule) })
        }
        .sheet(isPresented: $showingProcessPicker) {
            ProcessPickerView(existing: chargeLimit.keepAwakeProcesses) { picked in
                // Union with the existing list (case-insensitive), preserving order.
                var names = chargeLimit.keepAwakeProcesses
                let have = Set(names.map { $0.lowercased() })
                for name in picked where !have.contains(name.lowercased()) { names.append(name) }
                chargeLimit.keepAwakeProcesses = names
                chargeLimit.apply()
            }
        }
    }

    // MARK: - Tab bar

    /// Tabs share the bar equally. A fixed per-tab minimum would overflow the
    /// window once there were six of them, pushing the last pill off the edge.
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private func tabButton(_ tab: Tab) -> some View {
        let selected = selection == tab
        return Button {
            selection = tab
        } label: {
            VStack(spacing: 4) {
                HugeIcon(tab.icon, size: 19)
                    .frame(height: 20)
                Text(tab.title)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // No focus ring: on a tab strip it reads as a stray outline, not focus.
        .focusEffectDisabled()
    }

    // MARK: - About

    private var aboutTab: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    HugeIcon("charging", size: 40)
                        .foregroundStyle(.tint)
                        .frame(width: 76, height: 76)
                        .background(.quaternary.opacity(0.4),
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Text("Battlify")
                        .font(.title2.weight(.semibold))
                    Text("Version \(updater.currentVersion)")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Created by Nischal Dahal")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.top, 28)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)

                Divider()

                VStack(spacing: 0) {
                    licenseRow
                    divider
                    linkRow("Send Me an Email", systemImage: "mail",
                            url: "mailto:nischaldahal01395@gmail.com")
                    divider
                    linkRow("Donate", systemImage: "heart",
                            url: "https://nischal-dahal.com.np/donate")
                    divider
                    linkRow("Check It Out on GitHub", systemImage: "code",
                            url: "https://github.com/broisnischal/battlify")
                    divider
                    linkRow("Visit the Website", systemImage: "compass",
                            url: "https://nischal-dahal.com.np")
                }
                .padding(.vertical, 20)

                Divider()

                Text("Made with care for Apple Silicon Macs.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 16)
            }
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    /// Always available so a licensed user can still manage the license after the
    /// trial banner is gone.
    private var licenseRow: some View {
        Button {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "license")
        } label: {
            HStack(spacing: 10) {
                HugeIcon(license.isLicensed ? "check" : "key", size: 19)
                    .frame(width: 22)
                    .foregroundStyle(.tint)
                Text(license.isLicensed ? "Manage License" : "Activate License")
                    .foregroundStyle(.tint)
                Spacer()
                Text(license.statusText)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                HugeIcon("chevronRight", size: 12)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 24)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func linkRow(_ title: String, systemImage: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        } label: {
            HStack(spacing: 10) {
                HugeIcon(systemImage, size: 17)
                    .frame(width: 22)
                    .foregroundStyle(.tint)
                Text(title)
                    .foregroundStyle(.tint)
                Spacer()
                HugeIcon("arrowUpRight", size: 13)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 24)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Charging

    private var chargingTab: some View {
        tab {
            if chargeLimit.daemonAvailable {
                proGate {
                    card("Enforcement") {
                        toggleRow("Stop charging before sleep",
                                  "Cuts charging as the Mac sleeps so it can't top up past the limit.",
                                  isOn: bind(\.disableChargingBeforeSleep))
                        divider
                        toggleRow("Prevent idle sleep while plugged in",
                                  "Keeps the Mac awake on power so the limit is always enforced. Uses a little more energy.",
                                  isOn: bind(\.preventIdleSleep))
                        divider
                        toggleRow("Always Active (keep awake with lid closed)",
                                  "Terminal jobs and background tasks keep running with the lid shut. The display and keyboard backlight switch off while the lid is closed to save power. On AC power by default — it releases when you unplug unless you turn on “Also keep awake on battery” below. Heavy work with the lid closed runs hot, so keep it ventilated.",
                                  isOn: bind(\.keepAwake))
                        if chargeLimit.keepAwake {
                            divider
                            toggleRow("Also keep awake on battery",
                                      "Keep running with the lid closed even when unplugged. The battery drains quickly and a closed Mac can run hot — set a temperature guardrail below. Off by default.",
                                      isOn: bind(\.keepAwakeOnBattery))
                            divider
                            toggleRow("Only while a task is running",
                                      "Stay awake only while a matching process runs, then let the Mac sleep — so an overnight build or download finishes and then it rests.",
                                      isOn: bind(\.keepAwakeRequiresTask))
                            if chargeLimit.keepAwakeRequiresTask {
                                divider
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text("Keep awake for these apps/processes").font(.callout)
                                        Spacer()
                                        Button {
                                            showingProcessPicker = true
                                        } label: {
                                            Label("Choose…", systemImage: "plus.circle")
                                        }
                                        .buttonStyle(.link)
                                    }
                                    TextField("e.g. ffmpeg, npm, docker, rsync",
                                              text: keepAwakeProcessText)
                                        .textFieldStyle(.roundedBorder)
                                    Text("Comma-separated names; matched against running commands. Use “Choose…” to pick from running processes.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                divider
                                stepperRow("Or any process above",
                                           value: chargeLimit.keepAwakeMinCpu > 0
                                                ? "\(Int(chargeLimit.keepAwakeMinCpu))% CPU" : "Off",
                                           binding: Binding(
                                            get: { chargeLimit.keepAwakeMinCpu },
                                            set: { chargeLimit.keepAwakeMinCpu = $0; chargeLimit.apply() }),
                                           range: 0...100)
                                divider
                                toggleRow("Sleep when the task finishes",
                                          "Put the Mac to sleep automatically once the matching task stops (waits ~30s to be sure it's really done), so an overnight build or download finishes and then the Mac sleeps.",
                                          isOn: bind(\.sleepWhenTaskDone))
                            }
                            divider
                            toggleRow("Sleep if it gets too hot",
                                      "Safety guardrail — releases keep-awake and lets the Mac sleep if it runs hot with the lid closed.",
                                      isOn: Binding(
                                        get: { chargeLimit.keepAwakeMaxTempC > 0 },
                                        set: { chargeLimit.keepAwakeMaxTempC = $0 ? 40 : 0; chargeLimit.apply() }))
                            if chargeLimit.keepAwakeMaxTempC > 0 {
                                divider
                                stepperRow("Temperature cutoff",
                                           value: "\(Int(chargeLimit.keepAwakeMaxTempC)) °C",
                                           binding: Binding(
                                            get: { chargeLimit.keepAwakeMaxTempC },
                                            set: { chargeLimit.keepAwakeMaxTempC = $0; chargeLimit.apply() }),
                                           range: 35...55)
                            }
                        }
                    }

                    card("Heat") {
                        toggleRow("Pause charging when hot",
                                  "Stops charging when the battery runs warm to reduce wear.",
                                  isOn: bind(\.heatAwareEnabled))
                        if chargeLimit.heatAwareEnabled {
                            divider
                            stepperRow("Max temperature",
                                       value: "\(Int(chargeLimit.maxChargeTempC)) °C",
                                       binding: Binding(
                                        get: { chargeLimit.maxChargeTempC },
                                        set: { chargeLimit.maxChargeTempC = $0; chargeLimit.apply() }),
                                       range: 30...45)
                        }
                    }

                    if chargeLimit.dischargeSupported {
                        card("Discharge") {
                            toggleRow("Discharge to limit",
                                      "If you plug in above the limit, run off battery until it drops back down.",
                                      isOn: bind(\.dischargeEnabled))
                        }
                    }

                    if chargeLimit.magSafeSupported {
                        card("MagSafe LED") {
                            pickerRow(magSafeHint) {
                                Picker("", selection: Binding(
                                    get: { chargeLimit.magSafeLedMode },
                                    set: { chargeLimit.magSafeLedMode = $0; chargeLimit.apply() })) {
                                    ForEach(MagSafeLEDMode.allCases) { Text($0.title).tag($0) }
                                }
                                .pickerStyle(.segmented).labelsHidden()
                            }
                        }
                    }
                }
            } else {
                helperCard
            }
        }
    }

    // MARK: - Schedule

    private var scheduleTab: some View {
        tab {
            if chargeLimit.daemonAvailable {
                proGate {
                    card("Charging schedules") {
                        if chargeLimit.schedules.isEmpty {
                            infoRow("No schedules yet. Add one to charge, hold, or run on battery on a weekly timetable — for example, hold every night from 10 PM for 5 hours.",
                                    systemImage: "clock")
                        } else {
                            ForEach(chargeLimit.schedules) { s in
                                scheduleRow(s)
                                divider
                            }
                        }
                        HStack {
                            Button {
                                editingIsNew = true
                                editingSchedule = ChargeSchedule()
                            } label: { Label("Add Schedule", systemImage: "plus") }
                                .controlSize(.small)
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                    }

                    card("Ready by") {
                        toggleRow("Charge to a target by a set time",
                                  "Hold at your limit overnight, then top up so it's ready right on time — minimizing hours spent at a high charge.",
                                  isOn: Binding(
                                    get: { chargeLimit.readyBy.enabled },
                                    set: { chargeLimit.readyBy.enabled = $0; chargeLimit.apply() }))
                        if chargeLimit.readyBy.enabled {
                            divider
                            HStack {
                                Text("Ready by").font(.callout)
                                Spacer()
                                DatePicker("", selection: Binding(
                                    get: { ClockTime.date(fromMinute: chargeLimit.readyBy.targetMinute) },
                                    set: { chargeLimit.readyBy.targetMinute = ClockTime.minute(from: $0); chargeLimit.apply() }),
                                    displayedComponents: .hourAndMinute)
                                .labelsHidden()
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            divider
                            stepperRow("Charge to",
                                       value: "\(chargeLimit.readyBy.targetPercent)%",
                                       binding: Binding(
                                        get: { Double(chargeLimit.readyBy.targetPercent) },
                                        set: { chargeLimit.readyBy.targetPercent = Int($0); chargeLimit.apply() }),
                                       range: 50...100)
                            divider
                            VStack(alignment: .leading, spacing: 8) {
                                Text("On these days").font(.callout)
                                WeekdayPicker(days: Binding(
                                    get: { chargeLimit.readyBy.days },
                                    set: { chargeLimit.readyBy.days = $0; chargeLimit.apply() }))
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                        }
                    }

                    card("Charge power") {
                        chargePowerRow
                    }
                }
            } else {
                helperCard
            }
        }
    }

    private func scheduleRow(_ s: ChargeSchedule) -> some View {
        Button {
            editingIsNew = false
            editingSchedule = s
        } label: {
            HStack(spacing: 10) {
                Image(systemName: scheduleIcon(s.action))
                    .frame(width: 22)
                    .foregroundStyle(s.enabled ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(s.label.isEmpty ? s.action.title : s.label)
                            .font(.callout)
                        if chargeLimit.activeSchedule?.id == s.id {
                            Text("ACTIVE")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.green.opacity(0.25), in: Capsule())
                                .foregroundStyle(.green)
                        }
                    }
                    Text("\(s.windowLabel()) · \(s.days.summary)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { s.enabled },
                    set: { var c = s; c.enabled = $0; chargeLimit.updateSchedule(c) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func scheduleIcon(_ a: ScheduleAction) -> String {
        switch a {
        case .charge: return "bolt.fill"
        case .hold: return "pause.fill"
        case .discharge: return "battery.25"
        }
    }

    // MARK: - Automation

    /// Condition-driven rules: apply a charging or power setting while something
    /// is true of the Mac, and put it back when it stops being true.
    private var automationTab: some View {
        tab {
            if chargeLimit.daemonAvailable {
                proGate {
                    card("Rules") {
                        if triggers.rules.isEmpty {
                            infoRow("No rules yet. A rule watches your Mac — a display connected, an app running, a network joined, the CPU busy — and applies a charging or power setting the whole time that holds, then puts your setting back.",
                                    systemImage: "wand")
                            divider
                        } else {
                            ForEach(triggers.rules) { rule in
                                TriggerRuleRow(store: triggers, rule: rule) {
                                    editingRuleIsNew = false
                                    editingRule = rule
                                }
                                divider
                            }
                        }
                        HStack(spacing: 10) {
                            Button {
                                editingRuleIsNew = true
                                editingRule = TriggerRule()
                            } label: {
                                HStack(spacing: 5) {
                                    HugeIcon("plus", size: 12)
                                    Text("Add Rule")
                                }
                            }
                            .controlSize(.small)

                            Menu("Start from an example") {
                                ForEach(TriggerStore.templates) { template in
                                    Button(template.label) {
                                        // A fresh id, so the same example can be
                                        // added more than once.
                                        var rule = template
                                        rule.id = UUID()
                                        editingRuleIsNew = true
                                        editingRule = rule
                                    }
                                }
                            }
                            .controlSize(.small)
                            .fixedSize()

                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                    }

                    if needsLocationForWiFiRule {
                        card("Permission needed") {
                            infoRow("macOS treats the Wi-Fi network name as location data, so a Wi-Fi condition can't match until Battlify has Location access.",
                                    systemImage: "location")
                            divider
                            HStack {
                                Button("Grant Location Access…") { network.requestLocationAccess() }
                                    .controlSize(.small)
                                Spacer()
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                        }
                    }

                    card("Right now") {
                        TriggerLiveStateView(store: triggers)
                    }
                }
            } else {
                helperCard
            }
        }
    }

    /// A Wi-Fi rule is set up, but macOS won't hand over the network name yet.
    private var needsLocationForWiFiRule: Bool {
        !network.locationAuthorized && triggers.rules.contains { rule in
            rule.enabled && rule.conditions.contains { $0.kind == .wifiNetwork }
        }
    }

    // MARK: - Sleep & Power

    private var sleepPowerTab: some View {
        tab {
            proGate {
                card("Battery saver (Endurance)") {
                    toggleRow("Endurance mode",
                              "Cuts battery drain: dims the screen, turns on Low Power Mode, and trims background wake & Bluetooth. Restores everything when you turn it off.",
                              isOn: Binding(get: { endurance.active },
                                            set: { endurance.setActive($0) }))
                    divider
                    toggleRow("Turn on automatically on battery",
                              "Activates Endurance whenever you unplug, and turns it back off when you plug in.",
                              isOn: $endurance.autoOnBattery)
                    if endurance.brightnessSupported {
                        divider
                        stepperRow("Screen brightness cap",
                                   value: "\(Int((endurance.brightnessCap * 100).rounded()))%",
                                   binding: Binding(
                                    get: { endurance.brightnessCap * 100 },
                                    set: { endurance.brightnessCap = $0 / 100 }),
                                   range: 20...80)
                    }
                    divider
                    if let s = endurance.savingsPercent {
                        infoRow("Measured: \(s)% less drain — normal \(fmtW(endurance.normalWatts)) → saver \(fmtW(endurance.enduranceWatts)).\(nowSuffix)",
                                systemImage: "leaf")
                    } else {
                        infoRow("Measuring drain… run on battery with the mode on and off for a few minutes to compare.\(nowSuffix)",
                                systemImage: "gauge")
                    }
                }

                card("Hibernate after a while") {
                    pickerRow(hibernateDelaySummary) {
                        Picker("", selection: Binding(
                            get: { chargeLimit.hibernateAfterMinutes },
                            set: { chargeLimit.hibernateAfterMinutes = $0; chargeLimit.apply() })) {
                            Text("Off").tag(0)
                            Text("30 min").tag(30)
                            Text("1 hour").tag(60)
                            Text("3 hours").tag(180)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                }

                card("Deep sleep") {
                    pickerRow(chargeLimit.sleepDepth.summary) {
                        Picker("", selection: Binding(
                            get: { chargeLimit.sleepDepth },
                            set: { chargeLimit.sleepDepth = $0; chargeLimit.apply() })) {
                            ForEach(SleepDepth.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                    if chargeLimit.sleepDepth == .deep {
                        divider
                        infoRow("Opening the lid will take a few seconds while memory is read back from disk — the more memory in use, the longer it takes. Worth it only if the Mac often stays closed for a day or more.",
                                systemImage: "clock")
                    }
                    divider
                    infoRow("A closed Mac already sips power, so expect a small gain, not a large one. macOS still wakes briefly now and then for maintenance either way.",
                            systemImage: "bulb")
                }

                card("When the lid closes") {
                    toggleRow("Super Save when lid closed",
                              "Maximizes battery while closed, restores when you open it.",
                              isOn: $automation.superSaveOnLidClose)
                    divider
                    Group {
                        toggleRow("Turn off Wi-Fi", isOn: $automation.wifiOffOnLidClose)
                        divider
                        toggleRow("Turn off Bluetooth", isOn: $automation.bluetoothOffOnLidClose)
                        divider
                        toggleRow("Restore Wi-Fi & Bluetooth on wake", isOn: $automation.restoreOnWake)
                    }
                    .disabled(automation.superSaveOnLidClose)
                    .opacity(automation.superSaveOnLidClose ? 0.45 : 1)
                }

                if chargeLimit.daemonAvailable {
                    powerToggleCard("On Battery", category: .batteryOptions)

                    powerToggleCard("Wake while closed", category: .sleepWake)

                    card("Power") {
                        toggleRow("Low Power Mode",
                                  "Save Modes turn this on. It also lowers the display refresh rate on ProMotion Macs — turn it off here to get full refresh rate back.",
                                  isOn: Binding(
                                    get: { chargeLimit.lowPowerMode },
                                    set: { chargeLimit.setLowPowerMode($0) }))
                    }

                    networkCard
                }
            }
        }
    }

    // MARK: - Network profiles

    private var networkCard: some View {
        card("Network profiles") {
            toggleRow("Switch mode by Wi-Fi network",
                      "Automatically pick a save mode based on the network you join — e.g. hold 80% at home, charge to full on the road.",
                      isOn: Binding(get: { network.enabled },
                                    set: { network.enabled = $0 }))
            if network.enabled {
                divider
                labelRow("Current network", network.currentSSID ?? "Not connected")
                if !network.locationAuthorized {
                    divider
                    infoRow("Allow Location access so Battlify can read the Wi-Fi network name (macOS requires it). Check System Settings › Privacy & Security › Location Services.",
                            systemImage: "location.slash")
                }
                divider
                ForEach(network.profiles) { p in
                    HStack(spacing: 10) {
                        Image(systemName: "wifi").frame(width: 20).foregroundStyle(.tint)
                        Text(p.ssid).font(.callout).lineLimit(1)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { p.mode },
                            set: { m in
                                if let i = network.profiles.firstIndex(where: { $0.id == p.id }) {
                                    network.profiles[i].mode = m
                                }
                            })) {
                            ForEach(SaveMode.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(width: 130)
                        Button {
                            network.removeProfile(p)
                        } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    divider
                }
                HStack {
                    Button {
                        if let ssid = network.currentSSID {
                            network.addProfile(ssid: ssid, mode: chargeLimit.mode)
                        }
                    } label: { Label("Add current network", systemImage: "plus") }
                        .controlSize(.small)
                        .disabled(network.currentSSID == nil)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
    }

    // MARK: - General

    private var generalTab: some View {
        tab {
            helperCard

            card("Menu Bar") {
                pickerRow("Pick how the battery looks in the menu bar. The fill tracks your exact charge.") {
                    BatteryStylePicker(selection: $settings.batteryIconStyle,
                                       percentage: battery.snapshot.percentage)
                }
                divider
                toggleRow("Show battery percentage",
                          "Turn off to show just the icon.",
                          isOn: $settings.showMenuBarPercentage)
                divider
                toggleRow("Color icon by charge state",
                          "Green while charging, red when low or warm. Off keeps it monochrome.",
                          isOn: $settings.colorMenuBarIcon)
                divider
                toggleRow("Animate the icon while charging",
                          "A moving glyph costs about a tenth of a core for as long as you're plugged in, because the menu bar re-lays out on every frame. Off keeps a static charging bolt.",
                          isOn: $settings.animateMenuBarIcon)
            }

            card("Notifications") {
                toggleRow("Notify me about charge events",
                          "Charge limit reached, charging paused for heat, low battery, and fully charged.",
                          isOn: Binding(
                            get: { settings.notificationsEnabled },
                            set: { on in
                                settings.notificationsEnabled = on
                                if on { notifier.enableRequested() }
                            }))
                if settings.notificationsEnabled {
                    divider
                    HStack {
                        Text("Test").font(.callout)
                        Spacer()
                        Button("Send Test Notification") { notifier.sendTest() }
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                }
            }

            card("Startup") {
                toggleRow("Launch at login", isOn: Binding(
                    get: { startup.launchAtLogin },
                    set: { startup.setLaunchAtLogin($0) }))
                if startup.requiresApproval {
                    divider
                    infoRow("Approve Battlify in System Settings › General › Login Items.",
                            systemImage: "exclamationmark.triangle.fill")
                }
            }

            card("System") {
                labelRow("Lid", automation.isLidClosed ? "Closed · clamshell" : "Open")
                if let s = automation.lastLidSession {
                    divider
                    labelRow("Last closed", lastClosedText(s))
                }
            }

            card("Updates") {
                if let update = updater.available {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Update available — v\(update.version)")
                                .font(.callout.weight(.medium))
                            Text("You have v\(updater.currentVersion)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(updater.installing ? "Installing…" : "Update Now") {
                            updater.installUpdate()
                        }
                        .disabled(updater.installing)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                } else {
                    HStack {
                        Button(updater.checking ? "Checking…" : "Check for Updates…") {
                            updater.check(userInitiated: true)
                        }
                        .disabled(updater.checking)
                        Spacer()
                        Text("v\(updater.currentVersion)")
                            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                }
            }
        }
    }

    // MARK: - Layout scaffolding

    private func tab<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) { content() }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func proGate<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 20) { content() }
            .disabled(!license.isPro)
            .opacity(license.isPro ? 1 : 0.45)
    }

    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) { content() }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var divider: some View { Divider().padding(.leading, 12) }

    private func powerToggleCard(_ title: String, category: PowerToggle.Category) -> some View {
        let toggles = PowerToggle.allCases.filter { $0.category == category }
        return card(title) {
            ForEach(Array(toggles.enumerated()), id: \.element) { index, toggle in
                if index > 0 { divider }
                toggleRow(toggle.title, toggle.hint, isOn: Binding(
                    get: { chargeLimit.isPowerToggleOn(toggle) },
                    set: { chargeLimit.setPowerToggle(toggle, $0) }))
            }
        }
    }

    // MARK: - Helper management

    private var helperCard: some View {
        card("Helper") {
            VStack(alignment: .leading, spacing: 10) {
                Label(helperStatus.title, systemImage: helperStatus.icon)
                    .font(.callout)
                    .foregroundStyle(helperStatus.installed ? Color.primary : .secondary)
                Text(helperStatus.detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if HelperInstaller.canInstall {
                    HStack(spacing: 8) {
                        Button(chargeLimit.daemonAvailable ? "Reinstall Helper…" : "Install Helper…") {
                            installHelper()
                        }
                        if chargeLimit.daemonAvailable {
                            Button("Uninstall…", role: .destructive) { uninstallHelper() }
                        }
                    }
                } else {
                    Text("Run scripts/install-helper.sh from the source checkout.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let installError {
                    Text(installError).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true).lineLimit(3)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
    }

    private var helperStatus: (title: String, detail: String, icon: String, installed: Bool) {
        if !chargeLimit.daemonAvailable {
            return ("Not installed",
                    "The root helper enforces the charge limit, heat pause, and sleep settings. Install it once to enable them — it runs at boot on its own.",
                    "exclamationmark.triangle.fill", false)
        }
        if chargeLimit.daemonOutdated {
            return ("Update required",
                    "A newer helper ships with this app. Reinstall it so pause/resume and the latest features work.",
                    "arrow.triangle.2.circlepath", true)
        }
        return ("Installed and running",
                "Enforcing your charge policy in the background. It re-enables charging if ever stopped.",
                "checkmark.circle.fill", true)
    }

    private func installHelper() {
        installError = nil
        let result = HelperInstaller.install()
        if result.ok {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { chargeLimit.refresh() }
        } else {
            installError = result.message
        }
    }

    private func uninstallHelper() {
        installError = nil
        let result = HelperInstaller.uninstall()
        if result.ok {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { chargeLimit.refresh() }
        } else {
            installError = result.message
        }
    }

    // MARK: - Rows

    private func toggleRow(_ title: String, _ subtitle: String? = nil,
                           isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func stepperRow(_ title: String, value: String,
                            binding: Binding<Double>, range: ClosedRange<Double>) -> some View {
        Stepper(value: binding, in: range, step: 1) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(value).font(.callout).fontWeight(.semibold).monospacedDigit()
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var hibernateDelaySummary: String {
        guard chargeLimit.hibernateAfterMinutes > 0 else {
            return "A closed Mac still draws about 130 mW keeping memory alive — roughly 2% overnight. Turn this on and Battlify powers memory down once the lid has been shut that long, so a short close still wakes instantly and a night closed costs nothing."
        }
        return "Shut for this long on battery and memory powers down for the rest of the sleep. Opening the lid restores your Deep sleep setting, so only long closes pay the slower wake."
    }

    /// Applies on release so dragging doesn't spam the daemon.
    private var chargePowerRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Power to the battery").font(.callout)
                Spacer()
                Text(chargeLimit.chargePower == 0 ? "Off" : "\(chargeLimit.chargePower)%")
                    .font(.callout.weight(.semibold)).monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { Double(chargeLimit.chargePower) },
                    set: { chargeLimit.chargePower = Int($0) }
                ),
                in: 0...100, step: 5,
                onEditingChanged: { editing in if !editing { chargeLimit.apply() } }
            )
            .controlSize(.small)

            liveSplitReadout

            Text("How much of the charger's power goes into the battery versus running your Mac. 100% charges at full speed; lower values duty-cycle charging so the battery gets less average power and stays cooler (charging to full takes longer); 0% holds the battery and sends everything to your Mac. The hardware only has an on/off charge switch, so this is an average, not an exact split.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    @ViewBuilder
    private var liveSplitReadout: some View {
        let f = battery.powerFlow
        let cycling = chargeLimit.chargePower > 0 && chargeLimit.chargePower < 100
        if f.isPluggedIn {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 16) {
                    wattStat(.green, cycling ? "Into battery (now)" : "Into battery", f.chargeWatts)
                    wattStat(.orange, "To your Mac", max(0, f.systemWatts ?? 0))
                    Spacer()
                    if let a = f.adapterWatts {
                        Text(String(format: "Adapter %.0f W", a))
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if cycling {
                    Text("At \(chargeLimit.chargePower)% charging runs in long on/off cycles (a couple of minutes each), so this reads full while charging and 0 while resting — averaging about \(chargeLimit.chargePower)% of full power.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.4),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            Text("On battery — plug in the charger to see the live power split.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func wattStat(_ color: Color, _ label: String, _ w: Double) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Text(String(format: "%.1f W", w))
                    .font(.callout.weight(.semibold)).monospacedDigit()
            }
        }
    }

    private func pickerRow<Content: View>(_ hint: String,
                                          @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content()
            Text(hint).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func labelRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium).monospacedDigit()
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func infoRow(_ text: String, systemImage: String) -> some View {
        Label {
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
        } icon: {
            HugeIcon(systemImage, size: 17).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    // MARK: - Helpers

    private func fmtW(_ w: Double?) -> String {
        guard let w else { return "—" }
        return String(format: "%.1f W", w)
    }

    private var nowSuffix: String {
        endurance.liveWatts > 0.1 ? " Now: \(fmtW(endurance.liveWatts))." : ""
    }

    private var keepAwakeProcessText: Binding<String> {
        Binding(
            get: { chargeLimit.keepAwakeProcesses.joined(separator: ", ") },
            set: {
                chargeLimit.keepAwakeProcesses = $0
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                chargeLimit.apply()
            })
    }

    /// Binding that re-applies the policy on change.
    private func bind(_ keyPath: ReferenceWritableKeyPath<ChargeLimitStore, Bool>) -> Binding<Bool> {
        Binding(
            get: { chargeLimit[keyPath: keyPath] },
            set: { chargeLimit[keyPath: keyPath] = $0; chargeLimit.apply() })
    }

    private var magSafeHint: String {
        switch chargeLimit.magSafeLedMode {
        case .system: return "macOS controls the LED."
        case .status: return "Orange charging · green holding limit · off briefly after wake."
        case .off:    return "Keeps the MagSafe LED off."
        }
    }

    private func lastClosedText(_ s: LidSession) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        let ago = f.localizedString(for: s.openedAt, relativeTo: Date())
        let drop = s.dropPercent == 0 ? "no drop" : "−\(s.dropPercent)%"
        return "\(ago) · \(drop)"
    }
}

/// Mirrors the menu-bar rendering so what you pick is what you get.
struct BatteryStylePicker: View {
    @Binding var selection: BatteryIconStyle
    let percentage: Int

    @State private var hovering: BatteryIconStyle?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(BatteryIconStyle.allCases) { style in
                let isSelected = style == selection
                let isHovering = hovering == style
                VStack(spacing: 6) {
                    Image(nsImage: BatteryIconRenderer.image(
                        style: style, percentage: previewPct, charging: false,
                        tint: .neutral, height: 22))
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)
                        .frame(height: 24)
                    Text(style.displayName)
                        .font(.caption2)
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color.accentColor.opacity(0.14)
                              : Color.secondary.opacity(isHovering ? 0.12 : 0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
                )
                .scaleEffect(isSelected ? 1.0 : (isHovering ? 1.04 : 1.0))
                .contentShape(Rectangle())
                .onHover { hovering = $0 ? style : (hovering == style ? nil : hovering) }
                .onTapGesture {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) { selection = style }
                }
                .help("\(style.displayName) battery")
            }
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.spring(response: 0.32, dampingFraction: 0.7), value: selection)
    }

    // Show a representative level so the styles are easy to tell apart even at 0%.
    private var previewPct: Int { max(35, min(100, percentage)) }
}
