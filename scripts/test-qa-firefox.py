#!/usr/bin/env python3
"""Test Firefox QA preparation without registering hosts or launching Firefox."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("qa_firefox", Path(__file__).with_name("prepare-qa-firefox.py"))
qa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qa)


class QAFirefoxPreparation(unittest.TestCase):
    def fixture(self, temp):
        root = Path(temp).resolve()
        root.chmod(0o700)
        (root / qa.MARKER).write_text(qa.MARKER_CONTENTS)
        source = root / "source"
        source.mkdir()
        (source / "manifest.json").write_text(json.dumps({
            "name": "Original",
            "browser_specific_settings": {"gecko": {
                "id": "intent-firefox@loganmondi.dev", "update_url": "https://example.test"}},
        }))
        (source / "background.js").write_text('const HOST_NAME = "intent_native_host";\n')
        host = root / "host"
        host.write_text("#!/bin/sh\nexit 0\n")
        host.chmod(0o700)
        registrations = root / "fixture-registrations"
        registrations.mkdir()
        return root, source, host, registrations

    def test_isolated_copy_exclusive_registration_and_cleanup(self):
        with tempfile.TemporaryDirectory(prefix="intent-qa-") as temp:
            root, source, host, registrations = self.fixture(temp)
            production = registrations / "intent_native_host.json"
            production.write_text("production sentinel")
            chrome_fixture = root / "browser-fixtures"
            chrome_fixture.mkdir()
            (chrome_fixture / "sentinel").write_text("Chrome fixture untouched")
            original_manifest = (source / "manifest.json").read_text()
            result = qa.prepare(root, source, host, registrations)
            copied = Path(result["extension"])
            manifest = json.loads((copied / "manifest.json").read_text())
            registration = json.loads(Path(result["manifest"]).read_text())
            self.assertEqual(registration["allowed_extensions"], ["intent-firefox-qa@loganmondi.dev"])
            self.assertNotIn("allowed_origins", registration)
            self.assertEqual(manifest["browser_specific_settings"]["gecko"]["id"], result["extension_id"])
            self.assertNotIn("update_url", manifest["browser_specific_settings"]["gecko"])
            self.assertIn(qa.HOST_NAME, (copied / "background.js").read_text())
            self.assertEqual((source / "manifest.json").read_text(), original_manifest)
            self.assertIn("intent_native_host", (source / "background.js").read_text())
            self.assertIn("unset INTENT_QA_ROOT", Path(result["wrapper"]).read_text())
            self.assertIn(str(root), Path(result["wrapper"]).read_text())
            with self.assertRaises(ValueError):
                qa.prepare(root, source, host, registrations)
            qa.cleanup(root, registrations)
            self.assertFalse(Path(result["manifest"]).exists())
            self.assertFalse((root / "firefox-fixtures").exists())
            self.assertEqual(production.read_text(), "production sentinel")
            self.assertEqual((chrome_fixture / "sentinel").read_text(), "Chrome fixture untouched")

    def test_refuse_foreign_registration_and_cleanup(self):
        with tempfile.TemporaryDirectory(prefix="intent-qa-") as temp:
            root, source, host, registrations = self.fixture(temp)
            registration = registrations / (qa.HOST_NAME + ".json")
            registration.write_text("existing QA registration")
            with self.assertRaises(ValueError):
                qa.prepare(root, source, host, registrations)
            self.assertEqual(registration.read_text(), "existing QA registration")
            self.assertFalse((root / "firefox-fixtures").exists())
            registration.unlink()
            qa.prepare(root, source, host, registrations)
            registration.write_text(json.dumps({"name": qa.HOST_NAME, "path": "/another/run"}))
            with self.assertRaises(ValueError):
                qa.cleanup(root, registrations)
            self.assertTrue(registration.exists())

    def test_refuse_daily_or_unmarked_roots(self):
        with self.assertRaises((ValueError, FileNotFoundError)):
            qa.validated_root(Path.home() / ".intent")
        with tempfile.TemporaryDirectory(prefix="intent-qa-") as temp:
            with self.assertRaises(FileNotFoundError):
                qa.validated_root(temp)


if __name__ == "__main__":
    unittest.main()
