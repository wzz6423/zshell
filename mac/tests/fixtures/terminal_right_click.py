"""Raw PTY recording clipboard payloads and mouse protocols for native surfaces."""
import os
from pathlib import Path
import signal
import sys
import termios
import tty

record = Path(sys.argv[1])
record.write_bytes(b"")
mode = "plain"
bracketed = True


def draw(*_):
    controls = "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l"
    controls += "\x1b[?2004h" if bracketed else "\x1b[?2004l"
    if mode == "sgr":
        controls += "\x1b[?1002h\x1b[?1006h"
    elif mode == "legacy":
        controls += "\x1b[?1002h"
    os.write(1, (controls + "\x1b[2J\x1b[HSELECT_RIGHT_CLICK\r\n"
                 + "RIGHT_CLICK_READY_" + mode + "\r\n").encode())


saved = termios.tcgetattr(0)
try:
    tty.setraw(0)
    signal.signal(signal.SIGWINCH, draw)
    draw()
    while True:
        data = os.read(0, 4096)
        if not data or b"\x04" in data:
            break
        with record.open("ab") as stream:
            stream.write(data)
        if b"\x12" in data:
            mode = "sgr"
            draw()
        elif b"\x13" in data:
            mode = "legacy"
            draw()
        elif b"\x14" in data:
            mode = "plain"
            draw()
        elif b"\x15" in data:
            bracketed = False
            mode = "unsafe"
            draw()
finally:
    termios.tcsetattr(0, termios.TCSANOW, saved)
