import Foundation
import XCTest
@testable import QuotaTrackerCore

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
        for failure in [NativeClaude.Failure.missing, .malformed, .keychain] {
            var reads = 0
            XCTAssertThrowsError(try NativeClaude.loadCredential(location: location, keychain: { _ in .failure(.missing) }, file: { path in
                reads += 1
                XCTAssertEqual(path, "/synthetic/work/.credentials.json")
                return .failure(failure)
            })) { XCTAssertEqual($0 as? NativeClaude.Failure, failure) }
            XCTAssertEqual(reads, 1)
        }
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
            UsageSnapshot(codex: .notConfigured, claude: accounts)
        }
        let usage = try NativeClaude.usage(data(#"{"five_hour":{"utilization":10},"seven_day":{"utilization":65}}"#))
        let first = try NativeClaude.account(profile: profile(), usage: usage)
        let pin = DisplaySelection.claudeAccount(try XCTUnwrap(first.id))
        XCTAssertEqual(pin.text(snapshot: snapshot([first])), "35%")
        for failure in [NativeClaude.Failure.missing, .expired, .keychain, .malformed] {
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
}
