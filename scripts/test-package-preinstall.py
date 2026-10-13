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
              bundle=None, legacy=False, expected=0, os_version='13.0', os_status=0,
              arm64='1', arm_status=0, machine='arm64', machine_status=0,
              architecture='arm64', target='/'):
        with tempfile.TemporaryDirectory(prefix='intent-package-guard-') as temp:
            root = Path(temp)
            destinations = root / 'destinations'
            destinations.mkdir()
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            probe = bin_dir / 'pgrep'
            probe.write_text('#!/bin/bash\n[[ "$2" == "$MOCK_RUNNING" ]] && exit 0\nexit "$MOCK_STATUS"\n')
            probe.chmod(0o700)
            for name, body in {
                'sw_vers': 'printf "%s\\n" "$MOCK_OS"\nexit "$MOCK_OS_STATUS"',
                'sysctl': 'printf "%s\\n" "$MOCK_ARM64"\nexit "$MOCK_ARM_STATUS"',
                'uname': 'printf "%s\\n" "$MOCK_MACHINE"\nexit "$MOCK_MACHINE_STATUS"',
            }.items():
                tool = bin_dir / name
                tool.write_text('#!/bin/bash\n' + body + '\n')
                tool.chmod(0o700)
            # Rewrite literal absolute destinations, without adding a production
            # environment override that could weaken an actual installer.
            script = root / 'preinstall'
            script.write_text(SOURCE.replace("'/Applications", "'" + str(destinations) + '/Applications')
                              .replace("'/Library", "'" + str(destinations) + '/Library')
                              .replace('/usr/bin/sw_vers', str(bin_dir / 'sw_vers'))
                              .replace('/usr/sbin/sysctl', str(bin_dir / 'sysctl'))
                              .replace('/usr/bin/uname', str(bin_dir / 'uname'))
                              .replace('RELEASE_ARCHITECTURE=arm64', 'RELEASE_ARCHITECTURE=' + architecture))
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
                       MOCK_RUNNING=running, MOCK_STATUS=str(process_status), MOCK_OS=os_version,
                       MOCK_OS_STATUS=str(os_status), MOCK_ARM64=arm64, MOCK_ARM_STATUS=str(arm_status),
                       MOCK_MACHINE=machine, MOCK_MACHINE_STATUS=str(machine_status))
            result = subprocess.run(['/bin/bash', str(script), 'Intent.pkg', '/', target], env=env, capture_output=True)
            self.assertEqual(result.returncode, expected, result.stderr.decode())
            after = {str(p): (os.readlink(p) if p.is_symlink() else p.read_bytes())
                     for p in destinations.rglob('*') if p.is_symlink() or p.is_file()}
            self.assertEqual(before, after, 'preinstall must be read-only')

    def test_clean_install(self): self.check()
    def test_newer_supported_macos(self):
        for version in ('13.0.1', '14.7', '26.1'):
            with self.subTest(version=version): self.check(os_version=version)
    def test_old_macos_refused(self):
        for version in ('10.15.7', '11.7', '12.7.6'):
            with self.subTest(version=version): self.check(os_version=version, expected=1)
    def test_macos_probe_fails_closed(self):
        self.check(os_status=1, expected=1)
        for version in ('', 'unknown', '13', '13.x', '13.0\n12.0', '999999999999999999999.0'):
            with self.subTest(version=version): self.check(os_version=version, expected=1)
    def test_intel_refused_by_arm64_package(self): self.check(arm64='0', machine='x86_64', expected=1)
    def test_arm64_probe_fails_closed(self):
        self.check(arm_status=1, expected=1)
        for value in ('', 'unknown', '2', '1\n0'):
            with self.subTest(value=value): self.check(arm64=value, expected=1)
    def test_rosetta_does_not_hide_apple_silicon(self): self.check(arm64='1', machine='x86_64')
    def test_universal_package_accepts_both_architectures(self):
        for machine in ('arm64', 'x86_64'):
            with self.subTest(machine=machine): self.check(architecture='universal', machine=machine, arm64='0')
    def test_universal_package_refuses_unknown_machine(self):
        self.check(architecture='universal', machine_status=1, expected=1)
        self.check(architecture='universal', machine='ppc', expected=1)
    def test_invalid_package_architecture(self): self.check(architecture='unknown', expected=1)
    def test_nonstartup_volume_refused(self): self.check(target='/Volumes/Other Mac', expected=1)
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
