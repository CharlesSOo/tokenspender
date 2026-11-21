import Foundation
import XCTest
@testable import QuotaTrackerCore

final class NativeClaudeTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "claude-native-" + name, withExtension: "json", subdirectory: "Fixtures")))
    }
    private func json(_ value: String) -> Data { Data(value.utf8) }

    func testNativeFetchVerifiesIdentityAndUsage() async throws {
        let auth = try NativeClaude.credential(fixture("auth"))
        let profile = try fixture("profile"), usage = try fixture("usage")
        var endpoints: [String] = []
        let accounts = await NativeClaude.fetch(credential: .success(auth)) { request in
            endpoints.append(request.url!.lastPathComponent)
            XCTAssertEqual(request.url?.host, "api.anthropic.com")
            XCTAssertEqual(request.timeoutInterval, 20)
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-claude-access-token")
            return request.url!.lastPathComponent == "profile" ? profile : usage
        }
        XCTAssertEqual(endpoints, ["profile", "usage"])
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts[0].email, "native@example.com")
        let id = try XCTUnwrap(accounts[0].id)
        XCTAssertEqual(id, "claude/00000000-0000-0000-0000-000000000001/00000000-0000-0000-0000-000000000002")
        XCTAssertEqual(accounts[0].usage.windows.map(\.percentLeft), [96, 0])
        XCTAssertNotNil(accounts[0].usage.windows[0].resetsAt)
        let snapshot = UsageSnapshot(codex: .notConfigured, claude: accounts)
        XCTAssertEqual(DisplaySelection.claudeAccount(id).text(snapshot: snapshot), "0%")
        XCTAssertEqual(DisplaySelection.choices(snapshot: snapshot, selected: .mode(.claudePool)).count, 5)
    }

    func testProfileDiscoveryDefaultFirstDedupedSorted() {
        let home = "/Users/x"
        let entries = [".claude-work", ".claude", ".claude-me", ".claude-swap-backup", ".claude-empty", "other"]
        let withConfig: Set<String> = ["/Users/x/.claude-work", "/Users/x/.claude-me", "/Users/x/.claude-swap-backup-not"]
        let found = NativeClaude.profiles(environment: ["CLAUDE_CONFIG_DIR": "/Users/x/.claude-me"], home: home,
                                          entries: entries, hasConfig: { withConfig.contains($0) })
        XCTAssertEqual(found, ["", "/Users/x/.claude-me", "/Users/x/.claude-work"])
        XCTAssertEqual(NativeClaude.profiles(environment: ["CLAUDE_CONFIG_DIR": "/elsewhere"], home: home, entries: [], hasConfig: { _ in true }),
                       ["", "/elsewhere"])
        XCTAssertEqual(NativeClaude.label(profile: "", home: home), "~/.claude")
        XCTAssertEqual(NativeClaude.label(profile: "/Users/x/.claude-me", home: home), "~/.claude-me")
        XCTAssertEqual(NativeClaude.label(profile: "/elsewhere", home: home), "/elsewhere")
    }

    func testKeychainServiceForConfigDirMatchesClaudeCode() throws {
        let location = try NativeClaude.location(profile: "/Users/charles/.claude-me", environment: [:], home: "/Users/charles", username: "charles")
        XCTAssertEqual(location.service, "Claude Code-credentials-8ee9146d")
        XCTAssertEqual(location.file, "/Users/charles/.claude-me/.credentials.json")
        XCTAssertEqual(try NativeClaude.location(profile: "", environment: [:], home: "/Users/charles", username: "charles").service,
                       "Claude Code-credentials")
    }

    func testOneRowPerProfileMissingSkippedFailuresLabeledDuplicatesMerged() async throws {
        let auth = try NativeClaude.credential(fixture("auth"))
        let profile = try fixture("profile"), usage = try fixture("usage")
        let home = "/Users/x"
        let credentials: [String: Result<NativeClaude.Credential, NativeClaude.Failure>] = [
            "": .failure(.expired), "/Users/x/.claude-a": .failure(.missing),
            "/Users/x/.claude-b": .success(auth), "/Users/x/.claude-c": .success(auth),
            "/Users/x/.claude-d": .failure(.keychain)]
        let refresher = NativeClaude.Refresher { _ in }
        let accounts = await NativeClaude.fetch(profiles: ["", "/Users/x/.claude-a", "/Users/x/.claude-b", "/Users/x/.claude-c", "/Users/x/.claude-d"],
                                                home: home, refresher: refresher, load: { credentials[$0]! }) { request in
            request.url!.lastPathComponent == "profile" ? profile : usage
        }
        XCTAssertEqual(accounts.map(\.profile), ["~/.claude", "~/.claude-b", "~/.claude-d"])
        XCTAssertEqual(accounts.map(\.email), ["~/.claude", "native@example.com", "~/.claude-d"])
        XCTAssertEqual(accounts[0].usage.error, NativeClaude.Failure.expired.rawValue)
        XCTAssertEqual(accounts[2].usage.error, NativeClaude.Failure.keychain.rawValue)
        XCTAssertEqual(accounts[1].id, "claude/00000000-0000-0000-0000-000000000001/00000000-0000-0000-0000-000000000002")

        // Same account in two profiles: the successful row wins regardless of order.
        let failed = try NativeClaude.account(profile: profile, usage: .failure("rate limited"), label: "~/.claude")
        let ok = try NativeClaude.account(profile: profile, usage: RowUsage(windows: []), label: "~/.claude-b")
        XCTAssertEqual(NativeClaude.merge([[failed], [ok]]), [ok])
        XCTAssertEqual(NativeClaude.merge([[ok], [failed]]), [ok])
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
        for error in [NativeClaude.Failure.missing, .expired, .malformed, .keychain, .unsupportedProfile] {
            let accounts = await NativeClaude.fetch(credential: .failure(error)) { _ in
                XCTFail("Invalid credentials must not reach the provider")
                return Data()
            }
            if error == .missing { XCTAssertTrue(accounts.isEmpty) }
            else {
                XCTAssertEqual(accounts.count, 1)
                XCTAssertEqual(accounts[0].usage.error, error.rawValue)
                XCTAssertNil(accounts[0].id)
            }
        }
    }

    func testKeychainFileFallbackFailClosed() throws {
        let location = try NativeClaude.location(environment: [:], home: "/fake-home", username: "example")
        let auth = try fixture("auth")
        _ = try NativeClaude.loadCredential(location: location, keychain: {
            XCTAssertEqual($0.service, "Claude Code-credentials")
            XCTAssertEqual($0.account, "example")
            return .success(auth)
        }, file: { _ in XCTFail("Present Keychain wins"); return .failure(.missing) })
        _ = try NativeClaude.loadCredential(location: location, keychain: { _ in .failure(.missing) }, file: {
            XCTAssertEqual($0, "/fake-home/.claude/.credentials.json")
            return .success(auth)
        })
        for error in [NativeClaude.Failure.keychain, .timeout, .malformed, .expired] {
            XCTAssertThrowsError(try NativeClaude.loadCredential(location: location,
                keychain: { _ in .failure(error) }, file: { _ in XCTFail("No fallback on failure"); return .success(auth) }))
        }
        XCTAssertThrowsError(try NativeClaude.loadCredential(location: location,
            keychain: { _ in .success(json("invalid")) }, file: { _ in XCTFail("Malformed does not fallback"); return .success(auth) }))
    }

    func testSecurityExitCodeMapping() {
        XCTAssertNil(NativeClaude.keychainStatus(exitCode: 0))
        XCTAssertEqual(NativeClaude.keychainStatus(exitCode: 44), .missing)
        for code: Int32 in [1, 36, 45, 51, 128, -1] {
            XCTAssertEqual(NativeClaude.keychainStatus(exitCode: code), .keychain)
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

    func testModelScopedWeeklyLimitBecomesItsOwnWindow() throws {
        let body = #"""
        {"five_hour":{"utilization":20,"resets_at":"2030-01-01T05:00:00Z"},
         "seven_day":{"utilization":57,"resets_at":"2030-01-07T08:00:00.739572+00:00"},
         "limits":[{"kind":"session","percent":20},{"kind":"weekly_all","percent":57},
                   {"kind":"weekly_scoped","percent":79,"resets_at":"2030-01-07T08:00:00.739718+00:00",
                    "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}]}
        """#
        let usage = try NativeClaude.usage(json(body))
        XCTAssertEqual(usage.windows.map(\.label), ["5H", "WK", "FABLE"])
        XCTAssertEqual(usage.windows.map(\.percentLeft), [80, 43, 21])
        XCTAssertEqual(usage.constraining?.label, "FABLE")
        let now = try XCTUnwrap(Parse.date("2030-01-01T00:00:00Z"))
        XCTAssertEqual(ResetFormat.line(for: usage.windows, now: now), "resets 6d 8h")
    }

    // MARK: Server-listed meters (scrubbed real payloads)

    private func real(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "claude-real-" + name, withExtension: "json", subdirectory: "Fixtures")))
    }

    func testRealPayloadWithSessionHasFiveHourWeeklyAndModel() throws {
        let usage = try NativeClaude.usage(real("usage"))
        XCTAssertEqual(usage.windows.map(\.label), ["5H", "WK", "FABLE"])
        XCTAssertEqual(usage.windows.map(\.percentLeft), [97, 96, 97])
        XCTAssertNotNil(usage.windows[0].resetsAt)
    }

    func testRealPayloadWithoutSessionHasNoFiveHour() throws {
        let usage = try NativeClaude.usage(real("usage-no-session"))
        XCTAssertEqual(usage.windows.map(\.label), ["WK", "FABLE"])
        // limits is authoritative even if a stale five_hour object were still present.
        XCTAssertEqual(try NativeClaude.usage(json(#"{"five_hour":{"utilization":5},"limits":[{"kind":"weekly_all","percent":10}]}"#)).windows.map(\.label), ["WK"])
    }

    func testPlanLabelParsedAndFollowsEachPoll() async throws {
        let credential = try NativeClaude.credential(fixture("auth"))
        let ultra = try real("profile"), usage = try real("usage")
        let max = Data(String(decoding: ultra, as: UTF8.self).replacingOccurrences(of: #""plan_display_name": "Ultra""#, with: #""plan_display_name": "Max""#).utf8)
        XCTAssertNotEqual(max, ultra)
        let first = await NativeClaude.fetch(credential: .success(credential)) { $0.url!.lastPathComponent == "profile" ? ultra : usage }
        XCTAssertEqual(first.first?.plan, "Ultra")
        XCTAssertEqual(first.first?.title, "ultra@example.com · Ultra")
        let second = await NativeClaude.fetch(credential: .success(credential)) { $0.url!.lastPathComponent == "profile" ? max : usage }
        XCTAssertEqual(second.first?.title, "ultra@example.com · Max")
        XCTAssertNil(try NativeClaude.account(profile: fixture("profile"), usage: RowUsage()).plan)
    }

    // MARK: Renewal through Claude Code

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String] = []
        private var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var runs: [String] { lock.withLock { value } }
        func run(_ profile: String) { lock.withLock { value.append(profile) } }
        var now: Date { lock.withLock { clock } }
        func advance(_ seconds: TimeInterval) { lock.withLock { clock += seconds } }
    }

    func testExpiredCredentialRunsClaudeOnceThenRereadsAndThrottles() async throws {
        let good = try NativeClaude.credential(fixture("auth"))
        let profile = try fixture("profile"), usage = try fixture("usage")
        let box = Box()
        let refresher = NativeClaude.Refresher(now: { box.now }) { box.run($0) }
        // The Keychain holds a dead token until Claude Code has run for this folder.
        let renewedAfter = { @Sendable (count: Int) -> Result<NativeClaude.Credential, NativeClaude.Failure> in
            box.runs.count > count ? .success(good) : .failure(.expired)
        }
        let transport: @Sendable (URLRequest) async throws -> Data = { $0.url!.lastPathComponent == "profile" ? profile : usage }
        let rows = await NativeClaude.fetch(profile: "/Users/x/.claude-me", home: "/Users/x", refresher: refresher,
                                            load: { _ in renewedAfter(0) }, transport: transport)
        XCTAssertEqual(box.runs, ["/Users/x/.claude-me"])
        XCTAssertNil(rows.first?.usage.error)
        XCTAssertEqual(rows.first?.email, "native@example.com")

        // Expired again within 10 minutes: no second run; the row names the folder to fix.
        box.advance(9 * 60)
        let again = await NativeClaude.fetch(profile: "/Users/x/.claude-me", home: "/Users/x", refresher: refresher,
                                             load: { _ in .failure(.expired) }, transport: transport)
        XCTAssertEqual(box.runs.count, 1)
        XCTAssertEqual(again.first?.usage.error, NativeClaude.Failure.expired.rawValue)
        XCTAssertEqual(again.first?.usage.hint, "run claude in ~/.claude-me")

        // Another folder is not throttled by the first; after 10 minutes the first may run again.
        _ = await NativeClaude.fetch(profile: "", home: "/Users/x", refresher: refresher, load: { _ in .failure(.expired) }, transport: transport)
        XCTAssertEqual(box.runs, ["/Users/x/.claude-me", ""])
        box.advance(61)
        _ = await NativeClaude.fetch(profile: "/Users/x/.claude-me", home: "/Users/x", refresher: refresher, load: { _ in .failure(.expired) }, transport: transport)
        XCTAssertEqual(box.runs.count, 3)
    }

    func testHTTP401AlsoRunsClaudeAndOtherFailuresDoNot() async throws {
        let good = try NativeClaude.credential(fixture("auth"))
        let profile = try fixture("profile"), usage = try fixture("usage")
        let box = Box()
        let refresher = NativeClaude.Refresher(now: { box.now }) { box.run($0) }
        let rows = await NativeClaude.fetch(profile: "", home: "/Users/x", refresher: refresher, load: { _ in .success(good) }) { request in
            if box.runs.isEmpty { throw NativeClaude.Failure.expired }
            return request.url!.lastPathComponent == "profile" ? profile : usage
        }
        XCTAssertEqual(box.runs, [""])
        XCTAssertNil(rows.first?.usage.error)
        XCTAssertNil(rows.first?.usage.hint)
        for failure in [NativeClaude.Failure.network, .forbidden, .keychain, .missing] {
            _ = await NativeClaude.fetch(profile: "/Users/x/.claude-z", home: "/Users/x", refresher: refresher, load: { _ in .failure(failure) }) { _ in Data() }
        }
        XCTAssertEqual(box.runs, [""])
    }

    func testUserAddedFoldersJoinProfilesDeduped() {
        let home = "/Users/x"
        let auto = NativeClaude.profiles(environment: [:], home: home, entries: [".claude-me"], folders: [], hasConfig: { _ in true })
        XCTAssertEqual(auto, ["", "/Users/x/.claude-me"])
        let added = NativeClaude.profiles(environment: ["CLAUDE_CONFIG_DIR": "/env"], home: home, entries: [".claude-me"],
                                          folders: ["/work/claude", "/Users/x/.claude-me", "/Users/x/.claude-me/", "/Users/x/.claude", "/env"],
                                          hasConfig: { _ in true })
        XCTAssertEqual(added, ["", "/Users/x/.claude-me", "/env", "/work/claude"])
        // Removing the folder from the setting drops it.
        XCTAssertEqual(NativeClaude.profiles(environment: [:], home: home, entries: [".claude-me"], folders: [], hasConfig: { _ in true }), auto)
    }
}
