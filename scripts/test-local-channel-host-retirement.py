import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('host_retirement', Path(__file__).with_name('retire-local-channel-hosts.py'))
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class RetirementTests(unittest.TestCase):
    target = '/Users/example/Applications/Intent.app/Contents/Helpers/IntentNativeHost'
    other = '/Users/example/Applications/Test Intent.app/Contents/Helpers/IntentNativeHost'
    binary = '/Users/example/.intent/bin/IntentNativeHost'

    def test_only_exact_target_channel_paths_and_user(self):
        rows = [(1, 501, self.target), (2, 501, self.other), (3, 502, self.target),
                (4, 501, self.target + 'QA'), (5, 501, '/tmp/IntentNativeHost'), (6, 501, self.binary)]
        self.assertEqual(policy.helper_pids(rows, 501, [self.target, self.binary]), {1, 6})

    def test_retirement_waits_for_target_exit_and_preserves_other_channel(self):
        running = [(1, 501, self.target), (2, 501, self.other)]
        signalled = []
        elapsed = [0]
        def signal(pid):
            signalled.append(pid)
        def wait(duration):
            elapsed[0] += duration
            running[:] = [row for row in running if row[0] not in signalled]
        self.assertEqual(policy.retire([self.target], rows=lambda: running[:], uid=501,
                                     terminate=signal, clock=lambda: elapsed[0], sleep=wait), 1)
        self.assertEqual(signalled, [1])
        self.assertEqual(running, [(2, 501, self.other)])
        self.assertGreater(elapsed[0], 0, 'Replacement cannot start before helper termination is observed')

    def test_changed_identity_between_snapshot_and_signal_is_not_killed(self):
        snapshots = [[(1, 501, self.target)], [(1, 501, self.other)], [(1, 501, self.other)]]
        signalled = []
        policy.retire([self.target], rows=lambda: snapshots.pop(0) if len(snapshots) > 1 else snapshots[0],
                      uid=501, terminate=signalled.append)
        self.assertEqual(signalled, [])

    def test_helper_that_does_not_exit_blocks_replacement_without_escalation(self):
        elapsed = [0]
        signalled = []
        with self.assertRaisesRegex(RuntimeError, 'No executable has been replaced'):
            policy.retire([self.target], rows=lambda: [(1, 501, self.target)], uid=501,
                          terminate=signalled.append, clock=lambda: elapsed[0],
                          sleep=lambda duration: elapsed.__setitem__(0, elapsed[0] + duration))
        self.assertEqual(signalled, [1], 'No SIGKILL escalation or repeated signalling')

    def test_no_target_helpers_does_not_signal_anyone(self):
        signalled = []
        self.assertEqual(policy.retire([self.target], rows=lambda: [(2, 501, self.other)], uid=501,
                                     terminate=signalled.append), 0)
        self.assertEqual(signalled, [])


if __name__ == '__main__':
    unittest.main()
