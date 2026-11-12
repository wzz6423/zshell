"""A real PTY consumer for terminal scrollback, cursor keys and mouse reports."""

import json
import os
from pathlib import Path
import select
import sys
import termios
import tty


root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
inbox = root / "command.json"
received = root / "input"
acknowledged = root / "ack"
saved = termios.tcgetattr(0)
mode = "normal"
last_command = None


def change_mode(value):
    global mode
    os.write(1, b"\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?1l\x1b[?1049l")
    if value == "normal":
        os.write(1, b"\x1b[2J\x1b[H")
        os.write(1, b"".join(f"ROW-{row:04d}\r\n".encode() for row in range(600)))
        os.write(1, b"SCROLL_READY")
    else:
        os.write(1, b"\x1b[?1049h\x1b[?1007h\x1b[2J\x1b[H")
        if value in ("mouse", "legacy"):
            os.write(1, b"\x1b[?1000h")
        if value == "mouse":
            os.write(1, b"\x1b[?1006h")
        if value == "application":
            os.write(1, b"\x1b[?1h")
        os.write(1, ("SCROLL_READY " + value).encode())
    mode = value


try:
    tty.setraw(0)
    received.write_bytes(b"")
    change_mode("normal")
    (root / "started").write_text(str(os.getpid()))
    while True:
        if inbox.is_file():
            try:
                command = json.loads(inbox.read_text())
            except (json.JSONDecodeError, OSError):
                command = None
            if command and command["id"] != last_command:
                if command["operation"] == "mode":
                    change_mode(command["value"])
                elif command["operation"] == "clear":
                    received.write_bytes(b"")
                elif command["operation"] == "quit":
                    break
                last_command = command["id"]
                acknowledged.write_text(last_command)
        if select.select([0], [], [], 0.01)[0]:
            data = os.read(0, 65536)
            if not data:
                break
            with received.open("ab") as stream:
                stream.write(data)
finally:
    termios.tcsetattr(0, termios.TCSADRAIN, saved)
