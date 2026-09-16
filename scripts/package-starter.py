#!/usr/bin/env python3
"""Export only redistributable source/tools; never runtime data or credentials."""
from pathlib import Path
import hashlib,json,zipfile
r=Path(__file__).resolve().parents[1];out=r/'distribution/ZCode-Remote-Starter.zip'
files={}
for p in (r/'distribution/starter').rglob('*'):
 if p.is_file() and '__pycache__' not in p.parts and 'overrides' not in p.parts:files[str(p.relative_to(r/'distribution/starter'))]=p
for name in ['package.json','package-lock.json']:
 files['relay-server/'+name]=r/'relay-server'/name
for folder in ['relay-server/src','relay-server/web','relay-server/tests','relay-server/scripts','ios/ZCodeMobile','ios/ZCodeMobile.xcodeproj']:
 for p in (r/folder).rglob('*'):
  if p.is_file() and not any(x in p.parts for x in ['xcuserdata','DerivedData','.git']):files[str(p.relative_to(r))]=p
files['ios/ZCodeMobile/Core/ReferenceData.swift']=r/'distribution/starter/overrides/ReferenceData.swift'
manifest={n:hashlib.sha256(p.read_bytes()).hexdigest() for n,p in sorted(files.items())}
out.parent.mkdir(exist_ok=True)
with zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
 for n,p in sorted(files.items()):z.write(p,'ZCode-Remote-Starter/'+n)
 z.writestr('ZCode-Remote-Starter/MANIFEST.json',json.dumps(manifest,indent=2)+'\n')
with zipfile.ZipFile(out) as z:
 assert z.testzip() is None
 for n,h in manifest.items():assert hashlib.sha256(z.read('ZCode-Remote-Starter/'+n)).hexdigest()==h
print(json.dumps({'path':str(out),'files':len(files),'bytes':out.stat().st_size,'sha256':hashlib.sha256(out.read_bytes()).hexdigest(),'verified':True}))
