# Native macOS testing with Tart

The local `winmux-tests` VM provides a separate desktop for tests and screenshots.
It uses macOS 27 (Golden Gate) with Xcode 27, whose bundled Swift is the pinned 6.4.0,
8 virtual CPUs, and 24 GB memory. Source is shared read-only; generated screenshots
and logs use a separate writable results directory. No host signing keys or Apple
Account are needed in the guest.

## Start or recreate the VM

Install Tart using its [official quick start](https://tart.run/quick-start/).
The image used for this validation is pinned by digest:

```sh
tart clone ghcr.io/cirruslabs/macos-golden-gate-xcode@sha256:324ea5656dee8ab9b0a0df70fda2cfed8912051ad0eca3b1b883bf6ddac88fab winmux-tests
tart set winmux-tests --cpu 8 --memory 24576 --display 1600x1000pt
mkdir -p .local/vm-share/input .local/vm-share/results
tart run winmux-tests --no-graphics --no-audio --no-clipboard \
  --dir "inputs:$PWD/.local/vm-share/input:ro" \
  --dir "results:$PWD/.local/vm-share/results"
```

`script/tart-tests.sh test` fails when the guest's Swift isn't the version in
`.swift-version`; move to a newer image when the pin changes.

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
