"""Lock Ghostty precise trackpad scrolling to pixels without building the app.

python3 -B mac/tests/test_terminal_scroll_scale.py
"""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]


def function_body(source, signature):
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise AssertionError(f"unclosed {signature}")


def compact(source):
    return "".join(source.split())


view = (ROOT / "mac/zshell/ZshellTerminalView.swift").read_text()
settings = (ROOT / "mac/zshell/TerminalScrollSettings.swift").read_text()
scroll = function_body(view, "    override func scrollWheel(with event: NSEvent)")
conversion = function_body(settings, "    static func ghosttyPrecisePixels(")
collapsed = compact(scroll)

if "let scale = backingScale.isFinite && backingScale > 0 ? backingScale : 1" not in conversion:
    raise SystemExit("precise pixel conversion does not fall back to scale 1")
if "return points * scale" not in conversion:
    raise SystemExit("precise pixel conversion does not multiply by the backing scale")
if "ghosttyPrecisePixels" in function_body(view, "    func sendApplicationScroll(lines: Int)"):
    raise SystemExit("application scroll already sends pixels and must not scale again")

vertical = (
    "precise"
    "?TerminalScrollSettings.ghosttyPrecisePixels(event.scrollingDeltaY,backingScale:backingScale)"
    ":event.scrollingDeltaY"
)
if vertical not in collapsed:
    raise SystemExit("precise vertical deltas are not scaled before the pixel clamp")
horizontal = (
    "letpointCellWidth=Double(grid.cellWidthPixels)"
    "/TerminalScrollSettings.ghosttyPrecisePixels(1,backingScale:backingScale)"
)
if horizontal not in collapsed or "event.scrollingDeltaX/pointCellWidth" not in collapsed:
    raise SystemExit("horizontal accumulation does not divide points by the point cell width")
if "x=Double(columns)*Double(grid.cellWidthPixels)" not in collapsed:
    raise SystemExit("horizontal scroll does not send pixel columns")

else_at = scroll.index("} else {")
wheel = scroll[else_at:scroll.index("let momentum", else_at)]
if "ghosttyPrecisePixels" in wheel or "backingScale" in wheel:
    raise SystemExit("wheel ticks must not be multiplied by the backing scale")
if "event.scrollingDeltaX.rounded()" not in wheel:
    raise SystemExit("discrete horizontal ticks changed")

with tempfile.TemporaryDirectory(prefix="zshell-scroll-scale-", dir="/tmp") as directory:
    temporary = Path(directory)
    binary = temporary / "terminal-scroll-scale"
    subprocess.run(
        [
            "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
            "-module-cache-path", str(temporary / "ModuleCache"),
            str(ROOT / "mac/zshell/TerminalScrollSettings.swift"),
            str(ROOT / "mac/tests/TerminalScrollScaleProbe.swift"),
            "-o", str(binary),
        ],
        cwd=ROOT,
        check=True,
        timeout=90,
    )
    completed = subprocess.run([str(binary)], cwd=ROOT, check=True, timeout=15, text=True, capture_output=True)

required = (
    "PASS scale 2 turns one point-cell width into one pixel-cell",
    "PASS scale 2 turns one point-cell height into one pixel-cell",
    "PASS scale 1 is identity for 1.0",
    "PASS wheel tick is not multiplied",
    "PASS a precise tick-sized point delta is scaled",
    "PASS horizontal wheel tick is not multiplied",
    "PASS one horizontal point-cell sends one pixel-cell",
    "PASS one vertical point-cell survives the pixel clamp",
    "terminal scroll scale checks passed",
)
for line in required:
    if line not in completed.stdout:
        raise SystemExit(f"missing probe result: {line}\n{completed.stdout}")
print(completed.stdout, end="")
