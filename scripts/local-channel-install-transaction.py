#!/usr/bin/env python3
"""Hold the existing per-user engine lease across a local install commit.

The command is synchronous and receives a copy of the lock descriptor, so a
wrapper crash cannot release the lease while its installation child survives.
No app is terminated and no owner/workspace/native-host registration is written.
This contract covers lease-aware engines; older unleased apps and command-line
sessions must remain closed. Known installed/source CLIs are checked before and
under the lease; an arbitrary unleased executable launched later cannot be fenced
by this script-only transaction.
"""
import argparse
from contextlib import contextmanager
import fcntl
import importlib.util
import os
from pathlib import Path
import stat
import subprocess
import sys

sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location(
    'intent_local_install_guard', Path(__file__).with_name('check-local-channel-idle.py'))
guard = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(guard)


class InstallRefused(RuntimeError):
    pass


def _private_metadata(fd, directory, uid):
    metadata = os.fstat(fd)
    expected_type = stat.S_ISDIR if directory else stat.S_ISREG
    if (not expected_type(metadata.st_mode) or metadata.st_uid != uid
            or metadata.st_mode & 0o077 or (not directory and metadata.st_nlink != 1)):
        raise InstallRefused('The private Intent engine lease is not safe to use.')
    return metadata


@contextmanager
def installation_lease(home, process_commands=guard.process_commands_for_user, uid=None):
    uid = os.getuid() if uid is None else uid
    home = Path(home)
    if not home.is_absolute():
        raise InstallRefused('The installation home must be an absolute path.')
    descriptors = []
    try:
        root_fd = os.open(home, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        descriptors.append(root_fd)
        root_info = os.fstat(root_fd)
        if not stat.S_ISDIR(root_info.st_mode) or root_info.st_uid != uid:
            raise InstallRefused('The installation home is not owned by this user.')
        # Refuse running/preparing apps before creating even coordination files.
        blocker = guard.closed_engine(home, process_commands())
        if blocker:
            raise InstallRefused(blocker)
        try:
            os.mkdir('.intent-engine', 0o700, dir_fd=root_fd)
        except FileExistsError:
            pass
        directory_fd = os.open('.intent-engine', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                               dir_fd=root_fd)
        descriptors.append(directory_fd)
        directory_info = _private_metadata(directory_fd, True, uid)
        lease_fd = os.open('engine.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC,
                           0o600, dir_fd=directory_fd)
        descriptors.append(lease_fd)
        lease_info = _private_metadata(lease_fd, False, uid)
        try:
            fcntl.flock(lease_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise InstallRefused('An Intent engine or another installer still holds the engine lease.') from error
        # Validate the same named directory/file after acquisition, then inspect
        # ownership and all relevant processes again under the held lease.
        current_directory = os.stat('.intent-engine', dir_fd=root_fd, follow_symlinks=False)
        current_lease = os.stat('engine.lock', dir_fd=directory_fd, follow_symlinks=False)
        if ((current_directory.st_dev, current_directory.st_ino) != (directory_info.st_dev, directory_info.st_ino)
                or (current_lease.st_dev, current_lease.st_ino) != (lease_info.st_dev, lease_info.st_ino)):
            raise InstallRefused('The Intent engine lease changed during installation preparation.')
        blocker = guard.closed_engine(home, process_commands())
        if blocker:
            raise InstallRefused(blocker)
        yield lease_fd
    finally:
        # Close references; do not explicitly LOCK_UN, which would unlock a
        # surviving installation child sharing the same open-file description.
        for descriptor in reversed(descriptors):
            os.close(descriptor)


def run_installation(home, command, process_commands=guard.process_commands_for_user):
    if not command:
        raise InstallRefused('No installation command was supplied.')
    with installation_lease(home, process_commands=process_commands) as descriptor:
        child = subprocess.Popen(command, pass_fds=(descriptor,))
        try:
            return child.wait()
        except KeyboardInterrupt:
            # The child normally receives the terminal's interrupt too. Retain
            # ownership until it exits rather than unlocking mid-replacement.
            while True:
                try:
                    child.wait()
                    break
                except KeyboardInterrupt:
                    continue
            raise


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('home')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    try:
        sys.exit(run_installation(args.home, command))
    except (InstallRefused, OSError, ValueError, subprocess.SubprocessError) as error:
        sys.exit(str(error) + ' Close both Intent apps and any Intent command-line session, then retry. No app has been stopped.')
