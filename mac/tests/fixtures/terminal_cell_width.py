"""Raw PTY fixture recording real window sizes, cursor reports and mouse cells."""

import fcntl
import json
import os
from pathlib import Path
import re
import signal
import struct
import sys
import termios
import tty


directory = Path(sys.argv[1])
generation = 0
resize_count = 0
mouse_enabled = False
cursor_reports = []
mouse_reports = []
pending = b""


def save(name, value):
    temporary = directory / (name + ".tmp")
    temporary.write_text(json.dumps(value))
    temporary.replace(directory / (name + ".json"))


def draw(reason="refresh"):
    global generation, resize_count
    generation += 1
    if reason == "resize":
        resize_count += 1
    rows, columns, pixel_width, pixel_height = struct.unpack(
        "HHHH", fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0" * 8)
    )
    output = (
        "\x1b[2J\x1b[H"
        "A中😀e\u0301 \x1b[6nhttps://example.com/width\r\n"
        "ASCII_COLUMNS_0123456789\r\n"
        "SELECT_ME\r\n"
        "👩🏽‍💻 한글 日本語\r\n"
        f"READY_CW_{generation}\r\n"
        + ("MOUSE_ON" if mouse_enabled else "MOUSE_OFF")
        + "\x1b[7;10H\x1b[6n"
    )
    os.write(1, output.encode())
    save("size", {"rows": rows, "columns": columns, "pixelWidth": pixel_width,
                  "pixelHeight": pixel_height, "generation": generation,
                  "resizeCount": resize_count})


saved = termios.tcgetattr(0)
try:
    tty.setraw(0)
    signal.signal(signal.SIGWINCH, lambda *_: draw("resize"))
    draw("initial")
    while True:
        data = os.read(0, 4096)
        if not data or b"\x04" in data:
            break
        pending += data
        while pending:
            cursor = re.match(rb"\x1b\[(\d+);(\d+)R", pending)
            mouse = re.match(rb"\x1b\[<(\d+);(\d+);(\d+)([Mm])", pending)
            if cursor:
                cursor_reports.append([int(cursor.group(1)), int(cursor.group(2))])
                save("cursor", cursor_reports)
                pending = pending[cursor.end():]
            elif mouse:
                mouse_reports.append([int(mouse.group(1)), int(mouse.group(2)),
                                      int(mouse.group(3)), mouse.group(4).decode()])
                save("mouse", mouse_reports)
                pending = pending[mouse.end():]
            elif pending.startswith(b"\x1b") and len(pending) < 30:
                break
            else:
                command, pending = pending[:1], pending[1:]
                if command in (b"m", b"n"):
                    mouse_enabled = command == b"m"
                    os.write(1, b"\x1b[?1000h\x1b[?1006h" if mouse_enabled
                             else b"\x1b[?1000l\x1b[?1006l")
                    draw()
                elif command == b"r":
                    draw()
finally:
    termios.tcsetattr(0, termios.TCSANOW, saved)
