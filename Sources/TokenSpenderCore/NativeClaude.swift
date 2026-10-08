import Foundation
import CryptoKit
import Security
import LocalAuthentication

/// Read-only Claude Code OAuth integration. Parsing/path conventions adapted from CodexBar (MIT).
/// Never refreshes, persists, logs, or exports credentials; Claude Code owns login and renewal.
public enum NativeClaude {
    enum Failure: String, Error {
        case missing = "not logged in"
        case malformed = "Claude auth unreadable"
        case expired = "expired — log in Claude"
        case authorization = "authorize in Settings"
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

    /// Claude hashes the raw, NFC-normalized profile string, not its resolved filesystem path.
    /// Relative paths are deliberately unsupported: a login item's CWD is not Claude Code's CWD.
    static func location(environment: [String: String], home: String, username: String) throws -> Location {
        let profile = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] ?? environment["CLAUDE_CONFIG_DIR"] ?? ""
        guard profile.isEmpty || profile.hasPrefix("/") else { throw Failure.unsupportedProfile }
        let suffix = profile.isEmpty ? "" : "-" + SHA256.hash(data: Data(profile.precomposedStringWithCanonicalMapping.utf8))
            .prefix(4).map { String(format: "%02x", $0) }.joined()
        return Location(service: "Claude Code-credentials" + suffix,
                        account: environment["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? username,
                        file: (profile.isEmpty ? home + "/.claude" : profile) + "/.credentials.json")
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
    static func loadCredential(location: Location, authorize: Bool,
                               keychain: (Location, Bool) -> Result<Data, Failure>,
                               file: (String) -> Result<Data, Failure>) throws -> Credential {
        let result = keychain(location, authorize)
        if case .failure(.missing) = result { return try credential(file(location.file).get()) }
        return try credential(result.get())
    }

    private static let keychainQueue = DispatchQueue(label: "tokenspender.claude-keychain", qos: .utility)

    static func keychainFailure(_ status: OSStatus) -> Failure {
        switch status {
        case errSecItemNotFound: .missing
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled, errSecNoAccessForItem: .authorization
        default: .keychain
        }
    }

    static func keychainQuery(location: Location, authorize: Bool) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = !authorize
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: location.service,
         kSecAttrAccount as String: location.account,
         kSecMatchLimit as String: kSecMatchLimitOne,
         kSecReturnData as String: true,
         kSecUseAuthenticationContext as String: context]
    }

    /// The legacy login Keychain still needs its documented process-level switch (CodexBar's
    /// KeychainLegacyInteraction). Resolve it dynamically because Apple deprecated the legacy API.
    private static func setInteractionAllowed(_ allowed: Bool) -> OSStatus {
        typealias SetInteraction = @convention(c) (DarwinBoolean) -> OSStatus
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY | RTLD_NOLOAD) else { return errSecNotAvailable }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "SecKeychainSetUserInteractionAllowed") else { return errSecNotAvailable }
        return unsafeBitCast(symbol, to: SetInteraction.self)(DarwinBoolean(allowed))
    }

    private static func readKeychain(_ location: Location, authorize: Bool) -> Result<Data, Failure> {
        // Legacy login-keychain ACL dialogs can ignore the per-query no-UI flag. Serialize our only
        // Security.framework reader and disable process-wide interaction unless the user just asked.
        // No ACL changes or access-control bypass: without approval, reads fail and show Settings retry.
        guard setInteractionAllowed(authorize) == errSecSuccess else { return .failure(.keychain) }
        defer { _ = setInteractionAllowed(false) }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(keychainQuery(location: location, authorize: authorize) as CFDictionary, &item)
        guard status == errSecSuccess else { return .failure(keychainFailure(status)) }
        guard let data = item as? Data, data.count <= 1_048_576 else { return .failure(.malformed) }
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

    private static func load(authorize: Bool) async -> Result<Credential, Failure> {
        await withCheckedContinuation { continuation in
            keychainQueue.async {
                do {
                    let location = try location(environment: ProcessInfo.processInfo.environment,
                                                home: NSHomeDirectory(), username: NSUserName())
                    let credential = try loadCredential(location: location, authorize: authorize,
                                                        keychain: readKeychain, file: readFile)
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

    static func account(profile data: Data, usage: RowUsage) throws -> ClaudeAccount {
        guard let profile = try? JSONDecoder().decode(Profile.self, from: data) else { throw Failure.profile }
        return ClaudeAccount(slot: 1, email: profile.account.email ?? "Claude Code", usage: usage,
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

    static func fetch(credential: Result<Credential, Failure>,
                      transport: (URLRequest) async throws -> Data) async -> [ClaudeAccount] {
        do {
            let credential = try credential.get()
            // The same token authenticates profile and usage. Never trust ~/.claude.json attribution.
            let profile = try await transport(request("profile", credential: credential))
            var account = try account(profile: profile, usage: RowUsage())
            do { account.usage = try usage(await transport(request("usage", credential: credential))) }
            catch { account.usage = failure(error as? Failure ?? .network).usage }
            return [account]
        } catch {
            let failure = error as? Failure ?? .network
            return failure == .missing ? [] : [self.failure(failure)]
        }
    }

    private static func failure(_ error: Failure) -> ClaudeAccount {
        var usage = RowUsage.failure(error.rawValue)
        usage.needsClaudeAuthorization = error == .authorization || error == .keychain
        return ClaudeAccount(slot: 0, email: "Claude Code", usage: usage)
    }

    public static func fetch(authorize: Bool = false) async -> [ClaudeAccount] {
        await fetch(credential: load(authorize: authorize), transport: send)
    }
}
