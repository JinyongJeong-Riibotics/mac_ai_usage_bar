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

final class ProcessIsolationTests: XCTestCase {
    func testMinimalEnvironmentKeepsRuntimeValuesAndDropsAmbientContext() {
        let environment = minimalProcessEnvironment(inherited: [
            "HOME": "/Users/test",
            "PATH": "/usr/bin:/bin",
            "HTTPS_PROXY": "http://proxy.example",
            "PWD": "/Users/test/Music",
            "OLDPWD": "/Users/test/Documents",
            "OPENAI_API_KEY": "secret",
            "CLAUDE_PLUGIN_ROOT": "/Users/test/plugin",
        ])

        XCTAssertEqual(environment["HOME"], "/Users/test")
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(environment["HTTPS_PROXY"], "http://proxy.example")
        XCTAssertNil(environment["PWD"])
        XCTAssertNil(environment["OLDPWD"])
        XCTAssertNil(environment["OPENAI_API_KEY"])
        XCTAssertNil(environment["CLAUDE_PLUGIN_ROOT"])
    }

    func testCommandsDefaultToNeutralTemporaryDirectory() throws {
        let output = try XCTUnwrap(runCommand("/bin/pwd", []))
        let actual = URL(fileURLWithPath: output).resolvingSymlinksInPath().path
        XCTAssertEqual(actual, safeProcessWorkingDirectory().path)
    }
}

final class CodexParseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_785_000_000)

    func testParsesNamedCodexBucket() {
        let response: [String: Any] = ["result": [
            "rateLimits": NSNull(),
            "rateLimitsByLimitId": ["codex": [
                "limitId": "codex",
                "primary": ["usedPercent": 8, "windowDurationMins": 300,
                            "resetsAt": 1_785_010_000],
                "secondary": ["usedPercent": 10, "windowDurationMins": 10080,
                              "resetsAt": 1_785_500_000],
            ]],
            "rateLimitResetCredits": [
                "availableCount": 2,
                "credits": [],
            ],
        ]]
        let usage = CodexReader.parseAppServerResponse(response, now: now)
        XCTAssertEqual(usage?.fiveHour?.usedPercent, 8)
        XCTAssertEqual(usage?.weekly?.usedPercent, 10)
        XCTAssertEqual(usage?.rateLimitResetCredits, 2)
        XCTAssertEqual(usage?.sampledAt, now)
    }

    func testFallsBackToTopLevelRateLimits() {
        let response: [String: Any] = ["result": ["rateLimits": [
            "primary": ["usedPercent": 92.0, "windowDurationMins": 10080,
                        "resetsAt": 1_785_261_651.0],
            "secondary": NSNull(),
        ]]]
        let usage = CodexReader.parseAppServerResponse(response, now: now)
        XCTAssertNil(usage?.fiveHour)
        XCTAssertEqual(usage?.weekly?.window, .weekly)
        XCTAssertEqual(usage?.weekly?.usedPercent, 92.0)
        XCTAssertNil(usage?.rateLimitResetCredits)
    }

    func testPreservesZeroAvailableResetCredits() {
        let response: [String: Any] = ["result": [
            "rateLimits": [
                "primary": ["usedPercent": 4, "windowDurationMins": 10080,
                            "resetsAt": 1_785_261_651],
            ],
            "rateLimitResetCredits": ["availableCount": 0, "credits": []],
        ]]
        let usage = CodexReader.parseAppServerResponse(response, now: now)
        XCTAssertEqual(usage?.rateLimitResetCredits, 0)
    }

    func testRejectsErrorsAndEmptyLimits() {
        XCTAssertNil(CodexReader.parseAppServerResponse(["error": ["message": "no"]], now: now))
        XCTAssertNil(CodexReader.parseAppServerResponse(["result": ["rateLimits": [:]]], now: now))
    }

    func testResolvesTildeHome() {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex").standardizedFileURL
        XCTAssertEqual(CodexReader.resolveHomePath("~/.codex").path, expected.path)
    }

    func testAugmentedPathMakesHomebrewRuntimeAvailableToGUIProcess() {
        let path = CodexReader.augmentedPath(
            executablePath: "/opt/homebrew/bin/codex",
            inheritedPath: "/usr/bin:/bin"
        ).split(separator: ":").map(String.init)

        XCTAssertEqual(path.first, "/opt/homebrew/bin")
        XCTAssertTrue(path.contains("/usr/bin"))
        XCTAssertEqual(path.filter { $0 == "/opt/homebrew/bin" }.count, 1)
    }
}

final class ClaudeProfileTests: XCTestCase {
    func testDefaultProfileKeepsLegacyKeychainService() {
        XCTAssertEqual(ClaudeReader.keychainService(configDirectoryPath: "~/.claude"),
                       "Claude Code-credentials")
        XCTAssertEqual(ClaudeReader.keychainService(
            configDirectoryPath: ClaudeReader.resolvedConfigDirectory().path
        ), "Claude Code-credentials")
    }

    func testCustomProfileUsesClaudeCodeCompatibleHash() {
        XCTAssertEqual(ClaudeReader.keychainService(
            configDirectoryPath: "/tmp/claude-profile"
        ), "Claude Code-credentials-7182514b")
    }

    func testCredentialsFileBelongsToSelectedProfile() {
        XCTAssertEqual(ClaudeReader.credentialsURL(
            configDirectoryPath: "/tmp/claude-profile"
        ).path, "/tmp/claude-profile/.credentials.json")
    }

    func testClaudeEnvironmentIsolatesProfilesAndAuthOverrides() {
        let custom = ClaudeReader.claudeEnvironment(
            configDirectoryPath: "/tmp/claude-profile",
            inherited: [
                "PATH": "/usr/bin",
                "CLAUDE_CONFIG_DIR": "/wrong",
                "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/shared",
                "CLAUDE_CODE_OAUTH_TOKEN": "wrong-token",
                "ANTHROPIC_API_KEY": "wrong-key",
                "PWD": "/Users/test/Music",
                "CLAUDE_PLUGIN_ROOT": "/Users/test/plugin",
            ]
        )
        XCTAssertEqual(custom["CLAUDE_CONFIG_DIR"], "/tmp/claude-profile")
        XCTAssertEqual(custom["PATH"], "/usr/bin")
        XCTAssertNil(custom["CLAUDE_SECURESTORAGE_CONFIG_DIR"])
        XCTAssertNil(custom["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertNil(custom["ANTHROPIC_API_KEY"])
        XCTAssertNil(custom["PWD"])
        XCTAssertNil(custom["CLAUDE_PLUGIN_ROOT"])
        XCTAssertEqual(custom["CLAUDE_CODE_SKIP_PROMPT_HISTORY"], "1")

        let defaultProfile = ClaudeReader.claudeEnvironment(
            configDirectoryPath: "~/.claude",
            inherited: ["CLAUDE_CONFIG_DIR": "/wrong"]
        )
        XCTAssertNil(defaultProfile["CLAUDE_CONFIG_DIR"])
    }

    func testCLIRefreshRunsWithoutLocalCapabilitiesOrPersistence() {
        let arguments = ClaudeReader.cliRefreshArguments()
        XCTAssertTrue(arguments.contains("--safe-mode"))
        XCTAssertTrue(arguments.contains("--restricted"))
        XCTAssertTrue(arguments.contains("--strict-mcp-config"))
        XCTAssertTrue(arguments.contains("--no-chrome"))
        XCTAssertTrue(arguments.contains("--no-session-persistence"))
        XCTAssertEqual(Array(arguments.suffix(2)), ["-p", "ok"])

        let toolsIndex = arguments.firstIndex(of: "--tools")
        XCTAssertNotNil(toolsIndex)
        if let toolsIndex {
            XCTAssertEqual(arguments[toolsIndex + 1], "")
        }
        let promptsIndex = arguments.firstIndex(of: "--permission-prompts")
        XCTAssertNotNil(promptsIndex)
        if let promptsIndex {
            XCTAssertEqual(arguments[promptsIndex + 1], "none")
        }
    }

    func testParsesClaudeVersionWithoutReadingProjectTranscripts() {
        XCTAssertEqual(ClaudeReader.parseClaudeVersion("2.1.276 (Claude Code)"), "2.1.276")
        XCTAssertNil(ClaudeReader.parseClaudeVersion("Claude Code"))
        XCTAssertNil(ClaudeReader.parseClaudeVersion("2.1"))
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
