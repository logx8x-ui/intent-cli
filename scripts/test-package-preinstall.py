#!/usr/bin/env python3
"""Execute the shipped preinstall script against disposable destinations only."""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).with_name('package-preinstall.sh').read_text()


class PackagePreinstall(unittest.TestCase):
    def check(self, running='', process_status=1, manifest=None, symlink=None,
              bundle=None, legacy=False, expected=0):
        with tempfile.TemporaryDirectory(prefix='intent-package-guard-') as temp:
            root = Path(temp)
            destinations = root / 'destinations'
            destinations.mkdir()
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            probe = bin_dir / 'pgrep'
            probe.write_text('#!/bin/bash\n[[ "$2" == "$MOCK_RUNNING" ]] && exit 0\nexit "$MOCK_STATUS"\n')
            probe.chmod(0o700)
            # Rewrite literal absolute destinations, without adding a production
            # environment override that could weaken an actual installer.
            script = root / 'preinstall'
            script.write_text(SOURCE.replace("'/Applications", "'" + str(destinations) + '/Applications')
                              .replace("'/Library", "'" + str(destinations) + '/Library'))
            host = destinations / 'Library/Application Support/Mozilla/NativeMessagingHosts/intent_native_host.json'
            host.parent.mkdir(parents=True)
            if manifest is not None:
                host.write_text(manifest.replace('@HOST@', str(destinations) + '/Library/Application Support/Intent/IntentNativeHost'))
            if bundle is not None:
                info = destinations / 'Applications/Intent.app/Contents/Info.plist'
                info.parent.mkdir(parents=True)
                info.write_bytes(plistlib.dumps({'CFBundleIdentifier': bundle}))
            if legacy:
                agent = destinations / 'Library/LaunchAgents/dev.loganmondi.intent.plist'
                agent.parent.mkdir()
                agent.write_text('preserve this agent')
            if symlink:
                path = destinations / symlink
                path.parent.mkdir(parents=True, exist_ok=True)
                if path.exists():
                    if path.is_dir():
                        path.rmdir()
                    else:
                        path.unlink()
                path.symlink_to(root / 'missing')
            before = {str(p): (os.readlink(p) if p.is_symlink() else p.read_bytes())
                      for p in destinations.rglob('*') if p.is_symlink() or p.is_file()}
            env = dict(os.environ, PATH=str(bin_dir) + ':/usr/bin:/bin',
                       MOCK_RUNNING=running, MOCK_STATUS=str(process_status))
            result = subprocess.run(['/bin/bash', str(script)], env=env, capture_output=True)
            self.assertEqual(result.returncode, expected, result.stderr.decode())
            after = {str(p): (os.readlink(p) if p.is_symlink() else p.read_bytes())
                     for p in destinations.rglob('*') if p.is_symlink() or p.is_file()}
            self.assertEqual(before, after, 'preinstall must be read-only')

    def test_clean_install(self): self.check()
    def test_running_gui(self): self.check(running='IntentApp', expected=1)
    def test_running_cli(self): self.check(running='Intent', expected=1)
    def test_process_inspection_failure(self): self.check(process_status=2, expected=1)
    def test_owned_host(self): self.check(manifest='{"path":"@HOST@"}')
    def test_foreign_host(self): self.check(manifest='{"path":"/some/other/host"}', expected=1)
    def test_invalid_host(self): self.check(manifest='invalid', expected=1)
    def test_owned_app(self): self.check(bundle='dev.loganmondi.intent')
    def test_test_app(self): self.check(bundle='dev.loganmondi.intent.test', expected=1)
    def test_symlink_host(self): self.check(symlink='Library/Application Support/Mozilla/NativeMessagingHosts/intent_native_host.json', expected=1)
    def test_symlink_parent(self): self.check(symlink='Library/Google', expected=1)
    def test_legacy_agent(self): self.check(legacy=True, expected=1)


if __name__ == '__main__': unittest.main()
