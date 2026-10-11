#!/usr/bin/env python3
"""Read-only install guard, including pre-channel app-only intentions."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid
import argparse

SOURCE_ROOT = Path(__file__).resolve().parent.parent


def intent_cli_paths(home):
    """Exact shipped CLI locations, never an arbitrary process named Intent.

    The CLI can enforce app-only restrictions without publishing an engine lease
    or a browser/session journal. Both installed channels and the supported
    products in this checkout therefore have to be closed before replacement.
    Canonical paths also recognize aliases resolving to those same products.
    """
    home = Path(home)
    paths = [home / '.intent/bin/Intent', home / '.intent-test/bin/Intent',
             home / '.local/bin/intent', home / '.local/bin/Intent',
             home / '.local/bin/test-intent', Path('/opt/homebrew/bin/intent'),
             Path('/opt/homebrew/bin/test-intent'),
             Path('/Library/Application Support/Intent/Intent')]
    for build in ('.build', '.build-development', '.build-launch'):
        for architecture in ('', 'arm64-apple-macosx', 'x86_64-apple-macosx'):
            for configuration in ('debug', 'release'):
                paths.append(SOURCE_ROOT / build / architecture / configuration / 'Intent')
    return frozenset(os.path.realpath(path) for path in paths)


def valid_owner(owner):
    """Match the durable lease schema; truthy strings are not idle evidence."""
    if not isinstance(owner, dict):
        return False
    pid = owner.get('pid')
    if type(pid) is not int or not 0 < pid <= 2**31 - 1:
        return False
    if type(owner.get('activeSession')) is not bool:
        return False
    if owner.get('channel') not in ('launch', 'development'):
        return False
    generation = owner.get('generation')
    if not isinstance(generation, str):
        return False
    try:
        return str(uuid.UUID(generation)).lower() == generation.lower()
    except (ValueError, AttributeError):
        return False


def process_state(pid):
    """None is unknown, never proof that an owner is safely gone."""
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except OSError:
        return None


def owner_pid(owner):
    # A malformed record can still identify a process worth checking. Accept a
    # decimal string for that check only; valid_owner still rejects its schema.
    if not isinstance(owner, dict):
        return None
    pid = owner.get('pid')
    if isinstance(pid, str) and len(pid) <= 10 and pid.isascii() and pid.isdecimal():
        pid = int(pid)
    return pid if type(pid) is int and 0 < pid <= 2**31 - 1 else None


def active_engine(home, process_commands, now=None):
    home = Path(home)
    now = time.time() if now is None else now
    process_commands = tuple(process_commands)
    live_app = any(f'/{name}.app/Contents/MacOS/IntentApp' in command
                   for name in ('Intent', 'Test Intent') for command in process_commands)
    owner = None
    malformed_owner = False
    try:
        path = home / '.intent-engine' / 'owner.json'
        if path.is_symlink() or path.stat().st_size > 16_384:
            malformed_owner = True
        else:
            owner = json.loads(path.read_text())
            malformed_owner = not valid_owner(owner)
    except FileNotFoundError:
        pass
    except (OSError, ValueError, TypeError):
        malformed_owner = True
    pid = owner_pid(owner)
    state = process_state(pid) if pid is not None else False
    if malformed_owner:
        if state is not False or live_app:
            return 'The running Intent engine’s ownership cannot be checked safely.'
    elif owner is not None and state is not False:
        if state is None:
            return 'The Intent engine process cannot be checked safely.'
        if owner['activeSession']:
            return 'The running Intent engine has an active intention.'
        # This preserves the existing confirmed-idle install path. The current
        # lease does not publish draft/preparation state; this guard must not be
        # represented as proof of canYieldEngine for those separate states.
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


def closed_engine(home, process_commands):
    """Installation cannot infer preparation/draft safety from activeSession."""
    commands = tuple(process_commands)
    blocker = active_engine(home, commands)
    if blocker:
        return blocker
    cli_paths = intent_cli_paths(home)
    for command in commands:
        if Path(command).is_absolute() and os.path.realpath(command) in cli_paths:
            return 'An Intent command-line process is still running and may have active restrictions.'
        if (any(f'/{name}.app/Contents/MacOS/IntentApp' in command
                for name in ('Intent', 'Test Intent'))
                or Path(command).name in ('IntentApp', 'TestIntentApp')):
            return 'Intent or Test Intent is still running, including selection or preparation.'
    path = Path(home) / '.intent-engine' / 'owner.json'
    try:
        if path.is_symlink() or path.stat().st_size > 16_384:
            return 'The Intent engine ownership cannot be checked safely.'
        owner = json.loads(path.read_text())
    except FileNotFoundError:
        return None
    except (OSError, ValueError, TypeError):
        return 'The Intent engine ownership cannot be checked safely.'
    pid = owner_pid(owner)
    # Positively dead owners permit recovery. Unknown or live owners do not,
    # even when a stale idle flag exists and the advisory lock is currently free.
    if pid is None or process_state(pid) is not False:
        return 'The Intent engine process is still running or cannot be checked safely.'
    return None


def process_commands_for_user(uid=None):
    """Read full executable names without arguments or another user's state."""
    uid = os.getuid() if uid is None else uid
    output = subprocess.check_output(
        ['/bin/ps', '-ww', '-axo', 'pid=,uid=,comm='], text=True)
    commands = []
    for line in output.splitlines():
        columns = line.strip().split(None, 2)
        if (len(columns) != 3 or not columns[0].isascii()
                or not columns[0].isdecimal() or not columns[1].isascii()
                or not columns[1].isdecimal() or not 0 <= int(columns[0]) <= 2**31 - 1
                or not 0 <= int(columns[1]) <= 2**32 - 1):
            raise ValueError('The running application inventory cannot be checked safely.')
        if int(columns[1]) == uid:
            commands.append(columns[2])
    if not output.strip():
        raise ValueError('The running application inventory is unavailable.')
    return tuple(commands)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('home')
    parser.add_argument('--require-closed', action='store_true')
    args = parser.parse_args()
    try:
        if args.require_closed:
            blocker = closed_engine(args.home, process_commands_for_user())
        else:
            commands = subprocess.check_output(['/bin/ps', '-axo', 'command='], text=True).splitlines()
            blocker = active_engine(args.home, commands)
    except (OSError, ValueError, subprocess.SubprocessError):
        blocker = 'The running application inventory cannot be checked safely.'
    if blocker:
        action = 'Close both Intent apps and any Intent command-line session before installing.' if args.require_closed else 'Finish it before installing either app.'
        sys.exit(blocker + ' ' + action + ' No app has been stopped.')
