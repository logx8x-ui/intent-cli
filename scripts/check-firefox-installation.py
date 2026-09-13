#!/usr/bin/env python3
"""Check the persistent Firefox package, independently of a temporary live add-on."""
import argparse
import json
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
ADDON_ID = "intent-firefox@loganmondi.dev"


def check_package(package, source):
    """A fresh heartbeat alone does not prove that a browser restart is safe."""
    if not package.is_file():
        return "missing permanent Browser Guard; temporary add-ons disappear on restart"
    try:
        with zipfile.ZipFile(package) as archive:
            manifest = json.loads(archive.read("manifest.json"))
            expected = json.loads((source / "manifest.json").read_text())
            if manifest.get("browser_specific_settings", {}).get("gecko", {}).get("id") != ADDON_ID:
                return "permanent package has the wrong extension ID"
            if manifest.get("version") != expected["version"]:
                return f"permanent version {manifest.get('version')} is outdated; needs {expected['version']}"
            if "META-INF/mozilla.rsa" not in archive.namelist():
                return "permanent package has no Mozilla signature; do not bypass Firefox signing"
            # Check the actual package rather than extensions.json, which can refer
            # to the temporary replacement currently loaded in this profile.
            for name in expected["background"]["scripts"]:
                if archive.read(name) != (source / name).read_bytes():
                    return "permanent background code differs from the tested source"
    except (OSError, ValueError, KeyError, zipfile.BadZipFile):
        return "permanent package is unreadable or incomplete"
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", type=Path, help="Firefox profile directory to check")
    args = parser.parse_args()
    profiles_root = Path.home() / "Library/Application Support/Firefox/Profiles"
    profiles = [args.profile] if args.profile else sorted(profiles_root.glob("*"))
    profiles = [p for p in profiles if p.is_dir() and (args.profile or (p / "prefs.js").exists())]
    if not profiles:
        print("Firefox: no profile found; permanent Browser Guard installation is unverified.")
        return 1
    failures = 0
    for profile in profiles:
        issue = check_package(profile / "extensions" / f"{ADDON_ID}.xpi", ROOT / "firefox-extension")
        failures += bool(issue)
        print(f"Firefox {profile.name}: {issue or 'matching permanent package found (Firefox must still validate its signature and connect)'}.")
    return int(failures > 0)


if __name__ == "__main__":
    raise SystemExit(main())
