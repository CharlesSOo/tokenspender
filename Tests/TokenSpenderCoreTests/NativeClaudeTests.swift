import Foundation
import Security
import LocalAuthentication
import XCTest
@testable import TokenSpenderCore

final class NativeClaudeTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "claude-native-" + name, withExtension: "json", subdirectory: "Fixtures")))
    }
    private func json(_ value: String) -> Data { Data(value.utf8) }

    func testNativeOnlyWithoutCswapAndEmptyManagedConfiguration() async throws {
        let auth = try NativeClaude.credential(fixture("auth"))
        let profile = try fixture("profile"), usage = try fixture("usage")
        for metadata: Result<Data, DirectSources.CredentialError> in [.failure(.missing), .success(json(#"{"accounts":{}}"#))] {
            var endpoints: [String] = []
            let accounts = await Fetcher.claudeAccounts(metadata: metadata, managed: {
                XCTFail("Native-only setup must not invoke or require cswap")
                return nil
            }, native: {
                await NativeClaude.fetch(credential: .success(auth)) { request in
                    endpoints.append(request.url!.lastPathComponent)
                    XCTAssertEqual(request.url?.host, "api.anthropic.com")
                    XCTAssertEqual(request.timeoutInterval, 20)
                    XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-claude-access-token")
                    return request.url!.lastPathComponent == "profile" ? profile : usage
                }
            })
            XCTAssertEqual(endpoints, ["profile", "usage"])
            XCTAssertEqual(accounts.count, 1)
            XCTAssertEqual(accounts[0].email, "native@example.com")
            let id = try XCTUnwrap(accounts[0].id)
            XCTAssertEqual(id, "claude/00000000-0000-0000-0000-000000000001/00000000-0000-0000-0000-000000000002")
            XCTAssertEqual(accounts[0].usage.windows.map(\.percentLeft), [96, 0])
            XCTAssertNotNil(accounts[0].usage.windows[0].resetsAt)
            let snapshot = UsageSnapshot(codex: .notConfigured, claude: accounts, kimi: .notConfigured)
            XCTAssertEqual(DisplaySelection.claudeAccount(id).text(snapshot: snapshot), "0%")
            XCTAssertEqual(DisplaySelection.choices(snapshot: snapshot, selected: .mode(.claudePool)).count, 5)
        }
    }

    func testManagedSourcePreferredAndFailuresNeverFallbackToNative() async throws {
        let metadata = json(#"{"accounts":{"1":{"uuid":"00000000-0000-0000-0000-000000000001","email":"a@example.com","organizationUuid":""},"2":{"uuid":"00000000-0000-0000-0000-000000000002","email":"b@example.com","organizationUuid":""}}}"#)
        let managed = json(#"{"accounts":[{"number":1,"email":"a@example.com","usageStatus":"token_expired"},{"number":2,"email":"b@example.com","usageStatus":"ok","usage":{"fiveHour":{"pct":25}}}]}"#)
        for output in [managed, nil, json("invalid"), json(#"{"accounts":[]}"#)] {
            let accounts = await Fetcher.claudeAccounts(metadata: .success(metadata), managed: { output }, native: {
                XCTFail("Managed presence or failure must never silently switch to native")
                return []
            })
            XCTAssertFalse(accounts.isEmpty)
            XCTAssertNotNil(accounts[0].usage.error)
            if output == managed {
                XCTAssertEqual(accounts.count, 2)
                XCTAssertEqual(accounts[0].usage.error, "expired")
                XCTAssertNotNil(accounts[0].id)
                XCTAssertEqual(accounts[1].usage.constraining?.percentLeft, 75)
            }
        }
        for metadata: Result<Data, DirectSources.CredentialError> in [.failure(.unreadable), .success(json("invalid")), .success(json("{}"))] {
            let accounts = await Fetcher.claudeAccounts(metadata: metadata, managed: {
                XCTFail("Invalid managed metadata cannot safely select a source")
                return nil
            }, native: { XCTFail("No native fallback"); return [] })
            XCTAssertEqual(accounts.first?.usage.error, "cswap metadata unreadable")
        }
    }

    func testCredentialExpiryMalformedMissingAndNoRefreshParsing() throws {
        XCTAssertEqual(try NativeClaude.credential(fixture("auth")).access, "fake-claude-access-token")
        let cases: [(String, NativeClaude.Failure)] = [
            (#"{"claudeAiOauth":{"accessToken":"fake","expiresAt":1}}"#, .expired),
            (#"{"claudeAiOauth":{"accessToken":"","expiresAt":4102444800000}}"#, .malformed),
            (#"{"claudeAiOauth":{"accessToken":"fake"}}"#, .malformed),
            (#"{"claudeAiOauth":"broken"}"#, .malformed),
            ("not JSON", .malformed), ("{}", .missing), (#"{"mcpOAuth":{}}"#, .missing)
        ]
        for (data, error) in cases {
            XCTAssertThrowsError(try NativeClaude.credential(json(data))) { XCTAssertEqual($0 as? NativeClaude.Failure, error) }
        }
    }

    func testMissingHiddenButDeniedMalformedExpiredVisibleWithoutNetwork() async {
        for error in [NativeClaude.Failure.missing, .expired, .malformed, .authorization, .keychain, .unsupportedProfile] {
            let accounts = await NativeClaude.fetch(credential: .failure(error)) { _ in
                XCTFail("Invalid credentials must not reach the provider")
                return Data()
            }
            if error == .missing { XCTAssertTrue(accounts.isEmpty) }
            else {
                XCTAssertEqual(accounts.count, 1)
                XCTAssertEqual(accounts[0].usage.error, error.rawValue)
                XCTAssertEqual(accounts[0].usage.needsClaudeAuthorization, error == .authorization || error == .keychain)
                XCTAssertNil(accounts[0].id)
            }
        }
    }

    func testKeychainConsentQueryAndFileFallbackFailClosed() throws {
        let location = try NativeClaude.location(environment: [:], home: "/fake-home", username: "example")
        let auth = try fixture("auth")
        for allow in [false, true] {
            let query = NativeClaude.keychainQuery(location: location, authorize: allow)
            XCTAssertEqual(query[kSecAttrService as String] as? String, "Claude Code-credentials")
            XCTAssertEqual(query[kSecAttrAccount as String] as? String, "example")
            XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
            XCTAssertEqual((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed, !allow)
            _ = try NativeClaude.loadCredential(location: location, authorize: allow, keychain: { _, authorize in
                XCTAssertEqual(authorize, allow)
                return .success(auth)
            }, file: { _ in XCTFail("Present Keychain wins"); return .failure(.missing) })
        }
        _ = try NativeClaude.loadCredential(location: location, authorize: false, keychain: { _, _ in .failure(.missing) }, file: {
            XCTAssertEqual($0, "/fake-home/.claude/.credentials.json")
            return .success(auth)
        })
        for error in [NativeClaude.Failure.authorization, .keychain, .malformed, .expired] {
            XCTAssertThrowsError(try NativeClaude.loadCredential(location: location, authorize: false,
                keychain: { _, _ in .failure(error) }, file: { _ in XCTFail("No fallback on failure"); return .success(auth) }))
        }
        XCTAssertThrowsError(try NativeClaude.loadCredential(location: location, authorize: false,
            keychain: { _, _ in .success(json("invalid")) }, file: { _ in XCTFail("Malformed does not fallback"); return .success(auth) }))
        XCTAssertEqual(NativeClaude.keychainFailure(errSecItemNotFound), .missing)
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled, errSecNoAccessForItem] {
            XCTAssertEqual(NativeClaude.keychainFailure(status), .authorization)
        }
    }

    func testProfilePathIsolationAndSecureStoragePrecedence() throws {
        func location(_ environment: [String: String]) throws -> NativeClaude.Location {
            try NativeClaude.location(environment: environment, home: "/fake-home", username: "example")
        }
        let standard = try location([:])
        let custom = try location(["CLAUDE_CONFIG_DIR": "/profiles/work"])
        XCTAssertNotEqual(custom.service, standard.service)
        XCTAssertEqual(custom.file, "/profiles/work/.credentials.json")
        XCTAssertNotEqual(custom.service, try location(["CLAUDE_CONFIG_DIR": "/profiles/work/"]).service)
        XCTAssertEqual(try location(["CLAUDE_CONFIG_DIR": "/profiles/work", "CLAUDE_SECURESTORAGE_CONFIG_DIR": ""]), standard)
        XCTAssertEqual(try location(["CLAUDE_CONFIG_DIR": "/ignored", "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/profiles/work"]), custom)
        XCTAssertEqual(try location(["CLAUDE_CONFIG_DIR": "/caf\u{e9}"]), try location(["CLAUDE_CONFIG_DIR": "/cafe\u{301}"]))
        for path in ["relative", "~/profile"] {
            XCTAssertThrowsError(try location(["CLAUDE_CONFIG_DIR": path])) { XCTAssertEqual($0 as? NativeClaude.Failure, .unsupportedProfile) }
        }
    }

    func testIdentityMustComeFromSameTokenProfileNotLocalLabel() async throws {
        let credential = try NativeClaude.credential(fixture("auth"))
        for profile in [json("{}"), json(#"{"account":{"email":"stale@example.com"},"organization":{"uuid":"00000000-0000-0000-0000-000000000002"}}"#), json(#"{"account":{"uuid":"not-a-uuid"}}"#)] {
            var calls = 0
            let accounts = await NativeClaude.fetch(credential: .success(credential)) { _ in calls += 1; return profile }
            XCTAssertEqual(calls, 1)
            XCTAssertNil(accounts.first?.id)
            XCTAssertEqual(accounts.first?.usage.error, "profile unavailable")
        }
        let profile = try fixture("profile")
        let failedUsage = await NativeClaude.fetch(credential: .success(credential)) { request in
            if request.url!.lastPathComponent == "profile" { return profile }
            throw NativeClaude.Failure.expired
        }
        XCTAssertNotNil(failedUsage.first?.id) // Verified identity survives an immediate usage error.
        XCTAssertEqual(failedUsage.first?.usage.error, NativeClaude.Failure.expired.rawValue)
        let renamed = Data(String(decoding: profile, as: UTF8.self).replacingOccurrences(of: "native@example.com", with: "renamed@example.com").utf8)
        XCTAssertEqual(try NativeClaude.account(profile: profile, usage: RowUsage()).id,
                       try NativeClaude.account(profile: renamed, usage: RowUsage()).id)
    }

    func testHTTPFailuresNeverExposeBodyAndUsageRequiresWindows() throws {
        for (status, error) in [(401, NativeClaude.Failure.expired), (403, .forbidden), (429, .rateLimited), (500, .network), (302, .network)] {
            XCTAssertThrowsError(try NativeClaude.response(json("do not display server body"), status: status)) {
                XCTAssertEqual($0 as? NativeClaude.Failure, error)
            }
        }
        XCTAssertThrowsError(try NativeClaude.usage(json("{}")))
        XCTAssertThrowsError(try NativeClaude.usage(json(#"{"five_hour":{"utilization":"bad"}}"#)))
    }
}
