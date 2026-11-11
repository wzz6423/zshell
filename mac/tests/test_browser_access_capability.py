"""Check retained-daemon compatibility without a Rust build or live user sessions."""

import importlib.util
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
            capability.write_text("import Foundation\nnonisolated enum BrowserAccessError: Error { case message(String); case sessionServiceRequired }\n" + protocol[begin:end])
            harness = directory / "Harness.swift"
            harness.write_text('''import Foundation
@main struct Probe {
    static func main() {
        do { try BrowserAccessMuxCapability.prepare(); print("accepted") }
        catch { print("rejected") }
    }
}
''')
            binary = directory / "probe"
            subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(directory / "modules"),
                            str(directory / "JSON.swift"), str(wire), str(command), str(capability), str(harness),
                            "-o", str(binary)], check=True)
            for observe, running in [(False, True), (False, False), (True, True)]:
                with self.subTest(observe=observe, running=running):
                    state = directory / (str(observe) + str(running))
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
                            value += connection.recv(count - len(value))
                        return value

                    def serve():
                        while not stopped.is_set():
                            try:
                                connection, _ = listener.accept()
                            except TimeoutError:
                                continue
                            with connection:
                                count = struct.unpack(">I", read(connection, 4))[0]
                                request = json.loads(read(connection, count))
                                method = request["method"]
                                methods.append(method)
                                ok = method != "capabilities" or observe
                                result = {"observe": observe} if method == "capabilities" else [{"running": running}] if method == "list" else {"accepted": True}
                                response = json.dumps({"version": 2, "id": request["id"], "ok": ok, "result": result if ok else None,
                                    "error": None if ok else {"code": "unknown_method", "message": "unsupported"}}).encode()
                                connection.sendall(struct.pack(">I", len(response)) + response)

                    worker = threading.Thread(target=serve)
                    worker.start()
                    try:
                        result = subprocess.check_output([str(binary)], text=True, timeout=4,
                            env={**os.environ, "ZSHELL_PTY_MUX_DIRECTORY": str(state)}).strip()
                        self.assertEqual(result, "rejected" if running and not observe else "accepted")
                        self.assertEqual("shutdown" in methods, not observe and not running)
                        self.assertNotIn("terminateAll", methods)
                    finally:
                        stopped.set()
                        worker.join(timeout=2)
                        listener.close()
                        path.unlink()


if __name__ == "__main__":
    unittest.main()
