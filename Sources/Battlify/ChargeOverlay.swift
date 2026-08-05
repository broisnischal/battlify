import SwiftUI
import AppKit

/// Which animation the screen flashes when you plug in.
enum ChargeOverlayStyle: String, CaseIterable, Identifiable, Codable {
    /// A grid of dots that ripples out from the charge port, each dot jittering as the
    /// wave passes through it.
    case dotGrid
    /// Rings pushing out from the port with the charge level in the middle — the phone
    /// charging animation everybody recognises.
    case ring
    /// A soft glow rising off the bottom edge. The quiet one.
    case aurora
    /// Whatever image sequence you've dropped in the frames folder — a Rive, Lottie or
    /// After Effects export, played back frame by frame.
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dotGrid: return "Dot Grid"
        case .ring:    return "Rings"
        case .aurora:  return "Glow"
        case .custom:  return "Custom"
        }
    }

    var summary: String {
        switch self {
        case .dotGrid: return "A grid of dots ripples out from the port, jittering as the wave passes."
        case .ring:    return "Rings push out from the port with the charge level in the middle."
        case .aurora:  return "A soft glow rises off the bottom edge and fades."
        case .custom:  return "Plays your own frames — export a numbered image sequence from Rive, Lottie or After Effects and drop it in the folder."
        }
    }
}

/// Shows the plug-in animation: a borderless, click-through window over everything for
/// up to a couple of seconds, then gone.
///
/// Deliberately cheap. It exists for about a second, draws on the screen the pointer is
/// on rather than all of them, and the window is torn down afterwards rather than kept
/// around — a battery app has no business holding a full-screen layer open.
@MainActor
final class ChargeOverlayController: ObservableObject {
    private var window: NSWindow?
    private var dismissal: Task<Void, Never>?

    /// `plugging` false runs the unplug variant (cooler colour, no level).
    /// `allowMotion` false draws the still variant — the caller owns that decision, so
    /// the system's Reduce Motion setting and the user's override for this app are
    /// resolved in one place rather than read again down here.
    func show(style: ChargeOverlayStyle, duration: Double, percentage: Int,
              plugging: Bool = true, allowMotion: Bool = true) {
        dismissal?.cancel()
        teardown()

        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        guard let frame = screen?.frame else { return }

        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        // Above full-screen apps, like a system HUD, but never taking focus or clicks:
        // this fires while the user is working and must not interrupt anything.
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle,
                                    .fullScreenAuxiliary]
        panel.contentView = NSHostingView(
            rootView: ChargeOverlayView(style: style, duration: duration,
                                        percentage: percentage, plugging: plugging,
                                        allowMotion: allowMotion, start: Date()))
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        window = panel

        // A little past the animation's own end, so the fade-out finishes on screen.
        dismissal = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((duration + 0.15) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.teardown()
        }
    }

    private func teardown() {
        window?.orderOut(nil)
        window = nil
    }
}

/// One shot of the animation, driven by wall-clock time rather than a stored frame
/// counter so it plays at the same speed whatever the display refresh rate.
private struct ChargeOverlayView: View {
    let style: ChargeOverlayStyle
    let duration: Double
    let percentage: Int
    let plugging: Bool
    let allowMotion: Bool
    let start: Date

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(start)
            let t = max(0, min(1, elapsed / duration))
            Canvas { gc, size in
                if !allowMotion {
                    drawStill(gc, size: size, t: t)
                } else {
                    switch style {
                    case .dotGrid: drawDotGrid(gc, size: size, t: t)
                    case .ring:    drawRings(gc, size: size, t: t)
                    case .aurora:  drawAurora(gc, size: size, t: t)
                    case .custom:  drawCustom(gc, size: size, t: t)
                    }
                }
            }
            .opacity(envelope(t))
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    /// In fast, out slower: arriving deserves the attention, leaving shouldn't ask for any.
    private func envelope(_ t: Double) -> Double {
        if t < 0.12 { return t / 0.12 }
        if t > 0.62 { return max(0, 1 - (t - 0.62) / 0.38) }
        return 1
    }

    private var tint: Color {
        plugging ? Color(red: 0.30, green: 0.85, blue: 0.44) : Color(white: 0.75)
    }

    /// Where the energy comes from: the port side of a MacBook, low and to the left,
    /// so the wave looks like it enters the machine rather than appearing in mid-air.
    private func origin(_ size: CGSize) -> CGPoint {
        CGPoint(x: size.width * 0.12, y: size.height * 0.94)
    }

    // MARK: - Styles

    private func drawDotGrid(_ gc: GraphicsContext, size: CGSize, t: Double) {
        let spacing: CGFloat = 26
        let from = origin(size)
        let maxDistance = hypot(size.width, size.height)
        let cols = Int(size.width / spacing) + 1
        let rows = Int(size.height / spacing) + 1

        for row in 0...rows {
            for col in 0...cols {
                let base = CGPoint(x: CGFloat(col) * spacing, y: CGFloat(row) * spacing)
                let d = hypot(base.x - from.x, base.y - from.y) / maxDistance
                // One wave front travelling out. Dots ahead of it and well behind it
                // stay dark, so the grid reads as a pulse crossing the screen.
                // A narrow band, not a slow gradient: at 0.6 the lit window covered most
                // of the screen at once and read as "dots everywhere" rather than a wave
                // crossing it. 0.3 keeps a recognisable front with a short tail.
                let phase = t * 2.3 - d * 1.5
                guard phase > 0, phase < 0.3 else { continue }
                let amp = sin(phase / 0.3 * .pi)
                guard amp > 0.01 else { continue }

                // Deterministic per-dot jitter — the "vibrating" part. Hashing the grid
                // position keeps each dot's shake stable frame to frame instead of
                // turning the whole grid into noise.
                let seed = sin(Double(col) * 12.9898 + Double(row) * 78.233) * 43758.5453
                let jitter = (seed - seed.rounded(.down)) * 2 - 1
                let shake = CGFloat(jitter * amp * 2.2)
                let r = 1.3 + CGFloat(amp) * 2.6
                let rect = CGRect(x: base.x + shake - r, y: base.y + shake * 0.6 - r,
                                  width: r * 2, height: r * 2)
                gc.fill(Path(ellipseIn: rect), with: .color(tint.opacity(0.14 + amp * 0.7)))
            }
        }
    }

    private func drawRings(_ gc: GraphicsContext, size: CGSize, t: Double) {
        let from = origin(size)
        let maxR = hypot(size.width, size.height) * 0.75
        for k in 0..<3 {
            let offset = Double(k) * 0.17
            let p = t * 1.5 - offset
            guard p > 0, p < 1 else { continue }
            let r = CGFloat(p) * maxR
            let rect = CGRect(x: from.x - r, y: from.y - r, width: r * 2, height: r * 2)
            gc.stroke(Path(ellipseIn: rect),
                      with: .color(tint.opacity((1 - p) * 0.55)),
                      lineWidth: 2.5 + CGFloat(1 - p) * 3)
        }
        guard plugging else { return }
        // Level, once the first ring has had time to travel.
        let textAppear = max(0, min(1, (t - 0.12) / 0.25))
        let scale = 0.86 + 0.14 * textAppear
        var text = gc
        text.translateBy(x: size.width / 2, y: size.height / 2)
        text.scaleBy(x: scale, y: scale)
        text.opacity = textAppear * (t > 0.7 ? max(0, 1 - (t - 0.7) / 0.3) : 1)
        text.draw(Text("\(percentage)%")
                    .font(.system(size: 96, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint),
                  at: .zero)
    }

    private func drawAurora(_ gc: GraphicsContext, size: CGSize, t: Double) {
        let height = size.height * (0.18 + 0.22 * sin(t * .pi))
        let rect = CGRect(x: 0, y: size.height - height, width: size.width, height: height)
        gc.fill(Path(rect),
                with: .linearGradient(
                    Gradient(colors: [tint.opacity(0), tint.opacity(0.42)]),
                    startPoint: CGPoint(x: 0, y: rect.minY),
                    endPoint: CGPoint(x: 0, y: rect.maxY)))
    }

    /// A frame from the user's own sequence, scaled to fit and centred so a square export
    /// isn't stretched across a 16:10 display. With no frames to play it falls back to the
    /// dot grid rather than flashing an empty screen at you.
    private func drawCustom(_ gc: GraphicsContext, size: CGSize, t: Double) {
        guard let frame = ChargeFrameSequence.frame(at: t) else {
            drawDotGrid(gc, size: size, t: t)
            return
        }
        let source = frame.size
        guard source.width > 0, source.height > 0 else { return }
        let scale = min(size.width / source.width, size.height / source.height)
        let drawn = CGSize(width: source.width * scale, height: source.height * scale)
        let rect = CGRect(x: (size.width - drawn.width) / 2,
                          y: (size.height - drawn.height) / 2,
                          width: drawn.width, height: drawn.height)
        gc.draw(Image(nsImage: frame), in: rect)
    }

    /// Reduce Motion: the same information, no travel — just the level fading in place.
    private func drawStill(_ gc: GraphicsContext, size: CGSize, t: Double) {
        var text = gc
        text.translateBy(x: size.width / 2, y: size.height / 2)
        text.draw(Text(plugging ? "\(percentage)%" : "Unplugged")
                    .font(.system(size: 72, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint),
                  at: .zero)
    }
}
