import AppKit
import XCTest
import UsageCore
@testable import MacAIUsageBar

final class MenuBarClickTests: XCTestCase {
    func testSingleClickWaitsThenOpensDetailsOnlyOnce() {
        var state = MenuBarClickState()
        XCTAssertEqual(state.click(count: 1, isCollapsed: false), .waitForSingleClick)
        XCTAssertEqual(state.singleClickExpired(), .toggleDetails)
        XCTAssertEqual(state.singleClickExpired(), .none)
    }

    func testDoubleClickCollapsesWithoutOpeningDetails() {
        var state = MenuBarClickState()
        XCTAssertEqual(state.click(count: 1, isCollapsed: false), .waitForSingleClick)
        XCTAssertEqual(state.click(count: 2, isCollapsed: false), .collapse)
        XCTAssertEqual(state.singleClickExpired(), .none)
    }

    func testCollapsedSingleClickOnlyTogglesDetails() {
        var state = MenuBarClickState()
        XCTAssertEqual(state.click(count: 1, isCollapsed: true), .waitForSingleClick)
        XCTAssertEqual(state.singleClickExpired(), .toggleDetails)
        XCTAssertEqual(state.singleClickExpired(), .none)
    }

    func testCollapsedDoubleClickExpandsWithoutOpeningDetails() {
        var state = MenuBarClickState()
        XCTAssertEqual(state.click(count: 1, isCollapsed: true), .waitForSingleClick)
        XCTAssertEqual(state.click(count: 2, isCollapsed: true), .expand)
        XCTAssertEqual(state.singleClickExpired(), .none)
    }

    func testTripleClickDoesNotUndoCollapse() {
        var state = MenuBarClickState()
        _ = state.click(count: 1, isCollapsed: false)
        _ = state.click(count: 2, isCollapsed: false)
        XCTAssertEqual(state.click(count: 3, isCollapsed: true), .none)
        XCTAssertEqual(state.singleClickExpired(), .none)
    }

    func testSeparateSingleClicksBothToggleDetails() {
        for isCollapsed in [true, false] {
            var state = MenuBarClickState()
            for _ in 0..<2 {
                XCTAssertEqual(state.click(count: 1, isCollapsed: isCollapsed), .waitForSingleClick)
                XCTAssertEqual(state.singleClickExpired(), .toggleDetails)
            }
        }
    }

    func testTripleClickDoesNotUndoExpansion() {
        var state = MenuBarClickState()
        _ = state.click(count: 1, isCollapsed: true)
        _ = state.click(count: 2, isCollapsed: true)
        XCTAssertEqual(state.click(count: 3, isCollapsed: false), .none)
        XCTAssertEqual(state.singleClickExpired(), .none)
    }

    func testSettingsChangeCancelsPendingClick() {
        var state = MenuBarClickState()
        _ = state.click(count: 1, isCollapsed: false)
        state.cancel()
        XCTAssertEqual(state.singleClickExpired(), .none)
    }

    func testAccessibilityActivationIsImmediate() {
        var state = MenuBarClickState()
        XCTAssertEqual(state.click(count: 0, isCollapsed: true), .toggleDetails)
        XCTAssertEqual(state.click(count: 0, isCollapsed: false), .toggleDetails)
        XCTAssertEqual(state.singleClickExpired(), .none)
    }
}

final class MenuBarSettingsTests: XCTestCase {
    @MainActor
    func testCollapsePreferencePersistsAndDefaultsToExpanded() async throws {
        let name = "MenuBarSettingsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.isMenuBarCollapsed)
        settings.isMenuBarCollapsed = true
        XCTAssertTrue(AppSettings(defaults: defaults).isMenuBarCollapsed)
        settings.isMenuBarCollapsed = false
        XCTAssertFalse(AppSettings(defaults: defaults).isMenuBarCollapsed)
    }

    @MainActor
    func testCollapsedLabelHidesAccountNamesAndExpansionRestoresThem() async throws {
        let name = "MenuBarLabelTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.addCodexAccount()
        settings.addClaudeAccount()
        let label = BarLabel(store: UsageStore(), settings: settings)
        let expanded = label.attributedTitle.string
        XCTAssertTrue(expanded.contains("Codex 2"))
        XCTAssertTrue(expanded.contains("Claude 2"))
        settings.isMenuBarCollapsed = true
        XCTAssertEqual(label.attributedTitle.string, "AI ›")
        settings.isMenuBarCollapsed = false
        XCTAssertEqual(label.attributedTitle.string, expanded)
    }

    @MainActor
    func testCollapsedWarningRespectsColorAndServiceVisibility() async throws {
        let name = "MenuBarWarningTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.isMenuBarCollapsed = true
        let store = UsageStore()
        store.codexByAccount[settings.codexAccounts[0].id] = ProviderUsage(
            provider: .codex, fiveHour: nil,
            weekly: RateWindow(window: .weekly, usedPercent: 95, resetsAt: .distantFuture),
            sampledAt: Date()
        )
        let label = BarLabel(store: store, settings: settings)
        XCTAssertEqual(label.attributedTitle.string, "⚠ AI ›")
        XCTAssertEqual(label.attributedTitle.attribute(.foregroundColor, at: 2,
                                                       effectiveRange: nil) as? NSColor, .systemRed)
        settings.colorMenuBar = false
        XCTAssertEqual(label.attributedTitle.string, "AI ›")
        XCTAssertEqual(label.attributedTitle.attribute(.foregroundColor, at: 0,
                                                       effectiveRange: nil) as? NSColor, .labelColor)
        settings.colorMenuBar = true
        settings.showCodex = false
        XCTAssertEqual(label.attributedTitle.string, "AI ›")
    }
}
