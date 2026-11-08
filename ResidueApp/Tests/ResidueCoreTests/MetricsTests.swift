import XCTest
@testable import ResidueCore

/// 指标定义层的单测。
///
/// **测试用例直接取自三方评审单给出的反例**——这样测试失败即等价于
/// 契约被违反，而不是「实现和实现不一致」。
final class MetricsTests: XCTestCase {

    // MARK: - M2 门槛

    func testThresholdIsMinOf30AndTotal() {
        XCTAssertEqual(Threshold.h(forTotal: 30), 30)
        XCTAssertEqual(Threshold.h(forTotal: 40), 30)
        XCTAssertEqual(Threshold.h(forTotal: 5), 5)
    }

    func testThresholdNeverZeroForInDomainSource() {
        // 入域来源 T ≥ 1 → H ≥ 1（契约 M2）
        XCTAssertGreaterThanOrEqual(Threshold.h(forTotal: 1), 1)
    }

    // MARK: - M3 样本 / 失联

    func testSnapshotIdentityHolds() {
        let m = SnapshotMetrics(
            total: 30, attributable: 28,
            snapshotDate: Date(timeIntervalSince1970: 0),
            settlementDate: Date(timeIntervalSince1970: 14 * 86400)
        )
        XCTAssertEqual(m.lost, 2)
        XCTAssertTrue(m.identityHolds)
        XCTAssertEqual(m.attributable + m.lost, m.total)
    }

    // MARK: - M1 观察期进度

    func testCountedDaysCappedAt14() {
        // 契约 M1 · 质量 Q16：报告产出失败而继续等待时，界面永不显示 15/14
        var p = ObservationProgress(round: 1, startAnchor: Date(), countedDays: 16)
        XCTAssertEqual(p.displayCountedDays, 14)
        XCTAssertTrue(p.isDayQuotaReached)
        XCTAssertNil(p.remainingDays) // 该格显示 `—` 而非 `0`
    }

    func testRemainingDaysIsFourteenMinusCounted() {
        let p = ObservationProgress(round: 1, startAnchor: Date(), countedDays: 9)
        XCTAssertEqual(p.remainingDays, 5)
    }

    func testUnmetTextUnifiedStyles() {
        // 契约 M1：唯一样式串两串
        XCTAssertEqual(
            UnmetGlobalItem.text(round: 1, countedDays: 9),
            "第 1 轮 · 观察期 9/14 天"
        )
        XCTAssertEqual(
            UnmetGlobalItem.text(round: 2, countedDays: 14),
            "第 2 轮 · 观察期未满 · 待结算扫描（无需操作）"
        )
    }

    // MARK: - M4 误判判据（评审方反例）

    private func id(_ p: String, _ t: TimeInterval = 0) -> CandidateID {
        CandidateID(path: p, birthtime: Date(timeIntervalSince1970: t))
    }

    /// 评审方用例：自始被持有（首检即阳性）→ 不算误判。
    func testSelfHeldFromStartIsNotAMiss() {
        var st = SourceL0State()
        let x = id("/x")
        // 扫描 1、2：X 一直被持有（首检即阳性 → 从未判阴性）
        for i in 0..<2 {
            MissCounter.apply(state: &st, judgments: [x: .hasLiveReference], now: Date())
        }
        XCTAssertEqual(st.missCount, 0, "自始被持有者不是 L0 误判")
    }

    /// 评审方用例：真误判（首检阴性 → 复检被持有）→ 计 1。
    func testRealMissIsCountedOnce() {
        var st = SourceL0State()
        let x = id("/x")
        MissCounter.apply(state: &st, judgments: [x: .noLiveReference], now: Date())
        MissCounter.apply(state: &st, judgments: [x: .hasLiveReference], now: Date())
        XCTAssertEqual(st.missCount, 1)
    }

    /// 评审方用例：持续被持有 → 只计一次。
    func testContinuousHoldingCountsOnce() {
        var st = SourceL0State()
        let x = id("/x")
        MissCounter.apply(state: &st, judgments: [x: .noLiveReference], now: Date())
        for _ in 0..<5 { MissCounter.apply(state: &st, judgments: [x: .hasLiveReference], now: Date()) }
        XCTAssertEqual(st.missCount, 1, "持续被持有不重复计")
    }

    /// 评审方用例：间歇持有 → 同一候选只计一次。
    func testIntermittentHoldingCountsOnce() {
        var st = SourceL0State()
        let x = id("/x")
        MissCounter.apply(state: &st, judgments: [x: .noLiveReference], now: Date())
        MissCounter.apply(state: &st, judgments: [x: .hasLiveReference], now: Date())
        MissCounter.apply(state: &st, judgments: [x: .noLiveReference], now: Date())
        MissCounter.apply(state: &st, judgments: [x: .hasLiveReference], now: Date())
        XCTAssertEqual(st.missCount, 1, "间歇持有不重复计（`− C_done` 保证）")
    }

    /// 评审方用例：两个不同候选各误判一次 → 2。
    func testTwoCandidatesEachMissOnce() {
        var st = SourceL0State()
        let x = id("/x"), y = id("/y")
        MissCounter.apply(state: &st, judgments: [x: .noLiveReference, y: .noLiveReference], now: Date())
        MissCounter.apply(state: &st, judgments: [x: .hasLiveReference, y: .noLiveReference], now: Date())
        MissCounter.apply(state: &st, judgments: [x: .noLiveReference, y: .hasLiveReference], now: Date())
        XCTAssertEqual(st.missCount, 2)
    }

    /// 评审方用例：手删 X → 同路径重建 X′（birthtime 变）→ X′ 自始被持有 → 不计误判。
    ///
    /// **这是 Q29 的核心反例**：X′ 是新身份 → 不继承 X 的 `F` 位 → `a` 恒为 0。
    func testRebuiltCandidateDoesNotInheritNegativeFlag() {
        var st = SourceL0State()
        let x = id("/p", 100)
        let xPrime = id("/p", 200)   // 同路径、birthtime 不同 → 新身份
        // 扫描 1：X 判阴性 → F 置位
        MissCounter.apply(state: &st, judgments: [x: .noLiveReference], now: Date())
        // 扫描 2：X 被手删、X′ 在同路径重建并自始被持有
        MissCounter.apply(state: &st, judgments: [xPrime: .hasLiveReference], now: Date())
        XCTAssertEqual(st.missCount, 0, "新身份不继承旧候选的 F 位")
        XCTAssertTrue(st.hasBeenJudgedClean(x), "旧候选应仍被记为曾判干净")
        XCTAssertFalse(st.hasBeenJudgedClean(xPrime), "新身份不继承旧的「曾判干净」标记")
    }

    /// M5：`b` = L0 判定次数。
    func testCheckCountIsNumberOfJudgments() {
        XCTAssertEqual(CheckCounter.count(from: [:]), 0)
        XCTAssertEqual(
            CheckCounter.count(from: [id("/a"): .noLiveReference, id("/b"): .hasLiveReference]),
            2
        )
    }

    // MARK: - 位槽分配（Q29 / Q32）

    func testSlotIsStableForSameIdentity() {
        var table = SlotTable()
        let x = id("/p", 100)
        let s1 = table.slot(for: x)
        let s2 = table.slot(for: x)
        XCTAssertEqual(s1, s2, "同一身份键恒得同一位槽")
    }

    func testRebuiltCandidateGetsDifferentSlot() {
        // Q29 反例：同路径重建 → 新身份 → 必须拿新位槽，否则继承旧 `F` 位
        var table = SlotTable()
        let old = id("/p", 100)
        let rebuilt = id("/p", 200)
        let sOld = table.slot(for: old)
        let sNew = table.slot(for: rebuilt)
        XCTAssertNotEqual(sOld, sNew, "同路径重建的新候选必须分到新位槽")
    }

    func testSlotIsNotRecycledAfterDeletion() {
        // Q32：位槽不回收 → 反复重建不会复用旧槽
        var table = SlotTable()
        var slots: [Int] = []
        for i in 0..<50 {
            // 模拟同路径反复重建（birthtime 每次不同）
            let c = id("/p", TimeInterval(i))
            slots.append(table.slot(for: c))
        }
        XCTAssertEqual(Set(slots).count, slots.count, "50 次重建应得 50 个互不相同的位槽")
    }

    func testSlotCountHasNoUpperBound() {
        // Q32：位槽号域无上限 → 大量候选都能分到槽位（不存在「无空槽可用」）
        var table = SlotTable()
        for i in 0..<2000 {
            _ = table.slot(for: id("/c\(i)", TimeInterval(i)))
        }
        XCTAssertEqual(table.count, 2000)
        XCTAssertEqual(Set(table.assignments.values).count, 2000, "2000 个候选应得 2000 个互异位槽")
    }

    func testSlotHashDependsOnBirthtime() {
        // 身份键 = 路径 + birthtime → 两者任一不同都应改变哈希
        XCTAssertNotEqual(
            SlotTable.stableHash(id("/p", 100)),
            SlotTable.stableHash(id("/p", 200))
        )
        XCTAssertNotEqual(
            SlotTable.stableHash(id("/p", 100)),
            SlotTable.stableHash(id("/q", 100))
        )
    }

    // MARK: - 判定域

    func testDecisionDomainExcludesPipx() {
        let members = DecisionDomain.members(snapshotSources: [.uvCache, .npmNpx, .pipxRun])
        XCTAssertEqual(members, [.uvCache, .npmNpx])
    }

    // MARK: - AC-08 组 A / 组 B

    private func input(
        _ s: Source,
        k: Int? = nil, t: Int? = nil,
        a: Int? = nil, b: Int? = nil,
        undetermined: Bool = false
    ) -> SourceGateInput {
        SourceGateInput(source: s, attributable: k, total: t, missCount: a, checkCount: b, undetermined: undetermined)
    }

    func testUnmetDuringObservationIsGlobalOnly() {
        // 用例①：期内 → 集合只含 {观察期未满}（来源项不判定）
        let items = GateEvaluator.unmetItems(
            progress: ObservationProgress(round: 1, startAnchor: Date(), countedDays: 9),
            settlementProduced: false,
            sources: [input(.uvCache, a: 0, b: 10)]
        )
        XCTAssertEqual(items.global, .observationUnfinished)
        XCTAssertTrue(items.bySource.isEmpty)
    }

    func testUnmetSampleInsufficient() {
        // 用例②：K = T−1 < H = T
        let items = GateEvaluator.unmetItems(
            progress: ObservationProgress(round: 1, startAnchor: Date(), countedDays: 14),
            settlementProduced: true,
            sources: [input(.uvCache, k: 4, t: 5, a: 0, b: 100)]
        )
        XCTAssertNil(items.global)
        XCTAssertEqual(items.bySource.count, 1)
        XCTAssertEqual(items.bySource[0].item, .insufficientSample)
    }

    func testUnmetL0Misjudged() {
        // 用例②′：K = T = H，a = 1
        let items = GateEvaluator.unmetItems(
            progress: ObservationProgress(round: 1, startAnchor: Date(), countedDays: 14),
            settlementProduced: true,
            sources: [input(.uvCache, k: 5, t: 5, a: 1, b: 100)]
        )
        XCTAssertEqual(items.bySource.count, 1)
        if case .l0Misjudged(let m, _, _) = items.bySource[0].item {
            XCTAssertEqual(m, 1)
        } else {
            XCTFail("应为 L0 误判项")
        }
    }

    func testUnmetFDAUndetermined() {
        // 用例②″：未取得 FDA 且不失联（K = T ≥ H）→ 只含「L0 未判定」一项
        let items = GateEvaluator.unmetItems(
            progress: ObservationProgress(round: 1, startAnchor: Date(), countedDays: 14),
            settlementProduced: true,
            sources: [input(.uvCache, k: 5, t: 5, undetermined: true)]
        )
        XCTAssertEqual(items.bySource.count, 1)
        XCTAssertEqual(
            items.bySource[0].item,
            .l0Misjudged(missCount: nil, checkCount: nil, undetermined: true)
        )
    }

    /// 用例①′：样本不足 + L0 误判 → **两项两行**（不合并）
    func testUnmetSampleAndL0TwoRows() {
        let items = GateEvaluator.unmetItems(
            progress: ObservationProgress(round: 1, startAnchor: Date(), countedDays: 14),
            settlementProduced: true,
            sources: [input(.uvCache, k: 4, t: 5, a: 1, b: 100)]
        )
        XCTAssertEqual(items.bySource.count, 2, "必须两项两行、不得合并")
        XCTAssertEqual(items.bySource[0].item, .insufficientSample)
        if case .l0Misjudged(let m, _, let und) = items.bySource[1].item {
            XCTAssertEqual(m, 1)
            XCTAssertFalse(und)
        } else {
            XCTFail("第二项应为 L0 误判")
        }
    }

    /// 用例②‴：未取得 FDA **且**手删 1 条（K = T−1 < H）→ 必须两项两行
    ///
    /// 这是第 18 轮抓到的实现 bug：原实现 `undetermined` 时提前 `continue`，
    /// 漏掉「样本不足」→ 只报 1 项。此项测试即为该 bug 的回归防护。
    func testUnmetSampleAndFDAUndeterminedTwoRows() {
        let items = GateEvaluator.unmetItems(
            progress: ObservationProgress(round: 1, startAnchor: Date(), countedDays: 14),
            settlementProduced: true,
            sources: [input(.uvCache, k: 4, t: 5, undetermined: true)]
        )
        XCTAssertEqual(items.bySource.count, 2, "样本不足 + L0 未判定 必须两项两行")
        XCTAssertEqual(items.bySource[0].item, .insufficientSample)
        XCTAssertEqual(
            items.bySource[1].item,
            .l0Misjudged(missCount: nil, checkCount: nil, undetermined: true)
        )
    }

    /// F 位图按位槽号索引：容量随位槽增长，字节数 = 位槽数 / 64 * 8
    func testNegativeBitmapIsSlotIndexedAndCompact() {
        var st = SourceL0State()
        // 10 万个候选，全部判阴性
        var judgments: [CandidateID: L0Verdict] = [:]
        for i in 0..<100_000 {
            judgments[CandidateID(path: "/c\(i)", birthtime: Date(timeIntervalSince1970: TimeInterval(i)))] = .noLiveReference
        }
        MissCounter.apply(state: &st, judgments: judgments, now: Date())

        XCTAssertEqual(st.missCount, 0, "全程无持有 → 无 L0 误判")
        XCTAssertEqual(st.slotTable.count, 100_000)
        // 位图容量应覆盖已分配的最大位槽号
        let maxSlot = st.slotTable.assignments.values.max() ?? 0
        XCTAssertGreaterThan(st.negativeSeen.capacityBits, maxSlot, "位图容量应覆盖最大位槽号")
        // 紧凑性：10 万位槽 → 最坏 ~1.6 MB；若按路径存 Set 会是数十 MB
        XCTAssertLessThan(st.negativeSeen.byteSize, 2_000_000, "位图必须是稠密位、不是路径集合")
    }

    func testQualifiedRequiresAllThree() {
        let p = ObservationProgress(round: 1, startAnchor: Date(), countedDays: 14)
        // 达标
        XCTAssertTrue(GateEvaluator.isQualified(
            progress: p, settlementProduced: true,
            sources: [input(.uvCache, k: 30, t: 30, a: 0, b: 128)]
        ))
        // a ≠ 0 → 不达标
        XCTAssertFalse(GateEvaluator.isQualified(
            progress: p, settlementProduced: true,
            sources: [input(.uvCache, k: 30, t: 30, a: 1, b: 128)]
        ))
        // K < H → 不达标
        XCTAssertFalse(GateEvaluator.isQualified(
            progress: p, settlementProduced: true,
            sources: [input(.uvCache, k: 29, t: 30, a: 0, b: 128)]
        ))
        // 未取得 FDA → 不达标
        XCTAssertFalse(GateEvaluator.isQualified(
            progress: p, settlementProduced: true,
            sources: [input(.uvCache, k: 30, t: 30, undetermined: true)]
        ))
    }

    func testEmptyDomainNeverQualified() {
        // 全称量词在空集上恒真 → 必须显式排除
        XCTAssertFalse(GateEvaluator.isQualified(
            progress: ObservationProgress(round: 1, startAnchor: Date(), countedDays: 14),
            settlementProduced: true,
            sources: [input(.pipxRun, k: 5, t: 5, a: 0, b: 0)]
        ))
    }

    // MARK: - M6 留存

    func testReclaimableBytesExemptsExecutionRecordsOnly() {
        // 目录 200 MB 全是 14 日内举证链（不豁免） → 可回收 200 MB → 触发
        let r = RetentionPolicy.reclaimableBytes(
            totalJSONLBytes: 200_000_000, exemptExecutionRecordBytes: 0
        )
        XCTAssertEqual(r, 200_000_000)
        XCTAssertTrue(RetentionPolicy.shouldReclaim(reclaimableBytes: r))
    }

    func testCapacityThresholdUsesDecimalMegabytes() {
        // 200 MB = 200 × 10⁶ 字节（不取 2²⁰ → 避免边界两结论）
        XCTAssertEqual(RetentionPolicy.capacityBytes, 200_000_000)
        XCTAssertFalse(RetentionPolicy.shouldReclaim(reclaimableBytes: 199_999_999))
        XCTAssertTrue(RetentionPolicy.shouldReclaim(reclaimableBytes: 200_000_000))
    }

    func testCapacityExemptionDoesNotApplyToTerm() {
        XCTAssertTrue(RetentionPolicy.isWithinCapacityExemption(recordAgeDays: 13))
        XCTAssertFalse(RetentionPolicy.isWithinCapacityExemption(recordAgeDays: 14))
        // 14 日豁免只作用于容量阈值，不作用于 90 天期限
        XCTAssertFalse(RetentionPolicy.isExpiredByTerm(recordAgeDays: 13))
        XCTAssertTrue(RetentionPolicy.isExpiredByTerm(recordAgeDays: 90))
    }
}
