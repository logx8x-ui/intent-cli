#!/usr/bin/env python3
"""Bundle one verified launch release with the selected browser setup route."""
import hashlib
import html
import json
import os
import pathlib
import plistlib
import re
import subprocess
import sys
import zipfile


CHROME_STORE_ID = 'ffgfjfpkddgimambgmahlodjjojmjnbc'
KIT_CHOICES = ('Firefox', 'Chrome', 'Both')


def file_sha256(path):
    digest = hashlib.sha256()
    with pathlib.Path(path).open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def checked_archive(path, expected_version, firefox=False):
    try:
        with zipfile.ZipFile(path) as archive:
            # Duplicate ZIP entries can hide a second manifest from a consumer.
            if archive.namelist().count('manifest.json') != 1:
                raise ValueError(f'One browser manifest is required: {path.name}')
            metadata = json.loads(archive.read('manifest.json'))
            if not isinstance(metadata, dict) or metadata.get('version') != expected_version:
                raise ValueError(f'Browser Guard version mismatch: {path.name}')
            if archive.testzip() is not None:
                raise ValueError(f'Corrupt browser archive: {path.name}')
            if firefox and ('META-INF/mozilla.rsa' not in archive.namelist()
                            or not archive.read('META-INF/mozilla.rsa')):
                raise ValueError('Firefox Browser Guard is missing its Mozilla signature.')
    except (zipfile.BadZipFile, KeyError, json.JSONDecodeError, UnicodeDecodeError) as error:
        raise ValueError(f'Invalid browser archive: {path.name}') from error


def verify_release_inputs(directory, manifest_path=None, dmg_path=None):
    """Check metadata and artifact consistency before creating any kit.

    Actual Apple signature/notarization assessment belongs to verify-release.sh;
    these checks prevent a stale or mixed artifact set from being packaged.
    """
    root = pathlib.Path(directory)
    manifest_file = pathlib.Path(manifest_path) if manifest_path else root / 'release-manifest.json'
    manifest = json.loads(manifest_file.read_text())
    if not isinstance(manifest, dict):
        raise ValueError('The release manifest must be a JSON object.')
    if manifest.get('channel') != 'launch' or manifest.get('website_adder_enabled') is not False:
        raise ValueError('Download kits require the launch channel with the T website adder disabled.')
    if (manifest.get('notarized') is not True
            or not re.fullmatch(r'[A-Z0-9]{10}', str(manifest.get('team_id', '')))):
        raise ValueError('Download kits require a notarized Developer ID release and its Apple Team ID.')
    if manifest.get('firefox_extension_signed') is not True:
        raise ValueError('Firefox must be signed by Mozilla.')
    firefox_version = manifest.get('firefox_extension_version')
    chrome_version = manifest.get('chrome_extension_version')
    if (not isinstance(firefox_version, str)
            or not re.fullmatch(r'\d+(?:\.\d+){1,3}', firefox_version)
            or chrome_version != firefox_version
            or manifest.get('extension_version') != chrome_version):
        raise ValueError('The release must specify exact matching Firefox and Chrome Browser Guard versions.')
    assets = [
        ('firefox_extension_asset', 'Intent-Firefox-Extension.xpi', 'firefox_extension_sha256'),
        ('chrome_extension_asset', 'Intent-Chrome-Extension.zip', 'chrome_extension_sha256'),
    ]
    for field, name, digest_field in assets:
        if manifest.get(field) != name:
            raise ValueError(f'Unexpected release asset: {field}')
        if file_sha256(root / name) != manifest.get(digest_field):
            raise ValueError(f'Checksum mismatch: {name}')
    dmg = pathlib.Path(dmg_path) if dmg_path else root / 'Intent.dmg'
    if file_sha256(dmg) != manifest.get('sha256'):
        raise ValueError('Checksum mismatch: Intent.dmg')
    checked_archive(root / 'Intent-Firefox-Extension.xpi', firefox_version, firefox=True)
    checked_archive(root / 'Intent-Chrome-Extension.zip', chrome_version)
    if manifest.get('chrome_web_store_approved') is True:
        approved_chrome_store_url(manifest.get('chrome_store_url'),
                                  manifest.get('chrome_web_store_version'), manifest)
    return manifest


def approved_chrome_store_url(url, approved_version, manifest):
    if not url and not approved_version:
        return None
    match = re.fullmatch(r'https://chromewebstore\.google\.com/detail/(?:[a-z0-9-]+/)?([a-p]{32})', url or '')
    if not match or match.group(1) != CHROME_STORE_ID:
        raise ValueError('Use Intent Browser Guard’s published Chrome Web Store listing URL.')
    if not approved_version or approved_version != manifest['chrome_extension_version']:
        raise ValueError('Chrome download kits require the approved Web Store version to match this release exactly.')
    if (manifest.get('chrome_web_store_approved') is not True
            or manifest.get('chrome_web_store_version') != approved_version):
        raise ValueError('This release does not confirm the matching Chrome Web Store approval.')
    return url


def verify_compiled_launch(app, run=None):
    """Query only after the caller verifies the Apple signature and Mach-O.

    Reject old/unknown apps before execution: their unknown flag could otherwise
    launch normal UI, open user data and take over browser-host registration.
    """
    bundle = pathlib.Path(app)
    with (bundle / 'Contents/Info.plist').open('rb') as source:
        metadata = plistlib.load(source)
    if (metadata.get('CFBundleIdentifier') != 'dev.loganmondi.intent'
            or metadata.get('CFBundleExecutable') != 'IntentApp'
            or metadata.get('IntentBuildChannel') != 'launch'
            or metadata.get('IntentDevelopmentBuild') is not False):
        raise ValueError('The signed application metadata does not identify the launch channel.')
    executable = bundle / 'Contents/MacOS/IntentApp'
    marker = b'--print-build-channel'
    supported = False
    overlap = b''
    with executable.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            data = overlap + chunk
            if marker in data:
                supported = True
                break
            overlap = data[-len(marker):]
    if not supported:
        raise ValueError('This application cannot safely report its compiled channel.')
    try:
        result = (run or subprocess.run)([str(executable), '--print-build-channel'], text=True,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       timeout=5, check=True)
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError, OSError) as error:
        raise ValueError('The compiled-channel query failed safely; the release was rejected.') from error
    if result.stdout.strip() != 'launch':
        raise ValueError('The signed application contains a development executable.')
    return 'launch'


def verify_embedded_browsers(app, manifest):
    bundle = pathlib.Path(app)
    resources = bundle / 'Contents/Resources/BrowserGuard'
    for browser in ('Chrome', 'Firefox'):
        metadata = json.loads((resources / browser / 'manifest.json').read_text())
        if metadata.get('version') != manifest[f'{browser.lower()}_extension_version']:
            raise ValueError(f'The application embeds a different {browser} Browser Guard version.')
    signed_firefox = resources / 'Intent-Firefox-Extension.xpi'
    if file_sha256(signed_firefox) != manifest['firefox_extension_sha256']:
        raise ValueError('The application embeds a different signed Firefox Browser Guard package.')
    checked_archive(signed_firefox, manifest['firefox_extension_version'], firefox=True)
    with (bundle / 'Contents/Info.plist').open('rb') as source:
        metadata = plistlib.load(source)
    expected_chrome = manifest['chrome_extension_version'] if manifest.get('chrome_web_store_approved') is True else ''
    if metadata.get('IntentChromePublishedGuardVersion', '') != expected_chrome:
        raise ValueError('The application’s Chrome setup approval does not match this release.')
    if (metadata.get('SUEnableAutomaticChecks') is True) != (manifest.get('automatic_update_checks_enabled') is True):
        raise ValueError('The application’s automatic update checks do not match the setup guide.')


def setup_page(choice, manifest, chrome_store_url):
    profile_choice = {'Firefox': 'Firefox', 'Chrome': 'Chrome', 'Both': 'Firefox and Chrome'}[choice]
    steps = [
        '<li><strong>Install Intent.</strong> Open <b>Intent.dmg</b>, then run <b>Install Intent.pkg</b>. Approve the macOS installation prompts.</li>',
        '<li><strong>Choose your browser profiles.</strong> Open Intent’s browser setup, choose <b>' + profile_choice + '</b>, then select the profiles you use. Choose <b>Select all</b> to include every detected profile. A Google account belongs to a Chrome profile; extensions are installed per profile, not per email account.</li>',
    ]
    if choice in ('Firefox', 'Both'):
        steps.append('<li><strong>Connect Firefox.</strong> In each selected Firefox profile, <a href="Intent-Firefox-Extension.xpi">add Intent Browser Guard</a>. Firefox will ask you to confirm installation and its permissions; approve those prompts.</li>')
    if choice in ('Chrome', 'Both'):
        steps.append('<li><strong>Connect Chrome.</strong> In each selected Chrome profile, <a href="' + html.escape(chrome_store_url, quote=True) + '">open Intent Browser Guard in the Chrome Web Store</a>, choose <b>Add to Chrome</b> and confirm its permissions.</li>')
    steps.append('<li><strong>Make your first intention.</strong> Return to Intent after its browser connection checks succeed, grant the requested macOS permissions and choose what you want to use.</li>')
    update_note = ('Intent checks for app updates automatically and lets you choose when to install.'
                   if manifest.get('automatic_update_checks_enabled') is True
                   else 'Automatic app update checks are off for this release. Use a new download when your tester invitation includes an update.')
    return '''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Finish Intent setup</title><style>
:root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;min-height:100vh;background:#08090b;color:#eceef2;font:16px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
main{max-width:680px;margin:0 auto;padding:64px 28px 48px}.wordmark{font:bold 34px Georgia,serif;letter-spacing:-1.5px;position:relative;display:inline-block}.star{position:absolute;font:18px Georgia,serif;color:#cfd3dd;top:-16px;right:-18px}
.eyebrow{color:#a7abb5;letter-spacing:.14em;text-transform:uppercase;font-size:11px;margin-top:48px}h1{font-size:36px;line-height:1.2;letter-spacing:-1.3px;margin:12px 0 20px}p{color:#b6bac4}ol{padding-left:23px;margin:32px 0}li{padding-left:8px;margin:0 0 25px}strong{display:block;color:#f3f4f7}a{color:#e3e6ee;text-decoration-color:#737986;text-underline-offset:4px}a:hover{color:#fff}a:focus-visible{outline:2px solid #d1d6e2;outline-offset:5px;border-radius:2px}.note{border-top:1px solid #34373e;padding-top:22px;font-size:13px}
@media(max-width:420px){main{padding:40px 20px}h1{font-size:30px}.eyebrow{margin-top:36px}}
</style></head><body><main><div class="wordmark">intent<span class="star" aria-hidden="true">✦</span></div>
<p class="eyebrow">Your computer, with intention</p><h1>Finish setting up Intent.</h1><p>A few quick steps before your first intention.</p>
<ol>''' + ''.join(steps) + '</ol><p class="note">' + update_note + ' Browser installation confirmations must be completed in each selected profile.</p></main></body></html>'


def build_kits(directory, chrome_store_url=None, chrome_store_version=None):
    root = pathlib.Path(directory)
    manifest = verify_release_inputs(root)
    chrome_store_url = approved_chrome_store_url(chrome_store_url, chrome_store_version, manifest)
    # Firefox ships independently while Chrome waits for its matching store approval.
    choices = KIT_CHOICES if chrome_store_url else ('Firefox',)
    for stale_choice in set(KIT_CHOICES).difference(choices):
        (root / f'Intent-{stale_choice}.zip').unlink(missing_ok=True)
    results = []
    for choice in choices:
        target = root / f'Intent-{choice}.zip'
        temporary = root / f'.Intent-{choice}.zip.tmp'
        try:
            with zipfile.ZipFile(temporary, 'w', zipfile.ZIP_DEFLATED) as kit:
                kit.write(root / 'Intent.dmg', 'Intent.dmg')
                kit.write(root / 'release-manifest.json', 'release-manifest.json')
                if choice in ('Firefox', 'Both'):
                    kit.write(root / 'Intent-Firefox-Extension.xpi', 'Intent-Firefox-Extension.xpi')
                kit.writestr('Finish setup.html', setup_page(choice, manifest, chrome_store_url))
            temporary.replace(target)
        finally:
            temporary.unlink(missing_ok=True)
        results.append(target)
    return results


if __name__ == '__main__':
    try:
        for path in build_kits(sys.argv[1] if len(sys.argv) > 1 else 'dist/release',
                               os.environ.get('INTENT_CHROME_WEB_STORE_URL'),
                               os.environ.get('INTENT_CHROME_WEB_STORE_VERSION')):
            print(path)
    except (ValueError, OSError, KeyError) as error:
        sys.exit(str(error))
