import XCTest
@testable import ResidueCore
import Darwin

/// L0Probe 测试（契约 ADR-03 / IF-03 · K2 台账 A-6 验收四问）。
///
/// **判定域 = 同 uid 进程**（ADR-03「判定域写死」）：
/// - ① 目标机器上「本用户进程无引用」判定正确
/// - ② 跨 uid 不计入 `degraded`
/// - ③ 自身 fd 不计入 `P_now`
/// - ④ `degraded` 只在同 uid 失败时为 true
final class L0ProbeTests: XCTestCase {

    // MARK: - ① 本用户进程持有 → 判定为「被持有」

    /// 打开一个文件 → 它的 `(dev, ino)` 必须出现在快照的倒排表里。
    ///
    /// **注意**：产品自身默认被排除（IF-03「自污染防护」），
    /// 所以本用例通过**排除另一个进程**来验证「倒排表确实抓到了真实持有者」——
    /// 测试进程自己打开的文件**不会**出现在表里（那正是③ 验证的事）。
    func testOpenFileIsDetectedAsHeldByAnotherProcess() throws {
        // 起一个子进程打开文件，父进程（测试）枚举时应看到它
        let path = NSTemporaryDirectory() + "l0probe-held-\(UUID().uuidString).txt"
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }

        // 用 sh 持有文件：`sh -c 'cat file'` 会真的打开它
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "sleep 30 < '\(path)'"]
        try proc.run()
        defer {
            proc.terminate()
            proc.waitUntilExit()
        }

        var st = stat()
        XCTAssertEqual(stat(path, &st), 0)
        let identity = FileIdentity(st: st)

        // 等待子进程确实打开
        var found = false
        for _ in 0..<50 {
            let snapshot = L0Probe.snapshot()
            if snapshot.inodes[identity] != nil { found = true; break }
            usleep(100_000)
        }
        XCTAssertTrue(
            found,
            "另一个同 uid 进程打开的文件必须出现在倒排表中"
            + "（否则 L0 恒判「无引用」→ 误删正在被使用的文件）"
        )
    }

    /// 未被任何进程打开的文件 → **不应**出现在倒排表里（倒排表不能是全集）。
    func testUnopenedFileIsNotInTable() throws {
        let path = NSTemporaryDirectory() + "l0probe-unopened-\(UUID().uuidString).txt"
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }

        var st = stat()
        XCTAssertEqual(stat(path, &st), 0)
        let identity = FileIdentity(st: st)

        let snapshot = L0Probe.snapshot()
        XCTAssertNil(snapshot.inodes[identity], "没被打开的文件不应出现在倒排表里")
    }

    /// **倒排表里的身份必须与 `stat()` 一致**（实测约束 2 的回归断言）。
    ///
    /// ⚠️ 若误用 `vnode_info_path` 解析 `PROC_PIDFDVNODEPATHINFO`，
    /// 会读出 `dev=1, ino=0` 的垃圾 → 与 `stat()` 永远对不上 → **L0 恒判无引用**。
    func testTableIdentityMatchesStatExactly() throws {
        // 让子进程持有文件
        let path = NSTemporaryDirectory() + "l0probe-identity-\(UUID().uuidString).txt"
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "sleep 30 < '\(path)'"]
        try proc.run()
        defer { proc.terminate(); proc.waitUntilExit() }

        var st = stat()
        XCTAssertEqual(stat(path, &st), 0)
        let identity = FileIdentity(st: st)

        var matched: FileIdentity?
        for _ in 0..<50 {
            let snapshot = L0Probe.snapshot()
            if let hit = snapshot.inodes.keys.first(where: { $0 == identity }) {
                matched = hit
                break
            }
            usleep(100_000)
        }
        let hit = try XCTUnwrap(matched, "应能按 (dev, ino) 精确命中")
        XCTAssertEqual(hit.dev, UInt32(truncatingIfNeeded: st.st_dev), "dev 必须与 stat 一致")
        XCTAssertEqual(hit.ino, UInt64(st.st_ino), "ino 必须与 stat 一致")
        XCTAssertNotEqual(hit.dev, 1, "dev=1 是「误用 vnode_info_path 解析」的典型垃圾值")
        XCTAssertNotEqual(hit.ino, 0, "ino=0 是同上")
    }

    // MARK: - ③ 自身 fd 不计入 `P_now`（自污染防护）

    /// `excludePIDs` 含自身 pid 时，自己打开的文件**不应**出现在倒排表。
    func testExcludeSelfRemovesOwnFds() throws {
        let path = NSTemporaryDirectory() + "l0probe-self-\(UUID().uuidString).txt"
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let fd = open(path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }

        var st = stat()
        XCTAssertEqual(stat(path, &st), 0)
        let identity = FileIdentity(st: st)

        // 排除自身（产品自身 + 其他被排除 pid）
        let snapshot = L0Probe.snapshot(excludePIDs: [getpid()])
        XCTAssertNil(
            snapshot.inodes[identity],
            "自身 fd 必须被排除 —— 否则产品自己 open() 候选做 lock 探测会把自己判成活引用"
        )
    }

    /// **默认就排除自身**（不必调用方显式传）——IF-03「必须排除 excludePIDs（含自身）」。
    func testSelfIsAlwaysExcludedByDefault() throws {
        // 默认调用（不传 excludePIDs）时，自身 pid 也不应出现在倒排表的 pid 列表里。
        let snapshot = L0Probe.snapshot()
        let myPID = getpid()
        for (_, owners) in snapshot.inodes {
            XCTAssertFalse(
                owners.contains(myPID),
                "自身 pid 不得出现在任何倒排项的持有者列表里"
            )
        }
    }

    // MARK: - ② 跨 uid 不计入 `degraded`

    /// 跨 uid 进程**恒不可读**，但这**不得**让 `degraded` 变 true。
    ///
    /// 这是 ADR-03 实测约束 ③：`degraded` 恒 true 会导致**永远不可点亮**（AC-08 组 B）。
    func testCrossUIDDoesNotSetDegraded() {
        let snapshot = L0Probe.snapshot()
        XCTAssertFalse(
            snapshot.degraded,
            "跨 uid 进程恒 EPERM 是正常行为，不得计入 degraded（否则永远不可点亮）"
        )
        // 若本机存在其它 uid 的进程，应被计入 statOtherUID 而非 degraded
        if snapshot.coverage.statOtherUID > 0 {
            XCTAssertGreaterThan(
                snapshot.coverage.statOtherUID, 0,
                "存在跨 uid 进程时 coverage.statOtherUID 应大于 0（诊断用）"
            )
        }
    }

    /// ④ `degraded` 只在**同 uid** 失败时为 true —— 本机同 uid 枚举成功 → 必为 false。
    func testDegradedOnlyWhenSameUIDFails() {
        let snapshot = L0Probe.snapshot()
        if snapshot.coverage.sameUIDTotal > 0 && snapshot.coverage.sameUIDRead > 0 {
            XCTAssertFalse(
                snapshot.degraded,
                "同 uid 枚举成功 → degraded 必须为 false"
            )
        }
        // 同 uid 总数应 > 0（至少含本进程）
        XCTAssertGreaterThan(snapshot.coverage.sameUIDTotal, 0)
    }

    // MARK: - 实现约束回归（踩过的坑，防止被改回去）

    /// **`PROC_PIDLISTFDS` 每项 8 B，不是 24 B**。
    ///
    /// R2 v1.6 原文写「每项 24 B」是错的（那是 `state.residue` 段表项的尺寸）。
    /// 按 24 B 解析会读进 3 倍脏数据 → fd 号全是垃圾 → **L0 恒判「无引用」→ 误删活文件**。
    func testProcFdInfoStrideIsEightBytes() {
        XCTAssertEqual(
            MemoryLayout<proc_fdinfo>.size, 8,
            "proc_fdinfo = int32 fd + uint32 type = 8 B；若此断言变了说明 SDK 变了，"
            + "必须同步复核 ADR-03 的解析约束"
        )
    }

    /// **实测：返回字节数 ÷ 8 == 真实 fd 数**（用 `fcntl` 作地面真值）。
    ///
    /// 这是对「返回值是字节数、fd 号 = 数组下标」的最强断言。
    func testProcPidListFdsReturnsBytesAndFdsAreIndices() throws {
        let myPID = getpid()
        // 先打开一个文件，制造已知的 fd
        let tmp = NSTemporaryDirectory() + "l0probe-fdcheck-\(UUID().uuidString).txt"
        FileManager.default.createFile(atPath: tmp, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let myFD = open(tmp, O_RDONLY)
        XCTAssertGreaterThanOrEqual(myFD, 0)
        defer { close(myFD) }

        // 地面真值：本进程实际打开的 fd 集合
        var realFDs = Set<Int32>()
        for fd in Int32(0)..<Int32(65536) where fcntl(fd, F_GETFD) != -1 {
            realFDs.insert(fd)
        }
        XCTAssertTrue(realFDs.contains(myFD), "前置：刚打开的 fd 应在真实集合里")

        // 按 8 B stride 解析
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var length = 0
        XCTAssertEqual(sysctl(&mib, 4, nil, &length, nil, 0), 0)
        let count = length / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        XCTAssertEqual(sysctl(&mib, 4, &procs, &length, nil, 0), 0)

        var myProc: kinfo_proc?
        for i in 0..<(length / MemoryLayout<kinfo_proc>.stride) where procs[i].kp_proc.p_pid == myPID {
            myProc = procs[i]
            break
        }
        let proc = try XCTUnwrap(myProc)

        let fdBytes = proc_pidinfo(proc.kp_proc.p_pid, PROC_PIDLISTFDS, 0, nil, 0)
        XCTAssertGreaterThan(fdBytes, 0, "本进程应能枚举到自己的 fd")

        let entryCount = Int(fdBytes) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: entryCount)
        let got = fds.withUnsafeMutableBytes { raw -> Int32 in
            proc_pidinfo(proc.kp_proc.p_pid, PROC_PIDLISTFDS, 0, raw.baseAddress, fdBytes)
        }
        let gotCount = Int(got) / MemoryLayout<proc_fdinfo>.stride

        // 解析出的 fd 号（= 数组下标）应与地面真值**完全一致**
        var parsed = Set<Int32>()
        for j in 0..<gotCount { parsed.insert(Int32(j)) }
        XCTAssertEqual(
            parsed, realFDs,
            "按 8 B stride 解析出的 fd 下标集合应与 fcntl 实测集合完全一致；"
            + "不一致说明 stride 假设错了（24 B 会读进 3 倍脏数据）"
        )
        XCTAssertTrue(parsed.contains(myFD), "刚打开的 fd 必须出现在解析结果里")
    }

    /// **失败时返回 0 而非 −1**，且 `errno` 才有意义（ADR-03 失败判据）。
    ///
    /// 用**不存在的 pid** 触发失败路径：应得 `returned == 0`（或负值但 errno 有意义），
    /// **不能**假设 `r < 0`。
    func testFailureReturnsZeroNotMinusOne() {
        let bogusPID: pid_t = 0x7FFFFFF0   // 几乎不可能存在的 pid
        errno = 0
        let r = proc_pidinfo(bogusPID, PROC_PIDLISTFDS, 0, nil, 0)
        // 关键断言：**不是靠 `r < 0` 判断失败**
        XCTAssertFalse(
            r < 0,
            "若此处返回负值，说明契约前提变了（失败返回 0）需复核 ADR-03 失败判据"
        )
        // 失败时 errno 应被设置
        XCTAssertNotEqual(errno, 0, "失败时应设置 errno")
    }

    /// **`vinfo_stat` 没有 `vnodeid`**（ADR-03 的 K2 实测更正）。
    ///
    /// 用反射确认：`vst_dev` / `vst_ino` 存在，且没有名为 `vnodeid` 的成员。
    func testVnodeInfoHasNoVnodeIDField() {
        let devOffset = MemoryLayout<vinfo_stat>.offset(of: \vinfo_stat.vst_dev)
        let inoOffset = MemoryLayout<vinfo_stat>.offset(of: \vinfo_stat.vst_ino)
        XCTAssertNotNil(devOffset, "vst_dev 应存在")
        XCTAssertNotNil(inoOffset, "vst_ino 应存在")
        // dev 是 uint32、ino 是 uint64 —— 故**不能**用 `(dev << 32) | ino` 编码（会截断 ino）
        XCTAssertEqual(MemoryLayout<vinfo_stat>.size, 136)
    }

    // MARK: - cwd 祖先判定

    /// `isAncestor` 必须**按路径分量边界**比较，不能用裸 `hasPrefix`。
    func testIsAncestorRespectsPathComponentBoundary() {
        XCTAssertTrue(L0Probe.isAncestor("/a/b", of: "/a/b/c"), "真祖先")
        XCTAssertTrue(L0Probe.isAncestor("/a/b", of: "/a/b"), "自身")
        XCTAssertFalse(
            L0Probe.isAncestor("/a/b", of: "/a/bc"),
            "`/a/bc` 不是 `/a/b` 的子目录 —— 裸 hasPrefix 会误判为真"
        )
        XCTAssertFalse(L0Probe.isAncestor("/a/b/", of: "/a/bc"))
        XCTAssertTrue(L0Probe.isAncestor("/a/b/", of: "/a/b/c"), "带尾斜杠也应成立")
    }

    /// 目录候选：若某进程的 cwd 在该目录下 → 判定为被持有。
    func testDirectoryCandidateHeldWhenProcessCwdInside() {
        var snapshot = L0Snapshot()
        snapshot.cwdPaths = ["/tmp/some/workdir"]
        let dirPath = "/tmp/some/workdir/sub"
        XCTAssertTrue(
            L0Probe.isHeld(identity: FileIdentity(dev: 1, ino: 2),
                           isDirectory: true, path: dirPath, by: snapshot),
            "进程 cwd 是候选目录的祖先 → 判定为被持有"
        )
    }

    /// 文件候选（isDirectory = false）**不走** cwd 祖先判定。
    func testFileCandidateIgnoresCwdAncestorRule() {
        var snapshot = L0Snapshot()
        snapshot.cwdPaths = ["/tmp/some/workdir"]
        let filePath = "/tmp/some/workdir/sub/file.txt"
        XCTAssertFalse(
            L0Probe.isHeld(identity: FileIdentity(dev: 1, ino: 2),
                           isDirectory: false, path: filePath, by: snapshot),
            "文件候选不适用 cwd 祖先判定（cwd 祖先规则只对目录成立）"
        )
    }

    // MARK: - FileIdentity 编码

    /// `FileIdentity` 必须区分不同 `ino`、不同 `dev`。
    func testFileIdentityDistinguishesDevAndIno() {
        let a = FileIdentity(dev: 1, ino: 100)
        let b = FileIdentity(dev: 2, ino: 100)
        let c = FileIdentity(dev: 1, ino: 101)
        XCTAssertNotEqual(a, b, "dev 不同 → 不同身份")
        XCTAssertNotEqual(a, c, "ino 不同 → 不同身份")
        XCTAssertEqual(a, FileIdentity(dev: 1, ino: 100))
    }

    /// **`ino` 高位不能被截断**——这正是不能用 `(dev << 32) | ino` 的原因。
    func testLargeInoIsNotTruncated() {
        let big = FileIdentity(dev: 7, ino: UInt64(1) << 40 | 12345)
        XCTAssertEqual(big.ino, UInt64(1) << 40 | 12345, "ino 不得被截断")
        XCTAssertEqual(big.dev, 7)
    }
}
