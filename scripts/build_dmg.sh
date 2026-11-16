#!/bin/bash
# Universal DMG, macOS 14+: Apple Silicon + Intel; only project artifacts are copied.
set -euo pipefail
cd "$(dirname "$0")/.."

RELEASE_VERSION="${1:?用法：bash scripts/build_dmg.sh 1.0.0}"
[[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "版本必须为 x.y.z" >&2; exit 1; }
DIST="build/dist"
STAGE="build/dmg-stage"
APP="build/ProxyBridge.app"
mkdir -p "$DIST"

bash scripts/build_app.sh arm64-apple-macos14.0
ACTUAL_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
[[ "$ACTUAL_VERSION" == "$RELEASE_VERSION" ]] || { echo "标签版本与工程版本不一致" >&2; exit 1; }
cp "$APP/Contents/MacOS/ProxyBridge" build/ProxyBridge-arm64
bash scripts/build_app.sh x86_64-apple-macos14.0
codesign --remove-signature "$APP"
lipo -create build/ProxyBridge-arm64 "$APP/Contents/MacOS/ProxyBridge" -output build/ProxyBridge-universal
mv build/ProxyBridge-universal "$APP/Contents/MacOS/ProxyBridge"
lipo "$APP/Contents/MacOS/ProxyBridge" -verify_arch arm64 x86_64
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/ProxyBridge.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/安装说明.txt" <<'NOTES'
ProxyBridge（macOS 14 或更高版本，支持 Apple Silicon 与 Intel）

1. 将 ProxyBridge.app 拖到 Applications 文件夹。
2. 从应用程序文件夹启动；应用位于菜单栏。
3. 首次打开被 macOS 拦截时（ad-hoc 签名，未获 Apple 公证，属预期），
   确认从官方仓库下载后，任选其一解除：
   a. 「系统设置 → 隐私与安全性」底部点「仍要打开」；
   b. 终端执行：xattr -dr com.apple.quarantine /Applications/ProxyBridge.app
4. 在此 Mac 上启动代理客户端，并在 ProxyBridge 中添加服务器。
5. 首次连接前，请在此 Mac 的终端 SSH 登录一次并核对主机指纹。

安装包不包含任何用户配置、钥匙串、密码或私钥。
官方仓库：https://github.com/fejxc/ProxyBridge

------------------------------------------------------------------------------
English quick guide

ProxyBridge (macOS 14+, universal: Apple Silicon & Intel)

1. Drag ProxyBridge.app into the Applications folder.
2. Launch it from Applications; the app lives in the menu bar.
3. If macOS blocks the first launch (ad-hoc signature, not notarized — expected),
   after confirming the download is from the official repo, either:
   a. open "System Settings → Privacy & Security" and click "Open Anyway", or
   b. run in Terminal: xattr -dr com.apple.quarantine /Applications/ProxyBridge.app
4. Start your proxy client on this Mac, then add a server in ProxyBridge.
5. Before the first connection, SSH into the server once from this Mac's
   Terminal and verify the host fingerprint.

The installer contains no user config, keychain, password, or private keys.
Official repo: https://github.com/fejxc/ProxyBridge
NOTES
DMG="$DIST/ProxyBridge-${RELEASE_VERSION}-universal.dmg"
hdiutil create -volname "ProxyBridge ${RELEASE_VERSION}" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
hdiutil verify "$DMG"

# Verify the actual mounted payload, not merely the staging folder.
hdiutil attach -readonly -nobrowse -plist "$DMG" > build/dmg-mount.plist
MOUNT_POINT=$(python3 - <<'PYMOUNT'
import plistlib
with open('build/dmg-mount.plist', 'rb') as file:
    entities = plistlib.load(file)['system-entities']
print(next(entity['mount-point'] for entity in entities if 'mount-point' in entity))
PYMOUNT
)
trap 'hdiutil detach "$MOUNT_POINT" >/dev/null' EXIT
codesign --verify --deep --strict "$MOUNT_POINT/ProxyBridge.app"
lipo "$MOUNT_POINT/ProxyBridge.app/Contents/MacOS/ProxyBridge" -verify_arch arm64 x86_64
[[ "$(readlink "$MOUNT_POINT/Applications")" == /Applications ]]
[[ "$RELEASE_VERSION" == "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MOUNT_POINT/ProxyBridge.app/Contents/Info.plist")" ]]
python3 - "$DMG" <<'PYHASH'
import hashlib
from pathlib import Path
import sys
path = Path(sys.argv[1])
digest = hashlib.sha256()
with path.open('rb') as file:
    for chunk in iter(lambda: file.read(1024 * 1024), b''):
        digest.update(chunk)
Path(str(path) + '.sha256').write_text(f'{digest.hexdigest()}  {path.name}\n')
PYHASH
echo "DMG 验证通过：$DMG"
