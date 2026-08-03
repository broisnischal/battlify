import SwiftUI
import AppKit

/// The brief overlay a global shortcut shows so it's obvious it fired.
///
/// Without this a shortcut for something invisible — Low Power Mode, force discharge —
/// is indistinguishable from a shortcut that isn't registered at all. Modelled on the
/// system volume HUD: bottom-centre, non-interactive, gone in about a second.
@MainActor
final class HotkeyHUD {
    static let shared = HotkeyHUD()

    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?
    private let visibleFor: TimeInterval = 1.1

    private init() {}

    func show(_ title: String, detail: String? = nil, icon: String) {
        dismissal?.cancel()

        let panel = self.panel ?? makePanel()
        self.panel = panel

        // Rebuild the content each time: the HUD is transient, and swapping the
        // hosting view is cheaper than keeping an observable model alive for it.
        let host = NSHostingView(rootView: HotkeyHUDView(title: title, detail: detail, icon: icon))
        host.layoutSubtreeIfNeeded()
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        position(panel)

        panel.alphaValue = 1
        panel.orderFrontRegardless()

        dismissal = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.visibleFor ?? 1.1) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.fadeOut()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // Never take focus or steal a click — the user is in another app when this fires.
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle,
                                    .fullScreenAuxiliary]
        return panel
    }

    /// Bottom-centre of whichever screen has the mouse, matching the system HUDs.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                     y: frame.minY + 120))
    }

    private func fadeOut() {
        guard let panel else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        }
    }
}

private struct HotkeyHUDView: View {
    let title: String
    let detail: String?
    let icon: String

    var body: some View {
        HStack(spacing: 10) {
            HugeIcon(icon, size: 20, weight: 2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minWidth: 180, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }
}
