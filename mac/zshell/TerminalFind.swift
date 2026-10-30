//
//  TerminalFind.swift
//  zshell
//

import AppKit
import Combine
import Foundation

/// Find-in-terminal state for one session.
///
/// The backend owns the search itself — it scans the screen and scrollback on
/// its own thread, highlights every match in its renderer, and moves the
/// selection as you navigate — so this holds only what the find bar draws and
/// forwards the user's intent as surface find actions. Match counts arrive
/// back asynchronously through `TerminalBackendEvents`.
@MainActor
final class TerminalFind: nonisolated ObservableObject {
    @Published private(set) var isPresented = false

    /// The needle. Every edit restarts the backend's search, so the bar
    /// searches as you type.
    @Published var query = "" {
        didSet {
            guard query != oldValue, !isApplyingReportedNeedle else { return }
            runSearch()
        }
    }

    /// Matches found so far, or nil while a count for the current needle has
    /// not been reported yet.
    @Published private(set) var total: Int?
    /// Zero-based index of the highlighted match, nil when none is.
    @Published private(set) var selected: Int?

    /// Bumped whenever the bar should take (or retake) keyboard focus, so ⌘F
    /// on an already-open bar re-selects the term the way the system find bar
    /// does. A counter rather than a flag: repeated requests must each land.
    @Published private(set) var focusRequest = 0

    /// The session owning this also owns the surface, so an unowned reference
    /// is safe and keeps the session's object graph acyclic.
    private unowned let surface: any TerminalBackendSurface

    /// Set while a needle the backend resolved for us (⌘E's selection) is
    /// being written into `query`, so echoing it back as a fresh search —
    /// which would restart the one already running — is suppressed.
    private var isApplyingReportedNeedle = false

    /// Bumped per search so a deferred reveal belonging to an older needle can
    /// tell it has been superseded. A backend reports each restart as a burst
    /// of counts, several per keystroke.
    private var searchGeneration = 0
    /// Whether the current needle has already jumped to a match.
    private var hasRevealedMatch = false
    private struct LogReveal {
        let generation: Int
        let target: Int
        let total: Int
        let forward: Bool
        let completion: (Bool) -> Void
        var started = false
    }
    private var logReveal: LogReveal?

    init(surface: any TerminalBackendSurface) {
        self.surface = surface
    }

    // MARK: - Find menu

    func perform(_ action: FindAction) {
        switch action {
        case .show: present()
        case .hide: dismiss()
        case .next: navigate(forward: true)
        case .previous: navigate(forward: false)
        case .useSelection: searchSelection()
        // Terminal output is read-only, so Find and Replace stays disabled
        // while a terminal is focused and never arrives here.
        case .replace: break
        }
    }

    // MARK: - Commands

    /// Shows the bar and focuses its field. The needle survives a close, so
    /// reopening offers the previous term again, pre-selected.
    func present() {
        isPresented = true
        focusRequest += 1
        runSearch()
    }

    /// Closes the bar, clears the backend's highlights, and hands typing back
    /// to the terminal.
    func dismiss() {
        guard isPresented else { return }
        finishLogReveal(false)
        isPresented = false
        clearCounts()
        surface.endFind()
    }

    /// Returns first responder to the terminal. Called once the find bar has
    /// actually left the view tree, because claiming it any earlier loses the
    /// race with SwiftUI tearing down the find field: AppKit resigns that
    /// field editor afterwards and the window is left without a first
    /// responder, so the terminal silently stops receiving keystrokes.
    func restoreTerminalFocus() {
        DispatchQueue.main.async { [surface] in
            guard NSApp.isActive,
                  let window = surface.window,
                  window.isKeyWindow,
                  window.firstResponder !== surface
            else { return }
            window.makeFirstResponder(surface)
        }
    }

    func navigate(forward: Bool) {
        guard !query.isEmpty else { return }
        finishLogReveal(false)
        // ⌘G with the bar closed resumes the last search rather than doing
        // nothing, matching how Find Next behaves elsewhere on macOS.
        guard isPresented else {
            present()
            return
        }
        surface.stepFind(forward: forward)
    }

    /// ⌘E. The backend resolves the needle from the grid selection and reports
    /// it back through ``started(needle:)``, so the selection never has to be
    /// read out and re-escaped here.
    func searchSelection() {
        guard surface.hasSelection else { return }
        surface.findSelection()
    }

    // MARK: - Reports from the backend

    func started(needle: String) {
        // Only claim keyboard focus when this actually opens the bar. A
        // backend may report a start for a search already under way, and
        // re-selecting the field mid-edit would eat what the user is typing.
        if !isPresented {
            isPresented = true
            focusRequest += 1
        }
        guard !needle.isEmpty, needle != query else { return }
        isApplyingReportedNeedle = true
        query = needle
        isApplyingReportedNeedle = false
    }

    /// The backend ended the search on its own. Mirror it without sending
    /// an end straight back at it.
    func ended() {
        if logReveal != nil { return }
        isPresented = false
        clearCounts()
    }

    func update(total: Int?) {
        self.total = total
        if let reveal = logReveal {
            if reveal.started, total != reveal.total { finishLogReveal(false); return }
            guard !reveal.started, total == reveal.total else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, var pending = self.logReveal,
                      pending.generation == reveal.generation, !pending.started,
                      self.total == pending.total else { return }
                pending.started = true
                self.logReveal = pending
                self.surface.stepFind(forward: pending.forward)
            }
            return
        }
        revealFirstMatchIfNeeded()
    }

    func update(selected: Int?) {
        self.selected = selected
        guard let reveal = logReveal, reveal.started, let selected else { return }
        if selected == reveal.target {
            finishLogReveal(true)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.logReveal?.generation == reveal.generation else { return }
                self.surface.stepFind(forward: reveal.forward)
            }
        }
    }

    /// The snapshot is checked by the workspace controller before this runs.
    /// Ghostty reports its matches asynchronously and numbers newest first.
    func revealLogMatch(needle: String, occurrence: Int, total: Int, completion: @escaping (Bool) -> Void) {
        finishLogReveal(false)
        guard occurrence >= 0, occurrence < total else { completion(false); return }
        if let result = surface.revealLogMatch(needle: needle, occurrence: occurrence, total: total) {
            completion(result)
            return
        }
        isPresented = true
        let target = surface.findMatchesNewestFirst ? total - occurrence - 1 : occurrence
        let forward = target <= total / 2
        searchGeneration += 1
        let generation = searchGeneration
        logReveal = LogReveal(generation: generation, target: target, total: total,
                              forward: forward, completion: completion)
        isApplyingReportedNeedle = true
        query = needle
        isApplyingReportedNeedle = false
        hasRevealedMatch = true
        clearCounts()
        surface.endFind()
        surface.beginFind(needle)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard self?.logReveal?.generation == generation else { return }
            self?.finishLogReveal(false)
        }
    }

    private func finishLogReveal(_ succeeded: Bool) {
        let completion = logReveal?.completion
        logReveal = nil
        completion?(succeeded)
    }

    func cancelLogReveal() { finishLogReveal(false) }

    /// A backend tallies matches but selects none until asked, so the first
    /// non-empty result for a needle jumps to one — typing in the find bar is
    /// meant to reveal the hit, not merely count it. Deferred so it never
    /// re-enters the backend from inside its own action callback, and dropped
    /// when the needle has moved on by the time it runs.
    private func revealFirstMatchIfNeeded() {
        guard !hasRevealedMatch, let total, total > 0 else { return }
        hasRevealedMatch = true
        let generation = searchGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, isPresented, searchGeneration == generation else { return }
            surface.stepFind(forward: true)
        }
    }

    // MARK: - Search

    /// Restarts the backend's search for the current needle. Counts are
    /// dropped first so the bar never shows a tally belonging to the previous
    /// term.
    private func runSearch() {
        guard isPresented else { return }
        finishLogReveal(false)
        searchGeneration += 1
        hasRevealedMatch = false
        clearCounts()
        surface.beginFind(query)
    }

    private func clearCounts() {
        total = nil
        selected = nil
    }
}
