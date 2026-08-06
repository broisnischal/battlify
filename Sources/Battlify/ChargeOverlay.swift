import SwiftUI
import AppKit
import BattlifyKit

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
        case .dotGrid: return "A dot matrix fills to your charge level, with one rise up to the line."
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

    /// Dot-matrix charge meter, in the spirit of Nothing's charging visual.
    ///
    /// The previous version launched three fronts diagonally out of the port, one after
    /// another, which read as something swinging out and back — a boomerang, not charging.
    /// Three things fix that:
    ///
    ///   - The whole matrix is faintly lit the entire time. Before, only the moving band
    ///     was drawn, so there was no grid to move *through* — just a stripe crossing the
    ///     screen, which is what made the motion the subject instead of the charge.
    ///   - Dots below your actual charge level are lit. The animation now says how full
    ///     the battery is, which is the one thing a charging animation should say.
    ///   - One rise, bottom to the fill line, and done. Charging goes up. Anything that
    ///     repeats or reverses reads as a loading spinner.
    private func drawDotGrid(_ gc: GraphicsContext, size: CGSize, t: Double) {
        let spacing: CGFloat = 16
        let radius: CGFloat = 1.1
        let level = CGFloat(max(0, min(100, percentage))) / 100
        // Canvas y grows downward, so the fill line sits `level` up from the bottom.
        let fillLine = size.height * (1 - level)

        // The highlight rises from the bottom edge to the fill line over the first part of
        // the animation, eased so it leaves fast and settles — then holds while the
        // envelope fades everything out.
        let rise = CGFloat(Easing.outStrong(min(1, t / 0.62)))
        let sweepY = size.height - rise * (size.height - fillLine)
        let falloff: CGFloat = 46          // how far the highlight reaches, in points

        let buckets = 6
        var paths = [Path](repeating: Path(), count: buckets)
        var rows = 0
        var y: CGFloat = spacing / 2
        while y < size.height {
            var x: CGFloat = spacing / 2
            var col = 0
            while x < size.width {
                // Faint matrix everywhere, brighter below the charge line.
                // Wider gap between filled and empty than looks right in isolation: over a
                // busy desktop the two regions have to be told apart at a glance.
                var alpha: CGFloat = y >= fillLine ? 0.5 : 0.06
                var grow: CGFloat = 0

                let distance = abs(y - sweepY)
                if distance < falloff {
                    let amp = cos(distance / falloff * .pi / 2)   // 1 at the line, 0 at the edge
                    alpha += 0.5 * amp
                    grow = amp * 1.5
                }
                guard alpha > 0.05 else { x += spacing; col += 1; continue }

                // A touch of jitter, only for dots the highlight is passing through: the
                // "vibrating" quality, without shaking the static matrix.
                var offset: CGFloat = 0
                if grow > 0.05 {
                    let seed = sin(Double(col) * 12.9898 + Double(rows) * 78.233) * 43758.5453
                    offset = CGFloat((seed - seed.rounded(.down)) * 2 - 1) * grow * 1.1
                }
                let r = radius + grow
                paths[min(buckets - 1, Int(min(1, alpha) * CGFloat(buckets)))]
                    .addEllipse(in: CGRect(x: x + offset - r, y: y - r, width: r * 2, height: r * 2))
                x += spacing
                col += 1
            }
            y += spacing
            rows += 1
        }

        for (index, path) in paths.enumerated() where !path.isEmpty {
            let alpha = (CGFloat(index) + 0.5) / CGFloat(buckets)
            gc.fill(path, with: .color(tint.opacity(Double(alpha))))
        }

        // The level, in the same monochrome register as the matrix, once the rise is done.
        guard plugging else { return }
        let appear = max(0, min(1, (t - 0.34) / 0.24))
        var text = gc
        text.opacity = Double(appear)
        text.translateBy(x: size.width / 2, y: size.height / 2)
        text.draw(Text("\(percentage)%")
                    .font(.system(size: 74, weight: .medium, design: .monospaced))
                    .foregroundStyle(tint),
                  at: .zero)
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
