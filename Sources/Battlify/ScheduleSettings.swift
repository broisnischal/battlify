import SwiftUI
import BattlifyKit

/// Minute-of-day ⇄ Date helpers so SwiftUI's `DatePicker` (which works in Dates)
/// can edit our stored minutes-from-midnight values.
enum ClockTime {
    static func date(fromMinute minute: Int) -> Date {
        let cal = Calendar.current
        let base = cal.startOfDay(for: Date())
        return cal.date(byAdding: .minute, value: minute, to: base) ?? base
    }
    static func minute(from date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}

/// A compact S–M–T–W–T–F–S selector for a `Weekdays` set.
struct WeekdayPicker: View {
    @Binding var days: Weekdays
    private let bits: [(String, Weekdays)] = [
        ("S", .sun), ("M", .mon), ("T", .tue), ("W", .wed),
        ("T", .thu), ("F", .fri), ("S", .sat),
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(bits.enumerated()), id: \.offset) { _, item in
                let on = days.contains(item.1)
                Button {
                    if on { days.subtract(item.1) } else { days.formUnion(item.1) }
                } label: {
                    Text(item.0)
                        .font(.caption.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .background(on ? Color.accentColor : Color.primary.opacity(0.08),
                                    in: Circle())
                        .foregroundStyle(on ? Color.white : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Modal editor for one recurring charge schedule. Edits a local copy; commits via
/// `onSave` (or discards on Cancel). `onDelete` is nil when adding a new one.
struct ScheduleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ChargeSchedule
    let isNew: Bool
    let onSave: (ChargeSchedule) -> Void
    let onDelete: (() -> Void)?

    init(schedule: ChargeSchedule, isNew: Bool,
         onSave: @escaping (ChargeSchedule) -> Void, onDelete: (() -> Void)?) {
        _draft = State(initialValue: schedule)
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
    }

    private var durationHours: Binding<Double> {
        Binding(get: { Double(draft.durationMinutes) / 60 },
                set: { draft.durationMinutes = max(30, Int(($0 * 60).rounded())) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New Schedule" : "Edit Schedule")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Name").frame(width: 90, alignment: .leading)
                    TextField("e.g. Overnight hold", text: $draft.label)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text("Action").frame(width: 90, alignment: .leading)
                    Picker("", selection: $draft.action) {
                        ForEach(ScheduleAction.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }

                HStack {
                    Text("Starts").frame(width: 90, alignment: .leading)
                    DatePicker("", selection: Binding(
                        get: { ClockTime.date(fromMinute: draft.startMinute) },
                        set: { draft.startMinute = ClockTime.minute(from: $0) }),
                        displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    Spacer()
                }

                HStack {
                    Text("For").frame(width: 90, alignment: .leading)
                    Stepper(value: durationHours, in: 0.5...24, step: 0.5) {
                        Text(durationText).monospacedDigit()
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Repeat").frame(width: 90, alignment: .leading)
                    WeekdayPicker(days: $draft.days)
                    HStack(spacing: 8) {
                        quickDays("Every day", .everyday)
                        quickDays("Weekdays", .weekdays)
                        quickDays("Weekends", .weekends)
                    }
                }

                Text("Window: \(draft.windowLabel()) · \(draft.days.summary)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                if let onDelete {
                    Button(role: .destructive) { onDelete(); dismiss() } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    if draft.label.trimmingCharacters(in: .whitespaces).isEmpty {
                        draft.label = draft.action.title
                    }
                    onSave(draft); dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.days.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var durationText: String {
        let h = draft.durationMinutes / 60, m = draft.durationMinutes % 60
        if m == 0 { return "\(h) h" }
        if h == 0 { return "\(m) min" }
        return "\(h) h \(m) min"
    }

    private func quickDays(_ title: String, _ set: Weekdays) -> some View {
        Button(title) { draft.days = set }
            .controlSize(.small)
            .buttonStyle(.bordered)
    }
}
