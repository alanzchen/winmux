#!/usr/bin/env python3
"""The Chrome extension package: the files Chrome loads, a reproducible zip, and its stable ID."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("package_chrome_extension", ROOT / "script/package-chrome-extension.py")
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class PackageChromeExtensionTest(unittest.TestCase):
    def test_folder_and_zip_hold_the_same_three_files_reproducibly(self):
        with tempfile.TemporaryDirectory() as first, tempfile.TemporaryDirectory() as second:
            ids = [package.package(Path(directory) / "WinMuxTabs-Chrome") for directory in (first, second)]
            self.assertEqual(ids[0], ids[1])
            self.assertEqual(ids[0], "hnanakkjaimkfkpgmcoaglbgiiaohgbj", "The manifest key keeps the unpacked ID stable")
            folder = Path(first) / "WinMuxTabs-Chrome"
            zips = [Path(directory) / "WinMuxTabs-Chrome.zip" for directory in (first, second)]
            self.assertEqual(sorted(path.name for path in folder.iterdir()), ["background.js", "manifest.json", "shared.js"])
            with zipfile.ZipFile(zips[0]) as archive:
                self.assertEqual(sorted(archive.namelist()), ["background.js", "manifest.json", "shared.js"])
                for name in archive.namelist():
                    self.assertEqual(archive.read(name), (folder / name).read_bytes(), name)
            self.assertEqual(hashlib.sha256(zips[0].read_bytes()).hexdigest(), hashlib.sha256(zips[1].read_bytes()).hexdigest(),
                             "The same sources make the same release asset")

    def test_manifest_asks_for_no_site_access_and_titles_its_button(self):
        manifest = json.loads((ROOT / "Sources/ChromeExtension/manifest.json").read_text())
        self.assertEqual(manifest["manifest_version"], 3)
        self.assertEqual(manifest["incognito"], "not_allowed")
        self.assertEqual(sorted(manifest["permissions"]), ["alarms", "nativeMessaging", "storage", "tabs"])
        # Chrome adds a site-access line to the button's accessible name only for an extension
        # with or wanting host access; the marker must be its whole name.
        self.assertNotIn("host_permissions", manifest)
        self.assertNotIn("optional_host_permissions", manifest)
        self.assertNotIn("content_scripts", manifest)
        self.assertEqual(manifest["action"], {"default_title": "WinMux Tabs"})


if __name__ == "__main__":
    unittest.main()
