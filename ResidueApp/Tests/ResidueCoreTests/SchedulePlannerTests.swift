import XCTest
@testable import ResidueCore

/// `SchedulePlanner` 测试（N3 / N4 / ADR-02）。
///
/// 排程是**纯函数**，所以边界能穷举：跨日、时钟回拨、首次运行、
/// 7 天全量切换、错峰窗口。真跑一天测不了的东西，这里都能测。
final class SchedulePlannerTests: XCTestCase {

    private let day: TimeInterval = 24 * 3600
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - isDue

    /// **从未运行 → 立刻该跑**（首次启动要补一次）。
    func testDueWhenNeverRun() {
        XCTAssertTrue(SchedulePlanner.isDue(lastRun: nil, now: t0))
    }

    /// **刚跑过（< 24 h）→ 不跑**。
    func testNotDueWithinADay() {
        let last = t0.addingTimeInterval(-3600)   // 1 小时前
        XCTAssertFalse(SchedulePlanner.isDue(lastRun: last, now: t0))
    }

    /// **满 24 h → 跑**。
    func testDueAtExactlyOneDay() {
        let last = t0.addingTimeInterval(-day)
        XCTAssertTrue(SchedulePlanner.isDue(lastRun: last, now: t0), "满 24 h 应到期")
    }

    /// **时钟回拨 → 仍判该跑**（不是判「永远不到期」）。
    ///
    /// 若用 `now - last >= 24h`，回拨一年会得负数 → 永远不跑；
    /// 若反过来判「负数即到期」，回拨也会立刻跑。两种极端都不对，
    /// 取「立刻补一次」更安全（宁可多扫一次，不可漏扫）。
    func testClockRollbackTriggersCatchUp() {
        let last = t0.addingTimeInterval(365 * day)   // 「未来」的 lastRun（说明时钟被调回去了）
        XCTAssertTrue(
            SchedulePlanner.isDue(lastRun: last, now: t0),
            "时钟回拨不得导致永远不跑"
        )
    }

    // MARK: - nextFireDate

    /// **从未运行 → 立刻**（返回 `now`）。
    func testNextFireImmediatelyWhenNeverRun() {
        XCTAssertEqual(SchedulePlanner.nextFireDate(lastRun: nil, now: t0), t0)
    }

    /// **未到期 → `lastRun + 24h`**。
    func testNextFireIsLastPlusInterval() {
        let last = t0.addingTimeInterval(-3600)
        let next = SchedulePlanner.nextFireDate(lastRun: last, now: t0)
        XCTAssertEqual(next.timeIntervalSince1970,
                       last.addingTimeInterval(day).timeIntervalSince1970,
                       accuracy: 0.001)
    }

    /// **已过期 → 立刻**（不返回一个过去的时刻去排 Timer）。
    func testNextFireIsNowWhenOverdue() {
        let last = t0.addingTimeInterval(-3 * day)
        let next = SchedulePlanner.nextFireDate(lastRun: last, now: t0)
        XCTAssertEqual(next.timeIntervalSince1970, t0.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(next, t0, "排 Timer 不得给过去时刻")
    }

    // MARK: - mode（N3：全量每 7 天 1 次）

    /// **从未全量 → 本次全量**。
    func testFirstRunIsFull() {
        XCTAssertEqual(SchedulePlanner.mode(lastFullScan: nil, now: t0), .full)
    }

    /// **7 天内 → 增量**（N3：增量优先）。
    func testIncrementalWithinSevenDays() {
        let lastFull = t0.addingTimeInterval(-3 * day)
        XCTAssertEqual(SchedulePlanner.mode(lastFullScan: lastFull, now: t0), .incremental)
    }

    /// **满 7 天 → 全量**。
    func testFullAfterSevenDays() {
        let lastFull = t0.addingTimeInterval(-7 * day)
        XCTAssertEqual(SchedulePlanner.mode(lastFullScan: lastFull, now: t0), .full)
    }

    /// **时钟回拨 → 按全量**（宁可多扫一次，不可漏扫）。
    func testClockRollbackForcesFull() {
        let lastFull = t0.addingTimeInterval(30 * day)   // 未来时刻
        XCTAssertEqual(SchedulePlanner.mode(lastFullScan: lastFull, now: t0), .full)
    }

    // MARK: - jitter（错峰）

    /// **同一天错峰偏移恒定**——Timer 重排不会漂移。
    ///
    /// 这条是「确定性抖动」相对 `random()` 的核心好处：
    /// 随机数会让每次重算得到不同时刻，于是「下次触发时间」在界面上闪烁。
    func testJitterIsStableWithinSameDay() {
        let a = t0
        let b = t0.addingTimeInterval(3600)          // 同一天稍晚
        XCTAssertEqual(
            SchedulePlanner.jitter(for: a),
            SchedulePlanner.jitter(for: b),
            accuracy: 1e-9,
            "同一天内偏移必须相同"
        )
    }

    /// **跨天偏移变化**（否则所有机器永远同一时刻跑）。
    func testJitterVariesAcrossDays() {
        let a = t0
        let b = t0.addingTimeInterval(day)
        XCTAssertNotEqual(
            SchedulePlanner.jitter(for: a),
            SchedulePlanner.jitter(for: b),
            accuracy: 1e-9
        )
    }

    /// **偏移落在 `[0, jitterMax)`**。
    func testJitterWithinBounds() {
        let policy = SchedulePolicy(jitterMax: 1800)
        for i in 0..<64 {
            let d = t0.addingTimeInterval(Double(i) * day)
            let j = SchedulePlanner.jitter(for: d, policy: policy)
            XCTAssertGreaterThanOrEqual(j, 0)
            XCTAssertLessThan(j, 1800)
        }
    }

    /// **`jitterMax = 0` 时无偏移**（便于测试与确定性场景）。
    func testZeroJitter() {
        let policy = SchedulePolicy(jitterMax: 0)
        XCTAssertEqual(SchedulePlanner.jitter(for: t0, policy: policy), 0)
    }

    /// **带错峰的触发时刻 ≥ 基础触发时刻**（只会推迟，不会提前）。
    func testJitteredFireDateNeverEarlierThanBase() {
        let last = t0.addingTimeInterval(-3600)
        let base = SchedulePlanner.nextFireDate(lastRun: last, now: t0)
        let jittered = SchedulePlanner.nextFireDateWithJitter(lastRun: last, now: t0)
        XCTAssertGreaterThanOrEqual(jittered, base)
    }
}
