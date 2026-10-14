import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("release", Path(__file__).resolve().parents[1] / "release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class SigningFailureTests(unittest.TestCase):
    def test_denied_key_is_reported_without_retry(self):
        result = subprocess.CompletedProcess([], 1, "", "BLOCKED: Keychain denied access (OSStatus=-25293)\n")
        with patch.object(release.subprocess, "run", return_value=result) as run:
            with self.assertRaisesRegex(RuntimeError, "OSStatus=-25293"):
                release.run("Existing update key without prompts", "/usr/bin/swift", release.ROOT / "signing.swift", "check", release.ACCOUNT, release.PUBLIC_KEY)
            self.assertEqual(run.call_count, 1)


if __name__ == "__main__":
    unittest.main()
