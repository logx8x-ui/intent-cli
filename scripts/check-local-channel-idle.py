#!/usr/bin/env python3
"""Read-only install guard, including pre-channel app-only intentions."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def active_engine(home, process_commands, now=None):
    home = Path(home)
    now = time.time() if now is None else now
    try:
        owner = json.loads((home / '.intent-engine' / 'owner.json').read_text())
        pid = int(owner.get('pid', 0))
        if pid > 0 and owner.get('activeSession') is True:
            try:
                os.kill(pid, 0)
                return 'The running Intent engine has an active intention.'
            except ProcessLookupError:
                pass
            except PermissionError:
                return 'The active Intent engine cannot be checked safely.'
    except (OSError, ValueError, TypeError):
        pass
    for folder, app_name in (('.intent', 'Intent'), ('.intent-test', 'Test Intent')):
        directory = home / folder
        try:
            rules = json.loads((directory / 'browser-rules.json').read_text())
            age = now - (float(rules['updatedAt']) + 978307200)
            if rules.get('active') is True and -1 <= age < 10:
                return f'{app_name} is publishing an active intention.'
        except (OSError, ValueError, TypeError, KeyError):
            pass
        # Older engines have no shared lease, and app-only selections may never
        # emit browser rules. Require both a live app process and an open journal.
        executable_suffix = f'/{app_name}.app/Contents/MacOS/IntentApp'
        if not any(executable_suffix in command for command in process_commands):
            continue
        journals = [directory / 'session-journal.json']
        accounts = directory / 'accounts'
        if accounts.is_dir() and not accounts.is_symlink():
            journals += [child / 'session-journal.json' for child in accounts.iterdir()
                         if child.is_dir() and not child.is_symlink()]
        for journal_path in journals:
            try:
                journal = json.loads(journal_path.read_text())
                records = journal.get('records', [])
                recovery = journal.get('recovery')
                if isinstance(recovery, dict):
                    records = [*records, recovery]
                if any(isinstance(record, dict) and record.get('endedAt') is None for record in records):
                    return f'{app_name} has an unfinished intention in its current workspace.'
            except (OSError, ValueError, TypeError):
                pass
    return None


if __name__ == '__main__':
    commands = subprocess.check_output(['/bin/ps', '-axo', 'command='], text=True).splitlines()
    blocker = active_engine(sys.argv[1], commands)
    if blocker:
        sys.exit(blocker + ' Finish it before installing either app. No app has been stopped.')
