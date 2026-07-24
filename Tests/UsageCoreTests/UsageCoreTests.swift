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

final class ClaudeTokenTests: XCTestCase {
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
