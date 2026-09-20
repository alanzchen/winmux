# Idle CPU validation — 20 September 2026

The target is **less than 2% of one CPU core while idle**, including each measured
five-second interval after startup settles. This is a CPU budget, not a conversion
of Activity Monitor's Energy Impact score.

## Changes

- Native Dock visibility checks back off to once per second when its geometry and
  input are settled, including when it remains visible. Previously a visible Dock
  was checked every 150 ms indefinitely.
- The poll loop waits for its native read before choosing the next interval, so
  observed transitions receive the intended short observation burst. Cancellation
  prevents a disabled or replaced loop from scheduling another interval.
- The existing keyboard event monitor wakes polling for Command/Control chords and
  Escape. Pointer-edge checks retain their fast path. Plain typing adds no polls.
  Shortcut-heavy use can keep the faster cadence active; programmatic changes with
  no recognized event use the one-second fallback. System-consumed shortcuts also
  depend on macOS delivering them to the existing event monitor.
- Minute-only clocks use a minute-aligned timeline; clocks displaying seconds keep
  their second-aligned timeline. This covers compact, expanded, and horizontal
  clock views.

Icon artwork and badge refresh behavior remain compatible. This change does not
rewrite hover rendering or alter the Dock's appearance.

## Measurement

Native application runs used the isolated Tart macOS 26.6.2 desktop on an Apple
M2 Ultra host, with one 1024×768-point Retina virtual display, six application
windows, a visible glass WinMux Dock, and a visible native Dock on a different
edge. Startup settled for 35 seconds before measurement. CPU includes user and
system time for the complete WinMux process; 100% means one fully occupied core.
The target process was enabled and its Dock was visually verified.

The baseline was the published 0.6.329 archive, verified against its published
SHA-256. Automatic updates were disabled in the test VM, and executable version
and hash were checked before and after each accepted run. A preliminary copy
that updated itself to 0.6.330 was excluded.

The first optimized build used `deebe425` plus this fix. It was built with Xcode
in Release configuration using Swift 6.2.4, for ARM64 only. App and CLI versions
matched. The unrelated pending glass-material edit was excluded.

| Build and configuration | Duration | Mean CPU | Highest full ~5s interval |
| --- | ---: | ---: | ---: |
| Published 0.6.329, clock/badges/magnification off | 120 s | 1.17% | 2.14% |
| Optimized, same configuration | 120 s | 0.89% | 1.08% |
| Published 0.6.329, badges/clock/magnification on | 120 s | 0.87% | 1.42% |
| Optimized, same enabled features | 121 s | 1.07% | 1.36% |

After integrating the separate auto-hide change `25880e29`, the final combined
Release build also passed both configurations:

| Final combined build | Duration | Mean CPU | Highest ~5s interval |
| --- | ---: | ---: | ---: |
| Clock/badges/magnification off | 61 s | 0.94% | 1.10% |
| Badges/clock/magnification on | 61 s | 1.17% | 1.37% |

Both final runs used the complete-interval sampler; every measured interval
remained below 2%. These shorter integration runs supplement the preceding
two-minute measurements.

The enabled-feature case hides clock seconds and leaves the pointer stationary
over a Dock icon. All accepted samples reported no input during the interval and
an awake primary display. The early sampler could leave a shorter final interval;
the maxima above occurred in full intervals. The final sampler always rounds up
to complete intervals.

These are observed process measurements, not a universal hardware guarantee or
proof that every configuration improves by the same amount. The MacBook Air's
reported idle Energy Impact spike and interaction CPU spike have not been
reproduced on that physical machine. WindowServer/GPU power is outside this CPU
measurement. Physical multi-monitor and custom Dock keyboard shortcuts still need
native coverage.

## Checks and independent reviews

- Swift 6.2.4 ARM64: 31 focused tests passed, including clock boundaries, pending
  native reads, cancellation, and keyboard wake versus ordinary typing.
- Full suite after the idle fix: 965 tests, 7 opt-in tests skipped, zero failures.
- After the separate auto-hide change `25880e29` landed, the combined source passed
  979 tests, 7 skipped, zero failures, and an Xcode Release build.
- Native Cmd-Option-D checks with the final build showed WinMux's Bottom Dock
  disappearing when the native Dock was revealed and returning when it was hidden.
  Screenshots and WindowServer window lists confirmed both transitions. Control-F3
  did not reveal the native Dock in this VM, so its native delivery and Escape
  dismissal remain unverified; their polling behavior has deterministic test coverage.
- Three Python tests cover Mach-timebase conversion, one-core normalization, and
  rejection of invalid counter/clock deltas.
- Claude CLI `claude-fable-5` and agy CLI `gemini-3.8-flash-high` completed independent
  read-only reviews and targeted follow-ups. Both follow-ups reported no blocking
  findings. Accepted findings fixed the stale-state poll interval and fractional
  sampler tail; the coordinator tests cover the actual asynchronous ordering.

Raw reports, source manifests, build/test logs, configurations, screenshots and
measurements are retained under ignored `.local/reviews/idle-cpu-20260920/` and
`.local/vm-share/results/idle-cpu-20260920/`. No hosted CI or release publication
was performed.

## Repeat on the target Mac

Run the app normally with its desired settings. Keep the display awake and the
pointer and keyboard still throughout warmup and measurement. To include a
stationary hover, position the pointer over an icon before starting the command.

```sh
python3 script/measure-idle-cpu.py --pid "$(pgrep -x WinMux)" --output idle-cpu.json
```

The sampler defaults to a 15-second warmup and at least 120 seconds of complete
five-second intervals. It reads `proc_pid_rusage` counters, applies the actual
`mach_timebase_info` conversion, and does not divide by the machine's core count.
The conversion was cross-checked against `ps` total CPU time; treating raw Mach
ticks as nanoseconds is incorrect on this host's 125/3 timebase.

It exits unsuccessfully if a sampled interval reaches 2%, the process changes,
input occurs, or the primary display is asleep at a sampling endpoint. Display
state is checked at endpoints, so a sleep/wake entirely within an interval is not
detected. The JSON retains each interval and the overall average. The tool only
observes the supplied PID; it does not launch, configure, disable, or throttle the
app being measured.
