#!/usr/bin/env python3
"""Assemble the dependency-free unpacked extension and reproducible adjacent zip."""
import base64
import hashlib
import json
from pathlib import Path
import shutil
import sys
import zipfile


def package(destination):
    root = Path(__file__).resolve().parent.parent
    destination = Path(destination)
    manifest = json.loads((root / 'Sources/ChromeExtension/manifest.json').read_text())
    digest = hashlib.sha256(base64.b64decode(manifest['key'], validate=True)).hexdigest()[:32]
    extension_id = ''.join(chr(97 + int(c, 16)) for c in digest)
    identity = (root / 'Sources/Common/BrowserPushIdentity.swift').read_text()
    if f'extensionId = "{extension_id}"' not in identity:
        raise ValueError('Chrome manifest key and native allowed origin differ')
    destination.mkdir(parents=True, exist_ok=True)
    files = {
        'manifest.json': root / 'Sources/ChromeExtension/manifest.json',
        'background.js': root / 'Sources/ChromeExtension/background.js',
        'shared.js': root / 'Sources/SafariExtension/Resources/shared.js',
    }
    for name, source in files.items():
        shutil.copyfile(source, destination / name)
    with zipfile.ZipFile(str(destination) + '.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
        for name in sorted(files):
            entry = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o644 << 16
            archive.writestr(entry, (destination / name).read_bytes())
    return extension_id


if __name__ == '__main__':
    print(package(sys.argv[1]))
