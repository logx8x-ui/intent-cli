#!/usr/bin/env python3
import importlib.util, hashlib, json, pathlib, tempfile, unittest, zipfile
spec = importlib.util.spec_from_file_location('kits', pathlib.Path(__file__).with_name('build-download-kits.py'))
kits = importlib.util.module_from_spec(spec); spec.loader.exec_module(kits)
class DownloadKitsTests(unittest.TestCase):
    def test_selection_and_release_gates(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root/'Intent.dmg').write_bytes(b'fixture-dmg')
            (root/'Intent-Firefox-Extension.xpi').write_bytes(b'fixture-xpi')
            manifest = dict(notarized=True,team_id='TESTTEAM',firefox_extension_signed=True,
                sha256=hashlib.sha256(b'fixture-dmg').hexdigest(),firefox_extension_sha256=hashlib.sha256(b'fixture-xpi').hexdigest())
            def save(): (root/'release-manifest.json').write_text(json.dumps(manifest))
            save()
            self.assertEqual([p.name for p in kits.build_kits(root)],['Intent-Firefox.zip'])
            paths=kits.build_kits(root,'https://chromewebstore.google.com/detail/'+'a'*32)
            self.assertEqual(len(paths),3)
            for path in paths:
                with zipfile.ZipFile(path) as package:
                    self.assertIn('Intent.dmg',package.namelist())
                    self.assertEqual('Intent-Firefox-Extension.xpi' in package.namelist(),path.name!='Intent-Chrome.zip')
                    self.assertEqual('chromewebstore.google.com' in package.read('Finish setup.html').decode(),path.name!='Intent-Firefox.zip')
            manifest['notarized']=False;save()
            with self.assertRaises(ValueError):kits.build_kits(root)
            manifest['notarized']=True;manifest['sha256']='wrong';save()
            with self.assertRaises(ValueError):kits.build_kits(root)
if __name__=='__main__': unittest.main()
