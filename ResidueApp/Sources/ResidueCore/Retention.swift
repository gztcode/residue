import Foundation

/// M6 · 留存计量与回收。
///
/// 契约依据：`Residue-R2-技术方案-v1.6.md` IF-11 / §5.3 / §5.4 / M6。
///
/// **唯一计量式（M6 · 唯一口径）**
///     可回收字节 := 目录内全部 .jsonl 字节合计 − 14 日内执行记录字节合计
/// - 减数项**只含执行记录**（`execution.jsonl`）；举证链 / 扫描日志**不豁免**。
/// - `200 MB` = `200 × 10⁶` 字节（不取 2²⁰）。
/// - 90 天期限**按记录时刻判定，对全部记录适用**。
/// - 14 日豁免**只作用于容量阈值**，**不作用于 90 天期限**。
///
/// **回收单位 = 整条记录（整行）**，不做行内截断。
/// **回收顺序 = 按记录时刻升序**（「最旧」的唯一含义）。
public enum Retention {

    // MARK: - 常量

    /// 容量阈值：`200 × 10⁶` 字节（M6 · 不取 2²⁰，避免边界上两个结论）。
    public static let capacityThresholdBytes: Int64 = 200_000_000

    /// 90 天期限（M6 · 对全部记录适用）。
    public static let retentionDays: Int = 90

    /// 14 日豁免（**只作用于容量阈值**；AC-13 的恢复承诺依赖它）。
    public static let executionExemptionDays: Int = 14

    // MARK: - 输入 / 输出

    /// 一条可参与回收的记录。
    ///
    /// - `writtenAt` = **记录时刻**：执行记录用 P3 删除记录时刻；
    ///   举证链 / 扫描日志用**该行的写入时刻**（M6 · 唯一化）。
    /// - `isExecutionRecord` = 是否 `execution.jsonl` 的行（**减数项只认它**）。
    /// - `bytes` = 该行的字节数（**整行**，含换行符由写入侧保证）。
    public struct Record: Equatable, Sendable {
        public var id: String
        public var writtenAt: Date
        public var bytes: Int64
        public var isExecutionRecord: Bool
        public var file: RecordFile

        public init(
            id: String,
            writtenAt: Date,
            bytes: Int64,
            isExecutionRecord: Bool,
            file: RecordFile
        ) {
            self.id = id
            self.writtenAt = writtenAt
            self.bytes = bytes
            self.isExecutionRecord = isExecutionRecord
            self.file = file
        }
    }

    /// 三种记录文件（`scan.jsonl` / `execution.jsonl` / `evidence.jsonl`）。
    public enum RecordFile: String, Codable, Sendable, CaseIterable {
        case evidence
        case execution
        case scan

        /// 是否计入 M6 的**减数项**（14 日豁免只作用于执行记录）。
        public var countsAsExemption: Bool { self == .execution }
    }

    /// 回收动作的结果（一条记录 = 一个动作）。
    public struct Disposal: Equatable, Sendable {
        public enum Reason: String, Sendable {
            /// 容量阈值触发（滚动丢最旧）。
            case capacity
            /// 90 天期限到期。
            case ageLimit
        }

        public var record: Record
        public var reason: Reason

        public init(record: Record, reason: Reason) {
            self.record = record
            self.reason = reason
        }
    }

    /// 一次回收的完整结果。
    public struct Outcome: Equatable, Sendable {
        /// 本次删除的记录（按删除顺序 = 记录时刻升序）。
        public var disposed: [Disposal]
        /// 回收**前**的可回收字节。
        public var bytesBefore: Int64
        /// 回收**后**的可回收字节。
        public var bytesAfter: Int64
        /// 终止条件是否达成（**「丢弃后可回收字节 < 阈值」**）。
        public var reachedTermination: Bool
        /// 未能达成的说明（如实登记，不假装）。
        public var terminationNote: String?

        public init(
            disposed: [Disposal] = [],
            bytesBefore: Int64 = 0,
            bytesAfter: Int64 = 0,
            reachedTermination: Bool = false,
            terminationNote: String? = nil
        ) {
            self.disposed = disposed
            self.bytesBefore = bytesBefore
            self.bytesAfter = bytesAfter
            self.reachedTermination = reachedTermination
            self.terminationNote = terminationNote
        }
    }

    // MARK: - 计量

    /// M6 唯一式：`可回收字节 := 目录内全部 .jsonl 字节合计 − 14 日内执行记录字节合计`。
    ///
    /// - 参数 `now` = 当前时刻（**14 日的边界以记录时刻为准**，AC-13 的 14 日承诺同源）。
    /// - **减数项只含 14 日内的执行记录**；举证链 / 扫描日志**不豁免**。
    public static func reclaimableBytes(records: [Record], now: Date) -> Int64 {
        let total = records.reduce(Int64(0)) { $0 + $1.bytes }
        let exempted = records
            .filter { $0.isExecutionRecord && isWithinDays($0.writtenAt, days: executionExemptionDays, now: now) }
            .reduce(Int64(0)) { $0 + $1.bytes }
        return total - exempted
    }

    /// 某条记录是否落在「距今 N 日内」（**按记录时刻**，不是按文件 mtime）。
    public static func isWithinDays(_ date: Date, days: Int, now: Date) -> Bool {
        let elapsed = now.timeIntervalSince(date)
        // 未来时刻（时钟回拨 / 注入）不算「N 日内」，但也不判为超期 —— 由调用方分别处理。
        guard elapsed >= 0 else { return true }
        return elapsed < Double(days) * 86_400
    }

    /// 记录是否已过 90 天期限（**对全部记录适用**，含 14 日内的执行记录）。
    public static func isExpiredByAge(_ record: Record, now: Date) -> Bool {
        let elapsed = now.timeIntervalSince(record.writtenAt)
        guard elapsed >= 0 else { return false }
        return elapsed >= Double(retentionDays) * 86_400
    }

    // MARK: - 回收决策

    /// 计算一次回收应当删除哪些记录（**纯函数，不碰文件系统**）。
    ///
    /// 规则（IF-11）：
    /// 1. **90 天期限**：到期记录**无条件删除**（对全部记录适用）。
    /// 2. **容量阈值**：若回收后 `可回收字节 ≥ 阈值`，则**按记录时刻升序整行删**直到 `< 阈值`。
    ///    - **注意顺序**：14 日豁免只作用于容量阈值 → 14 日内的执行记录**仍参与**容量回收的
    ///      「丢弃最旧」过程，但它们**不计入减数**；因此本函数按「丢弃后重算可回收字节」推进，
    ///      直到 `< 阈值`。
    /// 3. **终止条件** = 「丢弃后可回收字节 < 阈值」。
    ///
    /// - 参数 `now` = 当前时刻。
    /// - 返回的 `disposed` 已按**实际删除顺序**（记录时刻升序）排好。
    public static func plan(records: [Record], now: Date) -> Outcome {
        var outcome = Outcome()
        outcome.bytesBefore = reclaimableBytes(records: records, now: now)

        // 剩余待处理集合（按记录时刻升序）。
        var remaining = records.sorted { lhs, rhs in
            if lhs.writtenAt != rhs.writtenAt { return lhs.writtenAt < rhs.writtenAt }
            return lhs.id < rhs.id          // 同一时刻按 id 稳定排序，保证可复算
        }

        // ---- 第一步：90 天期限（无条件，对全部记录适用） ----
        var expired: [Record] = []
        var survivors: [Record] = []
        for r in remaining {
            if isExpiredByAge(r, now: now) {
                expired.append(r)
            } else {
                survivors.append(r)
            }
        }
        for r in expired {
            outcome.disposed.append(Disposal(record: r, reason: .ageLimit))
        }
        remaining = survivors

        // ---- 第二步：容量阈值（按记录时刻升序整行丢最旧） ----
        var currentBytes = reclaimableBytes(records: remaining, now: now)
        while currentBytes >= capacityThresholdBytes, !remaining.isEmpty {
            let oldest = remaining.removeFirst()
            outcome.disposed.append(Disposal(record: oldest, reason: .capacity))
            currentBytes = reclaimableBytes(records: remaining, now: now)
        }

        outcome.bytesAfter = currentBytes
        outcome.reachedTermination = currentBytes < capacityThresholdBytes
        if !outcome.reachedTermination {
            // 全部可回收对象都丢了仍 ≥ 阈值：如实登记，**不假装可达**（M6 · 终止性）。
            outcome.terminationNote =
                "已丢弃全部可回收对象，可回收字节仍为 \(currentBytes) 字节（阈值 \(capacityThresholdBytes)）"
        }
        return outcome
    }

    /// 判断当前状态是否处于「`restoring` 态」——该态下**禁止回收**。
    ///
    /// 理由（IF-11）：回退期间 `execution.jsonl` 的行正是「哪些条目被移回原位」的依据；
    /// 此时回收会把正在回退的记录删掉 → **回退依据消失**。
    public static func mayRun(isRestoring: Bool) -> Bool {
        !isRestoring
    }
}
