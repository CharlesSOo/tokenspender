import Foundation
import XCTest
@testable import QuotaTrackerCore

final class ParseTests: XCTestCase {
    func testDateParsing() {
        XCTAssertNotNil(Parse.date("2026-10-08T09:38:41Z"))
        XCTAssertNotNil(Parse.date("2026-10-08T09:38:41.123456+00:00"))
    }

    func testModesAndWeeklyExhaustion() {
        func row(_ five: Double, _ week: Double) -> RowUsage {
            RowUsage(windows: [UsageWindow(label: "5H", percentLeft: five, resetsAt: nil), UsageWindow(label: "WK", percentLeft: week, resetsAt: nil)])
        }
        let snapshot = UsageSnapshot(codex: row(80, 40), claude: [ClaudeAccount(profile: "~/.claude", email: "a@example.com", usage: row(100, 0)), ClaudeAccount(profile: "~/.claude-b", email: "b@example.com", usage: row(60, 80))])
        XCTAssertEqual(MenuLabel.text(mode: .availableNow, snapshot: snapshot), "33%")
        XCTAssertEqual(MenuLabel.text(mode: .lowest, snapshot: snapshot), "0%")
        XCTAssertEqual(MenuLabel.text(mode: .claudePool, snapshot: snapshot), "30%")
        XCTAssertEqual(MenuLabel.text(mode: .codexPool, snapshot: snapshot), "40%")
        XCTAssertNil(AvailableNow.share(rows: [.notConfigured, .failure("expired")]))
        XCTAssertNil(Pool.share(label: "WK", accounts: []))
        XCTAssertEqual(DisplayMode.allCases.map(\.title), ["Available now", "Lowest account", "Claude pool", "Codex pool"])
        XCTAssertEqual(Pool.summary(accounts: [row(80, 40)]), "5H 80% · WK 40%")
    }

    func testBurnRateRequiresDistinctFreshDeclinesAndFutureResetIsNotCutoff() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let samples = [90.0, 80, 70].enumerated().map { UsageSample(at: start.addingTimeInterval(Double($0.offset) * 450), percentLeft: $0.element) }
        XCTAssertEqual(BurnRate.eta(samples: samples)!, 3150, accuracy: 0.01)
        XCTAssertNil(BurnRate.eta(samples: samples.map { UsageSample(at: $0.at, percentLeft: 70) }))
        XCTAssertNil(BurnRate.eta(samples: [samples[0], samples[0], samples[2]]))
        XCTAssertNil(BurnRate.eta(samples: samples + [UsageSample(at: start.addingTimeInterval(1000), percentLeft: 99)]))
        let now = start.addingTimeInterval(900)
        let usage = RowUsage(windows: [UsageWindow(label: "5H", percentLeft: 70, resetsAt: now.addingTimeInterval(3600))])
        XCTAssertEqual(BurnRate.label(usage: usage, history: { _ in samples }, now: now), "5h burnt in ~55m")
        XCTAssertNil(BurnRate.label(usage: usage, history: { _ in samples }, now: now.addingTimeInterval(901)))
    }

    func testHistoryDeduplicatesCacheAndBounds() {
        var history = SampleHistory()
        let start = Date(timeIntervalSince1970: 1_000_000)
        for _ in 0..<30 { history.append("a", UsageSample(at: start, percentLeft: 90)) }
        XCTAssertEqual(history.samples("a").count, 1)
        for i in 1...400 { history.append("a", UsageSample(at: start.addingTimeInterval(Double(i)), percentLeft: 80)) }
        XCTAssertEqual(history.samples("a").count, SampleHistory.maxCount)
        XCTAssertNil(BurnRate.eta(samples: history.samples("a")))
        history.retain(keys: [], now: start)
        XCTAssertTrue(history.samples("a").isEmpty)
    }

    func testResetLineAndDuplicateLabels() {
        let now = Date(timeIntervalSince1970: 0)
        let windows = [UsageWindow(label: "5H", percentLeft: 20, resetsAt: now.addingTimeInterval(3600)), UsageWindow(label: "WK", percentLeft: 90, resetsAt: now.addingTimeInterval(86400))]
        XCTAssertEqual(ResetFormat.line(for: windows, now: now), "5h resets 1h 0m · wk resets 1d 0h")
        let duplicate = DirectSources.parseCodex(Data(#"{"rate_limit":{"primary_window":{"used_percent":10},"secondary_window":{"used_percent":20}}}"#.utf8))
        XCTAssertEqual(duplicate.windows.map(\.label), ["5H", "5H"])
        XCTAssertEqual(duplicate.windows.map(\.percentLeft), [90, 80])
    }
}

extension ParseTests {
    func testNoisyLeastSquaresRate() {
        let start = Date(timeIntervalSince1970: 0)
        let noisy = [100.0, 90, 81, 70].enumerated().map { UsageSample(at: start.addingTimeInterval(Double($0.offset) * 300), percentLeft: $0.element) }
        XCTAssertEqual(BurnRate.eta(samples: noisy)!, 70 / (9.9 / 300), accuracy: 1)
    }
}
