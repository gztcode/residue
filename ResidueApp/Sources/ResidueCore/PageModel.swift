import Foundation

// ============================================================
// Residue · 页面模型（**在 Core，不在 App**）
//
// ## 为什么它在 Core 而不在 App 层
// R2 §3 定了「界面禁止任何算术」（L4）。但如果页面模型和它的构造逻辑都住在
// App target，**测试够不到它**——`ResidueCoreTests` 只依赖 `ResidueCore`。
// 那样「禁止算术」就只能靠 review 看，不能靠单测钉。
//
// 所以：**页面模型 + 构造器在 Core（可单测），只有视图在 App。**
// 这条搬迁本身就是「把纪律变成可验证约束」的一部分。
//
// ## 硬约束
// 每个字段都是 `SemanticSlot`（或纯文案）。数值必须在进入模型**之前**
// 由 `Metrics` / `GateEvaluator` 算好——本文件不做任何算术。
// ============================================================

// MARK: - 页标识

/// 七页（顺序 = 导航顺序，承载指定见 PRD §6 / 视觉基线 §五）。
public enum Page: Int, CaseIterable, Identifiable, Sendable {
    case overview = 0        // ① 只读存储总览
    case environments = 1    // ② 环境明细与候选清单
    case policy = 2          // ③ 清理策略配置
    case privacy = 3         // ④ 授权与隐私
    case report = 4          // ⑤ 影子观察期报告
    case confirm = 5         // ⑥ 确认清理（抽屉态）
    case evidence = 6        // ⑦ 举证链 / 执行日志

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .overview: return L.pick("存储总览", "Storage overview")
        case .environments: return L.pick("环境与候选", "Environments & candidates")
        case .policy: return L.pick("清理策略", "Cleanup policy")
        case .privacy: return L.pick("授权与隐私", "Permissions & privacy")
        case .report: return L.pick("观察期报告", "Observation report")
        case .confirm: return L.pick("确认清理", "Confirm cleanup")
        case .evidence: return L.pick("举证链与日志", "Evidence & logs")
        }
    }

    /// 侧栏用的短标题。
    ///
    /// 页头可以放全称（`title`），但侧栏只有 168/196 pt：英文全称会截成
    /// 「Environments & can…」。导航项的作用是**找得到**，不是把话说全。
    public var navTitle: String {
        switch self {
        case .environments: return L.pick("环境与候选", "Environments")
        case .privacy: return L.pick("授权与隐私", "Permissions")
        default: return title
        }
    }

    public var symbolName: String {
        switch self {
        case .overview: return "internaldrive"
        case .environments: return "list.bullet.rectangle"
        case .policy: return "slider.horizontal.3"
        case .privacy: return "lock.shield"
        case .report: return "chart.bar.doc.horizontal"
        case .confirm: return "trash"
        case .evidence: return "doc.text.magnifyingglass"
        }
    }
}

// MARK: - 页面模型

/// 七页的视图模型（**纯数据，无 SwiftUI 依赖**）。
public struct PageModel: Sendable {
    /// 是否处于只读态（数据由更高版本创建）。
    public var readOnly: Bool = false
    /// **扫描进度**（`nil` = 不在扫描）。
    ///
    /// ## 为什么取代 `loading` + `loadingMessage`（CR-037 §3.4）
    ///
    /// 旧的两个字段是**并列的事实源**（一个说「在加载」、一个说「加载到哪儿了」）
    /// ⇒ 必然出现「`loading` 为真但 `loadingMessage` 是旧的」这类自相矛盾状态。
    ///
    /// 现在**只有这一个载体**：`nil` 表示不在扫描；
    /// 在扫描时它同时携带**弧长**（`fraction`）与**文案**（`displayText`）。
    public var scanProgress: ScanProgress? = nil

    /// ① 页来源区块（每来源一块）。
    public var overviewBlocks: [OverviewBlock] = []
    /// ① 页：**全部来源占用总量**（字节）。
    ///
    /// 原首屏只有各来源各自数额的卡，**没有「一共占了多少」** —— 用户要自己心算。
    /// 而「我到底能被腾出多少空间」正是这个产品最该先回答的问题。
    public var totalFootprintBytes: SemanticSlot = .metric(0, unit: .bytes)
    /// ① 页：**是否还没有任何扫描数据**（决定显示空态还是数据）。
    ///
    /// 原先 `overviewBlocks` 恒为全部来源块数（`Source.allCases.map`）→ 空态分支
    /// **在真实产品里不可达**，首启看到的是七张 `0 B` 卡 + 一串 0 ——
    /// 既不告诉用户「你还没扫过」，也不给「开始扫描」的入口。
    public var isFirstRunEmpty: Bool = true
    /// ① 页状态条。
    public var statusSlot: SemanticSlot?

    /// **最近一次清理的结果反馈**（`nil` = 本次会话还没执行过）。
    ///
    /// 原实现执行完只更新 `lastExecutionAt`，界面上**什么都不变** ——
    /// 用户点了确认，回到原样，不知道删了几条、有没有失败、要不要处理。
    /// 那是「点了没反应」的一类，比报错更让人困惑。
    public var lastExecutionNotice: ExecutionNotice?

    /// 一次清理的结果摘要（纯数据，文案在 Core 拼好 —— 界面不做算术）。
    public struct ExecutionNotice: Equatable, Sendable {
        /// 实际移入废纸篓的条目数。
        public let deletedCount: Int
        /// 实际腾出的字节数。
        public let deletedBytes: Int64
        /// 因上限顺延的条目数。
        public let deferredCount: Int
        /// 失败条目数（执行期错误）。
        public let failedCount: Int
        /// 被二次检查 / 范围守卫拦下的条目数。
        public let blockedCount: Int

        public init(
            deletedCount: Int,
            deletedBytes: Int64,
            deferredCount: Int,
            failedCount: Int,
            blockedCount: Int
        ) {
            self.deletedCount = deletedCount
            self.deletedBytes = deletedBytes
            self.deferredCount = deferredCount
            self.failedCount = failedCount
            self.blockedCount = blockedCount
        }

        /// 是否什么都没做（用户最需要知道的那种「没反应」）。
        public var didNothing: Bool { deletedCount == 0 }

        /// 摘要文案（**唯一实现处**）。
        public var summary: String {
            if didNothing {
                if blockedCount > 0 {
                    return L.pick(
                        "本次没有删除任何条目：\(blockedCount) 条被执行前检查拦下（文件已变化或正在被使用）。",
                        "Nothing was deleted: \(blockedCount) item(s) were stopped by the pre-execution check (changed or in use)."
                    )
                }
                return L.pick(
                    "本次没有条目可删（可能都被上限顺延，或候选已不存在）。",
                    "Nothing to delete this time (deferred by limits, or candidates no longer exist)."
                )
            }
            var parts = [
                L.pick(
                    "已移入废纸篓 \(deletedCount) 条，共 \(MetricUnit.formatBytes(Int(deletedBytes)))",
                    "Moved \(deletedCount) item(s) to Trash, \(MetricUnit.formatBytes(Int(deletedBytes))) total"
                )
            ]
            if deferredCount > 0 {
                parts.append(L.pick("顺延 \(deferredCount) 条", "\(deferredCount) deferred"))
            }
            if blockedCount > 0 {
                parts.append(L.pick("拦下 \(blockedCount) 条", "\(blockedCount) blocked"))
            }
            if failedCount > 0 {
                parts.append(L.pick("失败 \(failedCount) 条", "\(failedCount) failed"))
            }
            return parts.joined(separator: " · ")
        }
    }

    /// ② 页候选行。
    public var candidateRows: [CandidateRow] = []
    /// ② 页当前页码（0 起）与总页数。
    public var pageIndex: Int = 0
    public var pageCount: Int = 1

    /// ③ 页：自动删除开关当前是否处于「已启用」。
    public var autoDeleteEnabled: Bool = false
    /// ③ 页：开关是否可点亮（AC-08 组 B 的门槛是否全过）。
    ///
    /// **不可点亮时开关必须 disabled**——否则用户能点，但点了不生效，
    /// 这比「不能点」更糟（AC-08 组 B 的全部意义就是「未达线不得点亮」）。
    public var canLightUp: Bool = false

    /// ③ 页：未达项区的**态**（CR-036）。
    ///
    /// 四态：`.rows`（有未达项，**一项一行**）/ `.none`（确无未达项）/
    /// `.emptyDomain`（**没有可判定的东西**）/ `.rows`（从未扫描 ⇒ 保留全局项）。
    ///
    /// ⚠️ **四态里的 `.rows` 有两种来源**，靠 `.none` / `.emptyDomain` 区分「空」的两种含义。
    public var unmetSection: UnmetSection = .rows([])
    /// ③ 页：未达项（**派生** —— 真值在 `unmetSection`）。
    ///
    /// 保留为派生属性 ⇒ 既有断言与调用点一行不动。
    /// 空数组 = 无未达项行可列（`.none` / `.emptyDomain`）。
    public var unmetNotices: [SemanticSlot] {
        if case .rows(let slots) = unmetSection { return slots }
        return []
    }
    /// ③ 页：剩余天数（`.duration`，`nil` → 「—」）。
    public var remainingDays: SemanticSlot = .duration(days: nil)
    /// **只读态的成因**（`nil` = 非只读）。
    ///
    /// 两种只读必须能区分：版本降级（`E-301`）与权限降级（`E-501`）。
    /// 界面据此显示不同的成因文案与不同的可执行动作。
    public var readOnlyReason: String?

    /// 渲染用：顶部错误条文案（产品路径由 `AppModel.errorMessage` 提供）。
    public var errorMessageForRender: String?

    /// ① 页：**「确定可释放（L1）」**（AC-02）。
    ///
    /// 由 T1 本地引用图可达性等**确定性**判定生成。
    /// 契约边界：**仅用于生成 / 缩小候选，不构成删除的正面授权**（CR-002 硬约束）。
    public var l1Confirmed: SemanticSlot = .metric(0, unit: .items)
    /// ① 页：**「推断可释放（L2）」**（AC-02）。
    ///
    /// **带「推断 · 不作为删除依据」标识**（下方位），且**不并入可删除量**。
    /// L2 只有否决权、无许可权（决策 ⑦）。
    public var l2Inferred: SemanticSlot = .metric(0, unit: .items)
    /// ① 页：**L2 的标识文案**（AC-02 判定要求「非空」）。
    public var l2Label: String = L.pick("推断 · 不作为删除依据", "Inferred · not a basis for deletion")
    /// ① 页：**「可删除量」独立展示元素**，其值 = L1 值（AC-02 判定）。
    ///
    /// 为什么单独一个字段而不是直接复用 `l1Confirmed`：
    /// AC-02 的判定是「**这三个数值可分别读出**」，
    /// 且要能验证「向 L2 注入非零值后可删除量不变」（排除 A=A 永真）。
    /// 共用一个字段会让那条断言在类型层面就无法表达。
    public var deletableAmount: SemanticSlot = .metric(0, unit: .items)

    /// ③ 页：**执行方式**（AC-03 四项之一，默认「仅报告」）。
    public var executionModeLabel: String = ExecutionMode.reportOnly.label
    /// ③ 页：**单次容量上限**（AC-03：可见可编辑）。
    public var capacityCapSlot: SemanticSlot = .metric(5_000_000_000, unit: .bytes)
    /// ③ 页：**条目数上限**（AC-03：可见可编辑）。
    public var itemCapSlot: SemanticSlot = .metric(200, unit: .items)
    /// ③ 页：**白名单**（AC-03；用户唯一的主动保护动作）。
    public var whitelist: [String] = []
    /// ③ 页：是否有白名单条目（决定显示列表还是空态）。
    public var hasWhitelist: Bool { !whitelist.isEmpty }

    /// ③ 页：定时任务状态（登录项四态，ADR-02）。
    ///
    /// **非 `.enabled` 时必须显示对应文案，且不得显示「已启用」**——
    /// 「登录项被关」显示成「已启用」是本产品最不能犯的谎（ADR-02 代价 ①）。
    public var scheduledTaskSlot: SemanticSlot?
    /// ③ 页：登录项是否需要用户去系统设置允许（决定是否给按钮）。
    public var needsLoginItemApproval: Bool = false
    /// ③ 页：登录项是否处于「未注册」态（决定是否给「设为登录项」按钮）。
    ///
    /// 与 `needsLoginItemApproval` 平行：一个是 `.requiresApproval` 的动作，
    /// 一个是 `.notRegistered` 的动作。两者互斥，都不会同时为真。
    public var canRegisterLoginItem: Bool = false

    /// 页面顶部位置告警（Translocation：从 .dmg 直接运行 → 登录项会失效）。
    public var locationWarning: String?

    /// ③ 页：清理策略参数区（第一个语义位）。
    public var policySlots: [(String, SemanticSlot)] = []
    /// ③ 页：规则版本区（**第二个、与策略参数不重叠的语义位**）。
    public var ruleVersionSlots: [(String, SemanticSlot)] = []

    /// ④ 页：采集范围说明。
    public var collectionScopeNotice: String = ""

    /// ④ 页：**四档采集与授权**（AC-10 状态位 / AC-11 独立授权 / AC-14 受阻）。
    ///
    /// 原来 ④ 页只有两段说明和一个清除按钮，导致 AC-10 / AC-11 / AC-14
    /// **三条 AC 在界面上没有任何落点**（R1.5 第 1 轮 B-05/B-09 阻塞项）。
    public var collectionTiers: [CollectionTier] = []
    /// ④ 页：是否显示「一键清除」。
    public var canClearLogs: Bool = true

    /// ⑤ 页矩阵行（**七项**）。
    public var reportRows: [ReportRow] = []
    /// ⑤ 页页级状态。
    public var pageLevelSlot: SemanticSlot?
    /// ⑤ 页「上一轮」行（**存在上一轮结算记录时非 nil**）。
    public var previousRoundSlot: SemanticSlot?
    /// ⑤ 页：报告是否已产出（未产出 → 结论列取「本轮未结算」）。
    public var reportProduced: Bool = false

    /// ⑥ 页：本次将删除的条目数与字节。
    public var confirmItemCount: SemanticSlot = .metric(0, unit: .items)
    public var confirmBytes: SemanticSlot = .metric(0, unit: .bytes)

    /// ⑦ 页：执行记录行。
    public var evidenceRows: [EvidenceRow] = []

    /// ⑦ 页：**举证链八字段**（AC-18：8 字段完整率 100%，空白为 0）。
    ///
    /// 原设计没有举证详情入口，AC-18 因此无落点（R1.5 B-14）。
    public var evidenceFields: [(String, SemanticSlot)] = []

    /// ⑦ 页：**上游命令的调用与执行次数**（AC-19）。
    ///
    /// 原设计没有这块，AC-19 的全称命题在界面上不可见（R1.5 B-15）。
    public var upstreamCommands: [UpstreamCommandRow] = []

    /// ⑦ 页：**本次扫描各来源的项数 / 体积 / 耗时**（CR-043，台账 P2-1）。
    ///
    /// 只在上一次扫描有逐来源统计时非空（本次没扫过 ⇒ 空，**不编造 0**）。
    /// 顺序由 `SourceScanStats.make` 定（耗时降序），界面不再排序。
    public var sourceScanRows: [SourceScanRow] = []

    /// ⑥ 页：**顺延条目数**（AC-15：顺延条目数 = 候选总数 − 实际删除条目数）。
    public var deferredCountSlot: SemanticSlot = .metric(0, unit: .items)

    public init() {}
}

// MARK: - 上游命令行（AC-19）

/// 一条上游命令的调用 / 执行统计。
///
/// **为什么必须分两个数**：AC-19 判的是「直接删文件的上游命令**出现**次数 = 0」。
/// 而被白名单拒掉的调用**从未执行**——若把它计成「1 次」，用户会看到
/// 「uv cache clean：1 次」，误以为产品真的执行了删除命令。
/// 事实是：**我们主动拦住了它**。把「试图调用」与「实际执行」混成一个数，
/// 会让「守住了」看起来像「违规了」。
public struct UpstreamCommandRow: Identifiable, Sendable {
    /// 稳定身份 = 命令串。
    public var id: String { command }
    public let command: String
    /// 调用次数（含被拒的尝试）。
    public let invoked: SemanticSlot
    /// **实际执行次数**（AC-19 判的就是这个 = 0）。
    public let executed: SemanticSlot

    public init(command: String, invoked: SemanticSlot, executed: SemanticSlot) {
        self.command = command
        self.invoked = invoked
        self.executed = executed
    }
}

// MARK: - 逐来源扫描统计（CR-043）

/// 「本次扫描 · 各来源」一行（**全部是已算好的槽位**，界面零算术）。
///
/// ## 为什么「体积」是候选体积而不是目录体积
///
/// 来源根下的**全部**字节（含不可回收的部分）需要为每个来源另做一次
/// 全量累加 —— 那是第二套逐来源求和（不变量②），而且与 ① 页的数字对不上。
/// 这里直接复用 `PageModelBuilder` 既有的 `bytesBySource`（**候选**字节），
/// 列名如实写「候选体积」：它是「这个来源里有多少是 Residue 认定的可回收量」。
public struct SourceScanRow: Identifiable, Sendable {
    /// 稳定身份 = 来源 rawValue。
    public var id: String { sourceID }
    /// 来源 rawValue（仅供 `id`；界面显示 `source`）。
    public let sourceID: String
    /// 来源展示名。
    public let source: SemanticSlot
    /// 该来源扫到的叶子条目数。
    public let items: SemanticSlot
    /// 该来源的**候选**体积。
    public let bytes: SemanticSlot
    /// 该来源的扫描耗时（Core 侧格式化成串 —— `MetricUnit` 没有秒单位）。
    public let duration: SemanticSlot

    public init(
        sourceID: String,
        source: SemanticSlot,
        items: SemanticSlot,
        bytes: SemanticSlot,
        duration: SemanticSlot
    ) {
        self.sourceID = sourceID
        self.source = source
        self.items = items
        self.bytes = bytes
        self.duration = duration
    }
}

// MARK: - 四档采集（AC-10 / AC-11 / AC-14）

/// 一档采集信号（P4 状态词取值封闭：未采集 / 已停止 / 运行中 / 无法判定）。
public struct CollectionTier: Identifiable, Sendable {
    /// 稳定身份 = 档位名。
    public var id: String { name }
    public let name: String
    /// 授权状态（AC-11：四档独立授权）。
    public let authorized: Bool
    /// 采集状态（P4 状态词）。
    public let state: SemanticSlot
    /// 受阻时的「所缺权限」（AC-14：该字段必须有值）+ 授权指引条目 ID。
    public let blockReason: SemanticSlot?

    public init(
        name: String,
        authorized: Bool,
        state: SemanticSlot,
        blockReason: SemanticSlot? = nil
    ) {
        self.name = name
        self.authorized = authorized
        self.state = state
        self.blockReason = blockReason
    }
}

// MARK: - 行 / 块

public struct OverviewBlock: Identifiable, Sendable {
    public let title: String
    public let slot: SemanticSlot

    /// **稳定身份 = 标题**（来源展示名，天然唯一且不随重建变化）。
    ///
    /// 原先是 `let id = UUID()` —— 每次 `build()` 都会生成新 UUID，
    /// SwiftUI 的列表 diff 会认为「所有行都换了」，200 行的候选清单因此
    /// 每帧全量重建（客户端审查 C7）。身份必须来自**内容**，不来自一次分配。
    public var id: String { title }

    public init(title: String, slot: SemanticSlot) {
        self.title = title
        self.slot = slot
    }
}

public struct CandidateRow: Identifiable, Sendable {
    /// **稳定身份 = 路径**（候选身份键的第一半；同名重建时路径也唯一）。
    public var id: String { name }
    public let name: String
    /// 「可参与自动删除」/「仅报告」。
    ///
    /// ⚠️ **值域被 AC-04 冻结为 2 值**（「第 ② 页候选清单每行带标签且取值
    /// ∈ {可参与自动删除 / 仅报告}」）。所以 AC-05 / AC-06 / AC-17 的阻断态
    /// **不能塞进这里**——那样会直接违反 AC-04 的判定。
    /// 阻断原因走下面的 `blockReason` 副行。
    public let participation: CandidateParticipation
    public let bytes: SemanticSlot
    /// 阻断原因（AC-05 L0 活引用 / AC-06 L2 否决 / AC-17 二次检查）。
    /// `nil` = 未被阻断。
    public let blockReason: SemanticSlot?

    public init(
        name: String,
        participation: CandidateParticipation,
        bytes: SemanticSlot,
        blockReason: SemanticSlot? = nil
    ) {
        self.name = name
        self.participation = participation
        self.bytes = bytes
        self.blockReason = blockReason
    }
}

public enum CandidateParticipation: Sendable {
    case autoDeletable
    case reportOnly

    public var label: String {
        switch self {
        case .autoDeletable: return L.pick("可参与自动删除", "Eligible for auto-delete")
        case .reportOnly: return L.pick("仅报告", "Report only")
        }
    }

    /// 图标位（**视觉基线 v1.1 §二：五标签五图标，不得复用**）。
    ///
    /// 原来有个 `isSignal` 属性——**已删除**：它的存在本身就是
    /// 「允许逐行用信号色」的入口，留着下次还会被用。
    public var symbolName: String {
        switch self {
        case .autoDeletable: return "bolt.circle"   // 「会被自动执行」——动作性
        case .reportOnly: return "doc.text"         // 「只记录不动作」——记录性
        }
    }
}

public struct ReportRow: Identifiable, Sendable {
    /// **稳定身份 = 来源名**（矩阵行唯一键）。
    public var id: String { source }
    public let source: String
    /// 七列单元格（顺序见 `ReportMatrix.columns`）。
    ///
    /// **每列是一个「多槽位」数组**，不是单个槽位——因为第 6 列
    /// 「L0 误判 · 检查」是**两个独立的数值**（`a` 与 `b`）。
    /// 若把两个数拼成一个字符串再放进 `.text`，那就是**界面自己拼数值**
    /// ——正是 DAC-47 判不通过的破口。
    public let cells: [[SemanticSlot]]

    /// 便捷构造：单槽位列 + 双槽位的第 6 列。
    public init(
        source: String,
        slots: [SemanticSlot],
        multiSlotColumn: Int? = nil,
        extraSlots: [SemanticSlot] = []
    ) {
        self.source = source
        var built: [[SemanticSlot]] = slots.map { [$0] }
        if let idx = multiSlotColumn, idx < built.count {
            built[idx] = [slots[idx]] + extraSlots
        }
        self.cells = built
    }
}

public struct EvidenceRow: Identifiable, Sendable {
    /// **稳定身份 = 路径 + 标签**。同一路径可能出现多条记录（先删除、后恢复），
    /// 仅用路径会撞键。
    public var id: String { "\(path)#\(label.text)" }
    public let path: String
    public let label: EvidenceLabel
    /// **对应的执行记录**（`nil` = 来自日志但无法还原成完整记录）。
    ///
    /// ## 为什么必须把它带上
    /// 「恢复」这个动作需要 `restorePath`（废纸篓里的实际位置），
    /// 而它只存在于 `ExecutionRecord` 里。原来 `EvidenceRow` 只有
    /// 路径与标签 → **恢复按钮根本接不上 `TrashExecutor.restore`**，
    /// 于是它成了一个点了没反应的按钮。
    ///
    /// 这不是「以后再补」的字段：**没有它，AC-13 的恢复能力就不存在。**
    public let record: ExecutionRecord?

    public init(
        path: String,
        label: EvidenceLabel,
        record: ExecutionRecord? = nil
    ) {
        self.path = path
        self.label = label
        self.record = record
    }
}

public enum EvidenceLabel: Sendable {
    case recoverable      // 可恢复
    case restored         // 已恢复
    case blocked          // 已阻断

    public var text: String {
        switch self {
        case .recoverable: return L.pick("可恢复", "Recoverable")
        case .restored: return L.pick("已恢复", "Restored")
        case .blocked: return L.pick("已阻断", "Blocked")
        }
    }

    /// 图标位（**v1.1 §二：五标签五图标，不得复用**）。
    public var symbolName: String {
        switch self {
        case .recoverable: return "arrow.uturn.backward"   // 「可回转」
        case .restored: return "checkmark.circle"          // 「回转已完成」
        case .blocked: return "slash.circle"               // 「回转被拦」
        }
    }
}

// MARK: - ⑤ 页矩阵列定义

/// ⑤ 页矩阵列定义（**七项，顺序唯一**）。
public enum ReportMatrix {
    public static var columns: [String] {
        [
            L.pick("来源", "Source"),
            L.pick("判定域", "In domain"),
            sampleColumnTitle,
            L.pick("门槛", "Threshold"),
            L.pick("观察期", "Observation"),
            l0ColumnTitle,
            L.pick("结论", "Conclusion"),
        ]
    }

    /// ③ 列的两个冻结时点——**列级元数据，在表头内分行标注**（v1.1 · B1）。
    ///
    /// 放在这里而不是 `ReportRow` 里，是因为它**每行都相同**：
    /// 逐行重复等于让用户把同一句话读七遍。列级的东西就放在列上。
    public static var freezeNotes: [String] {
        [
            L.pick("总量冻结：开轮时", "Total frozen: at round start"),
            L.pick("样本冻结：报告产出时", "Samples frozen: when report is produced"),
        ]
    }

    /// ③ 列的列名（表头第一行）。
    public static var sampleColumnTitle: String {
        L.pick("样本 / 总量", "Samples / Total")
    }

    /// 表头块高（v1.1 · B1：60 pt，**不计入数据行高**）。
    ///
    /// 算式：列名 11pt + 两行副标 11pt×2，按 1.3 行高 = 42.9，
    /// 加行间 4×2 + 上下内边距 4×2 = 58.9 → 上取整到 4 栅格 = **60**。
    public static let headerHeight: CGFloat = 60

    /// ③ 列宽（需容纳两行副标）。
    public static let sampleColumnWidth: CGFloat = 150

    /// ⑥ 列的列名。
    public static var l0ColumnTitle: String {
        L.pick("L0 误判 · 检查", "L0 misjudgment · Checks")
    }

    /// ⑥ 列的两个子标——**同样是列级元数据，放表头**（v1.1 · B1 原则的延伸）。
    ///
    /// 为什么需要：`a` 与 `b` 是两个独立数值（不能拼成一个字符串），
    /// 而数据行固定 32 pt 装不下两行带标文字 → 两个裸数字堆叠会让用户
    /// 分不清哪个是 `a`、哪个是 `b`。按 B1 的同一逻辑，子标放表头。
    public static var l0SubLabels: [String] {
        [L.pick("误判", "Misses"), L.pick("检查", "Checks")]
    }

    /// ⑥ 列两个子值的宽度（用于表头子标与数据格左右对齐）。
    public static let l0SubWidth: CGFloat = 62
}
