//
//  AppTerminalView+PublicInput.swift
//  libghostty-spm
//
//  Public wrappers around `TerminalSurface` write paths so hosts can
//  inject bytes into the pty without reaching for internal API.
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import GhosttyKit

    extension AppTerminalView {
        /// Send raw UTF-8 text directly to the underlying pty (bypassing
        /// key translation). Use this for synthetic input like `\x1b[Z`
        /// (Shift+Tab / CSI Z) or multi-line paste-style injections.
        /// No-op when the surface has not been created yet.
        public func sendText(_ text: String) {
            surface?.sendText(text)
        }

        /// Invoke a named Ghostty binding action (e.g. "copy_to_clipboard",
        /// "clear_screen"). Returns true when the action dispatched.
        @discardableResult
        public func performBindingAction(_ action: String) -> Bool {
            surface?.performBindingAction(action) ?? false
        }

        /// Jump the viewport by a number of shell prompts.
        ///
        /// Negative offsets move toward older prompts and positive offsets move
        /// toward newer prompts. Prompt navigation requires shell integration.
        @discardableResult
        public func jumpToPrompt(by offset: Int16) -> Bool {
            surface?.jumpToPrompt(by: offset) ?? false
        }

        /// Reveal an absolute scrollback row, where zero is the first row.
        @discardableResult
        public func scrollToRow(_ row: UInt) -> Bool {
            surface?.scrollToRow(row) ?? false
        }

        /// Whether the grid currently holds a selection.
        public var hasSelection: Bool {
            surface?.hasSelection() ?? false
        }

        /// The visible terminal selection without modifying the pasteboard.
        /// It remains nil when no surface exists.
        public var selectedText: String? {
            surface?.readSelection()
        }

        /// True when the application running in the terminal owns mouse input.
        public var isMouseCaptured: Bool {
            surface?.isMouseCaptured ?? false
        }

        /// Refreshes link callbacks at a context click and reads its text token
        /// without changing the terminal selection or the system pointer.
        public func contextText(for event: NSEvent) -> String? {
            guard let surface, let rawSurface = surface.rawValue else { return nil }
            let point = mousePoint(from: event)
            let mods = TerminalInputModifiers(from: event.modifierFlags).ghosttyMods
            // Ghostty skips equal coordinates even when modifiers or output changed.
            surface.sendMousePos(x: -1, y: -1, mods: mods)
            surface.sendMousePos(x: point.x, y: point.y, mods: mods)
            guard let word = surface.quicklookWord(), !word.word.isEmpty else { return nil }

            func read(_ end: ghostty_point_s) -> (text: String, start: UInt32, length: UInt32)? {
                let selection = ghostty_selection_s(
                    top_left: ghostty_point_s(
                        tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0
                    ),
                    bottom_right: end,
                    rectangle: false
                )
                var result = ghostty_text_s()
                guard ghostty_surface_read_text(rawSurface, selection, &result) else { return nil }
                defer { ghostty_surface_free_text(rawSurface, &result) }
                let text = result.text.map {
                    String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(result.text_len)), as: UTF8.self)
                } ?? ""
                return (text, result.offset_start, result.offset_len)
            }

            // Native offsets count cells, not bytes. A prefix read maps the
            // word's first cell to a String index, including wide Unicode cells.
            guard let size = surface.size(),
                  let firstRow = read(ghostty_point_s(
                    tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                    x: UInt32(size.columns), y: 0
                  )),
                  firstRow.length < UInt32.max,
                  word.offsetStart >= firstRow.start
            else { return word.word }
            let columns = firstRow.length + 1
            let offset = word.offsetStart - firstRow.start
            guard let prefix = read(ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                x: offset % columns, y: offset / columns
            )), let viewport = read(ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0
            )) else { return word.word }
            let anchor = prefix.text.utf16.count - String(word.word.prefix(1)).utf16.count
            guard anchor >= 0, anchor < viewport.text.utf16.count else { return word.word }
            let text = viewport.text
            var lower = String.Index(utf16Offset: anchor, in: text)
            var upper = lower
            func isBoundary(_ character: Character) -> Bool {
                character.isWhitespace || "<>\"'`。，、；：？！）".contains(character)
            }
            while lower > text.startIndex, !isBoundary(text[text.index(before: lower)]) {
                lower = text.index(before: lower)
            }
            while upper < text.endIndex, !isBoundary(text[upper]) {
                upper = text.index(after: upper)
            }
            return String(text[lower..<upper]).trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}"))
        }

        /// Search the screen and scrollback for `needle`, replacing any active
        /// search. An empty needle cancels without dismissing host search UI.
        @discardableResult
        public func search(_ needle: String) -> Bool {
            surface?.search(needle) ?? false
        }

        /// Search for the current selection; no-op without one.
        @discardableResult
        public func searchSelection() -> Bool {
            surface?.searchSelection() ?? false
        }

        /// Open search with no terms set, reported back through
        /// ``TerminalSurfaceSearchDelegate``.
        @discardableResult
        public func startSearch() -> Bool {
            surface?.startSearch() ?? false
        }

        /// Select the next or previous match of the active search.
        @discardableResult
        public func navigateSearch(forward: Bool) -> Bool {
            surface?.navigateSearch(forward: forward) ?? false
        }

        /// End the active search and clear its highlights.
        @discardableResult
        public func endSearch() -> Bool {
            surface?.endSearch() ?? false
        }
    }
#endif
