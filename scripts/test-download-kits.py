#!/usr/bin/env python3
import importlib.util
import json
import pathlib
import plistlib
import subprocess
import tempfile
import unittest
import zipfile
from unittest.mock import Mock

spec = importlib.util.spec_from_file_location('kits', pathlib.Path(__file__).with_name('build-download-kits.py'))
kits = importlib.util.module_from_spec(spec)
spec.loader.exec_module(kits)
STORE_URL = 'https://chromewebstore.google.com/detail/intent-browser-guard/' + kits.CHROME_STORE_ID
VERSION = '0.2.43'


class DownloadKitsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        (self.root / 'Intent.dmg').write_bytes(b'fixture-dmg')
        self.archive('Intent-Firefox-Extension.xpi', VERSION, signed=True)
        self.archive('Intent-Chrome-Extension.zip', VERSION)
        self.manifest = dict(channel='launch', website_adder_enabled=False,
            notarized=True, team_id='TESTTEAM01', firefox_extension_signed=True,
            sha256=kits.file_sha256(self.root / 'Intent.dmg'),
            firefox_extension_asset='Intent-Firefox-Extension.xpi',
            firefox_extension_version=VERSION,
            firefox_extension_sha256=kits.file_sha256(self.root / 'Intent-Firefox-Extension.xpi'),
            chrome_extension_asset='Intent-Chrome-Extension.zip',
            chrome_extension_version=VERSION,
            chrome_extension_sha256=kits.file_sha256(self.root / 'Intent-Chrome-Extension.zip'),
            extension_version=VERSION, chrome_web_store_approved=True,
            chrome_web_store_version=VERSION, chrome_store_url=STORE_URL,
            automatic_update_checks_enabled=False)
        self.save()

    def archive(self, name, version, signed=False):
        with zipfile.ZipFile(self.root / name, 'w') as archive:
            archive.writestr('manifest.json', json.dumps(dict(version=version)))
            archive.writestr('background.js', '// test fixture')
            if signed:
                archive.writestr('META-INF/mozilla.rsa', b'fixture-signature-marker')

    def save(self):
        (self.root / 'release-manifest.json').write_text(json.dumps(self.manifest))

    def rejected(self):
        self.save()
        with self.assertRaises(ValueError):
            kits.build_kits(self.root)
        self.assertFalse(list(self.root.glob('Intent-Firefox.zip')))
        self.assertFalse(list(self.root.glob('Intent-Chrome.zip')))
        self.assertFalse(list(self.root.glob('Intent-Both.zip')))

    def test_firefox_can_ship_without_chrome_store_approval(self):
        paths = kits.build_kits(self.root)
        self.assertEqual([path.name for path in paths], ['Intent-Firefox.zip'])
        with zipfile.ZipFile(paths[0]) as package:
            self.assertIn('Intent-Firefox-Extension.xpi', package.namelist())
            self.assertNotIn('chromewebstore.google.com', package.read('Finish setup.html').decode())

    def test_all_selection_bundles_contain_exact_verified_release(self):
        paths = kits.build_kits(self.root, STORE_URL, VERSION)
        self.assertEqual([path.name for path in paths], ['Intent-Firefox.zip', 'Intent-Chrome.zip', 'Intent-Both.zip'])
        for path in paths:
            with self.subTest(choice=path.name), zipfile.ZipFile(path) as package:
                firefox = path.name != 'Intent-Chrome.zip'
                chrome = path.name != 'Intent-Firefox.zip'
                expected = {'Intent.dmg', 'release-manifest.json', 'Finish setup.html'}
                if firefox:
                    expected.add('Intent-Firefox-Extension.xpi')
                self.assertEqual(set(package.namelist()), expected)
                self.assertEqual(package.read('Intent.dmg'), (self.root / 'Intent.dmg').read_bytes())
                self.assertEqual(json.loads(package.read('release-manifest.json')), self.manifest)
                page = package.read('Finish setup.html').decode()
                self.assertEqual(STORE_URL in page, chrome)
                self.assertEqual('href="Intent-Firefox-Extension.xpi"' in page, firefox)
                self.assertIn('Select all', page)
                self.assertIn('installed per profile, not per email account', page)
                self.assertIn('confirm', page)
                self.assertNotIn('checks for app updates automatically', page)
                self.assertIn('background:#08090b', page)
                self.assertIn('✦', page)

    def test_chrome_listing_alone_is_not_approval(self):
        with self.assertRaisesRegex(ValueError, 'approved Web Store version'):
            kits.build_kits(self.root, STORE_URL)

    def test_chrome_approved_version_must_match(self):
        for version in ['0.2.42', '', '0.2.430']:
            with self.subTest(version=version), self.assertRaises(ValueError):
                kits.build_kits(self.root, STORE_URL, version)

    def test_chrome_env_cannot_override_unapproved_release(self):
        self.manifest['chrome_web_store_approved'] = False
        self.save()
        with self.assertRaisesRegex(ValueError, 'does not confirm'):
            kits.build_kits(self.root, STORE_URL, VERSION)
        self.assertEqual([path.name for path in kits.build_kits(self.root)], ['Intent-Firefox.zip'])

    def test_chrome_listing_identity_and_scheme_are_verified(self):
        for url in ['https://chromewebstore.google.com/detail/' + 'a' * 32,
                    'http://chromewebstore.google.com/detail/' + kits.CHROME_STORE_ID,
                    'https://evil.test/' + kits.CHROME_STORE_ID, 'javascript:alert(1)', None]:
            with self.subTest(url=url), self.assertRaises(ValueError):
                kits.build_kits(self.root, url, VERSION)

    def test_only_explicit_launch_channel_passes(self):
        for channel in ['development', 'test', '', None]:
            with self.subTest(channel=channel):
                self.manifest['channel'] = channel
                self.rejected()

    def test_t_requires_explicit_false_boolean(self):
        for enabled in [True, None, 'false', 0]:
            with self.subTest(enabled=enabled):
                self.manifest['website_adder_enabled'] = enabled
                self.rejected()

    def test_notary_requires_explicit_true_boolean(self):
        for value in [False, None, 'true', 1]:
            with self.subTest(notarized=value):
                self.manifest['notarized'] = value
                self.rejected()

    def test_apple_team_is_required(self):
        for team in ['', None, 'TESTTEAM', 'Developer ID Application: tester']:
            with self.subTest(team=team):
                self.manifest['team_id'] = team
                self.rejected()

    def test_all_artifact_hashes_are_checked_before_any_kit(self):
        for field in ['sha256', 'firefox_extension_sha256', 'chrome_extension_sha256']:
            with self.subTest(field=field):
                original = self.manifest[field]
                self.manifest[field] = '0' * 64
                self.rejected()
                self.manifest[field] = original

    def test_actual_changed_artifact_is_rejected(self):
        for name in ['Intent.dmg', 'Intent-Firefox-Extension.xpi', 'Intent-Chrome-Extension.zip']:
            with self.subTest(name=name):
                path = self.root / name
                original = path.read_bytes()
                path.write_bytes(original + b'changed')
                self.rejected()
                path.write_bytes(original)

    def test_manifest_browser_versions_must_match_each_other(self):
        self.manifest['chrome_extension_version'] = '0.2.42'
        self.rejected()

    def test_generic_guard_version_must_match_browser_versions(self):
        self.manifest['extension_version'] = '0.2.42'
        self.rejected()

    def test_archive_version_must_match_even_when_hash_is_updated(self):
        for name, digest in [('Intent-Firefox-Extension.xpi', 'firefox_extension_sha256'),
                             ('Intent-Chrome-Extension.zip', 'chrome_extension_sha256')]:
            with self.subTest(name=name):
                original = (self.root / name).read_bytes()
                original_digest = self.manifest[digest]
                self.archive(name, '0.2.42', signed=name.endswith('.xpi'))
                self.manifest[digest] = kits.file_sha256(self.root / name)
                self.rejected()
                (self.root / name).write_bytes(original)
                self.manifest[digest] = original_digest

    def test_declared_firefox_signing_cannot_replace_archive_marker(self):
        self.archive('Intent-Firefox-Extension.xpi', VERSION)
        self.manifest['firefox_extension_sha256'] = kits.file_sha256(self.root / 'Intent-Firefox-Extension.xpi')
        self.rejected()

    def test_firefox_signing_metadata_is_required(self):
        self.manifest['firefox_extension_signed'] = False
        self.rejected()

    def test_asset_names_cannot_escape_release_directory(self):
        self.manifest['firefox_extension_asset'] = '../Intent-Firefox-Extension.xpi'
        self.rejected()

    def test_firefox_only_removes_stale_chrome_choices(self):
        kits.build_kits(self.root, STORE_URL, VERSION)
        kits.build_kits(self.root)
        self.assertFalse((self.root / 'Intent-Chrome.zip').exists())
        self.assertFalse((self.root / 'Intent-Both.zip').exists())
        self.assertTrue((self.root / 'Intent-Firefox.zip').exists())

    def test_update_copy_follows_explicit_check_policy(self):
        for enabled in [None, False, True]:
            with self.subTest(enabled=enabled):
                self.manifest['automatic_update_checks_enabled'] = enabled
                self.save()
                package = kits.build_kits(self.root)[0]
                with zipfile.ZipFile(package) as archive:
                    page = archive.read('Finish setup.html').decode()
                    self.assertEqual('checks for app updates automatically' in page, enabled is True)

    def embedded_app(self):
        app = self.root / 'Intent.app'
        resources = app / 'Contents/Resources/BrowserGuard'
        for browser in ['Chrome', 'Firefox']:
            (resources / browser).mkdir(parents=True)
            (resources / browser / 'manifest.json').write_text(json.dumps(dict(version=VERSION)))
        (resources / 'Intent-Firefox-Extension.xpi').write_bytes((self.root / 'Intent-Firefox-Extension.xpi').read_bytes())
        with (app / 'Contents/Info.plist').open('wb') as target:
            plistlib.dump(dict(IntentChromePublishedGuardVersion=VERSION, SUEnableAutomaticChecks=False), target)
        return app

    def test_embedded_browser_versions_and_signed_package_match(self):
        app = self.embedded_app()
        kits.verify_embedded_browsers(app, self.manifest)
        for browser in ['Firefox', 'Chrome']:
            with self.subTest(browser=browser):
                path = app / 'Contents/Resources/BrowserGuard' / browser / 'manifest.json'
                path.write_text(json.dumps(dict(version='0.2.42')))
                with self.assertRaisesRegex(ValueError, 'different ' + browser):
                    kits.verify_embedded_browsers(app, self.manifest)
                path.write_text(json.dumps(dict(version=VERSION)))
        (app / 'Contents/Resources/BrowserGuard/Intent-Firefox-Extension.xpi').write_bytes(b'old package')
        with self.assertRaisesRegex(ValueError, 'different signed Firefox'):
            kits.verify_embedded_browsers(app, self.manifest)

    def test_embedded_browser_setup_approval_and_update_copy_match(self):
        app = self.embedded_app()
        for chrome_version, checks in [('0.2.42', False), (VERSION, True)]:
            with self.subTest(version=chrome_version, checks=checks):
                with (app / 'Contents/Info.plist').open('wb') as target:
                    plistlib.dump(dict(IntentChromePublishedGuardVersion=chrome_version,
                                       SUEnableAutomaticChecks=checks), target)
                with self.assertRaises(ValueError):
                    kits.verify_embedded_browsers(app, self.manifest)


class CompiledChannelVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.app = pathlib.Path(self.temporary.name) / 'Intent.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        self.metadata = dict(CFBundleIdentifier='dev.loganmondi.intent', CFBundleExecutable='IntentApp',
                             IntentBuildChannel='launch', IntentDevelopmentBuild=False)
        self.save()
        self.binary = self.app / 'Contents/MacOS/IntentApp'
        self.binary.write_bytes(b'fixture Mach-O marker --print-build-channel')
        self.run = Mock(return_value=subprocess.CompletedProcess([], 0, stdout='launch\n', stderr=''))

    def save(self):
        with (self.app / 'Contents/Info.plist').open('wb') as target:
            plistlib.dump(self.metadata, target)

    def test_channel_probe_has_bounded_known_arguments(self):
        self.assertEqual(kits.verify_compiled_launch(self.app, run=self.run), 'launch')
        arguments, options = self.run.call_args
        self.assertEqual(arguments[0], [str(self.binary), '--print-build-channel'])
        self.assertEqual(options['timeout'], 5)
        self.assertTrue(options['check'])

    def test_unknown_old_binary_is_never_executed(self):
        self.binary.write_bytes(b'old executable without supported query')
        with self.assertRaisesRegex(ValueError, 'safely report'):
            kits.verify_compiled_launch(self.app, run=self.run)
        self.run.assert_not_called()

    def test_wrong_metadata_is_never_executed(self):
        for field, value in [('IntentBuildChannel', 'development'), ('IntentDevelopmentBuild', True),
                             ('CFBundleIdentifier', 'other.app'), ('CFBundleExecutable', 'other')]:
            with self.subTest(field=field):
                original = self.metadata[field]
                self.metadata[field] = value
                self.save()
                with self.assertRaises(ValueError):
                    kits.verify_compiled_launch(self.app, run=self.run)
                self.run.assert_not_called()
                self.metadata[field] = original

    def test_development_executable_cannot_be_relabelled_launch(self):
        self.run.return_value.stdout = 'development\n'
        with self.assertRaisesRegex(ValueError, 'development executable'):
            kits.verify_compiled_launch(self.app, run=self.run)

    def test_timeout_rejects_candidate(self):
        self.run.side_effect = subprocess.TimeoutExpired('fixture', 5)
        with self.assertRaisesRegex(ValueError, 'failed safely'):
            kits.verify_compiled_launch(self.app, run=self.run)


if __name__ == '__main__':
    unittest.main()
