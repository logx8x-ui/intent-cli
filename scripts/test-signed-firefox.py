#!/usr/bin/env python3
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('signed_firefox', Path(__file__).with_name('verify-signed-firefox.py'))
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class SignedFirefox(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.keys = tempfile.TemporaryDirectory(prefix='intent-signature-fixture-')
        cls.key_root = Path(cls.keys.name)
        subprocess.run(['/usr/bin/openssl', 'req', '-new', '-newkey', 'rsa:2048', '-nodes',
                        '-x509', '-days', '1', '-subj', '/CN=Intent disposable signature fixture',
                        '-keyout', str(cls.key_root / 'key.pem'), '-out', str(cls.key_root / 'cert.pem')],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    @classmethod
    def tearDownClass(cls): cls.keys.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='intent-xpi-fixture-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'
        self.source.mkdir()
        self.manifest = {'version': '1.2.3', 'browser_specific_settings': {'gecko': {'id': verifier.GECKO_ID}}}
        (self.source / 'manifest.json').write_text(json.dumps(self.manifest))
        (self.source / 'background.js').write_text('// fixture source')
        (self.source / '.amo-upload-uuid').write_text('local signing metadata, not extension content')
        self.payload = {'manifest.json': json.dumps(self.manifest, indent=2).encode(),
                        'background.js': b'// fixture source'}
        self.archive = self.root / 'signed.xpi'

    @staticmethod
    def digest(data): return base64.b64encode(hashlib.sha256(data).digest()).decode()

    def signed_archive(self, *, corrupt_signature=False, omit_coverage=False):
        signed = {name: value for name, value in self.payload.items()
                  if not omit_coverage or name != 'background.js'}
        jar = ('Manifest-Version: 1.0\n\n' + ''.join('Name: '+name+'\nSHA256-Digest: '+self.digest(value)+'\n\n'
                                                  for name, value in signed.items())).encode()
        sf = ('Signature-Version: 1.0\nSHA256-Digest-Manifest: '+self.digest(jar)+'\n\n').encode()
        (self.root / 'mozilla.sf').write_bytes(sf)
        subprocess.run(['/usr/bin/openssl', 'cms', '-sign', '-binary', '-md', 'sha256',
                        '-in', str(self.root / 'mozilla.sf'), '-outform', 'DER',
                        '-signer', str(self.key_root / 'cert.pem'), '-inkey', str(self.key_root / 'key.pem'),
                        '-out', str(self.root / 'mozilla.rsa')], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        signature = (self.root / 'mozilla.rsa').read_bytes()
        if corrupt_signature:
            signature = signature[:-1] + bytes([signature[-1] ^ 1])
        with zipfile.ZipFile(self.archive, 'w') as archive:
            for name, value in self.payload.items(): archive.writestr(name, value)
            archive.writestr('META-INF/manifest.mf', jar)
            archive.writestr('META-INF/mozilla.sf', sf)
            archive.writestr('META-INF/mozilla.rsa', signature)
        self.sha = hashlib.sha256(self.archive.read_bytes()).hexdigest()

    def verify(self): return verifier.verify(self.archive, self.source, self.sha)

    def test_formatted_manifest_and_exact_signed_content_pass(self):
        self.signed_archive()
        self.assertEqual(self.verify(), '1.2.3')

    def test_hash_is_mandatory_and_exact(self):
        self.signed_archive()
        for value in ['', 'not-a-hash', '0' * 64]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                verifier.verify(self.archive, self.source, value)

    def test_changed_source_requires_new_signed_archive(self):
        self.signed_archive()
        (self.source / 'background.js').write_text('// changed source')
        with self.assertRaisesRegex(ValueError, 'differs from source'): self.verify()

    def test_manifest_permissions_and_version_must_match(self):
        for field, value in [('version', '1.2.4'), ('permissions', ['tabs'])]:
            with self.subTest(field=field):
                self.payload['manifest.json'] = json.dumps(dict(self.manifest, **{field: value})).encode()
                self.signed_archive()
                with self.assertRaisesRegex(ValueError, 'manifest differs'): self.verify()

    def test_foreign_source_id_is_rejected(self):
        self.manifest['browser_specific_settings']['gecko']['id'] = 'foreign@example.test'
        (self.source / 'manifest.json').write_text(json.dumps(self.manifest))
        self.payload['manifest.json'] = json.dumps(self.manifest).encode()
        self.signed_archive()
        with self.assertRaisesRegex(ValueError, 'different extension ID'): self.verify()

    def test_corrupt_signature_is_rejected_even_with_matching_hash(self):
        self.signed_archive(corrupt_signature=True)
        with self.assertRaisesRegex(ValueError, 'CMS signature'): self.verify()

    def test_unsigned_member_is_rejected(self):
        self.signed_archive(omit_coverage=True)
        with self.assertRaisesRegex(ValueError, 'every source file'): self.verify()

    def test_extra_payload_is_rejected(self):
        self.payload['surprise.js'] = b'// different source set'
        self.signed_archive()
        with self.assertRaisesRegex(ValueError, 'different source files'): self.verify()

    def test_duplicate_member_is_rejected(self):
        self.signed_archive()
        import warnings
        with warnings.catch_warnings(), zipfile.ZipFile(self.archive, 'a') as archive:
            warnings.simplefilter('ignore')
            archive.writestr('manifest.json', self.payload['manifest.json'])
        self.sha = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        with self.assertRaisesRegex(ValueError, 'duplicate'): self.verify()


if __name__ == '__main__': unittest.main()
