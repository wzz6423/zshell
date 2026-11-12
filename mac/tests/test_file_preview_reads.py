"""Bound direct image preview reads without building the app.

Run: python3 -B mac/tests/test_file_preview_reads.py
The probe compiles the production helper sliced from FileViewerView.swift.
"""

from pathlib import Path
import base64
import os
import re
import struct
import subprocess
import tempfile
import time
import unittest
import zlib

MAC = Path(__file__).resolve().parents[1]
SOURCE = MAC / "zshell/FileViewerView.swift"
HELPER_START = "    private nonisolated static func readDirectImagePreview(path: String) -> ReadResult {"
HELPER_END = "    private nonisolated static func contentType(for url: URL) -> UTType? {"
LIMIT = "    private nonisolated static let maxImagePreviewBytes = "
READ_DATA_START = "    private nonisolated static func readData(path: String) -> ReadResult {"


def slice_between(source, start, end):
    return source[source.index(start):source.index(end)]


def tiny_png():
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    signature = b"\x89PNG\r\n\x1a\n"
    header = struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)
    pixels = zlib.compress(b"\x00\xff\x00\x00")
    return signature + chunk(b"IHDR", header) + chunk(b"IDAT", pixels) + chunk(b"IEND", b"")


class FilePreviewReadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="zshell-file-preview-build-")
        cls.addClassCleanup(cls.build.cleanup)
        temporary = Path(cls.build.name)
        source = SOURCE.read_text()
        limit_at = source.index(LIMIT) + len(LIMIT)
        expression = source[limit_at:source.index("\n", limit_at)].strip()
        if expression != "64 << 20":
            raise AssertionError(f"image preview cap is {expression!r}")
        helper = slice_between(source, HELPER_START, HELPER_END).replace(
            "private nonisolated static func readDirectImagePreview(path: String) -> ReadResult",
            "func readDirectImagePreview(path: String) -> PreviewRead",
            1,
        )
        probe = temporary / "Probe.swift"
        probe.write_text(
            "import Foundation\nimport Darwin\n\n"
            "enum PreviewRead {\n"
            "    case data(Data)\n"
            "    case tooLarge\n"
            "    case unavailable\n"
            "}\n\n"
            f"let maxImagePreviewBytes = {expression}\n\n"
            + helper
            + r'''

@main struct FilePreviewReadProbe {
    static func main() {
        let path = CommandLine.arguments[1]
        switch readDirectImagePreview(path: path) {
        case .data(let data):
            print("data")
            print(data.count)
            if data.count <= 4096 {
                print(data.base64EncodedString())
            }
        case .tooLarge:
            print("tooLarge")
            print(0)
        case .unavailable:
            print("unavailable")
            print(0)
        }
    }
}
'''
        )
        cls.probe = temporary / "file-preview-read"
        compiled = subprocess.run(
            [
                "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                "-module-cache-path", str(temporary / "modules"),
                str(probe), "-o", str(cls.probe),
            ],
            capture_output=True, text=True, cwd=temporary,
        )
        if compiled.returncode != 0:
            raise AssertionError(compiled.stderr or compiled.stdout)

    def run_probe(self, path):
        started = time.monotonic()
        try:
            completed = subprocess.run(
                ["/usr/bin/time", "-l", str(self.probe), str(path)],
                capture_output=True, text=True, timeout=3,
            )
        except subprocess.TimeoutExpired as error:
            self.fail(f"{path.name} blocked the preview read: {error}")
        elapsed = time.monotonic() - started
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertLess(elapsed, 3, completed.stdout + completed.stderr)
        lines = completed.stdout.splitlines()
        self.assertGreaterEqual(len(lines), 2, completed.stdout)
        rss = None
        for line in completed.stderr.splitlines():
            if line.strip().endswith("maximum resident set size"):
                rss = int(line.split()[0])
                break
        self.assertIsNotNone(rss, completed.stderr)
        return lines, rss, elapsed

    def test_source_bounds_direct_image_reads(self):
        source = SOURCE.read_text()
        self.assertIn("private nonisolated static let maxTextBytes = 5 << 20", source)
        reader = slice_between(source, READ_DATA_START, HELPER_START)
        code = re.sub(r"(?m)^\s*///.*$", "", reader)
        self.assertIn("return readDirectImagePreview(path: path)", code)
        self.assertNotIn("Data(contentsOf:", code)
        preview = slice_between(
            source,
            "        if usesDirectImagePreview(for: url),",
            "        guard data.count <= maxTextBytes else {",
        )
        self.assertLess(
            preview.index("data.count <= maxImagePreviewBytes"),
            preview.index("NSImage(data: data)"),
        )

    def test_tiny_png_returns_its_bytes(self):
        png = tiny_png()
        with tempfile.TemporaryDirectory(prefix="zshell-file-preview-png-") as directory:
            path = Path(directory) / "tiny.png"
            path.write_bytes(png)
            lines, _, _ = self.run_probe(path)
        self.assertEqual(lines[0], "data")
        self.assertEqual(int(lines[1]), len(png))
        self.assertEqual(base64.b64decode(lines[2]), png)

    def test_sparse_file_over_cap_is_too_large_without_its_bytes(self):
        cap = 64 << 20
        with tempfile.TemporaryDirectory(prefix="zshell-file-preview-sparse-") as directory:
            path = Path(directory) / "oversized.tiff"
            descriptor = os.open(path, os.O_CREAT | os.O_RDWR, 0o644)
            try:
                os.ftruncate(descriptor, cap + 1)
            finally:
                os.close(descriptor)
            info = path.stat()
            self.assertGreater(info.st_size, cap)
            self.assertLess(info.st_blocks * 512, 4096)
            png = Path(directory) / "tiny.png"
            png.write_bytes(tiny_png())
            _, png_rss, _ = self.run_probe(png)
            lines, sparse_rss, _ = self.run_probe(path)
        self.assertEqual(lines[0], "tooLarge", lines)
        self.assertEqual(lines[1], "0")
        self.assertLess(
            sparse_rss - png_rss, 16 << 20,
            f"sparse rss {sparse_rss} png rss {png_rss}",
        )

    def test_fifo_named_as_png_is_unavailable_quickly(self):
        with tempfile.TemporaryDirectory(prefix="zshell-file-preview-fifo-") as directory:
            path = Path(directory) / "queue.png"
            os.mkfifo(path)
            lines, _, elapsed = self.run_probe(path)
        self.assertEqual(lines[0], "unavailable")
        self.assertEqual(lines[1], "0")
        self.assertLess(elapsed, 3)


if __name__ == "__main__":
    unittest.main(verbosity=2)
