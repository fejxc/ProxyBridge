#!/bin/bash
# 集成测试（测试金字塔的集成层）：拉起一个只绑定 127.0.0.1 高位端口的用户态 sshd
# （无需管理员、不影响系统 sshd），用临时密钥对本机登录，然后运行真实隧道场景：
# 真实 /usr/bin/ssh 子进程 + 真实 Relay / HTTPEntryRelay + 真实远端探测。
# 覆盖单元/冒烟层无法自动化的缺陷类别：端口绑定、转发建立、监听就绪竞态、字节搬运。
# 用法：bash scripts/integration_test.sh   （PB_STRICT=1 时环境不可用视为失败而非跳过）

set -uo pipefail
cd "$(dirname "$0")/.."

TARGET="${PB_TARGET:-$(uname -m)-apple-macos14.0}"
OUT="build/integration"
mkdir -p build

SSHD_BIN="/usr/sbin/sshd"
if [ ! -x "$SSHD_BIN" ]; then
  echo "integration: 未找到 sshd（$SSHD_BIN）"
  [ "${PB_STRICT:-0}" = "1" ] && exit 1 || exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pb-integration.XXXXXX")"
SSHD_PORT=""
SSHD_PID=""
cleanup() {
  if [ -n "$SSHD_PID" ] && kill -0 "$SSHD_PID" 2>/dev/null; then
    kill "$SSHD_PID" 2>/dev/null
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "== 准备用户态 sshd（127.0.0.1 高位端口，临时主机/用户密钥）=="
ssh-keygen -q -t ed25519 -N "" -f "$WORK/hostkey"
ssh-keygen -q -t ed25519 -N "" -f "$WORK/userkey"
cp "$WORK/userkey.pub" "$WORK/authorized_keys"
chmod 600 "$WORK/hostkey" "$WORK/userkey"

# 端口从 2299 起探测空闲位（用户态 sshd 不能绑 <1024；避开常用服务端口）
for candidate in 2299 2399 2499 2599 2699; do
  if ! nc -z 127.0.0.1 "$candidate" 2>/dev/null; then
    SSHD_PORT="$candidate"
    break
  fi
done
if [ -z "$SSHD_PORT" ]; then
  echo "integration: 2299–2699 均被占用，无法启动用户态 sshd"
  [ "${PB_STRICT:-0}" = "1" ] && exit 1 || exit 0
fi

cat > "$WORK/sshd_config" <<EOF
Port $SSHD_PORT
ListenAddress 127.0.0.1
HostKey $WORK/hostkey
PidFile $WORK/sshd.pid
AuthorizedKeysFile $WORK/authorized_keys
# PasswordAuthentication=yes + VERBOSE：为 askpass 取证场景服务——
# 任何密码都会被 PAM 拒绝（本机口令未知也不需要知道），VERBOSE 日志的
# 「Failed password」即「密码确实经 askpass → ssh → sshd」全链路送达的证据
PasswordAuthentication yes
PubkeyAuthentication yes
KbdInteractiveAuthentication yes
UsePAM no
AllowTcpForwarding yes
PermitListen 127.0.0.1:*
StrictModes no
LogLevel VERBOSE
EOF

"$SSHD_BIN" -f "$WORK/sshd_config" -E "$WORK/sshd.log"
SSHD_PID="$(cat "$WORK/sshd.pid" 2>/dev/null || true)"
if [ -z "$SSHD_PID" ] || ! kill -0 "$SSHD_PID" 2>/dev/null; then
  echo "integration: 用户态 sshd 启动失败"; head -5 "$WORK/sshd.log" 2>/dev/null
  [ "${PB_STRICT:-0}" = "1" ] && exit 1 || exit 0
fi

# 就绪等待 + known_hosts 预置（生产 ssh 参数强制 StrictHostKeyChecking=yes）
seed_known_hosts() {
  mkdir -p "$WORK/.ssh"
  chmod 700 "$WORK/.ssh"
  ssh-keyscan -p "$SSHD_PORT" -T 5 127.0.0.1 > "$WORK/.ssh/known_hosts" 2>/dev/null
  [ -s "$WORK/.ssh/known_hosts" ]
}
READY=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if seed_known_hosts; then READY=1; break; fi
  sleep 0.5
done
if [ "$READY" != "1" ]; then
  echo "integration: sshd 就绪等待超时"; head -5 "$WORK/sshd.log" 2>/dev/null
  [ "${PB_STRICT:-0}" = "1" ] && exit 1 || exit 0
fi
echo "sshd 已就绪：127.0.0.1:${SSHD_PORT}（known_hosts 已预置指纹）"

echo "== 编译集成测试可执行文件（App 生产源码 + tools/integration）=="
# HOME 指向临时目录：ssh 的 known_hosts/配置读取与生产语义一致且完全隔离
swiftc -o "$OUT" -swift-version 5 -target "$TARGET" \
  ProxyBridge/Models/*.swift ProxyBridge/Persistence/*.swift ProxyBridge/Services/*.swift \
  ProxyBridge/Presentation/L10n.swift \
  tools/integration/IntegrationMain.swift || exit 1

echo "== 执行 =="
PB_SSH_KNOWN_HOSTS="$WORK/.ssh/known_hosts" \
PB_SSH_PORT="$SSHD_PORT" \
PB_SSH_USER="$(whoami)" \
PB_SSH_KEY="$WORK/userkey" \
PB_ASKPASS_PROOF=1 \
"$OUT"
STATUS=$?

# askpass 全链路取证：sshd 收到并拒绝了密码 = helper → ssh → sshd 链路打通
if grep -q "Failed password" "$WORK/sshd.log" 2>/dev/null; then
  echo "askpass 取证：sshd 日志确认收到密码尝试（Failed password）——投递链路完整"
else
  echo "askpass 取证：sshd 日志未见 Failed password"
fi

# 进程卫生：场景结束后不允许残留本测试拉起的 ssh 子进程。
# 只匹配「-p 本测试端口」——绝不触碰用户自己的其他 ssh 隧道。
LEFTOVER=$(pgrep -u "$(whoami)" -f "ssh .*-p ${SSHD_PORT} .*127.0.0.1" 2>/dev/null || true)
if [ -n "$LEFTOVER" ]; then
  echo "integration: 发现本测试残留的 ssh 进程，强制清理：$LEFTOVER"
  echo "$LEFTOVER" | xargs kill 2>/dev/null
  [ "$STATUS" = "0" ] && STATUS=1
fi

exit "$STATUS"
