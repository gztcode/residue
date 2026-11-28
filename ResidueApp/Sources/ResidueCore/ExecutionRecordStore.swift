import Foundation

/// `execution.jsonl`（AC-18 举证链的数据源）的落盘责任方。
///
/// ## 根因（这个类型存在的理由）
///
/// `TrashExecutor` 在返回前就把文件 `moveItem` 进了废纸篓 —— **删除动作已经发生**。
/// 而恢复路径 `restorePath` **只有这一条记录能提供**
/// （`TrashExecutor.restore` 的入口就是 `guard let restorePath else throw .noRestorePath`）。
/// 于是「执行记录写不下去」= **恢复入口永久消失**。
///
/// 原实现用 `try?` 吞掉写盘失败：记录没落盘、`restorePath` 丢失，
/// 界面却按内存里的记录报「已清理 N 条」—— **用户被告知一切都好，恢复入口却没了**。
///
/// ## 三条保证
///
/// 1. **写盘失败绝不静默**：落盘结果分三档（**已落盘 / 待补写 / 彻底丢失**），逐档报给界面。
/// 2. **恢复信息不丢**：写不进 `execution.jsonl` 的记录进 `state/pending-execution.jsonl`
///    （待补写队列），下次启动补写回 `execution.jsonl`。
/// 3. **补写幂等**：按「候选 + 动作 + 动作时刻」比对，已补写过的不会重复补
///    （补到一半崩溃时，队列里的副本会被认出来并丢弃）。
public struct ExecutionRecordStore: Sendable {

    // MARK: - 落点

    /// 举证链（`records/execution.jsonl`）。
    public let writer: RecordWriter

    /// 待补写队列（`state/pending-execution.jsonl`）。
    ///
    /// **落 `state/` 而不是 `records/`**：
    /// - `records/` 下的 `.jsonl` **计入 M6 计量**（可回收字节）—— 待补写队列不是举证链，
    ///   把它算进「可回收字节」等于把**还没写出去的恢复信息**算成垃圾；
    /// - `state/` 下的运行期态**不计入 M6 计量**，但**计入 N7 清除范围**
    ///   （它含用户路径副本，漏清即等于「清除后仍留用户路径副本」—— 质量 B-07）。
    public let pendingURL: URL

    public init(writer: RecordWriter, pendingURL: URL) {
        self.writer = writer
        self.pendingURL = pendingURL
    }

    /// 默认落点（`state/pending-execution.jsonl`，路径由 `StateFile` 唯一定义）。
    public init(writer: RecordWriter = RecordWriter()) {
        self.init(
            writer: writer,
            pendingURL: StateFile.pendingExecutionURL(
                in: writer.directory.deletingLastPathComponent()
            )
        )
    }

    // MARK: - 落盘结果

    /// 一批记录落盘后的去向（按「**恢复信息还在不在**」分档）。
    public struct Group: Equatable, Sendable {
        /// 已写进 `execution.jsonl` —— **恢复入口可用**。
        public let persisted: [ExecutionRecord]
        /// 没能写进 `execution.jsonl`，但**已进待补写队列** —— 恢复信息还在，下次启动补写。
        public let queued: [ExecutionRecord]
        /// 既没落盘也没进队列 —— **恢复信息彻底丢失**。
        public let lost: [ExecutionRecord]

        public init(
            persisted: [ExecutionRecord] = [],
            queued: [ExecutionRecord] = [],
            lost: [ExecutionRecord] = []
        ) {
            self.persisted = persisted
            self.queued = queued
            self.lost = lost
        }

        public var persistedCount: Int { persisted.count }
        public var queuedCount: Int { queued.count }
        public var lostCount: Int { lost.count }
        public var persistedBytes: Int64 { Self.bytes(persisted) }
        public var queuedBytes: Int64 { Self.bytes(queued) }
        public var lostBytes: Int64 { Self.bytes(lost) }

        /// 是否全部落盘（`true` = 没有任何一条需要用户操心）。
        public var isClean: Bool { queued.isEmpty && lost.isEmpty }

        private static func bytes(_ records: [ExecutionRecord]) -> Int64 {
            records.reduce(Int64(0)) { $0 + $1.bytes }
        }
    }

    /// 一次落盘的整体结果。
    public struct PersistResult: Equatable, Sendable {
        /// 删除类记录（`action == .renameToTrash`）—— **恢复信息在这一档**。
        public let deleted: Group
        /// 其余记录（拦下 / 失败 / 恢复回写）—— 这一档丢的是**举证链的一行**，不是恢复入口。
        public let other: Group

        public init(deleted: Group, other: Group) {
            self.deleted = deleted
            self.other = other
        }

        /// 是否全部落盘。
        public var isClean: Bool { deleted.isClean && other.isClean }
    }

    /// 补写（启动时把待补写队列搬回 `execution.jsonl`）的结果。
    public struct DrainResult: Equatable, Sendable {
        /// 补写**没做成**的原因（`nil` = 补写成功，或本来就没东西可补）。
        public enum Failure: Equatable, Sendable {
            /// `execution.jsonl` 读不出来 ⇒ 无从判断「是不是已经补写过」
            /// ⇒ **本次不补写**（宁可留在队列里，也不重复补）。
            case logUnreadable
        }

        /// 本次补写进 `execution.jsonl` 的记录。
        public let recoveredRecords: [ExecutionRecord]
        /// 补写后**仍留在队列里**的条数（**恢复信息还在**，下次启动再试）。
        public let remainingCount: Int
        /// 队列里**解不开**的行数（内容损坏，已如实登记）。
        public let corruptLineCount: Int
        /// 补写没做成的原因。
        public let failure: Failure?

        public init(
            recoveredRecords: [ExecutionRecord] = [],
            remainingCount: Int = 0,
            corruptLineCount: Int = 0,
            failure: Failure? = nil
        ) {
            self.recoveredRecords = recoveredRecords
            self.remainingCount = remainingCount
            self.corruptLineCount = corruptLineCount
            self.failure = failure
        }

        public var recoveredCount: Int { recoveredRecords.count }

        /// 是否一切正常（队列空了，也没有解不开的行）。
        public var isClean: Bool {
            remainingCount == 0 && corruptLineCount == 0 && failure == nil
        }
    }

    /// 启动时读回的执行记录 + 补写结果。
    public struct LoadResult: Equatable, Sendable {
        /// `execution.jsonl` 的全部记录 + 本次补写进来的（按动作时刻升序）。
        public let records: [ExecutionRecord]
        /// 补写结果（供界面如实报告）。
        public let drain: DrainResult

        public init(records: [ExecutionRecord], drain: DrainResult) {
            self.records = records
            self.drain = drain
        }
    }

    // MARK: - 落盘

    /// 把一批执行记录写进 `execution.jsonl`（AC-18）。
    ///
    /// **写盘失败绝不静默**：
    /// - 写成功的 → `persisted`；
    /// - 写失败的 → 进待补写队列 → `queued`（**恢复信息保住**，下次启动补写）；
    /// - 连队列都写不进去的 → `lost`（**如实登记，不假装成功**）。
    @discardableResult
    public func persist(_ records: [ExecutionRecord], now: Date = Date()) -> PersistResult {
        var persisted: [ExecutionRecord] = []
        var unwritten: [ExecutionRecord] = []
        for record in records {
            do {
                try writer.append(record, kind: .execution, now: now)
                persisted.append(record)
            } catch {
                unwritten.append(record)
            }
        }

        // 写不进去的记录进待补写队列（**逐条**，一条失败不影响其余）。
        let outcomes = enqueue(unwritten)
        var queued: [ExecutionRecord] = []
        var lost: [ExecutionRecord] = []
        for (record, outcome) in zip(unwritten, outcomes) {
            switch outcome {
            case .queued: queued.append(record)
            case .failed: lost.append(record)
            }
        }

        let p = Self.split(persisted)
        let q = Self.split(queued)
        let l = Self.split(lost)
        return PersistResult(
            deleted: Group(persisted: p.deleted, queued: q.deleted, lost: l.deleted),
            other: Group(persisted: p.other, queued: q.other, lost: l.other)
        )
    }

    // MARK: - 读取与补写

    /// 启动时的一次性动作：**补写待补写队列 → 读回全部执行记录**。
    ///
    /// ## 为什么合成一次
    ///
    /// 补写的幂等判定要拿 `execution.jsonl` 的现有记录做对照，界面也要这份记录 ——
    /// **读一次，两处用**（大日志上读两遍是纯浪费）。
    public func loadAndDrain(now: Date = Date()) -> LoadResult {
        let entries = readPendingEntries()
        let pendingRecords = entries.compactMap { entry -> ExecutionRecord? in
            guard case .record(let record) = entry else { return nil }
            return record
        }
        let corruptLineCount = entries.count - pendingRecords.count

        // 队列里没有可补写的记录 ⇒ 只读一次 `execution.jsonl` 即可。
        guard !pendingRecords.isEmpty else {
            let existing = (try? writer.readRecords(ExecutionRecord.self, kind: .execution)) ?? []
            return LoadResult(
                records: Self.sorted(existing),
                drain: DrainResult(corruptLineCount: corruptLineCount)
            )
        }

        let existing: [ExecutionRecord]
        do {
            existing = try writer.readRecords(ExecutionRecord.self, kind: .execution)
        } catch {
            // 读不出来 ⇒ 无从判断「是不是已经补写过」⇒ **不补写**
            // （宁可留在队列里下次再试，也不重复补 —— 重复的举证链行会污染 M6 计量）。
            return LoadResult(
                records: [],
                drain: DrainResult(
                    remainingCount: pendingRecords.count,
                    corruptLineCount: corruptLineCount,
                    failure: .logUnreadable
                )
            )
        }

        var known = Set(existing.map(Self.identity))
        var recovered: [ExecutionRecord] = []
        var remaining: [PendingEntry] = []
        for entry in entries {
            guard case .record(let record) = entry else {
                // 解不开的行：**原样留在队列里**（它可能含恢复路径，不许悄悄丢掉）。
                remaining.append(entry)
                continue
            }
            if known.contains(Self.identity(record)) {
                // 已经补写过（上次补到一半崩了）⇒ 队列里的副本作废。
                continue
            }
            do {
                try writer.append(record, kind: .execution, now: now)
                known.insert(Self.identity(record))
                recovered.append(record)
            } catch {
                // 补不成的**留在队列里**，下次启动再试（**恢复信息不丢**）。
                remaining.append(entry)
            }
        }

        // 队列重写 = 只留「还没补成的」+ 解不开的行（失败也不丢：写不进去就还是原样）。
        let stillPending = remaining.compactMap { entry -> ExecutionRecord? in
            guard case .record(let record) = entry else { return nil }
            return record
        }
        try? rewritePending(remaining)

        return LoadResult(
            records: Self.sorted(existing + recovered),
            drain: DrainResult(
                recoveredRecords: recovered,
                remainingCount: stillPending.count,
                corruptLineCount: corruptLineCount
            )
        )
    }

    // MARK: - 待补写队列

    /// 队列里的一行（**解不开的行原样保留** —— 它可能含恢复路径）。
    private enum PendingEntry {
        case record(ExecutionRecord)
        case raw(Data)
    }

    /// 把记录并入待补写队列（**追加**，不覆盖 —— 队列里已有的记录不许丢）。
    private func enqueue(_ records: [ExecutionRecord]) -> [EnqueueOutcome] {
        guard !records.isEmpty else { return [] }
        let store = JSONLStore(url: pendingURL)
        return records.map { record in
            do {
                try store.append(record)
                return .queued
            } catch {
                return .failed
            }
        }
    }

    /// 读回队列的全部行（**解不开的行原样带回**）。
    private func readPendingEntries() -> [PendingEntry] {
        guard let lines = try? JSONLStore(url: pendingURL).rawLines() else { return [] }
        return lines.map { line in
            if let record = try? JSONLStore.decoder().decode(ExecutionRecord.self, from: line) {
                return .record(record)
            }
            return .raw(line)
        }
    }

    /// 重写队列（**原子替换** —— 先删后写会留半个文件，丢的是恢复路径）。
    private func rewritePending(_ entries: [PendingEntry]) throws {
        var payload = Data()
        for entry in entries {
            switch entry {
            case .record(let record):
                var line = try JSONLStore.encoder().encode(record)
                line.append(0x0A)
                payload.append(line)
            case .raw(let data):
                payload.append(data)
                payload.append(0x0A)
            }
        }
        try JSONLStore(url: pendingURL).replaceAllBytes(payload)
    }

    // MARK: - 身份

    /// 一条执行记录的身份（**幂等判定的唯一依据**）。
    ///
    /// 「候选 + 动作 + 动作时刻」三元组：
    /// - 候选（路径 + 创建时刻）区分「哪个文件」；
    /// - 动作区分「删了 / 恢复了 / 被拦下了」；
    /// - 动作时刻区分「同一个文件的第几次动作」。
    private struct Identity: Hashable, Sendable {
        let id: CandidateID
        let action: ExecutionAction
        let executedAt: Date
    }

    private static func identity(_ record: ExecutionRecord) -> Identity {
        Identity(id: record.id, action: record.action, executedAt: record.executedAt)
    }

    // MARK: - 分组

    /// 按动作把记录分成「删除类」与「其余」（**恢复信息只在删除类这一档**）。
    private static func split(
        _ records: [ExecutionRecord]
    ) -> (deleted: [ExecutionRecord], other: [ExecutionRecord]) {
        (
            records.filter { $0.action == .renameToTrash },
            records.filter { $0.action != .renameToTrash }
        )
    }

    /// 按动作时刻升序（文件顺序是 append 顺序，恢复动作会再追加同一候选的一行）。
    private static func sorted(_ records: [ExecutionRecord]) -> [ExecutionRecord] {
        records.sorted { $0.executedAt < $1.executedAt }
    }

    /// 入队结果。
    private enum EnqueueOutcome {
        case queued
        case failed
    }
}
