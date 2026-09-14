#!/usr/bin/env python3
"""Exercise the actual installer against temporary homes, never the user's installation."""
import os,pathlib,subprocess,sys,tempfile,shutil
kit=pathlib.Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='intent-install-spec-') as tmp:
 root=pathlib.Path(tmp); state=root/'.intent'; state.mkdir()
 saved=state/'intentions.json'; saved.write_text('existing guest intentions')
 marker=state/'reset-on-next-launch'
 env=dict(os.environ,INTENT_INSTALL_TEST_ROOT=str(root))
 def install(): subprocess.run(['bash',str(kit/'Install Intent.command')],env=env,check=True,capture_output=True)
 install()
 assert marker.exists(), 'Fresh install over leftover data must schedule a reset'
 marker.unlink()
 install()
 assert not marker.exists() and saved.read_text()=='existing guest intentions', 'Update must preserve data'
 shutil.rmtree(root/'Applications/Intent.app')
 install()
 assert marker.exists(), 'Reinstall after removal must reset again'
 marker.unlink()
 system=root/'SystemApplications';system.mkdir()
 shutil.move(root/'Applications/Intent.app',system/'Intent.app')
 install()
 assert not marker.exists() and (system/'Intent.app').exists(), 'An existing system installation is an update, not a fresh install'
 assert not (root/'Applications/Intent.app').exists(), 'System updates must not create a second app'
 print('Beta installer fresh, update, reinstall and system migration specs passed')
