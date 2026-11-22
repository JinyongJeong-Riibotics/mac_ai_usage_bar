/// Separates click decisions from the system double-click timer and UI effects.
struct MenuBarClickState {
    enum Action: Equatable {
        case waitForSingleClick, toggleDetails, collapse, expand, none
    }

    private var waitingForSingleClick = false

    mutating func click(count: Int, isCollapsed: Bool) -> Action {
        // Accessibility/keyboard activation does not need double-click detection.
        if count == 0 {
            waitingForSingleClick = false
            return .toggleDetails
        }
        if count == 1 {
            waitingForSingleClick = true
            return .waitForSingleClick
        }
        // Ignore extra clicks after expanding or collapsing, including triples.
        guard count == 2, waitingForSingleClick else { return .none }
        waitingForSingleClick = false
        return isCollapsed ? .expand : .collapse
    }

    mutating func singleClickExpired() -> Action {
        guard waitingForSingleClick else { return .none }
        waitingForSingleClick = false
        return .toggleDetails
    }

    mutating func cancel() {
        waitingForSingleClick = false
    }
}
