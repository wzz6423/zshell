"""Exercise the production Tailscale lookup deadline with private fake CLIs.

Run: python3 -B remote/tests/test_tailscale_lookup.py --binary /path/to/zshell-server
Every status response stops before a TCP listener can bind. No Tailscale daemon,
network access, personal state, or installed Zshell instance is used.
"""

import argparse
import concurrent.futures
import os
from pathlib import Path
import shlex
import signal
import subprocess
import tempfile
import time


STOPPED = b'{"BackendState":"Stopped"}'


def probe(binary, body, output=None):
    with tempfile.TemporaryDirectory(prefix="zshell-tailnet-lookup-", dir="/tmp") as temporary:
        root = Path(temporary)
        fake = root / "tailscale"
        fake.write_text(f"#!/bin/sh\ncd {shlex.quote(str(root))} || exit 1\n{body}\n")
        fake.chmod(0o700)
        helper = root / "helper"
        helper.write_text("#!/bin/sh\n/bin/sleep 20\n:\n")
        if output is not None:
            (root / "output").write_bytes(output)
        started = time.monotonic()
        process = subprocess.Popen(
            [str(binary), "serve", "--state", str(root / "state"), "--listen",
             "tailscale://:17373", "--tailscale", str(fake)],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
            text=True, start_new_session=True,
        )
        try:
            _, error = process.communicate(timeout=8)
            return process.returncode, error.strip(), time.monotonic() - started
        finally:
            # A reaped root no longer reserves its PGID. Verify the live helper
            # by its private script before cleaning an inherited process group.
            owned = process.poll() is None
            helper_pid = root / "helper.pid"
            if not owned and helper_pid.exists():
                pid = int(helper_pid.read_text())
                identity = subprocess.run(["ps", "-p", str(pid), "-o", "pgid=,args="],
                                          capture_output=True, text=True, check=False).stdout.strip()
                fields = identity.split(None, 1)
                if len(fields) == 2:
                    arguments = shlex.split(fields[1])
                    owned = (int(fields[0]) == process.pid and len(arguments) == 2
                             and Path(arguments[0]).name == "sh" and arguments[1] == str(helper))
            if owned:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            process.wait(timeout=3)


def expect(binary, name, body, message, output=None, timed_out=False):
    code, error, elapsed = probe(binary, body, output)
    assert code != 0 and message in error, (name, code, error)
    if timed_out:
        assert 4.5 <= elapsed < 8, (name, elapsed)
    else:
        assert elapsed < 4, (name, elapsed)
    print(f"PASS {name}: {elapsed:.3f}s", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    options = parser.parse_args()
    binary = options.binary.resolve()
    assert binary.is_file(), binary

    expect(binary, "complete status drains at pipe EOF", "/bin/cat output",
           "Tailscale is not connected", STOPPED)
    expect(binary, "fragmented status drains before validation",
           "printf '{\"BackendState\":'; /bin/sleep 0.04; printf '\"Stopped\"}'",
           "Tailscale is not connected")
    for name, output in [("empty", b""), ("truncated", b'{"BackendState":'),
                         ("invalid UTF-8", b"\xff"), ("malformed", b"not JSON")]:
        expect(binary, name, "/bin/cat output", "zshell-server:", output)
    expect(binary, "nonzero exit rejects valid output", "/bin/cat output; exit 7",
           "lookup failed", STOPPED)
    expect(binary, "2 MiB output is accepted", "/bin/cat output",
           "Tailscale is not connected", STOPPED + b" " * (2 * 1024 * 1024 - len(STOPPED)))
    expect(binary, "2 MiB plus one byte is rejected", "/bin/cat output",
           "lookup failed", STOPPED + b" " * (2 * 1024 * 1024 + 1 - len(STOPPED)))
    expect(binary, "continuous output is bounded before exit",
           "while :; do printf '%8192s' ''; done", "lookup failed")
    expect(binary, "root exit with inherited stdout still times out",
           '/bin/sh "$PWD/helper" &\nprintf "%s" "$!" > helper.pid\n/bin/cat output\nexit 0',
           "lookup timed out", STOPPED, timed_out=True)
    expect(binary, "pipe EOF does not bypass root timeout",
           "/bin/cat output; exec 1>&-; exec /bin/sleep 20", "lookup timed out", STOPPED, timed_out=True)
    expect(binary, "live root and inherited stdout still time out",
           '/bin/sh "$PWD/helper" &\nprintf "%s" "$!" > helper.pid\nexec /bin/sleep 20',
           "lookup timed out", timed_out=True)

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        results = list(executor.map(lambda _: probe(binary, "/bin/cat output", STOPPED), range(12)))
    assert all(code != 0 and "Tailscale is not connected" in error and elapsed < 4
               for code, error, elapsed in results), results
    print("PASS 12 concurrent isolated lookups", flush=True)
    print("Tailscale lookup CLI: 14 passed, 0 failed; private state and jobs removed", flush=True)


if __name__ == "__main__":
    main()
