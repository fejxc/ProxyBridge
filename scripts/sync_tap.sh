#!/bin/bash
# 发布收尾：同步 Homebrew tap。
# 用法：bash scripts/sync_tap.sh <tag>        例：bash scripts/sync_tap.sh v1.8.2
# 流程：等待 Release 资产就绪 → 下载 DMG 与 .sha256 并校验 → 调 tap 镜像内的 bump.sh
#       更新 version/sha256 两行 → 提交并推送 fejxc/homebrew-tap。
# 依赖：curl、git、shasum、python3；本地 tap 镜像默认 $(brew --repository)/Library/Taps/fejxc/homebrew-tap。
# 凭据：经 git credential fill 取钥匙串中 github.com 的 token（仅用于读 Release API，不回显）。
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:?用法：bash scripts/sync_tap.sh v1.8.2}"
[[ "${TAG}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "标签必须为 vX.Y.Z 格式" >&2
  exit 1
}
VERSION="${TAG#v}"
DMG="ProxyBridge-${VERSION}-universal.dmg"

BREW_ROOT=$(brew --repository 2>/dev/null || true)
TAP_DIR="${PB_TAP_DIR:-${BREW_ROOT}/Library/Taps/fejxc/homebrew-tap}"
if [[ ! -d "${TAP_DIR}/.git" ]]; then
  echo "未找到本地 tap 镜像：${TAP_DIR}（可用 PB_TAP_DIR=<路径> 指定）" >&2
  exit 1
fi

TOKEN=$(printf "protocol=https\nhost=github.com\n\n" | git credential fill 2>/dev/null | awk -F= '/^password=/{print $2}')
[[ -n "${TOKEN}" ]] || {
  echo "钥匙串中无 github.com 凭据（git credential fill 为空）" >&2
  exit 1
}

echo "== 等待 Release 资产（每 30 秒查询，最多 20 分钟）=="
READY=""
for _ in $(seq 1 40); do
  ASSETS=$(curl -fsS -H "Authorization: token ${TOKEN}" \
    "https://api.github.com/repos/fejxc/ProxyBridge/releases/tags/${TAG}" 2>/dev/null |
    python3 -c "import json,sys; d=json.load(sys.stdin); print(' '.join(a['name'] for a in d.get('assets', [])))" 2>/dev/null || true)
  if echo "${ASSETS}" | grep -q "${DMG}" && echo "${ASSETS}" | grep -q "${DMG}.sha256"; then
    READY=1
    break
  fi
  sleep 30
done
if [[ -z "${READY}" ]]; then
  echo "超时：Release ${TAG} 的 DMG 与 sha256 资产未就绪" >&2
  exit 1
fi

TMPDIR_SYNC=$(mktemp -d)
trap 'rm -rf "${TMPDIR_SYNC}"' EXIT

echo "== 下载并校验发布产物 =="
# 与 cask 同一公开 URL 下载（不带认证），保证校验的字节就是用户会拿到的字节
curl -fsSL -o "${TMPDIR_SYNC}/${DMG}" "https://github.com/fejxc/ProxyBridge/releases/download/${TAG}/${DMG}"
curl -fsSL -o "${TMPDIR_SYNC}/${DMG}.sha256" "https://github.com/fejxc/ProxyBridge/releases/download/${TAG}/${DMG}.sha256"
shasum -a 256 -c "${TMPDIR_SYNC}/${DMG}.sha256"

echo "== 更新 tap =="
"${TAP_DIR}/bump.sh" "${VERSION}" "${TMPDIR_SYNC}/${DMG}.sha256"
cd "${TAP_DIR}"
git add Casks/proxybridge.rb
git commit -m "proxybridge ${VERSION}"
git -c http.proxy= -c https.proxy= push origin main
echo "tap 已同步 ${VERSION} 并推送"
