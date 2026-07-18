import SwiftUI

/// Full-screen "Nothing phone" style charging animation: a dot-matrix battery that
/// fills to the current charge, with a bright pulse sweeping up through the filled
/// region, plus the percentage in a 5×7 dot font. Pure Canvas — no assets.
struct ChargingAnimationView: View {
    let percentage: Int
    var accent: Color = .white

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
            Canvas { ctx, size in
                draw(ctx, size, t: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, t: Double) {
        let spacing = max(16.0, min(size.width, size.height) / 46)
        let dot = spacing * 0.42
        let cols = Int(size.width / spacing)
        let rows = Int(size.height / spacing)
        guard cols > 8, rows > 12 else { return }
        let offX = (size.width - CGFloat(cols) * spacing) / 2 + spacing / 2
        let offY = (size.height - CGFloat(rows) * spacing) / 2 + spacing / 2

        // Battery body in grid cells, centred, with a terminal nub on top.
        let bw = min(16, cols - 4)
        let bh = min(rows - 12, 24)
        let bx = (cols - bw) / 2
        let by = (rows - bh) / 2 - 1
        let termW = max(4, bw / 3), termH = 1
        let termX = bx + (bw - termW) / 2
        let termY = by - termH

        let interiorTop = by + 1, interiorBot = by + bh - 2
        let interiorRows = interiorBot - interiorTop + 1
        let filledRows = Int((Double(interiorRows) * Double(percentage) / 100.0).rounded())
        let fillTopRow = interiorBot - max(0, filledRows) + 1   // rows >= this are filled

        // Pulse sweeping bottom → top through the interior every ~1.8s.
        let period = 1.8
        let sweep = t.truncatingRemainder(dividingBy: period) / period
        let sweepRow = Double(interiorBot) - sweep * Double(interiorRows - 1)

        func cell(_ c: Int, _ r: Int, _ brightness: Double) {
            guard brightness > 0.05 else { return }
            let cx = offX + CGFloat(c) * spacing, cy = offY + CGFloat(r) * spacing
            let rect = CGRect(x: cx - dot / 2, y: cy - dot / 2, width: dot, height: dot)
            ctx.fill(Path(ellipseIn: rect), with: .color(accent.opacity(min(1, brightness))))
        }

        for r in 0..<rows {
            for c in 0..<cols {
                let onBodyOutline = c >= bx && c <= bx + bw - 1 && r >= by && r <= by + bh - 1
                    && (c == bx || c == bx + bw - 1 || r == by || r == by + bh - 1)
                let onTerminal = c >= termX && c <= termX + termW - 1 && r >= termY && r <= termY + termH - 1
                let interior = c > bx && c < bx + bw - 1 && r > by && r < by + bh - 1

                var brightness = 0.05   // faint background matrix
                if onBodyOutline || onTerminal {
                    brightness = 0.85
                } else if interior && r >= fillTopRow {
                    brightness = 0.5
                    let d = abs(Double(r) - sweepRow)   // charging pulse
                    if d < 1 { brightness = 1.0 } else if d < 2.2 { brightness = 0.75 }
                } else if interior {
                    brightness = 0.12
                }
                cell(c, r, brightness)
            }
        }

        let batteryBottomY = offY + CGFloat(by + bh - 1) * spacing
        drawText("\(percentage)%", ctx: ctx, width: size.width,
                 cell: spacing * 1.9, dot: dot * 1.9, topY: batteryBottomY + spacing * 2.5)
    }

    /// Render a string in the 5×7 dot font, centred horizontally, at an arbitrary size.
    private func drawText(_ s: String, ctx: GraphicsContext, width: CGFloat,
                          cell: CGFloat, dot: CGFloat, topY: CGFloat) {
        let chars = Array(s)
        let glyphW = 5, gap = 1
        let totalW = CGFloat(chars.count * (glyphW + gap) - gap) * cell
        let startX = (width - totalW) / 2 + cell / 2
        for (i, ch) in chars.enumerated() {
            guard let glyph = Self.font[ch] else { continue }
            let gx = i * (glyphW + gap)
            for (row, bits) in glyph.enumerated() {
                for col in 0..<glyphW where (bits & (1 << (glyphW - 1 - col))) != 0 {
                    let cx = startX + CGFloat(gx + col) * cell
                    let cy = topY + CGFloat(row) * cell + cell / 2
                    let rect = CGRect(x: cx - dot / 2, y: cy - dot / 2, width: dot, height: dot)
                    ctx.fill(Path(ellipseIn: rect), with: .color(accent))
                }
            }
        }
    }

    /// 5×7 dot font, 7 rows per glyph; the low 5 bits are the columns (MSB = left).
    private static let font: [Character: [UInt8]] = [
        "0": [0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E],
        "1": [0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E],
        "2": [0x0E, 0x11, 0x01, 0x06, 0x08, 0x10, 0x1F],
        "3": [0x1F, 0x01, 0x02, 0x06, 0x01, 0x11, 0x0E],
        "4": [0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02],
        "5": [0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E],
        "6": [0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E],
        "7": [0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08],
        "8": [0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E],
        "9": [0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C],
        "%": [0x19, 0x19, 0x02, 0x04, 0x08, 0x13, 0x13],
    ]
}
