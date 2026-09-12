#!/usr/bin/env python3
"""Bundle the verified release and the selected browsers into one download."""
import hashlib, html, json, os, pathlib, re, sys, zipfile


def build_kits(directory, chrome_store_url=None):
    root = pathlib.Path(directory)
    manifest = json.loads((root / 'release-manifest.json').read_text())
    if manifest.get('notarized') is not True or not manifest.get('team_id'):
        raise ValueError('Download kits require a notarized Developer ID release.')
    required = [('Intent.dmg', 'sha256'), ('Intent-Firefox-Extension.xpi', 'firefox_extension_sha256')]
    if manifest.get('firefox_extension_signed') is not True:
        raise ValueError('Firefox must be signed by Mozilla.')
    for name, digest in required:
        if hashlib.sha256((root / name).read_bytes()).hexdigest() != manifest.get(digest):
            raise ValueError(f'Checksum mismatch: {name}')
    if chrome_store_url and not re.fullmatch(r'https://chromewebstore\.google\.com/detail/(?:[a-z0-9-]+/)?[a-p]{32}', chrome_store_url):
        raise ValueError('Use the published Chrome Web Store listing URL.')
    # Firefox can ship independently while Chrome waits for store approval.
    choices = ['Firefox', 'Chrome', 'Both'] if chrome_store_url else ['Firefox']
    results = []
    for choice in choices:
        steps = '<li>Open <b>Intent.dmg</b> and run <b>Install Intent.pkg</b>. Approve the macOS prompts.</li>'
        if choice in ('Firefox', 'Both'):
            steps += '<li>Open this page in Firefox, then <a href="Intent-Firefox-Extension.xpi">add Intent Browser Guard to Firefox</a>. Approve Firefox’s installation prompt.</li>'
        if choice in ('Chrome', 'Both'):
            steps += '<li>In Chrome, <a href="' + html.escape(chrome_store_url, quote=True) + '">add Intent Browser Guard from the Chrome Web Store</a>.</li>'
        page = '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Finish Intent setup</title><style>body{font:18px/1.6 system-ui;max-width:640px;margin:60px auto;padding:24px;background:#101713;color:#edf6ef}a{color:#b8f7ce}li{margin:20px 0}</style><h1>Finish Intent setup</h1><ol>' + steps + '<li>Return to Intent and make your first intention.</li></ol><p>Intent checks for app updates automatically and lets you choose when to install. Your browsers update their extensions.</p></html>'
        target = root / f'Intent-{choice}.zip'
        with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as kit:
            kit.write(root / 'Intent.dmg', 'Intent.dmg')
            kit.write(root / 'release-manifest.json', 'release-manifest.json')
            if choice in ('Firefox', 'Both'):
                kit.write(root / 'Intent-Firefox-Extension.xpi', 'Intent-Firefox-Extension.xpi')
            kit.writestr('Finish setup.html', page)
        results.append(target)
    return results


if __name__ == '__main__':
    try:
        for path in build_kits(sys.argv[1] if len(sys.argv) > 1 else 'dist/release', os.environ.get('INTENT_CHROME_WEB_STORE_URL')):
            print(path)
    except (ValueError, OSError, KeyError) as error:
        sys.exit(str(error))
