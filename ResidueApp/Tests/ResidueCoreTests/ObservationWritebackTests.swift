import XCTest
@testable import ResidueCore

/// CR-031 §3.3–§3.6 · 观察期写回层（Core · 纯函数）。
///
/// 写回层是「一次扫描 → 载体」的**唯一**转换处（不变量②）：
/// 取快照、结算、`a` 写入、`b` 累计、计数日推进，全在这里发生。
///
/// 本文件**不碰真文件系统**：L0 判定结果与路径探针都是注入的
/// （真文件系统用例在 `L0JudgeTests` 里）。
final class ObservationWritebackTests: XCTestCase {

    // MARK: - 夹具

    private let later = Date(timeIntervalSince1970: 1_000)
    private let later2 = Date(timeIntervalSince1970: 2_000)

    private func candidate(_ path: String, _ birthtime: TimeInterval) -> CandidateID {
        CandidateID(path: path, birthtime: Date(timeIntervalSince1970: birthtime))
    }

    /// 探针：字典里没有的路径一律判「确定不存在」。
    private func probe(_ states: [String: Settlement.PathState]) -> @Sendable (String) -> Settlement.PathState {
        { path in states[path] ?? .absent }
    }

    private func entry(_ header: StateHeader, _ source: Source) -> SourceHeaderEntry? {
        header.sources.first { $0.source == source }
    }

    /// 造一个「已取快照、观察期已满」的载体头。
    ///
    /// `H` 由 Core 的算式算（`H = min(30, T)`）—— 测试里不复制第二套算式。
    private func headerWithSnapshot(countedDays: Int, a: Int = 0, T: Int = 2) -> StateHeader {
        var header = StateHeader(countedDays: countedDays)
        header.sources = [
            SourceHeaderEntry(
                source: .uvCache,
                snapshotTaken: true,
                T: T,
                H: Threshold.h(forTotal: T),
                a: a
            )
        ]
        return header
    }

    // MARK: - ① 取快照

    func testFirstSuccessfulFullScanTakesSnapshotForDecisionDomainSource() {
        let uv = Source.uvCache
        let ids = [candidate("/cache/uv/a", 100), candidate("/cache/uv/b", 200)]

        let outcome = ObservationWriteback.apply(
            input: ObservationWriteback.Input(
                now: later,
                succeeded: true,
                mode: .full,
                scannedSources: [uv],
                candidates: [uv: ids]
            ),
            header: StateHeader(),
            payloads: [:]
        )

        // 先断言行数齐全 —— 否则下面的 `first { }` 可能命中 nil 而假绿
        XCTAssertEqual(outcome.header.sources.count, Source.allCases.count)
        XCTAssertEqual(entry(outcome.header, uv)?.snapshotTaken, true)
        XCTAssertEqual(entry(outcome.header, uv)?.T, 2)
        XCTAssertEqual(entry(outcome.header, uv)?.H, 2)
        XCTAssertNotNil(entry(outcome.header, uv)?.snapshotDate)
        XCTAssertEqual(outcome.payloads[uv]?.snapshotMembers.count, 2)
        XCTAssertEqual(outcome.snapshotSources, [uv])
    }

    func testPipxDoesNotTakeSnapshot() {
        let pipx = Source.pipxRun
        let ids = [candidate("/pipx/a", 100)]

        let outcome = ObservationWriteback.apply(
            input: ObservationWriteback.Input(
                now: later,
                succeeded: true,
                mode: .full,
                scannedSources: [pipx],
                candidates: [pipx: ids]
            ),
            header: StateHeader(),
            payloads: [:]
        )

        XCTAssertEqual(entry(outcome.header, pipx)?.snapshotTaken, false)
        XCTAssertNil(entry(outcome.header, pipx)?.T)
        XCTAssertNil(entry(outcome.header, pipx)?.H)
        XCTAssertEqual(outcome.payloads[pipx]?.snapshotMembers.count, 0)
        XCTAssertEqual(outcome.snapshotSources, [])
    }

    func testIncrementalScanDoesNotTakeSnapshot() {
        let uv = Source.uvCache
        let ids = [candidate("/cache/uv/a", 100)]

        let outcome = ObservationWriteback.apply(
            input: ObservationWriteback.Input(
                now: later,
                succeeded: true,
                mode: .incremental,
                scannedSources: [uv],
                candidates: [uv: ids]
            ),
            header: StateHeader(),
            payloads: [:]
        )

        XCTAssertEqual(entry(outcome.header, uv)?.snapshotTaken, false)
        XCTAssertNil(entry(outcome.header, uv)?.T)
        XCTAssertEqual(outcome.snapshotSources, [])
    }

    func testAbortedScanDoesNotTakeSnapshot() {
        let uv = Source.uvCache
        let ids = [candidate("/cache/uv/a", 100)]

        let outcome = ObservationWriteback.apply(
            input: ObservationWriteback.Input(
                now: later,
                succeeded: false,
                mode: .full,
                scannedSources: [uv],
                candidates: [uv: ids]
            ),
            header: StateHeader(),
            payloads: [:]
        )

        XCTAssertEqual(entry(outcome.header, uv)?.snapshotTaken, false)
        XCTAssertEqual(outcome.snapshotSources, [])
    }

    // MARK: - ② 结算写入

    /// 观察期已满 + **样本达标** ⇒ 结算把 `K` / `J` / `T` / 凭证写进载体。
    ///
    /// ⚠️ 夹具必须落在「达标」场景（`K ≥ H`）：
    /// 样本不足（`K < H`）会**自动开下一轮**，派生量当场清零（CR-033），
    /// 那种场景由 `testInsufficientSampleSettlementOpensNextRound` 覆盖。
    func testSettlementWritesKJAndCredentialsWhenObservationIsFull() {
        let uv = Source.uvCache
        let kept = candidate("/cache/uv/a", 100)
        let kept2 = candidate("/cache/uv/b", 200)

        let outcome = ObservationWriteback.apply(
            input: ObservationWriteback.Input(
                now: later,
                succeeded: true,
                mode: .full,
                scannedSources: [uv],
                candidates: [uv: [kept, kept2]],
                probe: probe(["/cache/uv": .exists])
            ),
            header: headerWithSnapshot(countedDays: ObservationProgress.requiredDays),
            payloads: [uv: SourcePayload(snapshotMembers: [kept, kept2])]
        )

        let e = entry(outcome.header, uv)
        XCTAssertEqual(e?.K, 2)
        XCTAssertEqual(e?.J, 0)
        XCTAssertEqual(e?.T, 2)
        // 恒等式：K + J == T（`J = T − K` 派生）
        XCTAssertEqual((e?.K ?? 0) + (e?.J ?? 0), e?.T)
        XCTAssertNotNil(e?.settlementDate)
        XCTAssertNotNil(e?.unattributableCount)
        XCTAssertEqual(e?.unattributableCount, 0)
        XCTAssertNotNil(outcome.header.settlement.producedAt)
        XCTAssertNotNil(outcome.header.settlement.reportId)
        XCTAssertEqual(outcome.settledSources, [uv])
        // 达标 ⇒ 不开轮 ⇒ 结算值留在载体上
        XCTAssertEqual(outcome.header.round, 1)
        XCTAssertEqual(outcome.header.countedDays, ObservationProgress.requiredDays)
    }

    /// 样本**达标但有失联**（`T > 30` ⇒ `H` 封顶 30）⇒ `J` 仍写入载体。
    ///
    /// `T ≤ 30` 时 `H = T` ⇒ 「有失联」必然「样本不足」⇒ 必然开轮 ⇒ `J` 被清零；
    /// 只有 `T > 30`（`H` 封顶）这一条路，`J > 0` 与「达标」才能同时成立。
    func testLostCountIsWrittenWhenSampleStillMeetsThreshold() {
        let uv = Source.uvCache
        let members = (0..<31).map { candidate("/cache/uv/\($0)", TimeInterval(100 + $0)) }
        // 30 条还在，1 条失联
        let current = Array(members.prefix(30))

        let outcome = ObservationWriteback.apply(
            input: ObservationWriteback.Input(
                now: later,
                succeeded: true,
                mode: .full,
                scannedSources: [uv],
                candidates: [uv: current],
                probe: probe(["/cache/uv": .exists])
            ),
            header: headerWithSnapshot(countedDays: ObservationProgress.requiredDays, T: 31),
            payloads: [uv: SourcePayload(snapshotMembers: members)]
        )

        let e = entry(outcome.header, uv)
        XCTAssertEqual(e?.K, 30)
        XCTAssertEqual(e?.J, 1)
        XCTAssertEqual(e?.T, 31)
        XCTAssertEqual((e?.K ?? 0) + (e?.J ?? 0), e?.T)
        // `K = H = min(30, 31) = 30` ⇒ 达标 ⇒ 不开轮 ⇒ `J` 留在载体上
        XCTAssertEqual(outcome.header.round, 1)
        XCTAssertEqual(e?.J, 1)
    }

    func testSettlementHappensOnlyOnce() {
        let uv = Source.uvCache
        let kept = candidate("/cache/uv/a", 100)
        let kept2 = candidate("/cache/uv/b", 200)
        let input = ObservationWriteback.Input(
            now: later,
            succeeded: true,
            mode: .full,
            scannedSources: [uv],
            candidates: [uv: [kept, kept2]],
            probe: probe(["/cache/uv": .exists])
        )
        let header = headerWithSnapshot(countedDays: ObservationProgress.requiredDays)
        let payloads = [uv: SourcePayload(snapshotMembers: [kept, kept2])]

        let first = ObservationWriteback.apply(input: input, header: header, payloads: payloads)
        let second = ObservationWriteback.apply(
            input: input, header: first.header, payloads: first.payloads
        )

        XCTAssertEqual(entry(second.header, uv)?.K, 2)
        XCTAssertEqual(entry(second.header, uv)?.J, 0)
        XCTAssertEqual(second.settledSources, [])
    }

    func testSnapshotAndSettlementAreMutuallyExclusive() {
        let uv = Source.uvCache
        let ids = [candidate("/cache/uv/a", 100), candidate("/cache/uv/b", 200)]

        // 观察期已满，但本轮还没取过快照 ⇒ 同一次扫描里两者同时成立
        let outcome = ObservationWriteback.apply(
            input: ObservationWriteback.Input(
                now: later,
                succeeded: true,
                mode: .full,
                scannedSources: [uv],
                candidates: [uv: ids]
            ),
            header: StateHeader(countedDays: ObservationProgress.requiredDays),
            payloads: [:]
        )

        XCTAssertEqual(entry(outcome.header, uv)?.snapshotTaken, true)
        XCTAssertEqual(entry(outcome.header, uv)?.T, 2)
        // 快照优先 ⇒ 本次不结算
        XCTAssertNil(entry(outcome.header, uv)?.K)
        XCTAssertNil(entry(outcome.header, uv)?.J)
        XCTAssertEqual(outcome.settledSources, [])
    }

    func testSettlementDoesNotRunWhenObservationIsNotFull() {
        let uv = Source.uvCache
        let kept = candidate("/cache/uv/a", 100)
        let deleted = candidate("/cache/uv/b", 200)

        let outcome = ObservationWriteback.apply(
            input: ObservationWriteback.Input(
                now: later,
                succeeded: true,
                mode: .full,
                scannedSources: [uv],
                candidates: [uv: [kept]],
                probe: probe(["/cache/uv": .exists])
            ),
            header: headerWithSnapshot(countedDays: ObservationProgress.requiredDays - 1),
            payloads: [uv: SourcePayload(snapshotMembers: [kept, deleted])]
        )

        XCTAssertNil(entry(outcome.header, uv)?.K)
        XCTAssertNil(entry(outcome.header, uv)?.J)
        XCTAssertEqual(outcome.settledSources, [])
    }

    func testSettlementDoesNotRunForSourceNotScannedThisRound() {
        let uv = Source.uvCache
        let kept = candidate("/cache/uv/a", 100)
        let deleted = candidate("/cache/uv/b", 200)

        // 本轮没扫这个来源 ⇒ 不能用空 `current` 把快照全判失联
        let outcome = ObservationWriteback.apply(
            input: ObservationWriteback.Input(
                now: later,
                succeeded: true,
                mode: .full,
                scannedSources: [],
                candidates: [:],
                probe: probe(["/cache/uv": .exists])
            ),
            header: headerWithSnapshot(countedDays: ObservationProgress.requiredDays),
            payloads: [uv: SourcePayload(snapshotMembers: [kept, deleted])]
        )

        XCTAssertNil(entry(outcome.header, uv)?.K)
        XCTAssertEqual(outcome.settledSources, [])
    }

    /// **增量扫描不得结算** —— 增量只查已知候选，本轮 `current` 是**子集**。
    ///
    /// 拿子集去归因快照 ⇒ 没被扫到的那几条会被判成「失联」
    /// ⇒ `J` 虚高、`K` 虚低 ⇒ 结算凭证是一份**假报告**。
    func testIncrementalScanDoesNotSettle() {
        let uv = Source.uvCache
        let kept = candidate("/cache/uv/a", 100)
        let deleted = candidate("/cache/uv/b", 200)

        let outcome = ObservationWriteback.apply(
            input: ObservationWriteback.Input(
                now: later,
                succeeded: true,
                mode: .incremental,
                scannedSources: [uv],
                candidates: [uv: [kept]],
                probe: probe(["/cache/uv": .exists])
            ),
            header: headerWithSnapshot(countedDays: ObservationProgress.requiredDays),
            payloads: [uv: SourcePayload(snapshotMembers: [kept, deleted])]
        )

        XCTAssertNil(entry(outcome.header, uv)?.K)
        XCTAssertNil(entry(outcome.header, uv)?.J)
        XCTAssertEqual(outcome.settledSources, [])
        XCTAssertNil(outcome.header.settlement.producedAt)
    }

    // MARK: - ③ 计数日推进

    func testSuccessfulScanAdvancesCountedDay() {
        let outcome = ObservationWriteback.apply(
            input: ObservationWriteback.Input(now: later, succeeded: true, mode: .full),
            header: StateHeader(),
            payloads: [:]
        )

        XCTAssertEqual(outcome.header.countedDays, 1)
        XCTAssertNotNil(outcome.header.roundStartAnchor)
        XCTAssertEqual(outcome.header.lastScanAt, later)
    }

    func testAbortedScanDoesNotAdvanceCountedDay() {
        let outcome = ObservationWriteback.apply(
            input: ObservationWriteback.Input(now: later, succeeded: false, mode: .full),
            header: StateHeader(roundStartAnchor: later, countedDays: 3),
            payloads: [:]
        )

        XCTAssertEqual(outcome.header.countedDays, 3)
        XCTAssertEqual(outcome.header.roundStartAnchor, later)
    }

    func testCountedDayNeverExceedsRequiredDays() {
        var header = StateHeader()
        header.countedDays = ObservationProgress.requiredDays
        header.roundStartAnchor = later

        let outcome = ObservationWriteback.apply(
            input: ObservationWriteback.Input(now: later2, succeeded: true, mode: .full),
            header: header,
            payloads: [:]
        )

        XCTAssertEqual(outcome.header.countedDays, ObservationProgress.requiredDays)
    }

    // MARK: - ④ `a` 写入路径

    func testMisjudgmentIsCountedOncePerCandidate() {
        let uv = Source.uvCache
        let a = candidate("/cache/uv/a", 100)
        let b = candidate("/cache/uv/b", 200)

        // 第一轮：两条都判「无活引用」⇒ 置位 `F`，但不产生误判
        let first = ObservationWriteback.apply(
            input: ObservationWriteback.Input(
                now: later,
                succeeded: true,
                mode: .full,
                scannedSources: [uv],
                candidates: [uv: [a, b]],
                judgments: [uv: [a: .noLiveReference, b: .noLiveReference]]
            ),
            header: StateHeader(),
            payloads: [:]
        )
        XCTAssertEqual(entry(first.header, uv)?.a, 0)
        XCTAssertEqual(entry(first.header, uv)?.b, 2)

        // 第二轮：`a` 变成「有活引用」⇒ 它此前被判干净 ⇒ 记 1 次误判
        let second = ObservationWriteback.apply(
            input: ObservationWriteback.Input(
                now: later2,
                succeeded: true,
                mode: .full,
                scannedSources: [uv],
                candidates: [uv: [a, b]],
                judgments: [uv: [a: .hasLiveReference, b: .noLiveReference]]
            ),
            header: first.header,
            payloads: first.payloads
        )
        XCTAssertEqual(entry(second.header, uv)?.a, 1)

        // 第三轮：同一条再判「有活引用」⇒ `C_done` 去重，不再计
        let third = ObservationWriteback.apply(
            input: ObservationWriteback.Input(
                now: later2,
                succeeded: true,
                mode: .full,
                scannedSources: [uv],
                candidates: [uv: [a, b]],
                judgments: [uv: [a: .hasLiveReference, b: .noLiveReference]]
            ),
            header: second.header,
            payloads: second.payloads
        )
        XCTAssertEqual(entry(third.header, uv)?.a, 1)
    }

    func testUndeterminedVerdictDoesNotCountAsMisjudgment() {
        let uv = Source.uvCache
        let a = candidate("/cache/uv/a", 100)

        let first = ObservationWriteback.apply(
            input: ObservationWriteback.Input(
                now: later,
                succeeded: true,
                mode: .full,
                scannedSources: [uv],
                candidates: [uv: [a]],
                judgments: [uv: [a: .noLiveReference]]
            ),
            header: StateHeader(),
            payloads: [:]
        )

        // 不可判定 ⇒ 不置 `F`、不计误判，但**计入 `b`**
        let second = ObservationWriteback.apply(
            input: ObservationWriteback.Input(
                now: later2,
                succeeded: true,
                mode: .full,
                scannedSources: [uv],
                candidates: [uv: [a]],
                judgments: [uv: [a: .undetermined]]
            ),
            header: first.header,
            payloads: first.payloads
        )
        XCTAssertEqual(entry(second.header, uv)?.a, 0)
        XCTAssertEqual(entry(second.header, uv)?.b, 2)
    }

    func testDegradedScanDoesNotOverwriteMisjudgmentOrCheckCount() {
        let uv = Source.uvCache
        let a = candidate("/cache/uv/a", 100)

        let first = ObservationWriteback.apply(
            input: ObservationWriteback.Input(
                now: later,
                succeeded: true,
                mode: .full,
                scannedSources: [uv],
                candidates: [uv: [a]],
                judgments: [uv: [a: .noLiveReference]]
            ),
            header: StateHeader(),
            payloads: [:]
        )
        XCTAssertEqual(entry(first.header, uv)?.b, 1)

        // 降级（同 uid 进程枚举失败）⇒ `a` / `b` / 判定时刻**一律不动**
        let second = ObservationWriteback.apply(
            input: ObservationWriteback.Input(
                now: later2,
                succeeded: true,
                mode: .full,
                degraded: true,
                scannedSources: [uv],
                candidates: [uv: [a]],
                judgments: [uv: [a: .hasLiveReference]]
            ),
            header: first.header,
            payloads: first.payloads
        )
        XCTAssertEqual(entry(second.header, uv)?.a, 0)
        XCTAssertEqual(entry(second.header, uv)?.b, 1)
        XCTAssertEqual(entry(second.header, uv)?.lastJudgmentAt, later)
    }

    func testAbortedScanStillAccumulatesMisjudgmentAndCheckCount() {
        let uv = Source.uvCache
        let a = candidate("/cache/uv/a", 100)

        let first = ObservationWriteback.apply(
            input: ObservationWriteback.Input(
                now: later,
                succeeded: true,
                mode: .full,
                scannedSources: [uv],
                candidates: [uv: [a]],
                judgments: [uv: [a: .noLiveReference]]
            ),
            header: StateHeader(),
            payloads: [:]
        )

        let second = ObservationWriteback.apply(
            input: ObservationWriteback.Input(
                now: later2,
                succeeded: false,
                mode: .full,
                scannedSources: [uv],
                candidates: [uv: [a]],
                judgments: [uv: [a: .hasLiveReference]]
            ),
            header: first.header,
            payloads: first.payloads
        )
        // 中止扫描不推进计数日、不取快照、不结算，**但仍累计 `a` / `b`**
        XCTAssertEqual(entry(second.header, uv)?.a, 1)
        XCTAssertEqual(entry(second.header, uv)?.b, 2)
    }

    // MARK: - ⑤ `b` 按来源累计

    func testCheckCountAccumulatesPerSource() {
        let uv = Source.uvCache
        let npm = Source.npmNpx
        let uvIds = [candidate("/cache/uv/a", 100), candidate("/cache/uv/b", 200)]
        let npmIds = [
            candidate("/cache/npm/a", 100), candidate("/cache/npm/b", 200), candidate("/cache/npm/c", 300)
        ]

        func input(now: Date) -> ObservationWriteback.Input {
            ObservationWriteback.Input(
                now: now,
                succeeded: true,
                mode: .full,
                scannedSources: [uv, npm],
                candidates: [uv: uvIds, npm: npmIds]
            )
        }

        let first = ObservationWriteback.apply(input: input(now: later), header: StateHeader(), payloads: [:])
        XCTAssertEqual(entry(first.header, uv)?.b, 2)
        XCTAssertEqual(entry(first.header, npm)?.b, 3)

        let second = ObservationWriteback.apply(
            input: input(now: later2), header: first.header, payloads: first.payloads
        )
        XCTAssertEqual(entry(second.header, uv)?.b, 4)
        XCTAssertEqual(entry(second.header, npm)?.b, 6)
    }

    // MARK: - ⑥ 载体自洽（位图长度恒等式）

    func testPayloadBitmapLengthIsDerivedFromSlotDomain() {
        let uv = Source.uvCache
        let a = candidate("/cache/uv/a", 100)

        let outcome = ObservationWriteback.apply(
            input: ObservationWriteback.Input(
                now: later,
                succeeded: true,
                mode: .full,
                scannedSources: [uv],
                candidates: [uv: [a]],
                judgments: [uv: [a: .noLiveReference]]
            ),
            header: StateHeader(),
            payloads: [:]
        )

        let slotCount = entry(outcome.header, uv)?.slotCount ?? -1
        XCTAssertEqual(slotCount, 1)
        XCTAssertEqual(outcome.payloads[uv]?.bitmap.count, (slotCount + 7) / 8)
    }

    /// 载荷里的 `F` 位图**置位数**必须等于「被判阴性」的候选数 —— 取证字段
    /// `fSetBits` 由此而来（写死 0 的那处缺陷就是被这条抓住的）。
    ///
    /// 样本覆盖三种判定：**判阴性**（置位）/ **判被持有**（不置位）/
    /// **无法判定**（不置位 —— 不变量③：不知道不等于干净）。
    func testPayloadSetBitCountEqualsNegativeVerdictCount() {
        let uv = Source.uvCache
        let a = candidate("/cache/uv/a", 100)
        let b = candidate("/cache/uv/b", 200)
        let c = candidate("/cache/uv/c", 300)
        let d = candidate("/cache/uv/d", 400)

        let outcome = ObservationWriteback.apply(
            input: ObservationWriteback.Input(
                now: later,
                succeeded: true,
                mode: .full,
                scannedSources: [uv],
                candidates: [uv: [a, b, c, d]],
                judgments: [uv: [
                    a: .noLiveReference,
                    b: .noLiveReference,
                    c: .hasLiveReference,
                    d: .undetermined,
                ]]
            ),
            header: StateHeader(),
            payloads: [:]
        )

        XCTAssertEqual(
            outcome.payloads[uv]?.fSetBitCount, 2,
            "只有判阴性的候选置位（被持有 / 无法判定都不置）"
        )
    }

    func testEverySourceHasAPayloadEvenWhenNotScanned() {
        let uv = Source.uvCache

        let outcome = ObservationWriteback.apply(
            input: ObservationWriteback.Input(
                now: later,
                succeeded: true,
                mode: .full,
                scannedSources: [uv]
            ),
            header: StateHeader(),
            payloads: [:]
        )

        // 段表必须每来源四段 ⇒ 载荷必须每来源齐全
        XCTAssertEqual(outcome.payloads.count, Source.allCases.count)
        for source in Source.allCases {
            let slotCount = entry(outcome.header, source)?.slotCount ?? -1
            XCTAssertEqual(
                outcome.payloads[source]?.bitmap.count, (slotCount + 7) / 8,
                "来源 \(source.displayName) 的位图长度与位槽域不符"
            )
        }
    }

    // MARK: - ⑦ 落盘往返（同一��次 `save()` 里写全 K / J / 凭证）

    func testSettlementFieldsSurviveOneSaveRoundTrip() throws {
        let uv = Source.uvCache
        let kept = candidate("/cache/uv/a", 100)
        let kept2 = candidate("/cache/uv/b", 200)

        let outcome = ObservationWriteback.apply(
            input: ObservationWriteback.Input(
                now: later,
                succeeded: true,
                mode: .full,
                scannedSources: [uv],
                candidates: [uv: [kept, kept2]],
                probe: probe(["/cache/uv": .exists])
            ),
            header: headerWithSnapshot(countedDays: ObservationProgress.requiredDays),
            payloads: [uv: SourcePayload(snapshotMembers: [kept, kept2])]
        )

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("residue-writeback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let stateFile = StateFile(directory: dir)
        try stateFile.save(header: outcome.header, payloads: outcome.payloads)

        let loaded = stateFile.load()
        XCTAssertNil(loaded.error)
        let contents = try XCTUnwrap(loaded.contents)

        let e = contents.header.sources.first { $0.source == uv }
        XCTAssertEqual(e?.K, 2)
        XCTAssertEqual(e?.J, 0)
        XCTAssertEqual(e?.T, 2)
        XCTAssertNotNil(e?.settlementDate)
        XCTAssertEqual(e?.unattributableCount, 0)
        XCTAssertNotNil(contents.header.settlement.producedAt)
        XCTAssertNotNil(contents.header.settlement.reportId)
        XCTAssertEqual(contents.payloads[uv]?.snapshotMembers.count, 2)
        // 每来源四段 ⇒ 12 段
        XCTAssertEqual(contents.segments.count, Source.allCases.count * 4)
        // 位图长度恒等式在解码侧也成立（否则解码直接报段校验失败）
        for source in Source.allCases {
            let slotCount = contents.header.sources.first { $0.source == source }?.slotCount ?? -1
            XCTAssertEqual(contents.payloads[source]?.bitmap.count, (slotCount + 7) / 8)
        }
    }

    // MARK: - ⑧ 未达标自动开下一轮（CR-033）

    /// 步骤 1：本轮结算未达标（`K < H`）⇒ 自动开启下一轮。
    ///
    /// 契约：PRD v5.6 :68「若该轮未达标（存在任一来源 `K < H`），自动开启下一轮：
    /// 重新取快照、计时器归零、**保留 L0 误判计数 `a`**」。
    func testInsufficientSampleSettlementOpensNextRound() {
        let uv = Source.uvCache
        let kept = candidate("/cache/uv/a", 100)
        let deleted = candidate("/cache/uv/b", 200)

        let outcome = ObservationWriteback.apply(
            input: ObservationWriteback.Input(
                now: later,
                succeeded: true,
                mode: .full,
                scannedSources: [uv],
                candidates: [uv: [kept]],
                probe: probe(["/cache/uv": .exists])
            ),
            header: headerWithSnapshot(countedDays: ObservationProgress.requiredDays, a: 1),
            payloads: [uv: SourcePayload(snapshotMembers: [kept, deleted])]
        )

        // 先证明「结算确实发生」，否则后面的开轮断言没有意义
        XCTAssertEqual(outcome.settledSources, [uv], "本轮应产出结算")
        XCTAssertEqual(outcome.header.round, 2, "未达标自动开下一轮 ⇒ 轮次 +1")
        XCTAssertEqual(outcome.header.countedDays, 0, "开轮 ⇒ 本轮计数日归零")
        XCTAssertNil(outcome.header.roundStartAnchor, "开轮 ⇒ 起算点清空")
        XCTAssertEqual(entry(outcome.header, uv)?.snapshotTaken, false, "开轮时**不**取快照")
        XCTAssertNil(entry(outcome.header, uv)?.T, "开轮 ⇒ `T` 待重取")
        XCTAssertNil(entry(outcome.header, uv)?.H, "开轮 ⇒ `H` 随新 `T` 重算")
        XCTAssertNil(entry(outcome.header, uv)?.K, "开轮 ⇒ `K` 清零")
        XCTAssertNil(entry(outcome.header, uv)?.J, "开轮 ⇒ `J` 清零")
        XCTAssertEqual(outcome.payloads[uv]?.snapshotMembers.count, 0, "开轮 ⇒ 快照成员清空")
        XCTAssertEqual(entry(outcome.header, uv)?.a, 1, "开轮**不清零** `a`")
    }

    /// 步骤 2：仅 `a ≠ 0`（而 `K ≥ H`）⇒ **不**开下一轮。
    ///
    /// 契约：PRD v5.6 :68〔CR-010 · 质量 G-3〕触发条件只认「存在任一来源 `K < H`」，
    /// `a ≠ 0` **不单独触发开轮**。本步是防回归护栏。
    func testL0MisjudgmentAloneDoesNotOpenNextRound() {
        let uv = Source.uvCache
        let kept1 = candidate("/cache/uv/a", 100)
        let kept2 = candidate("/cache/uv/b", 200)

        let outcome = ObservationWriteback.apply(
            input: ObservationWriteback.Input(
                now: later,
                succeeded: true,
                mode: .full,
                scannedSources: [uv],
                candidates: [uv: [kept1, kept2]],
                probe: probe(["/cache/uv": .exists])
            ),
            header: headerWithSnapshot(countedDays: ObservationProgress.requiredDays, a: 1),
            payloads: [uv: SourcePayload(snapshotMembers: [kept1, kept2])]
        )

        // 先证明「结算确实发生且样本达标」，否则「没开轮」可能只是没结算
        XCTAssertEqual(outcome.settledSources, [uv], "本轮应产出结算")
        XCTAssertEqual(entry(outcome.header, uv)?.K, 2)
        XCTAssertEqual(entry(outcome.header, uv)?.H, 2)
        XCTAssertEqual(outcome.header.round, 1, "`a ≠ 0` **不单独**触发开轮")
        XCTAssertEqual(
            outcome.header.countedDays, ObservationProgress.requiredDays,
            "不开轮 ⇒ 计数日不动"
        )
        XCTAssertEqual(entry(outcome.header, uv)?.a, 1, "不开轮 ⇒ `a` 保留")
    }

    /// 步骤 3：开轮当天的结算扫描**不**计入新轮的第 1 计数日。
    ///
    /// 契约：PRD v5.6 :62〔CR-010 · R4〕新一轮的「本轮首次成功扫描」=
    /// 上一轮结束扫描完成后的**下一次**成功扫描 ⇒ 第 2 轮同样须走满 14 个计数日。
    func testSettlementScanDoesNotCountAsFirstDayOfNextRound() {
        let uv = Source.uvCache
        let kept = candidate("/cache/uv/a", 100)
        let deleted = candidate("/cache/uv/b", 200)

        let opening = ObservationWriteback.apply(
            input: ObservationWriteback.Input(
                now: later,
                succeeded: true,
                mode: .full,
                scannedSources: [uv],
                candidates: [uv: [kept]],
                probe: probe(["/cache/uv": .exists])
            ),
            header: headerWithSnapshot(countedDays: ObservationProgress.requiredDays),
            payloads: [uv: SourcePayload(snapshotMembers: [kept, deleted])]
        )

        XCTAssertEqual(opening.header.round, 2)
        XCTAssertEqual(opening.header.countedDays, 0, "开轮当天的结算扫描不计入新轮计数日")

        let next = ObservationWriteback.apply(
            input: ObservationWriteback.Input(
                now: later2,
                succeeded: true,
                mode: .full,
                scannedSources: [uv],
                candidates: [uv: [kept]],
                probe: probe(["/cache/uv": .exists])
            ),
            header: opening.header,
            payloads: opening.payloads
        )

        XCTAssertEqual(next.header.round, 2, "轮次不变")
        XCTAssertEqual(next.header.countedDays, 1, "新一轮的第 1 计数日 = 下一次成功扫描")
    }

    /// 未达标结算 ⇒ 上一轮的结算值落进 `previousRound` 单槽。
    ///
    /// 这个槽是第 ⑤ 页「上一轮」行四要素（轮次 / 样本 / 总量 / 冻结于）的**唯一数据源**
    /// （DAC-50 修订）—— 槽里没有 ⇒ 界面拼不出那行。
    func testInsufficientSettlementRecordsPreviousRound() throws {
        let uv = Source.uvCache
        let kept = candidate("/cache/uv/a", 100)
        let deleted = candidate("/cache/uv/b", 200)

        let outcome = ObservationWriteback.apply(
            input: ObservationWriteback.Input(
                now: later,
                succeeded: true,
                mode: .full,
                scannedSources: [uv],
                candidates: [uv: [kept]],
                probe: probe(["/cache/uv": .exists])
            ),
            header: headerWithSnapshot(countedDays: ObservationProgress.requiredDays),
            payloads: [uv: SourcePayload(snapshotMembers: [kept, deleted])]
        )

        let previous = try XCTUnwrap(outcome.header.previousRound, "未达标结算必须留下上一轮记录")
        XCTAssertEqual(previous.round, 1, "记录的是**被结算的那一轮**（开轮前的轮次）")
        XCTAssertEqual(previous.source, uv)
        XCTAssertEqual(previous.sample, 1)
        XCTAssertEqual(previous.total, 2)
        XCTAssertEqual(previous.settledAt, later, "冻结时刻 = 该轮结算时刻")
    }
}
