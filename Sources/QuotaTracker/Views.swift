import AppKit

/// Display model; every string is precomputed by the app so the view only lays out and draws.
struct PopoverModel {
    struct Bar {
        var label: String
        var fraction: Double
        var low: Bool
        var percent: String
    }
    /// The Claude pool: the parent of every account row.
    struct Pool {
        /// Pool NOW, e.g. "55%".
        var hero: String
        var low = false
        /// "token pool".
        var caption: String
        /// WK, then one bar per model-scoped weekly limit.
        var bars: [Bar] = []
    }
    /// A compact child row: name and NOW on one line, a thin bar, then one muted detail line.
    struct Child {
        var name: String
        /// "42%"; nil when `tag` is shown instead.
        var percent: String?
        var fraction: Double = 0
        var low = false
        /// Error or "loading"; drawn uppercased on the right in place of the percent.
        var tag: String?
        /// Detail parts ("5H 42", "WK 95", "resets 3h 48m"), joined with " · " and wrapped between parts.
        var detail: [String] = []
        /// What to do about a stale row; replaces `detail`.
        var hint: String?
        /// Last good data: numbers and bar drawn dimmed.
        var stale = false
    }
    struct Group {
        var label: String
        var rows: [Child]
    }
    var pool: Pool?
    /// "ACCOUNTS", then "CODEX".
    var groups: [Group] = []
    var footer = ""
    var refreshing = false
}

/// One flipped NSView that lays out and draws the whole popover in drawRect; no subviews, no layers.
///
/// Grid: 4 pt spacing scale, `pad` on all four sides, child rows indented one `indent` step, one
/// right-aligned number column. Vertical gaps are measured between visible ink (cap top to baseline),
/// so the rhythm reads evenly regardless of font size.
final class PopoverView: NSView {
    static let width: CGFloat = 320
    private static let pad: CGFloat = 20
    private static let indent: CGFloat = 12
    /// Spacing scale (4 pt steps), smallest to largest: lines within one row (name → bar → detail, wrapped
    /// lines, hero → caption); a group label to its first row and pool bar to bar; rows (accounts); sections
    /// (pool, accounts, Codex, footer), split by a hairline. Gaps run baseline to cap top.
    private static let lineGap: CGFloat = 8
    private static let labelGap: CGFloat = 12
    private static let rowGap: CGFloat = 20
    private static let sectionGap: CGFloat = 24
    private static let poolBarHeight: CGFloat = 8
    private static let childBarHeight: CGFloat = 4

    var model = PopoverModel() { didSet { relayout() } }
    var onRefresh: (() -> Void)?
    var onQuit: (() -> Void)?
    var onSettings: ((NSView, NSPoint) -> Void)?

    private let settingsButton = NSButton()
    private let refreshButton = NSButton()
    private let quitButton = NSButton()

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); configureButtons() }
    required init?(coder: NSCoder) { super.init(coder: coder); configureButtons() }
    private func configureButtons() {
        for (button, symbol, label, action) in [
            (settingsButton, "gearshape", "Settings", #selector(settings)),
            (refreshButton, "arrow.clockwise", "Refresh", #selector(refresh)),
            (quitButton, "power", "Quit", #selector(quit))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.title = ""
            button.isBordered = false
            button.contentTintColor = Palette.secondaryText
            button.setAccessibilityLabel(label)
            button.toolTip = label
            button.target = self
            button.action = action
            addSubview(button)
        }
        setAccessibilityElement(false)
    }
    @objc private func settings() { onSettings?(self, NSPoint(x: settingsRect.minX, y: settingsRect.maxY + 4)) }
    @objc private func refresh() { if !model.refreshing { onRefresh?() } }
    @objc private func quit() { onQuit?() }

    override func accessibilityChildren() -> [Any]? {
        var labels: [String] = []
        if let pool = model.pool {
            labels.append((["Claude \(pool.caption): \(pool.hero)"] + pool.bars.map { "\($0.label): \($0.percent) remaining" })
                .joined(separator: ", "))
        }
        for group in model.groups {
            labels.append(group.label)
            for row in group.rows {
                labels.append(([row.name, row.percent.map { "\($0) available now" }, row.tag, row.hint]
                               + row.detail).compactMap { $0 }.joined(separator: ", "))
            }
        }
        labels.append(model.footer)
        let frame = window?.convertToScreen(convert(bounds, to: nil)) ?? .zero
        let elements = labels.map { label -> NSAccessibilityElement in
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityLabel(label)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrame(frame)
            return element
        }
        return elements + [settingsButton, refreshButton, quitButton]
    }

    private var settingsRect = NSRect.zero
    private var refreshRect = NSRect.zero
    private var quitRect = NSRect.zero
    private var height: CGFloat = 0

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: height) }

    private func relayout() {
        height = layout(draw: false)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        Palette.background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        _ = layout(draw: true)
    }

    // MARK: Type

    private static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }
    /// Four sizes: hero > pool rows > child rows, labels and metadata (metadata told apart by colour).
    private static let hero = mono(26, .light)
    private static let poolRow = mono(12)
    private static let childRow = mono(10)
    private static let label = mono(10, .medium)

    private static func text(_ s: String, _ font: NSFont, _ color: NSColor, tracking: CGFloat = 0) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: tracking])
    }
    /// Letter-spaced small caps: section labels in secondary grey, status and tags in tertiary.
    private static func caps(_ s: String, _ color: NSColor = Palette.tertiaryText) -> NSAttributedString {
        text(s.uppercased(), label, color, tracking: 1.2)
    }
    /// Right column: wide enough for "100%" in the pool-row font, plus a gap before bars end.
    private static let numberColumn: CGFloat = 32
    private static var barEnd: CGFloat { width - pad - numberColumn - 12 }

    // MARK: Layout + draw in one pass

    /// Draws `s` with its cap height starting at `top`; returns the baseline.
    @discardableResult
    private func put(_ s: NSAttributedString, x: CGFloat, top: CGFloat, draw: Bool, width: CGFloat? = nil) -> CGFloat {
        let font = s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? Self.childRow
        let origin = NSPoint(x: x, y: top - (font.ascender - font.capHeight))
        if draw {
            if let width, s.size().width > width {
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byTruncatingMiddle
                let m = NSMutableAttributedString(attributedString: s)
                m.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: m.length))
                m.draw(with: NSRect(x: origin.x, y: origin.y, width: width, height: font.ascender - font.descender + 2),
                       options: [.usesLineFragmentOrigin])
            } else {
                s.draw(at: origin)
            }
        }
        return top + font.capHeight
    }

    private func putRight(_ s: NSAttributedString, top: CGFloat, draw: Bool) -> CGFloat {
        let w = s.size().width
        put(s, x: Self.width - Self.pad - w, top: top, draw: draw)
        return w
    }

    /// Walks the model top to bottom. With `draw` false it only measures; returns total height.
    private func layout(draw: Bool) -> CGFloat {
        let pad = Self.pad
        var y = pad
        var first = true
        func section() {
            if !first { y += Self.sectionGap }
            first = false
        }

        if let pool = model.pool {
            section()
            y = self.pool(pool, top: y, draw: draw)
        }
        for group in model.groups {
            if !first {
                // Hairline between sections; the pool above is the parent of the accounts below.
                y += Self.sectionGap
                if draw {
                    Palette.tertiaryText.withAlphaComponent(0.5).setFill()
                    NSRect(x: pad, y: y, width: Self.width - 2 * pad, height: 1 / (window?.backingScaleFactor ?? 2)).fill()
                }
            }
            section()
            y = put(Self.caps(group.label, Palette.secondaryText), x: pad, top: y, draw: draw)
            for (index, row) in group.rows.enumerated() {
                y = child(row, top: y + (index == 0 ? Self.labelGap : Self.rowGap), draw: draw)
            }
        }

        // Footer: status text, then settings, refresh and quit glyphs centred on its caps. The gap above is
        // measured to the glyphs' top, which stand taller than the caps.
        let glyph: CGFloat = 14
        let capHeight = Self.label.capHeight
        if !first { y += Self.sectionGap + (glyph - capHeight) / 2 }
        quitRect = NSRect(x: Self.width - pad - glyph, y: y + capHeight / 2 - glyph / 2, width: glyph, height: glyph)
        refreshRect = quitRect.offsetBy(dx: -(glyph + 12), dy: 0)
        settingsRect = refreshRect.offsetBy(dx: -(glyph + 12), dy: 0)
        settingsButton.frame = settingsRect.insetBy(dx: -3, dy: -3)
        refreshButton.frame = refreshRect.insetBy(dx: -3, dy: -3)
        quitButton.frame = quitRect.insetBy(dx: -3, dy: -3)
        refreshButton.isEnabled = !model.refreshing
        // A long status ("OFFLINE · UPDATED 23H AGO") wraps between its parts instead of meeting the glyphs.
        let lines = wrap(model.footer.components(separatedBy: " · "), width: settingsRect.minX - 12 - pad) { Self.caps($0) }
        for (index, line) in lines.enumerated() {
            y = put(Self.caps(line), x: pad, top: index == 0 ? y : y + Self.lineGap, draw: draw)
        }
        return (y + pad).rounded(.up)
    }

    /// Greedy wrap of `parts` joined with " · ", breaking only between parts.
    private func wrap(_ parts: [String], width: CGFloat, style: (String) -> NSAttributedString) -> [String] {
        var lines: [String] = []
        for part in parts {
            if let last = lines.last, style(last + " · " + part).size().width <= width {
                lines[lines.count - 1] = last + " · " + part
            } else {
                lines.append(part)
            }
        }
        return lines
    }

    /// Hero NOW, caption, then WK/model bars with labels in a fixed column.
    private func pool(_ pool: PopoverModel.Pool, top: CGFloat, draw: Bool) -> CGFloat {
        let pad = Self.pad
        var y = put(Self.text(pool.hero, Self.hero, pool.low ? Palette.terracotta : Palette.primaryText), x: pad - 1, top: top, draw: draw)
        y = put(Self.text(pool.caption, Self.childRow, Palette.secondaryText), x: pad, top: y + Self.lineGap + 4, draw: draw)
        let labels = pool.bars.map { Self.text($0.label, Self.poolRow, Palette.secondaryText) }
        let widest = labels.map { $0.size().width }.max() ?? 0
        let barStart = pad + max(48, ((widest + 12) / 4).rounded(.up) * 4)
        for (index, bar) in pool.bars.enumerated() {
            let top = y + (index == 0 ? Self.rowGap : Self.labelGap)
            put(labels[index], x: pad, top: top, draw: draw)
            _ = putRight(Self.text(bar.percent, Self.poolRow, Palette.primaryText), top: top, draw: draw)
            let capHeight = Self.poolRow.capHeight
            if draw {
                Self.dither(NSRect(x: barStart, y: top + capHeight / 2 - Self.poolBarHeight / 2, width: Self.barEnd - barStart, height: Self.poolBarHeight),
                            fraction: bar.fraction, low: bar.low)
            }
            y = top + capHeight
        }
        return y
    }

    /// Name and NOW, a thin bar under the name, then the muted detail (or hint) wrapped between parts.
    private func child(_ row: PopoverModel.Child, top: CGFloat, draw: Bool) -> CGFloat {
        let x = Self.pad + Self.indent, right = Self.width - Self.pad
        let ctx = draw ? NSGraphicsContext.current?.cgContext : nil
        func dimmed(_ body: () -> Void) {
            guard row.stale, let ctx else { return body() }
            ctx.saveGState()
            ctx.setAlpha(0.4)
            body()
            ctx.restoreGState()
        }

        var rightWidth: CGFloat = 0
        if let tag = row.tag {
            rightWidth = putRight(Self.caps(tag), top: top, draw: draw)
        } else if let percent = row.percent {
            let s = Self.text(percent, Self.childRow, Palette.primaryText)
            rightWidth = s.size().width
            dimmed { _ = putRight(s, top: top, draw: draw) }
        }
        let nameColor = row.tag == nil ? Palette.primaryText : Palette.tertiaryText
        var y = put(Self.text(row.name, Self.childRow, nameColor), x: x, top: top, draw: draw,
                    width: right - x - (rightWidth > 0 ? rightWidth + 12 : 0))
        if row.tag == nil && row.percent != nil {
            // Clear the name's descenders.
            let barTop = y + Self.lineGap
            dimmed {
                if draw { Self.dither(NSRect(x: x, y: barTop, width: Self.barEnd - x, height: Self.childBarHeight), fraction: row.fraction, low: row.low) }
            }
            y = barTop + Self.childBarHeight
        }
        if let hint = row.hint {
            y = put(Self.text(hint, Self.childRow, Palette.secondaryText), x: x, top: y + Self.lineGap, draw: draw, width: right - x)
        } else if !row.detail.isEmpty {
            // Wrap only between parts so metadata is never cut mid-word.
            let lines = wrap(row.detail, width: right - x) { Self.text($0, Self.childRow, Palette.tertiaryText) }
            dimmed {
                for (index, line) in lines.enumerated() {
                    y = put(Self.text(line, Self.childRow, Palette.tertiaryText), x: x, top: y + (index == 0 ? Self.lineGap : Self.lineGap), draw: draw)
                }
            }
        }
        return y
    }

    /// Stippled bar: dense checker for the filled part, sparse dots for the track. Static, no animation.
    private static func dither(_ rect: NSRect, fraction: Double, low: Bool) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let cell: CGFloat = 1
        let split = (rect.width * min(max(fraction, 0), 1) / cell).rounded() * cell
        var filled: [CGRect] = [], track: [CGRect] = []
        var row = 0
        var y = rect.minY
        while y < rect.maxY {
            var col = 0
            var x: CGFloat = 0
            while x < rect.width {
                if x < split {
                    if (row + col) % 2 == 0 { filled.append(CGRect(x: rect.minX + x, y: y, width: cell, height: cell)) }
                } else if row % 2 == 0 && col % 2 == 0 {
                    track.append(CGRect(x: rect.minX + x, y: y, width: cell, height: cell))
                }
                x += cell; col += 1
            }
            y += cell; row += 1
        }
        (low ? Palette.terracotta : Palette.primaryText).setFill()
        ctx.fill(filled)
        Palette.tertiaryText.setFill()
        ctx.fill(track)
    }

}
