import Foundation
import XCTest
@testable import TokenSpenderCore

final class CodexOAuthTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_454_000)
    private var directory: URL!
    private var path: String { directory.appendingPathComponent("auth.json").path }
    private let usage = Data(#"{"rate_limit":{"primary_window":{"used_percent":25,"limit_window_seconds":18000}}}"#.utf8)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func jwt(expires: TimeInterval, tag: String = "old") -> String {
        let payload = Data("{\"exp\":\(expires),\"tag\":\"\(tag)\"}".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJub25lIn0." + payload + ".sig"
    }

    @discardableResult
    private func writeAuth(expiresIn: TimeInterval, refresh: String? = "old-refresh",
                           account: String = "acct_test", tag: String = "old") throws -> String {
        let access = jwt(expires: now.timeIntervalSince1970 + expiresIn, tag: tag)
        var tokens = ["access_token": access, "id_token": "old-id", "account_id": account, "other_token_field": "keep"]
        tokens["refresh_token"] = refresh
        let auth: [String: Any] = ["tokens": tokens, "auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(), "other_field": "keep"]
        try JSONSerialization.data(withJSONObject: auth).write(to: URL(fileURLWithPath: path))
        return access
    }

    private func response(rotate: Bool = true) throws -> Data {
        var tokens = ["access_token": jwt(expires: now.timeIntervalSince1970 + 3600, tag: "new")]
        if rotate { tokens["refresh_token"] = "new-refresh"; tokens["id_token"] = "new-id" }
        return try JSONSerialization.data(withJSONObject: tokens)
    }

    func testExpiredAndExpiringCredentialsRenewAndPersistBeforeUsage() async throws {
        for expiresIn: TimeInterval in [-1, 0, 299, 300] {
            try writeAuth(expiresIn: expiresIn)
            var endpoints: [String] = []
            let row = await DirectSources.codex(path: path, now: now, oauth: CodexOAuth()) { request in
                endpoints.append(request.url!.host!)
                if request.url!.host == "auth.openai.com" {
                    XCTAssertEqual(request.url?.path, "/oauth/token")
                    XCTAssertEqual(request.httpMethod, "POST")
                    XCTAssertEqual(request.timeoutInterval, 20)
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
                    XCTAssertEqual(body, ["grant_type": "refresh_token", "client_id": "app_EMoamEEZ73f0CkXaXp7hrann", "refresh_token": "old-refresh"])
                    return (try self.response(), 200)
                }
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + self.jwt(expires: self.now.timeIntervalSince1970 + 3600, tag: "new"))
                XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acct_test")
                // Persistence must finish before the new access token is used.
                let saved = try DirectSources.codexCredential(authJSON: Data(contentsOf: URL(fileURLWithPath: self.path)), now: self.now).get()
                XCTAssertEqual(saved.refresh, "new-refresh")
                return (self.usage, 200)
            }
            XCTAssertNil(row.error)
            XCTAssertEqual(row.identity, "acct_test")
            XCTAssertEqual(row.windows.first?.percentLeft, 75)
            XCTAssertEqual(endpoints, ["auth.openai.com", "chatgpt.com"])
            let auth = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
            let tokens = try XCTUnwrap(auth["tokens"] as? [String: String])
            XCTAssertEqual(tokens["id_token"], "new-id")
            XCTAssertEqual(tokens["other_token_field"], "keep")
            XCTAssertEqual(auth["other_field"] as? String, "keep")
            XCTAssertTrue(auth["OPENAI_API_KEY"] is NSNull)
            XCTAssertEqual(auth["auth_mode"] as? String, "chatgpt")
            XCTAssertEqual(auth["last_refresh"] as? String, ISO8601DateFormatter().string(from: now))
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["auth.json"])
        }
    }

    func testFreshTokenDoesNotRenewOrWrite() async throws {
        let access = try writeAuth(expiresIn: 301)
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        let row = await DirectSources.codex(path: path, now: now, oauth: CodexOAuth()) { request in
            XCTAssertEqual(request.url?.host, "chatgpt.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + access)
            return (self.usage, 200)
        }
        XCTAssertNil(row.error)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original)
    }

    func testUsage401RenewsAndRetriesOnlyOnce() async throws {
        for retryStatus in [200, 401] {
            let access = try writeAuth(expiresIn: 3600)
            var endpoints: [String] = []
            let row = await DirectSources.codex(path: path, now: now, oauth: CodexOAuth()) { request in
                endpoints.append(request.url!.host!)
                switch endpoints.count {
                case 1:
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + access)
                    return (Data(), 401)
                case 2: return (try self.response(), 200)
                case 3: return (self.usage, retryStatus)
                default: XCTFail("Authentication retries must be bounded"); return (Data(), 401)
                }
            }
            XCTAssertEqual(endpoints, ["chatgpt.com", "auth.openai.com", "chatgpt.com"])
            XCTAssertEqual(row.error, retryStatus == 200 ? nil : CodexOAuth.Failure.loginRequired.rawValue)
        }
    }

    func test401AdoptsCLIRefreshWithoutAnotherGrant() async throws {
        try writeAuth(expiresIn: 3600)
        var requests = 0
        let row = await DirectSources.codex(path: path, now: now, oauth: CodexOAuth()) { request in
            requests += 1
            XCTAssertEqual(request.url?.host, "chatgpt.com")
            if requests == 1 {
                try self.writeAuth(expiresIn: 7200, refresh: "cli-refresh", tag: "cli")
                return (Data(), 401)
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + self.jwt(expires: self.now.timeIntervalSince1970 + 7200, tag: "cli"))
            return (self.usage, 200)
        }
        XCTAssertNil(row.error)
        XCTAssertEqual(requests, 2)
    }

    func testNonAuthenticationUsageFailuresDoNotRenew() async throws {
        for status in [403, 429, 500] {
            try writeAuth(expiresIn: 3600)
            var requests = 0
            let row = await DirectSources.codex(path: path, now: now, oauth: CodexOAuth()) { request in
                requests += 1
                XCTAssertEqual(request.url?.host, "chatgpt.com")
                return (Data(), status)
            }
            XCTAssertNotNil(row.error)
            XCTAssertEqual(requests, 1)
        }
    }

    func testUnrenewableExpiredCredentialsRequireLoginWithoutNetwork() async throws {
        for refresh: String? in [nil, ""] {
            try writeAuth(expiresIn: -1, refresh: refresh)
            let row = await DirectSources.codex(path: path, now: now, oauth: CodexOAuth()) { _ in
                XCTFail("No grant is possible"); return (Data(), 200)
            }
            XCTAssertEqual(row.error, CodexOAuth.Failure.loginRequired.rawValue)
        }
        try writeAuth(expiresIn: 60, refresh: nil)
        let row = await DirectSources.codex(path: path, now: now, oauth: CodexOAuth()) { request in
            XCTAssertEqual(request.url?.host, "chatgpt.com")
            return (self.usage, 200)
        }
        XCTAssertNil(row.error, "A still-valid token without a refresh token remains usable")
    }

    func testRejectedAndMalformedRenewalsPreserveAuthFile() async throws {
        let cases: [(Data, Int, String)] = [
            (Data(), 400, CodexOAuth.Failure.loginRequired.rawValue),
            (Data(), 401, CodexOAuth.Failure.loginRequired.rawValue),
            (Data("broken".utf8), 200, CodexOAuth.Failure.response.rawValue),
            (Data(#"{"access_token":""}"#.utf8), 200, CodexOAuth.Failure.response.rawValue),
            (Data(#"{"access_token":"x","refresh_token":""}"#.utf8), 200, CodexOAuth.Failure.response.rawValue),
        ]
        for (data, status, error) in cases {
            try writeAuth(expiresIn: -1)
            let original = try Data(contentsOf: URL(fileURLWithPath: path))
            var requests = 0
            let row = await DirectSources.codex(path: path, now: now, oauth: CodexOAuth()) { request in
                requests += 1
                XCTAssertEqual(request.url?.host, "auth.openai.com")
                return (data, status)
            }
            XCTAssertEqual(row.error, error)
            XCTAssertEqual(requests, 1)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original)
        }
    }

    func testTransientRenewalFailureCanRecoverOnNextPoll() async throws {
        try writeAuth(expiresIn: -1)
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        let oauth = CodexOAuth()
        let failed = await DirectSources.codex(path: path, now: now, oauth: oauth) { _ in throw URLError(.timedOut) }
        XCTAssertEqual(failed.error, "timed out")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original)
        let row = await DirectSources.codex(path: path, now: now, oauth: oauth) { request in
            request.url?.host == "auth.openai.com" ? (try self.response(), 200) : (self.usage, 200)
        }
        XCTAssertNil(row.error)
    }

    func testOmittedRotatedFieldsPreserveOriginalTokens() async throws {
        try writeAuth(expiresIn: -1)
        let credential = try await CodexOAuth().credential(path: path, now: now) { _ in (try self.response(rotate: false), 200) }
        XCTAssertEqual(credential.refresh, "old-refresh")
        let auth = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        XCTAssertEqual((auth["tokens"] as? [String: String])?["id_token"], "old-id")
    }

    func testCLIUpdateDuringRenewalIsAdoptedAndNeverOverwritten() async throws {
        for status in [200, 401] {
            try writeAuth(expiresIn: -1)
            let credential = try await CodexOAuth().credential(path: path, now: now) { _ in
                try self.writeAuth(expiresIn: 7200, refresh: "cli-refresh", tag: "cli")
                return (try self.response(), status)
            }
            XCTAssertEqual(credential.refresh, "cli-refresh")
            let saved = try DirectSources.codexCredential(authJSON: Data(contentsOf: URL(fileURLWithPath: path)), now: now).get()
            XCTAssertEqual(saved, credential)
        }
    }

    func testAccountSwitchDuringRenewalIsNotOverwrittenOrUsed() async throws {
        try writeAuth(expiresIn: -1)
        let row = await DirectSources.codex(path: path, now: now, oauth: CodexOAuth()) { request in
            XCTAssertEqual(request.url?.host, "auth.openai.com")
            try self.writeAuth(expiresIn: 7200, refresh: "other-refresh", account: "acct_other")
            return (try self.response(), 200)
        }
        XCTAssertEqual(row.error, CodexOAuth.Failure.changed.rawValue)
        let saved = try DirectSources.codexCredential(authJSON: Data(contentsOf: URL(fileURLWithPath: path)), now: now).get()
        XCTAssertEqual(saved.accountId, "acct_other")
        XCTAssertEqual(saved.refresh, "other-refresh")
    }

    func testLogoutDuringRenewalDoesNotRecreateCredentials() async throws {
        try writeAuth(expiresIn: -1)
        let row = await DirectSources.codex(path: path, now: now, oauth: CodexOAuth()) { _ in
            try FileManager.default.removeItem(atPath: self.path)
            return (try self.response(), 200)
        }
        XCTAssertEqual(row.error, "not logged in")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testConcurrentRequestsShareOneRenewal() async throws {
        try writeAuth(expiresIn: -1)
        let oauth = CodexOAuth(), requests = RequestCount()
        let transport: DirectSources.Transport = { _ in
            await requests.increment()
            await Task.yield()
            return (try self.response(), 200)
        }
        let credentials = try await withThrowingTaskGroup(of: DirectSources.Credential.self) { group in
            for _ in 0..<20 {
                group.addTask { try await oauth.credential(path: self.path, now: self.now, transport: transport) }
            }
            var values: [DirectSources.Credential] = []
            for try await value in group { values.append(value) }
            return values
        }
        let count = await requests.value
        XCTAssertEqual(count, 1)
        XCTAssertEqual(credentials.count, 20)
        XCTAssertTrue(credentials.allSatisfy { $0.refresh == "new-refresh" })
    }
}

private actor RequestCount {
    private(set) var value = 0
    func increment() { value += 1 }
}
