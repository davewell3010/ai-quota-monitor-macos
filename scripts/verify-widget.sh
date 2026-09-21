#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/widget/AI额度.app"
EXT="$APP/Contents/PlugIns/AIQuotaWidget.appex"
codesign --verify --deep --strict "$APP"
xcrun nm -u "$EXT/Contents/MacOS/AIQuotaWidget" | rg -q '_NSExtensionMain$'
python3 - <<'PY'
import plistlib,pathlib,subprocess,re
base=pathlib.Path('build/widget/AI额度.app/Contents')
a=plistlib.loads((base/'Info.plist').read_bytes())
w=plistlib.loads((base/'PlugIns/AIQuotaWidget.appex/Contents/Info.plist').read_bytes())
assert w['NSExtension']=={'NSExtensionPointIdentifier':'com.apple.widgetkit-extension'}
assert a['CFBundleVersion']==w['CFBundleVersion']
assert a['AIQuotaAppGroup']==w['AIQuotaAppGroup']
teams=[]
for bundle in [base.parent,base/'PlugIns/AIQuotaWidget.appex']:
 details=subprocess.run(['codesign','-dvv',str(bundle)],capture_output=True,text=True,check=True).stderr
 team=re.search(r'^TeamIdentifier=([A-Z0-9]{10})$',details,re.M)
 assert team, 'A real Apple team signature is required'
 teams.append(team.group(1))
 entitlements=subprocess.run(['codesign','-d','--entitlements',':-',str(bundle)],capture_output=True,check=True).stdout
 ent=plistlib.loads(entitlements)
 assert ent['com.apple.security.application-groups']==[a['AIQuotaAppGroup']]
 assert 'com.apple.developer.team-identifier' not in ent, 'Unneeded restricted entitlement requires a profile' 
assert teams[0]==teams[1]
assert a['AIQuotaAppGroup'].startswith(teams[0]+'.')
print('Widget extension entry point, metadata, group configuration and signature checks passed')
PY
