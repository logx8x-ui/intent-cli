#!/usr/bin/env python3
"""Verify an AMO download against its recorded digest and the exact source tree.

The expected hash must come from the approved AMO download receipt. CMS verifies
signature integrity; Firefox remains the authority for Mozilla certificate trust
(OpenSSL's system CA store does not contain Mozilla's add-on signing roots).
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import tempfile
import zipfile

GECKO_ID = 'intent-firefox@loganmondi.dev'


def sections(raw):
    text = raw.decode('utf-8').replace('\r\n', '\n')
    text = re.sub(r'\n ', '', text)
    result = []
    for section in text.strip().split('\n\n'):
        fields = {}
        for line in section.split('\n'):
            key, separator, value = line.partition(': ')
            if not separator or key in fields:
                raise ValueError('Malformed or duplicate JAR signature field.')
            fields[key] = value
        result.append(fields)
    return result


def digest_matches(raw, encoded):
    return base64.b64encode(hashlib.sha256(raw).digest()).decode() == encoded


def verify(path, source, expected_sha256, run=subprocess.run):
    path, source = Path(path), Path(source)
    if not re.fullmatch('[a-f0-9]{64}', expected_sha256 or ''):
        raise ValueError('Supply the SHA256 recorded for the approved Mozilla download.')
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected_sha256:
        raise ValueError('Signed Firefox archive does not match the approved download hash.')
    expected = {p.relative_to(source).as_posix(): p.read_bytes()
                for p in source.rglob('*') if p.is_file()
                and p.relative_to(source).as_posix() != '.amo-upload-uuid'}
    if any(p.is_symlink() for p in source.rglob('*')):
        raise ValueError('Firefox source cannot contain symbolic links.')
    manifest = json.loads(expected['manifest.json'])
    if manifest.get('browser_specific_settings', {}).get('gecko', {}).get('id') != GECKO_ID:
        raise ValueError('Firefox source has a different extension ID.')
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)) or archive.testzip() is not None:
            raise ValueError('Firefox archive has duplicate or corrupt members.')
        for item in archive.infolist():
            member = PurePosixPath(item.filename)
            if (member.is_absolute() or '..' in member.parts or '\\' in item.filename
                    or stat.S_ISLNK(item.external_attr >> 16)):
                raise ValueError('Firefox archive contains an unsafe member.')
        payload = {n: archive.read(n) for n in names
                   if not n.endswith('/') and not n.startswith('META-INF/')}
        if set(payload) != set(expected):
            raise ValueError('Signed Firefox archive contains different source files.')
        for name, value in payload.items():
            if name == 'manifest.json':
                # Mozilla may reformat JSON during signing; semantic equality
                # includes extension ID, version, permissions and update URL.
                if json.loads(value) != manifest:
                    raise ValueError('Signed Firefox manifest differs from current source.')
            elif value != expected[name]:
                raise ValueError('Signed Firefox content differs from source: ' + name)
        required = ('META-INF/mozilla.rsa', 'META-INF/mozilla.sf', 'META-INF/manifest.mf')
        if any(name not in names or not archive.read(name) for name in required):
            raise ValueError('Firefox archive is missing its Mozilla signature.')
        jar_manifest = archive.read('META-INF/manifest.mf')
        if not digest_matches(jar_manifest, sections(archive.read('META-INF/mozilla.sf'))[0].get('SHA256-Digest-Manifest')):
            raise ValueError('Firefox signature manifest digest does not match.')
        signed_members = {}
        for section in sections(jar_manifest)[1:]:
            name = section.get('Name')
            if name in signed_members or name not in names or not digest_matches(archive.read(name), section.get('SHA256-Digest')):
                raise ValueError('Firefox signed member digest does not match.')
            signed_members[name] = True
        if not set(payload).issubset(signed_members):
            raise ValueError('Firefox signature does not cover every source file.')
        with tempfile.TemporaryDirectory(prefix='intent-xpi-verify-') as temporary:
            folder = Path(temporary)
            for name in ('mozilla.rsa', 'mozilla.sf'):
                (folder / name).write_bytes(archive.read('META-INF/' + name))
            result = run(['/usr/bin/openssl', 'cms', '-verify', '-binary', '-inform', 'DER',
                          '-in', str(folder / 'mozilla.rsa'), '-content', str(folder / 'mozilla.sf'),
                          '-noverify', '-out', str(folder / 'verified.sf')],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
            if result.returncode != 0:
                raise ValueError('Firefox CMS signature verification failed.')
    return manifest['version']


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('archive')
    parser.add_argument('source')
    parser.add_argument('sha256')
    args = parser.parse_args()
    try:
        print(verify(args.archive, args.source, args.sha256))
    except (ValueError, KeyError, OSError, zipfile.BadZipFile, subprocess.SubprocessError) as error:
        parser.exit(1, str(error) + '\n')
