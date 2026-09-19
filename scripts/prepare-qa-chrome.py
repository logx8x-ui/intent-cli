#!/usr/bin/env python3
"""Prepare a copied Chrome guard and unique native host for an isolated QA profile.

No Chrome launch, extension installation, or production-manifest modification.
The sole out-of-root artifact is a newly created QA-only native-host registration.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import stat
import tempfile

HOST_NAME = "dev.loganmondi.intent.qa"
MARKER = ".intent-qa-root"
MARKER_CONTENTS = "Intent isolated QA data v1\n"


def validated_root(value):
    root = Path(value).resolve()
    parents = {Path(tempfile.gettempdir()).resolve(), Path("/private/tmp").resolve()}
    if not Path(value).is_absolute() or root.parent not in parents or not root.name.startswith("intent-qa-") or len(root.name) <= len("intent-qa-"):
        raise ValueError("Expected a dedicated, absolute intent-qa-* root in the temporary directory")
    if not root.is_dir() or stat.S_IMODE(root.stat().st_mode) != 0o700:
        raise ValueError("QA root must be a private directory (mode 700)")
    if (root / MARKER).read_text() != MARKER_CONTENTS:
        raise ValueError("QA root marker is missing or invalid")
    return root


def extension_id(key):
    digest = hashlib.sha256(base64.b64decode(key, validate=True)).hexdigest()[:32]
    return "".join(chr(ord("a") + int(character, 16)) for character in digest)


def default_manifest_directory():
    return Path.home() / "Library/Application Support/Google/Chrome/NativeMessagingHosts"


def prepare(root, source, host_binary, manifest_directory=None):
    root = validated_root(root)
    source, host_binary = Path(source).resolve(), Path(host_binary).resolve()
    if not host_binary.is_file() or not os.access(host_binary, os.X_OK):
        raise ValueError("Build the release IntentNativeHost executable first")
    directory = Path(manifest_directory) if manifest_directory is not None else default_manifest_directory()
    destination = directory / (HOST_NAME + ".json")
    fixture = root / "browser-fixtures"
    if destination.exists() or destination.is_symlink() or fixture.exists():
        raise ValueError("QA host or fixture already exists; refusing to overwrite it")
    manifest = json.loads((source / "manifest.json").read_text())
    guard_id = extension_id(manifest["key"])
    background = (source / "background.js").read_text()
    old = 'const HOST_NAME = "intent_native_host";'
    if background.count(old) != 1:
        raise ValueError("Expected exactly one production native-host declaration")
    created_inode = None
    try:
        fixture.mkdir(mode=0o700)
        guard = fixture / "ChromeGuardQA"
        shutil.copytree(source, guard)
        (guard / "background.js").write_text(background.replace(old, 'const HOST_NAME = "' + HOST_NAME + '";'))
        manifest["name"] = "Intent Browser Guard QA"
        manifest.pop("update_url", None)
        (guard / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        copied_host = fixture / "IntentNativeHostQA"
        shutil.copy2(host_binary, copied_host)
        copied_host.chmod(0o700)
        wrapper = fixture / "native-host.sh"
        wrapper.write_text("#!/bin/bash\nset -euo pipefail\nunset INTENT_QA_ROOT\n"
                           + "export INTENT_NATIVE_HOST_DIRECTORY=" + shlex.quote(str(root)) + "\n"
                           + "exec " + shlex.quote(str(copied_host)) + "\n")
        wrapper.chmod(0o700)
        registration = {
            "name": HOST_NAME, "description": "Intent isolated QA bridge",
            "path": str(wrapper), "type": "stdio",
            "allowed_origins": ["chrome-extension://" + guard_id + "/"],
        }
        directory.mkdir(parents=True, exist_ok=True)
        # Exclusive creation also prevents races from overwriting another QA run.
        descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        created_inode = os.fstat(descriptor).st_ino
        with os.fdopen(descriptor, "w") as handle:
            json.dump(registration, handle, indent=2)
            handle.write("\n")
        receipt = {"root": str(root), "manifest": str(destination), "wrapper": str(wrapper),
                   "extension": str(guard), "profile": str(root / "chrome-profile"), "extension_id": guard_id}
        (fixture / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        return receipt
    except Exception:
        # Remove only files created by this invocation, including partial writes.
        if created_inode is not None and not destination.is_symlink() and destination.exists() and destination.stat().st_ino == created_inode:
            destination.unlink()
        if fixture.exists():
            shutil.rmtree(fixture)
        raise


def cleanup(root, manifest_directory=None):
    root = validated_root(root)
    fixture = root / "browser-fixtures"
    receipt = json.loads((fixture / "receipt.json").read_text())
    directory = Path(manifest_directory) if manifest_directory is not None else default_manifest_directory()
    destination = directory / (HOST_NAME + ".json")
    wrapper = fixture / "native-host.sh"
    if receipt.get("root") != str(root) or receipt.get("manifest") != str(destination) or receipt.get("wrapper") != str(wrapper):
        raise ValueError("QA receipt does not match this root and registration")
    if destination.is_symlink():
        raise ValueError("QA registration became a symlink; refusing cleanup")
    if destination.exists():
        actual = json.loads(destination.read_text())
        if actual.get("name") != HOST_NAME or actual.get("path") != str(wrapper):
            raise ValueError("QA registration changed; refusing to remove another run's file")
        destination.unlink()
    shutil.rmtree(fixture)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", help="QA root printed by scripts/build-qa.sh")
    parser.add_argument("--host-binary", type=Path, default=Path(__file__).resolve().parent.parent / ".build/release/IntentNativeHost")
    parser.add_argument("--cleanup", action="store_true", help="Remove only this run's QA registration and copied guard/host after stopping QA Chrome")
    args = parser.parse_args()
    if args.cleanup:
        cleanup(args.root)
        print("Removed this run's QA native-host registration and copied browser fixture; profile/data retained.")
    else:
        result = prepare(args.root, Path(__file__).resolve().parent.parent / "chrome-extension", args.host_binary)
        print(json.dumps(result, indent=2))
