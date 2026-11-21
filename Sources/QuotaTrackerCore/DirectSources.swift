import Foundation
import CryptoKit

/// Direct usage fetcher for Codex that bypasses CodexBarCLI.
///
/// Credentials are never logged:
/// - Codex: `~/.codex/auth.json` (renewed by CodexOAuth; carries `account_id`). Pi's `openai`
///   OAuth token is a ChatGPT-for-API token without `chatgpt_account_id` and is rejected by
///   `wham/usage` with 401 `rejected_by_access_enforcement`, so it cannot be used here.
public enum DirectSources {
    public static var codexAuthPath = NSHomeDirectory() + "/.codex/auth.json"
    static let timeout: TimeInterval = 20
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    typealias Transport = (URLRequest) async throws -> (Data, Int)

    static func request(_ req: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: req)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // MARK: - Credentials

    struct Credential: Equatable {
        let access: String
        let expires: Date?
        var accountId: String?
        var refresh: String?
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

    private struct CodexAuth: Decodable {
        struct Tokens: Decodable {
            let access_token: String
            let account_id: String?
            let refresh_token: String?
        }
        let tokens: Tokens?
        private enum CodingKeys: String, CodingKey { case tokens }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tokens = c.contains(.tokens) ? try c.decode(Tokens.self, forKey: .tokens) : nil
        }
    }

    /// Codex CLI `auth.json`: `{ tokens: { access_token, account_id, ... } }`; expiry from the JWT `exp` claim.
    static func codexCredential(authJSON: Data, now: Date = Date(), allowExpired: Bool = false) -> Result<Credential, CredentialError> {
        guard let auth = try? JSONDecoder().decode(CodexAuth.self, from: authJSON) else { return .failure(.unreadable) }
        guard let t = auth.tokens else { return .failure(.missing) }
        guard !t.access_token.isEmpty else { return .failure(.unreadable) }
        let claims = jwtClaims(t.access_token)
        let expires = (claims?["exp"] as? Double).map { Date(timeIntervalSince1970: $0) }
        if !allowExpired, let expires, expires <= now { return .failure(.expired) }
        let accountId = t.account_id
            ?? (claims?["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String
        return .success(Credential(access: t.access_token, expires: expires, accountId: accountId, refresh: t.refresh_token))
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
        let plan_type: String?
        let rate_limit: RateLimit?
    }

    public static func parseCodex(_ data: Data, now: Date = Date()) -> RowUsage {
        guard let usage = try? JSONDecoder().decode(CodexUsage.self, from: data) else { return .failure("Unreadable usage response") }
        // A lapsed subscription still answers with a 30-day free-tier window; hide it like a missing login.
        if usage.plan_type == "free" { return .notConfigured }
        let windows = [usage.rate_limit?.primary_window, usage.rate_limit?.secondary_window].compactMap { w -> UsageWindow? in
            guard let w, let used = w.used_percent else { return nil }
            let label = (w.limit_window_seconds ?? 0) > 86400 ? "WK" : "5H"
            let reset = w.reset_at.map { Date(timeIntervalSince1970: $0) } ?? w.reset_after_seconds.map { now.addingTimeInterval($0) }
            return UsageWindow(label: label, percentLeft: Parse.left(used), resetsAt: reset)
        }
        return windows.isEmpty ? .failure("No usage windows") : RowUsage(windows: windows)
    }

    public static func codex() async -> RowUsage {
        await codex(path: codexAuthPath, transport: request)
    }

    static func codex(path: String, now: Date = Date(), oauth: CodexOAuth = .shared,
                      transport: @escaping Transport) async -> RowUsage {
        do {
            var cred = try await oauth.credential(path: path, now: now, transport: transport)
            var (data, status) = try await transport(codexRequest(cred))
            if status == 401 {
                cred = try await oauth.credential(path: path, rejected: cred, now: now, transport: transport)
                (data, status) = try await transport(codexRequest(cred))
            }
            guard status != 401 else { throw CodexOAuth.Failure.loginRequired }
            guard status == 200 else { return httpFailure(status) }
            var row = parseCodex(data)
            guard row.isConfigured else { return row }
            row.observedAt = Date()
            row.identity = cred.accountId ?? SHA256.hash(data: Data(cred.access.utf8)).description
            return row
        } catch let error as CredentialError {
            return .failure(error.message)
        } catch let error as CodexOAuth.Failure {
            return .failure(error.rawValue)
        } catch {
            return networkFailure(error)
        }
    }

    private static func codexRequest(_ cred: Credential) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!, timeoutInterval: timeout)
        req.setValue("Bearer \(cred.access)", forHTTPHeaderField: "Authorization")
        if let id = cred.accountId { req.setValue(id, forHTTPHeaderField: "ChatGPT-Account-Id") }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    // MARK: - helpers

    /// No connectivity, DNS/connection trouble and timeouts are transient; anything else is not.
    public static func isTransient(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
                .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive,
                .secureConnectionFailed, .badServerResponse].contains(code)
    }

    static func networkFailure(_ error: Error) -> RowUsage {
        .failure(Parse.quiet((error as? URLError)?.code == .timedOut ? "timed out" : "network error"), transient: isTransient(error))
    }

    /// 5xx and 429 are transient; 401/403 and other statuses are not.
    static func httpFailure(_ status: Int) -> RowUsage {
        .failure(Parse.quiet("HTTP \(status)"), transient: status == 429 || (500...599).contains(status))
    }

    static func readFile(_ path: String) -> Result<Data, CredentialError> {
        do { return .success(try Data(contentsOf: URL(fileURLWithPath: path))) }
        catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return .failure(.missing) }
            return .failure(.unreadable)
        }
    }
}
