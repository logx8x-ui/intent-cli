#!/usr/bin/env python3
"""Retire only idle installer target helpers, never another channel/browser."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def helper_pids(rows, uid, target_paths):
    targets = {os.path.normpath(str(path)) for path in target_paths}
    return {pid for pid, owner, executable in rows if owner == uid and pid > 0
            and os.path.normpath(executable) in targets}


def process_rows():
    output = subprocess.check_output(['/bin/ps', '-axo', 'pid=,uid=,comm='], text=True)
    rows = []
    for line in output.splitlines():
        columns = line.strip().split(None, 2)
        if len(columns) == 3:
            rows.append((int(columns[0]), int(columns[1]), columns[2]))
    return rows


def retire(target_paths, rows=process_rows, uid=None, terminate=None, clock=time.monotonic, sleep=time.sleep):
    uid = os.getuid() if uid is None else uid
    terminate = (lambda pid: os.kill(pid, signal.SIGTERM)) if terminate is None else terminate
    original = helper_pids(rows(), uid, target_paths)
    for pid in original:
        # Recheck the exact process path/UID immediately before signalling.
        if pid not in helper_pids(rows(), uid, target_paths):
            continue
        try:
            terminate(pid)
        except ProcessLookupError:
            pass
    deadline = clock() + 3
    while original.intersection(helper_pids(rows(), uid, target_paths)):
        if clock() >= deadline:
            raise RuntimeError('The previous channel helper has not stopped. No executable has been replaced.')
        sleep(.05)
    return len(original)


if __name__ == '__main__':
    paths = [Path(value) for value in sys.argv[1:]]
    if not paths or any(not path.is_absolute() or path.name != 'IntentNativeHost' for path in paths):
        sys.exit('Pass only absolute installer target IntentNativeHost paths.')
    try:
        retire(paths)
    except (OSError, ValueError, RuntimeError) as error:
        sys.exit(str(error))
