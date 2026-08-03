import SwiftUI
import AppKit
import Carbon.HIToolbox
import BattlifyKit

extension HotkeyModifiers {
    /// Only the four modifiers a shortcut can use. `.function` and `.numericPad`
    /// arrive set for arrow and keypad keys and must be dropped, or ⌃⌥⌘↑ would
    /// register with flags Carbon doesn't recognise and never fire.
    init(_ flags: NSEvent.ModifierFlags) {
        var m: HotkeyModifiers = []
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option)  { m.insert(.option) }
        if flags.contains(.shift)   { m.insert(.shift) }
        if flags.contains(.command) { m.insert(.command) }
        self = m
    }
}

/// The click-to-record shortcut field used by each row in the Shortcuts tab.
///
/// Which row is recording is owned by the parent, so starting a new recording ends
/// any other — two fields can't both hold first responder.
struct HotkeyRecorderField: View {
    let hotkey: Hotkey?
    let isRecording: Bool
    /// True when another app owns this combination, so it can't be registered.
    let unavailable: Bool
    let onBegin: () -> Void
    let onCapture: (Hotkey) -> Void
    let onCancel: () -> Void
    let onClear: () -> Void

    /// Set when the user types something without ⌃/⌥/⌘, which we won't accept.
    @State private var needsModifier = false

    var body: some View {
        HStack(spacing: 6) {
            if needsModifier {
                Text("Add ⌃, ⌥ or ⌘")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if unavailable, !isRecording {
                Text("In use by another app")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Button {
                needsModifier = false
                isRecording ? onCancel() : onBegin()
            } label: {
                Text(label)
                    .font(.callout.weight(hotkey == nil ? .regular : .medium))
                    .monospaced()
                    .foregroundStyle(foreground)
                    .frame(minWidth: 96)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(isRecording ? Color.accentColor : .clear, lineWidth: 1.5)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isRecording ? "Type the shortcut, or press ⎋ to cancel"
                              : "Click to set a shortcut")

            // Only offered when there's something to remove, so the row doesn't carry
            // a permanently dead button.
            Button(action: { needsModifier = false; onClear() }) {
                HugeIcon("cancel", size: 12)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove this shortcut")
            .opacity(hotkey != nil && !isRecording ? 1 : 0)
            .disabled(hotkey == nil || isRecording)
        }
        // Zero-sized and non-interactive: it exists only to hold first responder
        // while recording, and is torn down the moment recording ends.
        .overlay(alignment: .trailing) {
            if isRecording {
                KeyCatcher(
                    onCapture: { candidate in
                        guard candidate.isValid else {
                            needsModifier = true
                            NSSound.beep()
                            return
                        }
                        needsModifier = false
                        onCapture(candidate)
                    },
                    onClear: { needsModifier = false; onClear() },
                    onCancel: { needsModifier = false; onCancel() })
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }
        }
        .onChange(of: isRecording) { _, recording in
            if !recording { needsModifier = false }
        }
    }

    private var label: String {
        if isRecording { return "Type…" }
        return hotkey?.displayString ?? "Not set"
    }

    private var foreground: Color {
        if isRecording { return .primary }
        return hotkey == nil ? .secondary : .primary
    }

    private var background: AnyShapeStyle {
        if isRecording { return AnyShapeStyle(Color.accentColor.opacity(0.12)) }
        return AnyShapeStyle(.quaternary.opacity(0.6))
    }
}

// MARK: - Key capture

private struct KeyCatcher: NSViewRepresentable {
    let onCapture: (Hotkey) -> Void
    let onClear: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> KeyCatcherView {
        let view = KeyCatcherView()
        view.onCapture = onCapture
        view.onClear = onClear
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ view: KeyCatcherView, context: Context) {
        view.onCapture = onCapture
        view.onClear = onClear
        view.onCancel = onCancel
    }
}

/// Takes first responder and swallows one keystroke.
final class KeyCatcherView: NSView {
    var onCapture: ((Hotkey) -> Void)?
    var onClear: (() -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if !handle(event) { super.keyDown(with: event) }
    }

    /// Combinations including ⌘ are offered as key equivalents before `keyDown`, and
    /// would otherwise be eaten by the main menu (⌘W closing the window, say).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handle(event)
    }

    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = HotkeyModifiers(event.modifierFlags.intersection(.deviceIndependentFlagsMask))

        // Bare ⎋ cancels and bare ⌫ clears — both are more useful as recorder controls
        // than as bindings. With modifiers held they're recordable like any other key.
        if modifiers.isEmpty {
            switch Int(event.keyCode) {
            case kVK_Escape:
                onCancel?()
                return true
            case kVK_Delete, kVK_ForwardDelete:
                onClear?()
                return true
            default:
                break
            }
        }

        onCapture?(Hotkey(keyCode: UInt32(event.keyCode), modifiers: modifiers))
        return true
    }
}
