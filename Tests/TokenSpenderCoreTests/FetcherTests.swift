import XCTest
@testable import TokenSpenderCore

final class FetcherTests: XCTestCase {
    func testSuccessAndNonzeroExit() async {
        let good = await Fetcher.run("/bin/sh", ["-c", "printf hello"], timeout: 1)
        XCTAssertEqual(good, Data("hello".utf8))
        let bad = await Fetcher.run("/bin/sh", ["-c", "printf partial; exit 2"], timeout: 1)
        XCTAssertNil(bad)
        let missing = await Fetcher.run("/missing-executable", [], timeout: 1)
        XCTAssertNil(missing)
    }

    func testTermIgnoringChildAndDescendantPipeAreBounded() async {
        for script in ["trap '' TERM; while :; do sleep 1; done", "sleep 10 & exit 0", "exec 1>&-; sleep 10"] {
            let start = Date()
            let result = await Fetcher.run("/bin/sh", ["-c", script], timeout: 0.15)
            XCTAssertNil(result)
            XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        }
    }

    func testOutputBoundAndRepeatedReaping() async {
        let flood = await Fetcher.run("/usr/bin/yes", [], timeout: 1, maxOutput: 1024)
        XCTAssertNil(flood)
        for _ in 0..<25 {
            let output = await Fetcher.run("/bin/echo", ["ok"], timeout: 1)
            XCTAssertEqual(output, Data("ok\n".utf8))
        }
    }
}

extension FetcherTests {
    func testTimedOutDirectChildIsReaped() async throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = await Fetcher.run("/bin/sh", ["-c", "echo $$ > '\(file.path)'; exec sleep 10"], timeout: 0.15)
        XCTAssertNil(result)
        let pid = try XCTUnwrap(Int32(String(contentsOf: file).trimmingCharacters(in: .whitespacesAndNewlines)))
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
    }
}
