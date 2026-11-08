import Foundation

// ============================================================
// Residue · 记录落盘（R2 §5.2 / §5.3 / §5.4 / IF-10）
//
// ## 三类记录，全部落 `records/` 目录下的 `.jsonl`
//   - `evidence.jsonl`  举证链（V4 八顶层字段）**计入** N7 计量
//   - `execution.jsonl` 执行记录（P3）**计入**计量
//   - `scan.jsonl`      扫描日志（含 `upstreamCommands` / `diagnostics`）**计入**计量、**不豁免**
//
// ## 两条「不可妥协」
//   1. **未落盘即视为「无法证明」，验收按不通过处理**（§5.4）。
//      `upstreamCommands` 是 AC-19 的唯一可判载体；`diagnostics` 是「删错了」类事故的
//      唯一支持通道。所以本 writer 的 append **必须真写盘并 fsync**，
//      不允许「先攒内存、退出时统一写」——那次退出可能永远不来。
//   2. **`O_APPEND` 追加**（§5.1 决策）：并发写不同记录不互相覆盖，
//      不需要读-改-写整文件。
//
// ## 不计入 N7 计量的东西（别放错目录）
//   `state.residue`（M4 载体）/ `state/` 下的运行期临时态
//   （`checkpoints.json` / `journal.jsonl` / `migrating.json`）
//   —— 这些**不**在 `records/` 下，故天然不计入 M6 的「可回收字节」。
// ============================================================

/// `scan.jsonl` 的一行（§5.4）。
public struct ScanLogRecord: Codable, Sendable, Equatable {
    /// 扫描开始时刻。
    public var at: Date
    /// 扫描模式。
    public var mode: String
    /// 本次扫描的来源列表（`Source.rawValue`）。
    public var sources: [String]
    /// 遍历到的**叶子条目数**（不含目录）。
    public var filesScanned: Int
    /// 扫描涉及的字节数。
    public var bytesScanned: Int64
    /// 耗时（毫秒）。
    public var durationMs: Int
    /// 中止原因（`nil` = 正常完成）。
    public var aborted: String?
    /// 断点是否已保存。
    public var breakpointSaved: Bool
    /// `DT_UNKNOWN` 退回 `lstat` 的次数。
    public var unknownCount: Int
    /// **上游命令调用记录**（AC-19 的唯一可判载体）。
    ///
    /// **每次上游调用必须落一行**；未落盘即「无法证明」，验收按不通过。
    public var upstreamCommands: [UpstreamCommand]
    /// 诊断回显（「删错了」类事故的唯一支持通道）。
    public var diagnostics: Diagnostics

    /// `scan.jsonl` 的 `diagnostics` 段（§5.4）。
    ///
    /// **全是既有状态的回显**，不新增采集、不产生跨机聚合（SRE 第 10 条 / N7）。
    public struct Diagnostics: Codable, Sendable, Equatable {
        /// 同 uid 进程枚举是否失败（`degraded` 只在同 uid 失败时为 true）。
        public var degraded: Bool
        /// L0 覆盖信息（诊断用，不上界面）。
        public var coverage: Coverage
        /// 本轮被判「有活引用」的候选数（`P_now` 规模）。
        public var pNowCount: Int
        /// `F` 位图的置位数。
        public var fSetBits: Int
        /// `C_done` 的计数。
        public var doneCount: Int
        /// 累计误判数 `a`。
        public var a: Int
        /// 本轮 L0 检查次数 `b`。
        public var b: Int
        /// 轮次。
        public var round: Int
        /// 本轮计数日。
        public var countedDays: Int
        /// **内容读取次数**（AC-07 的判据载体）。
        ///
        /// 扫描阶段**只读元数据、不读内容** → 该值**恒为 0**。
        /// 非 0 即说明实现越界读了内容 → AC-07 由恒真变为**可证伪**。
        public var contentReads: Int

        public struct Coverage: Codable, Sendable, Equatable {
            public var sameUIDTotal: Int
            public var sameUIDRead: Int
            public var statOtherUID: Int

            public init(sameUIDTotal: Int = 0, sameUIDRead: Int = 0, statOtherUID: Int = 0) {
                self.sameUIDTotal = sameUIDTotal
                self.sameUIDRead = sameUIDRead
                self.statOtherUID = statOtherUID
            }
        }

        public init(
            degraded: Bool = false,
            coverage: Coverage = Coverage(),
            pNowCount: Int = 0,
            fSetBits: Int = 0,
            doneCount: Int = 0,
            a: Int = 0,
            b: Int = 0,
            round: Int = 1,
            countedDays: Int = 0,
            contentReads: Int = 0
        ) {
            self.degraded = degraded
            self.coverage = coverage
            self.pNowCount = pNowCount
            self.fSetBits = fSetBits
            self.doneCount = doneCount
            self.a = a
            self.b = b
            self.round = round
            self.countedDays = countedDays
            self.contentReads = contentReads
        }
    }

    public init(
        at: Date,
        mode: String,
        sources: [String],
        filesScanned: Int,
        bytesScanned: Int64,
        durationMs: Int,
        aborted: String? = nil,
        breakpointSaved: Bool = false,
        unknownCount: Int = 0,
        upstreamCommands: [UpstreamCommand] = [],
        diagnostics: Diagnostics = Diagnostics()
    ) {
        self.at = at
        self.mode = mode
        self.sources = sources
        self.filesScanned = filesScanned
        self.bytesScanned = bytesScanned
        self.durationMs = durationMs
        self.aborted = aborted
        self.breakpointSaved = breakpointSaved
        self.unknownCount = unknownCount
        self.upstreamCommands = upstreamCommands
        self.diagnostics = diagnostics
    }
}

/// 记录写入器（IF-10）。
///
/// **落点**：`~/Library/Application Support/Residue/records/`
/// 该目录**是** N7 的 `.jsonl` 记录目录 → **计入 M6 的「可回收字节」**。
public struct RecordWriter: Sendable {

    /// 记录目录（N7 计量范围内）。
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? RecordWriter.defaultRecordsDirectory()
    }

    /// 默认记录目录。
    ///
    /// 与应用状态目录同根（`.../Residue/`），但**单独一层 `records/`**——
    /// 这样 M6 的「目录内全部 `.jsonl`」正好只圈住记录，
    /// 而 `state.residue` 与 `state/` 天然在外（契约 M4 / §5.5）。
    public static func defaultRecordsDirectory() -> URL {
        StateFile.defaultDirectory().appendingPathComponent("records", isDirectory: true)
    }

    // MARK: - 文件名

    public enum Kind: String, Sendable, CaseIterable {
        /// 举证链（V4 八顶层字段），**计入**计量。
        case evidence = "evidence.jsonl"
        /// 执行记录（P3），**计入**计量。
        case execution = "execution.jsonl"
        /// 扫描日志，**计入**计量、**不豁免**。
        case scan = "scan.jsonl"

        public var fileName: String { rawValue }
    }

    private func url(for kind: Kind) -> URL {
        directory.appendingPathComponent(kind.fileName)
    }

    // MARK: - 写入

    /// 追加一行（`O_APPEND` + `fsync`）。
    ///
    /// **必须真落盘**：`upstreamCommands` / `diagnostics` 未落盘即「无法证明」。
    /// 故本方法在 `write` 后显式 `synchronize()`，不接受「攒内存最后统一写」。
    public func append<T: Encodable>(_ value: T, kind: Kind, now: Date = Date()) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = url(for: kind)

        let encoder = JSONEncoder()
        // **记录时刻只有一个来源 = 该行写入时刻**（M6 判据）。
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(value)
        line.append(0x0A)   // '\n' —— jsonl 一行一条

        if !fm.fileExists(atPath: target.path) {
            fm.createFile(atPath: target.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        // 落盘（不是可选优化：未落盘 = 无法证明）
        try handle.synchronize()
    }

    /// 追加一条扫描日志。
    public func appendScan(_ record: ScanLogRecord) throws {
        try append(record, kind: .scan, now: record.at)
    }

    // MARK: - 读取（供报告 / 自检）

    /// 读某类记录的全部行（解码为字典，便于报告层按字段取）。
    ///
    /// **只用于本机读取**；不外发（N7 零外发）。
    public func readLines(kind: Kind) throws -> [[String: Any]] {
        let target = url(for: kind)
        guard FileManager.default.fileExists(atPath: target.path) else { return [] }
        let data = try Data(contentsOf: target)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [[String: Any]] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            out.append(obj)
        }
        return out
    }

    /// 记录目录内全部 `.jsonl` 的字节合计（M6 的「可回收字节」的**被减项基础**）。
    ///
    /// ⚠️ 这只是**总字节**；`可回收字节 = 总字节 − 14 日内执行记录字节`
    /// 由 `Retention` 计算（M6 的唯一式在那个文件里，此处不另立公式）。
    public func totalJSONLBytes() throws -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return 0 }
        var total: Int64 = 0
        let items = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        for item in items where item.pathExtension == "jsonl" {
            let size = (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }
}
