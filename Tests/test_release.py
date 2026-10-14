import importlib.util
from pathlib import Path
import plistlib
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("release", Path(__file__).resolve().parents[1] / "release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseEntitlementsTests(unittest.TestCase):
    def test_preserves_capabilities_without_development_entitlements(self):
        app = {"com.apple.security.files.user-selected.read-only": True}
        widget = {"com.apple.security.app-sandbox": True}
        with patch.object(release, "run", side_effect=[plistlib.dumps(app).decode(), plistlib.dumps(widget).decode()]):
            release.verify_entitlements(Path("systemInfo.app"))
        for capabilities in ({}, {**widget, "com.apple.security.get-task-allow": True}):
            with self.subTest(capabilities=capabilities):
                with patch.object(release, "run", side_effect=[plistlib.dumps(app).decode(), plistlib.dumps(capabilities).decode()]):
                    with self.assertRaises(RuntimeError):
                        release.verify_entitlements(Path("systemInfo.app"))


if __name__ == "__main__":
    unittest.main()
