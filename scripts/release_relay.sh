#!/bin/bash
# 三段接力发版（v1.9.0 实战轮询流程固化，v1.10.0 起为标准发版路径）：
#   段1  等待标签指向 commit 的 ci.yml 全绿
#   段2  （--tag 模式）打标签并推送（默认要求标签已存在，标签确认权在发布者）
#   段3  等待发布工作流（release.yml）success → 资产核验：
#        Release 非草稿、Notes 非空、DMG + .sha256 资产齐备，
#        并用公开 URL 下载复算 sha256（校验的字节 = 用户拿到的字节）
#   收尾 调 scripts/sync_tap.sh 同步 Homebrew tap（--no-tap 跳过）
# 用法：
#   bash scripts/release_relay.sh v1.10.0 --tag        # CI 绿后自动打标签并走完全程
#   bash scripts/release_relay.sh v1.10.0              # 标签已推送：从段 3 开始
#   bash scripts/release_relay.sh v1.10.0 --tag --no-tap
# 依赖：curl、git、shasum、python3。
# 凭据：经 git credential fill 取 github.com token（仅用于 API 轮询，不回显）。
# 注意：轮询必须带认证头——匿名轮询耗尽出口 IP 的 API 配额后，用户 App 的
#       「检查更新」会报 403（v1.5.x 实测教训）；推送绕过本机代理（127.0.0.1:7897）。
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:?用法：bash scripts/release_relay.sh <tag> [--tag] [--no-tap]}"
AUTO_TAG=0
SYNC_TAP=1
for arg in "${@:2}"; do
  case "$arg" in
    --tag) AUTO_TAG=1 ;;
    --no-tap) SYNC_TAP=0 ;;
    *) echo "未知参数：$arg（支持 --tag / --no-tap）" >&2; exit 1 ;;
  esac
done
[[ "${TAG}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "标签必须为 vX.Y.Z 格式" >&2; exit 1; }
VERSION="${TAG#v}"
DMG="ProxyBridge-${VERSION}-universal.dmg"

TOKEN=$(printf "protocol=https\nhost=github.com\n\n" | git credential fill 2>/dev/null | awk -F= '/^password=/{print $2}')
[[ -n "${TOKEN}" ]] || { echo "钥匙串中无 github.com 凭据（git credential fill 为空）" >&2; exit 1; }
API="https://api.github.com/repos/fejxc/ProxyBridge"
api() { curl -fsS -H "Authorization: token ${TOKEN}" "$@"; }

# 查询某 workflow 在指定 head（sha 或分支/标签）上的最新 run，输出 "status conclusion"
run_state() {
  local head="$1" workflow="$2"
  api "${API}/actions/runs?head_sha=${head}&per_page=50" 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
for r in d.get('workflow_runs', []):
    if r['path'] == '.github/workflows/${workflow}':
        print(r['status'], r['conclusion'] or '-')
        break
" 2>/dev/null || true
}

echo "== 段1：等待 CI 全绿（每 60 秒查询，最多 30 分钟）=="
SHA=$(git rev-parse "${TAG}^{commit}")
for _ in $(seq 1 30); do
  STATE=$(run_state "${SHA}" ci.yml)
  case "${STATE}" in
    "completed success") echo "CI 全绿（${SHA:0:7}）"; break ;;
    "completed"*) echo "CI 结束但未通过：${STATE}" >&2; exit 1 ;;
    *) sleep 60 ;;
  esac
done
[[ "${STATE}" == "completed success" ]] || { echo "超时：CI 30 分钟未完成" >&2; exit 1; }

if [[ "${AUTO_TAG}" == 1 ]]; then
  if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    echo "标签 ${TAG} 已存在，跳过打标签"
  else
    git tag "${TAG}"
    git -c http.proxy= -c https.proxy= push origin "${TAG}"
    echo "标签 ${TAG} 已推送（指向 ${SHA:0:7}）"
  fi
else
  git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null || {
    echo "标签 ${TAG} 不存在：请先打标签推送，或使用 --tag 模式" >&2; exit 1;
  }
fi

echo "== 段3：等待发布工作流（每 60 秒查询，最多 30 分钟）=="
STATE=""
for _ in $(seq 1 30); do
  # 标签触发的工作流 head_branch = 标签名；用 event=push + branch 过滤
  STATE=$(api "${API}/actions/runs?branch=${TAG}&per_page=20" 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
for r in d.get('workflow_runs', []):
    if r['path'] == '.github/workflows/release.yml':
        print(r['status'], r['conclusion'] or '-')
        break
" 2>/dev/null || true)
  case "${STATE}" in
    "completed success") echo "发布工作流 success"; break ;;
    "completed"*) echo "发布工作流失败：${STATE}（草稿 Release 需用认证 API 删除后重跑）" >&2; exit 1 ;;
    *) sleep 60 ;;
  esac
done
[[ "${STATE}" == "completed success" ]] || { echo "超时：发布工作流 30 分钟未完成" >&2; exit 1; }

echo "== 段3：资产核验 =="
TMPDIR_RELAY=$(mktemp -d)
trap 'rm -rf "${TMPDIR_RELAY}"' EXIT
for _ in $(seq 1 10); do
  INFO=$(api "${API}/releases/tags/${TAG}" 2>/dev/null || true)
  ASSETS=$(printf '%s' "${INFO}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(' '.join(a['name'] for a in d.get('assets', [])))
" 2>/dev/null || true)
  if echo "${ASSETS}" | grep -q "${DMG}" && echo "${ASSETS}" | grep -q "${DMG}.sha256"; then break; fi
  sleep 30
done
printf '%s' "${INFO}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert not d.get('draft'), 'Release 仍为草稿'
assert (d.get('body') or '').strip(), 'Release Notes 为空'
print(f\"Release 公开非草稿，Notes {len(d['body'])} 字符\")
"
curl -fsSL -o "${TMPDIR_RELAY}/${DMG}" "https://github.com/fejxc/ProxyBridge/releases/download/${TAG}/${DMG}"
curl -fsSL -o "${TMPDIR_RELAY}/${DMG}.sha256" "https://github.com/fejxc/ProxyBridge/releases/download/${TAG}/${DMG}.sha256"
# shasum -c 按文件内裸文件名在 CWD 查找，必须先进入临时目录（v1.9.0 sync_tap 教训）
(cd "${TMPDIR_RELAY}" && shasum -a 256 -c "${DMG}.sha256")
stat -f "DMG %z 字节" "${TMPDIR_RELAY}/${DMG}"

if [[ "${SYNC_TAP}" == 1 ]]; then
  echo "== 收尾：同步 Homebrew tap =="
  bash scripts/sync_tap.sh "${TAG}"
else
  echo "已跳过 tap 同步（--no-tap）；需要时手动执行 bash scripts/sync_tap.sh ${TAG}"
fi
echo "发版接力完成：${TAG}"
