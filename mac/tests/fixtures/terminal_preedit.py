"""Draw Unicode controls and record every byte received from the real PTY."""

import fcntl
import json
import os
from pathlib import Path
import select
import signal
import struct
import sys
import termios
import tty


directory = Path(sys.argv[1])
generation = 0
last_control = None
received = bytearray()
resized = False


def resize(*_):
    global resized
    resized = True


def draw(*_):
    global generation
    control = json.loads((directory / "control.json").read_text())
    rows, columns, _, _ = struct.unpack("HHHH", fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0" * 8))
    generation += 1
    output = "\x1b[?2027h\x1b[?25h\x1b[2J"
    for row, text in enumerate(control["samples"], start=1):
        output += f"\x1b[{row};3H" + text
    preedit_row = len(control["samples"]) + 2
    column = columns if control.get("edge") else 3
    output += f"\x1b[{rows};1HPREEDIT_READY_{generation}\x1b[{preedit_row};{column}H"
    os.write(1, output.encode())
    temporary = directory / "size.tmp"
    temporary.write_text(json.dumps({"rows": rows, "columns": columns, "generation": generation,
                                    "preeditRow": preedit_row - 1, "cursorColumn": column - 1}))
    temporary.replace(directory / "size.json")


saved = termios.tcgetattr(0)
try:
    tty.setraw(0)
    signal.signal(signal.SIGWINCH, resize)
    (directory / "received.bin").write_bytes(b"")
    while True:
        control = (directory / "control.json").read_bytes()
        if control != last_control or resized:
            last_control = control
            resized = False
            draw()
        ready, _, _ = select.select([0], [], [], 0.02)
        if not ready:
            continue
        data = os.read(0, 4096)
        if not data or b"\x04" in data:
            break
        received.extend(data)
        (directory / "received.bin").write_bytes(received)
finally:
    termios.tcsetattr(0, termios.TCSANOW, saved)
