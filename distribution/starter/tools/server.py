#!/usr/bin/env python3
"""Install the isolated macOS relay. No existing web server or desktop edits."""
import argparse,json,os,pathlib,plistlib,shutil,subprocess,urllib.parse
p=argparse.ArgumentParser();p.add_argument('--origin',required=True);p.add_argument('--install',action='store_true');p.add_argument('--port',type=int,default=28791);a=p.parse_args()
u=urllib.parse.urlsplit(a.origin)
if u.scheme!='https' or not u.hostname or u.username or u.password or u.query or u.fragment or u.path not in ('','/'):
 raise SystemExit('Use an HTTPS origin without path or credentials.')
if not 1024<=a.port<=65535:raise SystemExit('Invalid port')
root=pathlib.Path(__file__).resolve().parents[1];relay=root/'relay-server';state=pathlib.Path.home()/'Library/Application Support/ZCodeRemoteRelay';node=shutil.which('node');npm=shutil.which('npm')
if not node or not npm:raise SystemExit('Install Node.js 22+ and npm first.')
major=int(subprocess.check_output([node,'-p','process.versions.node.split(".")[0]'],text=True))
if major<22:raise SystemExit('Node.js 22+ required')
if not a.install:
 print(json.dumps({'ready':True,'origin':a.origin,'port':a.port,'stateDirectory':str(state),'installRequested':False}));raise SystemExit
subprocess.run([npm,'ci','--omit=optional'],cwd=relay,check=True)
state.mkdir(parents=True,exist_ok=True);state.chmod(0o700)
label='dev.zcode.remote-relay';plist=pathlib.Path.home()/'Library/LaunchAgents'/f'{label}.plist'
if plist.exists():raise SystemExit('Existing service found. Review its configuration before replacing it.')
plist.parent.mkdir(parents=True,exist_ok=True)
value={'Label':label,'ProgramArguments':[node,str(relay/'src/cli.mjs'),'start','--state-dir',str(state),'--origin',a.origin.rstrip('/'),'--port',str(a.port)],'RunAtLoad':True,'KeepAlive':True,'Umask':63,'StandardOutPath':str(state/'relay.log'),'StandardErrorPath':str(state/'relay-error.log')}
plist.write_bytes(plistlib.dumps(value));plist.chmod(0o600)
subprocess.run(['launchctl','bootstrap',f'gui/{os.getuid()}',str(plist)],check=True)
print('Relay installed. Configure HTTPS reverse proxy as described in START_HERE.md; login is required after server restart.')
