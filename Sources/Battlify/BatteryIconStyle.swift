import AppKit
import BattlifyKit

/// Selectable menu-bar battery glyph styles; all fill to the real charge except
/// `bars`, which is intentionally stepped.
enum BatteryIconStyle: String, CaseIterable, Identifiable, Codable {
    case rounded   // HugeIcons squircle, smooth proportional fill
    case bars      // HugeIcons squircle with discrete level bars
    case classic   // traditional horizontal battery, smooth fill
    case minimal   // clean capsule/pill, no terminal, smooth fill
    case pixel     // chunky 8-bit battery; the fill sweeps upward while charging
    case vertical  // upright battery, fill rises from the bottom
    case ring      // circular gauge; the arc tracks the charge
    case segments  // stepped bars, tallest last, like a signal meter
    case dot       // a circle filling like liquid — the quietest of the set
    case wave      // battery filled with liquid whose surface actually moves
    case boltFill  // the lightning bolt itself is the gauge
    case gauge     // half-circle dial with a travelling head

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rounded:  return "Rounded"
        case .bars:     return "Bars"
        case .classic:  return "Classic"
        case .minimal:  return "Minimal"
        case .pixel:    return "Pixel"
        case .vertical: return "Upright"
        case .ring:     return "Ring"
        case .segments: return "Meter"
        case .dot:      return "Dot"
        case .wave:     return "Wave"
        case .boltFill: return "Bolt"
        case .gauge:    return "Dial"
        }
    }

    /// True for styles whose look changes frame to frame even on battery, so the menu
    /// bar can tick for them instead of only while charging.
    var animatesOnBattery: Bool { self == .wave }

    /// The drawing box, in SVG viewBox units. The five horizontal styles share one box
    /// so switching between them never shifts the menu-bar layout; the upright and
    /// round styles are narrower by nature and get their own, which is a deliberate
    /// choice the user makes once rather than something that moves while they work.
    ///
    /// Every box is sized so the glyph lands at a sensible width at the menu bar's
    /// 14pt: a tall, narrow box scales *down* to fit the height and leaves a sliver
    /// nobody can read, so the upright battery is deliberately stout rather than
    /// true-to-life, and the round styles get a nearly square box.
    var viewBox: (x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
        switch self {
        case .rounded, .bars, .classic, .minimal, .pixel, .wave:
            return (1.1, 5.1, 21.8, 13.8)
        case .boltFill:  return (6.2, 1.6, 11.6, 20.8)
        case .gauge:     return (1.4, 4.6, 21.2, 15.0)
        case .vertical:  return (5.4, 2.4, 13.2, 17.2)
        case .ring:      return (1.4, 1.4, 21.2, 21.2)
        case .segments:  return (1.8, 5.2, 20.4, 13.6)
        case .dot:       return (2.6, 2.6, 18.8, 18.8)
        }
    }
}

/// Renders `BatteryIconStyle` into cached `NSImage`s. Drawing is in a 24×24
/// viewBox scaled to the requested height, so it stays crisp at any screen scale.
enum BatteryIconRenderer {
    // HugeIcons battery paths (viewBox 0 0 24 24), taken from @hugeicons/core-free-icons.
    private static let bodyPath = "M2 12C2 9.17157 2 7.75736 2.87868 6.87868C3.75736 6 5.17157 6 8 6H13C15.8284 6 17.2426 6 18.1213 6.87868C19 7.75736 19 9.17157 19 12C19 14.8284 19 16.2426 18.1213 17.1213C17.2426 18 15.8284 18 13 18H8C5.17157 18 3.75736 18 2.87868 17.1213C2 16.2426 2 14.8284 2 12Z"
    private static let terminalPath = "M19 9.5L20.0272 9.6712C20.7085 9.78475 21.0491 9.84152 21.3076 10.0067C21.5618 10.1691 21.7612 10.4044 21.8796 10.6819C22 10.964 22 11.3093 22 12C22 12.6907 22 13.036 21.8796 13.3181C21.7612 13.5956 21.5618 13.8309 21.3076 13.9933C21.0491 14.1585 20.7085 14.2153 20.0272 14.3288L19 14.5"
    private static let boltPath = "M10.8282 9L9.08572 11.1749C8.89899 11.4079 9.03283 11.7433 9.33733 11.8053L11.1627 12.1773C11.4873 12.2434 11.6111 12.6147 11.3842 12.8413L9.22216 15"

    private static let stroke: CGFloat = 1.5

    @MainActor private static var cache: [String: NSImage] = [:]

    /// Menu-bar / preview glyph. `tint` neutral ⇒ template image; a colour ⇒
    /// fixed palette colour. `frame` is a monotonically increasing animation tick;
    /// the cache key stores the *resolved* animation state (fill count, pulse
    /// phase, or blink) so it stays bounded no matter how high the tick counts.
    @MainActor static func image(style: BatteryIconStyle, percentage: Int,
                                 charging: Bool, tint: MenuBarTint,
                                 height: CGFloat = 14, frame: Int = 0,
                                 celebrating: Bool = false) -> NSImage {
        let pct = max(0, min(100, percentage))
        let anim: Int
        if celebrating {
            anim = phase(frame, 4)                                          // bolt → check morph
        } else if charging && style == .pixel {
            anim = pixelFillCount(pct: pct, charging: charging, frame: frame) // sweep step
        } else if charging {
            anim = phase(frame, sweepSteps)                                  // fill sweep + bolt pulse
        } else if style.animatesOnBattery {
            anim = phase(frame, sweepSteps)                                  // wave keeps moving
        } else {
            anim = 0
        }
        let key = "\(style.rawValue)|\(pct)|\(charging)|\(celebrating)|\(tint.cacheKey)|\(height)|\(anim)"
        if let cached = cache[key] { return cached }

        let baseColor: NSColor = { if case .colored(let c) = tint { return c } else { return .black } }()
        // Celebration renders at 100% with no bolt, blinking by alpha (which
        // survives the template treatment, so it works monochrome too).
        let effPct = celebrating ? 100 : pct
        let effCharging = celebrating ? false : charging
        let color = (celebrating && phase(frame, 2) == 1)
            ? baseColor.withAlphaComponent(0.45) : baseColor
        let vb = style.viewBox
        let s = height / vb.h
        let size = NSSize(width: vb.w * s, height: vb.h * s)
        // Celebration keeps its own frame so the morph runs 0 → 1 from the flash's start,
        // rather than picking up wherever the shared tick happened to be.
        let celebrateFrame = celebrating ? phase(frame, 4) : 0

        let image = NSImage(size: size, flipped: false) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return true }
            // Map the y-down SVG viewBox into the (y-up) image, scaled to `height`.
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: s, y: -s)
            cg.translateBy(x: -vb.x, y: -vb.y)
            draw(style: style, pct: effPct, charging: effCharging, color: color,
                 frame: frame, celebrating: celebrating, celebrateFrame: celebrateFrame)
            return true
        }
        image.isTemplate = tint.isNeutral
        cache[key] = image
        return image
    }

    // MARK: - Per-style drawing (viewBox coordinates)

    private static func draw(style: BatteryIconStyle, pct: Int, charging: Bool, color: NSColor,
                             frame: Int = 0, celebrating: Bool = false,
                             celebrateFrame: Int = 0) {
        color.setStroke(); color.setFill()
        let frac = CGFloat(pct) / 100
        // While charging the fill rises from the real level towards full and restarts,
        // which is what a charging battery is expected to look like. The level itself
        // still shows: the sweep starts at it, so a glance at the low point reads true.
        let fillFrac = charging ? sweepFrac(frac, frame: frame) : frac
        switch style {
        case .rounded:
            strokeSVG(bodyPath); strokeSVG(terminalPath)
            fillAndBolt(charging: charging, celebrating: celebrating,
                        celebrateFrame: celebrateFrame, color: color, frame: frame,
                        bolt: boltPath, width: 1.7) {
                fillBar(x: 4.6, y: 9, maxW: 11.6, h: 6, r: 1.5, frac: fillFrac)
            }

        case .bars:
            strokeSVG(bodyPath); strokeSVG(terminalPath)
            fillAndBolt(charging: charging, celebrating: celebrating,
                        celebrateFrame: celebrateFrame, color: color, frame: frame,
                        bolt: boltPath, width: 1.7) {
                drawBars(frac: charging ? fillFrac : frac)
            }

        case .classic:
            let body = NSBezierPath(roundedRect: NSRect(x: 2, y: 7, width: 16.4, height: 10),
                                    xRadius: 2.2, yRadius: 2.2)
            body.lineWidth = stroke; body.stroke()
            NSBezierPath(roundedRect: NSRect(x: 19, y: 9.6, width: 1.9, height: 4.8),
                         xRadius: 0.7, yRadius: 0.7).fill()
            fillAndBolt(charging: charging, celebrating: celebrating,
                        celebrateFrame: celebrateFrame, color: color, frame: frame,
                        bolt: boltPath, width: 1.7) {
                fillBar(x: 3.7, y: 8.7, maxW: 13, h: 6.6, r: 1.2, frac: fillFrac)
            }

        case .minimal:
            let pill = NSBezierPath(roundedRect: NSRect(x: 2, y: 8, width: 18, height: 8),
                                    xRadius: 4, yRadius: 4)
            pill.lineWidth = stroke; pill.stroke()
            fillAndBolt(charging: charging, celebrating: celebrating,
                        celebrateFrame: celebrateFrame, color: color, frame: frame,
                        bolt: boltPath, width: 1.7) {
                fillBar(x: 3.6, y: 9.6, maxW: 14.8, h: 4.8, r: 2.4, frac: fillFrac)
            }

        case .pixel:
            drawPixel(fill: pixelFillCount(pct: pct, charging: charging, frame: frame))

        case .vertical:
            drawVertical(frac: fillFrac, charging: charging, color: color, frame: frame)

        case .ring:
            drawRing(frac: frac, charging: charging, color: color, frame: frame)

        case .segments:
            drawSegments(frac: charging ? fillFrac : frac, color: color)

        case .dot:
            drawDot(frac: fillFrac, charging: charging, color: color, frame: frame)

        case .wave:
            strokeSVG(bodyPath); strokeSVG(terminalPath)
            fillAndBolt(charging: charging, celebrating: celebrating,
                        celebrateFrame: celebrateFrame, color: color, frame: frame,
                        bolt: boltPath, width: 1.7) {
                drawWave(frac: fillFrac, frame: frame)
            }

        case .boltFill:
            drawBoltGauge(frac: fillFrac, charging: charging, color: color)

        case .gauge:
            drawDial(frac: frac, charging: charging, color: color, frame: frame)
        }
    }

    // MARK: - Upright / round styles

    /// Upright battery: cap on top, fill rising from the bottom. Drawn in a flipped
    /// context, so "up" is a smaller y — the fill grows by moving its origin down.
    ///
    /// Stout on purpose. A true-to-life upright cell is about half as wide as it is
    /// tall, which at 14pt is a 6pt sliver with an invisible fill; widening the body
    /// and shortening the can buys a glyph you can actually read in a menu bar.
    private static func drawVertical(frac: CGFloat, charging: Bool, color: NSColor, frame: Int) {
        let body = NSRect(x: 6.6, y: 4.6, width: 10.8, height: 14.2)
        let path = NSBezierPath(roundedRect: body, xRadius: 2.8, yRadius: 2.8)
        path.lineWidth = 1.6; path.stroke()
        // Cap.
        NSBezierPath(roundedRect: NSRect(x: 9.6, y: 2.9, width: 4.8, height: 1.9),
                     xRadius: 0.9, yRadius: 0.9).fill()

        let inset = NSRect(x: body.minX + 1.6, y: body.minY + 1.6,
                           width: body.width - 3.2, height: body.height - 3.2)
        fillAndBolt(charging: charging, color: color, frame: frame,
                    bolt: uprightBoltPath, width: 1.5) {
            guard frac > 0 else { return }
            let h = min(inset.height, max(2.0, inset.height * frac))
            NSBezierPath(roundedRect: NSRect(x: inset.minX, y: inset.maxY - h,
                                             width: inset.width, height: h),
                         xRadius: 1.4, yRadius: 1.4).fill()
        }
    }

    /// Circular gauge. The arc tracks the charge; while charging a short leading
    /// segment travels around the track, which reads as movement without the whole
    /// ring flickering.
    private static func drawRing(frac: CGFloat, charging: Bool, color: NSColor, frame: Int) {
        let center = NSPoint(x: 12, y: 12), radius: CGFloat = 8.2
        // Thick enough to survive 14pt: a 1.6pt track at menu-bar size is a grey hint,
        // not a track, and the gauge stops reading as a gauge.
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 2.6
        color.withAlphaComponent(0.22).setStroke()
        track.stroke()

        color.setStroke()
        let sweep = max(14, 360 * frac)          // always a visible tick of charge
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                      endAngle: 90 - sweep, clockwise: true)
        arc.lineWidth = 2.8
        arc.lineCapStyle = .round
        arc.stroke()

        guard charging else { return }
        // A solid head travelling the track: at 14pt a dot holds its shape where a thin
        // trailing arc smears into the track behind it.
        let lead = (90 - sweep - CGFloat(phase(frame, sweepSteps)) / CGFloat(sweepSteps) * 360)
            * .pi / 180
        let head = NSPoint(x: center.x + cos(lead) * radius, y: center.y - sin(lead) * radius)
        NSBezierPath(ovalIn: NSRect(x: head.x - 1.9, y: head.y - 1.9,
                                    width: 3.8, height: 3.8)).fill()
    }

    /// Stepped meter: four blocks, each taller than the last, lit up to the level.
    ///
    /// Unlit steps are filled at low alpha rather than outlined — a 1.1pt outline at
    /// menu-bar size is a smudge, while a dimmed block keeps its shape and still reads
    /// as "a step that isn't lit". Four fat steps rather than five thin ones for the
    /// same reason: at 14pt, 3.4pt of block beats 2.6pt of block plus a gap nobody sees.
    private static func drawSegments(frac: CGFloat, color: NSColor) {
        let lit = max(frac > 0.02 ? 1 : 0, min(4, Int((frac * 4).rounded())))
        let base: CGFloat = 18.4                                  // shared baseline
        for k in 0..<4 {
            let h = 5.0 + CGFloat(k) * 2.9
            let rect = NSRect(x: 2.6 + CGFloat(k) * 4.7, y: base - h, width: 3.4, height: h)
            let bar = NSBezierPath(roundedRect: rect, xRadius: 1.1, yRadius: 1.1)
            if k < lit {
                color.setFill()
            } else {
                color.withAlphaComponent(0.22).setFill()
            }
            bar.fill()
        }
        color.setFill()   // leave the fill colour as the caller set it
    }

    /// Liquid inside the standard battery body, with a moving surface: two sine crests
    /// across the width, the phase advancing one step per tick. The only style that
    /// animates on battery as well as while charging — it's the point of it — and it
    /// still stops dead when the animation toggle is off or Reduce Motion is on.
    private static func drawWave(frac: CGFloat, frame: Int) {
        guard frac > 0 else { return }
        let x0: CGFloat = 3.9, x1: CGFloat = 17.1          // inside the body walls
        let top: CGFloat = 8.3, bottom: CGFloat = 15.7     // flipped: bottom is larger y
        let surface = bottom - max(1.3, (bottom - top) * frac)
        let amplitude: CGFloat = min(0.85, (bottom - surface) / 2.4)
        let phase = CGFloat(self.phase(frame, sweepSteps)) / CGFloat(sweepSteps) * 2 * .pi

        let path = NSBezierPath()
        path.move(to: NSPoint(x: x0, y: bottom))
        let steps = 22
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = x0 + (x1 - x0) * t
            let y = surface + sin(phase + t * 2 * .pi * 2) * amplitude
            i == 0 ? path.line(to: NSPoint(x: x, y: y)) : path.line(to: NSPoint(x: x, y: y))
        }
        path.line(to: NSPoint(x: x1, y: bottom))
        path.close()
        // Clip to the body's inner radius so the liquid can't square off the corners.
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState()
        NSBezierPath(roundedRect: NSRect(x: x0, y: top, width: x1 - x0, height: bottom - top),
                     xRadius: 1.6, yRadius: 1.6).addClip()
        path.fill()
        cg.restoreGState()
    }

    /// The bolt *is* the gauge: a lightning silhouette that fills from the bottom, so
    /// the shape says "power" and the fill says "how much". Charging inverts it —
    /// the bolt goes solid — which needs no second mark crammed inside.
    private static func drawBoltGauge(frac: CGFloat, charging: Bool, color: NSColor) {
        let bolt = SVGPath.parse(boltGaugePath)
        bolt.lineWidth = 1.6
        bolt.lineJoinStyle = .round
        // The empty part of the bolt still has to be a bolt: too faint and a nearly
        // flat battery shows nothing at all in the menu bar.
        color.withAlphaComponent(0.45).setStroke()
        bolt.stroke()
        color.setStroke()

        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState()
        bolt.addClip()
        if charging {
            NSBezierPath(rect: NSRect(x: 5, y: 0, width: 14, height: 24)).fill()
        } else if frac > 0 {
            let bottom: CGFloat = 22.2, top: CGFloat = 1.8
            // The tail is the narrowest part, so a proportional sliver there is invisible;
            // a floor of 3 units keeps a low charge readable.
            let h = max(3.0, (bottom - top) * frac)
            NSBezierPath(rect: NSRect(x: 5, y: bottom - h, width: 14, height: h)).fill()
        }
        cg.restoreGState()
    }

    /// Half-circle dial: a wide track with the charge sweeping left to right and a solid
    /// head where it stops. Reads like a fuel gauge, and the flat bottom edge sits
    /// better next to menu-bar text than a full circle does.
    private static func drawDial(frac: CGFloat, charging: Bool, color: NSColor, frame: Int) {
        let center = NSPoint(x: 12, y: 17.4), radius: CGFloat = 7.8
        let track = NSBezierPath()
        // Flipped context: sweeping 180° → 360° draws the *upper* half.
        track.appendArc(withCenter: center, radius: radius, startAngle: 180, endAngle: 360)
        track.lineWidth = 2.6
        track.lineCapStyle = .round
        color.withAlphaComponent(0.22).setStroke()
        track.stroke()

        let end = 180 + max(8, 180 * frac)
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 180, endAngle: end)
        arc.lineWidth = 2.8
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()

        // Head marker: while charging it runs the dial, otherwise it parks at the level.
        let headDeg = charging
            ? 180 + CGFloat(phase(frame, sweepSteps)) / CGFloat(sweepSteps) * 180
            : end
        let a = headDeg * .pi / 180
        let head = NSPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
        NSBezierPath(ovalIn: NSRect(x: head.x - 1.9, y: head.y - 1.9,
                                    width: 3.8, height: 3.8)).fill()
    }

    /// A circle filling like liquid, clipped to the outline. The quietest style in the
    /// set: no terminal, no steps, just how full it is.
    ///
    /// It's the one style with no bolt while charging. There is no room for one inside a
    /// 14pt circle — every version of it came out a smudge — and the sweeping liquid
    /// already says "charging" without adding a mark that only works when zoomed in.
    private static func drawDot(frac: CGFloat, charging: Bool, color: NSColor, frame: Int) {
        let box = NSRect(x: 3.8, y: 3.8, width: 16.4, height: 16.4)
        let outline = NSBezierPath(ovalIn: box)
        outline.lineWidth = 1.8
        outline.stroke()

        guard frac > 0, let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState()
        let inner = box.insetBy(dx: 1.7, dy: 1.7)
        NSBezierPath(ovalIn: inner).addClip()
        let h = max(2.2, inner.height * frac)
        NSBezierPath(rect: NSRect(x: inner.minX, y: inner.maxY - h,
                                  width: inner.width, height: h)).fill()
        cg.restoreGState()
    }

    // MARK: - Animation helpers

    /// Bolt opacity cycle while charging — a slow breathe, not a hard blink.
    private static let boltPulse: [CGFloat] = [1.0, 0.72, 0.45, 0.72]

    /// Steps in the charging fill sweep. Also the modulus for every charging
    /// animation, so one tick drives the sweep, the bolt breathe and the ring marker
    /// together instead of them drifting against each other.
    private static let sweepSteps = 8

    /// Fill level to draw while charging: starts at the real level and rises to full
    /// across the cycle. `frame` 0 (animation off) draws the true level, so a static
    /// icon is never a lie.
    private static func sweepFrac(_ frac: CGFloat, frame: Int) -> CGFloat {
        let step = CGFloat(phase(frame, sweepSteps)) / CGFloat(sweepSteps)
        return min(1, frac + (1 - frac) * step)
    }

    /// A bolt sized for the upright and round styles, which have no room for the wide
    /// horizontal one.
    private static let uprightBoltPath = "M13 8.4L10.4 12.1C10.2 12.4 10.4 12.7 10.7 12.7L12.6 12.7C12.9 12.7 13.1 13.0 12.9 13.3L10.9 16.2"

    /// A wider bolt, morphed towards while charging so the mark breathes in shape and
    /// not just in opacity.
    private static let boltFatPath = "M11.3 8.6L8.6 11.3C8.3 11.6 8.5 12.1 8.9 12.2L11.6 12.7C12.1 12.8 12.3 13.3 12.0 13.7L9.0 15.6"

    /// The completion mark the bolt grows into.
    private static let checkPath = "M8.8 12.2L10.9 14.5L15.2 9.4"

    /// A *closed* bolt silhouette — the Bolt style fills and clips to it, which an open
    /// stroked path can't do.
    private static let boltGaugePath =
        "M14.8 1.8L7.2 13.1H11.1L9.2 22.2L16.8 10.4H12.6Z"

    /// Non-negative modulo, so an animation tick can never index out of range.
    private static func phase(_ frame: Int, _ n: Int) -> Int {
        ((frame % n) + n) % n
    }

    /// Draw a style's fill, then its charging bolt on top of it.
    ///
    /// A bolt stroked straight onto the fill vanishes — same colour, no edge. So the
    /// fill goes into a transparency layer and a slightly wider bolt is knocked out of
    /// it, leaving a transparent halo the bolt then sits in. That reads at any fill
    /// level, from a sliver to full, and survives the template treatment (macOS tints
    /// by alpha, and the halo is alpha).
    private static func fillAndBolt(charging: Bool, celebrating: Bool = false,
                                    celebrateFrame: Int = 0,
                                    color: NSColor, frame: Int,
                                    bolt: String, width: CGFloat,
                                    fill: () -> Void) {
        let glyph = overlayGlyph(charging: charging, celebrating: celebrating,
                                 celebrateFrame: celebrateFrame, frame: frame, bolt: bolt)
        guard let glyph, let cg = NSGraphicsContext.current?.cgContext else {
            fill()
            return
        }
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        fill()
        cg.saveGState()
        cg.setBlendMode(.destinationOut)   // erases only this layer's own pixels
        color.setStroke()
        stroke(glyph, width: width + 1.5)
        cg.restoreGState()
        cg.endTransparencyLayer()

        // The bolt breathes by alpha as well as by shape; the checkmark stays solid,
        // because a completion mark that dims looks like it's failing.
        let alpha = celebrating ? 1 : boltPulse[phase(frame, boltPulse.count)]
        color.withAlphaComponent(alpha).setStroke()
        stroke(glyph, width: width)
        color.setStroke()
    }

    /// The mark drawn over the fill, *morphed* between shapes rather than swapped.
    ///
    /// Charging breathes between a slim and a fat bolt — the same amount of energy,
    /// arriving — and the completion flash grows that bolt into a checkmark. Both go
    /// through `PathMorph`, which resamples the two outlines by arc length, so the
    /// in-between frames are real intermediate shapes instead of a cross-fade of two
    /// glyphs sitting on top of each other. Every frame is cached by the renderer, so
    /// the resampling happens a handful of times per state, not per redraw.
    private static func overlayGlyph(charging: Bool, celebrating: Bool,
                                     celebrateFrame: Int, frame: Int,
                                     bolt: String) -> NSBezierPath? {
        let slim = SVGPath.parse(bolt)
        if celebrating {
            let t = min(1, CGFloat(celebrateFrame) / 2)     // grow over two ticks, then hold
            return PathMorph.morph(from: slim, to: SVGPath.parse(checkPath), t: t)
        }
        guard charging else { return nil }
        let u = CGFloat(phase(frame, sweepSteps)) / CGFloat(sweepSteps)
        let t = 1 - abs(2 * u - 1)                          // 0 → 1 → 0, no jump at the wrap
        return PathMorph.morph(from: slim, to: SVGPath.parse(boltFatPath), t: t)
    }

    private static func stroke(_ path: NSBezierPath, width: CGFloat) {
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    /// Restores the stroke colour afterward so the rest of the glyph draws at
    /// full opacity.
    private static func drawBolt(_ color: NSColor, frame: Int,
                                 path: String? = nil, width: CGFloat = 1.7) {
        color.withAlphaComponent(boltPulse[phase(frame, boltPulse.count)]).setStroke()
        strokeSVG(path ?? boltPath, width: width)
        color.setStroke()
    }

    // MARK: - Pixel style (8-bit battery)

    /// Lit fill columns for a charge level and frame. While charging below full,
    /// the fill sweeps up one column per frame then wraps. Pure, so the renderer
    /// also uses it to bound an ever-growing frame tick into the cache key.
    static func pixelFillCount(pct: Int, charging: Bool, frame: Int) -> Int {
        let frac = CGFloat(max(0, min(100, pct))) / 100
        var n = Int((frac * CGFloat(pixelColumns)).rounded())
        // Keep one column lit for any non-zero charge (the "not dead yet" sliver).
        if frac > 0.02 && n == 0 { n = 1 }
        n = min(pixelColumns, n)
        guard charging, n < pixelColumns else { return n }
        return n + frame % (pixelColumns - n + 1)
    }

    /// Four fat cells, not six thin ones: at 14pt a 0.5-unit gap closes up and the fill
    /// reads as one solid barcode block instead of pixels.
    private static let pixelColumns = 4

    /// Chunky 8-bit battery: outline of four bars with empty corner cells (the
    /// pixel-art notched corner), a blocky terminal, then `fill` fat columns.
    /// Axis-aligned square-corner rects so it stays crisp when scaled.
    private static func drawPixel(fill: Int) {
        let u: CGFloat = 1.5                    // one "pixel" cell in viewBox units
        let x0: CGFloat = 2, y0: CGFloat = 6    // body origin
        let w: CGFloat = 16.5, h: CGFloat = 12  // body 11×8 cells
        NSBezierPath(rect: NSRect(x: x0 + u, y: y0, width: w - 2 * u, height: u)).fill()
        NSBezierPath(rect: NSRect(x: x0 + u, y: y0 + h - u, width: w - 2 * u, height: u)).fill()
        NSBezierPath(rect: NSRect(x: x0, y: y0 + u, width: u, height: h - 2 * u)).fill()
        NSBezierPath(rect: NSRect(x: x0 + w - u, y: y0 + u, width: u, height: h - 2 * u)).fill()
        NSBezierPath(rect: NSRect(x: x0 + w, y: y0 + (h - 3 * u) / 2, width: u, height: 3 * u)).fill()
        guard fill > 0 else { return }
        for k in 0..<min(fill, pixelColumns) {
            let x = 3.7 + CGFloat(k) * 3.3
            NSBezierPath(rect: NSRect(x: x, y: 7.75, width: 2.6, height: 8.5)).fill()
        }
    }

    /// Proportional rounded fill bar from the left, keeping a sliver visible for
    /// any non-zero charge so a nearly-empty battery still reads as "not dead".
    private static func fillBar(x: CGFloat, y: CGFloat, maxW: CGFloat, h: CGFloat,
                                r: CGFloat, frac: CGFloat) {
        guard frac > 0 else { return }
        let w = min(maxW, max(1.5, maxW * frac))
        let radius = min(r, w / 2, h / 2)
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h),
                     xRadius: radius, yRadius: radius).fill()
    }

    /// Four discrete level blocks. Filled rounded rects, not strokes: at 14pt a 1.5pt
    /// line lands between pixels and greys out, while a 2pt block stays a block.
    private static func drawBars(frac: CGFloat) {
        var n = Int((frac * 4).rounded())
        if frac > 0.02 && n == 0 { n = 1 }
        n = min(4, n)
        for k in 0..<max(0, n) {
            let rect = NSRect(x: 4.9 + CGFloat(k) * 3.1, y: 9.3, width: 2.1, height: 5.4)
            NSBezierPath(roundedRect: rect, xRadius: 0.8, yRadius: 0.8).fill()
        }
    }

    private static func strokeSVG(_ d: String, width: CGFloat = 1.5) {
        let path = SVGPath.parse(d)
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }
}

/// Minimal SVG path → NSBezierPath parser (absolute M, L, H, V, C, Z).
/// Coordinates stay in viewBox space; callers scale via the graphics context.
private enum SVGPath {
    static func parse(_ d: String) -> NSBezierPath {
        let nums = tokenize(d)
        let path = NSBezierPath()
        var cur = NSPoint.zero, start = NSPoint.zero
        var i = 0
        func f() -> CGFloat { defer { i += 1 }; return i < nums.count ? nums[i].num : 0 }
        func isNum() -> Bool { i < nums.count && !nums[i].isCmd }

        while i < nums.count {
            guard nums[i].isCmd else { i += 1; continue }
            let cmd = nums[i].cmd; i += 1
            switch cmd {
            case "M":
                cur = NSPoint(x: f(), y: f()); start = cur; path.move(to: cur)
                while isNum() { cur = NSPoint(x: f(), y: f()); path.line(to: cur) }
            case "L":
                while isNum() { cur = NSPoint(x: f(), y: f()); path.line(to: cur) }
            case "H":
                while isNum() { cur.x = f(); path.line(to: cur) }
            case "V":
                while isNum() { cur.y = f(); path.line(to: cur) }
            case "C":
                while isNum() {
                    let c1 = NSPoint(x: f(), y: f())
                    let c2 = NSPoint(x: f(), y: f())
                    let p = NSPoint(x: f(), y: f())
                    path.curve(to: p, controlPoint1: c1, controlPoint2: c2); cur = p
                }
            case "Z", "z":
                path.close(); cur = start
            default:
                break
            }
        }
        return path
    }

    private struct Token { let isCmd: Bool; let cmd: Character; let num: CGFloat }

    private static func tokenize(_ s: String) -> [Token] {
        var toks: [Token] = []
        let chars = Array(s)
        let cmdSet = Set("MLHVCSQTAZmlhvcsqtaz")
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "," || c == "\n" || c == "\t" { i += 1; continue }
            if cmdSet.contains(c) { toks.append(Token(isCmd: true, cmd: c, num: 0)); i += 1; continue }
            var j = i
            if chars[j] == "+" || chars[j] == "-" { j += 1 }
            while j < chars.count {
                let d = chars[j]
                if d.isNumber || d == "." { j += 1 }
                else if d == "e" || d == "E" {
                    j += 1
                    if j < chars.count, chars[j] == "+" || chars[j] == "-" { j += 1 }
                } else { break }
            }
            if j > i, let v = Double(String(chars[i..<j])) {
                toks.append(Token(isCmd: false, cmd: " ", num: CGFloat(v)))
            }
            i = max(j, i + 1)
        }
        return toks
    }
}
