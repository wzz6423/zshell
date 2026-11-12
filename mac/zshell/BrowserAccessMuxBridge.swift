import Darwin
import Foundation

/// One observed pane per browser socket. The reader pauses until xterm has
/// consumed output; the daemon's existing bounded queue disconnects slow peers.
nonisolated final class BrowserAccessMuxBridge: @unchecked Sendable {
    private let io = DispatchQueue(label: "sh.zshell.browser-access.mux")
    private let input = DispatchQueue(label: "sh.zshell.browser-access.mux.input")
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var stopped = false
    private var pendingInputBytes = 0
    private var pendingInputFrames = 0
    private let acknowledged = DispatchSemaphore(value: 0)
    private var outstanding = 0
    private var lastAcknowledgment = Date()
    let sessionID: UUID

    init(sessionID: UUID) { self.sessionID = sessionID }

    /// Attach a connected mux socket that already has `SO_NOSIGPIPE`.
    /// `start` dials the daemon; tests pass a socketpair so `write` can be
    /// observed without the browser server.
    init(sessionID: UUID, descriptor: Int32) {
        self.sessionID = sessionID
        self.descriptor = descriptor
    }

    func start(queue: DispatchQueue,
               frame: @escaping @Sendable (PTYMuxObserverFrame.Kind, Data) -> Void,
               ended: @escaping @Sendable (Bool) -> Void) {
        io.async { [self] in
            var socket: Int32 = -1
            var stalled = false
            defer {
                lock.lock()
                descriptor = -1
                stopped = true
                if socket >= 0 {
                    _ = shutdown(socket, SHUT_RDWR)
                    Darwin.close(socket)
                }
                lock.unlock()
                let wasStalled = stalled
                queue.async { ended(wasStalled) }
            }
            do {
                socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                guard socket >= 0 else { throw PTYMuxWire.errnoError("socket") }
                try PTYMuxWire.configureSocket(socket)
                var address = try PTYMuxWire.address(for: PTYMuxPaths.socketPath)
                let connected = withUnsafePointer(to: &address.0) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, address.1) }
                }
                guard connected == 0 else { throw PTYMuxWire.errnoError("connect") }
                lock.lock()
                let active = !stopped
                if active { descriptor = socket }
                lock.unlock()
                guard active else { return }
                let request = PTYMuxRequest(version: PTYMuxConstants.protocolVersion,
                    id: UUID().uuidString, method: "observe", params: ["id": .string(sessionID.uuidString)])
                try PTYMuxWire.writeFrame(request, to: socket)
                guard try PTYMuxWire.readFrame(PTYMuxResponse.self, from: socket).ok else { return }
                var timeout = timeval(tv_sec: 0, tv_usec: 0)
                _ = setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var buffer = Data()
                var bytes = [UInt8](repeating: 0, count: 32 * 1024)
                while isActive {
                    if let item = try PTYMuxObserverFrame.next(in: buffer) {
                        buffer.removeFirst(item.consumed)
                        if item.kind == .output {
                            while isActive, !reserve(item.data.count) {
                                lock.lock()
                                let timedOut = Date().timeIntervalSince(lastAcknowledgment) > 10
                                lock.unlock()
                                if timedOut { stalled = true; close(); return }
                                _ = acknowledged.wait(timeout: .now() + 0.5)
                            }
                            guard isActive else { return }
                        }
                        queue.async { frame(item.kind, item.data) }
                    } else {
                        let count = Darwin.read(socket, &bytes, bytes.count)
                        if count > 0 {
                            guard buffer.count + count <= 512 * 1024 else { return }
                            buffer.append(contentsOf: bytes.prefix(count))
                        } else if count < 0, errno == EINTR { continue }
                        else { return }
                    }
                }
            } catch { return }
        }
    }

    private var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !stopped
    }

    private func reserve(_ count: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, outstanding + count <= BrowserAccessLimits.outputCredit else { return false }
        if outstanding == 0 { lastAcknowledgment = Date() }
        outstanding += count
        return true
    }

    @discardableResult func acknowledge(_ count: Int) -> Bool {
        lock.lock()
        guard count > 0, count <= outstanding else { lock.unlock(); return false }
        outstanding -= count
        lastAcknowledgment = Date()
        lock.unlock()
        acknowledged.signal()
        return true
    }

    func write(_ data: Data, completed: @escaping @Sendable (Bool) -> Void) -> Bool {
        lock.lock()
        guard !stopped, descriptor >= 0, data.count <= BrowserAccessLimits.frameBytes,
              pendingInputBytes + data.count <= BrowserAccessLimits.sendQueueBytes,
              pendingInputFrames < BrowserAccessLimits.sendQueueBytes / BrowserAccessLimits.frameBytes else {
            lock.unlock()
            return false
        }
        guard !data.isEmpty else { lock.unlock(); completed(true); return true }
        pendingInputBytes += data.count
        pendingInputFrames += 1
        // A stalled PTY must leave browser ACK, detach and revoke on the
        // server queue responsive. Bound queue entries as well as payloads.
        input.async { [self] in
            let written = writeAll(data)
            if !written { close() }
            lock.lock()
            pendingInputBytes -= data.count
            pendingInputFrames -= 1
            lock.unlock()
            completed(written)
        }
        lock.unlock()
        return true
    }

    private func writeAll(_ data: Data) -> Bool {
        // The reader owns the original fd. Duplicate it under the same lock
        // used for closing so a pending send cannot hit a reused fd number.
        lock.lock()
        let fd = !stopped && descriptor >= 0 ? fcntl(descriptor, F_DUPFD_CLOEXEC, 0) : -1
        lock.unlock()
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        // Darwin AF_UNIX send ignores MSG_DONTWAIT and waits out SO_SNDTIMEO.
        // configureSocket leaves that at 2s, so a full 8 KiB buffer stalls the
        // paste and then returns a short count. A 1 ms timeout lets the loop
        // poll for the peer instead of treating that prefix as failure.
        var sendTimeout = timeval(tv_sec: 0, tv_usec: 1_000)
        guard setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            return false
        }

        // One browser paste is a single frame of up to 16 KiB, larger than the
        // Unix stream send buffer. A short send has already entered the PTY;
        // failing that frame disconnects and can run a partial command. Retry
        // until the frame is queued or the socket itself fails. A poll timeout
        // means the peer may still be reading.
        var offset = 0
        return data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return raw.count == 0 }
            while offset < raw.count {
                guard isActive else { return false }

                var ready = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let polled = poll(&ready, 1, 50)
                if polled < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if polled == 0 { continue }
                if ready.revents & Int16(POLLOUT) == 0 { return false }

                let sent = Darwin.send(fd, base.advanced(by: offset), raw.count - offset, MSG_DONTWAIT)
                if sent > 0 {
                    offset += sent
                } else if sent < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    func close() {
        lock.lock()
        stopped = true
        if descriptor >= 0 { _ = shutdown(descriptor, SHUT_RDWR) }
        lock.unlock()
        acknowledged.signal()
    }

    deinit { close() }
}
