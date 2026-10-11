import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('idle_guard', Path(__file__).with_name('check-local-channel-idle.py'))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class IdleGuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='intent-idle-')
        self.home = Path(self.temporary.name)
        self.command = '/test/Applications/Intent.app/Contents/MacOS/IntentApp'

    def tearDown(self):
        self.temporary.cleanup()

    def write(self, relative, value):
        target = self.home / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(value))

    def test_current_active_lease_blocks_even_without_browser_rules(self):
        self.write('.intent-engine/owner.json', {'pid': os.getpid(), 'activeSession': True})
        self.assertIsNotNone(guard.active_engine(self.home, []))

    def test_idle_lease_does_not_block(self):
        self.write('.intent-engine/owner.json', {'pid': os.getpid(), 'activeSession': False})
        self.assertIsNone(guard.active_engine(self.home, []))

    def test_legacy_app_only_intention_blocks_live_app(self):
        self.write('.intent/session-journal.json', {'records': [{'startedAt': 1, 'id': 'active'}]})
        self.assertIsNotNone(guard.active_engine(self.home, [self.command]))
        self.assertIsNone(guard.active_engine(self.home, []), 'Dead legacy process does not block recovery/install')

    def test_account_workspace_recovery_blocks_live_legacy_app(self):
        self.write('.intent/accounts/account/session-journal.json', {'records': [], 'recovery': {'startedAt': 1}})
        self.assertIsNotNone(guard.active_engine(self.home, [self.command]))

    def test_completed_history_does_not_block(self):
        self.write('.intent/session-journal.json', {'records': [{'startedAt': 1, 'endedAt': 2}]})
        self.assertIsNone(guard.active_engine(self.home, [self.command]))

    def test_other_idle_channel_is_not_treated_as_this_running_app(self):
        self.write('.intent-test/session-journal.json', {'records': [{'startedAt': 1}]})
        self.assertIsNone(guard.active_engine(self.home, [self.command]))
        self.assertIsNotNone(guard.active_engine(self.home, ['/test/Test Intent.app/Contents/MacOS/IntentApp']))

    def test_fresh_browser_rules_block_and_stale_rules_do_not(self):
        self.write('.intent/browser-rules.json', {'active': True, 'updatedAt': 100})
        self.assertIsNotNone(guard.active_engine(self.home, [], now=978307301))
        self.assertIsNone(guard.active_engine(self.home, [], now=978307400))


if __name__ == '__main__':
    unittest.main()
