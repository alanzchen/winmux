#!/usr/bin/env python3
"""Measure one macOS process without launching it or changing its configuration.

Example: python3 script/measure-idle-cpu.py --pid 1234 --output idle.json
Keep the display awake and leave the pointer and keyboard still during an idle run.
Use --mode interaction for a separately driven continuous pointer sweep; this
checks the average CPU budget and reports interval peaks without rejecting input.
100% means one fully occupied CPU core, as in Activity Monitor.
"""

import argparse
import ctypes
import json
import math
import platform
import time
from pathlib import Path


class Usage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64) for name in (
            "user", "system", "package_wakeups", "interrupt_wakeups", "pageins",
            "wired", "resident", "footprint", "start", "exit",
        )
    ]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


def cpu_percent(ticks, elapsed, numer, denom):
    if ticks < 0 or elapsed <= 0 or not math.isfinite(elapsed) or numer <= 0 or denom <= 0:
        raise ValueError("Invalid CPU counter delta, duration, or Mach timebase")
    # proc_pid_rusage CPU counters use Mach ticks, unlike getrusage's timeval.
    # Apple Silicon commonly has a 125/3 ns timebase; dividing ticks by 1e9
    # alone underreports CPU by more than 40 times.
    return ticks * numer / denom / 1e9 / elapsed * 100


def positive_number(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("must be a finite positive number")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", required=True, type=int)
    parser.add_argument("--seconds", type=positive_number, default=120)
    parser.add_argument("--interval", type=positive_number, default=5)
    parser.add_argument("--warmup", type=positive_number, default=15)
    parser.add_argument("--mode", choices=("idle", "interaction"), default="idle")
    parser.add_argument("--max-cpu", type=positive_number)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    limit = args.max_cpu if args.max_cpu is not None else (2 if args.mode == "idle" else 3)
    if platform.system() != "Darwin":
        parser.error("this sampler requires macOS")
    if args.pid <= 0 or args.seconds < args.interval:
        parser.error("PID must be positive and duration must be at least one interval")

    lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    lib.proc_pid_rusage.restype = ctypes.c_int
    lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    lib.proc_pidpath.restype = ctypes.c_int
    path = ctypes.create_string_buffer(4096)
    if lib.proc_pidpath(args.pid, path, len(path)) <= 0:
        raise OSError(ctypes.get_errno(), "Cannot read the target process path")

    clock = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    clock.mach_timebase_info.argtypes = [ctypes.POINTER(Timebase)]
    clock.mach_timebase_info.restype = ctypes.c_int
    timebase = Timebase()
    if clock.mach_timebase_info(ctypes.byref(timebase)) != 0:
        raise RuntimeError("Cannot read the Mach timebase")

    graphics = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    graphics.CGEventSourceSecondsSinceLastEventType.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    graphics.CGEventSourceSecondsSinceLastEventType.restype = ctypes.c_double
    graphics.CGMainDisplayID.restype = ctypes.c_uint32
    graphics.CGDisplayIsAsleep.argtypes = [ctypes.c_uint32]
    graphics.CGDisplayIsAsleep.restype = ctypes.c_uint32

    def sample():
        usage = Usage()
        if lib.proc_pid_rusage(args.pid, 0, ctypes.byref(usage)) != 0:
            raise OSError(ctypes.get_errno(), "Cannot read the target process CPU counters")
        return time.monotonic(), usage

    _, identity = sample()
    print(f"Warming up for {args.warmup:g}s; measuring PID {args.pid} for at least {args.seconds:g}s.", flush=True)
    time.sleep(args.warmup)
    started, initial = sample()
    previous_time, previous = started, initial
    samples = []
    # Round up to whole intervals. A short tail must not turn a single timer
    # wakeup into a false failure of the five-second CPU budget.
    for _ in range(math.ceil(args.seconds / args.interval)):
        time.sleep(args.interval)
        now, current = sample()
        if current.start != identity.start or bytes(current.uuid) != bytes(identity.uuid):
            raise RuntimeError("The target process restarted or changed executable")
        elapsed = now - previous_time
        idle_seconds = graphics.CGEventSourceSecondsSinceLastEventType(0, 0xFFFFFFFF)
        display_awake = graphics.CGDisplayIsAsleep(graphics.CGMainDisplayID()) == 0
        row = {
            "elapsed_seconds": now - started,
            "interval_seconds": elapsed,
            "cpu_percent": cpu_percent(current.user + current.system - previous.user - previous.system,
                                       elapsed, timebase.numer, timebase.denom),
            "package_wakeups_per_second": (current.package_wakeups - previous.package_wakeups) / elapsed,
            "input_idle_seconds": idle_seconds,
            "display_awake": display_awake,
            "idle": math.isfinite(idle_seconds) and idle_seconds >= elapsed and display_awake,
        }
        samples.append(row)
        print(json.dumps(row), flush=True)
        previous_time, previous = now, current

    duration = previous_time - started
    mean = cpu_percent(previous.user + previous.system - initial.user - initial.system,
                       duration, timebase.numer, timebase.denom)
    maximum = max(row["cpu_percent"] for row in samples)
    idle_valid = all(row["idle"] for row in samples)
    valid = idle_valid if args.mode == "idle" else all(row["display_awake"] for row in samples)
    passed = valid and (maximum if args.mode == "idle" else mean) < limit
    report = {
        "pid": args.pid,
        "mode": args.mode,
        "executable": path.value.decode(),
        "platform": platform.platform(),
        "timebase": {"numer": timebase.numer, "denom": timebase.denom},
        "duration_seconds": duration,
        "interval_seconds": args.interval,
        "mean_cpu_percent": mean,
        "max_interval_cpu_percent": maximum,
        "idle_run_valid": idle_valid,
        "run_valid": valid,
        "limit_percent": limit,
        "passed": passed,
        "samples": samples,
    }
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Mean {mean:.3f}%, max interval {maximum:.3f}%; {args.mode} valid={valid}; below {limit:g}%={passed}")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
