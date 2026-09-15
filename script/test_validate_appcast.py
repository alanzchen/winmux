"""Exercise the release feed checks before publication."""

import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "validate_appcast", Path(__file__).with_name("validate-appcast.py")
)
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)

URL = "https://github.com/alanzchen/winmux/releases/download/v0.5.3/WinMux-0.5.3.zip"
ITEM = f"""<item>
<sparkle:version>0.5.3</sparkle:version>
<sparkle:shortVersionString>0.5.3</sparkle:shortVersionString>
<enclosure url="{URL}" length="100" sparkle:edSignature="test-signature"/>
</item>"""


class AppcastValidationTest(unittest.TestCase):
    def validate(self, items, archive_bytes=None):
        with tempfile.TemporaryDirectory() as directory:
            feed = Path(directory) / "appcast.xml"
            feed.write_text(
                '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
                f"<channel>{items}</channel></rss>"
            )
            archive = None
            if archive_bytes is not None:
                archive = Path(directory) / "WinMux-0.5.3.zip"
                archive.write_bytes(archive_bytes)
            validator.validate_appcast(feed, "0.5.3", URL, archive)

    def test_current_release_is_accepted(self):
        self.validate(ITEM)

    def test_stale_archive_cannot_add_phantom_update(self):
        with self.assertRaisesRegex(ValueError, "exactly one"):
            self.validate(ITEM + ITEM.replace("0.5.3", "1.0"))

    def test_wrong_version_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "version"):
            self.validate(ITEM.replace(
                "<sparkle:version>0.5.3", "<sparkle:version>1"
            ))

    def test_wrong_short_version_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "shortVersionString"):
            self.validate(ITEM.replace(
                "<sparkle:shortVersionString>0.5.3", "<sparkle:shortVersionString>0.5.2"
            ))

    def test_wrong_archive_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "current release archive"):
            self.validate(ITEM.replace("WinMux-0.5.3.zip", "WinMux-0.5.1.zip"))

    def test_upstream_archive_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "current release archive"):
            self.validate(ITEM.replace("alanzchen/winmux", "ZimengXiong/winmux"))

    def test_unsigned_archive_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "signature"):
            self.validate(ITEM.replace('sparkle:edSignature="test-signature"', ""))

    def test_blank_signature_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "signature"):
            self.validate(ITEM.replace("test-signature", "   "))

    def test_invalid_archive_sizes_are_rejected(self):
        for size in ("", "0", "-1", "1.5", "unknown"):
            with self.subTest(size=size), self.assertRaisesRegex(ValueError, "size"):
                self.validate(ITEM.replace('length="100"', f'length="{size}"'))

    def test_missing_archive_size_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "positive size"):
            self.validate(ITEM.replace('length="100"', ""))

    def test_final_archive_with_matching_size_is_accepted(self):
        self.validate(ITEM, archive_bytes=b"x" * 100)

    def test_final_archive_with_wrong_size_is_rejected(self):
        for archive_bytes in (b"", b"x" * 99, b"x" * 101):
            with self.subTest(size=len(archive_bytes)):
                with self.assertRaisesRegex(ValueError, "match the published file"):
                    self.validate(ITEM, archive_bytes=archive_bytes)

    def test_missing_final_archive_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            feed = Path(directory) / "appcast.xml"
            feed.write_text(
                '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
                f"<channel>{ITEM}</channel></rss>"
            )
            with self.assertRaisesRegex(ValueError, "existing file"):
                validator.validate_appcast(feed, "0.5.3", URL, feed.parent / "missing.zip")

    def test_empty_feed_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "exactly one"):
            self.validate("")


if __name__ == "__main__":
    unittest.main()
