import SwiftUI
import BattlifyKit

/// The closed-lid panel: one switch, an honest checklist of what's still costing power,
/// and the measured result of the last time the lid was shut.
///
/// The checklist is the point. A switch on its own asks to be trusted; a switch next to a
/// list of nine named causes, each either struck through or still standing, can be checked.
/// It's also the only way to be straight about the two things Battlify can't decide for
/// you — Find My reachability, and a keep-awake you deliberately turned on.
struct SealedSleepPanel: View {
    @ObservedObject var chargeLimit: ChargeLimitStore
    @ObservedObject var automation: AutomationStore

    /// Compact form, for the menu: the verdict, what it measured, and only the causes
    /// still costing something.
    ///
    /// Settings shows all nine whether or not they're leaking, because there the list is
    /// the explanation. In the menu the same list would be nine rows of green ticks
    /// restating a sentence directly above them, in a popover that has four other sections
    /// to fit — so here it shrinks to what's still wrong, and to nothing when the answer
    /// is nothing.
    var compact = false

    private var state: SleepState { automation.sleepState(with: chargeLimit) }
    private var result: SealedSleepResult? {
        automation.lastLidSession.flatMap(SealedSleepResult.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? DS.Space.s : DS.Space.m) {
            header
            if !compact {
                Text(explanation).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !chargeLimit.sealedSleepRefused.isEmpty { refusedNotice }
            if chargeLimit.sealedSleep { wakeSpeedRow }
            checklist
            if let result { measured(result) }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            VStack(alignment: .leading, spacing: 1) {
                // Plain `.callout`, matching every other row title in the panel. It was
                // `.medium`, which made this one row read as a heading among peers.
                Text("Sealed Sleep").font(.body)
                if !verdict.isEmpty {
                    Text(verdict)
                        .font(.caption2)
                        .foregroundStyle(state.isSealed && chargeLimit.sealedSleep ? DS.Status.good : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Space.s)
            // The setter is spelled out rather than passed as `set: setSealed`. A bare
            // method reference here makes the compiler build a reabstraction thunk across
            // the main-actor boundary, and Swift 6.3's IRGen crashes on it.
            Toggle("Sealed Sleep", isOn: Binding(get: { chargeLimit.sealedSleep },
                                                 set: { setSealed($0) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .disabled(!chargeLimit.daemonAvailable)
        }
    }

    /// One line, and it has to be true. "Sealed" is claimed only when the switch is on
    /// *and* nothing in the audit is still leaking — a toggle that reads "on" over a Mac
    /// that is still waking hourly is the failure this whole panel exists to prevent.
    /// Short enough to hold one line at the panel's width. The long form said the same
    /// thing over two, and a verdict that wraps stops reading as a verdict.
    private var verdict: String {
        guard chargeLimit.daemonAvailable else { return "Helper not installed" }
        guard chargeLimit.sealedSleep else { return "Ordinary macOS sleep" }
        let remaining = state.leaks.count
        // Nothing to say in the menu when it is simply working: the switch reads on, the
        // row is titled Sealed Sleep, and a line under it repeating that in other words is
        // the panel talking to itself. The leak counts stay, because those are news.
        if remaining == 0 { return compact ? "" : "Nothing can wake it" }
        return remaining == 1 ? "1 leak left" : "\(remaining) leaks left"
    }

    /// The one trade this feature asks the user to make, put where they can act on it.
    ///
    /// It sits under the main switch rather than in Settings because it is the thing people
    /// come back to change: they turn Sealed Sleep on, shut the lid, open it thirty seconds
    /// later and want to know what happened. Answering that in a tooltip on another screen
    /// is how a feature gets switched off instead of adjusted.
    private var wakeSpeedRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Text("Wake instantly").font(.body)
                Spacer(minLength: DS.Space.s)
                Toggle("Wake instantly",
                       isOn: Binding(get: { chargeLimit.sealedSleepFastWake },
                                     set: { chargeLimit.setSealedSleepFastWake($0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            // Only the state that costs something to be in gets a caption. Instant wake is
            // the default and the label says what it does; spelling out that memory stays
            // powered is a line the menu spends to tell you nothing has changed.
            if !chargeLimit.sealedSleepFastWake {
                Text("Opening the lid takes 15 to 30 seconds.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if chargeLimit.sealedSleepFastWake && !compact { hibernateAfterRow }
        }
    }

    /// How long instant wake lasts before the close is treated as a long one.
    ///
    /// Settings only. It is the answer to "why did a 20-minute close open instantly and an
    /// overnight one take half a minute", and that question doesn't come up often enough to
    /// spend a row of the menu on. See `DeferredHibernate` for what it drives.
    private var hibernateAfterRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Then hibernate after").font(.callout)
                Text("Memory powers down once the lid has been shut this long, so a long close costs nothing.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Space.s)
            Picker("", selection: Binding(
                get: { chargeLimit.sealedSleepHibernateAfter },
                set: { chargeLimit.sealedSleepHibernateAfter = $0; chargeLimit.apply() }
            )) {
                Text("Never").tag(0)
                Text("5 min").tag(5)
                Text("20 min").tag(20)
                Text("1 hour").tag(60)
                Text("3 hours").tag(180)
            }
            .labelsHidden().fixedSize()
        }
    }

    private var explanation: String {
        "A closed Mac isn't off. macOS keeps waking it on a timer for maintenance, the "
        + "network and Find My. Sealed Sleep switches all of that off, so nothing brings it "
        + "up until you open the lid. Find My can't reach it while it's shut."
    }

    private var refusedNotice: some View {
        Label {
            Text("This Mac refused: \(chargeLimit.sealedSleepRefused.joined(separator: ", ")). "
                 + "Those settings are unchanged; everything else applied.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
        } icon: {
            HugeIcon("alert", size: DS.Icon.caption).foregroundStyle(DS.Status.attention)
        }
    }

    // MARK: - Checklist

    /// Every cause, sealed ones included, so the list doesn't shrink as things are fixed.
    ///
    /// A checklist that removes its finished items tells you what's wrong and hides what
    /// it did for you; keeping them makes the switch's effect visible in one glance, which
    /// is the difference between a claim and a receipt.
    /// No surface, in either place.
    ///
    /// The popover is already a rounded, bordered, shadowed panel, so a box inside it
    /// draws a second border a few points in from the first and the eye reads the nesting
    /// before the content. Settings no longer boxes its groups at all — see `card` there —
    /// so a box here would be the only one on the page. Both arguments land in the same
    /// place: a label, rows, and space.
    @ViewBuilder
    private var checklist: some View {
        let leaking = Set(state.leaks)
        let shown = compact
            ? state.leaks
            : SleepLeak.allCases.sorted { $0.weight < $1.weight }
        if !shown.isEmpty {
            VStack(spacing: compact ? DS.Space.s : 0) {
                ForEach(Array(shown.enumerated()), id: \.element) { index, leak in
                    if index > 0 && !compact { DSSeparator(inset: 0) }
                    row(leak, leaking: leaking.contains(leak))
                }
            }
        }
    }

    private func row(_ leak: SleepLeak, leaking: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            HugeIcon(leaking ? leak.icon : "check", size: DS.Icon.caption)
                .foregroundStyle(leaking ? (leak.isAutomatic ? Color.secondary : DS.Status.attention) : DS.Status.good)
                .frame(width: DS.Icon.row, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(leak.title)
                    .font(.caption)
                    .foregroundStyle(leaking ? Color.primary : .secondary)
                    .strikethrough(!leaking, color: .secondary)
                if leaking && !compact {
                    Text(leak.cost).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Space.s)
            if leaking && !leak.isAutomatic { manualFix(leak) }
        }
        .padding(.vertical, compact ? 0 : DS.Space.s - 2)
    }

    /// The one leak with no automatic answer gets its own button, because the fix is a
    /// decision rather than a setting: turning off keep-awake-on-battery is switching off
    /// something the user asked for.
    @ViewBuilder
    private func manualFix(_ leak: SleepLeak) -> some View {
        if leak == .keptAwakeOnBattery {
            Button("Release") {
                chargeLimit.keepAwakeOnBattery = false
                chargeLimit.apply()
            }
            .buttonStyle(.link).font(.caption)
        }
    }

    // MARK: - Measured result

    /// What the last closed-lid stretch actually cost. No projection, no estimate — the
    /// charge was read when the lid shut and again when it opened.
    private func measured(_ result: SealedSleepResult) -> some View {
        Label {
            Text(measuredText(result)).font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            HugeIcon(result.isEssentiallyZero ? "check" : "chart", size: DS.Icon.caption)
                .foregroundStyle(result.isEssentiallyZero ? DS.Status.good : .secondary)
        }
    }

    /// One line, telegraphic: "Last close: 34h shut · 0% lost".
    ///
    /// It was a sentence, and at this width a sentence is two lines — which put more panel
    /// behind the receipt than behind the switch it vouches for.
    private func measuredText(_ result: SealedSleepResult) -> String {
        let hours = result.session.duration / 3600
        let span = hours >= 1
            ? String(format: "%.0fh", hours)
            : String(format: "%.0fm", result.session.duration / 60)
        let lost = result.isEssentiallyZero
            ? "0% lost"
            : String(format: "%d%% lost · %.1f%%/h", result.session.dropPercent, result.perHour)
        return "Last close: \(span) shut · \(lost)"
    }

    // MARK: - Actions

    /// The switch owns both halves: the daemon's `pmset` settings and the app's radio
    /// preferences. Splitting them across two controls was the old design, and it let a
    /// Mac sit in a state where half the feature was on.
    private func setSealed(_ on: Bool) {
        chargeLimit.setSealedSleep(on)
        automation.setSealed(on)
    }
}

/// Which icon stands for each cause. Kept here rather than on `SleepLeak` — the model
/// lives in BattlifyKit, which has no business knowing what this app draws with.
private extension SleepLeak {
    var icon: String {
        switch self {
        case .memoryStaysPowered: return "cpu"
        case .standbyDisabled:    return "moon"
        case .powerNap:           return "refresh"
        case .wakeForNetwork:     return "globe"
        case .networkInSleep:     return "wifi"
        case .terminalSessions:   return "code"
        case .wifiLeftOn:         return "wifi"
        case .bluetoothLeftOn:    return "bluetooth"
        case .keptAwakeOnBattery: return "coffee"
        }
    }
}

extension AutomationStore {
    /// Assemble the audit from both halves of the app: the daemon reports what `pmset`
    /// says, and this store owns the radio preferences.
    func sleepState(with chargeLimit: ChargeLimitStore) -> SleepState {
        SleepState(
            hibernateMode: chargeLimit.hibernateMode,
            standby: chargeLimit.standbyEnabled,
            powerNap: chargeLimit.powerToggleState(.powerNap),
            wakeForNetwork: chargeLimit.powerToggleState(.wakeOnNetwork),
            networkInSleep: chargeLimit.powerToggleState(.tcpKeepAlive),
            terminalSessionsKeepAwake: chargeLimit.powerToggleState(.ttysKeepAwake),
            wifiOffOnLidClose: wifiOffOnLidClose,
            bluetoothOffOnLidClose: bluetoothOffOnLidClose,
            keepAwakeOnBattery: chargeLimit.keepAwake && chargeLimit.keepAwakeOnBattery,
            fastWake: chargeLimit.sealedSleepFastWake)
    }
}
