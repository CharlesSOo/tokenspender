import Foundation
import XCTest
@testable import QuotaTrackerCore

final class PoolTests: XCTestCase {
    private func account(_ plan: String?, _ windows: [(String, Double)], stale: Bool = false) -> ClaudeAccount {
        var usage = RowUsage(windows: windows.map { UsageWindow(label: $0.0, percentLeft: $0.1, resetsAt: nil) })
        usage.isStale = stale
        return ClaudeAccount(profile: "~/.claude", email: "a@example.com", usage: usage, plan: plan)
    }

    private func value(_ pool: ClaudePool, _ label: String) -> Double? {
        pool.lines.first { $0.label == label }?.percentLeft
    }

    func testTwoUltraAccountsArePlainMean() throws {
        let pool = ClaudePool(accounts: [account("Ultra", [("5H", 80), ("WK", 60)]), account("Ultra", [("5H", 40), ("WK", 20)])])
        XCTAssertEqual(pool.size, 20)
        XCTAssertEqual(try XCTUnwrap(pool.now), 40, accuracy: 1e-9) // mean(min(80,60), min(40,20))
        XCTAssertEqual(try XCTUnwrap(value(pool, "WK")), 40, accuracy: 1e-9)
        XCTAssertEqual(pool.lines.map(\.label), ["NOW", "WK"])
    }

    func testUltraAndMaxWeighTenToFive() throws {
        let pool = ClaudePool(accounts: [account("Ultra", [("5H", 90), ("WK", 90)]), account("Max", [("5H", 30), ("WK", 60)])])
        XCTAssertEqual(pool.size, 15)
        XCTAssertEqual(try XCTUnwrap(pool.now), (10 * 90 + 5 * 30) / 15, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(value(pool, "WK")), (10 * 90 + 5 * 60) / 15, accuracy: 1e-9)
    }

    func testMissingFiveHourCountsAsFull() throws {
        let pool = ClaudePool(accounts: [account("Ultra", [("WK", 100)]), account("Max", [("5H", 10), ("WK", 80)])])
        XCTAssertEqual(try XCTUnwrap(pool.now), (10 * 100 + 5 * 10) / 15, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(value(pool, "WK")), (10 * 100 + 5 * 80) / 15, accuracy: 1e-9)
    }

    func testModelScopedLineIsSeparateAndDoesNotLowerNow() throws {
        let pool = ClaudePool(accounts: [account("Ultra", [("5H", 70), ("WK", 80), ("FABLE", 0)]), account("Ultra", [("5H", 50), ("WK", 60)])])
        XCTAssertEqual(pool.lines.map(\.label), ["NOW", "WK", "FABLE"])
        XCTAssertEqual(try XCTUnwrap(pool.now), 60, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(value(pool, "FABLE")), 0, accuracy: 1e-9) // only the account that has it
    }

    func testStaleRowIncludedEmptyAndErrorRowsExcluded() throws {
        let stale = account("Max", [("5H", 20), ("WK", 50)], stale: true)
        let empty = account("Ultra", [])
        let failed = ClaudeAccount(profile: "~/.claude-x", email: "~/.claude-x", usage: .failure("expired"))
        let pool = ClaudePool(accounts: [stale, empty, failed])
        XCTAssertEqual(pool.size, 5)
        XCTAssertEqual(try XCTUnwrap(pool.now), 20, accuracy: 1e-9)
        XCTAssertNil(ClaudePool(accounts: [empty, failed]).now)
        XCTAssertEqual(ClaudePool(accounts: [empty, failed]).size, 0)
    }

    func testUnknownPlanWeighsOne() throws {
        let pool = ClaudePool(accounts: [account(nil, [("5H", 100), ("WK", 100)]), account("Team", [("5H", 0), ("WK", 0)]), account("Pro", [("5H", 40), ("WK", 40)])])
        XCTAssertEqual(pool.size, 3)
        XCTAssertEqual(try XCTUnwrap(pool.now), (100 + 0 + 40) / 3, accuracy: 1e-9)
        XCTAssertEqual(PlanWeight.of("ultra"), 10)
        XCTAssertNil(PlanWeight.of(nil))
    }

    func testFooterSaysOfflineOnlyForNetworkStaleRows() {
        let now = Date(timeIntervalSince1970: 100_000)
        var renewing = RowUsage(windows: [UsageWindow(label: "WK", percentLeft: 50, resetsAt: nil)], observedAt: now.addingTimeInterval(-3 * 3600))
        renewing.isStale = true
        XCTAssertNil(Footer.offline([renewing], now: now), "a login being renewed is only dimmed")
        var signedOut = renewing
        signedOut.hint = "signed out · run claude in ~/.claude-me"
        XCTAssertNil(Footer.offline([signedOut], now: now))
        var offline = renewing
        offline.isTransient = true
        XCTAssertEqual(Footer.offline([renewing, offline], now: now), "OFFLINE · UPDATED 3H AGO")
        XCTAssertNil(Footer.offline([RowUsage(windows: renewing.windows, observedAt: now)], now: now))
    }

    func testExpiredLoginKeepsDimmedNumbersWithoutHintOrOfflineFooter() {
        let now = Date(timeIntervalSince1970: 100_000)
        let good = ClaudeAccount(profile: "~/.claude", email: "a@example.com",
                                 usage: RowUsage(windows: [UsageWindow(label: "WK", percentLeft: 50, resetsAt: nil)], observedAt: now.addingTimeInterval(-600)),
                                 id: "claude/a/o", plan: "Ultra")
        let expired = ClaudeAccount(profile: "~/.claude", email: "~/.claude", usage: .failure(NativeClaude.Failure.expired.rawValue), id: "claude/a/o")
        let merged = LastGood.merge(fresh: UsageSnapshot(claude: [expired]), previous: UsageSnapshot(claude: [good]))
        XCTAssertTrue(merged.claude[0].usage.isStale)
        XCTAssertNil(merged.claude[0].hint)
        XCTAssertNil(Footer.offline(merged.claude.map(\.usage), now: now))
        XCTAssertEqual(ClaudePool(accounts: merged.claude).now, 50)

        // Signed out (renewal failed twice): same dimmed numbers, now with the hint.
        var signedOut = expired
        signedOut.usage.hint = NativeClaude.signedOutHint("~/.claude")
        let kept = LastGood.merge(fresh: UsageSnapshot(claude: [signedOut]), previous: merged)
        XCTAssertEqual(kept.claude[0].hint, "signed out · run claude in ~/.claude")
        XCTAssertEqual(kept.claude[0].usage.windows.first?.percentLeft, 50)
    }

    func testExpiredWithoutLastGoodShowsSignedOutHintNeverExpired() {
        let failed = ClaudeAccount(profile: "~/.claude-me", email: "~/.claude-me", usage: .failure(NativeClaude.Failure.expired.rawValue))
        let merged = LastGood.merge(fresh: UsageSnapshot(claude: [failed]), previous: UsageSnapshot())
        XCTAssertEqual(merged.claude[0].hint, "signed out · run claude in ~/.claude-me")
        XCTAssertFalse(NativeClaude.Failure.expired.rawValue.contains("expired"))
        XCTAssertFalse(CodexOAuth.Failure.loginRequired.rawValue.contains("expired"))
        XCTAssertEqual(Parse.quiet("HTTP 401"), "signed out")
        let network = ClaudeAccount(profile: "~/.claude", email: "~/.claude", usage: .failure("network error", transient: true))
        XCTAssertNil(network.hint)
    }
}
