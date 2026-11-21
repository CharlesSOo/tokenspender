import Foundation
import XCTest
@testable import QuotaTrackerCore

/// The renewal runner: process group cleanup on timeout, stdout read to EOF, and the environment given to `claude`.
final class ProcessRunTests: XCTestCase {
    private func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    private func waitUntilGone(_ pid: pid_t, within seconds: TimeInterval = 3) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if !alive(pid) { return true }; usleep(50_000) }
        return !alive(pid)
    }

    private func tempFile() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    }

    func testCapturesStdoutToEOFOnCleanExit() async {
        let output = await NativeClaude.run("/bin/sh", ["-c", "sleep 1.2; printf /usr/local/bin/claude"], environment: [:],
                                            timeout: 5, captureOutput: true)
        XCTAssertEqual(output.flatMap { String(data: $0, encoding: .utf8) }, "/usr/local/bin/claude")
        let failed = await NativeClaude.run("/bin/sh", ["-c", "echo x; exit 3"], environment: [:], timeout: 5, captureOutput: true)
        XCTAssertNil(failed)
    }

    func testTimeoutTerminatesWholeProcessGroup() async throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(atPath: file) }
        let start = Date()
        let output = await NativeClaude.run("/bin/sh", ["-c", "sleep 60 & echo $! > \(file); wait"], environment: [:], timeout: 0.5)
        XCTAssertNil(output)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        let child = try XCTUnwrap(pid_t(String(contentsOfFile: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertTrue(waitUntilGone(child), "background child must not survive the timeout")
    }

    func testTimeoutEscalatesToKillForTermIgnoringGroup() async throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(atPath: file) }
        let start = Date()
        let output = await NativeClaude.run("/bin/sh", ["-c", "trap '' TERM; sleep 60 & echo $! > \(file); wait"], environment: [:],
                                            timeout: 0.5, captureOutput: true)
        XCTAssertNil(output)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, NativeClaude.killGrace)
        XCTAssertLessThan(elapsed, NativeClaude.killGrace + 3)
        let child = try XCTUnwrap(pid_t(String(contentsOfFile: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertTrue(waitUntilGone(child))
    }

    func testGrandchildHoldingStdoutCannotOutliveTimeout() async throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(atPath: file) }
        // The leader exits at once but its background child keeps stdout open, so EOF never comes.
        let output = await NativeClaude.run("/bin/sh", ["-c", "sleep 60 & echo $! > \(file)"], environment: [:],
                                            timeout: 0.5, captureOutput: true)
        XCTAssertNil(output)
        let child = try XCTUnwrap(pid_t(String(contentsOfFile: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertTrue(waitUntilGone(child))
    }

    func testRenewalEnvironmentTargetsOnlyTheFolder() {
        let base = ["PATH": "/usr/bin", "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/elsewhere", "CLAUDE_CONFIG_DIR": "/other"]
        let folder = NativeClaude.renewalEnvironment(profile: "/Users/x/.claude-me", base: base)
        XCTAssertEqual(folder, ["PATH": "/usr/bin", "CLAUDE_CONFIG_DIR": "/Users/x/.claude-me"])
        let standard = NativeClaude.renewalEnvironment(profile: "", base: base)
        XCTAssertEqual(standard, ["PATH": "/usr/bin"])
    }
}
