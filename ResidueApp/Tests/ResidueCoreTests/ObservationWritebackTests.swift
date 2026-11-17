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
    private func headerWithSnapshot(countedDays: Int) -> StateHeader {
        var header = StateHeader(countedDays: countedDays)
        header.sources = [SourceHeaderEntry(source: .uvCache, snapshotTaken: true, T: 2, H: 2)]
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

    func testSettlementWritesKJAndCredentialsWhenObservationIsFull() {
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

        let e = entry(outcome.header, uv)
        XCTAssertEqual(e?.K, 1)
        XCTAssertEqual(e?.J, 1)
        XCTAssertEqual(e?.T, 2)
        // 恒等式：K + J == T（`J = T − K` 派生）
        XCTAssertEqual((e?.K ?? 0) + (e?.J ?? 0), e?.T)
        XCTAssertNotNil(e?.settlementDate)
        XCTAssertNotNil(e?.unattributableCount)
        XCTAssertEqual(e?.unattributableCount, 0)
        XCTAssertNotNil(outcome.header.settlement.producedAt)
        XCTAssertNotNil(outcome.header.settlement.reportId)
        XCTAssertEqual(outcome.settledSources, [uv])
    }

    func testSettlementHappensOnlyOnce() {
        let uv = Source.uvCache
        let kept = candidate("/cache/uv/a", 100)
        let deleted = candidate("/cache/uv/b", 200)
        let input = ObservationWriteback.Input(
            now: later,
            succeeded: true,
            mode: .full,
            scannedSources: [uv],
            candidates: [uv: [kept]],
            probe: probe(["/cache/uv": .exists])
        )
        let header = headerWithSnapshot(countedDays: ObservationProgress.requiredDays)
        let payloads = [uv: SourcePayload(snapshotMembers: [kept, deleted])]

        let first = ObservationWriteback.apply(input: input, header: header, payloads: payloads)
        let second = ObservationWriteback.apply(
            input: input, header: first.header, payloads: first.payloads
        )

        XCTAssertEqual(entry(second.header, uv)?.K, 1)
        XCTAssertEqual(entry(second.header, uv)?.J, 1)
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

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("residue-writeback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let stateFile = StateFile(directory: dir)
        try stateFile.save(header: outcome.header, payloads: outcome.payloads)

        let loaded = stateFile.load()
        XCTAssertNil(loaded.error)
        let contents = try XCTUnwrap(loaded.contents)

        let e = contents.header.sources.first { $0.source == uv }
        XCTAssertEqual(e?.K, 1)
        XCTAssertEqual(e?.J, 1)
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
}
