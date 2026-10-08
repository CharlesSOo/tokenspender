import Foundation
import Security
import XCTest
@testable import TokenSpenderCore

/// Independent verification: synthetic inputs only; never invoke live auth or provider transports.
final class StandaloneVerificationTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }
    private let user = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    private let org = "11111111-2222-3333-4444-555555555555"
    private func profile(user: String = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", org: String = "11111111-2222-3333-4444-555555555555") -> Data {
        data("{\"account\":{\"uuid\":\"\(user)\",\"email\":\"verify@example.com\"},\"organization\":{\"uuid\":\"\(org)\"}}")
    }

    func testExpiryBoundaryAndUnrelatedCredentialFieldsIgnored() throws {
        let now = Date(timeIntervalSince1970: 1000)
        for expiry in [999999, 1000000] {
            XCTAssertThrowsError(try NativeClaude.credential(data("{\"claudeAiOauth\":{\"accessToken\":\"fake\",\"expiresAt\":\(expiry)}}"), now: now)) {
                XCTAssertEqual($0 as? NativeClaude.Failure, .expired)
            }
        }
        let valid = data(#"{"claudeAiOauth":{"accessToken":" fake ","expiresAt":1000001,"refreshToken":{"unexpected":"ignored"}},"mcpOAuth":{"anything":"ignored"}}"#)
        XCTAssertEqual(try NativeClaude.credential(valid, now: now).access, "fake")
        for malformed in [#"{"claudeAiOauth":{"accessToken":"fake","expiresAt":0}}"#,
                          #"{"claudeAiOauth":{"accessToken":"fake","expiresAt":"4102444800000"}}"#,
                          #"{"claudeAiOauth":{"accessToken":null,"expiresAt":4102444800000}}"#] {
            XCTAssertThrowsError(try NativeClaude.credential(data(malformed))) {
                XCTAssertEqual($0 as? NativeClaude.Failure, .malformed)
            }
        }
    }

    func testFileFallbackFailuresStayDistinctAndNeverTryAnotherProfile() throws {
        let location = try NativeClaude.location(environment: ["CLAUDE_CONFIG_DIR": "/synthetic/work"], home: "/synthetic/home", username: "example")
        for failure in [NativeClaude.Failure.missing, .malformed, .authorization] {
            var reads = 0
            XCTAssertThrowsError(try NativeClaude.loadCredential(location: location, authorize: false, keychain: { _, _ in .failure(.missing) }, file: { path in
                reads += 1
                XCTAssertEqual(path, "/synthetic/work/.credentials.json")
                return .failure(failure)
            })) { XCTAssertEqual($0 as? NativeClaude.Failure, failure) }
            XCTAssertEqual(reads, 1)
        }
    }

    func testExactKeychainQueryAndMissingVersusUnavailableStatus() throws {
        let location = try NativeClaude.location(environment: [:], home: "/synthetic", username: "example")
        let query = NativeClaude.keychainQuery(location: location, authorize: false)
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
        XCTAssertNil(query[kSecReturnAttributes as String])
        XCTAssertNil(query[kSecMatchItemList as String])
        XCTAssertEqual(NativeClaude.keychainFailure(errSecNotAvailable), .keychain)
        XCTAssertEqual(NativeClaude.keychainFailure(errSecDecode), .keychain)
        XCTAssertEqual(NativeClaude.keychainFailure(errSecItemNotFound), .missing)
    }

    func testProfileFailuresDoNotIssueUsageOrExposeTransportMessages() async {
        for failure in [NativeClaude.Failure.expired, .forbidden, .rateLimited, .timeout, .network] {
            var paths: [String] = []
            let accounts = await NativeClaude.fetch(credential: .success(.init(access: "fake"))) { request in
                paths.append(request.url!.path)
                throw failure
            }
            XCTAssertEqual(paths, ["/api/oauth/profile"])
            XCTAssertEqual(accounts.first?.usage.error, failure.rawValue)
            XCTAssertNil(accounts.first?.id)
        }
        let accounts = await NativeClaude.fetch(credential: .success(.init(access: "fake"))) { _ in
            throw NSError(domain: "fake-secret-must-not-be-displayed", code: 1, userInfo: [NSLocalizedDescriptionKey: "fake-secret-must-not-be-displayed"])
        }
        XCTAssertEqual(accounts.first?.usage.error, "network error")
    }

    func testStableIdentityAcrossTokenRotationCaseAndOrganizationIsolation() async throws {
        var ids: [String?] = []
        for token in ["fake-first", "fake-rotated"] {
            let accounts = await NativeClaude.fetch(credential: .success(.init(access: token))) { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + token)
                return request.url!.lastPathComponent == "profile" ? self.profile(user: self.user.uppercased()) : self.data(#"{"five_hour":{"utilization":30}}"#)
            }
            ids.append(accounts.first?.id)
        }
        XCTAssertEqual(ids, ["claude/\(user)/\(org)", "claude/\(user)/\(org)"])
        let otherOrg = try NativeClaude.account(profile: profile(org: "99999999-2222-3333-4444-555555555555"), usage: RowUsage())
        XCTAssertNotEqual(otherOrg.id, ids[0])
        let otherUser = try NativeClaude.account(profile: profile(user: "bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee"), usage: RowUsage())
        XCTAssertNotEqual(otherUser.id, ids[0])
    }

    func testNativePinUnavailableAfterLogoutNeverFollowsDifferentLoginAndRecovers() async throws {
        func snapshot(_ accounts: [ClaudeAccount]) -> UsageSnapshot {
            UsageSnapshot(codex: .notConfigured, claude: accounts, kimi: .notConfigured)
        }
        let usage = try NativeClaude.usage(data(#"{"five_hour":{"utilization":10},"seven_day":{"utilization":65}}"#))
        let first = try NativeClaude.account(profile: profile(), usage: usage)
        let pin = DisplaySelection.claudeAccount(try XCTUnwrap(first.id))
        XCTAssertEqual(pin.text(snapshot: snapshot([first])), "35%")
        for failure in [NativeClaude.Failure.missing, .expired, .authorization, .malformed] {
            let accounts = await NativeClaude.fetch(credential: .failure(failure)) { _ in XCTFail("No request"); return Data() }
            XCTAssertEqual(pin.text(snapshot: snapshot(accounts)), "—")
        }
        let other = try NativeClaude.account(profile: profile(user: "bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee"), usage: usage)
        XCTAssertEqual(pin.text(snapshot: snapshot([other])), "—")
        XCTAssertEqual(pin.text(snapshot: snapshot([first])), "35%")
    }

    func testUsageFailureRetainsVerifiedIdentityAndDoesNotReusePreviousQuota() async {
        let accounts = await NativeClaude.fetch(credential: .success(.init(access: "fake"))) { request in
            if request.url!.lastPathComponent == "profile" { return self.profile() }
            return self.data(#"{"five_hour":{"utilization":"invalid"}}"#)
        }
        XCTAssertEqual(accounts.first?.id, "claude/\(user)/\(org)")
        XCTAssertEqual(accounts.first?.usage.error, "usage unavailable")
        XCTAssertEqual(accounts.first?.usage.windows, [])
        XCTAssertEqual(accounts.first?.usage.needsClaudeAuthorization, false)
    }

    func testUsageWindowBoundariesUnknownFieldsAndFractionalReset() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let usage = try NativeClaude.usage(data(#"{"five_hour":{"utilization":-5,"resets_at":"2030-01-01T00:00:00.123456Z"},"seven_day":{"utilization":101,"resets_at":"invalid"},"seven_day_opus":{"utilization":99},"extra_usage":{"is_enabled":false}}"#), now: now)
        XCTAssertEqual(usage.windows.map(\.label), ["5H", "WK"])
        XCTAssertEqual(usage.windows.map(\.percentLeft), [100, 0])
        XCTAssertNotNil(usage.windows[0].resetsAt)
        XCTAssertNil(usage.windows[1].resetsAt)
        XCTAssertEqual(usage.observedAt, now)
        let weeklyOnly = try NativeClaude.usage(data(#"{"five_hour":null,"seven_day":{"utilization":12.5}}"#))
        XCTAssertEqual(weeklyOnly.windows.map(\.percentLeft), [87.5])
    }

    func testNativeRoutingFailuresDoNotInvokeManagedExecutable() async {
        for metadata: Result<Data, DirectSources.CredentialError> in [.failure(.missing), .success(data(#"{"accounts":{},"nextNumber":1}"#))] {
            var nativeCalls = 0
            let accounts = await Fetcher.claudeAccounts(metadata: metadata, managed: { XCTFail("cswap must not run"); return nil }, native: {
                nativeCalls += 1
                return await NativeClaude.fetch(credential: .failure(.authorization)) { _ in XCTFail("No network"); return Data() }
            })
            XCTAssertEqual(nativeCalls, 1)
            XCTAssertEqual(accounts.first?.usage.error, "authorize in Settings")
        }
    }

    func testManagedOrderingMissingCredentialsAndBrokenIdentityNeverAddNative() async throws {
        let metadata = data(#"{"accounts":{"2":{"email":"b@example.com","uuid":"invalid"},"1":{"email":"a@example.com","uuid":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","organizationUuid":""}}}"#)
        let output = data(#"{"accounts":[{"number":2,"email":"b@example.com","usageStatus":"ok","usage":{"fiveHour":{"pct":50}}},{"number":1,"email":"a@example.com","usageStatus":"no_credentials"}]}"#)
        let accounts = await Fetcher.claudeAccounts(metadata: .success(metadata), managed: { output }, native: { XCTFail("Never silently add native"); return [] })
        XCTAssertEqual(accounts.map(\.slot), [1, 2])
        XCTAssertEqual(accounts.count, 2)
        XCTAssertFalse(accounts[0].usage.isConfigured)
        XCTAssertNotNil(accounts[0].id)
        XCTAssertEqual(accounts[1].usage.constraining?.percentLeft, 50)
        XCTAssertNil(accounts[1].id)
    }

    func testMalformedManagedSourceCannotSelectNativeEvenIfInstalledStateUnknown() async {
        for json in ["null", "[]", #"{"accounts":null}"#, #"{"accounts":{"1":null}}"#, #"{"accounts":{"1":{"email":42}}}"#] {
            let accounts = await Fetcher.claudeAccounts(metadata: .success(data(json)), managed: { XCTFail("No executable"); return nil }, native: { XCTFail("No account switching"); return [] })
            XCTAssertEqual(accounts.first?.usage.error, "cswap metadata unreadable")
        }
    }
}
