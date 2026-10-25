import Foundation
import Darwin

// MARK: - 单实例保护 + 崩溃孤儿清扫（P0）
//
// 双开（登录项与手动启动竞态）会抢本地 Relay 端口、抢远端转发端口，
// 互相制造"端口冲突"。孤儿 ssh（App 崩溃/强杀时 willTerminate 不执行，
// ssh -N 子进程被 launchd 收养）会持续占用远端端口。

/// 单实例锁：flock 一个缓存目录锁文件。
/// 崩溃时内核自动释放（进程退出即解锁），无需清理逻辑。
enum SingleInstanceGuard {
    static let activateNotificationName = "dev.sunyun.ProxyBridge.activate"

    private static var lockFD: Int32 = -1

    /// 获取单实例锁；false = 已有实例在运行（调用方应通知其激活后退出）。
    /// 锁文件不可用时放行（锁机制故障不应阻断启动）。
    /// 注意：绝不能用 FileManager.createFile 预建文件——它对已存在文件也走
    /// 「临时文件 + rename」原子替换，每次产生新 inode，旧 inode 上的 flock 锁
    /// 随之失效（实测踩坑）。open(O_CREAT) 原子创建且不重建已有文件。
    @discardableResult
    static func acquire() -> Bool {
        let path = NSHomeDirectory() + "/Library/Caches/dev.sunyun.ProxyBridge.single.lock"
        let fd = open(path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return true }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        lockFD = fd // 进程生命周期内持有；崩溃时内核自动释放
        return true
    }
}

/// 启动时清扫上次实例崩溃遗留的孤儿 ssh。
/// 判定（全部满足才动）：
/// - 属于当前用户（proc_bsdinfo.pbi_uid）
/// - 父进程已死（ppid == 1，被 launchd 收养；正常运行的隧道 ssh 父进程是本 App）
/// - 参数含 `-N`（非交互，纯转发）与 `ExitOnForwardFailure=yes`（本 App 隧道命令的独有组合；
///   用户终端里的交互式 ssh 不含 -N，不受影响）
/// 误杀面极小且收益明确：崩溃后远端端口不再被残留进程占住。
enum LocalOrphanSweeper {
    struct Orphan: Equatable, Sendable {
        var pid: Int32
        var arguments: [String]
    }

    /// 清扫并返回被终止的孤儿列表（如实上报，不静默）。
    static func sweep() -> [Orphan] {
        var killed: [Orphan] = []
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return killed }
        var pids = [Int32](repeating: 0, count: Int(capacity))
        let count = proc_listallpids(&pids, capacity)
        guard count > 0 else { return killed }
        let myUID = getuid()
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard isOrphan(pid: pid, uid: myUID) else { continue }
            guard let args = Self.arguments(of: pid), Self.matchesSignature(args) else { continue }
            kill(pid, SIGTERM)
            killed.append(Orphan(pid: pid, arguments: args))
        }
        return killed
    }

    /// 纯函数：参数是否匹配本 App 的隧道命令特征（测试覆盖）。
    static func matchesSignature(_ arguments: [String]) -> Bool {
        arguments.contains("-N") && arguments.contains("ExitOnForwardFailure=yes")
    }

    /// ppid==1 且同用户且非僵尸。
    static func isOrphan(pid: Int32, uid: UInt32) -> Bool {
        var info = proc_bsdinfo()
        let result = proc_pidinfo(pid, 0x0c /* PROC_PIDTBSDINFO */, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard result > 0 else { return false }
        return info.pbi_ppid == 1 && info.pbi_uid == uid && info.pbi_status != SZOMB
    }

    /// KERN_PROCARGS2 读取参数（同用户进程可读；失败返回 nil，跳过不杀）。
    /// 只返回 argv[1:]：布局里 envp 紧跟 argv，不按 argc 截断会把环境变量
    /// 一起带出来——一旦被写进日志或参与子串匹配就是环境变量泄露面。
    static func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, 49 /* KERN_PROCARGS2 */, pid]
        var buffer = [CChar](repeating: 0, count: 8192)
        var size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > Int32(MemoryLayout<Int32>.size) else { return nil }
        let raw = buffer[0..<Int(size)]
        // 布局：argc(Int32) + execpath\0 + 填充 NUL + argv[0..argc)\0 + envp\0…
        // 以 NUL 切分取非空段：segments[0]=argc 字节串、[1]=execpath、
        // [2 ..< 2+argc)=argv、其后为环境变量（必须丢弃）。
        let argc = raw.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return nil }
        var segments: [String] = []
        var start = raw.startIndex
        for index in raw.indices where raw[index] == 0 {
            if index > start {
                let bytes = raw[start..<index].map { UInt8(bitPattern: $0) }
                segments.append(String(decoding: bytes, as: UTF8.self))
            }
            start = raw.index(after: index)
        }
        let argvStart = 2
        guard segments.count >= argvStart + Int(argc) else { return nil }
        let argv = Array(segments[argvStart..<(argvStart + Int(argc))])
        return Array(argv.dropFirst()) // 丢弃 argv[0]（程序自身路径）
    }
}
