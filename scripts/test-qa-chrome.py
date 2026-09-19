#!/usr/bin/env python3
"""Test QA bridge preparation entirely inside temporary directories."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("qa_chrome", Path(__file__).with_name("prepare-qa-chrome.py"))
qa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qa)


class QABrowserPreparation(unittest.TestCase):
    def test_isolated_copy_exclusive_registration_and_cleanup(self):
        with tempfile.TemporaryDirectory(prefix="intent-qa-") as temp:
            root = Path(temp).resolve()
            root.chmod(0o700)
            (root / qa.MARKER).write_text(qa.MARKER_CONTENTS)
            source = root / "source"
            source.mkdir()
            (source / "manifest.json").write_text(json.dumps({"key": "dGVzdA==", "name": "Original", "update_url": "https://example.test"}))
            (source / "background.js").write_text('const HOST_NAME = "intent_native_host";\n')
            host = root / "host"
            host.write_text("#!/bin/sh\nexit 0\n")
            host.chmod(0o700)
            registrations = root / "fixture-registrations"
            registrations.mkdir()
            real = registrations / "intent_native_host.json"
            real.write_text("production sentinel")
            result = qa.prepare(root, source, host, registrations)
            copied = Path(result["extension"])
            self.assertIn(qa.HOST_NAME, (copied / "background.js").read_text())
            self.assertIn("intent_native_host", (source / "background.js").read_text())
            self.assertNotIn("update_url", json.loads((copied / "manifest.json").read_text()))
            self.assertEqual(real.read_text(), "production sentinel")
            self.assertIn("unset INTENT_QA_ROOT", Path(result["wrapper"]).read_text())
            with self.assertRaises(ValueError):
                qa.prepare(root, source, host, registrations)
            qa.cleanup(root, registrations)
            self.assertFalse(Path(result["manifest"]).exists())
            self.assertFalse((root / "browser-fixtures").exists())
            self.assertEqual(real.read_text(), "production sentinel")
            qa.prepare(root, source, host, registrations)
            registration = registrations / (qa.HOST_NAME + ".json")
            registration.write_text(json.dumps({"name": qa.HOST_NAME, "path": "/another/test"}))
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
