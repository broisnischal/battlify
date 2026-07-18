import SwiftUI

/// A transparent flame + rising-embers charging animation that overlays the screen
/// (the desktop stays visible — no dark takeover). Pure SwiftUI Canvas, additive glow.
struct ChargingAnimationView: View {
    let percentage: Int

    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in draw(ctx, size, tl.date.timeIntervalSinceReferenceDate) }
        }
        .ignoresSafeArea()
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double) {
        let cx = size.width / 2
        let baseY = size.height
        let flameH = size.height * 0.5
        let flameW = min(size.width * 0.42, 520)

        // warm base glow
        let gR = flameW * 1.5
        ctx.fill(
            Path(ellipseIn: CGRect(x: cx - gR, y: baseY - flameH - gR * 0.4, width: gR * 2, height: gR * 1.6)),
            with: .radialGradient(
                Gradient(colors: [Color(red: 1, green: 0.42, blue: 0.06).opacity(0.45), .clear]),
                center: CGPoint(x: cx, y: baseY - flameH * 0.12), startRadius: 0, endRadius: gR))

        var g = ctx
        g.blendMode = .plusLighter

        // layered flame tongues: deep-orange → yellow → white core
        let layers: [(w: Double, h: Double, c: Color, phase: Double, a: Double)] = [
            (1.00, 1.00, Color(red: 0.95, green: 0.24, blue: 0.02), 0.0, 0.50),
            (0.72, 0.93, Color(red: 1.00, green: 0.55, blue: 0.05), 1.3, 0.65),
            (0.46, 0.82, Color(red: 1.00, green: 0.84, blue: 0.34), 2.6, 0.80),
            (0.24, 0.64, Color(red: 1.00, green: 0.97, blue: 0.82), 3.9, 0.90),
        ]
        for l in layers {
            let flick = 1 + 0.10 * sin(t * 7 + l.phase) + 0.06 * sin(t * 13 + l.phase * 2)
            let sway = sin(t * 2.2 + l.phase) * flameW * l.w * 0.10
            let h = flameH * l.h * flick
            let p = flame(cx: cx + sway, baseY: baseY + 2, w: flameW * l.w, h: h, t: t, seed: l.phase)
            g.fill(p, with: .linearGradient(
                Gradient(colors: [l.c.opacity(l.a), l.c.opacity(l.a * 0.85), .clear]),
                startPoint: CGPoint(x: cx, y: baseY), endPoint: CGPoint(x: cx, y: baseY - h)))
        }

        embers(g, cx: cx, baseY: baseY, w: flameW, h: flameH * 1.35, t: t)

        let label = Text("\(percentage)%  ·  Charging")
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .foregroundColor(.white.opacity(0.85))
        ctx.draw(label, at: CGPoint(x: cx, y: size.height - 48))
    }

    private func flame(cx: Double, baseY: Double, w: Double, h: Double, t: Double, seed: Double) -> Path {
        var p = Path()
        let half = w / 2
        let tipX = cx + sin(t * 3.1 + seed) * w * 0.16
        p.move(to: CGPoint(x: cx - half, y: baseY))
        p.addQuadCurve(to: CGPoint(x: tipX - w * 0.08, y: baseY - h * 0.55),
                       control: CGPoint(x: cx - half * 0.9 + sin(t * 4 + seed) * w * 0.06, y: baseY - h * 0.35))
        p.addQuadCurve(to: CGPoint(x: tipX, y: baseY - h),
                       control: CGPoint(x: tipX - w * 0.16, y: baseY - h * 0.84))
        p.addQuadCurve(to: CGPoint(x: tipX + w * 0.08, y: baseY - h * 0.55),
                       control: CGPoint(x: tipX + w * 0.16, y: baseY - h * 0.84))
        p.addQuadCurve(to: CGPoint(x: cx + half, y: baseY),
                       control: CGPoint(x: cx + half * 0.9 + sin(t * 4 + seed + 1) * w * 0.06, y: baseY - h * 0.35))
        p.closeSubpath()
        return p
    }

    private func embers(_ ctx: GraphicsContext, cx: Double, baseY: Double, w: Double, h: Double, t: Double) {
        for i in 0..<70 {
            let seed = Double(i) * 12.9898
            func rnd(_ k: Double) -> Double { abs((sin(seed * k) * 43758.5453).truncatingRemainder(dividingBy: 1)) }
            let life = 2.0 + rnd(1) * 2.5
            let prog = (t + rnd(2) * life).truncatingRemainder(dividingBy: life) / life
            let x = cx + (rnd(3) - 0.5) * w * 0.9 + sin(t * 1.5 + seed) * w * 0.08
            let y = baseY - prog * h
            let a = (1 - prog) * (0.45 + rnd(4) * 0.5)
            let r = (1.0 + rnd(5) * 2.0) * (1 - prog * 0.5)
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                     with: .color(Color(red: 1, green: 0.5 + rnd(6) * 0.4, blue: 0.12).opacity(a)))
        }
    }
}
