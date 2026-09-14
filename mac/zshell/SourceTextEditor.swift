//
//  SourceTextEditor.swift
//  zshell
//

import AppKit
import STPluginNeon
import STTextKitPlus
import STTextView

/// Scroll offset and cursor position of a file tab's editor, kept on the
/// `FileTab` so it survives tab switches, and in the session snapshot so it
/// survives relaunches. Every field is optional so decoding tolerates
/// snapshots written by earlier editor stacks.
struct EditorState: Codable, Equatable {
    var selectionLocation: Int?
    var selectionLength: Int?
    var scrollX: Double?
    var scrollY: Double?
    /// When set, the editor scrolls `selectionLocation` into view on mount
    /// instead of restoring `scrollX`/`scrollY` — how opening a file from a
    /// search hit reaches its matched line. Consumed once applied.
    var revealSelection: Bool?
}

/// Editor colors derived from the application palette (`Theme.background` is
/// the same color, so the editor blends into the window). Selection color is
/// not included: STTextView always uses the system selection color.
struct EditorPalette: Equatable {
    var text: NSColor
    var background: NSColor
    var insertionPoint: NSColor
    var lineHighlight: NSColor
    var gutterText: NSColor

    static func theme(dark: Bool) -> EditorPalette {
        let theme = Theme.application(dark: dark)
        return EditorPalette(
            text: theme.foregroundNSColor,
            background: theme.backgroundNSColor,
            insertionPoint: theme.accentNSColor,
            lineHighlight: theme.surfaceNSColor(elevation: 0.04),
            gutterText: theme.surfaceNSColor(elevation: 0.3)
        )
    }
}

/// STTextView driven directly from AppKit: plain-text editing with line
/// numbers and the system search-and-replace find bar (⌘F / ⌥⌘F via the Edit ▸
/// Find menu, routed here by `FileTab.performFindAction`). Text edits are
/// written straight back to `FileTab.text`; scroll/cursor state is written back
/// to `FileTab.editorState` as it changes and restored when the editor is
/// rebuilt on tab switch or relaunch.
///
/// Owned by `FileViewerContainerView`, which mounts and discards it as the tab
/// switches between source and rendered markdown.
@MainActor
final class SourceEditorController: NSObject, STTextViewDelegate {
    /// The editor's scroll view, for the container to install.
    let scrollView: NSScrollView

    private let file: FileTab
    private weak var textView: STTextView?
    private var scrollObserver: (any NSObjectProtocol)?
    /// The in-flight edit from `willChangeTextIn`, replayed onto the text
    /// snapshot in `didChangeTextIn` so `file.text` updates without TextKit
    /// copying the whole document back out.
    private var pendingTextChange: (range: NSRange, replacement: String)?
    private var appliedGranularChange = false
    /// Last-applied focus state, so `update` acts only on the unfocused→focused
    /// edge rather than stealing the caret on every settings change.
    private var wasFocused = false

    init(
        file: FileTab,
        font: NSFont,
        palette: EditorPalette,
        wrapLines: Bool,
        isFocused: Bool,
        onFocused: @escaping () -> Void,
        onSplit: @escaping (PaneDropEdge) -> Void
    ) {
        self.file = file
        let scrollView = RestorableScrollView()
        self.scrollView = scrollView
        super.init()

        let textView = FocusReportingTextView()
        self.textView = textView
        textView.onBecomeFirstResponder = onFocused
        textView.splitTarget.onSplit = onSplit
        scrollView.wantsLayer = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = textView

        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        // The window uses a full-size content view, so automatic insets
        // would add a titlebar-height top inset that misaligns the gutter
        // numbers against the text by one line.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        // The gutter is a document-height floating subview that scrolls
        // vertically with the text; since macOS 14 NSViews no longer clip
        // subviews by default, so without this the scrolled-away line
        // numbers draw outside the scroll view, over the header above it.
        scrollView.clipsToBounds = true

        // Configure typography before setting the text: the font/color
        // setters restyle the whole document, and restyling after layout
        // used to leave stale layout fragments that broke gutter numbering.
        textView.showsLineNumbers = true
        textView.highlightSelectedLine = true
        // Highlight every match as the query is typed in the find bar, the way
        // the terminal's find bar searches as you type. Off by default in
        // STTextView.
        textView.isIncrementalSearchingEnabled = true
        apply(font: font, palette: palette, wrapLines: wrapLines)
        // Seed the snapshot the highlighting plugin and the granular write-back
        // below read from, so the document is never copied wholesale out of
        // TextKit just to observe it.
        textView.setTextSnapshot(file.text)
        textView.text = file.text

        // Tree-sitter syntax highlighting (STPluginNeon), for file types with
        // a bundled grammar. Added after the text is set so the plugin's
        // initial full-document parse — which runs when the view lands in a
        // window — sees the whole document. The plugin only layers foreground
        // colors as rendering attributes; the font stays zshell's (see
        // SyntaxHighlighting.theme).
        if let plugin = SyntaxHighlighting.plugin(for: file.path) {
            textView.addPlugin(plugin)
        }

        // Captured before the scroll observer attaches, because it starts
        // overwriting `editorState` immediately.
        let state = file.editorState
        if let location = state.selectionLocation {
            let limit = (textView.text ?? "").utf16.count
            let start = min(max(0, location), limit)
            let length = min(max(0, state.selectionLength ?? 0), limit - start)
            textView.textSelection = NSRange(location: start, length: length)
        }

        attach(textView: textView, scrollView: scrollView)

        // Restore the saved scroll offset during the first layout pass — while
        // the frame is finally known but before the first paint — so the file
        // opens already at its saved position. Doing this asynchronously (after
        // the initial paint at the top) makes the editor visibly scroll into
        // place and flashes the auto-hiding scroller. A pending reveal takes
        // its place instead: the caret was just placed on the line a search
        // hit asked for, and that line is scrolled into view the same way.
        if state.revealSelection == true, let location = state.selectionLocation {
            scrollView.restoreOnFirstLayout = { [weak scrollView, weak textView, weak file] in
                guard let scrollView, let textView else { return }
                textView.scrollRangeToVisible(NSRange(location: location, length: 0))
                // Consume the request so later tab switches restore the
                // offset the user actually scrolled to.
                file?.editorState.revealSelection = nil
            }
        } else if state.scrollX != nil || state.scrollY != nil {
            scrollView.restoreOnFirstLayout = { [weak scrollView, weak textView] in
                guard let scrollView, let textView else { return }
                let clipView = scrollView.contentView
                // setBoundsOrigin (not scroll(to:)) avoids clamping against a
                // content height that TextKit2 has only estimated so far.
                clipView.setBoundsOrigin(NSPoint(x: state.scrollX ?? 0, y: state.scrollY ?? 0))
                scrollView.reflectScrolledClipView(clipView)
                // Lay out the viewport around the restored offset in this same
                // pass so the region is painted in place, not after a scroll.
                textView.needsLayout = true
            }
        }

        // Only grab focus on mount when this pane is the focused one, so an
        // unfocused split doesn't steal the caret.
        if isFocused {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
        wasFocused = isFocused
        // Expose the view so a pane-move drag can snapshot it as a thumbnail,
        // and so Find menu actions can reach the text view.
        file.editorView = scrollView
    }

    deinit {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
    }

    func update(
        font: NSFont,
        palette: EditorPalette,
        wrapLines: Bool,
        isFocused: Bool,
        onFocused: @escaping () -> Void,
        onSplit: @escaping (PaneDropEdge) -> Void
    ) {
        guard let textView = textView as? FocusReportingTextView else { return }
        textView.onBecomeFirstResponder = onFocused
        textView.splitTarget.onSplit = onSplit
        apply(font: font, palette: palette, wrapLines: wrapLines)
        // Take focus on the unfocused→focused edge (keyboard navigation moving
        // focus here), never on every update.
        if isFocused, !wasFocused {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
        wasFocused = isFocused
    }

    func takeFocus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    /// Guarded assignments: the font/color setters restyle the whole document,
    /// and this runs on every settings or appearance change.
    private func apply(font: NSFont, palette: EditorPalette, wrapLines: Bool) {
        guard let textView else { return }
        if textView.font != font {
            textView.font = font
        }
        if textView.textColor != palette.text {
            textView.textColor = palette.text
        }
        if textView.backgroundColor != palette.background {
            textView.backgroundColor = palette.background
            scrollView.backgroundColor = palette.background
        }
        textView.insertionPointColor = palette.insertionPoint
        textView.selectedLineHighlightColor = palette.lineHighlight
        // false = wrap at the view width, true = expand horizontally.
        textView.isHorizontallyResizable = !wrapLines
        if let gutter = textView.gutterView {
            gutter.textColor = palette.gutterText
            gutter.selectedLineTextColor = palette.text
        }
    }

    private func attach(textView: STTextView, scrollView: NSScrollView) {
        textView.textDelegate = self
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self, weak scrollView] _ in
            MainActor.assumeIsolated {
                guard let self, let clipView = scrollView?.contentView else { return }
                self.file.editorState.scrollX = clipView.bounds.origin.x
                self.file.editorState.scrollY = clipView.bounds.origin.y
            }
        }
    }

    func textView(
        _ textView: STTextView,
        willChangeTextIn affectedCharRange: NSTextRange,
        replacementString: String
    ) {
        appliedGranularChange = false
        let range = NSRange(affectedCharRange, in: textView.textContentManager)
        guard range.location != NSNotFound else {
            pendingTextChange = nil
            (textView as? FocusReportingTextView)?.invalidateTextSnapshot()
            return
        }
        pendingTextChange = (range, replacementString)
    }

    func textView(
        _ textView: STTextView,
        didChangeTextIn affectedCharRange: NSTextRange,
        replacementString: String
    ) {
        defer { pendingTextChange = nil }
        guard let editor = textView as? FocusReportingTextView,
              editor.isTextSnapshotValid,
              let pendingTextChange,
              pendingTextChange.replacement == replacementString,
              pendingTextChange.range.location >= 0,
              pendingTextChange.range.location + pendingTextChange.range.length
                  <= editor.textSnapshotUTF16Length
        else {
            (textView as? FocusReportingTextView)?.invalidateTextSnapshot()
            return
        }

        let oldLength = editor.textSnapshotUTF16Length
        let newLength = oldLength - pendingTextChange.range.length + replacementString.utf16.count
        var snapshot = editor.textSnapshot
        let mutableSnapshot = NSMutableString(string: snapshot)
        mutableSnapshot.replaceCharacters(in: pendingTextChange.range, with: replacementString)
        snapshot = mutableSnapshot as String
        guard newLength == textView.textContentManager.length else {
            editor.invalidateTextSnapshot()
            return
        }
        editor.setTextSnapshot(snapshot, utf16Length: newLength)
        file.text = snapshot
        appliedGranularChange = true
    }

    func textViewDidChangeText(_ notification: Notification) {
        guard let textView else { return }
        // The granular path above already wrote `file.text` from the snapshot;
        // re-reading `textView.text` here would copy the whole document on
        // every keystroke — the cost this whole mechanism exists to avoid.
        if appliedGranularChange {
            appliedGranularChange = false
            file.refreshDirtyState()
            return
        }

        let newText = textView.text ?? ""
        (textView as? FocusReportingTextView)?.setTextSnapshot(
            newText,
            utf16Length: textView.textContentManager.length
        )
        guard newText != file.text else { return }
        file.text = newText
        file.refreshDirtyState()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView else { return }
        let selection = textView.textSelection
        file.editorState.selectionLocation = selection.location
        file.editorState.selectionLength = selection.length
    }
}

/// STTextView that reports when it takes first-responder status (a click, or a
/// programmatic focus), so the owning pane can mark itself focused in the model,
/// and appends pane-split items to its context menu.
final class FocusReportingTextView: STTextView {
    /// Plain-text mirror of the document, kept in step by the editor
    /// controller's granular will/did-change callbacks. Reading the document
    /// through TextKit (`attributedString(in: nil)`) styles and copies the
    /// whole text on every call — what tree-sitter's read handlers did per
    /// keystroke — so readers take this snapshot instead; an out-of-step
    /// update invalidates it and the next read falls back to (and re-seeds
    /// from) TextKit.
    private(set) var textSnapshot = ""
    private(set) var textSnapshotUTF16Length = 0
    private(set) var isTextSnapshotValid = true

    private struct SelectionState {
        var ranges: [NSRange]
        let affinity: NSTextSelection.Affinity
        let granularity: NSTextSelection.Granularity
        let anchorPositionOffset: CGFloat
        let isLogical: Bool
        let typingAttributes: [NSAttributedString.Key: Any]?
    }

    private struct NewlineEdit {
        let range: NSRange
        let textRange: NSTextRange
        let replacement: String
        let selectionIndex: Int
        let rangeIndex: Int
    }

    private enum SelectionUndoAction {
        case restoreBeforeEdit
        case restoreAfterEdit
    }

    var onBecomeFirstResponder: (() -> Void)?
    /// Owns the split context-menu items, kept off the text view so its own
    /// menu validation doesn't disable them.
    let splitTarget = SplitMenuTarget()

    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText(), let source = text as NSString? else {
            super.insertNewline(sender)
            return
        }
        let states = selectionStates()
        guard let edits = newlineEdits(for: states, in: source), !edits.isEmpty else {
            super.insertNewline(sender)
            return
        }

        let replacements = Set(edits.map(\.replacement))
        if edits.count == 1, let replacement = replacements.first {
            guard replacement != "\n" else {
                super.insertNewline(sender)
                return
            }
            breakUndoCoalescing()
            insertText(replacement, replacementRange: .notFound)
            breakUndoCoalescing()
            return
        }

        guard edits.allSatisfy({ shouldChangeText(in: $0.textRange, replacementString: $0.replacement) }) else {
            return
        }
        applyNewlineEdits(edits, selectionStates: states)
    }

    private func selectionStates() -> [SelectionState] {
        textLayoutManager.textSelections.map { selection in
            SelectionState(
                ranges: selection.textRanges.map { NSRange($0, in: textContentManager) },
                affinity: selection.affinity,
                granularity: selection.granularity,
                anchorPositionOffset: selection.anchorPositionOffset,
                isLogical: selection.isLogical,
                typingAttributes: selection.typingAttributes
            )
        }
    }

    private func newlineEdits(for states: [SelectionState], in source: NSString) -> [NewlineEdit]? {
        var edits: [NewlineEdit] = []
        for (selectionIndex, state) in states.enumerated() {
            for (rangeIndex, range) in state.ranges.enumerated() {
                guard range.location <= source.length,
                      range.length <= source.length - range.location,
                      let textRange = NSTextRange(range, in: textContentManager)
                else {
                    return nil
                }
                edits.append(NewlineEdit(
                    range: range,
                    textRange: textRange,
                    replacement: "\n" + indentation(at: range.location, in: source),
                    selectionIndex: selectionIndex,
                    rangeIndex: rangeIndex
                ))
            }
        }
        return edits
    }

    private func indentation(at location: Int, in source: NSString) -> String {
        var lineStart = 0
        source.getLineStart(&lineStart, end: nil, contentsEnd: nil, for: NSRange(location: location, length: 0))
        var end = lineStart
        while end < location {
            let character = source.character(at: end)
            guard character == 0x20 || character == 0x09 else { break }
            end += 1
        }
        return source.substring(with: NSRange(location: lineStart, length: end - lineStart))
    }

    private func applyNewlineEdits(_ edits: [NewlineEdit], selectionStates states: [SelectionState]) {
        var updatedStates = states
        breakUndoCoalescing()
        let shouldGroupUndo = allowsUndo && undoManager?.isUndoRegistrationEnabled == true
        if shouldGroupUndo {
            undoManager?.beginUndoGrouping()
        }
        defer {
            if shouldGroupUndo {
                undoManager?.endUndoGrouping()
            }
            breakUndoCoalescing()
        }

        let orderedEdits = edits.sorted(by: { $0.range.location > $1.range.location })
        for edit in orderedEdits {
            updateSelectionStates(&updatedStates, after: edit)
        }
        registerSelectionUndo(.restoreBeforeEdit, before: states, after: updatedStates)
        for edit in orderedEdits {
            replaceCharacters(in: edit.textRange, with: edit.replacement)
        }
        registerSelectionUndo(
            .restoreBeforeEdit, before: states, after: updatedStates, restoresSelection: false
        )
        restoreSelections(updatedStates)
    }

    private func updateSelectionStates(_ states: inout [SelectionState], after edit: NewlineEdit) {
        let delta = edit.replacement.utf16.count - edit.range.length
        for stateIndex in states.indices {
            for rangeIndex in states[stateIndex].ranges.indices {
                var range = states[stateIndex].ranges[rangeIndex]
                if stateIndex == edit.selectionIndex, rangeIndex == edit.rangeIndex {
                    range = NSRange(location: edit.range.location + edit.replacement.utf16.count, length: 0)
                } else if range.location >= edit.range.location + edit.range.length {
                    range.location += delta
                }
                states[stateIndex].ranges[rangeIndex] = range
            }
        }
    }

    /// Paired around the text edits so both undo and redo restore selections
    /// after restoring the text their ranges belong to. The other half only
    /// registers the inverse at the far end of the next undo group.
    private func registerSelectionUndo(
        _ action: SelectionUndoAction,
        before: [SelectionState],
        after: [SelectionState],
        restoresSelection: Bool = true
    ) {
        guard allowsUndo, let undoManager, undoManager.isUndoRegistrationEnabled else { return }
        switch action {
        case .restoreBeforeEdit:
            undoManager.registerUndo(withTarget: self) { textView in
                if restoresSelection { textView.restoreSelections(before) }
                textView.registerSelectionUndo(
                    .restoreAfterEdit, before: before, after: after, restoresSelection: !restoresSelection
                )
            }
        case .restoreAfterEdit:
            undoManager.registerUndo(withTarget: self) { textView in
                if restoresSelection { textView.restoreSelections(after) }
                textView.registerSelectionUndo(
                    .restoreBeforeEdit, before: before, after: after, restoresSelection: !restoresSelection
                )
            }
        }
    }

    private func restoreSelections(_ states: [SelectionState]) {
        let selections = states.compactMap { state -> NSTextSelection? in
            let ranges = state.ranges.compactMap { NSTextRange($0, in: textContentManager) }
            guard ranges.count == state.ranges.count else { return nil }
            let selection = NSTextSelection(ranges, affinity: state.affinity, granularity: state.granularity)
            selection.anchorPositionOffset = state.anchorPositionOffset
            selection.isLogical = state.isLogical
            selection.typingAttributes = state.typingAttributes ?? [:]
            return selection
        }
        guard selections.count == states.count else { return }
        textLayoutManager.textSelections = selections
    }

    func setTextSnapshot(_ text: String, utf16Length: Int? = nil) {
        textSnapshot = text
        textSnapshotUTF16Length = utf16Length ?? text.utf16.count
        isTextSnapshotValid = true
    }

    func invalidateTextSnapshot() {
        isTextSnapshotValid = false
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onBecomeFirstResponder?() }
        return became
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        menu.addItem(.separator())
        for item in splitTarget.menuItems() { menu.addItem(item) }
        return menu
    }
}

/// NSScrollView that runs a one-shot restoration during its first real layout
/// pass — before the first paint — so a restored file opens already scrolled to
/// its saved position instead of visibly jumping there afterward.
private final class RestorableScrollView: NSScrollView {
    var restoreOnFirstLayout: (() -> Void)?
    private var lastViewportSize: NSSize = .zero
    private var geometryUpdateScheduled = false

    /// Temporary: set ZSHELL_SCROLLER_DEBUG=1 to trace scroller geometry.
    private func logScroller(_ tag: String) {
        guard ProcessInfo.processInfo.environment["ZSHELL_SCROLLER_DEBUG"] != nil else { return }
        guard let scroller = verticalScroller else { print("[scroller] \(tag) none"); return }
        let scrollerInWindow = scroller.convert(scroller.bounds, to: nil)
        let selfInWindow = convert(bounds, to: nil)
        print("""
        [scroller] \(tag) \
        sv.w=\(Int(bounds.width)) sv.inWindow.x=\(Int(selfInWindow.minX))..\(Int(selfInWindow.maxX)) \
        clip.w=\(Int(contentView.bounds.width)) doc.w=\(Int(documentView?.frame.width ?? -1)) \
        scroller.frame=\(Int(scroller.frame.minX)),w=\(Int(scroller.frame.width)) \
        scroller.inWindow.x=\(Int(scrollerInWindow.minX)) hidden=\(scroller.isHidden) \
        super=\(scroller.superview.map { String(describing: type(of: $0)) } ?? "nil")
        """)
    }

    override func layout() {
        super.layout()
        let viewportSize = contentView.bounds.size
        if viewportSize != lastViewportSize {
            lastViewportSize = viewportSize
            scheduleEditorGeometryUpdate()
        }
        logScroller("layout")
        if bounds.width > 0, bounds.height > 0, let restore = restoreOnFirstLayout {
            restoreOnFirstLayout = nil
            restore()
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        scheduleEditorGeometryUpdate()
    }

    /// STTextView's document view can inherit the viewport's width while the
    /// window is resizing. Re-run its content sizing after AppKit finishes the
    /// scroll-view layout, then clamp the old offset to the new scroll range
    /// and refresh the scroller thumb/proportion.
    private func scheduleEditorGeometryUpdate() {
        guard !geometryUpdateScheduled else { return }
        geometryUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.geometryUpdateScheduled = false
            guard let textView = self.documentView as? STTextView else { return }

            textView.needsLayout = true
            textView.layoutSubtreeIfNeeded()

            // Re-place the scrollers against the new width. An overlay scroller
            // that was faded out when the viewport changed keeps the frame it
            // had, so it comes back at the editor's *old* trailing edge — most
            // visibly after ⇧⌘B closes the right panel, where it reappears
            // mid-document with text running past it.
            self.tile()

            let clipView = self.contentView
            let constrainedBounds = clipView.constrainBoundsRect(clipView.bounds)
            if constrainedBounds.origin != clipView.bounds.origin {
                clipView.setBoundsOrigin(constrainedBounds.origin)
            }
            self.reflectScrolledClipView(clipView)
        }
    }
}

// MARK: - Revealing a search hit

extension FileTab {
    /// Lands the caret on `location` (a UTF-16 offset into the file text) and
    /// scrolls it into view — how opening a file-content search hit reaches
    /// its matched line. A mounted editor is moved right away; an unmounted
    /// one (its tab is not selected) carries the request in `editorState` and
    /// applies it the next time it mounts.
    func revealSelection(at location: Int) {
        if let scrollView = editorView as? NSScrollView,
           let textView = scrollView.documentView as? STTextView {
            Self.reveal(location: location, in: textView)
            return
        }
        editorState.selectionLocation = location
        editorState.selectionLength = 0
        editorState.revealSelection = true
    }

    private static func reveal(location: Int, in textView: STTextView) {
        let limit = (textView.text ?? "").utf16.count
        let range = NSRange(location: min(max(0, location), limit), length: 0)
        textView.textSelection = range
        textView.scrollRangeToVisible(range)
    }
}
