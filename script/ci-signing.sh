#!/bin/bash
# Used only on ephemeral GitHub-hosted macOS release runners. Never enable xtrace.
set -euo pipefail
umask 077

case "${1:-}" in
    prepare)
        for name in RUNNER_TEMP GITHUB_ENV BUILD_CERTIFICATE_BASE64 P12_PASSWORD APPLE_ID APPLE_APP_SPECIFIC_PASSWORD SPARKLE_PRIVATE_KEY DEVELOPMENT_TEAM; do
            if [ -z "${!name:-}" ]; then
                echo "Missing release setting: $name" >&2
                exit 1
            fi
        done
        signing_dir="$(mktemp -d "$RUNNER_TEMP/winmux-signing.XXXXXX")"
        # Record cleanup paths before importing anything, including on partial failure.
        printf 'WINMUX_SIGNING_DIR=%s\n' "$signing_dir" >> "$GITHUB_ENV"
        keychain_path="$signing_dir/signing.keychain-db"
        security list-keychains -d user > "$signing_dir/original-keychains.txt"
        keychain_password="$(openssl rand -hex 32)"
        security create-keychain -p "$keychain_password" "$keychain_path"
        security set-keychain-settings -lut 7200 "$keychain_path"
        security unlock-keychain -p "$keychain_password" "$keychain_path"
        printf '%s' "$BUILD_CERTIFICATE_BASE64" | base64 --decode > "$signing_dir/certificate.p12"
        security import "$signing_dir/certificate.p12" -P "$P12_PASSWORD" \
            -t cert -f pkcs12 -k "$keychain_path" -T /usr/bin/codesign -T /usr/bin/security > /dev/null
        rm -f "$signing_dir/certificate.p12"
        security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
            -k "$keychain_password" "$keychain_path" > /dev/null
        python3 - "$signing_dir" <<'PY'
import pathlib
import shlex
import subprocess
import sys
root = pathlib.Path(sys.argv[1])
previous = shlex.split((root / "original-keychains.txt").read_text())
subprocess.run(["security", "list-keychains", "-d", "user", "-s",
                str(root / "signing.keychain-db"), *previous], check=True)
PY
        identity="$(python3 - "$keychain_path" <<'PY'
import os
import re
import subprocess
import sys
output = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning", sys.argv[1]], text=True)
team = re.escape(os.environ["DEVELOPMENT_TEAM"])
identities = re.findall(r'\b([A-Fa-f0-9]{40}) "Developer ID Application: [^"\n]+ \(' + team + r'\)"', output)
if len(identities) != 1:
    sys.exit("Expected exactly one valid Developer ID Application certificate for APPLE_TEAM_ID.")
print(identities[0])
PY
)"
        xcrun notarytool store-credentials winmux-ci --keychain "$keychain_path" \
            --apple-id "$APPLE_ID" --team-id "$DEVELOPMENT_TEAM" \
            --password "$APPLE_APP_SPECIFIC_PASSWORD" --validate
        printf '%s' "$SPARKLE_PRIVATE_KEY" > "$signing_dir/sparkle-private-key"
        printf 'CODESIGN_IDENTITY=%s\nNOTARYTOOL_KEYCHAIN=%s\nSPARKLE_PRIVATE_KEY_FILE=%s\n' \
            "$identity" "$keychain_path" "$signing_dir/sparkle-private-key" >> "$GITHUB_ENV"
        ;;
    cleanup)
        if [ -n "${WINMUX_SIGNING_DIR:-}" ] && [ -d "$WINMUX_SIGNING_DIR" ]; then
            case "$WINMUX_SIGNING_DIR" in "$RUNNER_TEMP"/winmux-signing.*) ;; *) exit 1 ;; esac
            python3 - "$WINMUX_SIGNING_DIR" <<'PY'
import pathlib
import shlex
import subprocess
import sys
root = pathlib.Path(sys.argv[1])
original = root / "original-keychains.txt"
if original.exists():
    subprocess.run(["security", "list-keychains", "-d", "user", "-s", *shlex.split(original.read_text())], check=True)
PY
            security delete-keychain "$WINMUX_SIGNING_DIR/signing.keychain-db" || true
            rm -rf "$WINMUX_SIGNING_DIR"
        fi
        ;;
    *) echo 'Usage: ci-signing.sh prepare|cleanup' >&2; exit 2 ;;
esac
