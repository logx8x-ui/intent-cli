#!/usr/bin/env python3
"""Run only after the corresponding signed GitHub release has been published."""
import hashlib, json, pathlib, re, sys, urllib.request
manifest_path, tag = sys.argv[1:]
if not re.fullmatch(r'v\d+\.\d+\.\d+', tag): sys.exit('Invalid release tag.')
manifest = json.loads(pathlib.Path(manifest_path).read_text())
if manifest.get('notarized') is not True or manifest.get('firefox_extension_signed') is not True or tag != 'v'+manifest['version']:
    sys.exit('Feed updates require the matching verified release.')
link = f'https://github.com/logx8x-ui/intent-cli/releases/download/{tag}/Intent-Firefox-Extension.xpi'
with urllib.request.urlopen(link, timeout=60) as response: digest=hashlib.sha256(response.read()).hexdigest()
if digest != manifest['firefox_extension_sha256']: sys.exit('Published Firefox asset does not match the verified build.')
feed={'addons':{'intent-firefox@loganmondi.dev':{'updates':[{'version':manifest['firefox_extension_version'],'update_link':link,'update_hash':'sha256:'+digest}]}}}
pathlib.Path('firefox-updates.json').write_text(json.dumps(feed,indent=2)+'\n')
