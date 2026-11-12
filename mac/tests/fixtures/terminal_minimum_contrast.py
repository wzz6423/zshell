"""Raw ANSI fixture for native minimum-contrast rendering and visible acceptance."""

import base64
import fcntl
import os
import signal
import struct
import termios
import tty


def draw(*_):
    size_rows, columns, _, _ = struct.unpack("HHHH", fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0" * 8))
    if size_rows < 18 or columns < 12:
        return
    output = "\x1b[2J\x1b[H\x1b[?25l"
    colors = (
        "38;2;24;24;24;48;2;0;0;0", "38;2;102;102;102;48;2;0;0;0",
        "38;2;255;255;255;48;2;0;0;0", "38;2;0;0;0;48;2;24;24;24;7",
        "38;2;24;24;24;48;2;0;0;0;1", "38;2;85;85;85;48;2;0;0;0;2",
        "38;2;24;24;24;48;2;0;0;0;8",
    )
    for row, sgr in enumerate(colors, 1):
        output += f"\x1b[{row};1H\x1b[0;{sgr}mMMMMMM\x1b[0m"
    output += "\x1b[8;1H\x1b[38;2;24;24;24;48;2;0;0;0m中文 é é\x1b[0m"
    output += "\x1b[9;1H\x1b[38;2;24;24;24;48;2;0;0;0m😀🌈\x1b[0m"
    rgba = base64.b64encode(bytes((24, 24, 26, 255)) * 16).decode()
    output += f"\x1b[10;1H\x1b_Ga=T,f=32,s=4,v=4,c=8,r=2,i=7,p=1,q=2;{rgba}\x1b\\"
    output += "\x1b[13;1HCONTRAST_READY"
    output += "\x1b]4;0;#000000;8;#181818\x1b\\"
    output += "\x1b[16;1H\x1b[90;40mMMMMMM\x1b[0m"
    output += "\x1b[17;1H\x1b[38;5;232;48;5;16mMMMMMM\x1b[0m"
    output += "\x1b[15;1H\x1b[38;2;85;85;85;48;2;0;0;0mCU SOR\x1b[0m\x1b[15;3H\x1b[2 q\x1b[?25h"
    pending = output.encode()
    while pending:
        pending = pending[os.write(1, pending):]


saved = termios.tcgetattr(0)
try:
    tty.setraw(0)
    signal.signal(signal.SIGWINCH, draw)
    draw()
    while True:
        data = os.read(0, 4096)
        if not data or b"\x04" in data:
            break
        if b"r" in data:
            draw()
finally:
    termios.tcsetattr(0, termios.TCSANOW, saved)
