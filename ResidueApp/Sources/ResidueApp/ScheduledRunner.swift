import Foundation
import ResidueCore

// ============================================================
// Residue · 定时任务壳（Timer + 落盘），排程计算在 Core
//
// ## 分工
// - **算**该不该跑、下次何时跑 → `SchedulePlanner`（Core，纯函数，有单测）
// - **跑**与**排** → 本文件（依赖 Timer / 文件系统，测不了的部分如实标注）
//
// ## 三条契约硬约束
// 1. **ADR-02**：登录项非 `.enabled` → **定时任务不执行**（不是「跑了再报错」）
// 2. **N3**：每日 1 次、错峰、增量优先；全量每 7 天 1 次
// 3. **N4**：单次执行超时 ≤ 5 min
//
// ## 为什么 lastRun 不写进 `state.residue`
// 载体 schema 已冻结（§5.1 有 CRC 与尺寸恒等式），为一个排程字段动它不划算。
// 排程状态属**运行期态**，按 §5.5 落在 `state/` 下、**不计入 M6 计量**。
// ============================================================

/// 排程运行期态（落 `state/schedule.json`，**不计入 N7 的 `.jsonl` 计量**）。
struct ScheduleState: Codable, Sendable, Equatable {
    /// 上次成功跑完定时任务的时刻。
    var lastRun: Date?
    /// 上次全量扫描时刻（决定本次 full / incremental）。
    var lastFullScanAt: Date?

    static let empty = ScheduleState()
}

/// 定时任务壳。
@MainActor
final class ScheduledRunner {

    /// 单次执行超时（N4：≤ 5 min）。
    static let executionTimeout: TimeInterval = 5 * 60

    private let policy: SchedulePolicy
    private let stateURL: URL
    private var timer: Timer?

    private(set) var state: ScheduleState = .empty

    /// 真正要跑的那件事（由 AppModel 注入，避免本文件依赖扫描实现）。
    private let work: (_ mode: ScanEngine.Mode) async -> Void

    init(
        directory: URL? = nil,
        policy: SchedulePolicy = .default,
        work: @escaping (_ mode: ScanEngine.Mode) async -> Void
    ) {
        self.policy = policy
        let dir = directory ?? StateFile.defaultDirectory().appendingPathComponent("state", isDirectory: true)
        self.stateURL = dir.appendingPathComponent("schedule.json")
        self.work = work
        loadState()
    }

    // MARK: - 启停

    /// 启动排程。
    ///
    /// - Parameter loginItemAllows: 登录项是否 `.enabled`。
    ///   **`false` 时直接不排**（ADR-02：非 enabled 不执行）——不是「排了但跳过」，
    ///   因为「排了」意味着界面上会显示「已排程」，那是在假装。
    /// 启动定时任务。
    ///
    /// - Parameters:
    ///   - loginItemAllows: 登录项是否为 `.enabled`（ADR-02：非 enabled 一律不排）。
    ///   - allowsCollection: **采集是否被允许**（AC-10）。
    ///
    /// ## `allowsCollection` 为什么是独立参数
    ///
    /// AC-10：用户**关闭自动删除后**，四档采集全部停止，且「关闭后定时任务
    /// **不跑采集**、仅按 N3 保留配置」。
    ///
    /// 但**观察期必须能继续采集** —— 否则用户永远攒不够样本、永远点不亮
    /// （那是把产品锁死）。所以条件不是「autoDeleteEnabled」这么简单：
    ///
    /// | 状态 | 采集 |
    /// |---|---|
    /// | 从未启用过（观察期中） | **要采集** —— 否则永远达不到点亮条件 |
    /// | 已启用 | 要采集 |
    /// | 曾启用、现已关闭 | **不采集**（AC-10 的 Then） |
    ///
    /// 这个判断由 `AppModel` 算好传进来（它持有 `preferences.everEnabledAutoDelete`），
    /// 本类不自己推断 —— 避免「同一判定两处实现必然分叉」。
    func start(loginItemAllows: Bool, allowsCollection: Bool = true, now: Date = Date()) {
        stop()
        guard loginItemAllows else { return }
        guard allowsCollection else {
            // 不排程，但不是「故障」——AC-10 的预期状态。**界面要能说清为什么不动**。
            return
        }

        // **补跑**：App 可能昨天没开。`isDue` 为真则立刻补一次。
        if SchedulePlanner.isDue(lastRun: state.lastRun, now: now, policy: policy) {
            fire(now: now)
        } else {
            scheduleNext(after: now)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 内部

    private func scheduleNext(after now: Date) {
        let fireAt = SchedulePlanner.nextFireDateWithJitter(
            lastRun: state.lastRun, now: now, policy: policy
        )
        let interval = max(1, fireAt.timeIntervalSince(now))
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.fire(now: Date())
            }
        }
    }

    private func fire(now: Date) {
        let mode = SchedulePlanner.mode(
            lastFullScan: state.lastFullScanAt, now: now, policy: policy
        )
        Task { @MainActor in
            await self.work(mode)
            self.state.lastRun = Date()
            if mode == .full { self.state.lastFullScanAt = Date() }
            self.saveState()
            self.scheduleNext(after: Date())
        }
    }

    // MARK: - 落盘

    private func loadState() {
        guard let data = try? Data(contentsOf: stateURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let s = try? dec.decode(ScheduleState.self, from: data) {
            state = s
        }
    }

    private func saveState() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(state) else { return }
        try? FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // 原子写：半份 schedule.json 会让「上次运行时刻」读不出来 → 每启动都补跑一次
        try? data.write(to: stateURL, options: [.atomic])
    }
}
