import Foundation

/// Navigating by position must still reach every item when each visit changes its rank.
struct WorkspaceSelectionCycle {
    private let order: [UUID]

    init(_ order: [UUID]) {
        self.order = order
    }

    func destination(from selection: UUID?, by offset: Int) -> UUID? {
        guard let selection, let index = order.firstIndex(of: selection) else { return nil }
        return order[(index + offset % order.count + order.count) % order.count]
    }
}
