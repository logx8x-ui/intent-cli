#!/usr/bin/env python3
"""Exercise the actual beta plist generator without building or publishing an app."""
import pathlib
import plistlib
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
installer = (root / "scripts/install-dev.sh").read_text()
xml = installer.split("<<PLIST\n", 1)[1].split("\nPLIST", 1)[0]
assert plistlib.loads(xml.encode())["IntentDevelopmentBuild"] is True
packager = (root / "scripts/package-beta.sh").read_text()
script = packager.split("<<'PLIST'\n", 1)[1].split("\nPLIST", 1)[0]
with tempfile.TemporaryDirectory() as directory:
    output = pathlib.Path(directory) / "Info.plist"
    original = sys.argv
    try:
        sys.argv = ["package-beta", str(output), "0.9.3-test", "202609230001"]
        exec(compile(script, "package-beta-plist", "exec"), {})
    finally:
        sys.argv = original
    release = plistlib.loads(output.read_bytes())
    assert not release.get("IntentDevelopmentBuild", False)
    assert release["CFBundleVersion"] == "202609230001"
    assert release["CFBundleIdentifier"] == "dev.loganmondi.intent"
print("Development/public update-channel packaging passed")
