"""Exercise production SSH agent discovery without changing personal dotfiles.

Run: python3 mac/tests/test_ssh_agent_environment.py
"""

import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
HARNESS = r'''
import Darwin
import Foundation

struct AgentInput: Decodable {
    let environment: [String: String]
    let shell: String
    let timeout: Double
    let mode: String
}

@main struct AgentHarness {
    @MainActor static func main() throws {
        let input = try JSONDecoder().decode(AgentInput.self, from: FileHandle.standardInput.readDataToEndOfFile())
        let agent = SSHAgentEnvironment(environment: input.environment, shellPath: input.shell, timeout: input.timeout)
        defer { agent.cleanup() }
        let started = Date()
        var values: [[String: String]] = []
        var result: [String: Any] = [:]
        switch input.mode {
        case "launch":
            let script = agent.terminalLaunchScript("printf '%s\\n%s\\n' \"${SSH_AUTH_SOCK:-}\" \"${ZSHELL_SSH_AGENT_RESOLVED:-}\"")
            result["setupElapsed"] = Date().timeIntervalSince(started)
            let process = try BoundedProcessRunner.run(executableURL: URL(fileURLWithPath: "/bin/sh"),
                                                       arguments: ["-c", script], timeout: 8, outputLimit: 4096,
                                                       environment: input.environment)
            result["stdout"] = process.output.stdout
            result["status"] = process.terminationStatus
            values.append(agent.resolvedEnvironment(input.environment))
        case "concurrent":
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: 16) { _ in
                let value = agent.resolvedEnvironment(input.environment)
                lock.lock()
                values.append(value)
                lock.unlock()
            }
        case "transport":
            let transport = OpenSSHTransport(executableURL: URL(fileURLWithPath: input.shell))
            result["stdout"] = try transport.run(endpoint: SSHEndpoint(host: "test"), command: [":"]).stdout
        default:
            values.append(agent.resolvedEnvironment(input.environment))
            values.append(agent.resolvedEnvironment(input.environment))
        }
        result["values"] = values
        result["elapsed"] = Date().timeIntervalSince(started)
        agent.cleanup()
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result))
    }
}
'''


class SSHAgentEnvironmentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="zshell-ssh-agent-build-", dir="/tmp")
        cls.addClassCleanup(cls.build.cleanup)
        directory = Path(cls.build.name)
        host = directory / "RemoteHost.swift"
        host.write_text((ROOT / "mac/zshell/RemoteHost.swift").read_text().split("nonisolated struct RemoteSessionInfo:")[0])
        harness = directory / "Harness.swift"
        harness.write_text(HARNESS)
        cls.binary = directory / "agent-probe"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                        "-default-isolation", "MainActor", "-module-cache-path", str(directory / "ModuleCache"),
                        str(ROOT / "mac/zshell/RemoteSSH.swift"), str(ROOT / "mac/zshell/SSHAgentEnvironment.swift"),
                        str(host), str(harness), "-o", str(cls.binary)], check=True)

    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory(prefix="zshell-agent-", dir="/tmp")
        self.addCleanup(self.fixture.cleanup)
        self.home = Path(self.fixture.name)
        self.sockets = []
        self.addCleanup(lambda: [value.close() for value in self.sockets])
        self.inherited = self.make_socket("launchd.sock")
        self.selected = self.make_socket("one password's.sock")
        self.counter = self.home / "profile-count"
        self.environment = {"HOME": str(self.home), "ZDOTDIR": str(self.home), "PATH": "/usr/bin:/bin",
                            "SSH_AUTH_SOCK": self.inherited, "UNRELATED": "keep"}
        self.profile("export SSH_AUTH_SOCK=\"$HOME/one password's.sock\"")

    def make_socket(self, name):
        value = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        path = str(self.home / name)
        value.bind(path)
        self.sockets.append(value)
        return path

    def profile(self, command):
        (self.home / ".zshrc").write_text(
            "printf x >> \"$HOME/profile-count\"\n"
            "printf 'startup noise without newline'\n"
            "printf 'startup stderr\\n' >&2\n" + command + "\n")

    def probe(self, *, mode="resolve", environment=None, shell="/bin/zsh", timeout=1, process_environment=None):
        payload = {"environment": self.environment if environment is None else environment,
                   "shell": shell, "timeout": timeout, "mode": mode}
        env = {key: value for key, value in os.environ.items()
               if key not in ("ZSHELL_CLI_STATE", "ZSHELL_CLI_TOKEN", "SSH_AUTH_SOCK")}
        env["CFFIXED_USER_HOME"] = str(self.home)
        if process_environment:
            env.update(process_environment)
        result = subprocess.run([str(self.binary)], input=json.dumps(payload), text=True, capture_output=True,
                                timeout=12, env=env, check=True)
        return json.loads(result.stdout)

    def assert_socket(self, result, path):
        self.assertTrue(result["values"])
        for environment in result["values"]:
            self.assertEqual(environment.get("SSH_AUTH_SOCK"), path)
            self.assertEqual(environment["UNRELATED"], "keep")
            self.assertEqual(environment["ZSHELL_SSH_AGENT_RESOLVED"], "1")

    def test_gui_uses_noisy_login_shell_socket_and_caches_success(self):
        result = self.probe()
        self.assert_socket(result, self.selected)
        self.assertEqual(self.counter.read_text(), "x")

    def test_terminal_preserves_inherited_agent(self):
        result = self.probe(environment={**self.environment, "TERM": "xterm-256color"})
        self.assert_socket(result, self.inherited)
        self.assertFalse(self.counter.exists())

    def test_terminal_with_invalid_inherited_agent_reads_profile(self):
        result = self.probe(environment={**self.environment, "TERM": "xterm", "SSH_AUTH_SOCK": "/missing"})
        self.assert_socket(result, self.selected)

    def test_profile_accepts_symlink_to_agent_socket(self):
        link = self.home / "agent-symlink"
        link.symlink_to(self.selected)
        self.profile("export SSH_AUTH_SOCK=\"$HOME/agent-symlink\"")
        self.assert_socket(self.probe(), str(link))

    def test_dash_reads_login_profile(self):
        (self.home / ".profile").write_text("export SSH_AUTH_SOCK=\"$HOME/one password's.sock\"\n")
        self.assert_socket(self.probe(shell="/bin/dash"), self.selected)

    def test_fish_receives_its_own_variable_syntax_and_login_flags(self):
        shell = self.home / "fish"
        shell.write_text("#!/bin/sh\n"
                         "[ \"$1\" = -l ] && [ \"$2\" = -i ] && [ \"$3\" = -c ] || exit 1\n"
                         "case \"$4\" in 'if set -q SSH_AUTH_SOCK;'*) ;; *) exit 1;; esac\n"
                         "marker=$(printf '%s' \"$4\" | /usr/bin/sed -nE 's/.*(ZSHELL_AGENT_[A-F0-9-]{36}).*/\\1/p')\n"
                         "printf '\\000%s\\000%s\\000' \"$marker\" \"$HOME/one password's.sock\"\n")
        shell.chmod(0o700)
        self.assert_socket(self.probe(shell=str(shell)), self.selected)

    def test_concurrent_connections_probe_once(self):
        self.profile("/bin/sleep 0.2; export SSH_AUTH_SOCK=\"$HOME/one password's.sock\"")
        result = self.probe(mode="concurrent")
        self.assert_socket(result, self.selected)
        self.assertEqual(len(result["values"]), 16)
        self.assertEqual(self.counter.read_text(), "x")

    def test_invalid_sockets_fall_back_and_cache_failure(self):
        regular = self.home / "ordinary-file"
        regular.write_text("text")
        for command in ("unset SSH_AUTH_SOCK", "export SSH_AUTH_SOCK=/missing", "export SSH_AUTH_SOCK=relative",
                        "export SSH_AUTH_SOCK=\"$HOME/ordinary-file\"", "export SSH_AUTH_SOCK=\"$HOME\"",
                        "export SSH_AUTH_SOCK=$'bad\\nsocket'"):
            with self.subTest(command=command):
                self.counter.unlink(missing_ok=True)
                self.profile(command)
                self.assert_socket(self.probe(), self.inherited)
                self.assertEqual(self.counter.read_text(), "x")

    def test_invalid_inherited_socket_is_removed(self):
        self.profile("unset SSH_AUTH_SOCK")
        result = self.probe(environment={**self.environment, "SSH_AUTH_SOCK": "/missing"})
        self.assert_socket(result, None)
        self.assertEqual(self.counter.read_text(), "x")

    def test_failure_timeout_and_excess_output_are_bounded(self):
        for command, timeout in (("exit 1", 1), ("while :; do :; done", 0.1),
                                 ("/usr/bin/head -c 40000 /dev/zero", 1)):
            with self.subTest(command=command):
                self.counter.unlink(missing_ok=True)
                self.profile(command)
                result = self.probe(timeout=timeout)
                self.assert_socket(result, self.inherited)
                self.assertLess(result["elapsed"], 3)
                self.assertEqual(self.counter.read_text(), "x")

    def test_unsupported_shell_preserves_fallback(self):
        result = self.probe(shell="/bin/cat")
        self.assert_socket(result, self.inherited)
        self.assertFalse(self.counter.exists())

    def test_already_resolved_relay_does_not_spawn_shell_again(self):
        for inherited in (self.inherited, "/missing"):
            with self.subTest(inherited=inherited):
                result = self.probe(environment={**self.environment, "SSH_AUTH_SOCK": inherited,
                                                 "ZSHELL_SSH_AGENT_RESOLVED": "1"})
                self.assert_socket(result, self.inherited if inherited == self.inherited else None)
                self.assertFalse(self.counter.exists())

    def test_launch_setup_returns_before_profile_and_child_reads_safe_path(self):
        self.profile("/bin/sleep 0.3; export SSH_AUTH_SOCK=\"$HOME/one password's.sock\"")
        result = self.probe(mode="launch")
        self.assertLess(result["setupElapsed"], 0.15)
        self.assertEqual(result["status"], 0)
        self.assertEqual(result["stdout"], self.selected + "\n1\n")
        self.assertEqual(self.counter.read_text(), "x")

    def test_launch_timeout_still_starts_child(self):
        self.profile("while :; do :; done")
        result = self.probe(mode="launch", timeout=0.1)
        self.assertLess(result["setupElapsed"], 0.15)
        self.assertLess(result["elapsed"], 3)
        self.assertEqual(result["stdout"], self.inherited + "\n1\n")
        self.assertEqual(result["status"], 0)

    def test_openssh_transport_inherits_resolved_agent(self):
        executable = self.home / "ssh"
        executable.write_text("#!/bin/sh\nprintf '%s\\n%s\\n' \"$SSH_AUTH_SOCK\" \"$SSH_ASKPASS_REQUIRE\"\n")
        executable.chmod(0o700)
        result = self.probe(mode="transport", shell=str(executable),
                            process_environment={"ZSHELL_SSH_AGENT_RESOLVED": "1", "SSH_AUTH_SOCK": self.selected})
        self.assertEqual(result["stdout"], self.selected + "\nnever\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
