#!/usr/bin/env python3
"""Catch the temporary-update / stale permanent-package regression."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import zipfile

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("installation", Path(__file__).with_name("check-firefox-installation.py"))
installation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installation)
source = installation.ROOT / "firefox-extension"
current = json.loads((source / "manifest.json").read_text())

with tempfile.TemporaryDirectory() as temporary:
    package = Path(temporary) / "guard.xpi"

    def write(version=current["version"], signed=True, changed=False):
        manifest = dict(current, version=version)
        with zipfile.ZipFile(package, "w") as archive:
            archive.writestr("manifest.json", json.dumps(manifest))
            if signed:
                # Structural fixture only; this is not a cryptographic verifier.
                archive.writestr("META-INF/mozilla.rsa", b"test fixture")
            for name in current["background"]["scripts"]:
                archive.writestr(name, b"stale source" if changed else (source / name).read_bytes())

    assert "missing permanent" in installation.check_package(package, source)
    write(version="0.2.5")
    assert "outdated" in installation.check_package(package, source)
    write(signed=False)
    assert "no Mozilla signature" in installation.check_package(package, source)
    write(changed=True)
    assert "differs" in installation.check_package(package, source)
    write()
    assert installation.check_package(package, source) is None
    package.write_text("incomplete download")
    assert "unreadable" in installation.check_package(package, source)

print("Firefox persistent-installation spec passed")
