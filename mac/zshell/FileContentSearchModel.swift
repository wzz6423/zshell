//
//  FileContentSearchModel.swift
//  zshell
//

import AppKit
import Combine
import Foundation

/// File-content search over the Files panel's project directory: BSD grep
/// (`/usr/bin/grep -r -n -I -F`) streamed through `Process` + `Pipe`, so
/// results appear on a ~200 ms cadence instead of after the whole tree is
/// scanned. One search runs at a time; reaching the match cap terminates
/// grep, and re-rooting the panel cancels it.
@MainActor
final class FileContentSearchModel: ObservableObject {

    /// One matched line: the path relative to the search root, its 1-based
    /// line number, and the matched line content (length-capped for display).
    nonisolated struct Match: Identifiable, Equatable, Sendable {
        let id: Int
        let path: String
        let line: Int
        let content: String
    }

    /// Directories grep never descends into — build, dependency, and tooling
    /// artifacts that dominate large trees. One `--exclude-dir` per entry.
    static let excludedDirectories: [String] = [
        ".git", "node_modules", ".build", "dist", "target", "vendor",
        "DerivedData", "Pods", ".venv", "__pycache__", ".cache",
    ]
    /// Hard cap on collected matches; grep is terminated once it is reached.
    static let maxMatches = 2000
    /// Cadence between UI flushes of streamed matches.
    private static let flushInterval: TimeInterval = 0.2
    /// Line content is capped in characters for display (bytes are capped
    /// while parsing, so multi-megabyte minified lines stay bounded).
    private static let maxContentLength = 240
    /// Files the editor refuses to open (see `FileTab`) have no line to
    /// reveal, so mapping a grep line to a caret offset skips them.
    private nonisolated static let maxRevealFileBytes = 5 << 20

    /// Root the search is anchored to — the Files panel's project directory.
    @Published private(set) var rootPath = ""
    /// The query survives deactivating the search row and re-rooting; only
    /// running a new search replaces the results.
    @Published var query = ""
    /// Off by default, mapping to grep's `-i`.
    @Published var isCaseSensitive = false
    @Published private(set) var isActive = false
    /// One-shot focus request, set by `activate()` and consumed by the
    /// mounting search panel — so returning to the Files tab while a search
    /// is showing does not steal focus from wherever the user works.
    private(set) var needsFocus = false

    /// Hands the one-shot focus request to the mounting search panel and
    /// consumes it.
    func consumeFocusRequest() -> Bool {
        defer { needsFocus = false }
        return needsFocus
    }
    @Published private(set) var isRunning = false
    /// Set when grep was terminated because it reached the match cap.
    @Published private(set) var isTruncated = false
    /// Set when the user stopped a still-running search.
    @Published private(set) var wasStopped = false
    @Published private(set) var matches: [Match] = []
    /// Why grep could not run, or its first stderr line when it failed
    /// without producing matches. Verbatim process output, not localized.
    @Published private(set) var failureMessage: String?

    /// The running grep and its output buffer. Main-actor only: spawn,
    /// terminate, and flush all happen here; the pipe handlers only feed the
    /// lock-guarded buffer and request main-actor work.
    private var process: Process?
    private var buffer: MatchBuffer?
    private var flushScheduled = false
    /// Guard against a replaced search's late termination handler touching
    /// the state of the run that replaced it.
    private var runID = 0

    // MARK: - Visibility

    /// Shows the search row in place of the file tree.
    func activate() {
        isActive = true
        needsFocus = true
    }

    /// Hides the search row (restoring the tree) and stops a running search.
    func deactivate() {
        isActive = false
        needsFocus = false
        stop()
    }

    func toggle() {
        if isActive { deactivate() } else { activate() }
    }

    // MARK: - Search

    /// Re-anchors the search to the Files panel's root. A root change — a
    /// project switch, or the panels following the terminal elsewhere —
    /// cancels a running grep and drops the results, which belong to the
    /// root they ran in. The query and case-sensitivity survive.
    func sync(root: String) {
        guard root != rootPath else { return }
        rootPath = root
        cancelAndClear()
    }

    /// Runs the current query against the current root. No-op while the
    /// query is empty — an empty pattern would match every line of every
    /// file.
    func run() {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !rootPath.isEmpty
        else { return }
        stopProcess()
        startProcess(pattern: query, root: rootPath)
    }

    /// Stops a running search, keeping whatever matches already arrived.
    func stop() {
        guard isRunning else { return }
        wasStopped = true
        stopProcess()
    }

    /// Replaces the in-flight search and its results with a clean slate.
    private func cancelAndClear() {
        // Orphan the in-flight termination handling: a cancelled search owns
        // no state afterwards, so grep's late SIGTERM exit must neither land
        // in the fresh state nor surface as a failure.
        runID += 1
        stopProcess()
        buffer = nil
        isRunning = false
        matches = []
        isTruncated = false
        wasStopped = false
        failureMessage = nil
    }

    // MARK: - grep process

    private func startProcess(pattern: String, root: String) {
        matches = []
        isTruncated = false
        wasStopped = false
        failureMessage = nil
        runID += 1
        let runID = self.runID
        isRunning = true

        let buffer = MatchBuffer(
            root: root,
            maxMatches: Self.maxMatches,
            maxContentLength: Self.maxContentLength
        )
        self.buffer = buffer

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        // -F keeps the query literal; -I skips binary files, which the
        // editor could not show a hit in anyway.
        var arguments = ["-r", "-n", "-I", "-F", "-H", "--null"]
        if !isCaseSensitive { arguments.append("-i") }
        for directory in Self.excludedDirectories {
            arguments.append("--exclude-dir=\(directory)")
        }
        // -e keeps a query that starts with "-" a pattern, not an option.
        arguments += ["-e", pattern, root]
        process.arguments = arguments

        let stdout = Pipe()
        process.standardOutput = stdout
        let stderr = Pipe()
        process.standardError = stderr
        let readers = DispatchGroup()
        readers.enter()
        readers.enter()
        process.terminationHandler = { [weak self] process in
            let terminationStatus = process.terminationStatus
            // Process exit can arrive before the pipes deliver their last chunk.
            readers.notify(queue: .main) { [weak self] in
                guard let model = self else { return }
                assumeMainActor {
                    model.processDidTerminate(exitStatus: terminationStatus, ofRun: runID)
                }
            }
        }

        do {
            try process.run()
        } catch {
            isRunning = false
            self.buffer = nil
            failureMessage = String(localized: "Search failed")
            return
        }
        self.process = process

        let stdoutReader = Thread { [weak self] in
            defer { readers.leave() }
            let handle = stdout.fileHandleForReading
            while let chunk = try? handle.read(upToCount: 16_384), !chunk.isEmpty {
                buffer.ingest(chunk)
                self?.requestFlush(ofRun: runID)
                if buffer.hasReachedLimit() {
                    self?.stopAtLimitFromHandler(ofRun: runID)
                }
            }
        }
        stdoutReader.qualityOfService = .userInitiated
        stdoutReader.start()
        // Drained so a chatty grep (unreadable paths, and so on) cannot fill
        // the pipe and stall; kept only to explain a failed search.
        let stderrReader = Thread {
            defer { readers.leave() }
            let handle = stderr.fileHandleForReading
            while let chunk = try? handle.read(upToCount: 8_192), !chunk.isEmpty {
                buffer.appendError(chunk)
            }
        }
        stderrReader.qualityOfService = .utility
        stderrReader.start()
    }

    /// Terminates the running grep, if any. Its termination handler still
    /// fires and performs the final flush under its run ID.
    private func stopProcess() {
        guard let process else { return }
        self.process = nil
        if process.isRunning {
            process.terminate()
        }
    }

    private func processDidTerminate(exitStatus: Int32, ofRun runID: Int) {
        guard runID == self.runID else { return }
        isRunning = false
        process = nil
        buffer?.ingestFragmentEnd()
        flushPending()
        // grep exits 2 on errors (exit 1 is just "no matches"); a SIGTERM
        // from stop() or the match cap also reports > 1, so only an error
        // that ends a search with no results surfaces as a failure.
        if exitStatus > 1, !isTruncated, !wasStopped, matches.isEmpty {
            let detail = (buffer?.errorText ?? "").split(separator: "\n").first
            failureMessage = detail.map(String.init)
                ?? String(localized: "Search failed")
        }
        buffer = nil
    }

    // MARK: - Throttled flush

    /// Called from grep's stdout handler; coalesces into ~200 ms main-actor
    /// batches so a fast stream never floods the UI.
    private nonisolated func requestFlush(ofRun runID: Int) {
        DispatchQueue.main.async {
            assumeMainActor {
                guard runID == self.runID else { return }
                self.scheduleFlush()
            }
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flushInterval) {
            assumeMainActor { self.flushPending() }
        }
    }

    /// Moves buffered matches into the published list, respecting the cap,
    /// and terminates grep when it has produced more than the cap.
    private func flushPending() {
        flushScheduled = false
        guard let buffer else { return }
        let room = Self.maxMatches - matches.count
        guard room > 0 else {
            finishAtLimit()
            return
        }
        let taken = buffer.takePending(max: room)
        if !taken.isEmpty {
            matches.append(contentsOf: taken)
        }
        if buffer.hasReachedLimit() {
            finishAtLimit()
        }
    }

    /// Marks results truncated, delivers whatever fits under the cap, and
    /// stops grep — the search is over once the cap is reached.
    private func finishAtLimit() {
        guard !isTruncated else { return }
        isTruncated = true
        flushPending()
        stopProcess()
    }

    /// Called from grep's stdout handler once the buffer reports the cap.
    private nonisolated func stopAtLimitFromHandler(ofRun runID: Int) {
        DispatchQueue.main.async {
            assumeMainActor {
                guard runID == self.runID else { return }
                self.finishAtLimit()
            }
        }
    }

    // MARK: - Revealing a hit

    /// UTF-16 offset of the start of `line` (1-based) in the file at `path`,
    /// in the same string the editor displays, so a search hit's caret lands
    /// exactly on its matched line. The read and scan run off the main
    /// thread; nil means the line cannot be mapped (unreadable, non-UTF-8,
    /// or past the size the editor opens).
    nonisolated static func lineStartLocation(
        line: Int, filePath: String
    ) async -> Int? {
        await Task.detached(priority: .userInitiated) {
            Self.revealLocation(line: line, filePath: filePath)
        }.value
    }

    private nonisolated static func revealLocation(line: Int, filePath: String) -> Int? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              data.count <= maxRevealFileBytes,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return lineStartLocation(ofLine: line, in: text)
    }

    private nonisolated static func lineStartLocation(ofLine line: Int, in text: String) -> Int? {
        guard line >= 1 else { return nil }
        var offset = 0
        var currentLine = 1
        for scalar in text.unicodeScalars {
            if currentLine == line { return offset }
            offset += scalar.value > 0xFFFF ? 2 : 1
            if scalar == "\n" { currentLine += 1 }
        }
        return currentLine == line ? offset : nil
    }
}

/// Accumulates grep's output between throttled UI flushes. All state is
/// lock-guarded: it is written from grep's pipe handler queues and read on
/// the main actor.
private nonisolated final class MatchBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var fragment: [UInt8] = []
    private var hasPathSeparator = false
    private var pending: [FileContentSearchModel.Match] = []
    private var deliveredCount = 0
    private var nextID = 0
    private var errorData = Data()
    private var reachedLimit = false

    /// Long lines are capped while parsing so a multi-megabyte minified line
    /// cannot grow the buffer; the path and line number sit at the front.
    private nonisolated static let maxLineBytes = 65536
    private nonisolated static let maxErrorBytes = 4096

    /// Root matches are reported relative to; fixed per run, because a root
    /// change cancels the run.
    private let root: String
    private let maxMatches: Int
    private let maxContentLength: Int

    init(root: String, maxMatches: Int, maxContentLength: Int) {
        self.root = root
        self.maxMatches = maxMatches
        self.maxContentLength = maxContentLength
    }

    func hasReachedLimit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return reachedLimit
    }

    /// Parses one stdout chunk into complete matches. A trailing partial
    /// line is held back until `ingestFragmentEnd()`. Called from grep's
    /// stdout handler queue.
    func ingest(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        for byte in chunk {
            if byte == 0x0A, hasPathSeparator {
                appendLine(fragment)
                fragment.removeAll(keepingCapacity: true)
                hasPathSeparator = false
            } else if fragment.count < Self.maxLineBytes {
                // The path and line number sit at the front of the line, so
                // dropping the tail of an oversized line still yields a
                // usable (byte-capped) content preview.
                fragment.append(byte)
                if byte == 0 { hasPathSeparator = true }
            }
        }
        if !reachedLimit, deliveredCount + pending.count >= maxMatches {
            reachedLimit = true
        }
    }

    /// Emits the final line when grep's output ended without a newline.
    func ingestFragmentEnd() {
        lock.lock()
        defer { lock.unlock() }
        guard !fragment.isEmpty else { return }
        appendLine(fragment)
        fragment.removeAll(keepingCapacity: true)
        hasPathSeparator = false
    }

    /// Moves up to `max` buffered matches out, in order. Called on the main
    /// actor during throttled flushes.
    func takePending(max: Int) -> [FileContentSearchModel.Match] {
        lock.lock()
        defer { lock.unlock() }
        let taken = Array(pending.prefix(max))
        pending.removeFirst(taken.count)
        deliveredCount += taken.count
        if deliveredCount >= maxMatches {
            reachedLimit = true
        }
        return taken
    }

    func appendError(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard errorData.count < Self.maxErrorBytes else { return }
        errorData.append(chunk)
        if errorData.count > Self.maxErrorBytes {
            // Re-based so later appends do not inherit slice indices.
            errorData = Data(errorData.prefix(Self.maxErrorBytes))
        }
    }

    var errorText: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: errorData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `--null` keeps colons and newlines in file names distinct from the
    /// line number and content delimiters.
    private func appendLine(_ bytes: [UInt8]) {
        guard !reachedLimit else { return }
        guard let separator = bytes.firstIndex(of: 0),
              let colon = bytes[(separator + 1)...].firstIndex(of: 0x3A),
              let lineNumber = Int(String(decoding: bytes[(separator + 1)..<colon], as: UTF8.self))
        else { return }

        // grep receives an absolute root, so paths come back absolute; the
        // UI shows them relative to the root the search was anchored to.
        var path = String(decoding: bytes[..<separator], as: UTF8.self)
        if path.hasPrefix(root) {
            path.removeFirst(root.count)
            if path.hasPrefix("/") {
                path.removeFirst()
            }
        }

        var content = String(decoding: bytes[(colon + 1)...], as: UTF8.self)
        if content.count > maxContentLength {
            content = String(content.prefix(maxContentLength))
        }

        pending.append(
            FileContentSearchModel.Match(
                id: nextID, path: path, line: lineNumber, content: content
            )
        )
        nextID += 1
    }
}
