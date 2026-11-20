"""Render production file rows while scrolling beneath a stationary pointer.

Run: python3 mac/tests/test_file_tree_hover.py [--source-ref <git-ref>]
The offscreen AppKit fixture never sends desktop input. Temporary binaries and
module caches are removed after every run.
"""

import argparse
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SOURCE = "mac/zshell/AppKitFileTreePanel.swift"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-ref")
    options = parser.parse_args()
    source = (subprocess.check_output(["git", "show", f"{options.source_ref}:{SOURCE}"],
                                      cwd=ROOT, text=True)
              if options.source_ref else (ROOT / SOURCE).read_text())
    # Keep the production table, row lifecycle, drawing, and tracking intact.
    # Only unrelated app/model dependencies are supplied by the fixture.
    rows = source[source.index("private final class FileTreeTableView:"):]
    fixture = r'''
import AppKit

enum Theme { static let accent = NSColor.systemBlue }
enum MaterialFileIcon {
    static func image(forPath path: String, appearance: NSAppearance) -> NSImage? { nil }
}
enum FileTreeModel {
    struct Item {
        let name: String
        let path: String
        let isDirectory: Bool
        let depth: Int
        var isDraft = false
    }
}
enum GitStatusModel {
    enum FileDecoration { case modified, added, untracked, deleted, renamed, copied, conflict, ignored }
}
final class HoverWindow: NSWindow {
    var pointer = NSPoint(x: -100, y: -100)
    var fixtureKey = true
    override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
    override var isKeyWindow: Bool { fixtureKey }
}
private final class HoverRows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let items = (0..<60).map {
        FileTreeModel.Item(name: "file-\($0).txt", path: "/fixture/file-\($0).txt", isDirectory: false, depth: 0)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("FileTreeRow")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? FileTreeRowView ?? FileTreeRowView()
        cell.identifier = id
        configure(cell, item: items[row])
        return cell
    }
    func configure(_ cell: FileTreeRowView, item: FileTreeModel.Item, selected: Bool = false, current: Bool = false) {
        cell.configure(item: item, expanded: false, decoration: nil,
                       current: current, selected: selected, drop: false, scale: 1)
    }
}

@main
struct FileTreeHoverTests {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var checks = 0
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(message)")
        }
        func alpha(_ view: NSView) -> CGFloat {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let context = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.clear(view.bounds)
            view.effectiveAppearance.performAsCurrentDrawingAppearance { view.draw(view.bounds) }
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            return bitmap.colorAt(x: Int(view.bounds.width) - 28,
                                  y: Int(view.bounds.height) / 2)!.alphaComponent
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let window = HoverWindow(contentRect: NSRect(x: -100_000, y: -100_000, width: 320, height: 160),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
            scroll.drawsBackground = false
            let table = FileTreeTableView(frame: scroll.bounds)
            table.headerView = nil
            table.style = .plain
            table.rowHeight = 24
            table.intercellSpacing = NSSize(width: 0, height: 1)
            table.selectionHighlightStyle = .none
            table.addTableColumn(NSTableColumn(identifier: .init("file")))
            let rows = HoverRows()
            table.delegate = rows
            table.dataSource = rows
            scroll.documentView = table
            window.contentView = scroll
            table.reloadData()
            table.layoutSubtreeIfNeeded()
            func row(_ index: Int) -> FileTreeRowView {
                let cell = table.view(atColumn: 0, row: index, makeIfNecessary: true) as! FileTreeRowView
                cell.layoutSubtreeIfNeeded()
                return cell
            }
            let first = row(2)
            window.pointer = first.convert(NSPoint(x: 80, y: first.bounds.midY), to: nil)
            let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: window.pointer,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
            first.mouseEntered(with: enter)
            check(alpha(first) > 0, "pointer over a file paints hover (\(appearance))")
            check(table.selectedRow == -1, "hover leaves the table unselected")

            // Clipping can rebuild tracking areas without an exit event for the
            // old region. Use AppKit geometry while the pointer stays still.
            scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: 2).minY))
            scroll.reflectScrolledClipView(scroll.contentView)
            first.updateTrackingAreas()
            let next = row(4)
            next.updateTrackingAreas()
            check(alpha(first) == 0, "scroll clears the old visible row without mouseExited")
            check(alpha(next) > 0, "the row scrolled under the stationary pointer gains hover")
            let visible = table.rows(in: table.visibleRect)
            for index in visible.location..<NSMaxRange(visible) {
                let cell = row(index)
                cell.updateTrackingAreas()
                check((alpha(cell) > 0) == (index == 4), "only the pointer row has hover: \(index)")
            }
            check(table.selectedRow == -1, "scrolling retains empty selection")

            scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: 12).minY))
            scroll.reflectScrolledClipView(scroll.contentView)
            next.updateTrackingAreas()
            check(alpha(next) == 0, "a clipped-out retained row loses hover")
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            let reused = row(2)
            reused.mouseEntered(with: enter)
            window.pointer = NSPoint(x: -100, y: -100)
            rows.configure(reused, item: rows.items[20])
            check(alpha(reused) == 0, "configure clears hover retained from the previous item")
            window.pointer = reused.convert(NSPoint(x: 80, y: reused.bounds.midY), to: nil)
            reused.updateTrackingAreas()
            check(alpha(reused) > 0, "hover returns under the pointer")
            window.fixtureKey = false
            reused.updateTrackingAreas()
            check(alpha(reused) == 0, "inactive window has no hover")
            window.fixtureKey = true
            reused.updateTrackingAreas()
            check(alpha(reused) > 0, "key window restores hover under a stationary pointer")
            scroll.isHidden = true
            check(alpha(reused) == 0, "hiding the file tree clears hover")
            scroll.isHidden = false
            reused.updateTrackingAreas()
            check(alpha(reused) > 0, "unhiding restores hover under the pointer")
            reused.removeFromSuperview()
            check(alpha(reused) == 0, "detaching a recycled row clears hover")

            window.pointer = NSPoint(x: -100, y: -100)
            let selected = FileTreeRowView(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            rows.configure(selected, item: rows.items[0], selected: true)
            let current = FileTreeRowView(frame: selected.frame)
            rows.configure(current, item: rows.items[1], current: true)
            let draft = FileTreeRowView(frame: selected.frame)
            var draftItem = rows.items[2]
            draftItem.isDraft = true
            rows.configure(draft, item: draftItem)
            check(alpha(selected) > 0.07, "selection keeps its independent background")
            check(alpha(current) > 0.07, "current file keeps its independent background")
            check(alpha(draft) > 0, "inline draft keeps its independent background")
            window.close()
        }
        check(!NSApp.isActive && NSApp.windows.allSatisfy { !$0.isVisible }, "fixture stays invisible and inactive")
        print("File tree hover regression: \(checks - failures) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
'''
    with tempfile.TemporaryDirectory(prefix="zshell-file-tree-hover-") as directory:
        temporary = Path(directory)
        helper = temporary / "FileTreeHoverTests.swift"
        helper.write_text(rows + fixture)
        binary = temporary / "file-tree-hover-tests"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                        "-default-isolation", "MainActor", "-warnings-as-errors",
                        "-module-cache-path", str(temporary / "modules"), str(helper),
                        "-o", str(binary)], cwd=ROOT, check=True, timeout=60)
        subprocess.run([str(binary)], cwd=ROOT, check=True, timeout=15)


if __name__ == "__main__":
    main()
