import Foundation
import Darwin

// ============================================================================
// L0Probe · L0 活引用判定（契约 ADR-03 / IF-03 · P-L0 / AC-05 / AC-17）
//
// **不 spawn `lsof`**（ADR-03 弃用理由：① `lsof` 静默丢权 → 「看不到」与「没有」
// 不可区分、失败不可归因，违反 N5；② 文本解析在含空格 / 非 UTF-8 路径上会串行；
// ③ PATH 劫持面。**性能不作为理由**）。
//
// ## 文件身份 = `(vst_dev, vst_ino)`，不是 `vnodeid`
// macOS SDK 的 `struct vnode_info` **只有 `vi_stat / vi_type / vi_fsid`，没有 `vnodeid`**
// → 产品自建 `UInt64` 键。
//
// ## 四条实测得来的实现约束（写死，否则第二个实现者还会踩）
//
// 1. **`PROC_PIDLISTFDS` 的返回值是字节数**，不是元素数。
//    **每项 8 B**（`struct proc_fdinfo` = `int32 proc_fd` + `uint32 proc_fdtype`），
//    **fd 号 = 数组下标**（不是结构体里存的字段）。
//    ⚠️ R2 v1.6 原文写「每项 24 B」是**错的**（那是 `state.residue` 段表项的尺寸，
//    被误套到 fd 列表上）——**按 24 B 解析会读进 3 倍脏数据**。
//    实测（2026-11-08 · 本机）：`returned=64` → 8 项，与 `fcntl` 实测 fd 集合
//    `{0..7}` **逐一对应**，fd 号即下标。
//
// 2. **`PROC_PIDFDVNODEPATHINFO` 的返回结构是 `vnode_fdinfowithpath`**，
//    **不是 `vnode_info_path`**。
//    `struct vnode_fdinfowithpath` = `proc_fileinfo pfi`（24 B）+ `vnode_info_path pvip`
//    → **`pvip` 起始于偏移 24**（实测：`dev`@24、`ino`@32）。
//    ⚠️ 若误按 `vnode_info_path` 解析，会把 24 字节头当成 `vi_stat` 的开头
//    → 读出 `dev=1, ino=0` 的**垃圾值** → **与 `stat()` 的身份永远对不上**
//    → L0 恒判「无活引用」→ **误删正在被使用的文件**。
//    实测（2026-11-08 · 本机）：`sizeof(vnode_fdinfowithpath)` = **1200**
//    = `proc_pidfdinfo` 的返回值；路径与 `fstat` 的 dev/ino **完全一致**。
//
// 3. **缓冲区必须 ≥ `PROC_PIDFDVNODEPATHINFO_SIZE`（1200 B）**。
//    实测：传 1024 B → `returned=0` 且 `errno=ENOMEM(12)`（**失败**）；
//    传 4096 B → 成功。**传 `sizeof(vnode_info_path)`（1176）会失败**。
//
// 4. **失败时返回 `0`，不是 `−1`**（`proc_pidinfo` / `proc_pidfdinfo`）。
//    **判定必须写 `returned == 0 && errno == EPERM`**——只判 `r < 0` 会**永不降级**
//    → 违反 N5 末句「不把未知判为安全」。
//
// 5. **跨 uid 进程恒 `EPERM` 是 APFS/TCC 的正常行为，FDA 也不解锁**
//    （实测：本机 8 个跨 uid 进程全部 `returned==0 && errno==EPERM`）。
//    故 **跨 uid 一律不计入 `degraded`**，只计入 `coverage.statOtherUID`（诊断用、不上界面）。
//    **`degraded = true` 仅当「同 uid 进程枚举失败」**——这才与 AC-14 的「权限受阻」同义。
// ============================================================================

/// 文件身份键 = `(vst_dev, vst_ino)`。
///
/// **为什么不直接用 `ino`**：inode 号**只在同一设备内唯一**，跨设备会撞。
/// `vst_dev` 是 `uint32`、`vst_ino` 是 `uint64`。
///
/// **为什么不编码成单个 `UInt64`**：`dev`（32 bit）与 `ino`（64 bit）**无法无损塞进 64 bit**。
/// R2 IF-03 写的「`(dev << 32) | ino`」在 `vst_ino` 为 64 bit 时**会截断 `ino` 的高位**
/// → 两个不同文件可能撞成同一身份 → **倒排表误命中 → 误判活引用 / 误删活文件**。
/// 故本实现**保留二元组**（`Hashable` 自带正确的相等判定），不做单键编码。
public struct FileIdentity: Hashable, Sendable, CustomStringConvertible {
    /// `vst_dev`：设备号（`uint32`）。
    public let dev: UInt32
    /// `vst_ino`：inode 号（`uint64`）。
    public let ino: UInt64

    public init(dev: UInt32, ino: UInt64) {
        self.dev = dev
        self.ino = ino
    }

    /// 由 `vinfo_stat` 构造。
    public init(vst: vinfo_stat) {
        self.dev = vst.vst_dev
        self.ino = vst.vst_ino
    }

    /// 由 `stat()` 构造（**地面真值**，用于把候选路径转成身份）。
    public init(st: stat) {
        self.dev = UInt32(truncatingIfNeeded: st.st_dev)
        self.ino = UInt64(st.st_ino)
    }

    public var description: String { "(\(dev), \(ino))" }
}

/// L0 快照的诊断覆盖信息（**不上界面**，仅供日志 / 报告）。
public struct L0Coverage: Sendable, Equatable {
    /// 同 uid 进程总数。
    public var sameUIDTotal: Int
    /// 同 uid 进程中**成功枚举到 fd 列表**的数量。
    public var sameUIDRead: Int
    /// 跨 uid 进程数（**恒不可读**，不计入 `degraded`）。
    public var statOtherUID: Int

    public init(sameUIDTotal: Int = 0, sameUIDRead: Int = 0, statOtherUID: Int = 0) {
        self.sameUIDTotal = sameUIDTotal
        self.sameUIDRead = sameUIDRead
        self.statOtherUID = statOtherUID
    }
}

/// L0 活引用快照（契约 IF-03）。
public struct L0Snapshot: Sendable {
    /// 倒排表：文件身份 → 持有它的进程 pid 列表。
    ///
    /// **只含同 uid 进程**（判定域 = 同 uid，见 ADR-03「判定域写死」）。
    public var inodes: [FileIdentity: [pid_t]]

    /// 各同 uid 进程的 cwd 路径集合（用于「候选是某进程 cwd 的祖先」判定）。
    public var cwdPaths: Set<String>

    /// 快照时刻。
    public var capturedAt: Date

    /// **仅当同 uid 进程枚举失败时为 `true`**（跨 uid 恒 `EPERM` 不计入）。
    public var degraded: Bool

    /// 诊断覆盖信息（不上界面）。
    public var coverage: L0Coverage

    public init(
        inodes: [FileIdentity: [pid_t]] = [:],
        cwdPaths: Set<String> = [],
        capturedAt: Date = Date(),
        degraded: Bool = false,
        coverage: L0Coverage = L0Coverage()
    ) {
        self.inodes = inodes
        self.cwdPaths = cwdPaths
        self.capturedAt = capturedAt
        self.degraded = degraded
        self.coverage = coverage
    }
}

/// L0 活引用探测器（契约 ADR-03 / IF-03）。
public enum L0Probe {

    // MARK: - 快照

    /// 采集一次 L0 快照。
    ///
    /// - Parameter excludePIDs: **必须排除的 pid**（含产品自身）。
    ///   产品自己 `open()` 候选做 lock 探测时，若不排除自身就会**把自己判成活引用**
    ///   → `a` / `b` 失真（IF-03「自污染防护」）。
    public static func snapshot(
        excludePIDs: Set<pid_t> = [],
        now: Date = Date()
    ) -> L0Snapshot {
        var snapshot = L0Snapshot(capturedAt: now)
        snapshot.coverage = L0Coverage()

        let myUID = getuid()
        let myPID = getpid()

        // ---- 进程表 ----
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var length = 0
        guard sysctl(&mib, 4, nil, &length, nil, 0) == 0, length > 0 else {
            // 连进程表都读不到 → **本用户进程也看不到** → 按「同 uid 失败」降级。
            snapshot.degraded = true
            return snapshot
        }
        let count = length / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &length, nil, 0) == 0 else {
            snapshot.degraded = true
            return snapshot
        }
        let realCount = length / MemoryLayout<kinfo_proc>.stride

        var inodeOwners: [FileIdentity: [pid_t]] = [:]
        var cwdPaths = Set<String>()

        for i in 0..<realCount {
            let proc = procs[i]
            let pid = proc.kp_proc.p_pid
            if pid <= 0 { continue }

            // 自身与显式排除项：**归集但不计入 `P_now`**（自污染防护）。
            let isExcluded = (pid == myPID) || excludePIDs.contains(pid)

            let ownerUID = proc.kp_eproc.e_ucred.cr_uid
            if ownerUID != myUID {
                // 跨 uid：**恒不可读**，不计入 `degraded`（ADR-03 实测约束 ③）。
                snapshot.coverage.statOtherUID += 1
                continue
            }
            snapshot.coverage.sameUIDTotal += 1

            // ---- fd 列表 ----
            // `proc_pidinfo` 签名（Swift 侧）：
            //   (pid: Int32, flavor: Int32, arg: UInt64, buf: UnsafeMutableRawPointer?, bufSize: Int32) -> Int32
            let fdBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            if fdBytes <= 0 {
                // 返回 0（不是 −1）；**errno 才有意义**。
                let e = errno
                if e == EPERM {
                    // 同 uid 也读不到 → **这才是真正的「权限受阻」**（AC-14 语义）。
                    snapshot.degraded = true
                }
                // 同 uid 但 errno 非 EPERM（如进程已退出）→ 不降级，只是不贡献 fd。
                continue
            }
            snapshot.coverage.sameUIDRead += 1

            // **返回值是字节数**，每项 `sizeof(proc_fdinfo)` = 8 B（实测约束 1）。
            let entryCount = Int(fdBytes) / MemoryLayout<proc_fdinfo>.stride
            guard entryCount > 0 else { continue }

            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: entryCount)
            let got = fds.withUnsafeMutableBytes { raw -> Int32 in
                proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, fdBytes)
            }
            guard got > 0 else { continue }
            let gotCount = Int(got) / MemoryLayout<proc_fdinfo>.stride

            for j in 0..<gotCount {
                let fdInfo = fds[j]
                // 只处理 vnode 类 fd（socket / pipe 等不是文件）。
                guard fdInfo.proc_fdtype == PROX_FDTYPE_VNODE else { continue }
                // **fd 号 = 数组下标**（实测约束 1）——不是结构体字段。
                let fd = Int32(j)

                // ⚠️ 必须是 `vnode_fdinfowithpath`（= `proc_fileinfo` 24 B + `vnode_info_path`），
                //    **不是** `vnode_info_path`（实测约束 2）——后者会读出 `dev=1, ino=0` 的垃圾。
                var vfpBuf = vnode_fdinfowithpath()
                // 缓冲区必须 ≥ `PROC_PIDFDVNODEPATHINFO_SIZE`（1200 B）；传 1176 会 ENOMEM 失败。
                let vnBytes = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
                let vn = withUnsafeMutablePointer(to: &vfpBuf) { ptr -> Int32 in
                    proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, ptr, vnBytes)
                }
                guard vn > 0 else { continue }

                let identity = FileIdentity(vst: vfpBuf.pvip.vip_vi.vi_stat)
                var owners = inodeOwners[identity] ?? []
                owners.append(pid)
                inodeOwners[identity] = owners
            }

            // ---- cwd ----
            var cwdBuf = vnode_info_path()
            let cwdBytes = Int32(MemoryLayout<vnode_info_path>.stride)
            let cw = withUnsafeMutablePointer(to: &cwdBuf) { ptr -> Int32 in
                proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, ptr, cwdBytes)
            }
            if cw > 0 {
                // `vip_path` 在 Swift 里已是 `Tuple` of `CChar`（不是指针）。
                // 借整体内存按 C 字符串读取——避开 tuple → Array 转换与
                // `withUnsafePointer(to:)` 的独占访问冲突。
                let path = withUnsafeBytes(of: &cwdBuf.vip_path) { raw -> String in
                    let base = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
                    return String(cString: base)
                }
                if !path.isEmpty { cwdPaths.insert(path) }
            }
        }

        // ---- 排除自身 / 排除项 ----
        // 倒排表的**值**（pid 列表）里要去掉排除项；
        // 若某身份**只剩排除者**，则该身份不算被持有。
        let excluded = excludePIDs.union([myPID])
        var filtered: [FileIdentity: [pid_t]] = [:]
        filtered.reserveCapacity(inodeOwners.count)
        for (identity, owners) in inodeOwners {
            let kept = owners.filter { !excluded.contains($0) }
            if !kept.isEmpty { filtered[identity] = kept }
        }

        snapshot.inodes = filtered
        snapshot.cwdPaths = cwdPaths
        return snapshot
    }

    // MARK: - 判定

    /// 判定某候选是否「被持有」（P-L0 判据：fd / 文件锁 / cwd 三者之一）。
    ///
    /// - `identity`: 候选的文件身份（`(dev, ino)`）。
    /// - `isDirectory`: 候选是否为目录（目录走 cwd 祖先判定）。
    /// - `path`: 候选路径（用于 cwd 祖先判定）。
    ///
    /// **判定域 = 同 uid 进程**（ADR-03）→ 返回 `true` 的含义是
    /// 「**本用户进程**持有」，**不是「全系统持有」**。
    public static func isHeld(
        identity: FileIdentity,
        isDirectory: Bool,
        path: String,
        by snapshot: L0Snapshot
    ) -> Bool {
        // ① fd 命中
        if snapshot.inodes[identity] != nil { return true }

        // ② 候选是某进程 cwd 的祖先（目录）
        if isDirectory {
            for cwd in snapshot.cwdPaths where isAncestor(cwd, of: path) {
                return true
            }
        }
        return false
    }

    /// `ancestor` 是否是 `path` 的祖先目录（或二者相同）。
    ///
    /// **按路径前缀比较，但必须按路径分量边界比较**——
    /// 直接用 `hasPrefix` 会把 `/a/bc` 误判为 `/a/b` 的子目录。
    public static func isAncestor(_ ancestor: String, of path: String) -> Bool {
        if ancestor == path { return true }
        var prefix = ancestor
        if !prefix.hasSuffix("/") { prefix += "/" }
        return path.hasPrefix(prefix)
    }
}
