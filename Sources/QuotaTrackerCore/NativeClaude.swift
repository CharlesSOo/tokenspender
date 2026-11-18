import Foundation
import CryptoKit

/// Read-only Claude Code OAuth integration. Parsing/path conventions adapted from CodexBar (MIT).
/// Never refreshes, persists, logs, or exports credentials; Claude Code owns login and renewal.
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

    /// Every Claude Code config profile: default first, then the environment's profile and each
    /// `~/.claude-*` directory containing `.claude.json`, deduped and sorted.
    static func profiles(environment: [String: String], home: String, entries: [String],
                         hasConfig: (String) -> Bool) -> [String] {
        var paths = Set<String>()
        let env = environmentProfile(environment)
        if !env.isEmpty { paths.insert(env) }
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
        struct Organization: Decodable { let uuid: UUID }
        let account: Account
        let organization: Organization
    }

    static func account(profile data: Data, usage: RowUsage, label: String = "~/.claude") throws -> ClaudeAccount {
        guard let profile = try? JSONDecoder().decode(Profile.self, from: data) else { throw Failure.profile }
        return ClaudeAccount(profile: label, email: profile.account.email ?? "Claude Code", usage: usage,
                             id: "claude/\(profile.account.uuid.uuidString.lowercased())/\(profile.organization.uuid.uuidString.lowercased())")
    }

    private struct Usage: Decodable {
        struct Window: Decodable { let utilization: Double?; let resets_at: String? }
        let five_hour: Window?
        let seven_day: Window?
    }

    static func usage(_ data: Data, now: Date = Date()) throws -> RowUsage {
        guard let usage = try? JSONDecoder().decode(Usage.self, from: data) else { throw Failure.usage }
        let windows = [("5H", usage.five_hour), ("WK", usage.seven_day)].compactMap { label, value -> UsageWindow? in
            guard let used = value?.utilization, used.isFinite else { return nil }
            return UsageWindow(label: label, percentLeft: Parse.left(used), resetsAt: value?.resets_at.flatMap(Parse.date))
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
        catch { throw (error as? URLError)?.code == .timedOut ? Failure.timeout : Failure.network }
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
        ClaudeAccount(profile: label, email: label, usage: .failure(error.rawValue))
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

    /// Keychain reads stay serialized on keychainQueue; network fetches run concurrently.
    static func fetch(profiles: [String], home: String,
                      load: @escaping @Sendable (String) async -> Result<Credential, Failure>,
                      transport: @escaping @Sendable (URLRequest) async throws -> Data) async -> [ClaudeAccount] {
        let rows = await withTaskGroup(of: (Int, [ClaudeAccount]).self) { group in
            for (index, profile) in profiles.enumerated() {
                group.addTask {
                    (index, await fetch(credential: load(profile), label: label(profile: profile, home: home), transport: transport))
                }
            }
            var rows = [[ClaudeAccount]](repeating: [], count: profiles.count)
            for await (index, accounts) in group { rows[index] = accounts }
            return rows
        }
        return merge(rows)
    }

    public static func fetch() async -> [ClaudeAccount] {
        let home = NSHomeDirectory()
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
        let list = profiles(environment: ProcessInfo.processInfo.environment, home: home, entries: entries) {
            FileManager.default.fileExists(atPath: $0 + "/.claude.json")
        }
        return await fetch(profiles: list, home: home, load: { await load(profile: $0) },
                           transport: { try await send($0) })
    }
}
