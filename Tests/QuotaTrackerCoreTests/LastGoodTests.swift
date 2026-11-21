import XCTest
@testable import QuotaTrackerCore

final class LastGoodTests: XCTestCase {
    let at = Date(timeIntervalSince1970: 1_800_000_000)

    func good(_ left: Double, identity: String? = nil) -> RowUsage {
        var row = RowUsage(windows: [UsageWindow(label: "WK", percentLeft: left, resetsAt: at.addingTimeInterval(3600))], observedAt: at)
        row.identity = identity
        return row
    }

    func claude(_ usage: RowUsage, id: String? = "claude/a/o", profile: String = "~/.claude") -> ClaudeAccount {
        ClaudeAccount(profile: profile, email: id == nil ? profile : "a@example.com", usage: usage, id: id)
    }

    func testTransientFailureKeepsPreviousGoodRowAsStale() {
        let previous = UsageSnapshot(codex: good(70, identity: "c"), claude: [claude(good(40))])
        let fresh = UsageSnapshot(codex: .failure("network error", transient: true),
                                  claude: [claude(.failure("network error", transient: true), id: nil)])
        let merged = LastGood.merge(fresh: fresh, previous: previous)
        XCTAssertEqual(merged.codex.windows, previous.codex.windows)
        XCTAssertTrue(merged.codex.isStale)
        XCTAssertNil(merged.codex.error)
        XCTAssertEqual(merged.claude.first?.id, "claude/a/o")
        XCTAssertEqual(merged.claude.first?.usage.windows.first?.percentLeft, 40)
        XCTAssertTrue(merged.claude.first?.usage.isStale == true)
        XCTAssertEqual(merged.codex.observedAt, at)
        // Still stale on the next transient failure, keeping the original fetch time.
        let again = LastGood.merge(fresh: fresh, previous: merged)
        XCTAssertTrue(again.codex.isStale)
        XCTAssertEqual(again.codex.observedAt, at)
    }

    func testNonTransientFailureReplacesCachedRow() {
        let previous = UsageSnapshot(codex: good(70), claude: [claude(good(40))])
        let fresh = UsageSnapshot(codex: .failure("expired — log in Codex"), claude: [claude(.failure("expired — log in Claude"))])
        let merged = LastGood.merge(fresh: fresh, previous: previous)
        XCTAssertEqual(merged, fresh)
        var other = RowUsage.failure("timed out", transient: true)
        other.identity = "different"
        XCTAssertEqual(LastGood.merge(fresh: UsageSnapshot(codex: other), previous: UsageSnapshot(codex: good(1, identity: "k"))).codex, other)
    }

    func testExpiredWithHintKeepsPreviousGoodRowWithHint() {
        let previous = UsageSnapshot(claude: [ClaudeAccount(profile: "~/.claude", email: "a@example.com", usage: good(40), id: "claude/a/o", plan: "Ultra")])
        var expired = RowUsage.failure("expired — log in Claude")
        expired.hint = "run claude in ~/.claude"
        let merged = LastGood.merge(fresh: UsageSnapshot(claude: [claude(expired, id: nil)]), previous: previous)
        let row = merged.claude[0]
        XCTAssertEqual(row.id, "claude/a/o")
        XCTAssertEqual(row.title, "a@example.com · Ultra")
        XCTAssertNil(row.usage.error)
        XCTAssertTrue(row.usage.isStale)
        XCTAssertEqual(row.usage.hint, "run claude in ~/.claude")
        XCTAssertEqual(row.usage.windows.first?.percentLeft, 40)
        // No previous good row: the bare error stays.
        XCTAssertEqual(LastGood.merge(fresh: UsageSnapshot(claude: [claude(expired, id: nil)]), previous: UsageSnapshot()).claude[0].usage.error,
                       "expired — log in Claude")
        // A later success clears the hint.
        let ok = LastGood.merge(fresh: UsageSnapshot(claude: [claude(good(30))]), previous: merged)
        XCTAssertNil(ok.claude[0].usage.hint)
        XCTAssertFalse(ok.claude[0].usage.isStale)
    }

    func testFreshSuccessClearsStale() {
        var stale = good(70)
        stale.isStale = true
        let merged = LastGood.merge(fresh: UsageSnapshot(codex: good(60)), previous: UsageSnapshot(codex: stale))
        XCTAssertFalse(merged.codex.isStale)
        XCTAssertEqual(merged.codex.windows.first?.percentLeft, 60)
    }

    func testPersistenceRoundTripAndCorruptFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("last-snapshot.json")
        let snapshot = UsageSnapshot(codex: good(70, identity: "c"),
                                     claude: [claude(good(40)), claude(.failure("expired"), id: nil, profile: "~/.claude-x")])
        try LastGood.save(snapshot, to: url)
        let loaded = try XCTUnwrap(LastGood.load(from: url))
        XCTAssertEqual(loaded.codex.windows, snapshot.codex.windows)
        XCTAssertEqual(loaded.codex.observedAt, at)
        XCTAssertTrue(loaded.codex.isStale)
        XCTAssertEqual(loaded.claude.map(\.id), ["claude/a/o"])
        XCTAssertTrue(loaded.claude[0].usage.isStale)

        try Data("{not json".utf8).write(to: url)
        XCTAssertNil(LastGood.load(from: url))
        XCTAssertNil(LastGood.load(from: dir.appendingPathComponent("missing.json")))
    }

    func testPastResetOnStaleRowReadsAsReset() {
        var row = RowUsage(windows: [UsageWindow(label: "5H", percentLeft: 10, resetsAt: at.addingTimeInterval(-60))])
        row.isStale = true
        let reset = LastGood.resettingPast(UsageSnapshot(codex: row), now: at)
        XCTAssertEqual(reset.codex.windows.first?.percentLeft, 100)
        XCTAssertNil(reset.codex.windows.first?.resetsAt)
    }

    func testErrorClassification() {
        for code in [URLError.Code.notConnectedToInternet, .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost] {
            XCTAssertTrue(DirectSources.isTransient(URLError(code)), "\(code)")
            XCTAssertTrue(DirectSources.networkFailure(URLError(code)).isTransient)
        }
        XCTAssertFalse(DirectSources.isTransient(URLError(.userAuthenticationRequired)))
        XCTAssertFalse(DirectSources.isTransient(NSError(domain: "x", code: 1)))
        XCTAssertTrue(DirectSources.httpFailure(500).isTransient)
        XCTAssertTrue(DirectSources.httpFailure(503).isTransient)
        XCTAssertTrue(DirectSources.httpFailure(429).isTransient)
        XCTAssertFalse(DirectSources.httpFailure(401).isTransient)
        XCTAssertFalse(DirectSources.httpFailure(403).isTransient)
        XCTAssertTrue(NativeClaude.Failure.network.isTransient)
        XCTAssertTrue(NativeClaude.Failure.rateLimited.isTransient)
        XCTAssertFalse(NativeClaude.Failure.expired.isTransient)
        XCTAssertFalse(NativeClaude.Failure.forbidden.isTransient)
    }
}
