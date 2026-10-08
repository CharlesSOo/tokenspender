import Foundation
import CryptoKit

/// Direct usage fetchers for Codex and Kimi that bypass CodexBarCLI.
///
/// Credentials are read-only and never logged:
/// - Codex: `~/.codex/auth.json` (Codex CLI's own token; carries `account_id`). Pi's `openai`
///   OAuth token is a ChatGPT-for-API token without `chatgpt_account_id` and is rejected by
///   `wham/usage` with 401 `rejected_by_access_enforcement`, so it cannot be used here.
/// - Kimi: `~/.pi/agent/auth.json` key `kimi-coding` (Pi owns refresh; expired → "expired").
public enum DirectSources {
    public static var piAuthPath = NSHomeDirectory() + "/.pi/agent/auth.json"
    public static var codexAuthPath = NSHomeDirectory() + "/.codex/auth.json"
    static let timeout: TimeInterval = 20
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    // MARK: - Credentials

    struct Credential: Equatable {
        let access: String
        let expires: Date?
        var accountId: String?
    }

    enum CredentialError: Error, Equatable {
        case unreadable, missing, expired
        var message: String {
            switch self {
            case .unreadable: return "auth.json unreadable"
            case .missing: return "not logged in"
            case .expired: return "expired"
            }
        }
    }

    private struct PiAuth: Decodable {
        struct Entry: Decodable {
            let type: String
            let access: String?
            let expires: Double?
        }
        let entries: [String: Entry]
        init(from decoder: Decoder) throws {
            // Tolerate non-OAuth entries (e.g. api_key) by decoding leniently per key.
            let c = try decoder.singleValueContainer()
            let raw = try c.decode([String: LenientEntry].self)
            entries = raw.compactMapValues(\.entry)
        }
        private struct LenientEntry: Decodable {
            let entry: Entry?
            init(from decoder: Decoder) throws { entry = try? Entry(from: decoder) }
        }
    }

    /// Pi `auth.json`: `{ "<key>": { type: "oauth", access, refresh, expires(ms epoch) } }`.
    static func piCredential(_ key: String, authJSON: Data, now: Date = Date()) -> Result<Credential, CredentialError> {
        guard let auth = try? JSONDecoder().decode(PiAuth.self, from: authJSON) else { return .failure(.unreadable) }
        guard let e = auth.entries[key], e.type == "oauth", let access = e.access, !access.isEmpty else { return .failure(.missing) }
        let expires = e.expires.map { Date(timeIntervalSince1970: $0 / 1000) }
        if let expires, expires <= now { return .failure(.expired) }
        return .success(Credential(access: access, expires: expires))
    }

    private struct CodexAuth: Decodable {
        struct Tokens: Decodable {
            let access_token: String
            let account_id: String?
        }
        let tokens: Tokens?
    }

    /// Codex CLI `auth.json`: `{ tokens: { access_token, account_id, ... } }`; expiry from the JWT `exp` claim.
    static func codexCredential(authJSON: Data, now: Date = Date()) -> Result<Credential, CredentialError> {
        guard let auth = try? JSONDecoder().decode(CodexAuth.self, from: authJSON) else { return .failure(.unreadable) }
        guard let t = auth.tokens, !t.access_token.isEmpty else { return .failure(.missing) }
        let claims = jwtClaims(t.access_token)
        let expires = (claims?["exp"] as? Double).map { Date(timeIntervalSince1970: $0) }
        if let expires, expires <= now { return .failure(.expired) }
        let accountId = t.account_id
            ?? (claims?["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String
        return .success(Credential(access: t.access_token, expires: expires, accountId: accountId))
    }

    /// Decodes a JWT payload (base64url, no signature check).
    static func jwtClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Codex: GET https://chatgpt.com/backend-api/wham/usage

    private struct CodexUsage: Decodable {
        struct Window: Decodable {
            let used_percent: Double?
            let limit_window_seconds: Int?
            let reset_after_seconds: Double?
            let reset_at: Double?
        }
        struct RateLimit: Decodable {
            let primary_window: Window?
            let secondary_window: Window?
        }
        let rate_limit: RateLimit?
    }

    public static func parseCodex(_ data: Data, now: Date = Date()) -> RowUsage {
        guard let usage = try? JSONDecoder().decode(CodexUsage.self, from: data) else { return .failure("Unreadable usage response") }
        let windows = [usage.rate_limit?.primary_window, usage.rate_limit?.secondary_window].compactMap { w -> UsageWindow? in
            guard let w, let used = w.used_percent else { return nil }
            let label = (w.limit_window_seconds ?? 0) > 86400 ? "WK" : "5H"
            let reset = w.reset_at.map { Date(timeIntervalSince1970: $0) } ?? w.reset_after_seconds.map { now.addingTimeInterval($0) }
            return UsageWindow(label: label, percentLeft: Parse.left(used), resetsAt: reset)
        }
        return windows.isEmpty ? .failure("No usage windows") : RowUsage(windows: windows)
    }

    public static func codex() async -> RowUsage {
        let cred: Credential
        switch readFile(codexAuthPath).flatMap({ codexCredential(authJSON: $0) }) {
        case .failure(let e): return .failure(e.message)
        case .success(let c): cred = c
        }
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!, timeoutInterval: timeout)
        req.setValue("Bearer \(cred.access)", forHTTPHeaderField: "Authorization")
        if let id = cred.accountId { req.setValue(id, forHTTPHeaderField: "ChatGPT-Account-Id") }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        var row = await fetch(req, parse: { parseCodex($0) })
        row.observedAt = Date()
        row.identity = cred.accountId ?? SHA256.hash(data: Data(cred.access.utf8)).description
        return row
    }

    // MARK: - Kimi: GET https://api.kimi.com/coding/v1/usages (ported from CodexBar KimiUsageFetcher.fetchCodeAPIUsage)

    private struct KimiUsage: Decodable {
        struct Pool: Decodable {
            let used_ratio: Double?
            let reset_time: String?
        }
        struct Pools: Decodable {
            let limit_5h: Pool?
            let limit_7d: Pool?
        }
        let usages: Pools?
    }

    public static func parseKimi(_ data: Data) -> RowUsage {
        guard let usage = try? JSONDecoder().decode(KimiUsage.self, from: data) else { return .failure("Unreadable usage response") }
        let windows = [("5H", usage.usages?.limit_5h), ("WK", usage.usages?.limit_7d)].compactMap { label, p -> UsageWindow? in
            guard let p, let ratio = p.used_ratio, ratio.isFinite, ratio >= 0 else { return nil }
            return UsageWindow(label: label, percentLeft: Parse.left(min(1, ratio) * 100), resetsAt: p.reset_time.flatMap(Parse.date))
        }
        return windows.isEmpty ? .failure("No usage windows") : RowUsage(windows: windows)
    }

    public static func kimi() async -> RowUsage {
        let cred: Credential
        switch readFile(piAuthPath).flatMap({ piCredential("kimi-coding", authJSON: $0) }) {
        case .failure(let e): return .failure(e.message)
        case .success(let c): cred = c
        }
        var req = URLRequest(url: URL(string: "https://api.kimi.com/coding/v1/usages")!, timeoutInterval: timeout)
        req.setValue("Bearer \(cred.access)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        var row = await fetch(req, parse: parseKimi)
        row.observedAt = Date()
        row.identity = SHA256.hash(data: Data(cred.access.utf8)).description
        return row
    }

    // MARK: - helpers

    static func readFile(_ path: String) -> Result<Data, CredentialError> {
        do { return .success(try Data(contentsOf: URL(fileURLWithPath: path))) }
        catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return .failure(.missing) }
            return .failure(.unreadable)
        }
    }

    private static func fetch(_ req: URLRequest, parse: (Data) -> RowUsage) async -> RowUsage {
        let data: Data, status: Int
        do {
            let (d, r) = try await session.data(for: req)
            data = d
            status = (r as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            return .failure(Parse.quiet((error as? URLError)?.code == .timedOut ? "timed out" : "network error"))
        }
        guard status == 200 else { return .failure(Parse.quiet("HTTP \(status)")) }
        return parse(data)
    }
}
