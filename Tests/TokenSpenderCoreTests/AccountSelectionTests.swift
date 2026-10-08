import Foundation
import XCTest
@testable import TokenSpenderCore

final class AccountSelectionTests: XCTestCase {
    private let first = "00000000-0000-0000-0000-000000000001"
    private let second = "00000000-0000-0000-0000-000000000002"
    private let org = "00000000-0000-0000-0000-000000000003"

    private func list(_ entries: [(Int, String, String, Double)]) -> Data {
        let accounts: [[String: Any]] = entries.map { slot, email, org, used in
            ["number": slot, "email": email, "organizationUuid": org,
             "usageStatus": "ok", "usage": ["fiveHour": ["pct": used], "sevenDay": ["pct": 20]]]
        }
        return try! JSONSerialization.data(withJSONObject: ["accounts": accounts])
    }

    private func metadata(_ entries: [(Int, String, String, String)]) -> Data {
        let accounts = Dictionary(uniqueKeysWithValues: entries.map { slot, email, uuid, org in
            (String(slot), ["email": email, "uuid": uuid, "organizationUuid": org])
        })
        return try! JSONSerialization.data(withJSONObject: ["accounts": accounts])
    }

    private func snapshot(_ accounts: [ClaudeAccount]) -> UsageSnapshot {
        UsageSnapshot(codex: .notConfigured, claude: accounts, kimi: .notConfigured)
    }

    private func pair() -> [ClaudeAccount] {
        Parse.cswap(list([(1, "a@example.com", org, 80), (2, "b@example.com", org, 30)]),
                    metadata: metadata([(1, "a@example.com", first, org), (2, "b@example.com", second, org)]))!
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

    func testRenameAndSlotReorderRetainIdentity() throws {
        let selected = DisplaySelection.claudeAccount(try XCTUnwrap(pair()[0].id))
        let reordered = try XCTUnwrap(Parse.cswap(
            list([(1, "b@example.com", org, 30), (9, "renamed@example.com", org, 90)]),
            metadata: metadata([(1, "b@example.com", second, org), (9, "renamed@example.com", first, org)])))
        XCTAssertEqual(selected.text(snapshot: snapshot(reordered)), "10%")
        XCTAssertEqual(selected.title(snapshot: snapshot(reordered)), "Claude: renamed@example.com")
        XCTAssertEqual(reordered[1].id, pair()[0].id)
    }

    func testDisappearanceReappearanceAndSlotReuseNeverSelectAnotherAccount() throws {
        let accounts = pair()
        let selected = DisplaySelection.claudeAccount(try XCTUnwrap(accounts[0].id))
        let replacement = try XCTUnwrap(Parse.cswap(list([(1, "b@example.com", org, 30)]),
            metadata: metadata([(1, "b@example.com", second, org)])))
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

    func testIdentityMetadataMissingCorruptMismatchedOrAmbiguousFailsClosed() throws {
        let data = list([(1, "a@example.com", org, 80)])
        let invalid: [Data?] = [nil, Data("invalid".utf8), Data("{}".utf8),
            metadata([(1, "wrong@example.com", first, org)]),
            metadata([(1, "a@example.com", first, second)]),
            metadata([(2, "a@example.com", first, org)]),
            metadata([(1, "a@example.com", "", org)]),
            metadata([(1, "a@example.com", first, org), (2, "b@example.com", first, org)])]
        for meta in invalid {
            let accounts = try XCTUnwrap(Parse.cswap(data, metadata: meta))
            XCTAssertNil(accounts[0].id)
            XCTAssertEqual(DisplaySelection.mode(.claudePool).text(snapshot: snapshot(accounts)), "20%")
            XCTAssertEqual(DisplaySelection.choices(snapshot: snapshot(accounts), selected: .mode(.claudePool)).count, 4)
        }
        let duplicateSlots = try XCTUnwrap(Parse.cswap(list([(1, "a@example.com", org, 80), (1, "a@example.com", org, 30)]),
            metadata: metadata([(1, "a@example.com", first, org)])))
        XCTAssertTrue(duplicateSlots.allSatisfy { $0.id == nil })
    }

    func testSameAccountAcrossOrganizationsHasDistinctIdentity() throws {
        let accounts = try XCTUnwrap(Parse.cswap(list([(1, "a@example.com", org, 80), (2, "a@example.com", second, 30)]),
            metadata: metadata([(1, "a@example.com", first, org), (2, "a@example.com", first, second)])))
        XCTAssertNotNil(accounts[0].id)
        XCTAssertNotEqual(accounts[0].id, accounts[1].id)
    }
}
