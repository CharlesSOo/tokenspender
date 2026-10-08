import Foundation
import Darwin

/// Direct providers are read-only. cswap owns Claude credentials and may refresh them itself.
public enum Fetcher {
    public static func fetchAll(authorizeClaude: Bool = false) async -> UsageSnapshot {
        async let codex = DirectSources.codex()
        async let claude = claudeAccounts(authorizeNative: authorizeClaude)
        async let kimi = DirectSources.kimi()
        return UsageSnapshot(codex: hideIfMissing(await codex), claude: await claude, kimi: hideIfMissing(await kimi))
    }

    private static func hideIfMissing(_ row: RowUsage) -> RowUsage {
        row.error == "not logged in" ? .notConfigured : row
    }

    /// Missing/empty managed metadata means native Claude, regardless of whether cswap is installed.
    /// Present but unreadable metadata or any managed fetch failure must never select a different login.
    static func claudeAccounts(metadata: Result<Data, DirectSources.CredentialError>,
                               managed: () async -> Data?, native: () async -> [ClaudeAccount]) async -> [ClaudeAccount] {
        struct Sequence: Decodable { let accounts: [String: Entry] }
        struct Entry: Decodable { let email: String }
        let data: Data
        switch metadata {
        case .failure(.missing): return await native()
        case .failure: return claudeFailure("cswap metadata unreadable")
        case .success(let value): data = value
        }
        guard let sequence = try? JSONDecoder().decode(Sequence.self, from: data) else {
            return claudeFailure("cswap metadata unreadable")
        }
        if sequence.accounts.isEmpty { return await native() }
        guard let output = await managed(), let accounts = Parse.cswap(output, metadata: data), !accounts.isEmpty else {
            return claudeFailure("cswap unavailable")
        }
        return accounts
    }

    private static func claudeFailure(_ message: String) -> [ClaudeAccount] {
        [ClaudeAccount(slot: 0, email: "Managed Claude accounts", usage: .failure(message))]
    }

    static func claudeAccounts(authorizeNative: Bool = false) async -> [ClaudeAccount] {
        let path = NSHomeDirectory() + "/.claude-swap-backup/sequence.json"
        return await claudeAccounts(metadata: DirectSources.readFile(path), managed: {
            await run(NSHomeDirectory() + "/.local/bin/cswap", ["list", "--json"])
        }, native: {
            await NativeClaude.fetch(authorize: authorizeNative)
        })
    }

    /// Off-main, bounded output and wall time. Spawn into a separate process group so descendants
    /// holding stdout cannot hang the reader. Timer is cancelled before scope exit; direct child reaped.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 30, maxOutput: Int = 1_048_576) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking(path, args, timeout: timeout, maxOutput: maxOutput))
            }
        }
    }

    private static func runBlocking(_ path: String, _ args: [String], timeout: TimeInterval, maxOutput: Int) -> Data? {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        defer { close(fds[0]); close(fds[1]) }
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[0], F_SETFL, O_NONBLOCK)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addclose(&actions, fds[0])
        posix_spawn_file_actions_addclose(&actions, fds[1])
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([path] + args).map { strdup($0) } + [nil]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = NSHomeDirectory() + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { a in
            envp.withUnsafeBufferPointer { e in
                posix_spawn(&pid, path, &actions, &attributes, UnsafeMutablePointer(mutating: a.baseAddress!), UnsafeMutablePointer(mutating: e.baseAddress!))
            }
        }
        guard result == 0 else { return nil }
        close(fds[1]); fds[1] = -1
        let state = ChildDeadline(pid: pid)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { state.expire() }
        timer.resume()
        defer { timer.cancel(); state.finish() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        var success = true
        while !state.expired {
            var descriptor = pollfd(fd: fds[0], events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = poll(&descriptor, 1, 50)
            if ready < 0 { if errno == EINTR { continue }; success = false; break }
            if ready == 0 { continue }
            let count = read(fds[0], &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EAGAIN || errno == EINTR { continue }; success = false; break }
            guard data.count + count <= maxOutput else { success = false; break }
            data.append(contentsOf: buffer.prefix(count))
        }
        // Never wait unbounded after EOF: the process can close stdout then hang.
        var status: Int32 = 0
        while success && !state.expired {
            if let completed = state.reapIfExited() { return completed == 0 ? data : nil }
            _ = poll(nil, 0, 10)
        }
        state.finish() // disable timer and kill group BEFORE reaping; never signal a recycled PID
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        return nil
    }
}

/// Synchronizes timeout cancellation with group cleanup. Child remains unreaped until output closes,
/// so its PID/group cannot be reused while the deadline still targets it.
private final class ChildDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private let pid: pid_t
    private var timedOut = false
    private var active = true
    init(pid: pid_t) { self.pid = pid }
    var expired: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
    func expire() {
        lock.lock(); defer { lock.unlock() }
        if active { timedOut = true; kill(-pid, SIGKILL) }
    }
    func reapIfExited() -> Int32? {
        lock.lock(); defer { lock.unlock() }
        var info = siginfo_t()
        guard waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0,
              info.si_pid == pid else { return nil }
        // WNOWAIT leaves the zombie reserving its PID while group cleanup/deadline cancellation run.
        if active { kill(-pid, SIGKILL); active = false }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        return status
    }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        if active { kill(-pid, SIGKILL); active = false }
    }
}
