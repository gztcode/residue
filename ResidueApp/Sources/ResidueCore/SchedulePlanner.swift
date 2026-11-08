import Foundation

// ============================================================
// Residue · 定时任务排程（**N3 / ADR-02**）
//
// ## 为什么排程计算在 Core
// 它是纯函数（输入「上次运行时刻 + 现在」，输出「该不该跑 / 下次何时跑」），
// **不需要文件系统、不需要 SMAppService**。放 Core 就能用单测穷举边界
// （跨日、时钟回拨、首次运行、错峰窗口、7 天全量），不必等真跑一天。
//
// 壳（Timer / SMAppService）留在 App——那部分依赖系统，测不了就如实标注。
//
// ## 契约依据
// - **N3**：默认每日 1 次、错峰、增量优先；全量扫描默认每 7 天 1 次（建议值）
// - **N4**：单次执行超时 ≤ 5 min
// - **ADR-02**：`SMAppService.status` 非 `.enabled` 时**定时任务不执行**
// ============================================================

/// 排程策略（N3 的建议值，可由上层覆盖）。
public struct SchedulePolicy: Sendable, Equatable {
    /// 每日间隔（默认 24 h = 每日 1 次）。
    public var dailyInterval: TimeInterval
    /// 全量扫描间隔（默认 7 天；其余为增量）。
    public var fullScanInterval: TimeInterval
    /// 错峰上限：同一时刻不集中开机（默认 1 h 内的确定性抖动）。
    public var jitterMax: TimeInterval

    public init(
        dailyInterval: TimeInterval = 24 * 3600,
        fullScanInterval: TimeInterval = 7 * 24 * 3600,
        jitterMax: TimeInterval = 3600
    ) {
        self.dailyInterval = dailyInterval
        self.fullScanInterval = fullScanInterval
        self.jitterMax = jitterMax
    }

    /// N3 的默认策略。
    public static let `default` = SchedulePolicy()
}

/// 排程计算（纯函数）。
public enum SchedulePlanner {

    /// 现在是否该跑一次。
    ///
    /// - Parameters:
    ///   - lastRun: 上次成功运行时刻（`nil` = 从未运行 → 首次跑到就跑）。
    ///   - now: 现在。
    public static func isDue(lastRun: Date?, now: Date, policy: SchedulePolicy = .default) -> Bool {
        guard let last = lastRun else { return true }
        // **时钟回拨保护**：`now < last` 说明系统时间被调回去了。
        // 此时不能判「已过 24 h」，否则回拨一年会立刻触发；
        // 也不能永远不跑——按「立即补一次」处理，随后 lastRun 会被更新。
        if now < last { return true }
        return now.timeIntervalSince(last) >= policy.dailyInterval
    }

    /// 下一次应触发的时刻（用于排 Timer）。
    ///
    /// - 从未运行 → 立刻（返回 `now`）。
    /// - 已到期 → 立刻。
    /// - 未到期 → `lastRun + dailyInterval`。
    public static func nextFireDate(
        lastRun: Date?, now: Date, policy: SchedulePolicy = .default
    ) -> Date {
        guard let last = lastRun else { return now }
        if now < last { return now }
        let due = last.addingTimeInterval(policy.dailyInterval)
        return max(due, now)
    }

    /// 本次应跑的模式：**全量每 7 天 1 次，其余增量**（N3）。
    ///
    /// - Parameter lastFullScan: 上次全量扫描时刻（`nil` = 从未全量 → 本次全量）。
    public static func mode(
        lastFullScan: Date?, now: Date, policy: SchedulePolicy = .default
    ) -> ScanEngine.Mode {
        guard let last = lastFullScan else { return .full }
        // 时钟回拨 → 按全量处理（宁可多扫一次，不可漏扫）
        if now < last { return .full }
        return now.timeIntervalSince(last) >= policy.fullScanInterval ? .full : .incremental
    }

    /// 错峰偏移（**确定性**，不是随机）。
    ///
    /// 为什么用「每天变化的确定性偏移」而不是 `random()`：
    /// ① 同一台机器同一天两次计算得到同一时刻（Timer 重排不会漂移）；
    /// ② 不同机器因安装时刻不同而自然错峰；
    /// ③ 可单测——随机数不可断言。
    ///
    /// 偏移量落在 `[0, jitterMax)`。
    public static func jitter(for day: Date, policy: SchedulePolicy = .default) -> TimeInterval {
        guard policy.jitterMax > 0 else { return 0 }
        // 用「自 1970 起的天数」做种子：同一天恒定，跨天变化
        let days = Int(day.timeIntervalSince1970 / 86400)
        // 一个便宜的整数散列（FNV-1a 风格），只为把天数摊开
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for shift in stride(from: 0, to: 64, by: 8) {
            h ^= UInt64(truncatingIfNeeded: days >> shift) & 0xFF
            h = h &* 0x0000_0100_0000_01B3
        }
        let ratio = Double(h % 1_000_000) / 1_000_000.0
        return ratio * policy.jitterMax
    }

    /// 带错峰的触发时刻（**实际排 Timer 用这个**）。
    public static func nextFireDateWithJitter(
        lastRun: Date?, now: Date, policy: SchedulePolicy = .default
    ) -> Date {
        let base = nextFireDate(lastRun: lastRun, now: now, policy: policy)
        return base.addingTimeInterval(jitter(for: base, policy: policy))
    }
}
