"""Exercise content search and bounded line reveals without opening app windows.

Run: python3 mac/tests/test_file_content_search.py
Run against a built Debug app: ZSHELL_TEST_DERIVED_DATA=/tmp/derived python3 mac/tests/test_file_content_search.py
"""
import json
import os
from pathlib import Path
import platform
import plistlib
import select
import subprocess
import sys
import tempfile
import unittest
import uuid

MAC = Path(__file__).resolve().parents[1]
BUILT_APP = "--built-app" in sys.argv or bool(os.environ.get("ZSHELL_TEST_DERIVED_DATA"))
if "--built-app" in sys.argv:
    sys.argv.remove("--built-app")


class FileContentSearchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="zshell-search-test-", dir="/tmp")
        cls.addClassCleanup(cls.build.cleanup)
        helper = Path(cls.build.name) / "SearchHarness.swift"
        helper.write_text(r'''
import Darwin
import Foundation
#if ZSHELL_BUILT_APP
import AppKit
import STTextView
@testable import zshell
#endif

@main struct SearchHarness {
    @MainActor static func main() async throws {
        if ProcessInfo.processInfo.environment["ZSHELL_TEST_STARTUP_HANDSHAKE"] != nil {
            FileHandle.standardOutput.write(Data("probe-ready\n".utf8))
            let start = try FileHandle.standardInput.read(upToCount: 1)
            precondition(start?.count == 1)
        }
        #if ZSHELL_BUILT_APP
        if CommandLine.arguments[1] == "--open-result" {
            try await openResult(root: CommandLine.arguments[2], query: CommandLine.arguments[3])
            return
        }
        #endif
        if CommandLine.arguments[1] == "--reveal" {
            let task = Task {
                await FileContentSearchModel.lineStartLocation(
                    line: Int(CommandLine.arguments[3])!, filePath: CommandLine.arguments[2]
                )
            }
            if CommandLine.arguments.last == "--cancel" {
                task.cancel()
            } else if CommandLine.arguments.last == "--cancel-after-read" {
                await Task.detached {
                    _ = try? FileHandle.standardInput.read(upToCount: 1)
                    task.cancel()
                    fputs("cancelled\n", stderr)
                }.value
            }
            let location = await task.value
            var usage = rusage()
            precondition(getrusage(RUSAGE_SELF, &usage) == 0)
            let result: [String: Any] = [
                "location": location as Any? ?? NSNull(),
                "peakRSSMiB": Double(usage.ru_maxrss) / 1_048_576,
            ]
            print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))
            return
        }
        let model = FileContentSearchModel()
        model.sync(root: CommandLine.arguments[1])
        model.query = CommandLine.arguments[2]
        model.run()
        if CommandLine.arguments.count > 3 {
            model.query = CommandLine.arguments[3]
            model.run()
        }
        for _ in 0..<500 {
            if !model.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let result: [String: Any] = [
            "running": model.isRunning,
            "truncated": model.isTruncated,
            "failed": model.failureMessage != nil,
            "matches": model.matches.map {
                ["path": $0.path, "line": $0.line, "content": $0.content] as [String: Any]
            },
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))
    }

    #if ZSHELL_BUILT_APP
    @MainActor static func openResult(root: String, query: String) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let model = FileContentSearchModel()
        model.sync(root: root)
        model.query = query
        model.run()
        for _ in 0..<500 {
            if !model.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(!model.isRunning && model.matches.count == 1)

        let match = model.matches[0]
        let path = (root as NSString).appendingPathComponent(match.path)
        let location = await FileContentSearchModel.lineStartLocation(line: match.line, filePath: path)
        let file = FileTab(path: path)
        if let location { file.revealSelection(at: location) }
        for _ in 0..<500 {
            if file.reloadRevision > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard file.reloadRevision > 0 else {
            throw NSError(domain: "SearchHarness", code: 1)
        }
        let viewer = FileViewerContainerView(file: file)
        viewer.update(font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                      palette: .theme(dark: true), wrapLines: false, isFocused: false,
                      showsSource: true, onFocused: {}, onSplit: { _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = viewer
        defer { window.contentView = nil }
        viewer.layoutSubtreeIfNeeded()
        let editor = (file.editorView as? NSScrollView)?.documentView as? STTextView
        let reason: String?
        if case .unavailable(let message) = file.content { reason = message } else { reason = nil }
        var usage = rusage()
        precondition(getrusage(RUSAGE_SELF, &usage) == 0)
        let result: [String: Any] = [
            "path": file.path, "line": match.line,
            "location": location as Any? ?? NSNull(),
            "selection": editor?.textSelection.location as Any? ?? NSNull(),
            "hasEditor": editor != nil, "text": file.text,
            "unavailable": reason as Any? ?? NSNull(), "windowVisible": window.isVisible,
            "tooLarge": reason == String(localized: "File is too large to open"),
            "peakRSSMiB": Double(usage.ru_maxrss) / 1_048_576,
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))
    }
    #endif
}
''')
        cls.helper = Path(cls.build.name) / "search"
        command = [
            "swiftc", "-parse-as-library", "-swift-version", "5",
            "-default-isolation", "MainActor",
            "-module-cache-path", str(Path(cls.build.name) / "modules"),
        ]
        if BUILT_APP:
            build = Path(os.environ.get("ZSHELL_TEST_DERIVED_DATA", MAC / "build/debug")) / "Build"
            products = build / "Products/Debug"
            app = products / "zshell Debug.app"
            library = app / "Contents/MacOS/zshell.debug.dylib"
            if not library.is_file():
                raise RuntimeError(f"Build the Debug app in {build.parent} before using --built-app")
            bundle = Path(cls.build.name) / "Search Probe.app/Contents"
            cls.helper = bundle / "MacOS/probe"
            cls.helper.parent.mkdir(parents=True)
            (bundle / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": f"sh.zshell.test.search.{uuid.uuid4().hex}",
                "CFBundleExecutable": "probe", "CFBundlePackageType": "APPL",
                "CFBundleDevelopmentRegion": "en", "LSBackgroundOnly": True,
            }))
            (bundle / "Resources").symlink_to(app / "Contents/Resources")
            command += ["-D", "ZSHELL_BUILT_APP", "-target", f"{platform.machine()}-apple-macos15.6",
                        "-I", str(products), "-I", str(products / "include"), "-F", str(products)]
            for modulemap in (build / "Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"):
                command += ["-Xcc", f"-fmodule-map-file={modulemap}"]
            for include in ("STTextView/Sources/STObjCLandShim/include", "swift-cmark/src/include",
                            "swift-cmark/extensions/include", "swift-markdown/Sources/CAtomic/include"):
                path = MAC / "Vendor" / include
                command += ["-I", str(path), "-Xcc", f"-fmodule-map-file={path / 'module.modulemap'}"]
            command += ["-I", str(MAC / "Vendor/alacritty-bridge/include"),
                        "-I", str(MAC / "Vendor/tree-sitter/lib/include"), str(library),
                        "-Xlinker", "-rpath", "-Xlinker", str(products),
                        "-Xlinker", "-rpath", "-Xlinker", str(library.parent)]
        else:
            command += [str(MAC / "zshell/FileContentSearchModel.swift"),
                        str(MAC / "zshell/MainActorIsolation.swift")]
        subprocess.run(command + [str(helper), "-o", str(cls.helper)], check=True)
        interposer = Path(cls.build.name) / "ReadFixtures.c"
        interposer.write_text(r'''
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static size_t read_calls;
static size_t read_bytes;

static ssize_t fixture_read(int descriptor, void *buffer, size_t count) {
    const char *target = getenv("ZSHELL_TEST_READ_PATH");
    char path[PATH_MAX];
    if (!target || fcntl(descriptor, F_GETPATH, path) != 0 || strcmp(path, target) != 0) {
        return read(descriptor, buffer, count);
    }
    const char *mode = getenv("ZSHELL_TEST_READ_MODE");
    read_calls++;
    if (strcmp(mode, "short") == 0 && count > 7) {
        count = 7;
    }
    if (read_calls == 1 && strcmp(mode, "grow") == 0) {
        if (truncate(target, 128 << 20) != 0) abort();
    }
    if (read_calls == 1 && strcmp(mode, "pause") == 0) {
        write(STDERR_FILENO, "read-started\n", 13);
        int gate = open(getenv("ZSHELL_TEST_READ_GATE"), O_RDONLY);
        char released;
        if (gate < 0 || read(gate, &released, 1) != 1) abort();
        close(gate);
    }
    ssize_t result = read(descriptor, buffer, count);
    if (result > 0) read_bytes += (size_t)result;
    if (read_calls == 1 && strcmp(mode, "truncate") == 0) {
        if (truncate(target, 0) != 0) abort();
    }
    return result;
}

__attribute__((used)) static const struct {
    const void *replacement;
    const void *original;
} read_interpose __attribute__((section("__DATA,__interpose"))) = {
    (const void *)&fixture_read, (const void *)&read,
};

__attribute__((destructor)) static void report_reads(void) {
    fprintf(stderr, "read-stats %zu %zu\n", read_calls, read_bytes);
}
''')
        cls.interposer = Path(cls.build.name) / "read-fixtures.dylib"
        subprocess.run([
            "xcrun", "clang", "-dynamiclib", "-Wall", "-Werror",
            str(interposer), "-o", str(cls.interposer),
        ], check=True)

    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory(prefix="zshell-search-fixture-")
        self.addCleanup(self.fixture.cleanup)
        self.root = Path(self.fixture.name)
        home = self.root / "home"
        config = home / ".config/zshell-dev"
        config.mkdir(parents=True)
        (home / "tmp").mkdir()
        (config / "config.toml").write_text("ai.enabled = false\nquick-terminal.enabled = false\n")
        self.environment = {key: value for key, value in os.environ.items()
                            if not key.startswith("ZSHELL_") and key != "DYLD_INSERT_LIBRARIES"}
        self.environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home), ZDOTDIR=str(home),
                                TMPDIR=str(home / "tmp"), XDG_CONFIG_HOME=str(home / ".config"))

    def search(self, query="needle", replacement=None):
        args = [str(self.helper), str(self.root), query]
        if replacement is not None:
            args.append(replacement)
        result = json.loads(self.run_probe(args, timeout=8).stdout)
        self.assertFalse(result["running"], "grep did not complete")
        self.assertFalse(result["failed"], "grep failed")
        return result

    def read_environment(self, path, mode):
        return dict(self.environment, DYLD_INSERT_LIBRARIES=str(self.interposer),
                    ZSHELL_TEST_READ_PATH=str(path.resolve()), ZSHELL_TEST_READ_MODE=mode)

    def start_probe(self, args, environment=None):
        environment = dict(environment or self.environment, ZSHELL_TEST_STARTUP_HANDSHAKE="1")
        process = subprocess.Popen(args, text=True, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
        try:
            # Loading the built Debug dylib can exceed the read deadline on a
            # busy machine. Start that deadline only after the probe is ready.
            startup_timeout = 15 if BUILT_APP else 3
            ready, _, _ = select.select([process.stdout], [], [], startup_timeout)
            if not ready:
                raise subprocess.TimeoutExpired(args, startup_timeout)
            self.assertEqual(process.stdout.readline(), "probe-ready\n", "probe did not finish startup")
            process.stdin.write("x")
            process.stdin.flush()
            return process
        except BaseException:
            if process.poll() is None:
                process.kill()
            process.communicate()
            raise

    def run_probe(self, args, *, timeout, environment=None):
        process = self.start_probe(args, environment)
        try:
            output, errors = process.communicate(timeout=timeout)
            if process.returncode:
                raise subprocess.CalledProcessError(process.returncode, args, output=output, stderr=errors)
            return subprocess.CompletedProcess(args, process.returncode, output, errors)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()

    def reveal(self, path, line=1, *, mode=None, cancel=False):
        args = [str(self.helper), "--reveal", str(path), str(line)]
        if cancel:
            args.append("--cancel")
        completed = self.run_probe(
            args, timeout=3,
            environment=self.read_environment(path, mode) if mode else self.environment,
        )
        result = json.loads(completed.stdout)
        if mode:
            stats = next(line for line in completed.stderr.splitlines() if line.startswith("read-stats "))
            result["readCalls"], result["readBytes"] = map(int, stats.split()[1:])
        return result

    def test_file_names_keep_colons_and_newlines(self):
        names = ["plain.txt", "has:colon.txt", "has\nnewline.txt"]
        for name in names:
            (self.root / name).write_text("first\nneedle\n")
        result = self.search()
        self.assertEqual({hit["path"] for hit in result["matches"]}, set(names))
        self.assertTrue(all(hit["line"] == 2 for hit in result["matches"]))

    def test_fast_exit_keeps_every_pipe_chunk(self):
        (self.root / "many.txt").write_text("needle\n" * 1999)
        result = self.search()
        self.assertEqual(len(result["matches"]), 1999)
        self.assertEqual(result["matches"][-1]["line"], 1999)
        self.assertFalse(result["truncated"])

    def test_match_limit_finishes_with_exact_cap(self):
        (self.root / "many.txt").write_text("needle\n" * 5000)
        result = self.search()
        self.assertEqual(len(result["matches"]), 2000)
        self.assertTrue(result["truncated"])

    def test_replaced_search_cannot_publish_old_matches_or_limit(self):
        (self.root / "many.txt").write_text("old\n" * 5000 + "new\n")
        result = self.search("old", "new")
        self.assertEqual(result["matches"], [
            {"path": "many.txt", "line": 5001, "content": "new"},
        ])
        self.assertFalse(result["truncated"])

    def test_query_starting_with_dash_and_binary_exclusion(self):
        (self.root / "plain.txt").write_text("-needle\n")
        (self.root / "binary.bin").write_bytes(b"\0-needle\n")
        result = self.search("-needle")
        self.assertEqual([hit["path"] for hit in result["matches"]], ["plain.txt"])

    def test_reveal_preserves_utf16_offsets_and_line_boundaries(self):
        path = self.root / "unicode.txt"
        path.write_text("é😀\r\nneedle\n最後")
        for line, location in [(0, None), (1, 0), (2, 5), (3, 12), (4, None)]:
            with self.subTest(line=line):
                self.assertEqual(self.reveal(path, line)["location"], location)
        path.write_bytes(b"")
        self.assertEqual(self.reveal(path)["location"], 0)
        self.assertIsNone(self.reveal(path, 2)["location"])

    def test_reveal_accepts_exact_editor_limit_and_rejects_one_extra_byte(self):
        path = self.root / "limit.txt"
        limit = 5 << 20
        path.write_bytes(b"a\n" + b"b" * (limit - 2))
        self.assertEqual(self.reveal(path, 2)["location"], 2)
        with path.open("r+b") as file:
            file.truncate(limit + 1)
        self.assertIsNone(self.reveal(path)["location"])

    def test_reveal_rejects_large_sparse_file_without_loading_it(self):
        baseline = self.reveal(self.root / "missing.txt")["peakRSSMiB"]
        path = self.root / "large.txt"
        with path.open("wb") as file:
            file.truncate(128 << 20)
        result = self.reveal(path)
        self.assertIsNone(result["location"])
        self.assertLess(result["peakRSSMiB"] - baseline, 16)

    def test_reveal_combines_short_reads_before_decoding_utf8(self):
        path = self.root / "short.txt"
        path.write_text("é😀\r\nneedle\n最後")
        result = self.reveal(path, 3, mode="short")
        self.assertGreater(result["readCalls"], 1, "short-read injection did not run")
        self.assertEqual(result["readBytes"], path.stat().st_size)
        self.assertEqual(result["location"], 12)

    def test_reveal_decodes_utf8_across_chunk_boundaries(self):
        path = self.root / "chunk.txt"
        path.write_bytes(b"a" * 65_535 + "😀\nneedle".encode())
        self.assertEqual(self.reveal(path, 2)["location"], 65_538)

    def test_reveal_bounds_a_file_that_grows_after_its_size_check(self):
        path = self.root / "growing.txt"
        path.write_text("first\nneedle\n")
        result = self.reveal(path, 2, mode="grow")
        self.assertEqual(path.stat().st_size, 128 << 20)
        self.assertGreater(result["readCalls"], 0, "growth injection did not run")
        self.assertIsNone(result["location"])
        self.assertLessEqual(result["readBytes"], (5 << 20) + 1)

    def test_reveal_discards_bytes_when_the_file_is_truncated_during_read(self):
        path = self.root / "truncated.txt"
        path.write_text("first\nneedle\n")
        result = self.reveal(path, 2, mode="truncate")
        self.assertEqual(path.stat().st_size, 0)
        self.assertGreater(result["readBytes"], 0, "truncation injection did not run")
        self.assertIsNone(result["location"])

    def test_reveal_rejects_unreadable_and_non_utf8_files(self):
        path = self.root / "invalid.txt"
        path.write_bytes(b"\xff\nneedle\n")
        self.assertIsNone(self.reveal(path, 2)["location"])
        self.assertIsNone(self.reveal(self.root / "missing.txt")["location"])

    def test_reveal_skips_nonregular_files_without_blocking(self):
        fifo = self.root / "fifo"
        os.mkfifo(fifo)
        alias = self.root / "fifo-link"
        alias.symlink_to(fifo)
        for path in [self.root, fifo, alias, Path("/dev/zero")]:
            with self.subTest(path=path):
                self.assertIsNone(self.reveal(path)["location"])

    def test_reveal_follows_symlinks_to_regular_files(self):
        path = self.root / "target.txt"
        path.write_text("first\nneedle\n")
        alias = self.root / "alias.txt"
        alias.symlink_to(path)
        self.assertEqual(self.reveal(alias, 2)["location"], 6)

    def test_cancelled_reveal_does_not_read_the_file(self):
        path = self.root / "cancelled.txt"
        path.write_text("needle\n")
        result = self.reveal(path, mode="count", cancel=True)
        self.assertIsNone(result["location"])
        self.assertEqual(result["readBytes"], 0)

    def test_reveal_cancellation_stops_an_active_reader(self):
        path = self.root / "cancelled.txt"
        path.write_bytes(b"a" * (1 << 20))
        gate = self.root / "read-gate"
        os.mkfifo(gate)
        release = os.open(gate, os.O_RDWR | os.O_NONBLOCK)
        self.addCleanup(os.close, release)
        environment = self.read_environment(path, "pause")
        environment["ZSHELL_TEST_READ_GATE"] = str(gate)
        process = self.start_probe(
            [str(self.helper), "--reveal", str(path), "1", "--cancel-after-read"],
            environment,
        )
        try:
            ready, _, _ = select.select([process.stderr], [], [], 3)
            self.assertTrue(ready, "file read did not start")
            self.assertEqual(process.stderr.readline(), "read-started\n")
            process.stdin.write("x")
            process.stdin.flush()
            ready, _, _ = select.select([process.stderr], [], [], 3)
            self.assertTrue(ready, "reader cancellation did not complete")
            self.assertEqual(process.stderr.readline(), "cancelled\n")
            os.write(release, b"x")
            output, errors = process.communicate(timeout=3)
            self.assertEqual(process.returncode, 0)
            self.assertIsNone(json.loads(output)["location"])
            stats = next(line for line in errors.splitlines() if line.startswith("read-stats "))
            read_calls, read_bytes = map(int, stats.split()[1:])
            self.assertGreater(read_bytes, 0, "cancellation injection did not read the file")
            self.assertEqual(read_calls, 1)
            self.assertLessEqual(read_bytes, 64 << 10)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()

    @unittest.skipUnless(BUILT_APP, "Use --built-app or ZSHELL_TEST_DERIVED_DATA for AppKit integration")
    def test_search_result_opens_unicode_line_in_the_production_editor(self):
        path = self.root / "unicode.txt"
        text = "é😀\r\nneedle\n最後"
        path.write_text(text)
        completed = self.run_probe(
            [str(self.helper), "--open-result", str(self.root), "needle"],
            timeout=12,
        )
        result = json.loads(completed.stdout)
        self.assertEqual(result["path"], str(path))
        self.assertEqual(result["line"], 2)
        self.assertEqual(result["location"], 5)
        self.assertEqual(result["selection"], 5)
        self.assertEqual(result["text"], text)
        self.assertTrue(result["hasEditor"])
        self.assertIsNone(result["unavailable"])
        self.assertFalse(result["windowVisible"])

    @unittest.skipUnless(BUILT_APP, "Use --built-app or ZSHELL_TEST_DERIVED_DATA for AppKit integration")
    def test_search_result_opens_an_oversized_file_without_loading_its_bytes(self):
        path = self.root / "oversized.txt"
        limit = 5 << 20
        with path.open("wb") as file:
            chunk = b"a\n" * (32 << 10)
            for _ in range(limit // len(chunk)):
                file.write(chunk)
            file.write(b"needle\n")
        completed = self.run_probe(
            [str(self.helper), "--open-result", str(self.root), "needle"],
            environment=self.read_environment(path, "count"), timeout=20,
        )
        result = json.loads(completed.stdout)
        self.assertGreater(path.stat().st_size, limit)
        self.assertEqual(result["path"], str(path))
        self.assertEqual(result["line"], limit // 2 + 1)
        self.assertIsNone(result["location"])
        self.assertIsNone(result["selection"])
        self.assertFalse(result["hasEditor"])
        self.assertEqual(result["text"], "")
        self.assertTrue(result["tooLarge"], result["unavailable"])
        self.assertFalse(result["windowVisible"])
        stats = next(line for line in completed.stderr.splitlines() if line.startswith("read-stats "))
        self.assertEqual(int(stats.split()[2]), 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
