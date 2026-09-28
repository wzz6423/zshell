"""Small PTY input fixture; the filename exercises the real agent recognition path."""

import codecs
import os
import re
import select
import signal
import sys
import time
import tty
import unicodedata


signal.signal(signal.SIGTTOU, signal.SIG_IGN)
if os.getpid() != os.getpgrp():
    os.setpgid(0, 0)
os.tcsetpgrp(0, os.getpgrp())
tty.setraw(0)

text = "0123456789abcdefghij"
cursor = len(text)
finish_at = None
decoder = codecs.getincrementaldecoder("utf-8")()
pending = ""
sequences = ("\x1b[D", "\x1b[C", "\x1b[A", "\x1b[B", "\x1b[3~", "\x1b[200~", "\x1b[201~")


def draw():
    rule = "─" * os.get_terminal_size().columns
    rows = text.split("\n")
    output = f"\x1b[2J\x1b[H{rule}\x1b[2;1H❯ "
    for index, row in enumerate(rows):
        # A TUI can leave erased cells for indentation and spaces instead of
        # printing literal spaces. Text reads must preserve those columns.
        output += f"\x1b[{index + 2};3H" + re.sub(r" +", lambda match: f"\x1b[{len(match[0])}C", row)
    prefix = text[:cursor].split("\n")
    column = sum(2 if unicodedata.east_asian_width(char) in ("W", "F") else 1 for char in prefix[-1])
    output += f"\x1b[{len(rows) + 2};1H{rule}\x1b[{len(prefix) + 1};{column + 3}H"
    sys.stdout.write(output)
    sys.stdout.flush()


draw()
while True:
    ready, _, _ = select.select([0], [], [], 0.005)
    if finish_at is not None and time.monotonic() >= finish_at:
        sys.stdout.write("\x1b[?2026l")
        sys.stdout.flush()
        finish_at = None
    if not ready:
        continue
    data = os.read(0, 4096)
    if not data or b"\x03" in data:
        break
    pending += decoder.decode(data)
    while pending:
        sequence = next((value for value in sequences if pending.startswith(value)), None)
        if sequence:
            pending = pending[len(sequence):]
            if sequence == "\x1b[D":
                cursor = max(0, cursor - 1)
            elif sequence == "\x1b[C":
                cursor = min(len(text), cursor + 1)
            elif sequence in ("\x1b[A", "\x1b[B"):
                rows = text.split("\n")
                prefix = text[:cursor].split("\n")
                row = max(0, min(len(rows) - 1, len(prefix) - 1 + (-1 if sequence == "\x1b[A" else 1)))
                cursor = sum(len(value) + 1 for value in rows[:row]) + min(len(prefix[-1]), len(rows[row]))
            elif sequence == "\x1b[3~":
                text = text[:cursor] + text[cursor + 1:]
            continue
        if any(value.startswith(pending) for value in sequences):
            break
        char, pending = pending[0], pending[1:]
        if char == "\x12":
            text = "0123456789abcdefghij"
            cursor = len(text)
        elif char in ("\x0e", "\x0f", "\x10"):
            text = {"\x0e": "first line\nsecond line\nthird line", "\x0f": "first line\n\nthird line", "\x10": "ab  cd"}[char]
            cursor = len(text)
        elif char == "\x11":
            text = "中文  cd"
            cursor = len(text)
        elif char == "\x14":
            sys.stdout.write("\x1b[?2026h")
            sys.stdout.flush()
            finish_at = time.monotonic() + 0.1
        elif char == "\x7f":
            if cursor:
                text = text[:cursor - 1] + text[cursor:]
                cursor -= 1
        elif char >= " ":
            text = text[:cursor] + char + text[cursor:]
            cursor += 1
    draw()
