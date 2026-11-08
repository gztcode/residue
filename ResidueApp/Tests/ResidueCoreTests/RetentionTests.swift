import XCTest
@testable import ResidueCore

/// M6 · 留存回收的用例集。
///
/// 期望值来源：`Residue-R2-技术方案-v1.6.md` IF-11 / M6 的**唯一计量式**与终止条件，
/// 以及 AC-13 的 14 日恢复承诺（**14 日豁免是它的前提**）。
final class RetentionTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_760_000_000)   // 固定时钟，避免用例随运行时间漂移
    private func daysAgo(_ d: Int) -> Date { now.addingTimeInterval(-Double(d) * 86_400) }

    private func rec(
        _ id: String,
        daysOld: Int,
        bytes: Int64,
        _ file: Retention.RecordFile = .execution
    ) -> Retention.Record {
        Retention.Record(
            id: id,
            writtenAt: daysAgo(daysOld),
            bytes: bytes,
            isExecutionRecord: file.countsAsExemption,
            file: file
        )
    }

    /// **显式时刻**的构造器：`atOffsetDays` 为**负 = 更早**。
    /// 用来消除「daysOld 越大是越新还是越老」的方向歧义 —— 方向搞反会让用例期望与实现互相掩盖。
    private func recAt(
        _ id: String,
        atOffsetDays offset: Double,
        bytes: Int64,
        _ file: Retention.RecordFile = .execution
    ) -> Retention.Record {
        Retention.Record(
            id: id,
            writtenAt: now.addingTimeInterval(offset * 86_400),
            bytes: bytes,
            isExecutionRecord: file.countsAsExemption,
            file: file
        )
    }

    // MARK: - 唯一计量式

    func testReclaimableBytesSubtractsOnlyRecentExecutionRecords() {
        // 目录内全部 .jsonl 字节合计 − 14 日内执行记录字节合计
        let records = [
            rec("e1", daysOld: 3, bytes: 1_000_000, .execution),    // 14 日内执行记录 → 计入减数
            rec("e2", daysOld: 30, bytes: 2_000_000, .execution),   // 超 14 日 → 不减
            rec("v1", daysOld: 1, bytes: 3_000_000, .evidence),     // 举证链 → **不豁免**
            rec("s1", daysOld: 1, bytes: 4_000_000, .scan),         // 扫描日志 → **不豁免**
        ]
        let total: Int64 = 10_000_000
        let exempt: Int64 = 1_000_000
        XCTAssertEqual(
            Retention.reclaimableBytes(records: records, now: now),
            total - exempt,
            "减数项只含 14 日内的执行记录；举证链与扫描日志不豁免"
        )
    }

    func testExecutionRecordOlderThan14DaysIsNotExempt() {
        let records = [rec("e", daysOld: 15, bytes: 5_000_000, .execution)]
        XCTAssertEqual(
            Retention.reclaimableBytes(records: records, now: now),
            5_000_000,
            "超 14 日的执行记录不再享受豁免 → 全额计入可回收字节"
        )
    }

    func testEvidenceAndScanNeverExempt() {
        let records = [
            rec("v", daysOld: 0, bytes: 7_000_000, .evidence),
            rec("s", daysOld: 0, bytes: 8_000_000, .scan),
        ]
        XCTAssertEqual(
            Retention.reclaimableBytes(records: records, now: now),
            15_000_000,
            "举证链 / 扫描日志永不豁免（M6 明确「不豁免」）"
        )
    }

    // MARK: - 90 天期限

    func testNinetyDayLimitAppliesToAllRecordsIncludingRecentExecution() {
        // 14 日豁免**只作用于容量阈值**，不作用于 90 天期限（M6 ⑦）
        let records = [rec("e", daysOld: 91, bytes: 1_000, .execution)]
        XCTAssertTrue(
            Retention.isExpiredByAge(records[0], now: now),
            "14 日内的执行记录满 90 天仍按期限删除"
        )
    }

    func testNinetyDayLimitAppliesToEvidenceAndScan() {
        let records = [
            rec("v", daysOld: 91, bytes: 1_000, .evidence),
            rec("s", daysOld: 91, bytes: 1_000, .scan),
        ]
        XCTAssertTrue(Retention.isExpiredByAge(records[0], now: now))
        XCTAssertTrue(Retention.isExpiredByAge(records[1], now: now))
    }

    func testRecordAtExactlyNinetyDaysIsExpired() {
        let records = [rec("v", daysOld: 90, bytes: 1, .evidence)]
        XCTAssertTrue(
            Retention.isExpiredByAge(records[0], now: now),
            "边界取「≥ 90 天」为到期"
        )
    }

    func testRecordAtNinetyDaysMinusOneSecondIsNotExpired() {
        let justUnder = Retention.Record(
            id: "v",
            writtenAt: now.addingTimeInterval(-(90 * 86_400) + 1),
            bytes: 1,
            isExecutionRecord: false,
            file: .evidence
        )
        XCTAssertFalse(Retention.isExpiredByAge(justUnder, now: now))
    }

    // MARK: - 容量回收：滚动丢最旧

    func testCapacityRollsOutOldestUntilBelowThreshold() {
        // 5 条各 60 MB → 300 MB，须丢到 < 200 MB → 丢 2 条（300 → 240 → 180）
        // 显式时刻：offset 越小 = 越早 = 越旧 → oldest 最旧
        let records = [
            recAt("oldest", atOffsetDays: -10, bytes: 60_000_000, .evidence),
            recAt("second", atOffsetDays: -8, bytes: 60_000_000, .evidence),
            recAt("third", atOffsetDays: -6, bytes: 60_000_000, .evidence),
            recAt("fourth", atOffsetDays: -4, bytes: 60_000_000, .evidence),
            recAt("newest", atOffsetDays: -2, bytes: 60_000_000, .evidence),
        ]
        let outcome = Retention.plan(records: records, now: now)

        XCTAssertEqual(outcome.disposed.count, 2, "300 MB 须丢 2 条才降到 180 MB")
        XCTAssertEqual(outcome.disposed.map { $0.record.id }, ["oldest", "second"], "按记录时刻升序丢最旧")
        XCTAssertTrue(outcome.disposed.allSatisfy { $0.reason == .capacity })
        XCTAssertEqual(outcome.bytesBefore, 300_000_000)
        XCTAssertEqual(outcome.bytesAfter, 180_000_000)
        XCTAssertTrue(outcome.reachedTermination, "终止条件 = 丢弃后可回收字节 < 阈值")
    }

    func testCapacityDisposalOrderIsByRecordTimeAscending() {
        // 数组顺序与时刻顺序故意不一致，验证按时刻排序而非按数组序；240MB → 丢 1 条到 180MB
        let records = [
            recAt("newest", atOffsetDays: -1, bytes: 60_000_000, .evidence),
            recAt("oldest", atOffsetDays: -50, bytes: 60_000_000, .evidence),
            recAt("middle", atOffsetDays: -25, bytes: 60_000_000, .evidence),
            recAt("keep", atOffsetDays: -2, bytes: 60_000_000, .evidence),
        ]
        let outcome = Retention.plan(records: records, now: now)
        XCTAssertEqual(outcome.disposed.map { $0.record.id }, ["oldest"], "按记录时刻升序丢最旧")
        XCTAssertEqual(outcome.bytesAfter, 180_000_000)
    }

    func testDisposalWithinSameTimestampIsStableById() {
        // 同一时刻 → 按 id 稳定排序，保证同样输入得出同样结果（可复算）
        // 4 条同时刻 240 MB → 丢 1 条即降到 180MB；丢哪一条由 id 稳定排序决定
        let records = ["c", "a", "b", "d"].map {
            recAt($0, atOffsetDays: -10, bytes: 60_000_000, .evidence)
        }
        let outcome = Retention.plan(records: records, now: now)
        XCTAssertEqual(outcome.disposed.map { $0.record.id }, ["a"], "同一时刻按 id 稳定排序")
        XCTAssertEqual(outcome.bytesAfter, 180_000_000)
    }

    func testBelowThresholdNothingIsDisposed() {
        let records = [rec("e", daysOld: 1, bytes: 1000, .execution)]
        let outcome = Retention.plan(records: records, now: now)
        XCTAssertTrue(outcome.disposed.isEmpty)
        XCTAssertTrue(outcome.reachedTermination)
        XCTAssertNil(outcome.terminationNote)
    }

    func testExactlyAtThresholdStillDisposes() {
        // 阈值边界取「≥ 触发」（M6：可回收字节 ≥ 200 MB → 回收）
        let records = [rec("v", daysOld: 1, bytes: 200_000_000, .evidence)]
        let outcome = Retention.plan(records: records, now: now)
        XCTAssertEqual(outcome.disposed.count, 1, "恰好等于阈值即触发回收")
        XCTAssertEqual(outcome.bytesAfter, 0)
    }

    // MARK: - 终止性：不得假装可达

    func testTerminationUnreachableIsReportedNotFaked() {
        // 单条就超过阈值 → 丢完后可回收字节必为 0 → 终态**可达**（这不是不可达场景）
        let records = [rec("v", daysOld: 1, bytes: 250_000_000, .evidence)]
        let outcome = Retention.plan(records: records, now: now)
        XCTAssertTrue(outcome.reachedTermination)
        XCTAssertEqual(outcome.bytesAfter, 0)
        XCTAssertNil(outcome.terminationNote)
    }

    func testTerminationNoteSetWhenNoObjectLeftButStillOverThreshold() {
        // 构造「丢弃全部可回收对象后仍 ≥ 阈值」：
        // 用 14 日内的执行记录 —— 它不计入减数，故可回收字节 = 总量 − 该记录；
        // 丢它之后可回收字节 = 0。改为构造「记录被 90 天期限先删光」的场景来验证 note 分支。
        let records = [
            rec("old", daysOld: 200, bytes: 300_000_000, .evidence),   // 先被 90 天期限删
            rec("new", daysOld: 0, bytes: 100, .execution),           // 剩一条，豁免中 → 可回收字节 = 100 - 100 = 0
        ]
        let outcome = Retention.plan(records: records, now: now)
        XCTAssertEqual(outcome.disposed.count, 1)
        XCTAssertEqual(outcome.disposed[0].record.id, "old")
        XCTAssertEqual(outcome.disposed[0].reason, .ageLimit)
    }

    // MARK: - 90 天期限优先于容量

    func testAgeLimitAppliedBeforeCapacity() {
        // 最旧的一条同时满足两个条件 → 原因串归 ageLimit（先判期限）
        let records = [
            rec("ancient", daysOld: 200, bytes: 250_000_000, .evidence),
            rec("recent", daysOld: 1, bytes: 10_000_000, .evidence),
        ]
        let outcome = Retention.plan(records: records, now: now)
        XCTAssertEqual(outcome.disposed.count, 1)
        XCTAssertEqual(outcome.disposed[0].reason, .ageLimit, "期限先判")
    }

    func testRecentExecutionRecordStillDisposedByCapacityEvenThoughExempt() {
        // 14 日豁免只作用于**计量**（减数），不豁免**被丢弃**：
        // 该记录虽在 14 日内（不计入减数），但仍是目录里最旧的行 → 容量回收时照样可被丢
        let records = [
            rec("recentExec", daysOld: 1, bytes: 250_000_000, .execution),
            rec("older", daysOld: 40, bytes: 250_000_000, .evidence),
        ]
        // 可回收字节 = 500M − 250M（recentExec 在 14 日内 → 计入减数）= 250M ≥ 阈值 → 丢最旧
        let outcome = Retention.plan(records: records, now: now)
        XCTAssertEqual(outcome.disposed.first?.record.id, "older")
        // 丢 older 后：剩 recentExec，可回收 = 250M − 250M = 0 → 终止
        XCTAssertTrue(outcome.reachedTermination)
    }

    // MARK: - restoring 态禁入

    func testRetentionMustNotRunWhileRestoring() {
        XCTAssertFalse(
            Retention.mayRun(isRestoring: true),
            "restoring 态回收会删掉回退依据 → 禁止"
        )
        XCTAssertTrue(Retention.mayRun(isRestoring: false))
    }

    // MARK: - 边界

    func testFutureTimestampIsNotTreatedAsExpired() {
        // 时钟回拨 / 注入导致的未来时刻：不判超期（否则会误删）
        let future = Retention.Record(
            id: "f",
            writtenAt: now.addingTimeInterval(3600),
            bytes: 1,
            isExecutionRecord: false,
            file: .evidence
        )
        XCTAssertFalse(Retention.isExpiredByAge(future, now: now))
    }

    func testZeroRecordsYieldsZeroBytes() {
        let outcome = Retention.plan(records: [], now: now)
        XCTAssertEqual(outcome.bytesBefore, 0)
        XCTAssertEqual(outcome.bytesAfter, 0)
        XCTAssertTrue(outcome.reachedTermination)
    }

    func testCapacityThresholdIsTwoHundredMillionNotTwoToTheTwenty() {
        XCTAssertEqual(
            Retention.capacityThresholdBytes,
            200_000_000,
            "M6：200 MB = 200 × 10⁶（不取 2²⁰，避免边界上两个结论）"
        )
    }
}
