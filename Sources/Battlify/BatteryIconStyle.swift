import AppKit

/// Selectable look for the menu-bar battery glyph. `rounded` and `bars` use
/// HugeIcons' actual battery geometry (squircle body + rounded terminal + bolt);
/// `classic` and `minimal` are drawn to complement them. All fill proportionally
/// to the real charge (except `bars`, which is intentionally stepped).
enum BatteryIconStyle: String, CaseIterable, Identifiable, Codable {
    case rounded   // HugeIcons squircle, smooth proportional fill (premium default)
    case bars      // HugeIcons squircle with discrete level bars (authentic set look)
    case classic   // traditional horizontal battery, smooth fill
    case minimal   // clean capsule/pill, no terminal, smooth fill
    case pixel     // chunky 8-bit battery; the fill sweeps upward while charging

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rounded: return "Rounded"
        case .bars:    return "Bars"
        case .classic: return "Classic"
        case .minimal: return "Minimal"
        case .pixel:   return "Pixel"
        }
    }
}

/// Renders `BatteryIconStyle` into cached `NSImage`s sized for the menu bar (or
/// larger, for settings previews). Drawing is done in HugeIcons' 24×24 viewBox
/// and scaled to the requested height, so every style stays pixel-aligned and
/// re-renders crisply at any screen scale.
enum BatteryIconRenderer {
    // HugeIcons battery paths (viewBox 0 0 24 24), taken from @hugeicons/core-free-icons.
    private static let bodyPath = "M2 12C2 9.17157 2 7.75736 2.87868 6.87868C3.75736 6 5.17157 6 8 6H13C15.8284 6 17.2426 6 18.1213 6.87868C19 7.75736 19 9.17157 19 12C19 14.8284 19 16.2426 18.1213 17.1213C17.2426 18 15.8284 18 13 18H8C5.17157 18 3.75736 18 2.87868 17.1213C2 16.2426 2 14.8284 2 12Z"
    private static let terminalPath = "M19 9.5L20.0272 9.6712C20.7085 9.78475 21.0491 9.84152 21.3076 10.0067C21.5618 10.1691 21.7612 10.4044 21.8796 10.6819C22 10.964 22 11.3093 22 12C22 12.6907 22 13.036 21.8796 13.3181C21.7612 13.5956 21.5618 13.8309 21.3076 13.9933C21.0491 14.1585 20.7085 14.2153 20.0272 14.3288L19 14.5"
    private static let boltPath = "M10.8282 9L9.08572 11.1749C8.89899 11.4079 9.03283 11.7433 9.33733 11.8053L11.1627 12.1773C11.4873 12.2434 11.6111 12.6147 11.3842 12.8413L9.22216 15"

    // Content bounds inside the 24×24 viewBox (battery + terminal + half stroke),
    // shared by every style so switching styles never shifts the menu-bar layout.
    private static let vbMinX: CGFloat = 1.1, vbMinY: CGFloat = 5.1
    private static let vbW: CGFloat = 21.8, vbH: CGFloat = 13.8
    private static let stroke: CGFloat = 1.5

    @MainActor private static var cache: [String: NSImage] = [:]

    /// Menu-bar / preview glyph for a style. `tint` neutral ⇒ template image that
    /// adapts to the bar; a colour ⇒ fixed palette colour. Cached per input.
    /// `frame` is a monotonically increasing animation tick; only the pixel style
    /// uses it (charging sweep) — for every other style it's ignored, and the
    /// cache key stores the *resolved* fill state so the cache stays bounded no
    /// matter how high the tick counts.
    @MainActor static func image(style: BatteryIconStyle, percentage: Int,
                                 charging: Bool, tint: MenuBarTint,
                                 height: CGFloat = 14, frame: Int = 0) -> NSImage {
        let pct = max(0, min(100, percentage))
        let anim = style == .pixel ? pixelFillCount(pct: pct, charging: charging, frame: frame) : 0
        let key = "\(style.rawValue)|\(pct)|\(charging)|\(tint.cacheKey)|\(height)|\(anim)"
        if let cached = cache[key] { return cached }

        let color: NSColor = { if case .colored(let c) = tint { return c } else { return .black } }()
        let s = height / vbH
        let size = NSSize(width: vbW * s, height: vbH * s)

        let image = NSImage(size: size, flipped: false) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return true }
            // Map the y-down SVG viewBox into the (y-up) image, scaled to `height`.
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: s, y: -s)
            cg.translateBy(x: -vbMinX, y: -vbMinY)
            draw(style: style, pct: pct, charging: charging, color: color, frame: frame)
            return true
        }
        image.isTemplate = tint.isNeutral
        cache[key] = image
        return image
    }

    // MARK: - Per-style drawing (viewBox coordinates)

    private static func draw(style: BatteryIconStyle, pct: Int, charging: Bool, color: NSColor,
                             frame: Int = 0) {
        color.setStroke(); color.setFill()
        let frac = CGFloat(pct) / 100
        switch style {
        case .rounded:
            strokeSVG(bodyPath); strokeSVG(terminalPath)
            if charging { strokeSVG(boltPath, width: 1.7) }
            else { fillBar(x: 4.6, y: 9, maxW: 11.6, h: 6, r: 1.5, frac: frac) }

        case .bars:
            strokeSVG(bodyPath); strokeSVG(terminalPath)
            if charging { strokeSVG(boltPath, width: 1.7) }
            else { drawBars(frac: frac) }

        case .classic:
            let body = NSBezierPath(roundedRect: NSRect(x: 2, y: 7, width: 16.4, height: 10),
                                    xRadius: 2.2, yRadius: 2.2)
            body.lineWidth = stroke; body.stroke()
            NSBezierPath(roundedRect: NSRect(x: 19, y: 9.6, width: 1.9, height: 4.8),
                         xRadius: 0.7, yRadius: 0.7).fill()   // terminal nub
            if charging { strokeSVG(boltPath, width: 1.7) }
            else { fillBar(x: 3.7, y: 8.7, maxW: 13, h: 6.6, r: 1.2, frac: frac) }

        case .minimal:
            let pill = NSBezierPath(roundedRect: NSRect(x: 2, y: 8, width: 18, height: 8),
                                    xRadius: 4, yRadius: 4)
            pill.lineWidth = stroke; pill.stroke()
            if charging { strokeSVG(boltPath, width: 1.7) }
            else { fillBar(x: 3.6, y: 9.6, maxW: 14.8, h: 4.8, r: 2.4, frac: frac) }

        case .pixel:
            drawPixel(fill: pixelFillCount(pct: pct, charging: charging, frame: frame))
        }
    }

    // MARK: - Pixel style (8-bit battery)

    /// How many of the pixel glyph's fill columns are lit for a charge level and
    /// animation frame. While charging below full, the fill sweeps from the
    /// current level up to full — one column per frame — then wraps back, like a
    /// classic handheld's charge animation. Pure, so the renderer can also use it
    /// to normalize an ever-growing frame tick into a bounded cache key.
    static func pixelFillCount(pct: Int, charging: Bool, frame: Int) -> Int {
        let frac = CGFloat(max(0, min(100, pct))) / 100
        var n = Int((frac * CGFloat(pixelColumns)).rounded())
        // Keep one column lit for any non-zero charge (matches the other styles'
        // "not dead yet" sliver).
        if frac > 0.02 && n == 0 { n = 1 }
        n = min(pixelColumns, n)
        guard charging, n < pixelColumns else { return n }
        return n + frame % (pixelColumns - n + 1)
    }

    private static let pixelColumns = 6

    /// Chunky 8-bit battery. The outline is four straight bars whose corner cells
    /// are left empty — the classic pixel-art notched corner — plus a blocky
    /// terminal. The charge is `fill` fat columns with 1-px gutters. Everything is
    /// axis-aligned rects with square corners so it stays crisp when scaled.
    private static func drawPixel(fill: Int) {
        let u: CGFloat = 1.5                    // one "pixel" cell in viewBox units
        let x0: CGFloat = 2, y0: CGFloat = 6    // body origin
        let w: CGFloat = 16.5, h: CGFloat = 12  // body 11×8 cells
        // Outline with notched corners.
        NSBezierPath(rect: NSRect(x: x0 + u, y: y0, width: w - 2 * u, height: u)).fill()
        NSBezierPath(rect: NSRect(x: x0 + u, y: y0 + h - u, width: w - 2 * u, height: u)).fill()
        NSBezierPath(rect: NSRect(x: x0, y: y0 + u, width: u, height: h - 2 * u)).fill()
        NSBezierPath(rect: NSRect(x: x0 + w - u, y: y0 + u, width: u, height: h - 2 * u)).fill()
        // Terminal: one cell wide, three tall, vertically centered.
        NSBezierPath(rect: NSRect(x: x0 + w, y: y0 + (h - 3 * u) / 2, width: u, height: 3 * u)).fill()
        // Fill columns.
        guard fill > 0 else { return }
        for k in 0..<min(fill, pixelColumns) {
            let x = 3.75 + CGFloat(k) * 2.25
            NSBezierPath(rect: NSRect(x: x, y: 7.75, width: 1.75, height: 8.5)).fill()
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

    /// HugeIcons-style discrete level bars (0–4) at the set's own x positions.
    private static func drawBars(frac: CGFloat) {
        var n = Int((frac * 4).rounded())
        if frac > 0.02 && n == 0 { n = 1 }
        n = min(4, n)
        for k in 0..<max(0, n) {
            let x = 6 + CGFloat(k) * 3
            let bar = NSBezierPath()
            bar.move(to: NSPoint(x: x, y: 10)); bar.line(to: NSPoint(x: x, y: 14))
            bar.lineWidth = 1.5; bar.lineCapStyle = .round; bar.stroke()
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

/// Minimal SVG path → NSBezierPath parser. Supports the absolute commands used by
/// the HugeIcons battery set (M, L, H, V, C, Z). Coordinates are kept in the
/// source viewBox space; callers apply scaling via the graphics context.
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
