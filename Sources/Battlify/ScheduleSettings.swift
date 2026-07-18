import SwiftUI
import BattlifyKit

/// Minute-of-day ⇄ Date helpers so `DatePicker` can edit our stored
/// minutes-from-midnight values.
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

struct WeekdayPicker: View {
    @Binding var days: Weekdays
    private let bits: [(String, Weekdays)] = [
        ("S", .sun), ("M", .mon), ("T", .tue), ("W", .wed),
        ("T", .thu), ("F", .fri), ("S", .sat),
    ]

    var body: some View {
        HStack(spacing: 7) {
            ForEach(Array(bits.enumerated()), id: \.offset) { _, item in
                let on = days.contains(item.1)
                Button {
                    if on { days.subtract(item.1) } else { days.formUnion(item.1) }
                } label: {
                    Text(item.0)
                        .font(.caption.weight(.bold))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(on ? Color.accentColor
                                                     : Color.secondary.opacity(0.15)))
                        .overlay(Circle().strokeBorder(
                            on ? Color.clear : Color.secondary.opacity(0.3), lineWidth: 1))
                        .foregroundStyle(on ? Color.white : Color.primary.opacity(0.7))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Modal editor for one charge schedule. Edits a local copy, committed via
/// `onSave`; `onDelete` is nil when adding.
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
                row("Name") {
                    TextField("e.g. Overnight hold", text: $draft.label)
                        .textFieldStyle(.roundedBorder)
                }

                row("Action") {
                    Picker("", selection: $draft.action) {
                        ForEach(ScheduleAction.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }

                row("Starts") {
                    DatePicker("", selection: Binding(
                        get: { ClockTime.date(fromMinute: draft.startMinute) },
                        set: { draft.startMinute = ClockTime.minute(from: $0) }),
                        displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    Spacer()
                }

                row("For") {
                    Stepper(value: durationHours, in: 0.5...24, step: 0.5) {
                        Text(durationText).monospacedDigit()
                    }
                    .fixedSize()
                    Spacer()
                }

                row("Repeat", alignment: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        WeekdayPicker(days: $draft.days)
                        HStack(spacing: 8) {
                            quickDays("Every day", .everyday)
                            quickDays("Weekdays", .weekdays)
                            quickDays("Weekends", .weekends)
                        }
                    }
                }

                row("") {
                    Text("Window: \(draft.windowLabel()) · \(draft.days.summary)")
                        .font(.caption).foregroundStyle(.secondary)
                }
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

    /// Label in a fixed left column so every field's control lines up in the
    /// same value column.
    @ViewBuilder
    private func row<Content: View>(_ label: String,
                                    alignment: VerticalAlignment = .center,
                                    @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: alignment, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            content()
        }
    }
    private let labelWidth: CGFloat = 72

    private func quickDays(_ title: String, _ set: Weekdays) -> some View {
        let active = draft.days == set
        return Button(title) { draft.days = set }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .tint(active ? Color.accentColor : Color.secondary)
    }
}
