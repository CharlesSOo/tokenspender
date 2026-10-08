import AppKit
import ImageIO
import ServiceManagement
import TokenSpenderCore

@main
enum TokenSpenderApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class UsagePanel: NSPanel { override var canBecomeKey: Bool { true } }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let activity = SessionLogActivity()
    /// Exists only while session-log activity is observed; cycles the animation frames.
    private var frameTimer: Timer?
    private var frame = 0
    /// Panel, view and minute timer exist only while the popover is on screen.
    private var panel: NSPanel?
    private var popoverView: PopoverView?
    private var minuteTick: Timer?
    private var keyObserver: NSObjectProtocol?
    private var closedAt = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        if Store.demo, let dir = env["TOKENSPENDER_SNAPSHOT_DIR"] {
            store.start()
            Task { await snapshot(to: dir) }
            return
        }
        let key = "registeredLoginItem"
        if !Store.demo, env["TOKENSPENDER_BENCH"] == nil, !UserDefaults.standard.bool(forKey: key) {
            do {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: key)
            } catch { /* Try again next launch; never claim registration succeeded. */ }
        }

        let button = statusItem.button!
        button.image = Critter.menuBar
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(togglePopover)
        store.onChange = { [weak self] in self?.storeChanged() }
        storeChanged()
        store.start()
        guard !Store.demo else { return }
        activity.onChange = { [weak self] in
            guard let self else { return }
            setAnimating(activity.isBurning)
        }
        applyAnimationSetting()
        if env["TOKENSPENDER_BENCH"] != nil { installBenchSignals() }
    }

    private func storeChanged() {
        let text = MenuLabel.text(mode: store.mode, snapshot: store.snapshot)
        statusItem.button?.attributedTitle = NSAttributedString(
            string: " " + text,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]
        )
        statusItem.button?.toolTip = "Estimated equal-account mean of limiting quotas, not token capacity. Missing/expired accounts excluded. Animation indicates log activity only."
        popoverView?.model = model(now: Date())
        resizePanel()
    }

    private func applyAnimationSetting() {
        if store.animation == .off {
            activity.stop()
        } else {
            activity.start()
            setAnimating(activity.isBurning)
        }
    }

    private func setAnimating(_ animating: Bool) {
        frameTimer?.invalidate()
        frameTimer = nil
        let animation = store.animation
        guard animating, !animation.frames.isEmpty else {
            statusItem.button?.image = Critter.menuBar
            return
        }
        let timer = Timer(timeInterval: CritterAnimation.interval, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                frame = (frame + 1) % animation.frames.count
                statusItem.button?.image = animation.frames[frame]
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    // MARK: Popover panel

    /// A borderless non-activating panel instead of NSPopover: no vibrancy backdrop, mask layers or
    /// arrow, which measured ~6 MB less resident after the first open.
    @objc private func togglePopover() {
        if panel != nil { return closePanel() }
        // Clicking the status item while open resigns key first (closing the panel); don't reopen.
        if Date().timeIntervalSince(closedAt) < 0.3 { return }
        store.refresh()
        let view = PopoverView()
        view.onRefresh = { [weak self] in self?.store.refresh() }
        view.onQuit = { NSApp.terminate(nil) }
        view.onSettings = { [weak self] view, point in self?.showSettingsMenu(in: view, at: point) }
        view.model = model(now: Date())
        let size = view.intrinsicContentSize
        let panel = UsagePanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        view.frame = NSRect(origin: .zero, size: size)
        scroll.documentView = view
        panel.contentView = scroll

        if let button = statusItem.button, let bw = button.window {
            let r = bw.convertToScreen(button.convert(button.bounds, to: nil))
            panel.setFrameOrigin(NSPoint(x: r.midX - size.width / 2, y: r.minY - size.height - 6))
        }
        self.panel = panel
        popoverView = view
        resizePanel()
        panel.makeKeyAndOrderFront(nil)
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
        let tick = Timer(timeInterval: 60, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.storeChanged() }
        }
        RunLoop.main.add(tick, forMode: .common)
        minuteTick = tick
    }

    private func resizePanel() {
        guard let panel, let view = popoverView else { return }
        let screen = statusItem.button?.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        let height = min(view.intrinsicContentSize.height, screen.height - 12)
        view.setFrameSize(view.intrinsicContentSize)
        var rect = panel.frame
        rect.origin.y += rect.height - height
        rect.size.height = height
        rect.origin.x = min(max(rect.minX, screen.minX + 6), screen.maxX - rect.width - 6)
        rect.origin.y = min(max(rect.minY, screen.minY + 6), screen.maxY - rect.height - 6)
        panel.setFrame(rect, display: true)
    }

    private func closePanel() {
        guard !menuOpen, let panel else { return }
        closedAt = Date()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        minuteTick?.invalidate()
        minuteTick = nil
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
        popoverView = nil
    }

    // MARK: Settings menu (gear)

    private var menuOpen = false

    /// Radio items for the menu-bar display mode, then an Animation submenu. Built on each click.
    private func showSettingsMenu(in view: NSView, at point: NSPoint) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for mode in DisplayMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(pickMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = mode.rawValue
            item.state = mode == store.mode ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let animation = NSMenu(title: "Animation")
        for option in CritterAnimation.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(pickAnimation(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == store.animation ? .on : .off
            animation.addItem(item)
        }
        let submenu = NSMenuItem(title: "Animation", action: nil, keyEquivalent: "")
        submenu.submenu = animation
        menu.addItem(submenu)
        // The panel resigns key while the menu tracks; keep it open until the menu is done.
        menuOpen = true
        menu.popUp(positioning: nil, at: point, in: view)
        menuOpen = false
        if panel?.isKeyWindow == false { panel?.makeKey() }
    }

    @objc private func pickMode(_ sender: NSMenuItem) {
        guard let mode = DisplayMode(rawValue: sender.tag) else { return }
        store.mode = mode
    }

    @objc private func pickAnimation(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let animation = CritterAnimation(rawValue: raw) else { return }
        store.animation = animation
        applyAnimationSetting()
    }

    // MARK: Model

    private func model(now: Date) -> PopoverModel {
        var m = PopoverModel()
        m.subtitle = "AVAILABLE NOW (EST.)  " + Format.percent(AvailableNow.share(rows: store.rows.map(\.usage)))
        let claudeIndices = store.rows.indices.filter { store.rows[$0].provider == "CLAUDE" && store.rows[$0].usage.isConfigured }
        var sections: [PopoverModel.Section] = []
        for provider in ["CODEX", "CLAUDE", "KIMI"] {
            if provider == "CLAUDE" {
                guard !claudeIndices.isEmpty else { continue }
                sections.append(PopoverModel.Section(
                    label: "CLAUDE",
                    subtitle: Pool.summary(accounts: claudeIndices.map { store.rows[$0].usage }).map { ("EST. POOL", $0) },
                    accounts: claudeIndices.map { i in
                        let usage = store.rows[i].usage
                        return PopoverModel.Account(name: store.rows[i].title,
                            note: usage.error == nil ? burnLabel(row: i, now: now) : nil,
                            tag: tag(usage), bars: bars(usage, now: now))
                    }
                ))
            } else if let i = store.rows.firstIndex(where: { $0.provider == provider && $0.usage.isConfigured }) {
                sections.append(section(provider, row: i, now: now))
            }
        }
        m.sections = sections
        m.refreshing = store.isRefreshing
        if store.isRefreshing {
            m.footer = "UPDATING…"
        } else if let updatedAt = store.updatedAt {
            let minutes = Int(now.timeIntervalSince(updatedAt) / 60)
            m.footer = minutes < 1 ? "UPDATED JUST NOW" : "UPDATED \(minutes)M AGO"
        } else {
            m.footer = "NOT UPDATED"
        }
        return m
    }

    private func section(_ label: String, row: Int, now: Date) -> PopoverModel.Section {
        let usage = store.rows[row].usage
        return PopoverModel.Section(
            label: label,
            tag: tag(usage),
            note: usage.error == nil ? burnLabel(row: row, now: now) : nil,
            bars: bars(usage, now: now)
        )
    }

    /// Error (uppercased by the view), or "loading" until the first fetch lands.
    private func tag(_ usage: RowUsage) -> String? {
        usage.error ?? (usage.windows.isEmpty ? "loading" : nil)
    }

    private func bars(_ usage: RowUsage, now: Date) -> PopoverModel.Bars {
        guard usage.error == nil else { return PopoverModel.Bars() }
        let bars = usage.windows.map { w in
            PopoverModel.Bar(
                label: w.label,
                fraction: w.percentLeft / 100,
                low: w.percentLeft < 20,
                percent: String(format: "%02d%%", Int(w.percentLeft.rounded()))
            )
        }
        return PopoverModel.Bars(bars: bars, reset: ResetFormat.line(for: usage.windows, now: now))
    }

    private func burnLabel(row: Int, now: Date) -> String? {
        BurnRate.label(usage: store.rows[row].usage, history: { store.samples(row: row, index: $0) }, now: now)
    }

    /// Renders the popover view in light and dark mode to PNGs at 2x, then exits.
    private func snapshot(to dir: String) async {
        while store.updatedAt == nil { try? await Task.sleep(for: .milliseconds(200)) }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = PopoverView()
            view.appearance = NSAppearance(named: appearance)
            view.model = model(now: Date())
            view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            rep.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("screenshot-\(name).png"))
        }
        // Documentation assets are rendered from demo data, never captured from the desktop.
        let url = URL(fileURLWithPath: dir)
        var frames: [CGImage] = []
        for critter in CritterAnimation.eating.frames {
            let image = NSImage(size: NSSize(width: 86, height: 24))
            image.lockFocus()
            hexColor(0xFAF9F5).setFill()
            NSRect(x: 0, y: 0, width: 86, height: 24).fill()
            critter.draw(in: NSRect(x: 6, y: 4, width: 22, height: 16))
            NSAttributedString(string: "59%", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.black]).draw(at: NSPoint(x: 34, y: 5))
            image.unlockFocus()
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { frames.append(cg) }
        }
        if let first = frames.first {
            let rep = NSBitmapImageRep(cgImage: first)
            try? rep.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("menubar.png"))
        }
        if let gif = CGImageDestinationCreateWithURL(url.appendingPathComponent("animation.gif") as CFURL, "com.compuserve.gif" as CFString, frames.count, nil) {
            CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            for frame in frames { CGImageDestinationAddImage(gif, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.5]] as CFDictionary) }
            CGImageDestinationFinalize(gif)
        }
        exit(0)
    }

    /// Bench hooks: SIGUSR1 toggles the popover, SIGUSR2 refreshes.
    private var signalSources: [DispatchSourceSignal] = []
    private func installBenchSignals() {
        let actions: [(Int32, () -> Void)] = [
            (SIGUSR1, { [weak self] in self?.togglePopover() }),
            (SIGUSR2, { [weak self] in self?.store.refresh() }),
        ]
        for (sig, action) in actions {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { action() }
            src.resume()
            signalSources.append(src)
        }
    }
}

struct Row {
    let id: String
    let provider: String
    let title: String
    var usage: RowUsage
}

@MainActor
final class Store {
    static let demo = ProcessInfo.processInfo.environment["TOKENSPENDER_DEMO"] != nil
    private(set) var snapshot = UsageSnapshot(codex: RowUsage(), kimi: .notConfigured)
    var rows: [Row] {
        [Row(id: "codex/" + (snapshot.codex.identity ?? "unknown"), provider: "CODEX", title: "Codex", usage: snapshot.codex)] +
        snapshot.claude.map { Row(id: $0.id, provider: "CLAUDE", title: $0.email, usage: $0.usage) } +
        [Row(id: "kimi/" + (snapshot.kimi.identity ?? "unknown"), provider: "KIMI", title: "Kimi", usage: snapshot.kimi)]
    }
    private(set) var updatedAt: Date?
    private(set) var isRefreshing = false
    var mode = (UserDefaults.standard.object(forKey: "displayMode.v2") as? Int).flatMap(DisplayMode.init) ?? .availableNow {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "displayMode.v2"); onChange?() }
    }
    var animation = CritterAnimation(rawValue: UserDefaults.standard.string(forKey: "animation.v2") ?? "") ?? .eating {
        didSet { UserDefaults.standard.set(animation.rawValue, forKey: "animation.v2") }
    }
    var onChange: (() -> Void)?
    private var history = SampleHistory()
    private var timer: Timer?

    private func key(row: Row, index: Int) -> String {
        let w = row.usage.windows[index]
        return "\(row.id)/\(index)/\(w.label)/\(w.resetsAt?.timeIntervalSince1970 ?? 0)"
    }
    func samples(row: Int, index: Int) -> [UsageSample] { history.samples(key(row: rows[row], index: index)) }

    func start() {
        if Self.demo { return loadDemo() }
        let timer = Timer(timeInterval: 300, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func refresh() {
        guard !isRefreshing, !Self.demo else { return }
        isRefreshing = true
        onChange?()
        Task {
            snapshot = await Fetcher.fetchAll()
            let now = Date()
            var keys: Set<String> = []
            for row in rows where row.usage.error == nil {
                for (index, window) in row.usage.windows.enumerated() {
                    let k = key(row: row, index: index)
                    keys.insert(k)
                    // Without a source timestamp cswap may be cached: no invented fresh observations.
                    guard let at = row.usage.observedAt, at <= now else { continue }
                    history.append(k, UsageSample(at: at, percentLeft: window.percentLeft))
                }
            }
            history.retain(keys: keys, now: now)
            updatedAt = now
            isRefreshing = false
            onChange?()
        }
    }

    private func loadDemo() {
        let now = Date()
        func window(_ label: String, _ left: Double, _ minutes: Double) -> UsageWindow {
            UsageWindow(label: label, percentLeft: left, resetsAt: now.addingTimeInterval(minutes * 60))
        }
        snapshot = UsageSnapshot(
            codex: RowUsage(windows: [window("WK", 73, 5 * 1440 + 20 * 60)]),
            claude: [
                ClaudeAccount(slot: 1, email: "you@example.com", usage: RowUsage(windows: [window("5H", 42, 228), window("WK", 95, 6 * 1440 + 21 * 60)])),
                ClaudeAccount(slot: 2, email: "work@example.com", usage: RowUsage(windows: [window("5H", 88, 72), window("WK", 61, 2 * 1440 + 3 * 60)]))
            ], kimi: .notConfigured)
        for (minutesAgo, left) in [(30.0, 61.09), (15.0, 51.545), (0.0, 42.0)] {
            history.append(key(row: rows[1], index: 0), UsageSample(at: now.addingTimeInterval(-minutesAgo * 60), percentLeft: left))
        }
        updatedAt = now
        onChange?()
    }
}
