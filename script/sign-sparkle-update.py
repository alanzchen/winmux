#!/usr/bin/env python3
"""Sign updates without allowing Sparkle to request interactive Keychain access."""

import argparse
import base64
import binascii
import os
from pathlib import Path
import stat
import subprocess
import sys
import xml.etree.ElementTree as ET


def default_key_path():
    return Path.home() / "Library/Application Support/WinMux/ReleaseCredentials/sparkle-ed25519.key"


def load_key(environment, default_path=None):
    secret = environment.get("SPARKLE_PRIVATE_KEY", "").strip()
    configured_file = environment.get("SPARKLE_PRIVATE_KEY_FILE", "")
    if secret and configured_file:
        raise ValueError("Set only SPARKLE_PRIVATE_KEY or SPARKLE_PRIVATE_KEY_FILE.")
    if not secret:
        path = Path(configured_file) if configured_file else (default_path or default_key_path())
        try:
            with path.open("rb") as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
                    raise ValueError("The Sparkle key file must be owned by this user with permissions 600 or 400.")
                secret = stream.read(4096).strip()
        except OSError:
            raise ValueError("No readable Sparkle key file. Configure SPARKLE_PRIVATE_KEY_FILE or SPARKLE_PRIVATE_KEY before a headless release.") from None
    if isinstance(secret, str):
        secret = secret.encode()
    try:
        decoded = base64.b64decode(secret, validate=True)
    except (ValueError, binascii.Error):
        raise ValueError("The Sparkle signing key is not valid base64.") from None
    if len(decoded) not in (32, 96):
        raise ValueError("The Sparkle signing key must decode to 32 or 96 bytes.")
    return secret


def run_signer(arguments, secret, environment):
    # Sparkle may echo malformed key input in error messages. Never forward its output.
    child_environment = {key: value for key, value in environment.items() if key != "SPARKLE_PRIVATE_KEY"}
    result = subprocess.run(arguments, input=secret + b"\n", env=child_environment,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise ValueError(f"{Path(arguments[0]).name} failed; signing output was suppressed to protect credentials.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-credentials", action="store_true")
    parser.add_argument("--tools", type=Path)
    parser.add_argument("--stage", type=Path)
    parser.add_argument("--download-prefix")
    args = parser.parse_args()
    secret = load_key(os.environ)
    if args.check_credentials:
        print("Headless Sparkle signing credentials are available.")
        return
    if args.tools is None or args.stage is None or not args.download_prefix:
        parser.error("--tools, --stage, and --download-prefix are required for signing")
    archives = list(args.stage.glob("WinMux-*.zip"))
    if len(archives) != 1:
        raise ValueError("Expected exactly one Sparkle update archive.")
    appcast = args.stage / "appcast.xml"
    run_signer([str(args.tools / "generate_appcast"), "--ed-key-file", "-",
                "--download-url-prefix", args.download_prefix, "-o", str(appcast), str(args.stage)],
               secret, os.environ)
    enclosure = ET.parse(appcast).find("channel/item/enclosure")
    signature = None if enclosure is None else enclosure.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature")
    if not signature:
        raise ValueError("No update signature was produced. Check that the signing key matches the app's public key.")
    run_signer([str(args.tools / "sign_update"), "--verify", "--ed-key-file", "-", str(archives[0]), signature],
               secret, os.environ)
    print("Sparkle update signed and verified without Keychain access.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, ET.ParseError) as error:
        sys.exit(str(error))
