import Foundation
import XCTest
@testable import QuotaTrackerCore

/// Edge cases for folder renewal, server-listed meters, plan labels and LastGood with hints.
final class ReliableClaudeEdgeTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }
    private func json(_ value: String) -> Data { Data(value.utf8) }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var runs: [String] = []
        private var loads = 0
        private var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var runList: [String] { lock.withLock { runs } }
        var loadCount: Int { lock.withLock { loads } }
        func run(_ profile: String) { lock.withLock { runs.append(profile) } }
        func load() -> Int { lock.withLock { loads += 1; return loads } }
        var now: Date { lock.withLock { clock } }
        func advance(_ seconds: TimeInterval) { lock.withLock { clock += seconds } }
    }

    // MARK: Refresher

    func testConcurrentRefreshesOfSameFolderRunClaudeOnce() async {
        let counter = Counter()
        let refresher = NativeClaude.Refresher(now: { counter.now }) { profile in
            try? await Task.sleep(nanoseconds: 50_000_000)
            counter.run(profile)
        }
        async let a = refresher.refresh("/f")
        async let b = refresher.refresh("/f")
        async let c = refresher.refresh("/g")
        let results = await [a, b, c]
        XCTAssertEqual(results.filter { $0 }.count, 2, "one /f run and one /g run")
        XCTAssertEqual(counter.runList.sorted(), ["/f", "/g"])
    }

    func testThrottleBoundaryIsExactlyTenMinutes() async {
        let counter = Counter()
        let refresher = NativeClaude.Refresher(now: { counter.now }) { counter.run($0) }
        let first = await refresher.refresh("")
        XCTAssertTrue(first)
        counter.advance(599.9)
        let throttled = await refresher.refresh("")
        XCTAssertFalse(throttled)
        counter.advance(0.1)
        let allowed = await refresher.refresh("")
        XCTAssertTrue(allowed)
        XCTAssertEqual(counter.runList, ["", ""])
    }

    func testExpiredLoadsExactlyTwiceAndHintsWhenRenewalDoesNotHelp() async throws {
        let counter = Counter()
        let refresher = NativeClaude.Refresher(now: { counter.now }) { counter.run($0) }
        let rows = await NativeClaude.fetch(profile: "/work/claude", home: "/Users/x", refresher: refresher,
                                            load: { _ in _ = counter.load(); return .failure(.expired) },
                                            transport: { _ in XCTFail("no request with a dead token"); return Data() })
        XCTAssertEqual(counter.runList, ["/work/claude"])
        XCTAssertEqual(counter.loadCount, 2, "initial read + one re-read after renewal")
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].id)
        XCTAssertEqual(rows[0].usage.error, NativeClaude.Failure.expired.rawValue)
        XCTAssertEqual(rows[0].usage.hint, "run claude in /work/claude", "folders outside home keep their absolute path")
        XCTAssertFalse(rows[0].usage.isTransient)
    }

    func testThrottledExpiryDoesNotReread() async {
        let counter = Counter()
        let refresher = NativeClaude.Refresher(now: { counter.now }) { counter.run($0) }
        _ = await refresher.refresh("")
        let rows = await NativeClaude.fetch(profile: "", home: "/Users/x", refresher: refresher,
                                            load: { _ in _ = counter.load(); return .failure(.expired) },
                                            transport: { _ in Data() })
        XCTAssertEqual(counter.loadCount, 1)
        XCTAssertEqual(counter.runList, [""])
        XCTAssertEqual(rows.first?.usage.hint, "run claude in ~/.claude")
    }

    func testUsage401AfterVerifiedProfileRenewsAndKeepsIdentityWithHint() async throws {
        let credential = try NativeClaude.credential(fixture("claude-native-auth"))
        let profile = try fixture("claude-native-profile")
        let counter = Counter()
        let refresher = NativeClaude.Refresher(now: { counter.now }) { counter.run($0) }
        let rows = await NativeClaude.fetch(profile: "/Users/x/.claude-me", home: "/Users/x", refresher: refresher,
                                            load: { _ in .success(credential) }) { request in
            if request.url!.lastPathComponent == "profile" { return profile }
            throw NativeClaude.Failure.expired
        }
        XCTAssertEqual(counter.runList, ["/Users/x/.claude-me"])
        XCTAssertEqual(rows.first?.id, "claude/00000000-0000-0000-0000-000000000001/00000000-0000-0000-0000-000000000002")
        XCTAssertEqual(rows.first?.usage.hint, "run claude in ~/.claude-me")

        // LastGood matches the verified id and keeps the previous numbers with the hint.
        var good = RowUsage(windows: [UsageWindow(label: "WK", percentLeft: 55, resetsAt: nil)], observedAt: Date())
        good.identity = nil
        let previous = UsageSnapshot(claude: [ClaudeAccount(profile: "~/.claude-me", email: "native@example.com", usage: good,
                                                            id: rows.first?.id, plan: "Max")])
        let merged = LastGood.merge(fresh: UsageSnapshot(claude: rows), previous: previous)
        XCTAssertEqual(merged.claude.count, 1)
        XCTAssertTrue(merged.claude[0].usage.isStale)
        XCTAssertNil(merged.claude[0].usage.error)
        XCTAssertEqual(merged.claude[0].usage.hint, "run claude in ~/.claude-me")
        XCTAssertEqual(merged.claude[0].usage.windows.first?.percentLeft, 55)
    }

    func testForbiddenAndMalformedNeverRunClaudeOrHint() async {
        let counter = Counter()
        let refresher = NativeClaude.Refresher(now: { counter.now }) { counter.run($0) }
        for failure in [NativeClaude.Failure.malformed, .forbidden, .rateLimited, .timeout, .unsupportedProfile] {
            let rows = await NativeClaude.fetch(profile: "/f", home: "/Users/x", refresher: refresher,
                                                load: { _ in .failure(failure) }, transport: { _ in Data() })
            XCTAssertNil(rows.first?.usage.hint, "\(failure)")
        }
        XCTAssertEqual(counter.runList, [])
    }

    // MARK: LastGood with hints

    private func good(_ left: Double) -> RowUsage {
        RowUsage(windows: [UsageWindow(label: "WK", percentLeft: left, resetsAt: nil)], observedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testExpiredHintDoesNotBorrowAnotherFoldersRow() {
        let previous = UsageSnapshot(claude: [ClaudeAccount(profile: "~/.claude-me", email: "a@example.com", usage: good(40), id: "claude/a/o")])
        var expired = RowUsage.failure(NativeClaude.Failure.expired.rawValue)
        expired.hint = "run claude in ~/.claude"
        let fresh = UsageSnapshot(claude: [ClaudeAccount(profile: "~/.claude", email: "~/.claude", usage: expired)])
        let merged = LastGood.merge(fresh: fresh, previous: previous)
        XCTAssertEqual(merged.claude[0].usage.error, NativeClaude.Failure.expired.rawValue)
        XCTAssertNil(merged.claude[0].id)
    }

    func testStaleHintedRowSurvivesRepeatedExpiryAndPersists() throws {
        let previous = UsageSnapshot(claude: [ClaudeAccount(profile: "~/.claude", email: "a@example.com", usage: good(40), id: "claude/a/o", plan: "Ultra")])
        var expired = RowUsage.failure(NativeClaude.Failure.expired.rawValue)
        expired.hint = "run claude in ~/.claude"
        let fresh = UsageSnapshot(claude: [ClaudeAccount(profile: "~/.claude", email: "~/.claude", usage: expired)])
        let once = LastGood.merge(fresh: fresh, previous: previous)
        let twice = LastGood.merge(fresh: fresh, previous: once)
        XCTAssertEqual(twice.claude[0].usage.windows.first?.percentLeft, 40)
        XCTAssertTrue(twice.claude[0].usage.isStale)
        XCTAssertEqual(twice.claude[0].usage.hint, "run claude in ~/.claude")
        XCTAssertEqual(twice.claude[0].title, "a@example.com · Ultra")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try LastGood.save(twice, to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("fake-claude-access-token"))
        XCTAssertFalse(text.lowercased().contains("token"))
        let loaded = try XCTUnwrap(LastGood.load(from: url))
        XCTAssertEqual(loaded.claude.first?.plan, "Ultra")
    }

    func testSnapshotFromBeforeThisChangeStillLoads() throws {
        // Older snapshots carried a kimi row and no plan/hint fields.
        let old = #"""
        {"codex":{"windows":[],"isTransient":false,"isStale":false,"isConfigured":true},
         "kimi":{"windows":[],"isTransient":false,"isStale":false,"isConfigured":false,"error":"not configured"},
         "claude":[{"profile":"~/.claude","email":"a@example.com","id":"claude/a/o",
                    "usage":{"windows":[{"label":"WK","percentLeft":40}],"isTransient":false,"isStale":false,"isConfigured":true}}]}
        """#
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(old.utf8).write(to: url)
        let loaded = try XCTUnwrap(LastGood.load(from: url))
        XCTAssertEqual(loaded.claude.first?.usage.windows.first?.percentLeft, 40)
        XCTAssertNil(loaded.claude.first?.plan)
    }

    // MARK: Server-listed meters

    func testLimitsSkipUnknownKindsMissingPercentAndUnnamedModels() throws {
        let body = #"""
        {"limits":[{"kind":"session","percent":null},
                   {"kind":"weekly_all","percent":30,"resets_at":"2030-01-07T08:00:00Z"},
                   {"kind":"weekly_scoped","percent":10,"scope":{"model":null}},
                   {"kind":"weekly_scoped","percent":10,"scope":{"model":{"display_name":""}}},
                   {"kind":"monthly_something","percent":50},
                   {"kind":"weekly_scoped","percent":100,"scope":{"model":{"display_name":"Opus 4"}}}]}
        """#
        let usage = try NativeClaude.usage(json(body))
        XCTAssertEqual(usage.windows.map(\.label), ["WK", "OPUS 4"])
        XCTAssertEqual(usage.windows.map(\.percentLeft), [70, 0])
    }

    func testFallbackOnlyWhenLimitsAbsent() throws {
        let fallback = try NativeClaude.usage(json(#"{"five_hour":{"utilization":10},"seven_day":{"utilization":20}}"#))
        XCTAssertEqual(fallback.windows.map(\.label), ["5H", "WK"])
        let nullLimits = try NativeClaude.usage(json(#"{"five_hour":null,"seven_day":{"utilization":20},"limits":null}"#))
        XCTAssertEqual(nullLimits.windows.map(\.label), ["WK"])
    }

    func testRealFixtureWeeklyScopedIsFable() throws {
        for name in ["claude-real-usage", "claude-real-usage-no-session"] {
            let usage = try NativeClaude.usage(fixture(name))
            XCTAssertEqual(usage.windows.last?.label, "FABLE", name)
            XCTAssertFalse(usage.windows.contains { $0.label == "5H" } && name.hasSuffix("no-session"))
        }
    }

    // MARK: Plan label

    func testEmptyOrMissingPlanFallsBackToEmailOnly() throws {
        let base = try String(decoding: fixture("claude-real-profile"), as: UTF8.self)
        let empty = Data(base.replacingOccurrences(of: #""plan_display_name": "Ultra""#, with: #""plan_display_name": """#).utf8)
        let account = try NativeClaude.account(profile: empty, usage: RowUsage())
        XCTAssertNil(account.plan)
        XCTAssertEqual(account.title, "ultra@example.com")
        let null = Data(base.replacingOccurrences(of: #""plan_display_name": "Ultra""#, with: #""plan_display_name": null"#).utf8)
        XCTAssertNil(try NativeClaude.account(profile: null, usage: RowUsage()).plan)
    }

    // MARK: Folders

    func testFolderListEdgeCases() {
        let home = "/Users/x"
        // ~/.claude-* without .claude.json is ignored unless the user added it explicitly.
        let list = NativeClaude.profiles(environment: [:], home: home, entries: [".claude-old", ".claude", ".claudette", ".claude-me"],
                                         folders: ["/Users/x/.claude-old", "/Users/x/.claude/"],
                                         hasConfig: { $0.hasSuffix("-me") })
        XCTAssertEqual(list, ["", "/Users/x/.claude-me", "/Users/x/.claude-old"])
        // The default folder is never duplicated, even when added with a trailing slash.
        XCTAssertEqual(list.filter { $0.isEmpty }.count, 1)
        XCTAssertEqual(NativeClaude.label(profile: "/Users/x/.claude-old", home: home), "~/.claude-old")
        XCTAssertEqual(NativeClaude.label(profile: "/Users/xy/.claude", home: home), "/Users/xy/.claude")
    }

    func testMultipleFoldersRenewIndependentlyInOneFetch() async throws {
        let credential = try NativeClaude.credential(fixture("claude-native-auth"))
        let profile = try fixture("claude-native-profile"), usage = try fixture("claude-native-usage")
        let counter = Counter()
        let refresher = NativeClaude.Refresher(now: { counter.now }) { counter.run($0) }
        let rows = await NativeClaude.fetch(profiles: ["", "/a", "/b"], home: "/Users/x", refresher: refresher,
                                            load: { p in p == "/b" ? .success(credential) : .failure(.expired) }) { request in
            request.url!.lastPathComponent == "profile" ? profile : usage
        }
        XCTAssertEqual(counter.runList.sorted(), ["", "/a"])
        XCTAssertEqual(rows.map(\.usage.hint), ["run claude in ~/.claude", "run claude in /a", nil])
    }
}
