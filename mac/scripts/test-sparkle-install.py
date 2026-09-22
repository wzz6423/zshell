#!/usr/bin/env python3
"""Exercise real Sparkle installation/relaunch in a disposable app, never production Zshell."""

from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import argparse
import json
import os
import platform
import plistlib
import shutil
import subprocess
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
FRAMEWORKS = ROOT / "mac/Vendor/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
ENV = dict(os.environ)
if "DEVELOPER_DIR" not in ENV and Path("/Applications/Xcode-beta.app/Contents/Developer").is_dir():
    ENV["DEVELOPER_DIR"] = "/Applications/Xcode-beta.app/Contents/Developer"


def run(*arguments, **kwargs):
    return subprocess.check_output([str(arg) for arg in arguments], env=ENV, stderr=subprocess.STDOUT, **kwargs).decode().strip()


def appcast_tool():
    configured = os.environ.get("SPARKLE_BIN")
    if configured and (Path(configured) / "generate_appcast").is_file():
        return Path(configured) / "generate_appcast"
    on_path = shutil.which("generate_appcast")
    if on_path:
        return Path(on_path)
    hits = list((Path.home() / "Library/Developer/Xcode/DerivedData").glob(
        "*/SourcePackages/artifacts/*/Sparkle/bin/generate_appcast"))
    if not hits:
        raise RuntimeError("Set SPARKLE_BIN to the directory containing generate_appcast")
    return hits[0]


def main(automatic=False):
    generator = appcast_tool()
    bundle_id = "sh.zshell.sparkle-install-test." + uuid.uuid4().hex
    with tempfile.TemporaryDirectory(prefix="zshell-sparkle-install-") as temporary:
        root = Path(temporary)
        served = root / "served"
        served.mkdir()
        requests = []

        class Handler(SimpleHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                requests.append(self.path)
                super().do_GET()

        server = ThreadingHTTPServer(("127.0.0.1", 0), partial(Handler, directory=str(served)))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        process = None
        try:
            executable = root / "Fixture"
            run("xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-target", f"{platform.machine()}-apple-macos15.6",
                "-F", FRAMEWORKS, "-framework", "Sparkle", "-Xlinker", "-rpath", "-Xlinker",
                "@executable_path/../Frameworks", "-Xlinker", "-rpath", "-Xlinker", FRAMEWORKS,
                ROOT / "mac/tests/SparkleInstallFixture.swift", "-o", executable)
            key_file = root / "test-key.txt"
            public_key = run(executable, "--generate-test-key", key_file)
            key_file.chmod(0o600)
            prefix = f"http://127.0.0.1:{server.server_port}/"

            def make_bundle(destination, build):
                contents = destination / "Contents"
                (contents / "MacOS").mkdir(parents=True)
                shutil.copy2(executable, contents / "MacOS/Fixture")
                shutil.copytree(FRAMEWORKS / "Sparkle.framework", contents / "Frameworks/Sparkle.framework", symlinks=True)
                info = {
                    "CFBundleExecutable": "Fixture", "CFBundleIdentifier": bundle_id,
                    "CFBundleInfoDictionaryVersion": "6.0", "CFBundleName": "Sparkle Install Fixture",
                    "CFBundlePackageType": "APPL", "CFBundleShortVersionString": f"0.0.{build}",
                    "CFBundleVersion": build, "LSMinimumSystemVersion": "15.6", "LSUIElement": True,
                    "SUFeedURL": prefix + "appcast.xml", "SUPublicEDKey": public_key,
                    "SUEnableAutomaticChecks": automatic, "SUAutomaticallyUpdate": automatic,
                    "SURequireSignedFeed": True, "ZshellTestAutomatic": automatic,
                    "SUVerifyUpdateBeforeExtraction": True, "ZshellTestRoot": str(root),
                }
                (contents / "Info.plist").write_bytes(plistlib.dumps(info))
                run("/usr/bin/codesign", "--force", "--deep", "--sign", "-", destination)

            installed = root / "installed/Sparkle Install Fixture.app"
            update = root / "staged/Sparkle Install Fixture.app"
            make_bundle(installed, "1")
            make_bundle(update, "2")
            archive = served / "fixture-update.zip"
            run("/usr/bin/ditto", "-c", "-k", "--keepParent", update, archive)
            tool_env = dict(ENV, CFFIXED_USER_HOME=str(root / "tool-home"))
            (root / "tool-home").mkdir()
            subprocess.run([str(generator), "--ed-key-file", str(key_file), "--download-url-prefix", prefix, str(served)],
                           env=tool_env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=True)
            print("Prepared independent signed appcast and update ZIP", flush=True)
            with (root / "fixture.log").open("w") as log:
                process = subprocess.Popen([str(installed / "Contents/MacOS/Fixture")], env=ENV, stdout=log, stderr=log)
                old_pid = process.pid
                relaunched_after_quit = False
                deadline = time.monotonic() + 120
                while time.monotonic() < deadline:
                    marker = root / "relaunched.json"
                    events_file = root / "events.jsonl"
                    events = [json.loads(line) for line in events_file.read_text().splitlines()] if events_file.exists() else []
                    errors = [event for event in events if event["stage"] == "error"]
                    if errors:
                        raise RuntimeError(f"Sparkle error: {errors}; stages: {events}; log: {(root / 'fixture.log').read_text()}")
                    if automatic and not relaunched_after_quit and process.poll() is not None:
                        installed_info = installed / "Contents/Info.plist"
                        if installed_info.exists() and plistlib.loads(installed_info.read_bytes())["CFBundleVersion"] == "2":
                            process = subprocess.Popen([str(installed / "Contents/MacOS/Fixture")], env=ENV, stdout=log, stderr=log)
                            relaunched_after_quit = True
                    if marker.exists():
                        result = json.loads(marker.read_text())
                        assert result["build"] == "2" and result["pid"] != old_pid, result
                        assert Path(result["bundle"]).resolve() == installed.resolve(), result
                        assert result["architecture"] == platform.machine(), result
                        assert any(event["stage"] == "signedFeedAccepted" for event in events), events
                        assert any(event["stage"] == "ready" for event in events), events
                        if automatic:
                            assert any(event["stage"] == "automaticDownload" for event in events), events
                            assert any(event["stage"] == "quitForAutomaticInstall" for event in events), events
                        assert "/appcast.xml" in requests and "/fixture-update.zip" in requests, requests
                        assert plistlib.loads((installed / "Contents/Info.plist").read_bytes())["CFBundleVersion"] == "2"
                        run("/usr/bin/codesign", "--verify", "--deep", "--strict", installed)
                        # Wait for the relaunched fixture to finish flushing its test preferences.
                        exit_deadline = time.monotonic() + 10
                        while time.monotonic() < exit_deadline:
                            if result["pid"] == process.pid and process.poll() is not None:
                                break
                            try:
                                os.kill(result["pid"], 0)
                            except ProcessLookupError:
                                break
                            time.sleep(0.05)
                        else:
                            raise RuntimeError("Relaunched fixture did not exit")
                        mode = "automatic download + install on quit" if automatic else "manual update"
                        print(f"Sparkle installer fixture E2E: 1 passed, 0 failed ({mode}, signed feed + ZIP, in-place install, relaunch, architecture, codesign)", flush=True)
                        return
                    time.sleep(0.1)
                raise RuntimeError(f"Timed out; stages: {events}; log: {(root / 'fixture.log').read_text()}")
        finally:
            if process and process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
            # Only this random test identity is removed; production preferences are untouched.
            subprocess.run(["/usr/bin/defaults", "delete", bundle_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            shutil.rmtree(Path.home() / "Library/Caches" / bundle_id, ignore_errors=True)
            (Path.home() / "Library/Preferences" / f"{bundle_id}.plist").unlink(missing_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--automatic", action="store_true", help="Verify background download and installation on normal quit")
    arguments = parser.parse_args()
    try:
        main(arguments.automatic)
    except subprocess.CalledProcessError as error:
        print(error.output.decode() if isinstance(error.output, bytes) else error.output)
        raise
