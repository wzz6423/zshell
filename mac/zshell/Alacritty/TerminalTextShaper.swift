import AppKit
import CoreText

/// CoreText chooses glyphs; the VT grid remains the authority for their cells.
final class TerminalTextShaper {
    struct Glyph {
        let font: CTFont
        let glyph: CGGlyph
        let position: CGPoint
        let columns: Range<Int>
    }

    private struct Cell: Equatable {
        let scalar: UInt32
        let text: Data?
        let flags: UInt16
    }

    private struct Row {
        let cells: [Cell]
        let glyphs: [Glyph]
    }

    private var rows: [Row?] = []
    private var fonts: [NSFont] = []
    private var cellWidth: CGFloat = 0
    #if DEBUG
    private(set) var shapedRunCount = 0
    #endif

    func reset(metrics: AlacrittyMetrics, rowCount: Int) {
        let fonts = [metrics.regular, metrics.bold, metrics.italic, metrics.boldItalic]
        if fonts != self.fonts || cellWidth != metrics.cellWidth || rows.count != rowCount {
            self.fonts = fonts
            cellWidth = metrics.cellWidth
            rows = Array(repeating: nil, count: rowCount)
        }
    }

    func glyphs(row: Int, snapshot: ZshellSnapshot, metrics: AlacrittyMetrics) -> [Glyph] {
        guard let source = snapshot.cells, rows.indices.contains(row) else { return [] }
        let shapeFlags = UInt16(ZSHELL_CELL_BOLD | ZSHELL_CELL_ITALIC | ZSHELL_CELL_HIDDEN
                                | ZSHELL_CELL_WIDE | ZSHELL_CELL_WIDE_SPACER)
        let cells = (0..<snapshot.columns).map { column in
            let cell = source[row * snapshot.columns + column]
            let offset = Int(cell.text_offset)
            let length = Int(cell.text_len)
            let text: Data?
            if length > 0, let buffer = snapshot.text,
               offset <= snapshot.text_len, length <= snapshot.text_len - offset {
                text = Data(bytes: buffer.advanced(by: offset), count: length)
            } else {
                text = nil
            }
            return Cell(scalar: cell.ch, text: text, flags: cell.flags & shapeFlags)
        }
        if let cached = rows[row], cached.cells == cells { return cached.glyphs }

        var result: [Glyph] = []
        var text = ""
        var columns: [Int] = []
        var style: UInt16 = 0
        let styleFlags = UInt16(ZSHELL_CELL_BOLD | ZSHELL_CELL_ITALIC)

        func finishRun(at endColumn: Int) {
            guard !text.isEmpty else { return }
            columns.append(endColumn)
            result += shape(text: text, columns: columns, cells: cells, font: metrics.font(
                bold: style & UInt16(ZSHELL_CELL_BOLD) != 0,
                italic: style & UInt16(ZSHELL_CELL_ITALIC) != 0
            ))
            text.removeAll(keepingCapacity: true)
            columns.removeAll(keepingCapacity: true)
        }

        for (column, cell) in cells.enumerated() {
            if cell.flags & UInt16(ZSHELL_CELL_WIDE_SPACER) != 0 { continue }
            let nextStyle = cell.flags & styleFlags
            if !text.isEmpty, nextStyle != style { finishRun(at: column) }
            style = nextStyle
            let content: String
            if cell.flags & UInt16(ZSHELL_CELL_HIDDEN) != 0 {
                content = " "
            } else if let data = cell.text, let cluster = String(data: data, encoding: .utf8) {
                content = cluster
            } else {
                content = Unicode.Scalar(cell.scalar).map(String.init) ?? " "
            }
            let normalized = cell.scalar == 0 ? " " : content
            text += normalized
            columns += repeatElement(column, count: normalized.utf16.count)
        }
        finishRun(at: snapshot.columns)
        rows[row] = Row(cells: cells, glyphs: result)
        return result
    }

    private func shape(text: String, columns: [Int], cells: [Cell], font: NSFont) -> [Glyph] {
        #if DEBUG
        shapedRunCount += 1
        #endif
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font,
            // Keep the paragraph anchored left; glyph string indices below
            // map shaped scripts back onto the emulator's logical cell order.
            NSAttributedString.Key(kCTWritingDirectionAttributeName as String): [0],
        ]))
        struct RunGlyph {
            let font: CTFont
            let glyph: CGGlyph
            let index: Int
            let position: CGPoint
            let advance: CGFloat
            let hasInk: Bool
        }
        var source: [RunGlyph] = []
        for case let run as CTRun in CTLineGetGlyphRuns(line) as NSArray {
            let count = CTRunGetGlyphCount(run)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let font = attributes[kCTFontAttributeName] else { continue }
            let runFont = font as! CTFont
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &positions)
            CTRunGetStringIndices(run, CFRange(), &indices)
            CTRunGetAdvances(run, CFRange(), &advances)
            for index in 0..<count where indices[index] >= 0 && indices[index] < columns.count - 1 {
                var glyph = glyphs[index]
                let bounds = CTFontGetBoundingRectsForGlyphs(runFont, .horizontal, &glyph, nil, 1)
                source.append(RunGlyph(font: runFont, glyph: glyph, index: indices[index],
                                       position: positions[index], advance: advances[index].width,
                                       hasInk: bounds.width > 0 && bounds.height > 0))
            }
        }
        let stringEnds = Array(Set(source.map(\.index) + [columns.count - 1])).sorted()
        var endByIndex: [Int: Int] = [:]
        for (start, end) in zip(stringEnds, stringEnds.dropFirst()) { endByIndex[start] = end }

        var result: [Glyph] = []
        var start = 0
        while start < source.count {
            var end = start + 1
            let first = source[start]
            while end < source.count, columns[source[end].index] == columns[first.index] { end += 1 }
            // Programming fonts can preserve one glyph per input cell by
            // replacing the leading cells with blank glyphs and drawing the
            // whole ligature from the last cell. Keep that group together when
            // cell spacing differs from the font's natural advance.
            if !first.hasInk, !cells[columns[first.index]].scalar.isWhitespace {
                while end < source.count, !source[end - 1].hasInk,
                      CFEqual(source[end].font, first.font),
                      !cells[columns[source[end].index]].scalar.isWhitespace {
                    end += 1
                }
            }
            let group = source[start..<end]
            let firstColumn = group.map { columns[$0.index] }.min() ?? 0
            let lastColumn = group.map { columns[endByIndex[$0.index] ?? columns.count - 1] }.max() ?? firstColumn + 1
            let range = firstColumn..<max(firstColumn + 1, lastColumn)
            let naturalLeft = group.map(\.position.x).min() ?? 0
            let naturalRight = group.map { $0.position.x + $0.advance }.max() ?? naturalLeft
            let centering = range.count > 1
                ? (CGFloat(range.count) * cellWidth - (naturalRight - naturalLeft)) / 2 : 0
            for glyph in group where glyph.hasInk {
                result.append(Glyph(
                    font: glyph.font, glyph: glyph.glyph,
                    position: CGPoint(x: CGFloat(firstColumn) * cellWidth + centering
                                      + glyph.position.x - naturalLeft, y: glyph.position.y),
                    columns: range
                ))
            }
            start = end
        }
        return result
    }
}

private extension UInt32 {
    var isWhitespace: Bool { self == 0 || Unicode.Scalar(self)?.properties.isWhitespace == true }
}
