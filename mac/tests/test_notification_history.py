"""Exercise production bounded history and command metadata without a GUI or build."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]

with tempfile.TemporaryDirectory(prefix="zshell-notification-history-", dir="/tmp") as directory:
    temporary = Path(directory)
    support = temporary / "Support.swift"
    connections = (ROOT / "mac/zshell/PersistentCLIConnection.swift").read_text()
    private_io = connections[connections.index("    static func preparePrivateDirectory"):connections.rindex("}")]
    history = (ROOT / "mac/zshell/AgentConversationHistory.swift").read_text()
    normalized = history[history.index("    static func normalizedText"):history.index("    init(")]
    wire = (ROOT / "mac/zshell/PTYMux.swift").read_text()
    write_all = wire[wire.index("    static func writeAll"):wire.index("    private static func readExactly")]
    support.write_text("""
import Darwin
import Foundation
enum CLIError: Error { case message(String) }
enum PTYMuxConstants { static let maximumFrameBytes = 256 * 1024 }
enum PTYMuxWire {
    static func errnoError(_ operation: String) -> CLIError { .message(operation) }
""" + write_all + "}\nenum PersistentCLIConnection {\n" + private_io
                       + "}\nstruct AgentConversationHistoryRecord {\n" + normalized + "}\n")
    binary = temporary / "history-probe"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-D", "DEBUG",
        "-module-cache-path", str(temporary / "ModuleCache"), str(support),
        str(ROOT / "mac/zshell/TerminalNotificationHistory.swift"),
        str(ROOT / "mac/zshell/TerminalCommandNotificationResult.swift"),
        str(ROOT / "mac/tests/TerminalNotificationHistoryTests.swift"), "-o", str(binary),
    ], cwd=ROOT, check=True)
    subprocess.run([str(binary), str(temporary)], cwd=ROOT, check=True, timeout=45)

    # Compile the production zsh shim so Swift interpolation and escaping are
    # identical to the real shell launch. The fixture uses no user dotfiles.
    source = (ROOT / "mac/zshell/TerminalSession.swift").read_text()
    shim = source[source.index("        if AppSettings.shared.notifyFinishSeconds > 0"):
                  source.index("        for (name, contents) in files", source.index("        if AppSettings.shared.notifyFinishSeconds > 0"))]
    generator = temporary / "Shell.swift"
    generator.write_text("""
import Foundation
struct AppSettings {
    static var shared = AppSettings()
    var notifyFinishSeconds = 5
    var notifyOnError = true
}
@main struct Probe {
    static func main() throws {
        var files = [".zshrc": "autoload -Uz add-zsh-hook\\n"]
""" + shim + """
        try files[".zshrc"]!.write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
    }
}
""")
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(generator), "-o", str(binary)], cwd=ROOT, check=True)
    script = temporary / "shim.zsh"
    subprocess.run([str(binary), str(script)], cwd=ROOT, check=True)
    subprocess.run(["/bin/zsh", "-n", str(script)], cwd=ROOT, check=True)
    fixture = temporary / "commands.zsh"
    fixture.write_text("""
source "$1"
preexec_functions=()
precmd_functions=()
_zshell_notify_preexec true
(( _zshell_notify_stamp = EPOCHSECONDS - 6 ))
true
_zshell_notify_precmd
_zshell_notify_preexec false
false
_zshell_notify_precmd
_zshell_notify_preexec true
true
_zshell_notify_precmd
""")
    result = subprocess.run(["/bin/zsh", "-f", str(fixture), str(script)], cwd=ROOT, check=True, capture_output=True)
    notifications = result.stdout.split(b"\x1b]777;notify;")[1:]
    if len(notifications) != 2:
        trace = subprocess.run(["/bin/zsh", "-fx", str(fixture), str(script)], cwd=ROOT, capture_output=True)
        raise AssertionError(trace.stderr.decode()[-5_000:])
    assert len(notifications) == 2, result.stdout
    for sequence, (notification, status) in enumerate(zip(notifications, (b"0", b"1")), 1):
        title, body = notification.split(b";", 1)
        fields = title.split(b":")
        assert fields[0] == b"zshell-command" and fields[2:] == [str(sequence).encode(), status]
        assert b"exit " + status in body
        expected = b"true finished" if status == b"0" else b"false failed"
        assert body.startswith(expected), body
    print("PASS production zsh shim: duration threshold, full command name, original exit status, typed metadata")
