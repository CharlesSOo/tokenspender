import Foundation
import XCTest
@testable import QuotaTrackerCore

final class FinalVerificationTests: XCTestCase {
    func testMalformedPresentCodexEmptyAccessIsVisibleError() {
        XCTAssertEqual(DirectSources.codexCredential(authJSON: Data(#"{"tokens":{"access_token":""}}"#.utf8)), .failure(.unreadable))
    }

    func testETAMinimumSpanAndResetBoundary() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        func samples(_ span: Double) -> [UsageSample] {
            [90.0, 80, 70].enumerated().map { UsageSample(at: start.addingTimeInterval(Double($0.offset) * span / 2), percentLeft: $0.element) }
        }
        XCTAssertNil(BurnRate.eta(samples: samples(899)))
        let accepted = samples(900), now = start.addingTimeInterval(900)
        let eta = try XCTUnwrap(BurnRate.eta(samples: accepted))
        XCTAssertEqual(eta, 3150, accuracy: 0.001)
        let resettingFirst = RowUsage(windows: [UsageWindow(label: "5H", percentLeft: 70, resetsAt: now.addingTimeInterval(eta))])
        XCTAssertNil(BurnRate.label(usage: resettingFirst, history: { _ in accepted }, now: now))
        let resettingLater = RowUsage(windows: [UsageWindow(label: "5H", percentLeft: 70, resetsAt: now.addingTimeInterval(eta + 1))])
        XCTAssertNotNil(BurnRate.label(usage: resettingLater, history: { _ in accepted }, now: now))
        XCTAssertNil(BurnRate.label(usage: resettingLater, history: { _ in accepted }, now: now.addingTimeInterval(901)))
    }
}
