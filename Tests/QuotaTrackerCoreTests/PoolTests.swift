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
        XCTAssertEqual(pool.title, "CLAUDE POOL · 20× Pro")
        XCTAssertFalse(pool.isEstimated)
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
        XCTAssertFalse(pool.isEstimated) // the failed row's missing plan does not count
        XCTAssertEqual(try XCTUnwrap(pool.now), 20, accuracy: 1e-9)
        XCTAssertNil(ClaudePool(accounts: [empty, failed]).now)
        XCTAssertEqual(ClaudePool(accounts: [empty, failed]).title, "CLAUDE POOL")
    }

    func testUnknownPlanWeighsOneAndIsEstimated() throws {
        let pool = ClaudePool(accounts: [account(nil, [("5H", 100), ("WK", 100)]), account("Team", [("5H", 0), ("WK", 0)]), account("Pro", [("5H", 40), ("WK", 40)])])
        XCTAssertEqual(pool.size, 3)
        XCTAssertTrue(pool.isEstimated)
        XCTAssertEqual(try XCTUnwrap(pool.now), (100 + 0 + 40) / 3, accuracy: 1e-9)
        XCTAssertEqual(PlanWeight.of("ultra"), 10)
        XCTAssertNil(PlanWeight.of(nil))
    }

    func testStaleFooterNamesExpiredLoginVersusOffline() {
        let now = Date(timeIntervalSince1970: 100_000)
        var expired = RowUsage(windows: [UsageWindow(label: "WK", percentLeft: 50, resetsAt: nil)], observedAt: now.addingTimeInterval(-3 * 3600))
        expired.isStale = true
        expired.hint = "run claude in ~/.claude-me"
        XCTAssertEqual(Footer.stale([expired], now: now), "LOGIN EXPIRED · UPDATED 3H AGO")
        var offline = expired
        offline.hint = nil
        XCTAssertEqual(Footer.stale([offline], now: now), "OFFLINE · UPDATED 3H AGO")
        XCTAssertNil(Footer.stale([RowUsage(windows: expired.windows, observedAt: now)], now: now))
    }

    func testExpiredLoginMergeYieldsLoginExpiredFooter() {
        let now = Date(timeIntervalSince1970: 100_000)
        let good = ClaudeAccount(profile: "~/.claude", email: "a@example.com",
                                 usage: RowUsage(windows: [UsageWindow(label: "WK", percentLeft: 50, resetsAt: nil)], observedAt: now.addingTimeInterval(-600)),
                                 id: "claude/a/o", plan: "Ultra")
        var failure = RowUsage.failure("expired")
        failure.hint = "run claude in ~/.claude"
        let merged = LastGood.merge(fresh: UsageSnapshot(claude: [ClaudeAccount(profile: "~/.claude", email: "~/.claude", usage: failure, id: "claude/a/o")]),
                                    previous: UsageSnapshot(claude: [good]))
        XCTAssertEqual(Footer.stale(merged.claude.map(\.usage), now: now), "LOGIN EXPIRED · UPDATED 10M AGO")
        XCTAssertEqual(ClaudePool(accounts: merged.claude).now, 50)
    }
}
