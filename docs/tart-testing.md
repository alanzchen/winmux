# Native macOS testing with Tart

The local `winmux-tests` VM provides a separate desktop for tests and screenshots.
It uses macOS 26.6.2, 8 virtual CPUs, 24 GB memory, and the repository's Swift 6.2.4
toolchain. Source and the toolchain are shared read-only; generated screenshots and
logs use a separate writable results directory. No host signing keys or Apple
Account are needed in the guest.

## Start or recreate the VM

Install Tart using its [official quick start](https://tart.run/quick-start/).
The image used for this validation is pinned by digest:

```sh
tart clone ghcr.io/cirruslabs/macos-tahoe-xcode@sha256:923c98d32e40ffadb6e6815a9722124b7a57bdf7d7763a708a2b28d1970831bd winmux-tests
tart set winmux-tests --cpu 8 --memory 24576 --display 1600x1000pt
mkdir -p .local/vm-share/input .local/vm-share/results
tart run winmux-tests --no-graphics --no-audio --no-clipboard \
  --dir "inputs:$PWD/.local/vm-share/input:ro" \
  --dir "results:$PWD/.local/vm-share/results" \
  --dir "swift-toolchain:$HOME/Library/Developer/Toolchains/swift-6.2.4-RELEASE.xctoolchain:ro"
```

Skip `clone` and `set` for the existing VM. `tart run` stays active until the VM
stops. The guest agent supports `tart exec` without SSH credentials. To see the
VM in a window, omit `--no-graphics` on its next start.

## Run tests and capture screenshots

```sh
script/tart-tests.sh test
script/tart-tests.sh screenshot
tart stop winmux-tests
```

The test helper exports tracked working-tree files, including local edits. Add new
source files to Git before running it. Results are in `.local/vm-share/results/`.
Use `tart exec winmux-tests /bin/bash` for additional guest commands. Screen
captures come from the guest desktop, not the host. The VM remains available for
reuse; stop it when finished to release CPU and memory.

## Dock performance benchmark

With the pinned Swift toolchain active, run:

```sh
WINMUX_DOCK_BENCHMARK=1 swift test --filter WorkspaceSidebarDockPerformanceTest
```

This opt-in benchmark sweeps 140 pointer positions through three- and eight-workspace
Docks, each with four apps per workspace. It reports warm CPU/layout durations and
checks that icon geometry actually changed. It does **not** measure displayed GPU
FPS; compare matching hardware, toolchain, and build configuration.

In the host debug benchmark, typical / 95th percentile times changed from
11.8 / 12.6 ms to 4.4 / 5.2 ms for three workspaces, and 27.6 / 332.2 ms to
5.1 / 5.7 ms for eight. The optimizations avoid laying out hidden expanded rows,
remove geometry-to-state feedback, and make compact workspace content lazy.
Native geometry and morph tests continue to cover hit regions, clipping, early
expansion, and Reduce Motion. Confirm smoothness on physical displays as well:
virtual GPU timing is not a substitute for hardware frame pacing.
