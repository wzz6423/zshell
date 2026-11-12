"""Keep browser input complete, ordered, bounded, and off the server queue.

Compiles the production mux bridge, observer, authorization and browser server.
Socket fixtures control partial sends, input backpressure and reader EOF; the
real WebSocket path verifies ACK, select, revoke and stop behind stalled input.
The fd probe pauses only poll readiness to force descriptor reuse before send.
All compilers, binaries, sockets and authorization state live in /tmp.
"""

import json
import os
import queue
from pathlib import Path
import platform
import select
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

sys.dont_write_bytecode = True
from test_browser_access import WebSocket


ROOT = Path(__file__).resolve().parents[2]
FRAME_BYTES = 16 * 1024
SEND_BUFFER = 8192

SUPPORT = r"""
import Darwin
import Foundation

nonisolated enum BrowserAccessLimits {
    static let frameBytes = 16 * 1024
    static let outputCredit = 256 * 1024
    static let sendQueueBytes = 1024 * 1024
}

nonisolated enum PTYMuxConstants {
    static let protocolVersion = 2
}

nonisolated enum StubJSON {
    case string(String)
}

nonisolated struct PTYMuxRequest {
    var version: Int
    var id: String
    var method: String
    var params: [String: StubJSON]
}

nonisolated struct PTYMuxResponse {
    var ok: Bool
}

nonisolated enum PTYMuxPaths {
    static var socketPath: String { "/tmp/zshell-browser-access-write-unused" }
}

nonisolated enum PTYMuxError: Error {
    case message(String)
}

nonisolated enum PTYMuxWire {
    static func errnoError(_ operation: String) -> PTYMuxError { .message(operation) }
    static func configureSocket(_ descriptor: Int32) throws {}
    static func address(for path: String) throws -> (sockaddr_un, socklen_t) { (sockaddr_un(), 0) }
    static func writeFrame(_ value: PTYMuxRequest, to descriptor: Int32) throws {}
    static func readFrame(_ type: PTYMuxResponse.Type, from descriptor: Int32) throws -> PTYMuxResponse {
        PTYMuxResponse(ok: false)
    }
}

nonisolated enum PTYMuxObserverFrame {
    enum Kind: UInt8 { case output = 1 }
    static func next(in buffer: Data) throws -> (kind: Kind, data: Data, consumed: Int)? { nil }
}

@main
struct BrowserAccessWriteHarness {
    static func main() {
        let arguments = CommandLine.arguments
        guard (2...3).contains(arguments.count), let descriptor = Int32(arguments[1]), descriptor >= 0 else {
            fputs("usage: browser-access-write <descriptor>\n", stderr)
            Darwin.exit(2)
        }
        // Production start() sets this through PTYMuxWire.configureSocket before
        // the peer can hang up. Doing it here, while the peer is still open,
        // keeps a closed-peer send on the EPIPE path instead of SIGPIPE.
        _ = signal(SIGPIPE, SIG_IGN)
        var enabled: Int32 = 1
        guard Darwin.setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            fputs("SO_NOSIGPIPE errno \(errno)\n", stderr)
            Darwin.exit(2)
        }
        // AF_UNIX send waits out SO_SNDTIMEO and does not honor MSG_DONTWAIT.
        // One millisecond is enough for a full buffer to return a short count,
        // which is the production failure this probe has to catch.
        var sendTimeout = timeval(tv_sec: 0, tv_usec: 1_000)
        guard Darwin.setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            fputs("SO_SNDTIMEO errno \(errno)\n", stderr)
            Darwin.exit(2)
        }
        fputs("ready\n", stdout)
        fflush(stdout)
        var payload = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(STDIN_FILENO, &chunk, chunk.count)
            if count > 0 {
                payload.append(contentsOf: chunk.prefix(count))
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        if arguments.last == "bounded-small" {
            let fill = Data(repeating: 0, count: 8192)
            guard fill.withUnsafeBytes({ Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }) == fill.count else { Darwin.exit(1) }
        }
        let bridge = BrowserAccessMuxBridge(sessionID: UUID(), descriptor: descriptor)
        if arguments.last == "control" {
            let queue = DispatchQueue(label: "browser-access-write.control")
            let responsive = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            queue.async {
                guard bridge.write(payload, completed: { written in
                    if written { Darwin.exit(1) }
                    finished.signal()
                }) else { Darwin.exit(1) }
            }
            queue.async {
                bridge.close()
                responsive.signal()
            }
            guard responsive.wait(timeout: .now() + 0.5) == .success else {
                fputs("control queue blocked by unread PTY input\n", stdout)
                fflush(stdout)
                Darwin.exit(1)
            }
            guard finished.wait(timeout: .now() + 0.5) == .success else { Darwin.exit(1) }
            fputs("control queue stayed responsive\n", stdout)
            fflush(stdout)
        } else if arguments.last == "bounded" || arguments.last == "bounded-small" {
            let payload = arguments.last == "bounded-small" ? Data(payload.prefix(1)) : payload
            let finished = DispatchGroup()
            var accepted = 0
            while accepted < 128 {
                finished.enter()
                if bridge.write(payload, completed: { _ in finished.leave() }) {
                    accepted += 1
                } else {
                    finished.leave()
                    break
                }
            }
            guard accepted == BrowserAccessLimits.sendQueueBytes / BrowserAccessLimits.frameBytes else {
                fputs("unexpected accepted frame count \(accepted)\n", stdout)
                fflush(stdout)
                Darwin.exit(1)
            }
            bridge.close()
            guard finished.wait(timeout: .now() + 0.5) == .success,
                  !bridge.write(payload, completed: { _ in }) else { Darwin.exit(1) }
            fputs("bounded input cancelled\n", stdout)
            fflush(stdout)
        } else if arguments.last == "ordered" {
            let finished = DispatchGroup()
            for offset in stride(from: 0, to: payload.count, by: BrowserAccessLimits.frameBytes) {
                let end = min(payload.count, offset + BrowserAccessLimits.frameBytes)
                finished.enter()
                guard bridge.write(payload.subdata(in: offset..<end), completed: { written in
                    guard written else { Darwin.exit(1) }
                    finished.leave()
                }) else { Darwin.exit(1) }
            }
            guard finished.wait(timeout: .now() + 5) == .success else { Darwin.exit(1) }
            fputs("true\n", stdout)
            fflush(stdout)
        } else {
            let finished = DispatchSemaphore(value: 0)
            let accepted = bridge.write(payload) { written in
                fputs(written ? "true\n" : "false\n", stdout)
                fflush(stdout)
                finished.signal()
            }
            if !accepted {
                fputs("false\n", stdout)
                fflush(stdout)
            } else if finished.wait(timeout: .now() + 5) != .success {
                Darwin.exit(1)
            }
        }
    }
}
"""


def compiler_arguments(temporary):
    return [
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-default-isolation", "MainActor",
        "-enable-upcoming-feature", "MemberImportVisibility",
        "-warnings-as-errors",
        "-target", f"{platform.machine()}-apple-macos15.6",
        "-module-cache-path", str(temporary / "ModuleCache"),
    ]


def compile_harness(temporary):
    support = temporary / "Support.swift"
    support.write_text(SUPPORT)
    binary = temporary / "browser-access-write"
    subprocess.run(
        compiler_arguments(temporary) + [
            str(support),
            str(ROOT / "mac/zshell/BrowserAccessMuxBridge.swift"),
            "-o", str(binary),
        ],
        cwd=ROOT,
        check=True,
        timeout=120,
    )
    return binary


NETWORK_SUPPORT = r"""
import Darwin
import Foundation
import Network

nonisolated enum AppLocalization {
    static let current = Selection()
    struct Selection { let identifier = "en" }
}

nonisolated struct BrowserAccessCertificate {
    let fingerprint = ""
    let pem = Data()
    func parameters(interface: BrowserAccessInterface) throws -> NWParameters { .tcp }
}

nonisolated enum PTYMuxCommandLine {
    static func exchange(method: String, params: [String: ZshellJSONValue] = [:], timeout: TimeInterval = 2) throws -> PTYMuxResponse {
        throw PTYMuxError.message("The socket fixture only accepts observer connections.")
    }
}

@main
struct BrowserAccessWriteServerHarness {
    @MainActor static func main() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let id = UUID()
        let server = try BrowserAccessServer(directory: directory.appendingPathComponent("authorization"), assets: [:],
            sessions: { [BrowserAccessSession(id: id, project: "Fixture", title: "Fixture")] }, changed: { snapshot in
                if let url = snapshot.localURL {
                    output(["type": "endpoint", "url": url.absoluteString, "session": id.uuidString])
                }
                if let pending = snapshot.pending.first {
                    output(["type": "pairing", "id": pending.id.uuidString])
                }
            })
        try await server.start(interface: .loopback, port: 39443, certificate: nil, translations: [:])
        DispatchQueue.global(qos: .utility).async {
            while let line = readLine() {
                Task { @MainActor in
                    let parts = line.split(separator: " ")
                    switch parts.first {
                    case "approve":
                        guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { return }
                        server.approve(id) { error in output(["type": "approved", "error": error ?? ""]) }
                    case "barrier":
                        server.queue.async { output(["type": "barrier"]) }
                    case "revoke":
                        server.revoke(nil) { error in output(["type": "revoked", "error": error ?? ""]) }
                    case "stop":
                        await server.stop().value
                        output(["type": "stopped"])
                    case "quit":
                        await server.stop().value
                        Darwin.exit(0)
                    default: break
                    }
                }
            }
        }
        while true { try await Task.sleep(for: .seconds(30)) }
    }

    nonisolated static func output(_ value: [String: String]) {
        let data = try! JSONSerialization.data(withJSONObject: value)
        FileHandle.standardOutput.write(data + Data([10]))
    }
}
"""


def compile_network_harness(temporary):
    protocol = (ROOT / "mac/zshell/ZshellAutomationProtocol.swift").read_text()
    (temporary / "JSON.swift").write_text(protocol[:protocol.index("struct ZshellAutomationRequest:")])
    mux = (ROOT / "mac/zshell/PTYMux.swift").read_text()
    (temporary / "Mux.swift").write_text(mux[:mux.index("private final class PTYMuxDaemon")])
    (temporary / "NetworkSupport.swift").write_text(NETWORK_SUPPORT)
    binary = temporary / "browser-access-write-server"
    sources = ["BrowserAccessProtocol", "BrowserAccessAuthorization", "PTYMuxObserverFrame",
               "BrowserAccessMuxBridge", "BrowserAccessServer"]
    subprocess.run(
        compiler_arguments(temporary) + [str(temporary / name) for name in
            ["JSON.swift", "Mux.swift", "NetworkSupport.swift"]] +
        [str(ROOT / "mac/zshell" / (name + ".swift")) for name in sources] + ["-o", str(binary)],
        cwd=ROOT, check=True, timeout=120,
    )
    return binary


def read_line(stream, timeout):
    deadline = time.monotonic() + timeout
    collected = bytearray()
    fileno = stream.fileno()
    while time.monotonic() < deadline:
        remaining = max(0, deadline - time.monotonic())
        ready, _, _ = select.select([fileno], [], [], remaining)
        if not ready:
            break
        byte = os.read(fileno, 1)
        if not byte:
            break
        collected.extend(byte)
        if collected.endswith(b"\n"):
            return bytes(collected)
    raise AssertionError(f"harness output timed out after {bytes(collected)!r}")


def limited_pair():
    local, peer = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    local.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, SEND_BUFFER)
    peer.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, SEND_BUFFER)
    send_buffer = local.getsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF)
    receive_buffer = peer.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
    return local, peer, send_buffer, receive_buffer


def run_write(binary, payload, *, close_peer, mode="write"):
    local, peer, send_buffer, receive_buffer = limited_pair()
    if min(send_buffer, receive_buffer) >= len(payload):
        local.close()
        peer.close()
        raise AssertionError(
            f"socket buffers send={send_buffer} receive={receive_buffer} hold a {len(payload)}-byte frame"
        )
    process = subprocess.Popen(
        [str(binary), str(local.fileno()), mode],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        pass_fds=(local.fileno(),),
        bufsize=0,
    )
    received = bytearray()
    reader_error = []

    def read_peer():
        try:
            # Stay out of recv until the first send has returned. A peer already
            # blocked in recv can drain the 8192-byte buffer inside that one
            # call, so the short write this test exists to catch never happens.
            time.sleep(0.2)
            peer.settimeout(2)
            while len(received) < len(payload):
                chunk = peer.recv(min(4096, len(payload) - len(received)))
                if not chunk:
                    break
                received.extend(chunk)
        except Exception as error:
            reader_error.append(error)

    reader = None
    peer_closed = False
    try:
        ready = read_line(process.stdout, 10)
        if ready != b"ready\n":
            raise AssertionError(f"harness ready line was {ready!r}")
        if close_peer:
            peer.close()
            peer_closed = True
        elif mode not in {"control", "bounded", "bounded-small"}:
            reader = threading.Thread(target=read_peer)
            reader.start()
        process.stdin.write(payload)
        process.stdin.close()
        result = read_line(process.stdout, 10)
        process.wait(timeout=10)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        stderr = process.stderr.read()
        local.close()
        if reader is not None:
            reader.join(timeout=5)
        if not peer_closed:
            peer.close()
    return {
        "result": result,
        "code": process.returncode,
        "stderr": stderr,
        "received": bytes(received),
        "send_buffer": send_buffer,
        "receive_buffer": receive_buffer,
        "reader_error": reader_error,
    }


def payload_bytes():
    return bytes((index * 31 + 7) & 0xFF for index in range(FRAME_BYTES))


class ObserverFixture:
    def __init__(self, path):
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(str(path))
        self.listener.listen()
        self.listener.settimeout(0.2)
        self.accepted = queue.Queue()
        self.peers = []
        self.stopped = threading.Event()
        self.worker = threading.Thread(target=self.accept, daemon=True)
        self.worker.start()

    @staticmethod
    def read_exact(peer, count):
        result = bytearray()
        while len(result) < count:
            chunk = peer.recv(count - len(result))
            if not chunk:
                raise EOFError("observer closed")
            result.extend(chunk)
        return bytes(result)

    def accept(self):
        while not self.stopped.is_set():
            try:
                peer, _ = self.listener.accept()
            except TimeoutError:
                continue
            except OSError:
                return
            self.peers.append(peer)
            try:
                peer.settimeout(2)
                peer.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, SEND_BUFFER)
                count = struct.unpack(">I", self.read_exact(peer, 4))[0]
                request = json.loads(self.read_exact(peer, count))
                assert request["method"] == "observe"
                response = json.dumps({"version": 2, "id": request["id"], "ok": True}).encode()
                peer.sendall(struct.pack(">I", len(response)) + response)
                for kind, payload in [(2, bytes([0, 80, 0, 24])), (4, b""), (1, b"output")]:
                    peer.sendall(struct.pack(">I", len(payload) + 1) + bytes([kind]) + payload)
                self.accepted.put(peer)
            except Exception as error:
                self.accepted.put(error)

    def next_peer(self):
        peer = self.accepted.get(timeout=3)
        if isinstance(peer, Exception):
            raise peer
        return peer

    def close(self):
        self.stopped.set()
        self.listener.close()
        self.worker.join(timeout=3)
        for peer in self.peers:
            peer.close()


def drain_peer(peer):
    result = bytearray()
    while True:
        chunk = peer.recv(8192)
        if not chunk:
            return bytes(result)
        result.extend(chunk)


def check_server_controls(binary, temporary):
    root = temporary / "server"
    root.mkdir()
    fixture = ObserverFixture(root / "control.sock")
    environment = dict(os.environ, ZSHELL_PTY_MUX_DIRECTORY=str(root))
    process = subprocess.Popen([str(binary), str(root)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, bufsize=1, env=environment)
    events = queue.Queue()
    reader = threading.Thread(target=lambda: [events.put(json.loads(line)) for line in process.stdout], daemon=True)
    reader.start()
    sockets = []

    def event(kind, timeout=3):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = events.get(timeout=max(0.001, deadline - time.monotonic()))
            if value["type"] == kind:
                return value
        raise AssertionError(f"server did not process {kind}")

    def command(value):
        process.stdin.write(value + "\n")
        process.stdin.flush()

    try:
        endpoint = event("endpoint", timeout=10)
        url = endpoint["url"].rstrip("/")
        session = endpoint["session"]

        def post(path, body):
            request = urllib.request.Request(url + path, data=json.dumps(body).encode(), method="POST",
                headers={"Content-Type": "application/json", "Origin": url})
            with urllib.request.urlopen(request, timeout=2) as response:
                return json.load(response)

        def pair():
            pairing = post("/api/pair", {"name": "Input control probe"})
            command("approve " + event("pairing")["id"])
            assert not event("approved")["error"]
            return post("/api/pair/status", {"ticket": pairing["ticket"]})["token"]

        token = pair()

        def attach():
            ws = WebSocket(url)
            sockets.append(ws)
            ws.send({"type": "authenticate", "token": token})
            ws.expect("authenticated")
            ws.send({"type": "select", "session": session})
            ws.expect("ready")
            peer = fixture.next_peer()
            opcode, output = ws.receive()
            assert opcode == 2 and output == b"output"
            ws.socket.settimeout(0.75)
            return ws, peer, output

        def stall(ws, peer):
            ws.send(payload_bytes(), binary=True)
            assert select.select([peer], [], [], 2)[0], "the first input prefix never reached the mux"
            # A saturated receive buffer keeps the write retry active while
            # the real NWConnection has to process the following control frame.
            assert len(peer.recv(SEND_BUFFER, socket.MSG_PEEK)) == SEND_BUFFER
            time.sleep(0.05)

        def ping(ws):
            ws.socket.sendall(bytes([0x89, 0x80]) + bytes(4))
            assert ws.receive() == (10, b""), "server queue could not process a ping behind PTY input"

        ws, peer, output = attach()
        stall(ws, peer)
        ws.send({"type": "ack", "stream": ws.stream, "bytes": len(output)})
        ping(ws)
        command("barrier")
        event("barrier", timeout=0.5)
        ws.send(b"must be cancelled", binary=True)
        ws.send({"type": "select", "session": session})
        ws.expect("ready")
        new_peer = fixture.next_peer()
        old_input = drain_peer(peer)
        assert old_input and old_input == payload_bytes()[:len(old_input)], "detach delivered queued input to the old pane"
        opcode, output = ws.receive()
        assert opcode == 2
        ws.send({"type": "ack", "stream": ws.stream, "bytes": len(output)})
        ws.send(b"new input\r", binary=True)
        assert ObserverFixture.read_exact(new_peer, 10) == b"new input\r", "old write completion closed the selected pane"
        ping(ws)
        ws.close()
        assert drain_peer(new_peer) == b""
        print("production WebSocket ACK, ping, select and close stayed responsive behind stalled input")

        ws, peer, output = attach()
        ws.send({"type": "ack", "stream": ws.stream, "bytes": len(output)})
        stall(ws, peer)
        for _ in range(64):
            try:
                ws.send(payload_bytes(), binary=True)
            except ConnectionError:
                break
        ws.expect_closed()
        queued = drain_peer(peer)
        assert len(queued) <= SEND_BUFFER, "input queue overflow drained pending frames before cancelling"
        ws.close()
        print("production input flood disconnected at the 1 MiB queue bound")

        ws, peer, output = attach()
        ws.send({"type": "ack", "stream": ws.stream, "bytes": len(output)})
        stall(ws, peer)
        command("revoke")
        assert not event("revoked", timeout=0.75)["error"]
        ws.expect_closed()
        drain_peer(peer)
        ws.close()
        print("production revoke cancelled a stalled input writer")

        token = pair()
        ws, peer, output = attach()
        ws.send({"type": "ack", "stream": ws.stream, "bytes": len(output)})
        stall(ws, peer)
        command("stop")
        event("stopped", timeout=0.75)
        ws.expect_closed()
        drain_peer(peer)
        print("production stop returned while PTY input was stalled")
    finally:
        for ws in sockets:
            ws.close()
        if process.poll() is None:
            command("quit")
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
        fixture.close()
        reader.join(timeout=3)
        assert process.returncode == 0, process.stderr.read()


FD_SUPPORT = r"""
import Darwin
import Foundation

nonisolated final class BrowserAccessFDProbe: @unchecked Sendable {
    static let shared = BrowserAccessFDProbe()
    let paused = DispatchSemaphore(value: 0)
    let resumed = DispatchSemaphore(value: 0)
    var original: Int32 = -1
    var armed = true
}

// Pause after writable readiness, exactly between the production active check
// and send. The reader can then close while that send still owns its fd.
nonisolated func poll(_ descriptors: UnsafeMutablePointer<pollfd>!, _ count: nfds_t, _ milliseconds: Int32) -> Int32 {
    let result = Darwin.poll(descriptors, count, milliseconds)
    if result > 0, BrowserAccessFDProbe.shared.armed,
       descriptors.pointee.revents & Int16(POLLOUT) != 0 {
        BrowserAccessFDProbe.shared.armed = false
        BrowserAccessFDProbe.shared.paused.signal()
        guard BrowserAccessFDProbe.shared.resumed.wait(timeout: .now() + 3) == .success else { Darwin.exit(1) }
    }
    return result
}

@main
struct BrowserAccessFDHarness {
    static func main() {
        let probe = BrowserAccessFDProbe.shared
        let queue = DispatchQueue(label: "browser-access-write.fd.control")
        let ready = DispatchSemaphore(value: 0)
        let ended = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let bridge = BrowserAccessMuxBridge(sessionID: UUID())
        bridge.start(queue: queue, frame: { kind, _ in
            if kind == .ready { ready.signal() }
        }, ended: { _ in ended.signal() })
        guard ready.wait(timeout: .now() + 2) == .success,
              bridge.write(Data(repeating: 7, count: 16 * 1024), completed: { written in
                  if written { Darwin.exit(1) }
                  finished.signal()
              }), probe.paused.wait(timeout: .now() + 2) == .success else { Darwin.exit(1) }
        fputs("paused\n", stdout)
        fflush(stdout)
        guard ended.wait(timeout: .now() + 2) == .success,
              fcntl(probe.original, F_GETFD) < 0, errno == EBADF else { Darwin.exit(1) }
        var sockets: [Int32] = [-1, -1]
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { Darwin.exit(1) }
        let source = sockets[0] == probe.original ? sockets[0] : sockets[1] == probe.original ? sockets[1] : sockets[0]
        let peer = source == sockets[0] ? sockets[1] : sockets[0]
        if source != probe.original {
            guard dup2(source, probe.original) == probe.original else { Darwin.exit(1) }
            Darwin.close(source)
        }
        defer { Darwin.close(probe.original); Darwin.close(peer) }
        probe.resumed.signal()
        guard finished.wait(timeout: .now() + 2) == .success else { Darwin.exit(1) }
        var readable = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
        guard Darwin.poll(&readable, 1, 50) == 0 else {
            fputs("old input reached the reused fd\n", stdout)
            fflush(stdout)
            Darwin.exit(1)
        }
        fputs("reused fd received no input\n", stdout)
        fflush(stdout)
    }
}
"""


def compile_fd_harness(temporary):
    mux = (temporary / "Mux.swift").read_text().replace(
        "        try markCloseOnExec(descriptor)",
        "        BrowserAccessFDProbe.shared.original = descriptor\n        try markCloseOnExec(descriptor)",
    )
    (temporary / "FDMux.swift").write_text(mux)
    limits = (ROOT / "mac/zshell/BrowserAccessProtocol.swift").read_text()
    limits = limits[limits.index("nonisolated enum BrowserAccessLimits"):limits.index("nonisolated enum BrowserAccessError")]
    (temporary / "FD.swift").write_text(FD_SUPPORT + "\n" + limits)
    binary = temporary / "browser-access-write-fd"
    subprocess.run(
        compiler_arguments(temporary) + [str(temporary / name) for name in ["JSON.swift", "FDMux.swift", "FD.swift"]] +
        [str(ROOT / "mac/zshell" / (name + ".swift")) for name in ["PTYMuxObserverFrame", "BrowserAccessMuxBridge"]] +
        ["-o", str(binary)], cwd=ROOT, check=True, timeout=120,
    )
    return binary


def check_fd_reuse(binary, temporary):
    root = temporary / "fd"
    root.mkdir()
    fixture = ObserverFixture(root / "control.sock")
    process = subprocess.Popen([str(binary)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0,
                              env=dict(os.environ, ZSHELL_PTY_MUX_DIRECTORY=str(root)))
    try:
        peer = fixture.next_peer()
        assert read_line(process.stdout, 3) == b"paused\n"
        peer.shutdown(socket.SHUT_WR)
        assert read_line(process.stdout, 3) == b"reused fd received no input\n"
        process.wait(timeout=3)
        assert process.returncode == 0, process.stderr.read()
        print("reader EOF during a paused send did not write into a reused fd")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=3)
        fixture.close()


def main():
    payload = payload_bytes()
    with tempfile.TemporaryDirectory(prefix="zshell-browser-access-write-", dir="/tmp") as directory:
        binary = compile_harness(Path(directory))
        delivered = run_write(binary, payload, close_peer=False)
        if delivered["code"] != 0 or delivered["result"] != b"true\n" or delivered["received"] != payload or delivered["reader_error"]:
            raise SystemExit(
                "full paste was not delivered: "
                f"code={delivered['code']} result={delivered['result']!r} "
                f"received={len(delivered['received'])} stderr={delivered['stderr']!r} "
                f"reader={delivered['reader_error']!r}"
            )
        print(
            f"delivered {len(payload)} bytes through send buffer {delivered['send_buffer']} "
            f"and receive buffer {delivered['receive_buffer']}"
        )
        control = run_write(binary, payload, close_peer=False, mode="control")
        if control["code"] != 0 or control["result"] != b"control queue stayed responsive\n":
            raise SystemExit(
                f"unread PTY blocked controls: code={control['code']} stderr={control['stderr']!r}"
            )
        print("unread PTY did not block queued close")
        rejected = run_write(binary, payload, close_peer=True)
        if rejected["code"] != 0 or rejected["result"] != b"false\n":
            raise SystemExit(
                "closed peer was not a failed write: "
                f"code={rejected['code']} result={rejected['result']!r} stderr={rejected['stderr']!r}"
            )
        print("closed peer rejected the frame")
        ordered_payload = payload + bytes((byte + 1) & 0xFF for byte in payload) + b"last input\r"
        ordered = run_write(binary, ordered_payload, close_peer=False, mode="ordered")
        assert ordered["code"] == 0 and ordered["result"] == b"true\n" and ordered["received"] == ordered_payload, ordered
        print("consecutive frames were delivered in order")
        bounded = run_write(binary, payload, close_peer=False, mode="bounded")
        assert bounded["code"] == 0 and bounded["result"] == b"bounded input cancelled\n", bounded
        print("unread input was capped at 1 MiB and cancelled on close")
        small = run_write(binary, payload, close_peer=False, mode="bounded-small")
        assert small["code"] == 0 and small["result"] == b"bounded input cancelled\n", small
        print("single-byte input was capped at 64 queued frames")
        server = compile_network_harness(Path(directory))
        check_server_controls(server, Path(directory))
        fd = compile_fd_harness(Path(directory))
        check_fd_reuse(fd, Path(directory))


if __name__ == "__main__":
    main()
