import Darwin
import Foundation

final class PTYMuxAttachment {
    let descriptor: Int32
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "sh.zshell.pty-mux.attachment")
    private var pendingBytes = 0
    private var pendingLiveBytes = 0
    private var closed = false

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func send(_ data: Data, snapshot: Bool = false) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        guard pendingBytes + data.count <= PTYMuxConstants.maximumSnapshotBytes + PTYMuxConstants.maximumBacklogBytes,
              snapshot || pendingLiveBytes + data.count <= PTYMuxConstants.maximumBacklogBytes else {
            lock.unlock()
            disconnect()
            return
        }
        pendingBytes += data.count
        if !snapshot { pendingLiveBytes += data.count }
        lock.unlock()
        writer.async { [self] in
            lock.lock()
            let canWrite = !closed
            lock.unlock()
            if canWrite {
                do { try PTYMuxWire.writeAll(data, to: descriptor) }
                catch { disconnect() }
            }
            lock.lock()
            pendingBytes -= data.count
            if !snapshot { pendingLiveBytes -= data.count }
            lock.unlock()
        }
    }

    func disconnect() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        _ = shutdown(descriptor, SHUT_RDWR)
    }

    func closeAfterDraining() {
        writer.async { [self] in disconnect() }
    }

    /// The daemon worker is the single close owner. Finish queued writes first
    /// so no task can write to an unrelated descriptor that reused this number.
    func finish() {
        disconnect()
        writer.sync {}
    }
}

final class PTYMuxSession: @unchecked Sendable {
    let id: String
    let pid: pid_t
    let startedAt = Date()
    let workingDirectory: String
    let command: [String]
    let bindingToken: String
    let launchDirectoryURL: URL?

    private let master: Int32
    private let state: PersistentTerminalState
    private let io: DispatchQueue
    private var attachment: PTYMuxAttachment?
    private var processExited = false
    private var waitStatus: Int32?
    private var masterClosed = false
    private var totalBytes: UInt64 = 0
    private var tail = Data()
    private var input = Data()
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var reapSource: DispatchSourceProcess?

    init(
        id: String, pid: pid_t, master: Int32, workingDirectory: String,
        command: [String], bindingToken: String, launchDirectoryURL: URL?,
        state: PersistentTerminalState
    ) {
        self.id = id
        self.pid = pid
        self.master = master
        self.workingDirectory = workingDirectory
        self.command = command
        self.bindingToken = bindingToken
        self.launchDirectoryURL = launchDirectoryURL
        self.state = state
        io = DispatchQueue(label: "sh.zshell.pty-mux.session.\(id)")
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: io)
        source.setEventHandler { [weak self] in self?.drainOutput() }
        readSource = source
        source.resume()
        let reap = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: io)
        reap.setEventHandler { [weak self] in self?.reap() }
        reapSource = reap
        reap.resume()
    }

    var isRunning: Bool { io.sync { !processExited } }

    func attach(_ client: PTYMuxAttachment, reply: () throws -> Void) throws {
        try io.sync {
            guard !processExited else { throw PTYMuxError.message("PTY session has exited.") }
            guard attachment == nil else {
                throw PTYMuxError.message("PTY session is already attached to another terminal.")
            }
            let snapshot = try state.snapshot()
            try reply()
            attachment = client
            client.send(snapshot, snapshot: true)
        }
    }

    func detach(_ client: PTYMuxAttachment) {
        io.sync {
            guard attachment === client else { return }
            attachment = nil
        }
    }

    func write(_ bytes: Data, from client: PTYMuxAttachment) {
        io.sync {
            guard attachment === client, !processExited else { return }
            enqueueInput(bytes)
        }
    }

    func resize(columns: UInt16, rows: UInt16, cellWidth: UInt16, cellHeight: UInt16) {
        io.sync {
            guard !masterClosed else { return }
            var size = winsize(
                ws_row: rows, ws_col: columns,
                ws_xpixel: UInt16(clamping: Int(columns) * Int(cellWidth)),
                ws_ypixel: UInt16(clamping: Int(rows) * Int(cellHeight))
            )
            _ = ioctl(master, TIOCSWINSZ, &size)
            state.resize(columns: columns, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight)
        }
    }

    func setTheme(_ theme: ZshellTheme) { io.sync { state.setTheme(theme) } }

    func snapshot(tailBytes: Int) -> ZshellJSONValue {
        io.sync {
            let foreground = masterClosed ? 0 : tcgetpgrp(master)
            return .object([
                "id": .string(id),
                "pid": .number(Double(pid)),
                "foregroundPid": .number(Double(foreground > 0 ? foreground : pid)),
                "running": .bool(!processExited),
                "waitStatus": waitStatus.map { .number(Double($0)) } ?? .null,
                "startedAt": .number(startedAt.timeIntervalSince1970),
                "workingDirectory": .string(processWorkingDirectory(pid: pid) ?? workingDirectory),
                "command": .array(command.map(ZshellJSONValue.string)),
                "bindingToken": .string(bindingToken),
                "launchDirectory": launchDirectoryURL.map { .string($0.path) } ?? .null,
                "totalOutputBytes": .number(Double(totalBytes)),
                "tailBase64": .string(Data(tail.suffix(tailBytes)).base64EncodedString()),
            ])
        }
    }

    func terminate() {
        io.async { [self] in
            guard !processExited else { return }
            // Job control creates a new process group for agents and servers.
            // Signal every group in this PTY session, including background jobs.
            let processes = Self.sessionProcesses(root: pid)
            signal(processes, SIGHUP)
            io.asyncAfter(deadline: .now() + .milliseconds(250)) { [self] in
                signal(processes + Self.sessionProcesses(root: pid), SIGKILL)
                cleanupFiles()
            }
        }
    }

    private func signal(_ processes: [pid_t], _ signal: Int32) {
        var groups = Set<pid_t>()
        for process in Set(processes) where process > 1 && process != getpid() {
            let group = getpgid(process)
            if group > 1 && group != getpgrp() { groups.insert(group) }
        }
        for group in groups { _ = Darwin.kill(-group, signal) }
        for process in Set(processes) where process > 1 && process != getpid() {
            _ = Darwin.kill(process, signal)
        }
    }

    private static func sessionProcesses(root: pid_t) -> [pid_t] {
        let bytes = proc_listallpids(nil, 0)
        guard bytes > 0 else { return [root] }
        var pids = [pid_t](repeating: 0, count: Int(bytes) + 32)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [root] }
        return pids.prefix(Int(count)).filter { $0 > 1 && getsid($0) == root }
    }

    private func drainOutput() {
        guard !masterClosed else { return }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        // Yield to attach/input work even when a program writes continuously.
        for _ in 0..<64 {
            let count = Darwin.read(master, &buffer, buffer.count)
            if count > 0 {
                let bytes = Data(buffer.prefix(count))
                totalBytes &+= UInt64(count)
                tail.append(bytes)
                if tail.count > PTYMuxConstants.maximumTailBytes {
                    tail.removeFirst(tail.count - PTYMuxConstants.maximumTailBytes)
                }
                let replies = state.feed(bytes, answerQueries: attachment == nil)
                if !replies.isEmpty { enqueueInput(replies) }
                attachment?.send(bytes)
            } else if count < 0 && errno == EINTR {
                continue
            } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                return
            } else {
                closeMaster()
                attachment?.closeAfterDraining()
                return
            }
        }
    }

    private func enqueueInput(_ bytes: Data) {
        guard !masterClosed, input.count + bytes.count <= PTYMuxConstants.maximumInputBytes else {
            attachment?.disconnect()
            return
        }
        input.append(bytes)
        flushInput()
    }

    private func flushInput() {
        while !input.isEmpty && !masterClosed {
            let count = input.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
            if count > 0 { input.removeFirst(count) }
            else if count < 0 && errno == EINTR { continue }
            else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                if writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: master, queue: io)
                    source.setEventHandler { [weak self] in self?.flushInput() }
                    writeSource = source
                    source.resume()
                }
                return
            } else { input.removeAll(); break }
        }
        writeSource?.cancel()
        writeSource = nil
    }

    private func reap() {
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &status, 0) } while result < 0 && errno == EINTR
        processExited = true
        waitStatus = result == pid ? status : nil
        reapSource?.cancel()
        reapSource = nil
        drainOutput()
        closeMaster()
        attachment?.closeAfterDraining()
        cleanupFiles()
    }

    private func closeMaster() {
        guard !masterClosed else { return }
        masterClosed = true
        readSource?.cancel()
        readSource = nil
        writeSource?.cancel()
        writeSource = nil
        Darwin.close(master)
    }

    private func cleanupFiles() {
        if let launchDirectoryURL { try? FileManager.default.removeItem(at: launchDirectoryURL) }
        if let id = UUID(uuidString: id) { PersistentCLIConnection.remove(for: id) }
    }
}
