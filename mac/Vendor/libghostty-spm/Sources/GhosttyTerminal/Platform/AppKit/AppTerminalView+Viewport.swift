//
//  AppTerminalView+Viewport.swift
//  libghostty-spm
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import GhosttyKit

    public struct TerminalViewportTextSnapshot {
        public let lines: [String]
        public let columns: Int
        public let cursorRow: Int
        public let cursorColumn: Int
        /// Coordinates use the terminal's top-left origin, in host points.
        public let origin: CGPoint
        public let cellSize: CGSize
    }

    extension AppTerminalView {
        /// Reads visible rows without exporting a file or altering selection.
        public func readViewportTextSnapshot() -> TerminalViewportTextSnapshot? {
            guard let surface, let size = surface.size(),
                  size.columns > 0, size.rows > 0,
                  Int(size.columns) * Int(size.rows) <= 100_000,
                  let originRead = readViewportText(row: 0, columns: 0..<1)
            else { return nil }
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
            let cellSize = CGSize(
                width: CGFloat(size.cellWidthPixels) / scale,
                height: CGFloat(size.cellHeightPixels) / scale
            )
            guard cellSize.width > 0, cellSize.height > 0 else { return nil }
            var lines: [String] = []
            let blankLine = String(repeating: " ", count: Int(size.columns))
            for row in 0..<Int(size.rows) {
                guard let line = readViewportText(row: row, columns: 0..<Int(size.columns))
                else { return nil }
                // An erased row still has the indentation of an empty input line.
                lines.append(line.text.allSatisfy { $0 == " " } ? blankLine : line.text)
            }
            let cursor = surface.imePoint()
            // read_text returns a text baseline; imePoint is the caret cell's
            // bottom center. Recover the grid's top edge from the caret row.
            let cursorRow = Int(((cursor.y - originRead.origin.y) / cellSize.height).rounded())
            let cursorColumn = Int(((cursor.x - originRead.origin.x) / cellSize.width).rounded(.down))
            guard lines.indices.contains(cursorRow), cursorColumn >= 0,
                  cursorColumn < Int(size.columns) else { return nil }
            let origin = CGPoint(
                x: originRead.origin.x,
                y: cursor.y - CGFloat(cursorRow + 1) * cellSize.height
            )
            return TerminalViewportTextSnapshot(
                lines: lines, columns: Int(size.columns),
                cursorRow: cursorRow, cursorColumn: cursorColumn,
                origin: origin, cellSize: cellSize
            )
        }

        public func readViewportText(
            fromRow: Int, column: Int, toRow: Int, column endColumn: Int
        ) -> String? {
            guard let rawSurface = surface?.rawValue, let size = surface?.size(),
                  fromRow >= 0, toRow >= fromRow, toRow < Int(size.rows),
                  column >= 0, endColumn >= 0,
                  column <= Int(size.columns), endColumn <= Int(size.columns)
            else { return nil }
            if fromRow == toRow, column == endColumn { return "" }
            guard (fromRow, column) < (toRow, endColumn) else { return nil }
            let selection = ghostty_selection_s(
                top_left: ghostty_point_s(
                    tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                    x: UInt32(column), y: UInt32(fromRow)
                ),
                bottom_right: ghostty_point_s(
                    tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                    x: UInt32(max(0, endColumn - 1)), y: UInt32(toRow)
                ), rectangle: false
            )
            var result = ghostty_text_s()
            guard ghostty_surface_read_text(rawSurface, selection, &result) else { return nil }
            defer { ghostty_surface_free_text(rawSurface, &result) }
            var text = result.text.map {
                String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(result.text_len)), as: UTF8.self)
            } ?? ""
            if endColumn == 0,
               let firstCell = readViewportText(row: toRow, columns: 0..<1)?.text,
               text.hasSuffix(firstCell) {
                text.removeLast(firstCell.count)
            }
            return text
        }

        /// Cell-bounded text lets hosts count graphemes using the emulator's
        /// actual wide-cell layout instead of a second Unicode-width table.
        public func readViewportText(
            row: Int, columns: Range<Int>, preservingTrailingSpaces: Bool = false
        ) -> (text: String, origin: CGPoint)? {
            guard row >= 0, columns.lowerBound >= 0 else { return nil }
            guard !columns.isEmpty else { return ("", .zero) }
            guard let rawSurface = surface?.rawValue else { return nil }
            let selection = ghostty_selection_s(
                top_left: ghostty_point_s(
                    tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                    x: UInt32(clamping: columns.lowerBound), y: UInt32(clamping: row)
                ),
                bottom_right: ghostty_point_s(
                    tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                    x: UInt32(clamping: columns.upperBound - 1), y: UInt32(clamping: row)
                ), rectangle: false
            )
            var result = ghostty_text_s()
            guard ghostty_surface_read_text(rawSurface, selection, &result) else { return nil }
            defer { ghostty_surface_free_text(rawSurface, &result) }
            var text = result.text.map {
                String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(result.text_len)), as: UTF8.self)
            } ?? ""
            if preservingTrailingSpaces {
                // read_text omits erased cells at a range's end. Caret offsets
                // need those spaces, including a continuation row's indentation.
                var blankStart = columns.upperBound
                if text.isEmpty {
                    blankStart = columns.lowerBound
                } else {
                    guard let last = readViewportText(row: row, columns: (columns.upperBound - 1)..<columns.upperBound)
                    else { return nil }
                    if last.text.isEmpty {
                        var lower = columns.lowerBound
                        var upper = columns.upperBound - 1
                        while lower < upper {
                            let middle = lower + (upper - lower) / 2
                            guard let suffix = readViewportText(row: row, columns: middle..<columns.upperBound)
                            else { return nil }
                            if suffix.text.isEmpty { upper = middle }
                            else { lower = middle + 1 }
                        }
                        blankStart = lower
                    }
                }
                text += String(repeating: " ", count: columns.upperBound - blankStart)
            }
            return (text, CGPoint(x: result.tl_px_x, y: result.tl_px_y))
        }
    }
#endif
