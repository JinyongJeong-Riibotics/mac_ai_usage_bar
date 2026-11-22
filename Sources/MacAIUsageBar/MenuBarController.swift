import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate, NSWindowDelegate {
    private let store: UsageStore
    private let settings: AppSettings
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var subscriptions = Set<AnyCancellable>()
    private var clickState = MenuBarClickState()
    private var singleClickTask: Task<Void, Never>?
    private var settingsWindow: NSWindow?
    private var graphWindows: [UsageGraphSelection: NSWindow] = [:]
    private var wasCollapsed: Bool

    init(store: UsageStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        wasCollapsed = settings.isMenuBarCollapsed
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseDown, .leftMouseUp])
        }
        // objectWillChange fires before assignment. Defer reading to the next
        // main-actor turn so the label uses the new values.
        store.objectWillChange.merge(with: settings.objectWillChange)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateLabel() }
            }
            .store(in: &subscriptions)
        updateLabel()
    }

    private func updateLabel() {
        if wasCollapsed != settings.isMenuBarCollapsed {
            singleClickTask?.cancel()
            clickState.cancel()
            if settings.isMenuBarCollapsed { popover.close() }
            wasCollapsed = settings.isMenuBarCollapsed
        }
        guard let button = statusItem.button else { return }
        button.attributedTitle = BarLabel(store: store, settings: settings).attributedTitle
        button.toolTip = settings.isMenuBarCollapsed
            ? "AI Usage 접힘 · 클릭하여 펼치고 상세 정보 보기"
            : "클릭하여 상세 정보 보기 · 더블 클릭하여 메뉴바 접기"
        button.setAccessibilityLabel(settings.isMenuBarCollapsed
            ? "AI Usage, 접힘" : button.attributedTitle.string)
        button.setAccessibilityHelp(button.toolTip)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .leftMouseDown {
            // Cancel on the second press, before its release, so a long second
            // press cannot let the single-click timer open the popover first.
            if event?.clickCount == 2 { singleClickTask?.cancel() }
            return
        }
        let count = event?.type == .leftMouseUp ? (event?.clickCount ?? 1) : 0
        perform(clickState.click(count: count, isCollapsed: settings.isMenuBarCollapsed))
    }

    private func perform(_ action: MenuBarClickState.Action) {
        switch action {
        case .waitForSingleClick:
            singleClickTask?.cancel()
            singleClickTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
                } catch { return }
                guard let self else { return }
                self.perform(self.clickState.singleClickExpired())
            }
        case .collapse:
            singleClickTask?.cancel()
            popover.close()
            settings.isMenuBarCollapsed = true
            updateLabel()
        case .expandAndShowDetails:
            singleClickTask?.cancel()
            settings.isMenuBarCollapsed = false
            updateLabel()
            showDetails()
        case .toggleDetails:
            if popover.isShown { popover.close() } else { showDetails() }
        case .none:
            break
        }
    }

    private func showDetails() {
        guard let button = statusItem.button else { return }
        let content = MenuContentView(store: store, settings: settings,
                                      showSettings: { [weak self] in self?.showSettings() },
                                      showGraph: { [weak self] in self?.showGraph($0) })
        // Many accounts must remain reachable even on a small display.
        let naturalHeight = NSHostingView(rootView: content).fittingSize.height
        let availableHeight = (button.window?.screen?.visibleFrame.height ?? 800) - 40
        let height = min(naturalHeight, availableHeight)
        popover.contentViewController = NSHostingController(rootView:
            ScrollView { content }.frame(width: 300, height: height)
        )
        popover.contentSize = NSSize(width: 300, height: height)
        // Reposition after changing from the short title to the expanded title.
        button.window?.layoutIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        button.highlight(true)
        store.start()
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
    }

    func showSettings() {
        popover.close()
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView(settings: settings)
            ))
            window.title = "AI Usage 설정"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func showGraph(_ selection: UsageGraphSelection) {
        popover.close()
        let window: NSWindow
        if let existing = graphWindows[selection] {
            window = existing
        } else {
            window = NSWindow(contentViewController: NSHostingController(
                rootView: UsageGraphView(selection: selection, store: store)
            ))
            window.title = "사용량 그래프 · \(selection.accountName)"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 720, height: 460))
            window.contentMinSize = NSSize(width: 620, height: 380)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            graphWindows[selection] = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        graphWindows = graphWindows.filter { $0.value !== window }
    }
}
