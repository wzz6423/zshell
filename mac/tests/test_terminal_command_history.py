"""Run production history storage without a terminal renderer or user state.

Run this focused probe before the full Debug build. Every compiled production
helper and binary is placed in a disposable directory. Surface/UI acceptance
uses test_terminal_command_history_surfaces.py after an isolated Debug build.
"""
import os
from pathlib import Path
import subprocess
import tempfile


root = Path(__file__).resolve().parents[2]
source = root / "mac/zshell"
with tempfile.TemporaryDirectory(prefix="zshell-command-history-probe-", dir="/tmp") as directory:
    temporary = Path(directory)
    # Keep the production wire/file helpers while omitting the daemon, which
    # would pull unrelated terminal, CLI and application code into this probe.
    mux = (source / "PTYMux.swift").read_text()
    (temporary / "Wire.swift").write_text(mux[:mux.index("private final class PTYMuxDaemon")])
    cli = (source / "ZshellCommandLine.swift").read_text()
    (temporary / "CLIError.swift").write_text(cli[cli.index("enum CLIError:"):cli.index("private var cursesActiveAtExit")])
    binary = temporary / "history-probe"
    record_source = Path(os.environ.get("ZSHELL_TEST_COMMAND_RECORD_SOURCE", source / "TerminalCommandRecord.swift"))
    integration = []
    if record_source.is_file():
        integration = ["-D", "HISTORY_RECORD_PROBE", str(record_source), str(source / "TerminalCommandHistoryIntegration.swift")]
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-D", "HISTORY_STORE_PROBE",
        "-module-cache-path", str(temporary / "ModuleCache"),
        str(source / "ZshellAutomationProtocol.swift"), str(temporary / "Wire.swift"),
        str(temporary / "CLIError.swift"), str(source / "PersistentCLIConnection.swift"),
        str(source / "TerminalCommandHistory.swift"), *integration,
        str(root / "mac/tests/TerminalCommandHistoryTests.swift"), "-o", str(binary),
    ], cwd=root, check=True)
    subprocess.run([str(binary), str(temporary / "fixture")], cwd=root, check=True, timeout=90)
