import AppKit

/// Display model; every string is precomputed by the app so the view only lays out and draws.
struct PopoverModel {
    struct Bar {
        var label: String
        var fraction: Double
        var low: Bool
        var percent: String
    }
    /// Bar rows plus the tertiary reset line under them ("5h resets 3h 48m · wk resets 6d 21h").
    struct Bars {
        var bars: [Bar] = []
        var reset: String?
    }
    struct Account {
        var name: String
        /// Right-aligned tertiary text on the name row ("5h burnt in ~1h 6m"); hidden when `tag` is set.
        var note: String?
        /// Error or "loading"; drawn uppercased on the right.
        var tag: String?
        var bars = Bars()
    }
    struct Section {
        var label: String
        var tag: String?
        var note: String?
        /// Tertiary line under the header: left label with tracking, right-aligned value ("CLAUDE POOL" / "5H 71% · WK 56%").
        var subtitle: (String, String)?
        var bars = Bars()
        var accounts: [Account] = []
    }
    /// Tertiary line under the title ("AVAILABLE NOW  70%").
    var subtitle = ""
    var sections: [Section] = []
    var footer = ""
    var refreshing = false
}

/// One flipped NSView that lays out and draws the whole popover in drawRect; no subviews, no layers.
final class PopoverView: NSView {
    static let width: CGFloat = 300
    private static let pad: CGFloat = 18

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
        func quota(_ bars: PopoverModel.Bars) -> String {
            (bars.bars.map { "\($0.label): \($0.percent) remaining" } + [bars.reset].compactMap { $0 }).joined(separator: ", ")
        }
        var labels = ["Usage. " + model.subtitle]
        for section in model.sections {
            labels.append([section.label, section.tag, section.note, quota(section.bars)].compactMap { $0 }.joined(separator: ". "))
            for account in section.accounts {
                labels.append([account.name, account.tag, account.note, quota(account.bars)].compactMap { $0 }.joined(separator: ". "))
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

    // MARK: Layout + draw in one pass

    private static func mono(_ size: CGFloat = 11, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    private static func text(_ s: String, _ font: NSFont, _ color: NSColor, tracking: CGFloat = 0) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: tracking])
    }

    private static func tag(_ s: String) -> NSAttributedString {
        text(s.uppercased(), small, Palette.tertiaryText, tracking: 0.8)
    }

    private static let title = NSFont.systemFont(ofSize: 15, weight: .semibold)
    private static let body = mono(11)
    private static let small = mono(10)
    private static let label = mono(10, .medium)
    private static let lineBody: CGFloat = 13
    private static let lineSmall: CGFloat = 12

    /// Walks the model top to bottom. With `draw` false it only measures; returns total height.
    private func layout(draw: Bool) -> CGFloat {
        let pad = Self.pad, right = Self.width - pad
        var y = pad

        // Title and the "AVAILABLE NOW" line.
        if draw { Self.text("Usage", Self.title, Palette.primaryText).draw(at: NSPoint(x: pad, y: y)) }
        y += 18 + 6
        if draw { Self.tag(model.subtitle).draw(at: NSPoint(x: pad, y: y)) }
        y += Self.lineSmall

        for section in model.sections {
            y += 18
            let rightText = section.tag.map(Self.tag) ?? section.note.map { Self.text($0, Self.small, Palette.tertiaryText) }
            row(y: y, draw: draw, left: Self.text(section.label, Self.label, Palette.secondaryText, tracking: 1.2), right: rightText)
            y += Self.lineSmall
            if let (label, value) = section.subtitle {
                y += 10
                row(y: y, draw: draw, left: Self.tag(label), right: Self.text(value, Self.small, Palette.tertiaryText))
                y += Self.lineSmall
            }
            y = bars(section.bars, y: y, draw: draw)
            for (index, account) in section.accounts.enumerated() {
                y += 10
                let name = NSMutableAttributedString()
                name.append(Self.text(index == section.accounts.count - 1 ? "└ " : "├ ", Self.body, Palette.tertiaryText))
                name.append(Self.text(account.name, Self.body, account.tag == nil ? Palette.primaryText : Palette.tertiaryText))
                let rightText = account.tag.map(Self.tag) ?? account.note.map { Self.text($0, Self.small, Palette.tertiaryText) }
                row(y: y, draw: draw, left: name, right: rightText, truncateLeft: true)
                y += Self.lineBody
                y = bars(account.bars, y: y, draw: draw)
            }
        }

        // Footer: status text, then settings, refresh and quit glyphs.
        y += 18
        let glyph: CGFloat = 14
        quitRect = NSRect(x: right - glyph, y: y - 1, width: glyph, height: glyph)
        refreshRect = quitRect.offsetBy(dx: -(glyph + 12), dy: 0)
        settingsRect = refreshRect.offsetBy(dx: -(glyph + 12), dy: 0)
        settingsButton.frame = settingsRect.insetBy(dx: -3, dy: -3)
        refreshButton.frame = refreshRect.insetBy(dx: -3, dy: -3)
        quitButton.frame = quitRect.insetBy(dx: -3, dy: -3)
        refreshButton.isEnabled = !model.refreshing
        if draw {
            Self.tag(model.footer).draw(at: NSPoint(x: pad, y: y))
        }
        y += Self.lineSmall
        return y + pad
    }

    /// Bar rows: label (20) · dithered bar · percent (34, right); then the reset line in tertiary.
    private func bars(_ group: PopoverModel.Bars, y start: CGFloat, draw: Bool) -> CGFloat {
        guard !group.bars.isEmpty else { return start }
        let pad = Self.pad, right = Self.width - pad
        var y = start + 6
        for (i, bar) in group.bars.enumerated() {
            if i > 0 { y += 5 }
            if draw {
                Self.text(bar.label, Self.body, Palette.secondaryText).draw(at: NSPoint(x: pad, y: y))
                let percent = Self.text(bar.percent, Self.body, Palette.primaryText)
                percent.draw(at: NSPoint(x: right - percent.size().width, y: y))
                let barRect = NSRect(x: pad + 28, y: y + 3, width: right - 34 - 8 - (pad + 28), height: 8)
                Self.dither(barRect, fraction: bar.fraction, low: bar.low)
            }
            y += Self.lineBody
        }
        if let reset = group.reset {
            y += 5
            if draw { Self.text(reset, Self.small, Palette.tertiaryText).draw(at: NSPoint(x: pad, y: y)) }
            y += Self.lineSmall
        }
        return y
    }

    /// Left text, optional right-aligned text; left is middle-truncated to fit when asked.
    private func row(y: CGFloat, draw: Bool, left: NSAttributedString, right: NSAttributedString?, truncateLeft: Bool = false) {
        guard draw else { return }
        let pad = Self.pad, rightEdge = Self.width - pad
        var available = rightEdge - pad
        if let right {
            let w = right.size().width
            right.draw(at: NSPoint(x: rightEdge - w, y: y))
            available -= w + 8
        }
        if truncateLeft, left.size().width > available {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingMiddle
            let m = NSMutableAttributedString(attributedString: left)
            m.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: m.length))
            m.draw(with: NSRect(x: pad, y: y, width: available, height: Self.lineBody + 4), options: [.usesLineFragmentOrigin])
        } else {
            left.draw(at: NSPoint(x: pad, y: y))
        }
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
