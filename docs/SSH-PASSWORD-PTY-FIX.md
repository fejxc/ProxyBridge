# SSH 密码 PTY 修复与验收（2026-10-12）

## 根因与修复

在真实服务器上，修复前的生产进程句柄输出 `read_passphrase: can't open /dev/tty: Device not configured`，随后 `Permission denied (publickey,password)`，未能进入可应答的密码提示。把 openpty 从端接到 Foundation.Process 的标准输入输出，并没有赋予 SSH 控制终端。

密码模式现在使用 posix_spawn 创建新 session，经应用的专用子进程入口调用 TIOCSCTTY 后 exec 系统 SSH。exec 保留 PID，终止操作只作用于该句柄拥有的进程。没有引入第三方 SSH、sshpass 或密码文件。密码通过关闭回显的 PTY 输入，未放入 argv、环境变量或日志；StrictHostKeyChecking=yes 和 NumberOfPasswordPrompts=1 保持不变。

提示检测改为完整的最后一行 `password:`，排除方法列表、调试行和拒绝文本。远端探测 stdout 独立收集；PTY 诊断在退出通知前排空，缓冲大小受限。密码提示超时会终止连接，旧进程的退出回调不会影响新会话。

OpenSSH 的控制终端读取逻辑可参见 [官方 readpass.c](https://github.com/openssh/openssh-portable/blob/master/readpass.c)。

## 变更文件

- `ProxyBridge/App/ProxyBridgeApp.swift`：应用启动前处理专用 PTY 子进程入口。
- `ProxyBridge/Services/SSHProcessLauncher.swift`：新 session、控制终端、无回显写入、独立 stdout、退出排空及进程回收。
- `ProxyBridge/Services/SSHTunnelCoordinator.swift`：完整提示检测、超时收尾、退出回调归属检查。
- `ProxyBridge/Services/RemoteProbeRunner.swift`：复用完整密码提示检测。
- `tools/smoke/SmokeMain.swift`：新增 10 项生产 PTY 回归断言，不改动原有 97 项语义。
- 本报告。

## 四态验收

| 项目 | 状态 | 实际结果 |
|---|---|---|
| `bash scripts/typecheck.sh` | 通过 | App、测试代码 0 error；Swift 6 预检也通过。测试代码仍有既有 warning；未运行 XCTest。 |
| `bash scripts/smoke_test.sh` | 通过 | 107 项 PASS，0 项失败，含原有 97 项及新增 10 项。 |
| `bash scripts/install_app.sh` | 通过 | 构建、安装并确认 `/Applications/ProxyBridge.app` 已启动。 |
| 正确密码 + 真实服务器 | 通过 | 生产协调器使用真实本地探测、真实 SSH 和真实远端 curl，进入 connected，HTTP 200。 |
| 已安装应用的 PTY 子进程入口 | 通过 | 诊断程序仅将启动入口指向已安装应用，重复正确/错误密码及断开验收，全部通过。 |
| 错误密码与记住密码清除 | 通过 | 一次密码尝试后进入 authRequired，显示密码拒绝原因；测试使用 InMemoryPasswordStore，确认记住密码被删除。 |
| 用户断开后无状态回跳 | 通过 | disconnect 后 idle，观察 2.5 秒无额外事件；结束后无测试 SSH 进程残留。 |
| 面板实际点击并提交密码 | 未验证 | 界面自动化多次读取超时，未完成面板输入操作。 |
| 面板与真实系统钥匙串联动清除 | 未验证 | 本轮认证失败清除验收使用内存替身，没有写入用户的系统钥匙串。 |
| 失败项 | 无 | 最终必要编译、冒烟、安装及服务器验证均通过。 |
| 阻塞项 | 界面自动化 | 应用窗口读取超时，只阻塞面板交互验收。 |

真实验证目标为已有服务器 `root@10.11.154.192:20064`，本地 HTTP 代理 `127.0.0.1:7897`，临时远端反向监听 `127.0.0.1:47891`。验证完毕已断开，没有修改服务器配置、authorized_keys 或用户配置文件。凭据从隐藏回显的 stdin 输入，仅在内存中使用，本报告和诊断源码不包含凭据。

编译、冒烟、安装输出保留在 `build/typecheck-result.log`、`build/smoke-result.log`、`build/install-result.log`。真实服务器诊断程序和无凭据源码保留在 `build/pty-diagnostics/`（git 忽略目录）。
