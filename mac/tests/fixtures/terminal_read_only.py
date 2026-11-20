"""Record real PTY input while a separate control file drives terminal output."""

import json
import os
from pathlib import Path
import select
import signal
import sys
import time
import tty


root = Path(sys.argv[1])
signal.signal(signal.SIGTTOU, signal.SIG_IGN)
if os.getpid() != os.getpgrp():
    os.setpgid(0, 0)
os.tcsetpgrp(0, os.getpgrp())
tty.setraw(0)
record = os.open(root / "input.bin", os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
sequence = -1
mode = "plain"
stream_remaining = 0
tick = 0
next_tick = 0


def output(value):
    os.write(1, value.encode("utf-8"))


def acknowledge():
    temporary = root / "state.pending"
    temporary.write_text(json.dumps({"sequence": sequence, "mode": mode, "tick": tick}))
    temporary.replace(root / "state.json")


def set_mode(value):
    global mode
    output("\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?1004l\x1b[<u")
    if mode == "capture" and value != "capture":
        output("\x1b[?1049l")
    if value == "capture":
        if mode != "capture":
            output("\x1b[?1049h")
        output("\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h\x1b[?1004h")
    if value == "keys":
        output("\x1b[>31u")
    output("\x1b[?2004l\x1b[2J\x1b[HSELECT_READ_ONLY_你好\r\nhttps://example.com/lock\r\n")
    output("READ_ONLY_READY_" + value + "\r\n")
    mode = value


set_mode("plain")
acknowledge()
deadline = time.monotonic() + 180
try:
    while time.monotonic() < deadline:
        readable, _, _ = select.select([0], [], [], 0.005)
        if readable:
            data = os.read(0, 65536)
            if not data:
                break
            os.write(record, data)
        try:
            command = json.loads((root / "control.json").read_text())
        except (OSError, ValueError):
            command = None
        if command is not None and command["sequence"] != sequence:
            sequence = command["sequence"]
            action = command["action"]
            if action in ("plain", "capture", "keys"):
                set_mode(action)
            elif action == "query":
                output("\x1b[6n\x1b[c\x1b[>c\x1b]10;?\x1b\\\x1b[18t")
            elif action == "lines":
                for index in range(120):
                    output(f"READ_ONLY_SCROLL_{index:03d}\r\n")
            elif action == "output":
                output("READ_ONLY_OUTPUT_CONTINUES\r\n")
            elif action == "stream":
                stream_remaining = 15
                next_tick = time.monotonic()
            elif action == "exit":
                acknowledge()
                break
            acknowledge()
        if stream_remaining and time.monotonic() >= next_tick:
            tick += 1
            stream_remaining -= 1
            output(f"READ_ONLY_STREAM_{tick}\r\n")
            next_tick = time.monotonic() + 0.03
            acknowledge()
finally:
    os.close(record)
