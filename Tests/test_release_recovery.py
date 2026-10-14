import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET


spec = importlib.util.spec_from_file_location("release", Path(__file__).resolve().parents[1] / "release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class RecoveryTests(unittest.TestCase):
    def test_unsafe_version_is_rejected_before_artifact_access(self):
        for operation in (lambda: release.prepare_feed("../1", "invalid"), lambda: release.publish_staged("../1")):
            with self.assertRaises(ValueError):
                operation()

    def test_feed_recovery_never_signs_and_rejects_archive_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "build/releases/1.5"
            contents = output / f"{release.APP}.app/Contents"
            contents.mkdir(parents=True)
            (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": release.IDENTIFIER, "CFBundleShortVersionString": "1.5", "CFBundleVersion": "6", "LSMinimumSystemVersion": "26.1"}))
            (output / "notarization.json").write_text(json.dumps({"version": "1.5", "status": "Accepted", "id": "accepted"}))
            (output / f"{release.APP}-1.5.zip").write_bytes(b"test archive")
            with patch.object(release, "ROOT", root), patch.object(release, "verify_entitlements"), patch.object(release, "run", return_value="") as run:
                with self.assertRaisesRegex(RuntimeError, "Invalid archive signature"):
                    release.prepare_feed("1.5", "invalid")
                feed = release.prepare_feed("1.5", "A" * 86 + "==")
                self.assertFalse(any("sign" in call.args[1:] or "check" in call.args[1:] for call in run.call_args_list))
                with self.assertRaisesRegex(RuntimeError, "Preserve existing appcast"):
                    release.prepare_feed("1.5", "A" * 86 + "==")
                xml = ET.parse(feed)
                xml.find("./channel/item/enclosure").set("length", "0")
                xml.write(feed)
                with self.assertRaisesRegex(RuntimeError, "exact staged archive"):
                    release.publish_staged("1.5")
                self.assertFalse(any("gh" in call.args[1:] for call in run.call_args_list))


if __name__ == "__main__":
    unittest.main()
