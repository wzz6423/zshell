"""Compile production daemon boundaries and use Codex's real TOML configuration API.

All settings, binaries, and module caches stay in a disposable directory.
No thread or model request is sent.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
if not shutil.which("codex"):
    raise SystemExit("Install Codex to verify its terminal-title configuration API.")

with tempfile.TemporaryDirectory(prefix="zshell-codex-binding-", dir="/tmp") as temp:
    directory = Path(temp)
    runner = (root / "mac/zshell/AgentUsage.swift").read_text()
    runner = "import Darwin\nimport Foundation\n" + runner[runner.index("nonisolated struct ProcessCommandResult") :]
    helper = directory / "ProcessRunner.swift"
    helper.write_text(runner)
    binary = directory / "binding-tests"
    sources = ["AgentConversationIdentity.swift", "AgentConversationBinding.swift", "ProcessWorkingDirectory.swift",
               "CodexTitleConfiguration.swift", "ZshellAutomationProtocol.swift", "ZshellAgentSessionHooks.swift"]
    command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
               "-module-cache-path", str(directory / "ModuleCache")]
    command += [str(root / "mac/zshell" / file) for file in sources]
    command += [str(helper), str(root / "mac/tests/CodexDaemonBindingTests.swift"), "-o", str(binary)]
    subprocess.run(command, check=True)
    contents = directory / "HookFixture.app/Contents"
    executable = contents / "MacOS/zshell"
    executable.parent.mkdir(parents=True)
    executable.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$HOOK_ARGUMENTS"\n')
    executable.chmod(0o700)
    resources = contents / "Resources"
    resources.mkdir()
    for name, operation in (("zshell-session-hook.sh", "_session-start"),
                            ("zshell-lifecycle-hook.sh", "_lifecycle")):
        script = resources / name
        shutil.copy2(root / "mac/zshell/AgentIntegrations" / name, script)
        script.chmod(0o700)
        link = directory / name
        link.symlink_to(script)
        captured = directory / (name + ".arguments")
        hook_environment = {"PATH": "/usr/bin:/bin", "HOOK_ARGUMENTS": str(captured)}
        subprocess.run([str(link), "codex", operation], env=hook_environment, check=True)
        assert captured.read_text().splitlines() == ["+agent", operation, "codex"]
        print(f"PASS managed {operation} hook finds its owning app without pane environment")
    environment = {key: value for key, value in os.environ.items()
                   if key not in {"CODEX_HOME", "CODEX_THREAD_ID"} and not key.startswith("ZSHELL_")}
    subprocess.run([str(binary)], check=True, env=environment, timeout=60)
    session = (root / "mac/zshell/TerminalSession.swift").read_text()
    record = session[session.index("    @discardableResult\n    func recordAgentConversation("):
                     session.index("    deinit {", session.index("    func recordAgentConversation("))]
    record_source = directory / "RecordConversation.swift"
    record_source.write_text("import Foundation\n@MainActor extension TerminalSession {\n" + record + "}\n")
    fork_binary = directory / "fork-binding-tests"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                    "-module-cache-path", str(directory / "ModuleCache"),
                    *[str(root / "mac/zshell" / name) for name in (
                        "AgentConversationIdentity.swift", "AgentConversationBinding.swift", "CodexDaemonBinding.swift",
                        "ZshellAutomationProtocol.swift")],
                    str(record_source), str(root / "mac/tests/CodexForkBindingTests.swift"), "-o", str(fork_binary)], check=True)
    subprocess.run([str(fork_binary)], check=True, env=environment, timeout=10)
