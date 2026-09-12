//
//  TerminalPromptQueue.swift
//  zshell
//

import Combine
import Foundation

/// One terminal session's typed-ahead prompts: an in-memory FIFO the user
/// fills from the pane-bottom bar while the session is busy — typically while
/// a coding agent owns the terminal — and that drains to the shell as each
/// prompt comes free.
///
/// Deliberately not persisted and not shared between sessions. The queue
/// holds commands aimed at *this* shell's very next prompt, so carrying it
/// across a restart — where the shell, its directory, and any running job are
/// gone — would replay stale intent into a different context, and closing the
/// session discards it for the same reason.
@MainActor
final class TerminalPromptQueue: nonisolated ObservableObject {
    @Published private(set) var commands: [String] = []
    @Published private(set) var isPresented = false

    // MARK: - Presentation

    func present() {
        isPresented = true
    }

    /// Closes the bar. The queue itself is kept: Esc hides the UI, not the
    /// user's typed-ahead work.
    func dismiss() {
        isPresented = false
    }

    func togglePresentation() {
        isPresented.toggle()
    }

    // MARK: - Items

    /// Flattens to the single line this queue composes and sends. The bar is
    /// one input field (no multi-line composer), and a newline-free fill
    /// keeps the send path to plain text plus one Return, so nothing in the
    /// queue can execute halfway through.
    func enqueue(_ command: String) {
        let flattened = command
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !flattened.isEmpty else { return }
        commands.append(flattened)
    }

    func remove(at index: Int) {
        guard commands.indices.contains(index) else { return }
        commands.remove(at: index)
    }
}

// MARK: - Auto-dispatch

/// Dispatch lives on `TerminalSession` because it walks the same
/// `sendCommand` → `surface.sendText` boundary as every other command send.
extension TerminalSession {
    /// The shell needs a few ticks after a prompt event before the zsh shim
    /// reports ZLE readiness, so the gate is polled briefly instead of being
    /// trusted at the instant of the event; a later prompt event restarts the
    /// window by rescheduling.
    private static let promptQueueSettleDelay: Duration = .milliseconds(150)
    private static let promptQueueRetryDelay: Duration = .milliseconds(250)
    private static let promptQueueDispatchAttempts = 8

    /// Called from ``terminalDidReportShellIntegration(_:)`` for both
    /// `.promptStart` and `.commandFinished` — whichever the active backend
    /// actually reports. libghostty surfaces only completed commands (there
    /// is no prompt-start callback), while the Alacritty bridge extracts all
    /// OSC 133 markers but Zshell's own zsh shim emits only the prompt-start
    /// half. Subscribing to both covers the two backends; a session whose
    /// shell reports neither simply leaves the queue to manual sends.
    func promptQueueDidObservePromptReturn() {
        guard !promptQueue.commands.isEmpty else { return }
        schedulePromptQueueDispatch()
    }

    /// Schedules one dispatch window. Re-checks the readiness gate on every
    /// attempt: while a foreground job — an agent, a build, anything — owns
    /// the pane, the gate stays false and nothing is sent.
    func schedulePromptQueueDispatch() {
        guard !hasExited, !promptQueue.commands.isEmpty else { return }
        promptQueueDispatchTask?.cancel()
        promptQueueDispatchTask = Task { [weak self] in
            for attempt in 0..<TerminalSession.promptQueueDispatchAttempts {
                try? await Task.sleep(for: attempt == 0
                    ? TerminalSession.promptQueueSettleDelay
                    : TerminalSession.promptQueueRetryDelay)
                guard let self, !self.hasExited, !Task.isCancelled else { return }
                if self.sendPromptQueueHeadIfShellIsReady() { break }
            }
            self?.promptQueueDispatchTask = nil
        }
    }

    /// Manual sends take over from any pending auto-dispatch, which would
    /// otherwise fire into the same shell right behind the explicit one.
    func cancelPromptQueueDispatch() {
        promptQueueDispatchTask?.cancel()
        promptQueueDispatchTask = nil
    }

    /// Sends the queue's head when the pane's own zsh is provably back at a
    /// fresh prompt. Returns whether the head was sent.
    private func sendPromptQueueHeadIfShellIsReady() -> Bool {
        guard !promptQueue.commands.isEmpty,
              terminalPromptSelectionIsReady
        else { return false }
        // The gate above already proves the root shell is the foreground
        // process — nothing else can be interrupted by this send — and that
        // ZLE just initialized a line the user has not typed into yet, so
        // the fill lands on an empty command line.
        guard let head = promptQueue.commands.first else { return false }
        promptQueue.remove(at: 0)
        sendQueuedPrompt(head)
        return true
    }

    /// The single send path for queued prompts: fill the prompt without a
    /// trailing newline, then send Return separately — the same `sendCommand`
    /// → `surface.sendText` discipline as the quick-command menus and the
    /// automation router. No backend is ever addressed privately.
    func sendQueuedPrompt(_ command: String) {
        sendCommand(command)
        sendCommand("\r")
    }
}
