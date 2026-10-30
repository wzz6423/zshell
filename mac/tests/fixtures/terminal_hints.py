"""Raw PTY fixture: deterministic visible hints, resize and exact input recording."""
import os
from pathlib import Path
import signal
import re
import sys
import termios
import tty

record = Path(sys.argv[1])
record.write_bytes(b"")
state = "screen"
long_url = "https://example.com/" + "segment/" * 16 + "end"
needs_cursor_report = True


def draw(*_):
    global needs_cursor_report
    if state == "history":
        output = "\x1b[?1049l\x1b[3J\x1b[2J\x1b[H" + "".join(
            ("https://history.example/old" if index == 5 else f"history row {index}") + "\r\n"
            for index in range(90)
        ) + "READY_HISTORY\r\n"
    else:
        cursor_query = "\x1b[6n" if needs_cursor_report else ""
        needs_cursor_report = False
        output = "\x1b[2J\x1b[H" + "\r\n".join([
            "中中 éé e\u0301 👩🏽‍💻 😀 " + cursor_query + "https://example.com/unicode",
            "https://example.com/first https://example.com/second",
            "./Sources/main.swift:42:7 main.swift:12:3",
            "192.168.1.2 2001:db8::1 deadbee",
            "https://changed.example/new" if state == "changed" else long_url,
            " ".join(f"/tmp/hint-{index}" for index in range(38)),
            "READY_HINTS",
        ]) + "\r\n"
    os.write(1, output.encode())


saved = termios.tcgetattr(0)
try:
    tty.setraw(0)
    signal.signal(signal.SIGWINCH, draw)
    draw()
    while True:
        data = os.read(0, 4096)
        if not data or b"\x04" in data:
            break
        def cursor_position(match):
            record.with_suffix(".cursor").write_bytes(match.group(1))
            return b""
        data = re.sub(rb"\x1b\[(\d+;\d+)R", cursor_position, data)
        if not data:
            continue
        with record.open("ab") as stream:
            stream.write(data)
        if b"\x12" in data:
            state = "screen"
            draw()
        elif b"\x13" in data:
            state = "history"
            draw()
        elif b"\x14" in data:
            state = "screen"
            os.write(1, b"\x1b[?1049h")
            draw()
        elif b"\x15" in data:
            state = "changed"
            draw()
finally:
    termios.tcsetattr(0, termios.TCSANOW, saved)
