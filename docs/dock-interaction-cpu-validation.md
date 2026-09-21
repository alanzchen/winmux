# Dock interaction CPU validation — September 20, 2026

For the subsequent native-renderer implementation and new measurements, see
[native Dock performance](native-dock-performance.md). This page records the
published 0.6.332 baseline and its original input generator.

**The published 0.6.332 app does not meet the requested under-3% average CPU
budget during continuous cursor movement over the Dock.** The earlier idle
measurements do not establish active-interaction performance.

## Primary measurement

These runs used a fresh app process for each Dock position and did not inspect
the app's accessibility tree before or during measurement. Coordinates came from
an earlier geometry check; screenshots verified the visible Dock and magnification.
Each run settled for 25 seconds and then warmed up with cursor movement for 10
seconds. Glass, 1.5× magnification, badges, and a minute-only clock were enabled.

| Configuration | Duration | Mean CPU | Highest ~5 s interval | Actual movement events/s |
| --- | ---: | ---: | ---: | ---: |
| Left Dock | 60.16 s | 25.20% | 26.39% | 29.9 |
| Bottom Dock | 60.18 s | 25.36% | 26.43% | 30.3 |

100% means one fully occupied CPU core, as in Activity Monitor. These numbers
are WinMux process user plus system CPU time divided by elapsed time, not
Energy Impact, layout milliseconds, machine-wide utilization, or a frame-rate
estimate. WindowServer, GPU work, and the separate input generator are excluded.

## Controlled comparisons

The following exploratory runs inspected the app's accessible icon bounds once
before measurement and once during the run. They are listed separately because
accessibility inspection can activate additional SwiftUI accessibility updates.
The primary measurements above remove that intervention. Except for the bundled
defaults rows, clock and badges remained enabled throughout the comparisons.

| Configuration | Duration | Mean CPU | Highest ~5 s interval | Actual movement events/s |
| --- | ---: | ---: | ---: | ---: |
| Left, glass, magnification on | 60.17 s | 31.72% | 33.42% | 30.2 |
| Bottom, glass, magnification on | 60.15 s | 32.57% | 33.66% | 30.2 |
| Left, glass, magnification off | 60.11 s | 3.08% | 3.58% | 28.1 |
| Bottom, glass, magnification off | 60.25 s | 4.59% | 5.52% | 27.2 |
| Left, solid, magnification on | 60.18 s | 25.70% | 27.71% | 29.3 |
| Bottom, solid, magnification on | 60.15 s | 28.87% | 30.79% | 29.7 |
| Left, bundled defaults | 60.20 s | 4.92% | 5.99% | 27.5 |
| Bottom, bundled defaults | 60.17 s | 6.93% | 7.54% | 27.5 |

Bundled defaults disable magnification, badges, and the clock. The bottom-defaults
case changes only Dock position. Geometry checks confirmed six 48-point app icons
with magnification disabled and changing icon sizes up to approximately 72 points
when enabled. Changing the material to solid does not meet the 3% target either.
These are individual observed runs, not a statistical estimate of all workloads.

## Provenance and method

- Public, signed, notarized 0.6.332 release, source
  `d7f03ca172357477c7405d6d34a0d586baf8449b`; no product source changes.
- App SHA-256: `db386f1e98cd70b8bb7e370cad505dba1f607f06ffa65bb41528e7a28b7efb0e`.
- Embedded CLI SHA-256: `31e654e7c1ab3ad1c8d55db51471dac7a2526e464674d3ac0ae6fcd2eb61a230`.
- Hashes matched the downloaded release and remained unchanged after every phase.
  Automatic updates were disabled in the guest.
- Isolated Tart macOS 26.6.2 desktop on Apple M2 Ultra, 8 virtual CPUs, one
  1024×768-point Retina virtual display, one workspace with six application
  windows/icons. Auto-hide was off; the app remained enabled and visible.
- Cursor sweeps followed the icon centers from first to last and back every
  three seconds, with no clicks, dragging, or intentional idle pauses.
  The generator requested 120 events/s but delivered the actual rates shown in
  the tables. These are not 120 Hz input or physical display-presentation tests.
- CPU counters came from `proc_pid_rusage`, using the measured Mach timebase
  of 125/3 nanoseconds per tick. Measurements detect process changes and check
  that the display remains awake at each five-second sampling endpoint.
- Startup and movement warm-up were excluded. A separate five-second `sample`
  profile was captured after the comparison runs; its CPU measurement is excluded
  from the tables. No profiling ran during the primary measurements.

## Diagnosis and remaining work

The magnification comparisons implicate the changing hover presentation as the
largest cost in these runs. The separate profile shows repeated
`NSHostingView.layout`, SwiftUI view-graph/accessibility updates, and Core Animation
commit work. Source inspection confirms that the display-link callback publishes
a changing SwiftUI state value and recomputes shelf/header geometry on each
changing frame. This identifies the rendering path to optimize; it does not
establish how much a particular rewrite would save.

The under-3% interaction target remains unmet. No settings workaround measured
here establishes compliance across both positions. The physical MacBook Air,
multiple displays, larger workspaces, clicks, dragging, and physical frame pacing
still need measurement. No claim is made that the VM's percentage equals the
MacBook Air's result.

Raw measurements, screenshots, configuration copies and the sampling profile are
under `.local/vm-share/results/dock-interaction-20260920/`; the harness is under
`.local/vm-share/input/dock-interaction-20260920/`. Driver logs and the generated
summary are under `.local/reviews/dock-interaction-20260920/` (all ignored by Git).
The host application and its settings were not changed; no new release was made.
