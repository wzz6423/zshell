"""Verify production clipboard capture, PNG conversion and private file storage."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="zshell-local-images-", dir="/tmp") as directory:
    temporary = Path(directory)
    # File storage and image conversion are production code. Only the remote
    # transfer types, which are not exercised here, are excluded from this probe.
    remote = (ROOT / "mac/zshell/RemotePaste.swift").read_text()
    input_source = remote[remote.index("nonisolated enum RemotePasteInput:"):
                          remote.index("nonisolated enum RemotePasteUpload {")]
    limits = remote[remote.index("    static let maximumFileBytes"):
                    remote.index("    private static let chunkBytes")]
    size_error = remote[remote.index("    static func sizeError()"):
                        remote.index("    private static func invalidResponse()")]
    dependencies = temporary / "ClipboardDependencies.swift"
    dependencies.write_text(
        "import AppKit\nimport Darwin\nimport Foundation\nimport ImageIO\nimport UniformTypeIdentifiers\n"
        + "nonisolated enum RemoteHostError: Error { case message(String) }\n"
        + "nonisolated enum RemotePasteUpload {\n" + limits + size_error + "}\n"
        + input_source
    )
    wire = (ROOT / "mac/zshell/PTYMux.swift").read_text()
    wire_source = temporary / "PTYMuxWire.swift"
    wire_source.write_text(
        wire[:wire.index("struct PTYMuxRequest:")]
        + wire[wire.index("nonisolated enum PTYMuxError:"):wire.index("enum PTYMuxPaths {")]
        + wire[wire.index("private extension Data {"):wire.index("private final class PTYMuxDaemon")]
    )
    binary = temporary / "clipboard-tests"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-default-isolation", "MainActor",
        "-module-cache-path", str(temporary / "modules"),
        str(dependencies), str(wire_source),
        str(ROOT / "mac/zshell/LocalClipboardImageStore.swift"),
        str(ROOT / "mac/tests/LocalClipboardImageStoreTests.swift"), "-o", str(binary),
    ], check=True, cwd=ROOT)
    subprocess.run([str(binary), str(temporary / "files")], check=True, timeout=30)
