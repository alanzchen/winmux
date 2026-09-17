#!/usr/bin/env python3
"""Reject release feeds that advertise stale or mislabeled archives."""

import argparse
from pathlib import Path
import xml.etree.ElementTree as ET

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def validate_appcast(path, version, archive_url, archive_path=None, *, require_arm64=False):
    items = ET.parse(path).findall("./channel/item")
    if len(items) != 1:
        raise ValueError("The release feed must contain exactly one update.")
    item = items[0]
    if require_arm64:
        requirements = item.findtext(SPARKLE + "hardwareRequirements", "")
        if "arm64" not in {value.strip() for value in requirements.split(",")}:
            raise ValueError("Apple Silicon updates must require arm64 hardware.")
    for key in ("version", "shortVersionString"):
        if item.findtext(SPARKLE + key) != version:
            raise ValueError(f"The update's {key} must match release {version}.")
    enclosure = item.find("enclosure")
    if enclosure is None or enclosure.get("url") != archive_url:
        raise ValueError("The update must point to the current release archive.")
    if not enclosure.get(SPARKLE + "edSignature", "").strip():
        raise ValueError("The update archive must have a Sparkle signature.")
    try:
        advertised_size = int(enclosure.get("length", "0"))
    except ValueError as error:
        raise ValueError("The update archive size must be an integer.") from error
    if advertised_size <= 0:
        raise ValueError("The update archive must have a positive size.")
    if archive_path is not None:
        archive = Path(archive_path)
        if not archive.is_file():
            raise ValueError("The update archive must be an existing file.")
        if advertised_size != archive.stat().st_size:
            raise ValueError("The update archive size must match the published file.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("appcast", type=Path)
    parser.add_argument("version")
    parser.add_argument("archive_url")
    parser.add_argument(
        "--archive", type=Path,
        help="Check the enclosure length against this final release archive.",
    )
    parser.add_argument(
        "--require-arm64", action="store_true",
        help="Reject updates that could be offered to Intel Macs.",
    )
    args = parser.parse_args()
    try:
        validate_appcast(args.appcast, args.version, args.archive_url, args.archive,
                         require_arm64=args.require_arm64)
    except (OSError, ValueError, ET.ParseError) as error:
        parser.error(str(error))
