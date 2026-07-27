import XCTest
@testable import UsageCore

final class FormattingTests: XCTestCase {
    func testFormatPercent() {
        XCTAssertEqual(formatPercent(0), "0%")
        XCTAssertEqual(formatPercent(92), "92%")
        XCTAssertEqual(formatPercent(8.4), "8%")
    }

    func testFormatReset() {
        XCTAssertEqual(formatReset(-10), "now")
        XCTAssertEqual(formatReset(0), "now")
        XCTAssertEqual(formatReset(90), "1m")           // 90s -> 1m
        XCTAssertEqual(formatReset(3 * 3600 + 25 * 60), "3h 25m")
        XCTAssertEqual(formatReset(4 * 86400 + 15 * 3600), "4d 15h")
    }
}

final class CodexParseTests: XCTestCase {
    func testWeeklyOnly() {
        let rl: [String: Any] = [
            "primary": ["used_percent": 92.0, "window_minutes": 10080, "resets_at": 1_785_261_651.0],
            "secondary": NSNull(),
        ]
        let (five, week) = CodexReader.parseRateLimits(rl)
        XCTAssertNil(five)
        XCTAssertEqual(week?.window, .weekly)
        XCTAssertEqual(week?.usedPercent, 92.0)
    }

    func testFiveHourAndWeekly() {
        let rl: [String: Any] = [
            "primary": ["used_percent": 8.0, "window_minutes": 300, "resets_at": 1_782_900_528.0],
            "secondary": ["used_percent": 10.0, "window_minutes": 10080, "resets_at": 1_783_389_453.0],
        ]
        let (five, week) = CodexReader.parseRateLimits(rl)
        XCTAssertEqual(five?.window, .fiveHour)
        XCTAssertEqual(five?.usedPercent, 8.0)
        XCTAssertEqual(week?.window, .weekly)
        XCTAssertEqual(week?.usedPercent, 10.0)
    }

    func testEmpty() {
        let (five, week) = CodexReader.parseRateLimits([:])
        XCTAssertNil(five)
        XCTAssertNil(week)
    }
}

/// Shape of the live `wham/usage` reply the Codex CLI polls.
final class CodexLiveParseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_785_000_000)

    func testParsesWeeklyPrimaryWindow() {
        let obj: [String: Any] = ["rate_limit": [
            "primary_window": ["used_percent": 94, "limit_window_seconds": 604800,
                               "reset_at": 1_785_261_651],
            "secondary_window": NSNull(),
        ]]
        let usage = CodexReader.parseUsage(obj, now: now)
        XCTAssertNil(usage?.fiveHour)
        XCTAssertEqual(usage?.weekly?.window, .weekly)
        XCTAssertEqual(usage?.weekly?.usedPercent, 94)
        XCTAssertEqual(usage?.weekly?.resetsAt, Date(timeIntervalSince1970: 1_785_261_651))
    }

    func testMapsFiveHourAndWeeklyByWindowLength() {
        let obj: [String: Any] = ["rate_limit": [
            "primary_window": ["used_percent": 8, "limit_window_seconds": 18000, "reset_at": 1_785_010_000],
            "secondary_window": ["used_percent": 10, "limit_window_seconds": 604800, "reset_at": 1_785_500_000],
        ]]
        let usage = CodexReader.parseUsage(obj, now: now)
        XCTAssertEqual(usage?.fiveHour?.usedPercent, 8)
        XCTAssertEqual(usage?.weekly?.usedPercent, 10)
    }

    // Some replies carry only a relative reset.
    func testFallsBackToResetAfterSeconds() {
        let w = CodexReader.parseWindow(
            ["used_percent": 50, "limit_window_seconds": 18000, "reset_after_seconds": 600], now: now)
        XCTAssertEqual(w?.resetsAt, now.addingTimeInterval(600))
    }

    func testRejectsEmptyOrLimitlessPayloads() {
        XCTAssertNil(CodexReader.parseUsage([:], now: now))
        XCTAssertNil(CodexReader.parseUsage(["rate_limit": [:]], now: now))
        XCTAssertNil(CodexReader.parseWindow(["used_percent": 5], now: now))
    }

    func testTokenExpiryReadsJWTExpClaim() {
        // {"exp":1785261651} base64url, unsigned — parsed for display only.
        let payload = Data(#"{"exp":1785261651}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(CodexReader.tokenExpiry("header.\(payload).sig"),
                       Date(timeIntervalSince1970: 1_785_261_651))
        XCTAssertNil(CodexReader.tokenExpiry("not-a-jwt"))
    }
}

final class ClaudeRefreshMergeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_785_000_000)

    func testMergePreservesOtherFieldsAndRotates() throws {
        let original: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": "old-at", "refreshToken": "old-rt",
                "expiresAt": 1, "subscriptionType": "max",
                "scopes": ["user:inference"],
            ],
            "someTopLevel": "keep-me",
        ]
        let oldOAuth = original["claudeAiOauth"] as! [String: Any]
        let response: [String: Any] = [
            "access_token": "new-at", "refresh_token": "new-rt", "expires_in": 28800.0,
        ]
        let data = try XCTUnwrap(ClaudeReader.mergedCredentials(
            original: original, oldOAuth: oldOAuth, response: response, now: now))
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let oauth = obj["claudeAiOauth"] as! [String: Any]

        XCTAssertEqual(oauth["accessToken"] as? String, "new-at")
        XCTAssertEqual(oauth["refreshToken"] as? String, "new-rt")     // rotated
        XCTAssertEqual(oauth["subscriptionType"] as? String, "max")     // preserved
        XCTAssertEqual(oauth["scopes"] as? [String], ["user:inference"])// preserved
        XCTAssertEqual(obj["someTopLevel"] as? String, "keep-me")       // preserved
        // expiresAt = now + expires_in, in ms.
        XCTAssertEqual(oauth["expiresAt"] as? Int, Int((now.timeIntervalSince1970 + 28800) * 1000))
        // The new token must parse back out.
        XCTAssertEqual(ClaudeReader.parseToken(from: data), "new-at")
    }

    // Server may omit refresh_token (non-rotating); keep the old one.
    func testMergeKeepsOldRefreshWhenResponseOmitsIt() throws {
        let oldOAuth: [String: Any] = ["accessToken": "old", "refreshToken": "keep-rt"]
        let data = try XCTUnwrap(ClaudeReader.mergedCredentials(
            original: ["claudeAiOauth": oldOAuth],
            oldOAuth: oldOAuth,
            response: ["access_token": "new"], now: now))
        let oauth = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["claudeAiOauth"] as! [String: Any]
        XCTAssertEqual(oauth["refreshToken"] as? String, "keep-rt")
    }

    func testMergeRejectsTokenlessResponse() {
        XCTAssertNil(ClaudeReader.mergedCredentials(
            original: [:], oldOAuth: [:], response: ["error": "bad"], now: now))
    }
}

final class ClaudeTokenTests: XCTestCase {
    func testExpiresAtReadsMilliseconds() {
        let data = Data(#"{"claudeAiOauth":{"accessToken":"t","expiresAt":1785261651000}}"#.utf8)
        XCTAssertEqual(ClaudeReader.expiresAt(from: data),
                       Date(timeIntervalSince1970: 1_785_261_651))
        XCTAssertNil(ClaudeReader.expiresAt(from: Data(#"{"claudeAiOauth":{}}"#.utf8)))
    }

    func testParsesCredentialsFileShape() {
        let data = #"{"claudeAiOauth":{"accessToken":"sk-tok","refreshToken":"r"}}"#.data(using: .utf8)!
        XCTAssertEqual(ClaudeReader.parseToken(from: data), "sk-tok")
    }

    func testParsesFlatAccessTokenShape() {
        let data = #"{"accessToken":"sk-flat"}"#.data(using: .utf8)!
        XCTAssertEqual(ClaudeReader.parseToken(from: data), "sk-flat")
    }

    // A keychain item could hold the token as a bare string rather than JSON.
    func testParsesBareTokenString() {
        XCTAssertEqual(ClaudeReader.parseToken(from: Data(" sk-raw \n".utf8)), "sk-raw")
    }

    func testRejectsEmptyAndTokenlessPayloads() {
        XCTAssertNil(ClaudeReader.parseToken(from: Data()))
        XCTAssertNil(ClaudeReader.parseToken(from: Data(#"{"claudeAiOauth":{}}"#.utf8)))
        XCTAssertNil(ClaudeReader.parseToken(from: Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)))
    }
}

final class ClaudeParseTests: XCTestCase {
    func testParsesBothWindows() {
        let obj: [String: Any] = [
            "five_hour": ["utilization": 9.0, "resets_at": "2026-07-24T04:49:59.467142+00:00"],
            "seven_day": ["utilization": 3.0, "resets_at": "2026-07-29T05:59:59.467162+00:00"],
        ]
        let usage = ClaudeReader.parse(obj)
        XCTAssertEqual(usage.provider, .claude)
        XCTAssertEqual(usage.fiveHour?.usedPercent, 9.0)
        XCTAssertEqual(usage.fiveHour?.window, .fiveHour)
        XCTAssertEqual(usage.weekly?.usedPercent, 3.0)
        XCTAssertEqual(usage.weekly?.window, .weekly)
        XCTAssertNil(usage.error)
    }

    func testMissingWindowsYieldNil() {
        let usage = ClaudeReader.parse([:])
        XCTAssertNil(usage.fiveHour)
        XCTAssertNil(usage.weekly)
    }
}
