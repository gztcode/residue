import Foundation

// ============================================================
// Residue · 运行期偏好（`state/preferences.json`）
//
// ## 为什么单独一个文件，而不是塞进 state.residue
//
// `state.residue` 的 schema 已冻结（`schemaVersion` 变更要迁移，而迁移是
// §10.3 的高风险路径）。而这里的字段是**运行期偏好**，不是计量数据：
//
// - 它不进 M6 的「可回收字节」计量（M6 只管 records/ 与日志）
// - 它丢了不影响正确性（最坏情况是「已停止」显示成「未采集」）
// - 它不需要 CRC 段表那套保护（一份小 JSON，坏了就重来）
//
// 所以放独立文件比改冻结 schema 便宜得多，也不引入迁移风险。
// 这与 `state/schedule.json` 是同一个模式（那里存 `lastRun`）。
// ============================================================

/// 运行期偏好。
public struct Preferences: Codable, Sendable, Equatable {

    /// **是否曾经点亮过自动删除**。
    ///
    /// ## 为什么必须有这一位（AC-10 的直接要求）
    ///
    /// AC-10 的 Given 是「用户**曾**启用过自动删除」，When 是「用户关闭自动删除」，
    /// Then 是「四档状态逐一显示「已停止」」。
    ///
    /// 只有 `autoDeleteEnabled == false` 这一个布尔时，**「从未启用过」与
    /// 「曾启用后关闭」不可区分** —— 而这两种状态下界面该显示的东西不同：
    ///
    /// | 状态 | 四档状态位 | 为什么 |
    /// |---|---|---|
    /// | 从未启用 | 「未采集」 | 采集压根没开始过 |
    /// | 曾启用后关闭 | 「已停止」 | 采集开始过，现在被关了（AC-10 要的就是这个） |
    ///
    /// 把两者都显示成「已停止」会让新用户以为「我关了什么」，那是**说谎**。
    /// 把两者都显示成「未采集」则 AC-10 的判定**永远不可满足**。
    public var everEnabledAutoDelete: Bool

    /// **执行方式**（AC-03：默认「仅报告」）。
    ///
    /// AC-03 判定把「执行方式」列为四项默认值之一，且默认必须是**仅报告**——
    /// 这不是保守，是「首次启动不该有删除能力」的直接体现。
    public var executionMode: ExecutionMode

    /// **单次容量上限（字节）**（AC-03：可见可编辑）。
    ///
    /// 默认取 AC-15 的首次档：`min(5 GB, 来源 10%)` 里的绝对值那一半。
    public var capacityCapBytes: Int64

    /// **条目数上限**（AC-03：可见可编辑）。
    public var itemCap: Int

    /// **白名单**：用户明确保护的路径（AC-03）。
    ///
    /// 语义：**加入后 X 不再出现在新候选清单中**（AC-03 判定）。
    /// 这是用户**唯一的主动保护动作**——查必究在 B-1 里指出
    /// 「TC-009/010 白名单在冒烟集与回归集里双双为零」，
    /// 原因就是它此前在界面上根本没有落点。
    public var whitelist: [String]

    /// 上次保存时刻（排查用，不参与判定）。
    public var updatedAt: Date?

    public init(
        everEnabledAutoDelete: Bool = false,
        executionMode: ExecutionMode = .reportOnly,
        capacityCapBytes: Int64 = 5_000_000_000,
        itemCap: Int = 200,
        whitelist: [String] = [],
        updatedAt: Date? = nil
    ) {
        self.everEnabledAutoDelete = everEnabledAutoDelete
        self.executionMode = executionMode
        self.capacityCapBytes = capacityCapBytes
        self.itemCap = itemCap
        self.whitelist = whitelist
        self.updatedAt = updatedAt
    }
}

/// 执行方式（AC-03 四项默认值之一）。
///
/// **默认必须是 `.reportOnly`**：「首次启动就有删除能力」不是保守不保守的问题，
/// 是「用户还没表达过任何意图，产品凭什么删他的东西」。
public enum ExecutionMode: String, Codable, Sendable, CaseIterable {
    /// 仅报告：扫、判、出报告，**不动手**。
    case reportOnly = "report_only"
    /// 自动删除：到了定时执行点会真的 rename 到废纸篓。
    case autoDelete = "auto_delete"

    public var label: String {
        switch self {
        case .reportOnly: return L.pick("仅报告", "Report only")
        case .autoDelete: return L.pick("自动删除", "Auto-delete")
        }
    }
}

/// 偏好文件的读写。
public struct PreferencesStore: Sendable {

    public let fileURL: URL

    /// 默认位置：`<state 目录>/preferences.json`。
    public init(directory: URL? = nil) {
        let dir = directory ?? StateFile.defaultDirectory()
        self.fileURL = dir.appendingPathComponent("preferences.json")
    }

    /// 读取。文件不存在 / 解析失败 → 返回默认值（**不抛错**）。
    ///
    /// 为什么不抛：偏好丢失只影响「已停止 / 未采集」的显示精度，
    /// 而抛出去会让整个 App 起不来。**为了一个显示精度让产品打不开，不值得。**
    public func load() -> Preferences {
        guard let data = try? Data(contentsOf: fileURL),
              let prefs = try? Self.decoder().decode(Preferences.self, from: data) else {
            return Preferences()
        }
        return prefs
    }

    /// **编码器与解码器必须成对**（`dateEncodingStrategy` 不对称 = 静默 bug）。
    ///
    /// ## 这里曾经有个真 bug，而且完全静默
    ///
    /// 第一版：`save` 用 `JSONEncoder` + `.iso8601`，`load` 用**默认策略**
    /// （默认期望 `Double` 时间戳）。于是：
    /// - `save` 返回 `true`（写入成功）
    /// - `load` **永远解码失败** → 永远返回默认值
    /// - **没有任何报错**
    ///
    /// 后果：偏好**永远存不住** —— 「曾启用过自动删除」每次启动都丢，
    /// 四档状态永远显示「未采集」，AC-10 的「已停止」在真机上永远不出现。
    ///
    /// 抓到它的路径：单测 `testPreferencesRoundTrip` 在「写入后回读」这步失败。
    /// **不是读代码看出来的** —— `save` 与 `load` 分开看都完全正确。
    ///
    /// 修法：两边共用同一份策略配置（下面两个私有工厂方法），
    /// 这样将来加字段时不可能只改一边。
    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// 写入。失败**不抛**（同上理由），但通过返回值如实报告。
    @discardableResult
    public func save(_ prefs: Preferences) -> Bool {
        var copy = prefs
        copy.updatedAt = Date()
        guard let data = try? Self.encoder().encode(copy) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}


// MARK: - AC-10 的采集开关判定（唯一实现处）

/// 「是否允许采集」的判定。
///
/// ## 为什么单独抽出来放 Core
///
/// 它看起来只是一行布尔表达式，但**三个状态各自对应契约里不同的要求**，
/// 而放在编排层（`AppModel`）就无法被单测钉住 —— 而这条判据一旦写错，
/// 后果是**产品锁死**（观察期不采集 → 永远攒不够样本 → 永远点不亮）。
///
/// | 状态 | 采集 | 依据 |
/// |---|---|---|
/// | 从未启用过（观察期中） | **允许** | 否则永远达不到 AC-08 的点亮条件 |
/// | 已启用 | 允许 | 正常路径 |
/// | 曾启用、现已关闭 | **不允** | AC-10 的 Then：关闭后定时任务不跑采集、仅按 N3 保留配置 |
public enum CollectionPolicy {

    /// - Parameters:
    ///   - autoDeleteEnabled: 自动删除当前是否开启。
    ///   - everEnabledAutoDelete: 是否**曾经**开启过。
    public static func isCollectionAllowed(
        autoDeleteEnabled: Bool,
        everEnabledAutoDelete: Bool
    ) -> Bool {
        // 已启用 → 采集
        if autoDeleteEnabled { return true }
        // 从未启用 → 还在观察期，必须采集（否则永远点不亮）
        if !everEnabledAutoDelete { return true }
        // 曾启用、现已关闭 → **停采集**（AC-10）
        return false
    }

    /// 关闭自动删除后是否**应当**处于「已停止」（四档状态位）。
    ///
    /// 与 `isCollectionAllowed` 的反面**不等价**：
    /// 「从未启用」是「未采集」（采集没开始过），
    /// 「曾启用后关闭」才是「已停止」（采集开始过、被停了）。
    /// 把两者混成一个布尔，界面就会对新用户说谎「你把它停了」。
    public static func shouldShowStopped(
        autoDeleteEnabled: Bool,
        everEnabledAutoDelete: Bool
    ) -> Bool {
        everEnabledAutoDelete && !autoDeleteEnabled
    }
}
