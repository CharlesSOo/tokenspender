import Foundation
import XCTest
import Darwin
@testable import TokenSpenderCore

final class FinalVerificationTests: XCTestCase {
    func testMalformedPresentKimiOAuthIsVisibleError() {
        for json in [
            #"{"kimi-coding":{"type":"oauth"}}"#,
            #"{"kimi-coding":{"type":"oauth","access":""}}"#,
            #"{"kimi-coding":{"type":"oauth","access":42}}"#,
            #"{"kimi-coding":{"type":"oauth","access":"fake","expires":"broken"}}"#,
            #"{"kimi-coding":null}"#
        ] {
            XCTAssertEqual(DirectSources.piCredential("kimi-coding", authJSON: Data(json.utf8)), .failure(.unreadable), json)
        }
    }

    func testMalformedPresentCodexEmptyAccessIsVisibleError() {
        XCTAssertEqual(DirectSources.codexCredential(authJSON: Data(#"{"tokens":{"access_token":""}}"#.utf8)), .failure(.unreadable))
    }

    func testMissingKimiAndUnrelatedMalformedEntryRemainHidden() {
        for json in ["{}", #"{"other":{"type":"oauth","access":42}}"#] {
            XCTAssertEqual(DirectSources.piCredential("kimi-coding", authJSON: Data(json.utf8)), .failure(.missing))
        }
        XCTAssertEqual(DirectSources.piCredential("kimi-coding", authJSON: Data(#"{"other":null,"kimi-coding":{"type":"oauth","access":"fake","expires":0}}"#.utf8)), .failure(.expired))
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

    func testSuccessKillsDetachedOutputDescendantBeforeReaping() async throws {
        let file = NSTemporaryDirectory() + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: file) }
        let output = await Fetcher.run("/bin/sh", ["-c", "sleep 1; (sleep 0.5; echo survived > '\(file)') >/dev/null 2>&1 & printf done"], timeout: 3)
        XCTAssertEqual(output, Data("done".utf8))
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file), "Successful parent exit must kill its group even if descendant closes stdout")
    }

    func testEOFStillHonorsChildDeadline() async {
        let start = Date()
        let result = await Fetcher.run("/bin/sh", ["-c", "exec 1>&-; trap '' TERM; sleep 20"], timeout: 0.15)
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}
