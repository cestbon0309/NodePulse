#!/bin/bash
set -euo pipefail

tag=${1:-}
case "$tag" in ''|.|..|*[!A-Za-z0-9._-]*) echo 'Usage: build-unsigned-ipa.sh TAG' >&2; exit 1 ;; esac
root=$(cd "$(dirname "$0")/../.." && pwd)
build=$root/ios/build
mkdir -p "$build"

DEVELOPER_DIR=$(python3 - "$root/ios/project.yml" <<'PY'
import glob
import json
import os
import plistlib
import subprocess
import sys

spec = json.loads(subprocess.check_output(['xcodegen', 'dump', '--spec', sys.argv[1], '--type', 'json']))
target = spec['options']['deploymentTarget']['iOS']
def version(value):
    parts = tuple(map(int, value.split('.')))
    return parts + (0,) * (3 - len(parts))

candidates = [os.environ.get('DEVELOPER_DIR', ''),
              subprocess.check_output(['xcode-select', '-p'], text=True).strip()]
candidates += sorted(glob.glob('/Applications/Xcode*.app/Contents/Developer'), reverse=True)
for candidate in dict.fromkeys(filter(None, candidates)):
    try:
        sdk = subprocess.check_output(['xcodebuild', '-version', '-sdk', 'iphoneos', 'Path'],
                                      env=dict(os.environ, DEVELOPER_DIR=candidate),
                                      stderr=subprocess.DEVNULL, text=True, timeout=30).strip()
        with open(os.path.join(sdk, 'SDKSettings.plist'), 'rb') as source:
            support = plistlib.load(source)['SupportedTargets']['iphoneos']
        if 'arm64' in support['Archs'] and version(support['MinimumDeploymentTarget']) <= version(target) <= version(support['MaximumDeploymentTarget']):
            print(f'Using {candidate} for iOS {target} (SDK {sdk})', file=sys.stderr)
            print(candidate)
            break
    except (OSError, KeyError, ValueError, subprocess.SubprocessError):
        continue
else:
    sys.exit(f'No installed Xcode supports arm64 iOS {target}')
PY
)
export DEVELOPER_DIR
xcodegen --spec "$root/ios/project.yml"
xcodebuild -project "$root/ios/NodePulse.xcodeproj" -scheme NodePulse \
    -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$build/Unsigned-$tag" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build

app=$build/Unsigned-$tag/Build/Products/Release-iphoneos/NodePulse.app
test "$(lipo -archs "$app/NodePulse")" = arm64
if codesign -dv "$app" 2>/dev/null; then echo 'Expected an unsigned app' >&2; exit 1; fi
stage=$(mktemp -d "$build/ipa-$tag.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/Payload"
ditto "$app" "$stage/Payload/NodePulse.app"
ipa=$build/NodePulse-$tag.ipa
ditto -c -k --keepParent "$stage/Payload" "$ipa"
python3 - "$ipa" <<'PY'
import os
import plistlib
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    assert archive.testzip() is None
    names = archive.namelist()
    assert 'Payload/NodePulse.app/NodePulse' in names
    info = plistlib.loads(archive.read('Payload/NodePulse.app/Info.plist'))
    assert any('nodepulse' in item.get('CFBundleURLSchemes', []) for item in info['CFBundleURLTypes'])
    assert not any('_CodeSignature/' in name or name.endswith('embedded.mobileprovision') for name in names)
print(f'PASS unsigned arm64 IPA: {sys.argv[1]} ({os.path.getsize(sys.argv[1])} bytes); binary, Info.plist and nodepulse URL scheme verified')
PY
