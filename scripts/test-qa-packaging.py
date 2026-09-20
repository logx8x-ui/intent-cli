#!/usr/bin/env python3
"""Package existing products only; never compile, launch, or grant permissions."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parent.parent
PACKAGER = REPO / "scripts/build-qa.sh"
ARTIFACTS = (Path.home() / ".codex/artifacts/intent-qa").resolve()


class QAPackagingTests(unittest.TestCase):
    def test_rejects_unmarked_data_before_packaging(self):
        with tempfile.TemporaryDirectory(prefix="intent-qa-") as directory:
            result = subprocess.run([str(PACKAGER), "--skip-build", "--data-root", directory],
                                    text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Refusing an invalid existing QA data root", result.stderr)
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_durable_bundle_preserves_data_and_detects_missing_resources(self):
        # This uses existing release products, including the actual nested
        # framework layout that failed after temporary-resource cleanup.
        packages = []
        framework_source = Path(os.environ.get("INTENT_QA_BUILD_PATH", str(REPO / ".build"))) / (
            "artifacts/sparkle/Sparkle/Sparkle.xcframework/"
            "macos-arm64_x86_64/Sparkle.framework/Resources/Info.plist")
        source_stamp = framework_source.stat().st_mtime_ns
        try:
            with tempfile.TemporaryDirectory(prefix="intent-qa-") as directory:
                root = Path(directory).resolve()
                root.chmod(0o700)
                (root / ".intent-qa-root").write_text("Intent isolated QA data v1\n")
                sentinel = root / "qa-data-sentinel"
                sentinel.write_bytes(b"Keep the existing QA workspace unchanged.\n")
                old_app = root / "Intent QA.app"
                old_app.mkdir()
                (old_app / "old-bundle-sentinel").write_bytes(b"Never replace this bundle.\n")
                started = time.time() - 1
                for _ in range(2):
                    result = subprocess.run([str(PACKAGER), "--skip-build", "--data-root", str(root)],
                                            cwd=REPO, text=True, capture_output=True, check=True)
                    values = dict(line.split(": ", 1) for line in result.stdout.splitlines()
                                  if line.startswith(("QA app: ", "QA data: ")))
                    app = Path(values["QA app"]).resolve()
                    self.assertEqual(app.parent.parent, ARTIFACTS)
                    self.assertTrue(app.parent.name.startswith("package-"))
                    packages.append(app.parent)
                    self.assertNotIn(root, app.parents)
                    self.assertNotIn(Path(tempfile.gettempdir()).resolve(), app.parents)
                    self.assertEqual(Path(values["QA data"]).resolve(), root)
                    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
                    self.assertEqual(info["CFBundleIdentifier"], "dev.loganmondi.intent.qa")
                    self.assertEqual(Path(info["LSEnvironment"]["INTENT_QA_ROOT"]).resolve(), root)
                    copied = app / "Contents/Frameworks/Sparkle.framework/Resources/Info.plist"
                    self.assertGreaterEqual(copied.stat().st_mtime, started)
                    resources = app / "Contents/Resources/Intent_IntentApp.bundle"
                    self.assertTrue(any(resources.iterdir()))
                    for deep in ([], ["--deep"]):
                        subprocess.run(["/usr/bin/codesign", "--verify", *deep, "--strict", str(app)],
                                       capture_output=True, check=True)
                self.assertNotEqual(packages[0], packages[1])
                self.assertEqual(sentinel.read_bytes(), b"Keep the existing QA workspace unchanged.\n")
                self.assertEqual((old_app / "old-bundle-sentinel").read_bytes(), b"Never replace this bundle.\n")
                self.assertEqual(framework_source.stat().st_mtime_ns, source_stamp)

                # Reproduce the observed failure exactly: remove only the copied
                # framework plist. Verification must reject it, while the first
                # newly packaged app and the retained QA data remain intact.
                (app / "Contents/Frameworks/Sparkle.framework/Resources/Info.plist").unlink()
                broken = subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
                                        capture_output=True)
                self.assertNotEqual(broken.returncode, 0)
                subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict",
                                str(packages[0] / "Intent QA.app")], capture_output=True, check=True)
        finally:
            for package in packages:
                # Only exact uniquely created test artifacts are removed.
                if package.parent == ARTIFACTS and package.name.startswith("package-"):
                    shutil.rmtree(package)


if __name__ == "__main__":
    unittest.main()
