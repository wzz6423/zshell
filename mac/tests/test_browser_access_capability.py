"""Check retained-daemon compatibility without a Rust build or live user sessions."""

import importlib.util
import fcntl
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading
import unittest
import sys

sys.dont_write_bytecode = True


ROOT = Path(__file__).resolve().parents[2]


class BrowserCapabilityTests(unittest.TestCase):
    def test_old_live_daemon_is_kept_and_empty_daemon_is_replaced(self):
        source = ROOT / "mac/zshell/BrowserAccessProtocol.swift"
        protocol = source.read_text()
        begin = protocol.index("nonisolated enum BrowserAccessMuxCapability")
        end = protocol.index("nonisolated struct BrowserAccessConfiguration", begin)
        mux = (ROOT / "mac/zshell/PTYMux.swift").read_text()
        with tempfile.TemporaryDirectory(prefix="zshell-browser-capability-", dir="/tmp") as temporary:
            directory = Path(temporary)
            spec = importlib.util.spec_from_file_location("browser_probe", ROOT / "mac/tests/test_browser_access.py")
            helper = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(helper)
            helper.production_fragments(directory)
            wire = directory / "Wire.swift"
            wire.write_text(mux[:mux.index("private final class PTYMuxDaemon")])
            command = directory / "Command.swift"
            # Compile the exact production exchange routine without the daemon.
            begin_exchange = mux.index("    nonisolated static func exchange(")
            end_exchange = mux.index("    private static func printResult", begin_exchange)
            command.write_text("import Foundation\nimport Darwin\nnonisolated enum PTYMuxCommandLine {\n" + mux[begin_exchange:end_exchange] + "}\n")
            capability = directory / "Capability.swift"
            capability.write_text("import Foundation\nimport Darwin\n" + protocol[protocol.index("nonisolated enum BrowserAccessError"):end])
            harness = directory / "Harness.swift"
            harness.write_text(r'''import Foundation
@main struct Probe {
    static func main() {
        do { try BrowserAccessMuxCapability.prepare(); print("accepted") }
        catch BrowserAccessError.sessionServiceRequired { print("required") }
        catch BrowserAccessError.sessionServiceUnavailable { print("unavailable") }
        catch { print("unexpected: \(error)") }
    }
}
''')
            binary = directory / "probe"
            subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(directory / "modules"),
                            str(directory / "JSON.swift"), str(wire), str(command), str(capability), str(harness),
                            "-o", str(binary)], check=True)
            cases = [
                ("old-live", "unknown_method", True, False, "required", False),
                ("old-empty", "unknown_method", False, False, "accepted", True),
                ("current", "supported", True, False, "accepted", False),
                ("failed-list", "unknown_method", True, True, "unavailable", False),
                ("observe-false", "disabled", True, False, "required", False),
                ("capability-error", "request_failed", True, False, "unavailable", False),
                ("capability-timeout", "timeout", True, False, "unavailable", False),
                ("malformed-capability", "malformed", True, False, "unavailable", False),
                ("shutdown-error", "shutdown-failed", False, False, "unavailable", True),
                ("shutdown-race", "shutdown-running", False, False, "required", True),
            ]
            for name, capability_mode, running, failed_list, expected, shutdown in cases:
                with self.subTest(name=name):
                    state = directory / name
                    state.mkdir(mode=0o700)
                    path = state / "control.sock"
                    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    listener.bind(str(path))
                    listener.listen()
                    listener.settimeout(0.1)
                    stopped = threading.Event()
                    methods = []

                    def read(connection, count):
                        value = b""
                        while len(value) < count:
                            chunk = connection.recv(count - len(value))
                            if not chunk:
                                raise EOFError("Socket probe closed without a request")
                            value += chunk
                        return value

                    def serve():
                        while not stopped.is_set():
                            try:
                                connection, _ = listener.accept()
                            except TimeoutError:
                                continue
                            with connection:
                                try:
                                    count = struct.unpack(">I", read(connection, 4))[0]
                                except EOFError:
                                    continue
                                request = json.loads(read(connection, count))
                                method = request["method"]
                                methods.append(method)
                                if method == "capabilities" and capability_mode == "timeout":
                                    stopped.wait(0.4)
                                    continue
                                ok = method != "capabilities" or capability_mode in ("supported", "disabled", "malformed")
                                code = "unknown_method"
                                if method == "capabilities" and capability_mode == "request_failed":
                                    code = "request_failed"
                                if method == "list" and failed_list:
                                    ok, code = False, "request_failed"
                                if method == "shutdown" and capability_mode in ("shutdown-failed", "shutdown-running"):
                                    ok = False
                                    code = "sessions_running" if capability_mode == "shutdown-running" else "request_failed"
                                result = ({} if capability_mode == "malformed" else {"observe": capability_mode == "supported"}) if method == "capabilities" else [{"running": running}] if method == "list" else {"accepted": True}
                                response = json.dumps({"version": 2, "id": request["id"], "ok": ok, "result": result if ok else None,
                                    "error": None if ok else {"code": code, "message": "unsupported"}}).encode()
                                connection.sendall(struct.pack(">I", len(response)) + response)

                    worker = threading.Thread(target=serve)
                    worker.start()
                    try:
                        result = subprocess.check_output([str(binary)], text=True, timeout=4,
                            env={**os.environ, "ZSHELL_PTY_MUX_DIRECTORY": str(state)}).strip()
                        self.assertEqual(result, expected)
                        self.assertEqual("shutdown" in methods, shutdown)
                        self.assertNotIn("terminateAll", methods)
                    finally:
                        stopped.set()
                        worker.join(timeout=2)
                        listener.close()
                        path.unlink()
            for locked in [False, True]:
                with self.subTest(stale_socket=True, daemon_locked=locked):
                    state = directory / ("stale-" + str(locked))
                    state.mkdir(mode=0o700)
                    path = state / "control.sock"
                    stale = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    stale.bind(str(path))
                    stale.close()
                    with (state / "daemon.lock").open("w") as lock:
                        if locked:
                            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        result = subprocess.check_output([str(binary)], text=True, timeout=4,
                            env={**os.environ, "ZSHELL_PTY_MUX_DIRECTORY": str(state)}).strip()
                        self.assertEqual(result, "unavailable" if locked else "accepted")
                        self.assertTrue(path.exists(), "The check must never unlink control.sock")
                        if locked:
                            fcntl.flock(lock, fcntl.LOCK_UN)
                            result = subprocess.check_output([str(binary)], text=True, timeout=4,
                                env={**os.environ, "ZSHELL_PTY_MUX_DIRECTORY": str(state)}).strip()
                            self.assertEqual(result, "accepted", "Retry recovers when the daemon lock is released")
            state = directory / "absent"
            state.mkdir(mode=0o700)
            result = subprocess.check_output([str(binary)], text=True, timeout=4,
                env={**os.environ, "ZSHELL_PTY_MUX_DIRECTORY": str(state)}).strip()
            self.assertEqual(result, "accepted")
            with (state / "daemon.lock").open("w") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                result = subprocess.check_output([str(binary)], text=True, timeout=4,
                    env={**os.environ, "ZSHELL_PTY_MUX_DIRECTORY": str(state)}).strip()
                self.assertEqual(result, "unavailable", "A held startup lock with no socket is retryable")


if __name__ == "__main__":
    unittest.main()
