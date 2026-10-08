import CoreServices
import Foundation

/// FSEvents JSONL writes are an activity proxy, never proof of token consumption.
@MainActor
final class SessionLogActivity {
    private(set) var isBurning = false
    var onChange: (() -> Void)?
    private var stream: FSEventStreamRef?
    private var idleTimer: Timer?
    private let queue = DispatchQueue(label: "so.charles.tokenspender.fsevents", qos: .utility)
    private static let idleSeconds: TimeInterval = 8
    private static let paths = [".claude/projects", ".pi/agent/sessions", ".codex/sessions"]
        .map { NSHomeDirectory() + "/" + $0 }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            let paths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            var touched = false
            for i in 0..<count where flags[i] & UInt32(kFSEventStreamEventFlagItemIsFile) != 0 {
                let path = String(cString: paths[i])
                if path.hasSuffix(".jsonl") { touched = true; break }
            }
            guard touched, let info else { return }
            let source = Unmanaged<SessionLogActivity>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in source.noteWrite() }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, Self.paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        idleTimer?.invalidate()
        idleTimer = nil
        set(burning: false)
    }

    private func noteWrite() {
        guard stream != nil else { return }
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: Self.idleSeconds, repeats: false) { _ in
            Task { @MainActor [weak self] in self?.set(burning: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
        set(burning: true)
    }

    private func set(burning: Bool) {
        guard burning != isBurning else { return }
        isBurning = burning
        if !burning { idleTimer = nil }
        onChange?()
    }
}
