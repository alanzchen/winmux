#!/bin/bash
# Run the pinned test suite in the isolated VM described in docs/tart-testing.md.
set -euo pipefail
cd "$(dirname "$0")/.."
vm_name="${TART_VM:-winmux-tests}"
share_dir="$PWD/.local/vm-share"
mkdir -p "$share_dir/input" "$share_dir/results"
if [ "${1:-test}" = screenshot ]; then
    tart exec "$vm_name" /usr/sbin/screencapture -x '/Volumes/My Shared Files/results/vm-desktop.png'
    echo "$share_dir/results/vm-desktop.png"
    exit
fi
if [ "${1:-test}" != test ]; then
    echo 'Usage: script/tart-tests.sh [test|screenshot]' >&2
    exit 2
fi
# Export tracked source only. Never share .git, signing keys, the host home, or build caches.
# Unique paths avoid VirtioFS serving cached contents from a previous host write.
run_dir="$(mktemp -d "$share_dir/input/run.XXXXXX")"
trap 'rm -rf "$run_dir"' EXIT
guest_run_dir="/Volumes/My Shared Files/inputs/$(basename "$run_dir")"
python3 - "$run_dir/source.tar" <<'PY'
from pathlib import Path
import subprocess
import sys
import tarfile
files = subprocess.check_output(['git', 'ls-files', '-z']).decode().split('\0')
archive = Path(sys.argv[1])
with tarfile.open(archive.with_suffix('.tmp'), 'w') as tar:
    for name in files:
        if name and Path(name).is_file():
            tar.add(name, arcname=name, recursive=False)
archive.with_suffix('.tmp').replace(archive)
PY
cat > "$run_dir/test.sh" <<'GUEST'
#!/bin/bash
set -euo pipefail
mkdir -p /Users/admin/winmux
cd /Users/admin/winmux
source_stage="$(mktemp -d /Users/admin/winmux-source.XXXXXX)"
trap 'rm -rf "$source_stage"' EXIT
tar -xf "$1" -C "$source_stage"
# Remove stale source while retaining the guest's dependency/build cache.
rsync -a --delete --exclude '/.build' --exclude '/.git' "$source_stage/" ./
# Debug configuration discovery uses a Git root. This is fresh guest metadata;
# no host history, remotes, credentials, or Git configuration are copied.
git init --quiet
# The guest's Xcode bundles the pinned Swift. Refuse to test with a different compiler.
xcodebuild -version
xcrun swift --version
expected="$(cat .swift-version)"
actual="$(xcrun swift --version 2> /dev/null | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+(\.[0-9]+)?)[ )].*/\1/p' || true)"
test "$actual" = "$expected" || test "$actual.0" = "$expected" || {
    echo "The guest's Swift $actual isn't the pinned $expected; update the VM's Xcode (docs/tart-testing.md)." >&2
    exit 1
}
xcrun swift test --arch arm64
xcrun swift build --arch arm64
GUEST
tart exec "$vm_name" /bin/bash "$guest_run_dir/test.sh" "$guest_run_dir/source.tar" 2>&1 | tee "$share_dir/results/tests.log"
