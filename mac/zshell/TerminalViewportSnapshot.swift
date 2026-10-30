import Foundation
import CoreGraphics

nonisolated struct TerminalViewportCell: Equatable, Sendable {
    let text: String
    let column: Int
    let width: Int
}

nonisolated struct TerminalViewportRow: Equatable, Sendable {
    let text: String
    let startColumns: [Int]
    let endColumns: [Int]
    let wraps: Bool

    init(cells: [TerminalViewportCell], wraps: Bool) {
        var text = ""
        var starts: [Int] = []
        var ends: [Int] = []
        for cell in cells {
            text += cell.text
            starts += repeatElement(cell.column, count: cell.text.utf16.count)
            ends += repeatElement(cell.column + cell.width, count: cell.text.utf16.count)
        }
        self.text = text
        startColumns = starts
        endColumns = ends
        self.wraps = wraps
    }

    func columns(for range: NSRange) -> Range<Int>? {
        guard range.length > 0, range.location >= 0,
              NSMaxRange(range) <= startColumns.count else { return nil }
        return startColumns[range.location]..<endColumns[NSMaxRange(range) - 1]
    }
}

/// All coordinates are viewport-relative; origin is the grid's top-left in
/// host points, so reparenting and Retina scale never enter the hint engine.
nonisolated struct TerminalViewportSnapshot: Equatable, Sendable {
    static let maximumCells = 100_000
    let rows: [TerminalViewportRow]
    let columns: Int
    let origin: CGPoint
    let cellSize: CGSize

    func rect(row: Int, columns: Range<Int>) -> CGRect {
        CGRect(x: origin.x + CGFloat(columns.lowerBound) * cellSize.width,
               y: origin.y + CGFloat(row) * cellSize.height,
               width: CGFloat(columns.count) * cellSize.width, height: cellSize.height)
    }
}
