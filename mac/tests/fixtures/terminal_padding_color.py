"""Draw controlled edge backgrounds through a real, raw PTY."""

import fcntl
import json
import os
from pathlib import Path
import signal
import struct
import sys
import termios
import tty


directory = Path(sys.argv[1])
if "--per-process" in sys.argv:
    directory /= str(os.getpid())
    directory.mkdir()
generation = 0
mode = "solid"
colors = ((180, 45, 35), (35, 140, 55), (50, 65, 180), (175, 120, 30),
          (145, 45, 150), (35, 145, 150))


def cursor(row, column=1):
    return f"\x1b[{row};{column}H"


def background(color):
    return "\x1b[48;2;" + ";".join(map(str, color)) + "m"


def draw_frame():
    global generation
    generation += 1
    rows, columns, _, _ = struct.unpack(
        "HHHH", fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0" * 8)
    )
    if rows < 4 or columns < 16:
        return
    output = "\x1b[?1049l\x1bc\x1b[?2026h\x1b[?25l"
    if mode == "alternate":
        output += "\x1b]133;A\x07\x1b[?1049h"
    for row in range(rows):
        pair = colors[:2] if row == 0 else colors[4:] if row == rows - 1 else colors[2:4]
        if mode == "default":
            output += cursor(row + 1) + "\x1b[0m" + " " * columns
            continue
        output += (cursor(row + 1) + background(pair[0]) + " " * (columns // 2)
                   + background(pair[1]) + " " * (columns - columns // 2))
    if mode == "mixed":
        for row in (1, rows):
            output += cursor(row, columns // 2) + "\x1b[49m "
    elif mode == "blank":
        output += cursor(rows) + "\x1b[0m\x1b[2K"
    elif mode == "powerline":
        for row, color, character in ((1, colors[0], "\ue0b0"), (rows, colors[4], "\ue0d4")):
            output += cursor(row, 5) + background(color) + character
    elif mode == "prompt":
        output += cursor(1) + "\x1b]133;A\x07" + background(colors[0]) + " "
        output += cursor(rows) + "\x1b]133;P\x07" + background(colors[4]) + " "
    elif mode in ("continuation", "input", "fish"):
        output += cursor(rows - 1) + "\x1b]133;A\x07"
        if mode == "input":
            output += "\x1b]133;B\x07"
        output += background(colors[2]) + " " * columns + "\r\n"
        if mode == "fish":
            output += "\x1b]133;C\x07"
        output += (background(colors[4]) + " " * (columns // 2)
                   + background(colors[5]) + " " * (columns - columns // 2))
    elif mode == "inverse":
        for row, pair in ((1, colors[:2]), (rows, colors[4:])):
            output += (cursor(row) + "\x1b[38;2;50;180;180m\x1b[7m"
                       + background(pair[0]) + " " * (columns // 2)
                       + background(pair[1]) + " " * (columns - columns // 2) + "\x1b[27m")
    elif mode == "alternate":
        output += cursor(1) + "\x1b]133;A\x07" + background(colors[0]) + " "
    elif mode == "dynamic":
        output += "\x1b]11;rgb:10/70/90\x07"
    elif mode == "dynamic-reset":
        output += "\x1b]111\x07"
    elif mode == "selection":
        output += cursor(1) + background(colors[0]) + "SELECT"
    output += (cursor(2, 5) + "\x1b[0m \x1b]2;PADDING_READY_"
               + str(generation) + "\x07\x1b[?2026l")
    os.write(1, output.encode())
    temporary = directory / "frame.tmp"
    temporary.write_text(json.dumps({"rows": rows, "columns": columns,
                                     "generation": generation, "mode": mode, "pid": os.getpid()}))
    temporary.replace(directory / "frame.json")


def draw():
    # Split-layout resize bursts must not reenter the same frame transaction.
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGWINCH})
    try:
        draw_frame()
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


saved = termios.tcgetattr(0)
commands = {b"s": "solid", b"d": "default", b"m": "mixed", b"b": "blank",
            b"p": "powerline", b"o": "prompt", b"c": "continuation", b"i": "input",
            b"f": "fish", b"a": "alternate", b"v": "inverse",
            b"y": "dynamic", b"z": "dynamic-reset", b"q": "selection"}
try:
    tty.setraw(0)
    signal.signal(signal.SIGWINCH, lambda *_: draw())
    draw()
    while True:
        data = os.read(0, 4096)
        if not data or b"\x04" in data:
            break
        for command in data:
            if bytes([command]) in commands:
                mode = commands[bytes([command])]
                draw()
finally:
    termios.tcsetattr(0, termios.TCSANOW, saved)
