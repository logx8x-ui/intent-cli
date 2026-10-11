import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('idle_guard', Path(__file__).with_name('check-local-channel-idle.py'))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
transaction_path = Path(__file__).with_name('local-channel-install-transaction.py')
transaction_spec = importlib.util.spec_from_file_location('install_transaction', transaction_path)
transaction = importlib.util.module_from_spec(transaction_spec)
transaction_spec.loader.exec_module(transaction)


class IdleGuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='intent-idle-')
        self.home = Path(self.temporary.name)
        self.command = '/test/Applications/Intent.app/Contents/MacOS/IntentApp'
        # Fixture liveness never probes, signals or changes a daily app process.
        probe_patch = patch.object(guard.os, 'kill')
        self.probe = probe_patch.start()
        self.addCleanup(probe_patch.stop)

    def owner(self, **changes):
        return {'pid': 101, 'channel': 'launch',
                'generation': '10000000-0000-0000-0000-000000000001',
                'activeSession': False, **changes}

    def tearDown(self):
        self.temporary.cleanup()

    def write(self, relative, value):
        target = self.home / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(value))

    def test_current_active_lease_blocks_even_without_browser_rules(self):
        self.write('.intent-engine/owner.json', self.owner(activeSession=True))
        self.assertIsNotNone(guard.active_engine(self.home, []))

    def test_idle_lease_does_not_block(self):
        self.write('.intent-engine/owner.json', self.owner())
        self.assertIsNone(guard.active_engine(self.home, [self.command]))

    def test_malformed_live_owner_cannot_certify_idle(self):
        cases = [self.owner(activeSession='false'), self.owner(activeSession=0),
                 self.owner(channel='unknown'), self.owner(generation='bad'),
                 self.owner(pid='101'), {'pid': 101},
                 self.owner(pid=True), self.owner(pid=101.0),
                 self.owner(pid=0), self.owner(pid=-1),
                 self.owner(pid=2**31), self.owner(pid='1' * 5000), [], None]
        for owner in cases:
            with self.subTest(owner=owner):
                self.write('.intent-engine/owner.json', owner)
                self.assertIsNotNone(guard.active_engine(self.home, [self.command]))
        for owner in cases[:6]:
            with self.subTest(identified_pid=owner):
                self.write('.intent-engine/owner.json', owner)
                self.assertIsNotNone(guard.active_engine(self.home, []))

    def test_broken_json_with_live_app_refuses_without_changing_files(self):
        target = self.home / '.intent-engine/owner.json'
        target.parent.mkdir(parents=True)
        target.write_text('{broken')
        before = target.read_bytes()
        self.assertIsNotNone(guard.active_engine(self.home, [self.command]))
        self.assertEqual(target.read_bytes(), before)
        self.assertIsNone(guard.active_engine(self.home, []))

    def test_stale_dead_owner_permits_recovery_install(self):
        self.probe.side_effect = ProcessLookupError
        for owner in (self.owner(activeSession=True), self.owner(activeSession='false')):
            with self.subTest(owner=owner):
                self.write('.intent-engine/owner.json', owner)
                self.assertIsNone(guard.active_engine(self.home, []))

    def test_uncheckable_process_never_certifies_idle(self):
        for error in (PermissionError, OSError):
            self.probe.side_effect = error
            self.write('.intent-engine/owner.json', self.owner())
            self.assertIsNotNone(guard.active_engine(self.home, []))

    def test_unreadable_live_metadata_refuses(self):
        self.write('.intent-engine/owner.json', self.owner())
        with patch.object(Path, 'read_text', side_effect=PermissionError):
            self.assertIsNotNone(guard.active_engine(self.home, [self.command]))

    def test_oversized_or_linked_live_metadata_refuses(self):
        target = self.home / '.intent-engine/owner.json'
        target.parent.mkdir(parents=True)
        target.write_text(' ' * 16_385)
        self.assertIsNotNone(guard.active_engine(self.home, [self.command]))
        target.unlink()
        outside = self.home / 'other.json'
        outside.write_text(json.dumps(self.owner()))
        target.symlink_to(outside)
        self.assertIsNotNone(guard.active_engine(self.home, [self.command]))

    def test_valid_idle_test_channel_is_allowed(self):
        self.write('.intent-engine/owner.json', self.owner(channel='development'))
        self.assertIsNone(guard.active_engine(self.home, ['/test/Test Intent.app/Contents/MacOS/IntentApp']))

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

    def test_closed_mode_refuses_idle_or_preparing_apps_without_active_rules(self):
        for command in (self.command, '/test/Applications/Test Intent.app/Contents/MacOS/IntentApp',
                        '/test/.intent/bin/IntentApp', 'IntentApp'):
            with self.subTest(command=command):
                self.assertIsNotNone(guard.closed_engine(self.home, [command]))
        self.write('.intent-engine/owner.json', self.owner())
        self.assertIsNotNone(guard.closed_engine(self.home, []), 'Live idle flag cannot prove preparation absent')
        self.assertIsNone(guard.active_engine(self.home, [self.command]), 'Default schema contract is preserved')

    def test_closed_mode_dead_recovery_and_unknown_metadata(self):
        self.probe.side_effect = ProcessLookupError
        self.write('.intent-engine/owner.json', self.owner(activeSession='false'))
        self.assertIsNone(guard.closed_engine(self.home, []))
        self.write('.intent-engine/owner.json', {'activeSession': False})
        self.assertIsNotNone(guard.closed_engine(self.home, []))
        self.write('.intent-engine/owner.json', self.owner())
        self.probe.side_effect = PermissionError
        self.assertIsNotNone(guard.closed_engine(self.home, []))

    def test_closed_mode_refuses_exact_installed_cli_without_lease_or_rules(self):
        commands = [self.home / '.intent/bin/Intent', self.home / '.intent-test/bin/Intent',
                    self.home / '.local/bin/intent', self.home / '.local/bin/Intent',
                    self.home / '.local/bin/test-intent',
                    Path('/opt/homebrew/bin/intent'), Path('/opt/homebrew/bin/test-intent'),
                    Path('/Library/Application Support/Intent/Intent')]
        for command in commands:
            with self.subTest(command=command):
                self.assertIsNotNone(guard.closed_engine(self.home, [str(command)]),
                                     'An app-only CLI session need not publish lease, rules or journal')
        self.assertFalse((self.home / '.intent-engine').exists())

    def test_closed_mode_refuses_supported_source_cli_and_resolves_aliases(self):
        source = self.home / 'source'
        with patch.object(guard, 'SOURCE_ROOT', source):
            for build in ('.build', '.build-development', '.build-launch'):
                for architecture in ('', 'arm64-apple-macosx', 'x86_64-apple-macosx'):
                    for configuration in ('debug', 'release'):
                        command = source / build / architecture / configuration / 'Intent'
                        with self.subTest(command=command):
                            self.assertIsNotNone(guard.closed_engine(self.home, [str(command)]))
            target = self.home / '.intent/bin/Intent'
            target.parent.mkdir(parents=True)
            target.touch()
            alias = self.home / 'custom-command'
            alias.symlink_to(target)
            self.assertIsNotNone(guard.closed_engine(self.home, [str(alias)]))
            for command in ('Intent', '/unrelated/Intent',
                            str(source / 'unrelated/release/Intent'),
                            str(source / '.build/release/IntentCoreSpec')):
                with self.subTest(unrelated=command):
                    self.assertIsNone(guard.closed_engine(self.home, [command]))

    def test_process_inventory_uses_exact_user_and_full_executables(self):
        output = '0 0 kernel_task\n1 501 /test/Test Intent.app/Contents/MacOS/IntentApp\n2 502 /test/Intent.app/Contents/MacOS/IntentApp\n'
        with patch.object(guard.subprocess, 'check_output', return_value=output) as query:
            self.assertEqual(guard.process_commands_for_user(501),
                             ('/test/Test Intent.app/Contents/MacOS/IntentApp',))
            self.assertEqual(query.call_args.args[0], ['/bin/ps', '-ww', '-axo', 'pid=,uid=,comm='])
        for output in ('', '1 501', 'bad 501 /test', '1 bad /test', '-1 501 /test'):
            with self.subTest(output=output), patch.object(guard.subprocess, 'check_output', return_value=output):
                with self.assertRaises(ValueError):
                    guard.process_commands_for_user(501)


class InstallationTransactionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='intent-install-lease-')
        self.home = Path(self.temporary.name)
        self.children = []
        self.addCleanup(self.cleanup)

    def cleanup(self):
        # Only fixture children are involved. Their own wait loops are bounded.
        for child in self.children:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=5)
            if child.stdout:
                child.stdout.close()
            if child.stderr:
                child.stderr.close()
        self.temporary.cleanup()

    def wait_for(self, path, child=None):
        deadline = time.monotonic() + 5
        while not path.exists():
            if child is not None and child.poll() is not None:
                self.fail('Fixture exited before its boundary: ' + child.stderr.read())
            if time.monotonic() >= deadline:
                self.fail('Fixture boundary timed out: ' + path.name)
            time.sleep(.01)

    def peer_lock_status(self):
        # Real subprocess flock, using only this fixture's synthetic engine.
        code = '''import fcntl,os,sys
fd=os.open(sys.argv[1],os.O_RDWR)
try:fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
except BlockingIOError:sys.exit(3)
os.close(fd)
'''
        return subprocess.run([sys.executable, '-B', '-c', code,
                               str(self.home / '.intent-engine/engine.lock')],
                              capture_output=True, text=True).returncode

    def test_private_existing_lock_is_not_replaced_and_owner_is_not_published(self):
        with transaction.installation_lease(self.home, process_commands=lambda: []):
            lock = self.home / '.intent-engine/engine.lock'
            inode = lock.stat().st_ino
            self.assertEqual(self.peer_lock_status(), 3)
            self.assertEqual(lock.stat().st_mode & 0o777, 0o600)
            self.assertEqual(lock.parent.stat().st_mode & 0o777, 0o700)
            self.assertFalse((lock.parent / 'owner.json').exists())
        self.assertEqual(self.peer_lock_status(), 0)
        with transaction.installation_lease(self.home, process_commands=lambda: []):
            self.assertEqual(lock.stat().st_ino, inode)

    def test_both_running_channels_refuse_before_child_or_coordination_mutation(self):
        sentinel = self.home / 'installed'
        for app in ('Intent', 'Test Intent'):
            with self.subTest(app=app), self.assertRaises(transaction.InstallRefused):
                transaction.run_installation(self.home,
                    [sys.executable, '-c', 'from pathlib import Path;import sys;Path(sys.argv[1]).touch()', str(sentinel)],
                    process_commands=lambda: [f'/fixture/{app}.app/Contents/MacOS/IntentApp'])
            self.assertFalse(sentinel.exists())
            self.assertFalse((self.home / '.intent-engine').exists())

    def test_app_appearing_after_preflight_is_rechecked_under_lock(self):
        inventories = iter([[], ['/fixture/Test Intent.app/Contents/MacOS/IntentApp']])
        with self.assertRaises(transaction.InstallRefused):
            with transaction.installation_lease(self.home, process_commands=lambda: next(inventories)):
                self.fail('A new preparing app must prevent commit')
        self.assertEqual(self.peer_lock_status(), 0)

    def test_cli_only_session_refuses_before_child_or_coordination_mutation(self):
        sentinel = self.home / 'installed'
        commands = [self.home / '.intent/bin/Intent', self.home / '.intent-test/bin/Intent',
                    transaction.guard.SOURCE_ROOT / '.build-development/arm64-apple-macosx/release/Intent',
                    Path('/Library/Application Support/Intent/Intent')]
        for command in commands:
            with self.subTest(command=command), self.assertRaises(transaction.InstallRefused):
                transaction.run_installation(self.home,
                    [sys.executable, '-c', 'from pathlib import Path;import sys;Path(sys.argv[1]).touch()', str(sentinel)],
                    process_commands=lambda: [str(command)])
            self.assertFalse(sentinel.exists())
            self.assertFalse((self.home / '.intent-engine').exists())

    def test_cli_appearing_after_preflight_is_rechecked_under_lock(self):
        inventories = iter([[], [str(self.home / '.intent-test/bin/Intent')]])
        with self.assertRaises(transaction.InstallRefused):
            with transaction.installation_lease(self.home, process_commands=lambda: next(inventories)):
                self.fail('A new unleased CLI must prevent commit')
        self.assertEqual(self.peer_lock_status(), 0)

    def test_unknown_inventory_refuses_before_child(self):
        def unknown():
            raise ValueError('unavailable')
        with self.assertRaises(ValueError):
            transaction.run_installation(self.home, [sys.executable, '-c', 'raise AssertionError'], process_commands=unknown)
        self.assertFalse((self.home / '.intent-engine').exists())

    def test_unsafe_directory_and_lock_refuse(self):
        directory = self.home / '.intent-engine'
        outside = self.home / 'outside'
        outside.mkdir(mode=0o700)
        directory.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(OSError):
            with transaction.installation_lease(self.home, process_commands=lambda: []):
                self.fail('Symlink must fail')
        directory.unlink()
        directory.mkdir(mode=0o755)
        with self.assertRaises(transaction.InstallRefused):
            with transaction.installation_lease(self.home, process_commands=lambda: []):
                self.fail('Nonprivate directory must fail')
        directory.chmod(0o700)
        lock = directory / 'engine.lock'
        other_lock = outside / 'lock'
        other_lock.write_text('unchanged')
        other_lock.chmod(0o600)
        lock.symlink_to(other_lock)
        with self.assertRaises(OSError):
            with transaction.installation_lease(self.home, process_commands=lambda: []):
                self.fail('Symlink lock must fail')
        self.assertEqual(other_lock.read_text(), 'unchanged')
        lock.unlink()
        os.link(other_lock, lock)
        with self.assertRaises(transaction.InstallRefused):
            with transaction.installation_lease(self.home, process_commands=lambda: []):
                self.fail('Shared/hardlinked lock must fail')

    def test_failed_child_returns_status_and_releases_lease(self):
        status = transaction.run_installation(self.home,
            [sys.executable, '-c', 'import sys;sys.exit(7)'], process_commands=lambda: [])
        self.assertEqual(status, 7)
        self.assertEqual(self.peer_lock_status(), 0)

    def test_live_idle_owner_and_malformed_unknown_owner_refuse_commit(self):
        directory = self.home / '.intent-engine'
        directory.mkdir(mode=0o700)
        owner_path = directory / 'owner.json'
        for owner in ({'pid': os.getpid(), 'activeSession': False, 'channel': 'launch',
                       'generation': '10000000-0000-0000-0000-000000000001'}, {'activeSession': False}):
            with self.subTest(owner=owner):
                owner_path.write_text(json.dumps(owner))
                before = owner_path.read_bytes()
                with self.assertRaises(transaction.InstallRefused):
                    transaction.run_installation(self.home, [sys.executable, '-c', 'raise AssertionError'],
                                                 process_commands=lambda: [])
                self.assertEqual(owner_path.read_bytes(), before)

    def test_home_owner_is_validated_before_coordination_mutation(self):
        with self.assertRaises(transaction.InstallRefused):
            with transaction.installation_lease(self.home, process_commands=lambda: [], uid=os.getuid() + 1):
                self.fail('Wrong owner cannot reserve a lease')
        self.assertFalse((self.home / '.intent-engine').exists())

    def paused_install(self, shell=False):
        ready, release, complete = (self.home / name for name in ('ready', 'release', 'complete'))
        commit = '''from pathlib import Path
import sys,time
ready,release,complete=map(Path,sys.argv[1:])
ready.touch()
deadline=time.monotonic()+5
while not release.exists():
 if time.monotonic()>deadline:sys.exit(8)
 time.sleep(.01)
complete.touch()
'''
        runner = '''import importlib.util,sys
sys.dont_write_bytecode=True
spec=importlib.util.spec_from_file_location('production_transaction',sys.argv[1])
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
sys.exit(module.run_installation(sys.argv[2],sys.argv[3:],process_commands=lambda:[]))
'''
        command = [sys.executable, '-B', '-c', commit, str(ready), str(release), str(complete)]
        if shell:
            command = ['/bin/bash', '-c', 'set -euo pipefail; fixture_commit() { '
                       + shlex.join(command) + '; }; fixture_commit']
        child = subprocess.Popen([sys.executable, '-B', '-c', runner, str(transaction_path), str(self.home), *command],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.children.append(child)
        self.wait_for(ready, child)
        return child, release, complete

    def test_actual_child_holds_lease_until_all_commit_effects_finish(self):
        child, release, complete = self.paused_install()
        try:
            self.assertEqual(self.peer_lock_status(), 3, 'A competing engine cannot acquire during commit')
            with self.assertRaises(transaction.InstallRefused):
                with transaction.installation_lease(self.home, process_commands=lambda: []):
                    self.fail('A second installer cannot overlap')
        finally:
            release.touch()
        self.assertEqual(child.wait(timeout=5), 0, child.stderr.read())
        self.assertTrue(complete.exists())
        self.assertEqual(self.peer_lock_status(), 0, 'Normal app opening can acquire after commit')

    def test_actual_exported_bash_function_handoff_runs_under_lease(self):
        marker = self.home / 'shell-commit'
        lock = self.home / '.intent-engine/engine.lock'
        probe = '''import fcntl,os,sys
from pathlib import Path
fd=os.open(sys.argv[1],os.O_RDWR)
try:fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
except BlockingIOError:Path(sys.argv[2]).write_text('held');sys.exit(0)
sys.exit('Commit ran without the engine lease')
'''
        runner = self.home / 'runner.py'
        runner.write_text('''import importlib.util,sys
sys.dont_write_bytecode=True
spec=importlib.util.spec_from_file_location('production_transaction',sys.argv[1])
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
sys.exit(module.run_installation(sys.argv[2],sys.argv[3:],process_commands=lambda:[]))
''')
        function = shlex.join([sys.executable, '-B', '-c', probe, str(lock), str(marker)])
        handoff = shlex.join([sys.executable, '-B', str(runner), str(transaction_path), str(self.home),
                              '/bin/bash', '-c', 'set -euo pipefail; fixture_commit'])
        script = 'set -euo pipefail; fixture_commit() { ' + function + '; }; export -f fixture_commit; ' + handoff
        result = subprocess.run(['/bin/bash', '-c', script], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(marker.read_text(), 'held')
        self.assertEqual(self.peer_lock_status(), 0)

    def test_wrapper_crash_does_not_unlock_surviving_install_child(self):
        child, release, complete = self.paused_install(shell=True)
        try:
            child.terminate()  # This isolated fixture wrapper, never an Intent app.
            child.wait(timeout=5)
            self.assertEqual(self.peer_lock_status(), 3, 'Child inherited the same held lease')
        finally:
            release.touch()
        self.wait_for(complete)
        deadline = time.monotonic() + 2
        while self.peer_lock_status() != 0 and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertEqual(self.peer_lock_status(), 0)

    def test_target_commit_preserves_other_channel_data_and_registrations(self):
        preserved = [self.home / path for path in (
            '.intent/session-journal.json', '.intent-test/session-journal.json',
            'Applications/Intent.app/daily', 'Library/NativeMessagingHosts/elsewhere.json')]
        for path in preserved:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'private fixture data')
        selected = self.home / 'Applications/Test Intent.app/updated'
        code = 'from pathlib import Path;import sys;Path(sys.argv[1]).parent.mkdir(parents=True,exist_ok=True);Path(sys.argv[1]).write_text("new test binary")'
        self.assertEqual(transaction.run_installation(self.home,
            [sys.executable, '-c', code, str(selected)], process_commands=lambda: []), 0)
        self.assertEqual(selected.read_text(), 'new test binary')
        for path in preserved:
            self.assertEqual(path.read_bytes(), b'private fixture data')


if __name__ == '__main__':
    unittest.main()
