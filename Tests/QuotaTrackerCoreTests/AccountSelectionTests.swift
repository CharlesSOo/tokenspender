import Foundation
import XCTest
@testable import QuotaTrackerCore

final class AccountSelectionTests: XCTestCase {
    private let first = "00000000-0000-0000-0000-000000000001"
    private let second = "00000000-0000-0000-0000-000000000002"
    private let org = "00000000-0000-0000-0000-000000000003"

    private func account(_ profile: String, _ email: String, _ uuid: String, _ used: Double) -> ClaudeAccount {
        ClaudeAccount(profile: profile, email: email,
                      usage: RowUsage(windows: [UsageWindow(label: "5H", percentLeft: 100 - used, resetsAt: nil),
                                                UsageWindow(label: "WK", percentLeft: 80, resetsAt: nil)]),
                      id: "claude/\(uuid)/\(org)")
    }

    private func snapshot(_ accounts: [ClaudeAccount]) -> UsageSnapshot {
        UsageSnapshot(codex: .notConfigured, claude: accounts)
    }

    private func pair() -> [ClaudeAccount] {
        [account("~/.claude", "a@example.com", first, 80), account("~/.claude-me", "b@example.com", second, 30)]
    }

    func testTwoAccountsShareOrganizationButRemainIndependentlySelectable() throws {
        let accounts = pair()
        let a = DisplaySelection.claudeAccount(try XCTUnwrap(accounts[0].id))
        let b = DisplaySelection.claudeAccount(try XCTUnwrap(accounts[1].id))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.text(snapshot: snapshot(accounts)), "20%")
        XCTAssertEqual(b.text(snapshot: snapshot(accounts)), "70%")
        XCTAssertEqual(DisplaySelection.mode(.claudePool).text(snapshot: snapshot(accounts)), "45%")
        let choices = DisplaySelection.choices(snapshot: snapshot(accounts), selected: a)
        XCTAssertEqual(choices.count, 6)
        XCTAssertEqual(Array(choices.prefix(4)).map(\.title), DisplayMode.allCases.map(\.title))
        XCTAssertEqual(choices.suffix(2).map(\.selection), [a, b])
        XCTAssertEqual(accounts.count, 2) // Selection never filters the popover snapshot.
    }

    func testSingleAccountKeepsExplicitPoolVersusPinnedSemantics() throws {
        let accounts = [pair()[0]]
        let selected = DisplaySelection.claudeAccount(try XCTUnwrap(accounts[0].id))
        let choices = DisplaySelection.choices(snapshot: snapshot(accounts), selected: selected)
        XCTAssertEqual(choices.count, 5)
        XCTAssertEqual(choices.last?.title, "Claude: a@example.com — pinned")
        XCTAssertEqual(selected.text(snapshot: snapshot(accounts)), "20%")
        XCTAssertEqual(DisplaySelection.mode(.claudePool).text(snapshot: snapshot(accounts)), "20%")
    }

    func testRenameAndProfileMoveRetainIdentity() throws {
        let selected = DisplaySelection.claudeAccount(try XCTUnwrap(pair()[0].id))
        let moved = [account("~/.claude", "b@example.com", second, 30), account("~/.claude-me", "renamed@example.com", first, 90)]
        XCTAssertEqual(selected.text(snapshot: snapshot(moved)), "10%")
        XCTAssertEqual(selected.title(snapshot: snapshot(moved)), "Claude: renamed@example.com")
    }

    func testDisappearanceAndReplacementNeverSelectAnotherAccount() throws {
        let accounts = pair()
        let selected = DisplaySelection.claudeAccount(try XCTUnwrap(accounts[0].id))
        let replacement = [account("~/.claude", "b@example.com", second, 30)]
        XCTAssertEqual(selected.text(snapshot: snapshot(replacement)), "—")
        let choices = DisplaySelection.choices(snapshot: snapshot(replacement), selected: selected)
        XCTAssertEqual(choices.last?.selection, selected)
        XCTAssertEqual(choices.last?.enabled, false)
        XCTAssertEqual(choices.last?.title, "Claude account unavailable — pinned")
        XCTAssertEqual(selected.text(snapshot: snapshot(accounts)), "20%")
        XCTAssertEqual(DisplaySelection(rawValue: selected.rawValue), selected)
    }

    func testWeeklyExhaustionErrorAndEmptyProvider() throws {
        var account = pair()[0]
        let selected = DisplaySelection.claudeAccount(try XCTUnwrap(account.id))
        account.usage = RowUsage(windows: [UsageWindow(label: "5H", percentLeft: 99, resetsAt: nil),
                                           UsageWindow(label: "WK", percentLeft: 0, resetsAt: nil)])
        XCTAssertEqual(selected.text(snapshot: snapshot([account])), "0%")
        account.usage.error = "expired"
        XCTAssertEqual(selected.text(snapshot: snapshot([account])), "—")
        XCTAssertTrue(DisplaySelection.choices(snapshot: snapshot([account]), selected: selected).last!.title.contains("expired"))
        account.usage = .notConfigured
        XCTAssertEqual(selected.text(snapshot: snapshot([account])), "—")
        XCTAssertFalse(DisplaySelection.choices(snapshot: snapshot([account]), selected: selected).last!.enabled)
        XCTAssertEqual(DisplaySelection.choices(snapshot: snapshot([]), selected: .mode(.availableNow)).count, 4)
        for mode in DisplayMode.allCases {
            XCTAssertEqual(DisplaySelection.mode(mode).text(snapshot: snapshot([])), "—")
            XCTAssertEqual(DisplaySelection(rawValue: DisplaySelection.mode(mode).rawValue), .mode(mode))
        }
        XCTAssertNil(DisplaySelection(rawValue: "not-a-selection"))
    }

    func testUnverifiedRowsArePooledButNotPinnableAndSameEmailShowsProfile() {
        let failed = ClaudeAccount(profile: "~/.claude", email: "~/.claude", usage: .failure("expired"))
        let unverified = ClaudeAccount(profile: "~/.claude-x", email: "x@example.com", usage: RowUsage(windows: [UsageWindow(label: "WK", percentLeft: 20, resetsAt: nil)]))
        XCTAssertEqual(DisplaySelection.choices(snapshot: snapshot([failed, unverified]), selected: .mode(.claudePool)).count, 4)
        XCTAssertEqual(DisplaySelection.mode(.claudePool).text(snapshot: snapshot([failed, unverified])), "20%")
        let twins = [account("~/.claude", "a@example.com", first, 80), account("~/.claude-me", "a@example.com", second, 30)]
        XCTAssertEqual(DisplaySelection.choices(snapshot: snapshot(twins), selected: .mode(.claudePool)).suffix(2).map(\.title),
                       ["Claude: a@example.com (~/.claude) — pinned", "Claude: a@example.com (~/.claude-me) — pinned"])
    }
}
