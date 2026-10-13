#!/usr/bin/env python3
"""Exercise the shipped remover exclusively inside disposable destinations."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1].joinpath('uninstall.sh').read_text()


class PackageUninstall(unittest.TestCase):
    def run_fixture(self, *, running='', process_status=1, team='Y3ZGWT477T',
                    bundle='dev.loganmondi.intent', host=None, symlink=None,
                    legacy=False, argument='--system-remove', expected=0):
        with tempfile.TemporaryDirectory(prefix='intent-uninstall-test-') as temporary:
            root = Path(temporary)
            destination = root / 'destinations'
            app = destination / 'Applications/Intent.app'
            support = destination / 'Library/Application Support/Intent'
            info = app / 'Contents/Info.plist'
            info.parent.mkdir(parents=True)
            info.write_bytes(plistlib.dumps({'CFBundleIdentifier': bundle}))
            support.mkdir(parents=True)
            for name in ('Intent', 'IntentNativeHost', 'unowned.txt'):
                (support / name).write_text('preserve unless owned')
            manifests = []
            for relative in ('Library/Application Support/Mozilla/NativeMessagingHosts',
                             'Library/Google/Chrome/NativeMessagingHosts'):
                path = destination / relative / 'intent_native_host.json'
                path.parent.mkdir(parents=True)
                path.write_text(json.dumps({'name': 'intent_native_host',
                                            'path': host or str(support / 'IntentNativeHost')}))
                manifests.append(path)
            untouched = destination / 'user-data/.intent'
            untouched.mkdir(parents=True)
            (untouched / 'saved.json').write_text('private fixture intentions')
            if legacy:
                agent = destination / 'Library/LaunchAgents/dev.loganmondi.intent.plist'
                agent.parent.mkdir()
                agent.write_text('legacy agent')
            if symlink:
                path = destination / symlink
                path.unlink()
                path.symlink_to(root / 'outside')
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            mocks = {
                'pgrep': '#!/bin/bash\n[[ "$2" == "$MOCK_RUNNING" ]] && exit 0\nexit "$MOCK_STATUS"\n',
                'codesign': '#!/bin/bash\n[[ "$1" == --verify ]] && exit 0\necho "TeamIdentifier=$MOCK_TEAM"\n',
                'pkgutil': '#!/bin/bash\nexit 0\n',
            }
            for name, content in mocks.items():
                path = bin_dir / name
                path.write_text(content)
                path.chmod(0o700)
            # Only test copies get path/privilege substitutions; production has
            # no destination override or test-only bypass environment variables.
            script = SOURCE.replace("'/Applications", "'" + str(destination) + '/Applications')
            script = script.replace("'/Library", "'" + str(destination) + '/Library')
            script = script.replace('"$EUID" != 0', '0 != 0')
            script = script.replace('/usr/bin/codesign', str(bin_dir / 'codesign'))
            script = script.replace('/usr/sbin/pkgutil', str(bin_dir / 'pkgutil'))
            target = root / 'uninstall'
            target.write_text(script)
            before = {str(p): os.readlink(p) if p.is_symlink() else p.read_bytes()
                      for p in destination.rglob('*') if p.is_file() or p.is_symlink()}
            result = subprocess.run(['/bin/bash', str(target), argument], capture_output=True,
                env=dict(os.environ, PATH=str(bin_dir)+':/usr/bin:/bin', MOCK_RUNNING=running,
                         MOCK_STATUS=str(process_status), MOCK_TEAM=team))
            self.assertEqual(result.returncode, expected, result.stderr.decode())
            self.assertEqual((untouched / 'saved.json').read_text(), 'private fixture intentions')
            self.assertTrue((support / 'unowned.txt').exists())
            if expected:
                after = {str(p): os.readlink(p) if p.is_symlink() else p.read_bytes()
                         for p in destination.rglob('*') if p.is_file() or p.is_symlink()}
                self.assertEqual(before, after, 'refusal must not remove anything')
            else:
                self.assertFalse(app.exists())
                self.assertFalse((support / 'Intent').exists())
                self.assertFalse((support / 'IntentNativeHost').exists())
                self.assertTrue(all(not path.exists() for path in manifests))

    def test_removes_only_verified_system_resources(self): self.run_fixture()
    def test_gui_running(self): self.run_fixture(running='IntentApp', expected=1)
    def test_cli_running(self): self.run_fixture(running='Intent', expected=1)
    def test_host_running(self): self.run_fixture(running='IntentNativeHost', expected=1)
    def test_process_probe_failed(self): self.run_fixture(process_status=2, expected=1)
    def test_foreign_signer(self): self.run_fixture(team='OTHERTEAM1', expected=1)
    def test_development_channel(self): self.run_fixture(bundle='dev.loganmondi.intent.test', expected=1)
    def test_foreign_host(self): self.run_fixture(host='/other/host', expected=1)
    def test_symlink_host(self): self.run_fixture(symlink='Library/Application Support/Intent/IntentNativeHost', expected=1)
    def test_symlink_manifest(self): self.run_fixture(symlink='Library/Google/Chrome/NativeMessagingHosts/intent_native_host.json', expected=1)
    def test_legacy_agent(self): self.run_fixture(legacy=True, expected=1)
    def test_delete_data_is_never_performed(self): self.run_fixture(argument='--delete-data', expected=2)


if __name__ == '__main__': unittest.main()
