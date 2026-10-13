#!/usr/bin/env python3
"""Run postinstall handoffs with a disposable app and mocked launch services."""
import os
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).with_name('package-postinstall.sh').read_text()


class PostinstallHandoff(unittest.TestCase):
    def check(self, choice, user='tester', launch_status=0):
        with tempfile.TemporaryDirectory(prefix='intent-postinstall-test-') as temporary:
            root = Path(temporary)
            app = root / 'Applications/Intent.app/Contents/MacOS/IntentApp'
            host = root / 'Library/Application Support/Intent/IntentNativeHost'
            for path in [app, host]:
                path.parent.mkdir(parents=True)
                path.write_text('not executed')
            (app.parent.parent / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleVersion': '202610140001'}))
            mocks = root / 'bin'
            mocks.mkdir()
            for name, text in {
                'stat': '#!/bin/bash\nprintf "%s\\n" "$MOCK_USER"\n',
                'id': '#!/bin/bash\necho 501\n',
                'launchctl': '#!/bin/bash\nprintf "%s\\n" "$@" > "$MOCK_LOG"\nexit "$MOCK_LAUNCH_STATUS"\n',
                'chown': '#!/bin/bash\nexit 0\n',
            }.items():
                path = mocks / name
                path.write_text(text)
                path.chmod(0o700)
            script = SOURCE.replace('SETUP_BROWSER_CHOICE=both', 'SETUP_BROWSER_CHOICE=' + choice)
            script = script.replace("'/Applications", "'" + str(root) + '/Applications')
            script = script.replace("'/Library", "'" + str(root) + '/Library')
            script = script.replace("'/System/Library", "'" + str(root) + '/no-system-library')
            script = script.replace('/usr/sbin/chown', str(mocks / 'chown'))
            target = root / 'postinstall'
            target.write_text(script)
            log = root / 'launch.log'
            result = subprocess.run(['/bin/bash', str(target)], capture_output=True,
                env=dict(os.environ, PATH=str(mocks)+':/usr/bin:/bin', MOCK_USER=user,
                         MOCK_LOG=str(log), MOCK_LAUNCH_STATUS=str(launch_status)))
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            receipt = root / 'Library/Application Support/Intent/onboarding-browser-choice.json'
            self.assertEqual(json.loads(receipt.read_text()), {'version': 1, 'browsers': choice, 'app_build': '202610140001'})
            self.assertEqual(receipt.stat().st_mode & 0o777, 0o644)
            self.assertFalse(list(receipt.parent.glob('.onboarding-browser-choice.*')))
            if user not in ('', 'root', 'loginwindow'):
                self.assertEqual(log.read_text().splitlines(), ['asuser', '501', 'sudo', '-u', user,
                    '/usr/bin/open', '-n', str(root / 'Applications/Intent.app'),
                    '--args', '--setup-browsers=' + choice])
            else:
                self.assertFalse(log.exists())
            if launch_status:
                self.assertIn('Open Intent from Applications', result.stderr.decode())

    def test_every_choice_launches_onboarding_for_the_console_user(self):
        for choice in ('firefox', 'chrome', 'both'):
            with self.subTest(choice=choice): self.check(choice)

    def test_loginwindow_never_receives_onboarding(self):
        for user in ('', 'root', 'loginwindow'):
            with self.subTest(user=user): self.check('both', user=user)

    def test_no_false_installer_failure_if_app_launch_needs_retry(self):
        self.check('firefox', launch_status=1)


if __name__ == '__main__': unittest.main()
