# 应用复查与演示清理（2026-10-12）

已删除应用中的演示装配入口、模式开关、横幅、代理检测演示分支以及日志演示前缀。隧道、代理检测、密码存储的内存替身统一放到 `ProxyBridgeTests/MockServices.swift`，只编入测试目标和冒烟测试，应用目标不包含这些替身。历史交付报告保留，不改写之前的验证记录。

修复和优化：

- 「检查连接」「断开」日志使用实际操作文案；状态不变时也记录新的健康检查结果和 HTTP 状态码。
- 健康检查复核隧道实际使用的本地代理，包括自动检测端点；失败时降级，不保留旧的绿色状态。
- 远端验证采用隧道实际使用的协议；复制命令优先使用当前隧道端点协议，不把协议偏好当成实测结果。
- 远端缺 curl 与 curl 请求失败分开处理；失败退出码即使伴随 HTTP 状态码也不能判定验证成功。
- 未实现的系统通知、周期检查控件禁用并附说明；通用设置去除开发阶段文案。
- 更新当前 README 和已知限制，移除“不支持记住密码”等过期说明。

## 验证

| 项目 | 状态 | 证据 |
|---|---|---|
| 编译检查 | 通过 | `bash scripts/typecheck.sh`：App 与测试代码 0 error，Swift 6 预检通过；既有测试 warning 仍在。 |
| 冒烟测试 | 通过 | `bash scripts/smoke_test.sh`：114 项 PASS，0 项失败。原有安全、断开、端点校验断言保留；演示前缀断言按删除需求改为普通日志脱敏断言。 |
| 实际远端脚本错误分类 | 通过 | 用 `/bin/sh` 执行生成的脚本：curl 不存在与代理连接失败分别分类；不访问外网来验证失败分支。 |
| 真实服务器复测 | 通过 | 生产协调器、真实本地代理和远端 SSH/curl：正确密码 connected、HTTP 200；错误密码 authRequired、测试内存存储清除；手动断开后无额外事件。使用临时远端端口 47891，测试后断开。 |
| 应用源码与已安装二进制清理检查 | 通过 | 没有演示字符串/模式符号，二进制不包含 MockProxyDetector、MockTunnelService、InMemoryPasswordStore。 |
| Xcode 工程结构 | 通过 | `plutil -lint` 通过；测试替身仅加入测试 Sources，未执行 xcodebuild。 |
| 安装与启动 | 通过 | `bash scripts/install_app.sh` 完成，安装到 `/Applications/ProxyBridge.app` 并确认启动。 |
| XCTest 运行与逐页视觉验收 | 未验证 | 本机只有 Command Line Tools；本轮没有运行 XCTest 或执行界面截图验收。 |
| 失败/阻塞 | 无 | 必要的编译、冒烟、安装及真实服务器复测完成。 |

安装重启会断开旧连接，使用前请重新连接服务器。用户配置和钥匙串未迁移或清空。当前不支持自动重连、周期健康检查、系统异常通知和应用内登录项注册，已在设置中说明。

检查输出：`build/typecheck-result.log`、`build/smoke-result.log`、`build/install-result.log`。真实服务器诊断源码不含凭据，保留在 git 忽略目录 `build/pty-diagnostics/`。
