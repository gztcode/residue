import XCTest
@testable import ResidueCore

// ============================================================
// L0 快照组装：`degraded` 与排除项的**分支覆盖**
//
// ## 这个文件为什么存在
//
// `degraded = true` 是 AC-14 第一类（权限受阻）的**唯一入口** ——
// 它一变真，界面上四档采集就必须给出「所缺权限 + 授权指引条目 ID」三要素。
//
// 而这条分支此前**一条测试都没有**。原来的两个相关测试是同义反复：
//
// ```swift
// // testCrossUIDDoesNotSetDegraded 里
// if snapshot.coverage.statOtherUID > 0 {
//     XCTAssertGreaterThan(snapshot.coverage.statOtherUID, 0)   // ← 在 if 里断言自己 > 0
// }
// // testDegradedOnlyWhenSameUIDFails 里
// if sameUIDTotal > 0 && sameUIDRead > 0 {
//     XCTAssertFalse(snapshot.degraded)   // ← 只验「本机不降级」
// }
// ```
//
// 两者都只在真机上能观察到的方向做断言。**「该降级时会降级」从未被验过。**
// 而按架构裁定，「同 uid 进程 fd 枚举失败」在真机上**不可确定性构造**
// （`chmod 000` 只撞 `E-101`；`PT_DENY_ATTACH` 不产生 EPERM；自然态 EPERM 恒 0）。
//
// 所以只能靠注入。`ProcessProbe` 就是为此抽出来的 —— 它**只换数据来源，不改判定逻辑**。
//
// > **一条永远不为真的分支，等于没实现。** 它会在界面上表现为
// > 「AC-14 第一类的授权指引永远不出现」，而所有测试全绿。
// ============================================================

final class L0SnapshotAssemblyTests: XCTestCase {

    // MARK: - 假探针

    /// 可编程的假探针：把「内核会怎么回答」变成测试输入。
    struct FakeProbe: L0Probe.ProcessProbe {
        var fdLists: [pid_t: L0Probe.FDList] = [:]
        var identities: [pid_t: [Int32: FileIdentity]] = [:]
        var cwds: [pid_t: String] = [:]

        func fdList(pid: pid_t) -> L0Probe.FDList {
            fdLists[pid] ?? L0Probe.FDList(fds: [], errno: 0)
        }
        func identity(pid: pid_t, fd: Int32) -> FileIdentity? {
            identities[pid]?[fd]
        }
        func cwd(pid: pid_t) -> String? {
            cwds[pid]
        }
    }

    private let myUID = getuid()
    /// **不能写死 501** —— 本机用户的 uid 恰好可能就是 501，
    /// 那样「跨 uid」就退化成「同 uid」，测试断言会全错。
    /// （我第一版就是这么写的，四条断言同时失败。）
    private var otherUID: uid_t { myUID &+ 1 }

    // MARK: - 一、degraded 的置位（此前从未被测）

    /// **同 uid 进程的 fd 枚举返回 `EPERM` → `degraded` 必须为 true。**
    ///
    /// 这是 AC-14 第一类的触发条件。若这条不成立，界面上「来源无法读取」
    /// 与「所缺权限 + 授权指引」永远不会出现 —— 而它不会有任何报错。
    func testDegradedWhenSameUIDEnumerationFails() {
        let probe = FakeProbe(fdLists: [
            4242: L0Probe.FDList(fds: [], errno: EPERM),
        ])
        let snap = L0Probe.snapshot(
            probe: probe,
            processTable: [.init(pid: 4242, uid: myUID)]
        )
        XCTAssertTrue(
            snap.degraded,
            "同 uid 枚举 EPERM 必须置 degraded —— 否则 AC-14 第一类永不出现"
        )
        XCTAssertEqual(snap.coverage.sameUIDTotal, 1, "同 uid 进程应被计入")
        XCTAssertEqual(snap.coverage.sameUIDRead, 0, "读取失败不得计为已读")
    }

    /// **同 uid 但 `errno` 不是 `EPERM`（如进程刚退出 `ESRCH`）→ 不得降级。**
    ///
    /// 理由：进程退出是常态，把它算成「权限受阻」会让界面长期显示一条
    /// 用户无法处理的告警，而且会把 `degraded` 变成噪音。
    func testNotDegradedWhenErrnoIsNotEPERM() {
        let probe = FakeProbe(fdLists: [
            4243: L0Probe.FDList(fds: [], errno: ESRCH),
        ])
        let snap = L0Probe.snapshot(
            probe: probe,
            processTable: [.init(pid: 4243, uid: myUID)]
        )
        XCTAssertFalse(
            snap.degraded,
            "ESRCH（进程已退出）不是权限问题，不得降级"
        )
        XCTAssertEqual(snap.coverage.sameUIDRead, 0, "失败不计为已读")
    }

    /// **跨 uid 恒不可读，但绝不能置 `degraded`。**
    ///
    /// 这是 ADR-03 实测约束 ③：跨 uid 的 `EPERM` 是 APFS/TCC 的正常行为，
    /// FDA 也不解锁。若把它计入降级，**每一台有其它用户进程的 Mac 都会永远降级**
    /// → 永远点不亮 → 产品在多人机器上完全不可用。
    func testCrossUIDNeverDegrades() {
        // 跨 uid 进程：即使探针说 EPERM，也不该被查询（uid 判断在前）
        let probe = FakeProbe(fdLists: [
            9001: L0Probe.FDList(fds: [], errno: EPERM),
        ])
        let snap = L0Probe.snapshot(
            probe: probe,
            processTable: [
                .init(pid: 9001, uid: otherUID),
                .init(pid: 4244, uid: myUID),
            ]
        )
        XCTAssertFalse(snap.degraded, "跨 uid 的 EPERM 不得计入 degraded")
        XCTAssertEqual(snap.coverage.statOtherUID, 1, "跨 uid 进程计入诊断位")
        XCTAssertEqual(snap.coverage.sameUIDTotal, 1, "只有同 uid 那个被计入同 uid")
    }

    /// **多个同 uid 进程里只要有一个 EPERM → 整体降级**（保守一侧）。
    ///
    /// 理由：只要有一个进程的 fd 看不到，就无法声称「我检查了所有活引用」。
    /// 此时宁可不判定，也不能假装判定过。
    func testOnePermissionFailureDegradesWholeSnapshot() {
        let id1 = FileIdentity(dev: 1, ino: 9001)
        let id3 = FileIdentity(dev: 1, ino: 9003)
        let probe = FakeProbe(
            fdLists: [
                5001: L0Probe.FDList(fds: [3], errno: 0),
                5002: L0Probe.FDList(fds: [], errno: EPERM),
                5003: L0Probe.FDList(fds: [4], errno: 0),
            ],
            // **必须配 identities**：否则 fd 查不到身份，倒排表必然空，
            // 「降级时仍保留已读信息」这条断言就变成了在测空气。
            identities: [
                5001: [3: id1],
                5003: [4: id3],
            ]
        )
        let snap = L0Probe.snapshot(
            probe: probe,
            processTable: [
                .init(pid: 5001, uid: myUID),
                .init(pid: 5002, uid: myUID),
                .init(pid: 5003, uid: myUID),
            ]
        )
        XCTAssertTrue(snap.degraded, "有一个读不到就整体降级（不假装判定过）")
        XCTAssertEqual(snap.coverage.sameUIDTotal, 3)
        XCTAssertEqual(snap.coverage.sameUIDRead, 2)
        // 读到的两个仍应贡献倒排表 —— 降级不等于丢弃已有信息
        XCTAssertFalse(snap.inodes.isEmpty, "降级时已读到的身份仍要保留（可看部分数据）")
    }

    /// **空进程表（不是 nil）→ 不降级。**
    ///
    /// 区分「读进程表失败」（`nil` → 降级）与「进程表里没有进程」（空数组 → 正常）。
    /// 两者混同会让一个空环境被误判成权限问题。
    func testEmptyProcessTableIsNotDegraded() {
        let snap = L0Probe.snapshot(probe: FakeProbe(), processTable: [])
        XCTAssertFalse(snap.degraded, "空进程表不是失败")
        XCTAssertEqual(snap.coverage.sameUIDTotal, 0)
        XCTAssertTrue(snap.inodes.isEmpty)
    }

    // MARK: - 二、排除项（倒排表过滤）

    /// **只有被排除的进程打开某文件 → 该文件不算被持有。**
    ///
    /// 这是自污染防护的核心：产品自己会打开候选文件做 stat，
    /// 若把自己算成「持有者」，**任何候选都会被判为「在用」→ 永远删不掉**。
    func testExcludedOnlyOpenerMeansNotHeld() {
        let identity = FileIdentity(dev: 1, ino: 100)
        let probe = FakeProbe(
            fdLists: [6001: L0Probe.FDList(fds: [3], errno: 0)],
            identities: [6001: [3: identity]]
        )
        let snap = L0Probe.snapshot(
            excludePIDs: [6001],
            probe: probe,
            processTable: [.init(pid: 6001, uid: myUID)]
        )
        XCTAssertTrue(
            snap.inodes[identity] == nil,
            "只有排除者打开过 → 该身份不算被持有（否则候选永远删不掉）"
        )
        XCTAssertFalse(L0Probe.isHeld(identity: identity, isDirectory: false,
                                      path: "/x", by: snap))
    }

    /// **排除者 + 另一个正常进程都打开 → 仍算被持有。**
    ///
    /// 滤掉排除者时不能把整个身份删掉，只能删「该 pid」这一项。
    /// 否则「产品自己打开过」会变成「可以删」的通行证 —— 那是灾难。
    func testExcludedPlusRealOwnerStillHeld() {
        let identity = FileIdentity(dev: 1, ino: 101)
        let probe = FakeProbe(
            fdLists: [
                6002: L0Probe.FDList(fds: [3], errno: 0),   // 被排除的
                6003: L0Probe.FDList(fds: [5], errno: 0),   // 真实持有者
            ],
            identities: [
                6002: [3: identity],
                6003: [5: identity],
            ]
        )
        let snap = L0Probe.snapshot(
            excludePIDs: [6002],
            probe: probe,
            processTable: [
                .init(pid: 6002, uid: myUID),
                .init(pid: 6003, uid: myUID),
            ]
        )
        XCTAssertEqual(
            snap.inodes[identity], [6003],
            "只删被排除的那个 pid，保留真实持有者"
        )
        XCTAssertTrue(L0Probe.isHeld(identity: identity, isDirectory: false,
                                     path: "/x", by: snap))
    }

    /// **自身进程默认被排除**，不需要调用方显式传。
    ///
    /// IF-03 原文要求「必须排除 excludePIDs（含自身）」。漏掉这条，
    /// 产品自己打开的任何文件都会变成「被持有」。
    func testSelfIsExcludedByDefaultInAssembly() {
        let myPID = getpid()
        let identity = FileIdentity(dev: 1, ino: 102)
        let probe = FakeProbe(
            fdLists: [myPID: L0Probe.FDList(fds: [3], errno: 0)],
            identities: [myPID: [3: identity]]
        )
        let snap = L0Probe.snapshot(
            probe: probe,
            processTable: [.init(pid: myPID, uid: myUID)]
        )
        XCTAssertTrue(
            snap.inodes[identity] == nil,
            "自身 pid 应默认被排除（不必调用方传 excludePIDs）"
        )
        XCTAssertEqual(snap.coverage.sameUIDTotal, 1, "自身仍计入 sameUIDTotal")
    }

    // MARK: - 三、cwd 祖先规则

    /// **目录候选：进程 cwd 在其子树内 → 判为被持有。**
    ///
    /// 理由：进程可能用相对路径访问该目录下的文件，此时 fd 表里看不到，
    /// 但目录确实在用。漏掉这条会删掉「当前正在工作的目录」。
    func testDirectoryHeldByCwdDescendant() {
        let probe = FakeProbe(cwds: [7001: "/tmp/proj/sub"])
        let snap = L0Probe.snapshot(
            probe: probe,
            processTable: [.init(pid: 7001, uid: myUID)]
        )
        XCTAssertTrue(
            L0Probe.isHeld(identity: FileIdentity(dev: 1, ino: 200),
                           isDirectory: true, path: "/tmp/proj", by: snap),
            "cwd 在候选目录之下 → 目录在用"
        )
        XCTAssertFalse(
            L0Probe.isHeld(identity: FileIdentity(dev: 1, ino: 201),
                           isDirectory: false, path: "/tmp/proj", by: snap),
            "文件候选不走 cwd 祖先规则（文件没有「子树」概念）"
        )
    }

    // MARK: - 四、端到端：degraded → AC-14 第一类的界面落点

    /// **`degraded` 一变真，④ 页四档就必须给出「所缺权限 + 授权指引条目 ID」。**
    ///
    /// 这是本文件里最要紧的一条：它把「内核层面看不见」与「用户能看到的指引」
    /// 连起来。少了这一环，前面所有 `degraded` 的断言都只是内部状态，
    /// 用户永远看不到那句「请到系统设置允许」。
    func testDegradedProducesPermissionTripleInUI() {
        let header = StateHeader(
            schemaVersion: 1,
            appVersion: "0.1.0",
            round: 1,
            roundStartAnchor: nil,
            countedDays: 0,
            countedDaysCap: 14,
            autoDeleteEnabled: false,
            lastScanAt: nil,
            sources: Source.allCases.map { SourceHeaderEntry(source: $0) },
            settlement: SettlementHeader(),
            bytes: ByteCounts()
        )
        let contents = StateFileContents(
            header: header, segments: [], payloads: [:], fileLength: 0
        )

        // 降级态
        let degraded = PageModelBuilder.build(
            PageModelBuilder.Input(contents: contents, degraded: true)
        )
        let blocked = degraded.collectionTiers[0].state
        XCTAssertTrue(blocked.isPermissionBlocked, "降级时状态位应为「权限受阻」")
        XCTAssertTrue(
            blocked.displayText.contains("所缺"),
            "必须给出「所缺权限」，实为「\(blocked.displayText)」"
        )
        XCTAssertTrue(
            blocked.displayText.contains("E-501"),
            "必须给出授权指引条目 ID，实为「\(blocked.displayText)」"
        )

        // 未降级态：同一位置不得出现权限受阻（否则告警永远在）
        let normal = PageModelBuilder.build(
            PageModelBuilder.Input(contents: contents, degraded: false)
        )
        XCTAssertFalse(
            normal.collectionTiers[0].state.isPermissionBlocked,
            "未降级时不得显示权限受阻"
        )
    }
}
