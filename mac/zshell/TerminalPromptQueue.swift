//
//  TerminalPromptQueue.swift
//  zshell
//

import Combine
import Foundation

/// One terminal session's typed-ahead prompts: an in-memory FIFO the user
/// fills from the pane-bottom bar while the session is busy. Sending is manual
/// unless the user enables automatic dispatch in terminal settings.
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
    private(set) var isEnabled = AppSettings.shared.promptQueueEnabled
    private var settingsObservation: AnyCancellable?

    init() {
        settingsObservation = AppSettings.shared.$promptQueueEnabled.removeDuplicates()
            .sink { [weak self] enabled in
                self?.isEnabled = enabled
                if !enabled { self?.dismiss() }
            }
    }

    // MARK: - Presentation

    func present() {
        guard isEnabled else { return }
        isPresented = true
    }

    /// Closes the bar. The queue itself is kept: Esc hides the UI, not the
    /// user's typed-ahead work.
    func dismiss() {
        isPresented = false
    }

    func togglePresentation() {
        if isPresented { dismiss() }
        else { present() }
    }

    // MARK: - Items

    /// Flattens to the single line this queue composes and sends. The bar is
    /// one input field (no multi-line composer), and a newline-free fill
    /// keeps the send path to plain text plus one Return, so nothing in the
    /// queue can execute halfway through.
    func enqueue(_ command: String) {
        guard isEnabled else { return }
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
    /// OSC 133 markers. Both paths still require the original zsh's empty
    /// prompt acknowledgement before dispatching.
    func promptQueueDidObservePromptReturn() {
        schedulePromptQueueDispatch()
    }

    /// Schedules one dispatch window. Re-checks the readiness gate on every
    /// attempt: while a foreground job — an agent, a build, anything — owns
    /// the pane, the gate stays false and nothing is sent.
    func schedulePromptQueueDispatch() {
        cancelPromptQueueDispatch()
        guard AppSettings.shared.promptQueueEnabled,
              promptQueue.isEnabled,
              AppSettings.shared.promptQueueAutoDispatch,
              !hasExited, !promptQueue.commands.isEmpty else { return }
        let generation = promptQueueDispatchGeneration
        promptQueueDispatchTask = Task { [weak self] in
            defer {
                if let self, self.promptQueueDispatchGeneration == generation {
                    self.promptQueueDispatchTask = nil
                }
            }
            for attempt in 0..<TerminalSession.promptQueueDispatchAttempts {
                do {
                    try await Task.sleep(for: attempt == 0
                        ? TerminalSession.promptQueueSettleDelay
                        : TerminalSession.promptQueueRetryDelay)
                } catch { return }
                guard let self, !Task.isCancelled,
                      self.promptQueueDispatchGeneration == generation,
                      AppSettings.shared.promptQueueEnabled,
                      AppSettings.shared.promptQueueAutoDispatch else { return }
                if self.dispatchQueuedPrompt(at: 0) { break }
            }
        }
    }

    /// Manual sends take over from any pending auto-dispatch, which would
    /// otherwise fire into the same shell right behind the explicit one.
    func cancelPromptQueueDispatch() {
        promptQueueDispatchGeneration &+= 1
        promptQueueDispatchTask?.cancel()
        promptQueueDispatchTask = nil
    }

    var canSendQueuedPrompt: Bool {
        guard AppSettings.shared.promptQueueEnabled,
              promptQueue.isEnabled,
              !hasExited,
              let shellPID = shellPid, shellPID > 0,
              surface.foregroundPid == shellPID,
              !TerminalCommandTaskStore.shared.hasActiveTask(terminalID: id),
              terminalPromptQueueIsReady
        else { return false }
        if let sent = promptQueueSentToken {
            guard promptQueueCompletedToken == sent else { return false }
            promptQueueSentToken = nil
        }
        return true
    }

    /// Explicit sends cancel pending automatic work and retain the entry if
    /// the original shell is busy, has a draft, or no longer owns this pane.
    @discardableResult
    func sendQueuedPrompt(at index: Int) -> Bool {
        cancelPromptQueueDispatch()
        return dispatchQueuedPrompt(at: index)
    }

    private func dispatchQueuedPrompt(at index: Int) -> Bool {
        guard canSendQueuedPrompt, promptQueue.commands.indices.contains(index) else { return false }
        if let context = ZshellAutomationRouter.context(forSession: id) {
            guard context.session === self, belongs(to: context.manager) else { return false }
        } else if hostManagerID != nil { return false }
        let command = promptQueue.commands[index]
        guard reservePromptQueueSend(for: command) else { return false }
        promptQueue.remove(at: index)
        sendCommand(command)
        surface.sendPromptQueueEnter()
        return true
    }
}
