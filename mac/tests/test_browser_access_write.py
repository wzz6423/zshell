"""A browser paste larger than the Unix send buffer must be written whole.

Compiles production BrowserAccessMuxBridge.write against a socketpair. No app
build, browser server, or mux daemon is required. The dial path is stubbed so
this file can typecheck; the assertions call the production write.

AF_UNIX send waits out SO_SNDTIMEO and does not honor MSG_DONTWAIT. The harness
sets a 1 ms send timeout so one send can accept only the 8192-byte buffer, and
the peer waits briefly before reading so that short write is visible.
"""

import os
from pathlib import Path
import platform
import select
import socket
import subprocess
import tempfile
import threading
import time


ROOT = Path(__file__).resolve().parents[2]
FRAME_BYTES = 16 * 1024
SEND_BUFFER = 8192

SUPPORT = r"""
import Darwin
import Foundation

nonisolated enum BrowserAccessLimits {
    static let frameBytes = 16 * 1024
    static let outputCredit = 256 * 1024
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
        guard arguments.count == 2, let descriptor = Int32(arguments[1]), descriptor >= 0 else {
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
        let bridge = BrowserAccessMuxBridge(sessionID: UUID(), descriptor: descriptor)
        fputs(bridge.write(payload) ? "true\n" : "false\n", stdout)
        fflush(stdout)
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


def run_write(binary, payload, *, close_peer):
    local, peer, send_buffer, receive_buffer = limited_pair()
    if min(send_buffer, receive_buffer) >= len(payload):
        local.close()
        peer.close()
        raise AssertionError(
            f"socket buffers send={send_buffer} receive={receive_buffer} hold a {len(payload)}-byte frame"
        )
    process = subprocess.Popen(
        [str(binary), str(local.fileno())],
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
        else:
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
        rejected = run_write(binary, payload, close_peer=True)
        if rejected["code"] != 0 or rejected["result"] != b"false\n":
            raise SystemExit(
                "closed peer was not a failed write: "
                f"code={rejected['code']} result={rejected['result']!r} stderr={rejected['stderr']!r}"
            )
        print("closed peer rejected the frame")


if __name__ == "__main__":
    main()
