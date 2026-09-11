#!/usr/bin/env python3
"""Sample one process's physical footprint and write comparable soak results."""

import argparse
import csv
import json
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path

MIB = 1024 * 1024


def arguments():
    parser = argparse.ArgumentParser(
        description="Sample a PID with macOS footprint without launching or stopping it."
    )
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--duration", type=float, default=1800)
    parser.add_argument("--interval", type=float, default=5)
    parser.add_argument("--warmup", type=float, default=60)
    parser.add_argument("--label", default="")
    parser.add_argument("--max-growth-mib", type=float)
    parser.add_argument("--heap", action="store_true")
    parser.add_argument("--leaks", action="store_true")
    parser.add_argument("--footprint-command", default="xcrun footprint", help=argparse.SUPPRESS)
    return parser.parse_args()


def fail(message):
    print(f"memory-soak: {message}", file=sys.stderr)
    raise SystemExit(1)


def check_process(pid):
    if pid <= 1:
        fail("--pid must identify a non-system process")
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        fail(f"PID {pid} does not exist")
    except PermissionError:
        pass


def prepare_output(path):
    if path.exists() and not path.is_dir():
        fail(f"output path is not a directory: {path}")
    if path.exists() and any(path.iterdir()):
        fail(f"output directory is not empty: {path}")
    path.mkdir(parents=True, exist_ok=True)


def collect(pid, output, duration, interval, footprint_command):
    raw = output / "footprint.json"
    command = [
        *shlex.split(footprint_command), "--noCategories", "-j", str(raw),
        "--sample", str(interval), "--sample-duration", str(duration),
        "-p", str(pid),
    ]
    try:
        subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
    except FileNotFoundError:
        fail("xcrun is unavailable; install the Xcode command-line tools")
    except subprocess.CalledProcessError as error:
        fail(f"footprint exited with status {error.returncode}")
    return raw


def parse_samples(raw, pid):
    data = json.loads(raw.read_text())
    bytes_per_unit = int(data.get("bytes per unit", 1))
    rows = []
    for sample in data.get("samples", []):
        process = next(
            (item for item in sample.get("processes", []) if item.get("pid") == pid),
            None,
        )
        if process is None:
            continue
        start = sample["start_time"]
        continuous_time = start.get("mach_continuous_time_ns")
        sample_time = (
            float(continuous_time) / 1_000_000_000
            if continuous_time is not None
            else float(start["wall_time_s"])
        )
        rows.append({
            "sample_time": sample_time,
            "timestamp": start.get("date", ""),
            "footprint_bytes": int(process["footprint"]) * bytes_per_unit,
            "process_name": process.get("name", ""),
        })
    if len(rows) < 2:
        fail(f"footprint returned {len(rows)} usable samples; at least 2 are required")
    origin = rows[0]["sample_time"]
    for row in rows:
        row["elapsed_seconds"] = row["sample_time"] - origin
    return rows


def slope_per_hour(rows):
    xs = [row["elapsed_seconds"] for row in rows]
    ys = [row["footprint_bytes"] / MIB for row in rows]
    mean_x = sum(xs) / len(xs)
    mean_y = sum(ys) / len(ys)
    denominator = sum((value - mean_x) ** 2 for value in xs)
    if denominator == 0:
        return 0.0
    slope = sum((x - mean_x) * (y - mean_y) for x, y in zip(xs, ys))
    return slope / denominator * 3600


def write_csv(path, rows):
    with path.open("w", newline="") as output:
        writer = csv.DictWriter(
            output,
            fieldnames=["elapsed_seconds", "timestamp", "footprint_bytes", "footprint_mib"],
        )
        writer.writeheader()
        for row in rows:
            writer.writerow({
                "elapsed_seconds": f"{row['elapsed_seconds']:.3f}",
                "timestamp": row["timestamp"],
                "footprint_bytes": row["footprint_bytes"],
                "footprint_mib": f"{row['footprint_bytes'] / MIB:.3f}",
            })


def diagnostic(name, pid, output):
    path = output / f"{name}.txt"
    command = ["xcrun", name]
    if name == "leaks":
        command += ["--quiet", "--nostacks"]
    command.append(str(pid))
    with path.open("w") as stream:
        try:
            result = subprocess.run(
                command, stdout=stream, stderr=subprocess.STDOUT, timeout=120
            )
        except FileNotFoundError:
            return "unavailable"
        except subprocess.TimeoutExpired:
            return "timed_out"
    if result.returncode == 0:
        return "completed"
    if name == "leaks" and result.returncode == 1:
        return "findings"
    return f"failed_{result.returncode}"


def main():
    args = arguments()
    if args.interval <= 0 or args.duration < args.interval * 2 or args.warmup < 0:
        fail("duration must cover at least two positive intervals, and warmup cannot be negative")
    check_process(args.pid)
    prepare_output(args.output)
    if args.warmup:
        print(f"Warming up PID {args.pid} for {args.warmup:g}s...", flush=True)
        time.sleep(args.warmup)
        check_process(args.pid)
    raw = collect(args.pid, args.output, args.duration, args.interval, args.footprint_command)
    rows = parse_samples(raw, args.pid)
    minimum_coverage = max(0, args.duration - args.interval * 1.1)
    if rows[-1]["elapsed_seconds"] < minimum_coverage:
        fail(
            f"footprint covered only {rows[-1]['elapsed_seconds']:.1f}s "
            f"of the requested {args.duration:g}s"
        )
    values = [row["footprint_bytes"] for row in rows]
    growth_mib = (values[-1] - values[0]) / MIB
    diagnostics = {}
    if args.heap:
        diagnostics["heap"] = diagnostic("heap", args.pid, args.output)
    if args.leaks:
        diagnostics["leaks"] = diagnostic("leaks", args.pid, args.output)
    summary = {
        "schema_version": 1,
        "label": args.label,
        "pid": args.pid,
        "process_name": rows[0]["process_name"],
        "sample_count": len(rows),
        "requested_duration_seconds": args.duration,
        "actual_duration_seconds": rows[-1]["elapsed_seconds"],
        "interval_seconds": args.interval,
        "warmup_seconds": args.warmup,
        "first_footprint_mib": values[0] / MIB,
        "last_footprint_mib": values[-1] / MIB,
        "minimum_footprint_mib": min(values) / MIB,
        "peak_footprint_mib": max(values) / MIB,
        "net_growth_mib": growth_mib,
        "linear_slope_mib_per_hour": slope_per_hour(rows),
        "diagnostics": diagnostics,
    }
    write_csv(args.output / "samples.csv", rows)
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    failed_diagnostic = any(
        status not in {"completed", "findings"} for status in diagnostics.values()
    )
    if failed_diagnostic:
        return 1
    if args.max_growth_mib is not None and growth_mib > args.max_growth_mib:
        print(f"memory-soak: growth exceeded {args.max_growth_mib:g} MiB", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
