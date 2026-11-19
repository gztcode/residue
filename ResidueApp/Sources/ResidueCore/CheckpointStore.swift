import Foundation

// ============================================================
// Residue · 扫描断点的落盘（`state/checkpoints.json`）
//
// 契约落点：R2 v1.8 §5.5（断点与 journal）· §6 `E-106` · PRD AC-20 / N1。
//
// ## 为什么必须有这个文件
//
// `ScanEngine` 从第一版起就能**生产**断点（中断时返回 `Checkpoint`），
// 引擎侧的名字集合机制、续扫三项一致都已有测试覆盖。
// 但**运行路径上断点从来没落过盘**：
//
//   · `AppModel.runScan` 把 `result.checkpoint` 直接丢弃
//   · 扫描日志里 `breakpointSaved: false` 是**写死的字面量**
//   · `E-106`（断点一致性校验失败）在源码里**没有任何触发路径**
//
// 于是 AC-20 的「重启后可续扫」只剩引擎单测在撑 —— 而**进程一重启，
// 断点就不存在了**。用户取消/超时/低电量中断一次，13 秒的扫描要从头再来。
//
// ## 落点与计量（R2 §5.5 / §10.3）
//   · `state/checkpoints.json` —— **不计入 N7 计量**（运行期临时态）
//   · **计入 N7 的「一键清除」范围**（含候选路径，漏清即留用户路径副本）
// ============================================================

/// 断点的读写（`state/checkpoints.json`）。
///
/// 落盘形态是**来源 → 断点**的映射（文件名是复数）：一次全量扫描会遍历
/// 每个来源各有一个 `Checkpoint`（`Source.allCases`），中断可能发生在任意一个之中。
public struct CheckpointStore: Sendable {

    /// `state/` 目录（**不是** N7 的 `.jsonl` 记录目录）。
    public let directory: URL
    public let fileURL: URL

    public init(directory: URL? = nil) {
        let dir = directory
            ?? StateFile.defaultDirectory().appendingPathComponent("state", isDirectory: true)
        self.directory = dir
        self.fileURL = dir.appendingPathComponent("checkpoints.json")
    }

    // MARK: - 落盘形态

    /// `checkpoints.json` 的内容。
    public struct Payload: Codable, Sendable, Equatable {
        /// 断点格式版本。**版本不符即不可用**（不得「尽力解析」——
        /// 字段语义变了还硬读，续扫结果会静默少算）。
        public var schemaVersion: Int
        /// 来源（`Source.rawValue`）→ 该来源的断点。
        public var checkpoints: [String: ScanEngine.Checkpoint]

        public init(
            schemaVersion: Int = CheckpointStore.currentSchemaVersion,
            checkpoints: [String: ScanEngine.Checkpoint] = [:]
        ) {
            self.schemaVersion = schemaVersion
            self.checkpoints = checkpoints
        }
    }

    public static let currentSchemaVersion = 1

    // MARK: - 读取

    /// 读取结果。
    public enum LoadOutcome: Sendable {
        /// 没有断点（首次扫描，或上次已正常完成）。
        case none
        /// 有可用断点。
        case usable([String: ScanEngine.Checkpoint])
        /// 断点**不可信** → `E-106`，必须全量重扫。
        case corrupt(reason: String)

        /// 对应的诊断码（`nil` = 不是错误）。
        public var diagnostic: DiagnosticCode? {
            switch self {
            case .corrupt: return .e106
            case .none, .usable: return nil
            }
        }
    }

    /// 读断点。**不抛错** —— 所有失败都以 `LoadOutcome` 表达。
    ///
    /// ## `E-106` 的判定口径（**这是对契约的解释，不是契约原文**）
    ///
    /// 契约（R2 §5.5）写的是「续扫结束时对**文件数 / 字节数 / 候选清单**三项
    /// 做一致性校验，不符 → `E-106` 要求全量重扫」。
    ///
    /// 运行期**做不强**那条的字面版本：要与「未中断扫描」比对，
    /// 而那个结果根本不存在（扫描没跑完）。AC-20 那份端到端断言
    /// （续扫结果 ≡ 未中断结果）只能由测试造出基线来验 ——
    /// 引擎侧已由 `testResumeOnRealFileSystemProducesIdenticalThreeItems` 覆盖。
    ///
    /// 运行期能守、且真正有用的是**「断点本身可不可信」**：
    /// 断点是「某一时刻的文件系统快照」，读不出来 / 格式对不上 / 落盘时坏了，
    /// 拿它续扫就会**静默少算候选**（`T` 偏小 → 门槛判据建立在错数上）。
    /// 这三条都不需要全量 IO，代价可控。
    public func load() -> LoadOutcome {
        let fm = FileManager.default

        guard fm.fileExists(atPath: fileURL.path) else { return .none }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return .corrupt(reason: "断点文件不可读：\(error.localizedDescription)")
        }

        let payload: Payload
        do {
            payload = try Self.decoder().decode(Payload.self, from: data)
        } catch {
            // 解不出来 = 内容已坏（写一半断电 / 磁盘损坏 / 被手改）。
            // **不「尽力解析」**：断点字段错位的后果是续扫漏条目，且完全静默。
            return .corrupt(reason: "断点内容无法解析：\(error.localizedDescription)")
        }

        guard payload.schemaVersion == Self.currentSchemaVersion else {
            return .corrupt(
                reason: "断点格式版本 \(payload.schemaVersion) ≠ 当前 \(Self.currentSchemaVersion)"
            )
        }

        // 空映射 = 没有可续的断点（与「文件不存在」同义）
        guard !payload.checkpoints.isEmpty else { return .none }
        return .usable(payload.checkpoints)
    }

    // MARK: - 写入

    public enum WriteError: Error, Equatable, Sendable {
        /// 写后回读与写入值不符（短写 / 损坏）。
        case writeVerifyFailed(detail: String)
    }

    /// 原子写断点，并**立刻回读自证**。
    ///
    /// 写后回读是必要的：断点是「续扫的依据」，一份写坏了的断点会让续扫
    /// **静默**产出错数；而错数直接进 `T` / `K` → 门槛判据被污染。
    /// 宁可这次不落盘（下次从全量开始），也不留一份不可信的续扫依据。
    public func save(_ checkpoints: [String: ScanEngine.Checkpoint]) throws {
        guard !checkpoints.isEmpty else {
            clear()
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let payload = Payload(checkpoints: checkpoints)
        let data = try Self.encoder().encode(payload)
        try data.write(to: fileURL, options: [.atomic])

        // 回读自证（三项：候选数 / 已计条目 / 字节数 —— 与 §5.5 的三项同源）
        let readBack = try Self.decoder().decode(Payload.self, from: try Data(contentsOf: fileURL))
        guard readBack == payload else {
            throw WriteError.writeVerifyFailed(detail: "回读内容与写入值不符")
        }
    }

    /// 清除断点（正常完成后调用 —— 断点只在「还有未扫完的部分」时有意义）。
    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - 编解码

    /// ⚠️ `dateEncodingStrategy` / `dateDecodingStrategy` **必须成对**。
    /// 不对称 → `save` 成功、`load` 永远失败，而且**完全没有报错**
    /// （本仓库已在偏好文件上踩过一次，见 CLAUDE.md §七 第 6 条）。
    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
