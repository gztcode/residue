import Foundation

// ============================================================
// Residue · 状态存储层
//
// 契约落点（PRD v5.2 · M4「写入时刻」）：
//   - 载体 = **应用状态目录**下的本机状态文件
//   - **不属 N7 的 `.jsonl` 记录目录、不计入 N7 计量与容量回收**
//   - **N7「一键清除全部采集与日志」不作用于该记录**
//     ⇒ 用户的清除动作**不构成 `a` 的重置路径**
//   - **应用版本变更时，载体字段（F / C_done / 位槽占用表 / a）一并清零**
//   - **轮次切换时不清零**（跨轮次累计，天然实现「错 1 次永久」）
//
// 本文件不引用任何 UI；纯 IO + 序列化，便于单测。
// ============================================================

/// 一个来源的持久化状态。
public struct PersistedSourceState: Codable, Sendable, Equatable {
    public let source: Source
    public var l0: SourceL0State
    /// 该来源最近一轮的快照与结算（供观察期判定复用）
    public var snapshot: SnapshotMetrics?
    /// 该来源当前轮次的 `b`（L0 检查次数，按轮分组、轮次切换清零）
    public var checkCountThisRound: Int

    public init(
        source: Source,
        l0: SourceL0State = SourceL0State(),
        snapshot: SnapshotMetrics? = nil,
        checkCountThisRound: Int = 0
    ) {
        self.source = source
        self.l0 = l0
        self.snapshot = snapshot
        self.checkCountThisRound = checkCountThisRound
    }
}

/// 全局状态（跨来源 + 观察期进度）。
public struct PersistedAppState: Codable, Sendable, Equatable {
    /// 观察期进度（轮次 / 起算点 / 计数日）。
    public var progress: ObservationProgress
    /// 各来源的状态。
    public var sources: [Source: PersistedSourceState]
    /// 是否已启用自动删除（点亮开关）。
    public var autoDeleteEnabled: Bool
    /// 写入该状态的**应用版本**——用于「应用版本变更时一并清零」判定。
    public var appVersion: String
    /// 最近一次成功扫描的时刻。
    public var lastScanAt: Date?

    public init(
        progress: ObservationProgress = ObservationProgress(),
        sources: [Source: PersistedSourceState] = [:],
        autoDeleteEnabled: Bool = false,
        appVersion: String = "",
        lastScanAt: Date? = nil
    ) {
        self.progress = progress
        self.sources = sources
        self.autoDeleteEnabled = autoDeleteEnabled
        self.appVersion = appVersion
        self.lastScanAt = lastScanAt
    }

    /// 载体全量清零（**应用版本变更**时调用）。
    ///
    /// 契约 M4 重置边界：`F` / `C_done` / 位槽占用表 / `a` **一并清零**；
    /// `b` 按轮分组 → 也随之清零。轮次切换**不**走这条路径。
    public mutating func resetCarrierForVersionChange(newVersion: String) {
        for (key, var st) in sources {
            st.l0 = SourceL0State()
            st.checkCountThisRound = 0
            sources[key] = st
        }
        progress = ObservationProgress(round: progress.round)  // 轮次不变
        appVersion = newVersion
    }

    /// 轮次切换（未达标自动开下一轮）：**只清本轮派生量，`F` / `C_done` / `a` 保留**。
    ///
    /// 契约：轮次切换时 `F` / `C_done` / `a` 三者均不清零（跨轮次累计，
    /// 天然实现「错 1 次永久」）；计数日与 `b` 随轮归零。
    public mutating func beginNextRound() {
        progress.round += 1
        progress.startAnchor = nil
        progress.countedDays = 0
        for (key, var st) in sources {
            st.checkCountThisRound = 0
            sources[key] = st
        }
    }
}

/// 状态文件的读写。
///
/// **落点**：`~/Library/Application Support/Residue/state.json`
/// 该目录**不在** N7 的 `.jsonl` 记录目录内，因此：
///   - 不被容量回收触及
///   - 不计入可回收字节
///   - 「一键清除全部采集与日志」不作用于它
public struct StateStore: Sendable {
    public let directory: URL
    public let fileURL: URL

    public init(directory: URL? = nil) {
        let dir = directory ?? StateStore.defaultDirectory()
        self.directory = dir
        self.fileURL = dir.appendingPathComponent("state.json")
    }

    /// 默认状态目录（应用状态目录，非日志目录）。
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Residue", isDirectory: true)
    }

    /// 读状态；文件不存在或损坏 → 返回初始状态（不抛错，保证首启可用）。
    public func load() -> PersistedAppState {
        guard let data = try? Data(contentsOf: fileURL) else {
            return PersistedAppState()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(PersistedAppState.self, from: data) else {
            // 损坏文件：不静默丢弃，改名保留供诊断，然后回落初始态
            let backup = directory.appendingPathComponent("state.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            return PersistedAppState()
        }
        return state
    }

    /// 写状态（原子写）。
    public func save(_ state: PersistedAppState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: [.atomic])
    }

    /// 应用版本变更时清零载体（契约 M4）。返回是否发生了重置。
    @discardableResult
    public func resetIfVersionChanged(state: inout PersistedAppState, currentVersion: String) -> Bool {
        guard !state.appVersion.isEmpty, state.appVersion != currentVersion else {
            state.appVersion = currentVersion
            return false
        }
        state.resetCarrierForVersionChange(newVersion: currentVersion)
        return true
    }
}
