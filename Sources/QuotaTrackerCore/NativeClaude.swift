import Foundation
import CryptoKit

/// Read-only Claude Code OAuth integration. Parsing/path conventions adapted from CodexBar (MIT).
/// Never writes, persists, logs, or exports credentials; Claude Code owns login and renewal. An expired
/// login is renewed by running Claude Code itself (`claude -p /usage`, no model call) for that folder.
public enum NativeClaude {
    enum Failure: String, Error {
        case missing = "not logged in"
        case malformed = "Claude auth unreadable"
        case expired = "expired — log in Claude"
        case keychain = "Keychain unavailable"
        case profile = "profile unavailable"
        case unsupportedProfile = "unsupported profile path"
        case usage = "usage unavailable"
        case network = "network error"
        case timeout = "timed out"
        case rateLimited = "rate limited"
        case forbidden = "Claude access denied"

        /// Offline, timeouts, 5xx and 429; auth and credential failures are not.
        var isTransient: Bool { [.network, .timeout, .rateLimited].contains(self) }
    }

    struct Location: Equatable {
        let service: String
        let account: String
        let file: String
    }

    /// The profile string Claude Code would use for this environment; "" is the default profile.
    static func environmentProfile(_ environment: [String: String]) -> String {
        environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] ?? environment["CLAUDE_CONFIG_DIR"] ?? ""
    }

    /// Claude hashes the raw, NFC-normalized profile string, not its resolved filesystem path.
    /// Relative paths are deliberately unsupported: a login item's CWD is not Claude Code's CWD.
    static func location(environment: [String: String], home: String, username: String) throws -> Location {
        try location(profile: environmentProfile(environment), environment: environment, home: home, username: username)
    }

    static func location(profile: String, environment: [String: String], home: String, username: String) throws -> Location {
        guard profile.isEmpty || profile.hasPrefix("/") else { throw Failure.unsupportedProfile }
        let suffix = profile.isEmpty ? "" : "-" + SHA256.hash(data: Data(profile.precomposedStringWithCanonicalMapping.utf8))
            .prefix(4).map { String(format: "%02x", $0) }.joined()
        return Location(service: "Claude Code-credentials" + suffix,
                        account: environment["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? username,
                        file: (profile.isEmpty ? home + "/.claude" : profile) + "/.credentials.json")
    }

    /// Every Claude Code config folder: default first, then the environment's profile, each
    /// `~/.claude-*` directory containing `.claude.json` and each user-added folder, deduped and sorted.
    static func profiles(environment: [String: String], home: String, entries: [String], folders: [String] = [],
                         hasConfig: (String) -> Bool) -> [String] {
        var paths = Set<String>()
        let env = environmentProfile(environment)
        if !env.isEmpty { paths.insert(env) }
        for folder in folders {
            let path = folder.count > 1 && folder.hasSuffix("/") ? String(folder.dropLast()) : folder
            if path != home + "/.claude" { paths.insert(path) }
        }
        for name in entries where name.hasPrefix(".claude-") {
            let path = home + "/" + name
            if hasConfig(path) { paths.insert(path) }
        }
        return [""] + paths.sorted()
    }

    /// Row label telling the user which login a profile is ("~/.claude", "~/.claude-me").
    static func label(profile: String, home: String) -> String {
        let path = profile.isEmpty ? home + "/.claude" : profile
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    struct Credential {
        let access: String
    }
    private struct Auth: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let expiresAt: Double
        }
        let claudeAiOauth: OAuth?
    }

    static func credential(_ data: Data, now: Date = Date()) throws -> Credential {
        guard let auth = try? JSONDecoder().decode(Auth.self, from: data) else { throw Failure.malformed }
        guard let oauth = auth.claudeAiOauth else { throw Failure.missing }
        let token = oauth.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, oauth.expiresAt.isFinite, oauth.expiresAt > 0 else { throw Failure.malformed }
        guard oauth.expiresAt / 1000 > now.timeIntervalSince1970 else { throw Failure.expired }
        return Credential(access: token)
    }

    /// Fallback is permitted only for a genuinely absent Keychain item, never denied/locked/broken auth.
    static func loadCredential(location: Location,
                               keychain: (Location) -> Result<Data, Failure>,
                               file: (String) -> Result<Data, Failure>) throws -> Credential {
        let result = keychain(location)
        if case .failure(.missing) = result { return try credential(file(location.file).get()) }
        return try credential(result.get())
    }

    private static let keychainQueue = DispatchQueue(label: "QuotaTracker.claude-keychain", qos: .utility)
    static let keychainTimeout: TimeInterval = 10

    /// Maps `security find-generic-password` exit codes; 44 is errSecItemNotFound.
    static func keychainStatus(exitCode: Int32) -> Failure? {
        switch exitCode {
        case 0: nil
        case 44: .missing
        default: .keychain
        }
    }

    /// Claude Code writes its items with /usr/bin/security, so that tool is on their ACL and reads
    /// them silently, unlike this ad-hoc-signed app whose identity changes on every rebuild.
    private static func readKeychain(_ location: Location) -> Result<Data, Failure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", location.service, "-a", location.account, "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return .failure(.keychain) }
        var data = Data()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            data = (try? stdout.fileHandleForReading.read(upToCount: 1_048_578)) ?? Data()
            reader.leave()
        }
        if done.wait(timeout: .now() + keychainTimeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 1)
            return .failure(.timeout)
        }
        _ = reader.wait(timeout: .now() + 1)
        if let failure = keychainStatus(exitCode: process.terminationStatus) { return .failure(failure) }
        if data.last == UInt8(ascii: "\n") { data.removeLast() }
        guard data.count <= 1_048_576 else { return .failure(.malformed) }
        return .success(data)
    }

    private static func readFile(_ path: String) -> Result<Data, Failure> {
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 1_048_577) ?? Data()
            return data.count <= 1_048_576 ? .success(data) : .failure(.malformed)
        } catch let error as NSError {
            return .failure(error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError ? .missing : .malformed)
        }
    }

    private static func load(profile: String) async -> Result<Credential, Failure> {
        await withCheckedContinuation { continuation in
            keychainQueue.async {
                do {
                    let location = try location(profile: profile, environment: ProcessInfo.processInfo.environment,
                                                home: NSHomeDirectory(), username: NSUserName())
                    let credential = try loadCredential(location: location, keychain: readKeychain, file: readFile)
                    continuation.resume(returning: .success(credential))
                } catch { continuation.resume(returning: .failure(error as? Failure ?? .malformed)) }
            }
        }
    }

    private struct Profile: Decodable {
        struct Account: Decodable { let uuid: UUID; let email: String? }
        struct Organization: Decodable { let uuid: UUID; let plan_display_name: String? }
        let account: Account
        let organization: Organization
    }

    static func account(profile data: Data, usage: RowUsage, label: String = "~/.claude") throws -> ClaudeAccount {
        guard let profile = try? JSONDecoder().decode(Profile.self, from: data) else { throw Failure.profile }
        let plan = profile.organization.plan_display_name.flatMap { $0.isEmpty ? nil : $0 }
        return ClaudeAccount(profile: label, email: profile.account.email ?? "Claude Code", usage: usage,
                             id: "claude/\(profile.account.uuid.uuidString.lowercased())/\(profile.organization.uuid.uuidString.lowercased())",
                             plan: plan)
    }

    private struct Usage: Decodable {
        struct Window: Decodable { let utilization: Double?; let resets_at: String? }
        /// The server's list of meters that apply: `session`, `weekly_all`, `weekly_scoped` (per model).
        struct Limit: Decodable {
            struct Scope: Decodable { struct Model: Decodable { let display_name: String? }; let model: Model? }
            let kind: String?; let percent: Double?; let resets_at: String?; let scope: Scope?
        }
        let five_hour: Window?
        let seven_day: Window?
        let limits: [Limit]?
    }

    /// Windows come only from the server's `limits` (a plan without a 5-hour limit has no `session`);
    /// `five_hour`/`seven_day` are used only when `limits` is absent.
    static func usage(_ data: Data, now: Date = Date()) throws -> RowUsage {
        guard let usage = try? JSONDecoder().decode(Usage.self, from: data) else { throw Failure.usage }
        let windows: [UsageWindow]
        if let limits = usage.limits {
            windows = limits.compactMap { limit -> UsageWindow? in
                guard let used = limit.percent, used.isFinite else { return nil }
                let label: String
                switch limit.kind {
                case "session": label = "5H"
                case "weekly_all": label = "WK"
                case "weekly_scoped":
                    guard let name = limit.scope?.model?.display_name, !name.isEmpty else { return nil }
                    label = name.uppercased()
                default: return nil
                }
                return UsageWindow(label: label, percentLeft: Parse.left(used), resetsAt: limit.resets_at.flatMap(Parse.date))
            }
        } else {
            windows = [("5H", usage.five_hour), ("WK", usage.seven_day)].compactMap { label, value -> UsageWindow? in
                guard let used = value?.utilization, used.isFinite else { return nil }
                return UsageWindow(label: label, percentLeft: Parse.left(used), resetsAt: value?.resets_at.flatMap(Parse.date))
            }
        }
        guard !windows.isEmpty else { throw Failure.usage }
        return RowUsage(windows: windows, observedAt: now)
    }

    /// Fixed provider endpoints only; never follow a redirect carrying a credential to another endpoint.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = DirectSources.timeout
        config.timeoutIntervalForResource = DirectSources.timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    static func request(_ endpoint: String, credential: Credential) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/" + endpoint)!, timeoutInterval: DirectSources.timeout)
        req.setValue("Bearer " + credential.access, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
        return req
    }

    static func response(_ data: Data, status: Int) throws -> Data {
        switch status {
        case 200: return data
        case 401: throw Failure.expired
        case 403: throw Failure.forbidden
        case 429: throw Failure.rateLimited
        default: throw Failure.network
        }
    }

    private static func send(_ req: URLRequest) async throws -> Data {
        do {
            let (data, result) = try await session.data(for: req)
            return try response(data, status: (result as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let failure as Failure { throw failure }
        catch {
            guard DirectSources.isTransient(error) else { throw Failure.usage }
            throw (error as? URLError)?.code == .timedOut ? Failure.timeout : Failure.network
        }
    }

    static func fetch(credential: Result<Credential, Failure>, label: String = "~/.claude",
                      transport: (URLRequest) async throws -> Data) async -> [ClaudeAccount] {
        do {
            let credential = try credential.get()
            // The same token authenticates profile and usage. Never trust ~/.claude.json attribution.
            let profile = try await transport(request("profile", credential: credential))
            var account = try account(profile: profile, usage: RowUsage(), label: label)
            do { account.usage = try usage(await transport(request("usage", credential: credential))) }
            catch { account.usage = failure(error as? Failure ?? .network, label: label).usage }
            return [account]
        } catch {
            let failure = error as? Failure ?? .network
            return failure == .missing ? [] : [self.failure(failure, label: label)]
        }
    }

    private static func failure(_ error: Failure, label: String) -> ClaudeAccount {
        ClaudeAccount(profile: label, email: label, usage: .failure(error.rawValue, transient: error.isTransient))
    }

    /// Profile order is kept; a verified account seen in several profiles keeps one row,
    /// preferring a successful one. Unverified (failure) rows are always kept.
    static func merge(_ rows: [[ClaudeAccount]]) -> [ClaudeAccount] {
        var result: [ClaudeAccount] = []
        for account in rows.joined() {
            guard let id = account.id, let index = result.firstIndex(where: { $0.id == id }) else {
                result.append(account); continue
            }
            if result[index].usage.error != nil && account.usage.error == nil { result[index] = account }
        }
        return result
    }

    /// One folder's row. An expired login (past `expiresAt` or HTTP 401) is renewed through the refresher,
    /// then the Keychain is read again; if it still fails the row carries a hint naming the folder.
    static func fetch(profile: String, home: String, refresher: Refresher,
                      load: @escaping @Sendable (String) async -> Result<Credential, Failure>,
                      transport: @escaping @Sendable (URLRequest) async throws -> Data) async -> [ClaudeAccount] {
        let label = label(profile: profile, home: home)
        let expired = Failure.expired.rawValue
        var rows = await fetch(credential: load(profile), label: label, transport: transport)
        if rows.first?.usage.error == expired, await refresher.refresh(profile) {
            rows = await fetch(credential: load(profile), label: label, transport: transport)
        }
        if rows.first?.usage.error == expired { rows[0].usage.hint = "run claude in \(label)" }
        return rows
    }

    /// Keychain reads stay serialized on keychainQueue; network fetches run concurrently.
    static func fetch(profiles: [String], home: String, refresher: Refresher,
                      load: @escaping @Sendable (String) async -> Result<Credential, Failure>,
                      transport: @escaping @Sendable (URLRequest) async throws -> Data) async -> [ClaudeAccount] {
        let rows = await withTaskGroup(of: (Int, [ClaudeAccount]).self) { group in
            for (index, profile) in profiles.enumerated() {
                group.addTask {
                    (index, await fetch(profile: profile, home: home, refresher: refresher, load: load, transport: transport))
                }
            }
            var rows = [[ClaudeAccount]](repeating: [], count: profiles.count)
            for await (index, accounts) in group { rows[index] = accounts }
            return rows
        }
        return merge(rows)
    }

    static let refresher = Refresher { await runClaude(profile: $0) }

    /// `folders`: user-added config folders, on top of the auto-detected ones.
    public static func fetch(folders: [String] = []) async -> [ClaudeAccount] {
        let home = NSHomeDirectory()
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
        let list = profiles(environment: ProcessInfo.processInfo.environment, home: home, entries: entries, folders: folders) {
            FileManager.default.fileExists(atPath: $0 + "/.claude.json")
        }
        return await fetch(profiles: list, home: home, refresher: refresher, load: { await load(profile: $0) },
                           transport: { try await send($0) })
    }

    // MARK: - Renewal through Claude Code

    /// Runs the injected renewal at most once per folder per `interval`.
    actor Refresher {
        static let interval: TimeInterval = 600
        private let runner: @Sendable (String) async -> Void
        private let now: @Sendable () -> Date
        private var lastRun: [String: Date] = [:]

        init(now: @escaping @Sendable () -> Date = { Date() }, runner: @escaping @Sendable (String) async -> Void) {
            self.now = now
            self.runner = runner
        }

        /// False when throttled (nothing was run).
        func refresh(_ profile: String) async -> Bool {
            let time = now()
            if let last = lastRun[profile], time.timeIntervalSince(last) < Self.interval { return false }
            lastRun[profile] = time
            await runner(profile)
            return true
        }
    }

    static let refreshTimeout: TimeInterval = 20

    /// `claude -p /usage` makes no model call but renews the folder's login the way Claude Code always does.
    /// The default folder gets no `CLAUDE_CONFIG_DIR`; output is discarded.
    static func runClaude(profile: String) async {
        guard let claude = await claudePath() else { return }
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CONFIG_DIR"] = profile.isEmpty ? nil : profile
        _ = await run(claude, ["-p", "/usage", "--output-format", "json"], environment: environment, timeout: refreshTimeout)
    }

    static func claudePath() async -> String? {
        let home = NSHomeDirectory()
        for path in [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            where FileManager.default.isExecutableFile(atPath: path) { return path }
        let output = await run("/bin/zsh", ["-lc", "command -v claude"], environment: ProcessInfo.processInfo.environment,
                               timeout: refreshTimeout, captureOutput: true)
        let path = output.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.hasPrefix("/") ? path : nil
    }

    /// Runs a process off the main thread with stdin closed; terminated after `timeout`.
    /// Returns stdout when captured and the process exited 0.
    private static func run(_ executable: String, _ arguments: [String], environment: [String: String],
                            timeout: TimeInterval, captureOutput: Bool = false) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = environment
                process.standardInput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                let stdout = Pipe()
                process.standardOutput = captureOutput ? stdout : FileHandle.nullDevice
                let done = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in done.signal() }
                do { try process.run() } catch { return continuation.resume(returning: nil) }
                var data: Data?
                let reader = DispatchGroup()
                if captureOutput {
                    reader.enter()
                    DispatchQueue.global(qos: .utility).async {
                        data = try? stdout.fileHandleForReading.read(upToCount: 65_536)
                        reader.leave()
                    }
                }
                if done.wait(timeout: .now() + timeout) == .timedOut {
                    process.terminate()
                    _ = done.wait(timeout: .now() + 1)
                    return continuation.resume(returning: nil)
                }
                _ = reader.wait(timeout: .now() + 1)
                continuation.resume(returning: process.terminationStatus == 0 ? data : nil)
            }
        }
    }
}
