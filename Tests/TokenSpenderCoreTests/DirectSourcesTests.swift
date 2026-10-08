import Foundation
import XCTest
@testable import TokenSpenderCore

final class DirectSourcesTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private let iso = ISO8601DateFormatter()

    func testCodexUsageMapping() throws {
        let now = Date(timeIntervalSince1970: 1_791_454_000)
        let row = DirectSources.parseCodex(try fixture("codex-wham-usage"), now: now)
        XCTAssertNil(row.error)
        XCTAssertEqual(row.windows.map(\.label), ["WK", "5H"])
        XCTAssertEqual(row.windows[0].percentLeft, 74)
        XCTAssertEqual(row.windows[0].resetsAt, Date(timeIntervalSince1970: 1_791_961_609))
        XCTAssertEqual(row.windows[1].percentLeft, 96.5)
        XCTAssertEqual(row.windows[1].resetsAt, now.addingTimeInterval(3600)) // reset_after_seconds fallback
        XCTAssertEqual(row.constraining?.label, "WK")
    }

    func testCodexUsageWithoutWindowsFails() {
        let row = DirectSources.parseCodex(Data(#"{"rate_limit": {"primary_window": null, "secondary_window": null}}"#.utf8))
        XCTAssertEqual(row.error, "No usage windows")
    }

    func testKimiUsageMapping() throws {
        let row = DirectSources.parseKimi(try fixture("kimi-code-usages"))
        XCTAssertNil(row.error)
        XCTAssertEqual(row.windows.map(\.label), ["5H", "WK"])
        XCTAssertEqual(row.windows[0].percentLeft, 37.5)
        XCTAssertEqual(row.windows[0].resetsAt, iso.date(from: "2026-10-08T20:15:44Z"))
        XCTAssertEqual(row.windows[1].percentLeft, 87.5)
        XCTAssertEqual(row.windows[1].resetsAt, iso.date(from: "2026-10-13T00:00:00Z"))
        XCTAssertEqual(row.constraining?.label, "5H")
    }

    func testPiAuthParsing() throws {
        let data = try fixture("pi-auth")
        let now = Date(timeIntervalSince1970: 1_791_454_000)
        let kimi = try DirectSources.piCredential("kimi-coding", authJSON: data, now: now).get()
        XCTAssertEqual(kimi.access, "fake-kimi-access")
        XCTAssertEqual(kimi.expires, Date(timeIntervalSince1970: 4_102_444_800))
        XCTAssertEqual(DirectSources.piCredential("openai", authJSON: data, now: now), .failure(.expired))
        XCTAssertEqual(DirectSources.piCredential("vercel-ai-gateway", authJSON: data, now: now), .failure(.missing))
        XCTAssertEqual(DirectSources.piCredential("nope", authJSON: data, now: now), .failure(.missing))
        XCTAssertEqual(DirectSources.piCredential("openai", authJSON: Data("nope".utf8), now: now), .failure(.unreadable))
    }

    func testCodexAuthParsing() throws {
        let now = Date(timeIntervalSince1970: 1_791_454_000)
        let cred = try DirectSources.codexCredential(authJSON: try fixture("codex-auth"), now: now).get()
        XCTAssertEqual(cred.accountId, "acct_fake")
        XCTAssertEqual(cred.expires, Date(timeIntervalSince1970: 4_102_444_800))
        XCTAssertTrue(cred.access.hasPrefix("eyJ"))
        // Expired JWT (exp 2000-01-01), account id only in the claim.
        let expired = #"{"tokens": {"access_token": "eyJhbGciOiJub25lIn0.eyJleHAiOjk0NjY4NDgwMH0.sig"}}"#
        XCTAssertEqual(DirectSources.codexCredential(authJSON: Data(expired.utf8), now: now), .failure(.expired))
        XCTAssertEqual(DirectSources.codexCredential(authJSON: Data("{}".utf8), now: now), .failure(.missing))
    }

    func testJWTClaimsBase64URL() {
        let claims = DirectSources.jwtClaims("eyJhbGciOiJub25lIn0.eyJleHAiOjk0NjY4NDgwMH0.sig")
        XCTAssertEqual(claims?["exp"] as? Double, 946_684_800)
        XCTAssertNil(DirectSources.jwtClaims("not-a-jwt"))
    }
}

extension DirectSourcesTests {
    func testResourceDeadlineAndNoCache() {
        let configuration = DirectSources.session.configuration
        XCTAssertEqual(configuration.timeoutIntervalForResource, 20)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 20)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
    }

    func testMissingFileVersusUnreadableConfiguredPath() {
        let missing = NSTemporaryDirectory() + UUID().uuidString
        XCTAssertEqual(DirectSources.readFile(missing), .failure(.missing))
        XCTAssertEqual(DirectSources.readFile(NSTemporaryDirectory()), .failure(.unreadable))
        XCTAssertEqual(DirectSources.codexCredential(authJSON: Data("broken".utf8)), .failure(.unreadable))
    }
}
