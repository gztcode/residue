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

    /// 侧栏分组（CR-031 §一 #15）。
    public var group: PageGroup {
        switch self {
        case .overview, .environments, .report: return .see
        case .policy, .confirm, .evidence: return .reclaim
        case .privacy: return .settings
        }
    }
}

/// 导航分组：先看清、再回收、最后设置。
public enum PageGroup: Int, CaseIterable, Sendable {
    case see = 0
    case reclaim = 1
    case settings = 2

    public var title: String {
        switch self {
        case .see: return L.pick("看清", "Understand")
        case .reclaim: return L.pick("回收", "Reclaim")
        case .settings: return L.pick("设置", "Settings")
        }
    }
}

// MARK: - 比例槽位（CR-031）

/// 0…1 比例（**视图唯一允许的比例来源**）。
///
/// ## 为什么不能直接把两个数交给视图
/// 「界面禁止算术」要求视图拿不到原料。进度条需要的是**比例**，不是
/// 「27 / 30」这串文字。若把分子分母交给视图，视图就会写 `Double(a) / Double(b)`
/// —— 契约里立刻多出第二个算式。
///
/// ## `nil` 不是 0
/// 分母 ≤ 0 时比例**无定义**（例：总量为 0 时的「占比」）。
/// 此时构造返回 `nil`，界面画空轨道 + 「—」，**不画 0%**。
/// 分子为 0 是**真实值**（这一来源确实没占用），照常返回 0。
///
/// 分子可以大于分母（`K` 是门槛的下界，可以超过 `H`），
/// `fraction` 封顶 1.0，进度条不会越界。
public struct RatioSlot: Sendable, Equatable {
    public let numerator: Int
    public let denominator: Int

    /// - Returns: 分母 ≤ 0 或分子 < 0 时 `nil`。
    public init?(numerator: Int, denominator: Int) {
        guard denominator > 0, numerator >= 0 else { return nil }
        self.numerator = numerator
        self.denominator = denominator
    }

    /// 0…1（Core 侧算好，视图只做 `CGFloat` 转换）。
    public var fraction: Double {
        Swift.min(1.0, Double(numerator) / Double(denominator))
    }

    /// 千分之一百分比：`452` = 45.2%。
    ///
    /// 用整数存，避免 `Double` 在等值断言里出现浮点噪声。
    public var percentTenths: Int {
        Int((fraction * 1000).rounded())
    }

    /// 呈现用百分比槽位（**唯一格式化处**，界面不再拼 `%`）。
    public var percentSlot: SemanticSlot {
        .percent(tenths: percentTenths)
    }
}

// MARK: - 页面模型

/// 七页的视图模型（**纯数据，无 SwiftUI 依赖**）。
public struct PageModel: Sendable {
    /// 是否处于只读态（数据由更高版本创建）。
    public var readOnly: Bool = false
    /// 是否正在加载。
    public var loading: Bool = false
    /// 加载进度文案。
    public var loadingMessage: String = L.pick("正在扫描…", "Scanning…")

    /// ① 页三区块。
    public var overviewBlocks: [OverviewBlock] = []
    /// ① 页状态条。
    public var statusSlot: SemanticSlot?

    // ---- 扫描新鲜度（重启后不把「不知道」显示成 0）----

    /// 是否有扫描结果可展示（本会话扫描过，或读回了上次扫描）。
    ///
    /// `false` → ① 页显示「还没有扫描过」；**任何数值都不显示**。
    public var hasScanned: Bool = true
    /// 当前数值是否来自**上次扫描**（本会话尚未扫描）。
    ///
    /// 为 `true` 时只有总量可信：来源明细、候选、可释放量都是「—」。
    public var restoredFromLastScan: Bool = false
    /// 重启 / 汇总不可读时的说明（`nil` = 数值来自本会话扫描）。
    public var lastScanNotice: String?

    /// 本会话是否有**可执行的**扫描结果（视图据此禁用「执行本批次」）。
    public var hasLiveScan: Bool { hasScanned && !restoredFromLastScan }

    // ---- 视觉基线 v2（CR-031）：数据可视化所需的**已算好**字段 ----

    /// ① 页主数字：全部来源合计字节。
    public var totalScannedSlot: SemanticSlot = .metric(0, unit: .bytes)
    /// ① 页来源占比行（堆叠条 + 明细表）。
    public var sourceShares: [SourceShareRow] = []
    /// ① 页「可释放 / 全量」比例；总量为 0 时 `nil`。
    public var reclaimableShare: RatioSlot?
    /// 观察期进度（侧栏 / ① 页 / ⑤ 页**共用同一个比例**）。
    public var observationRatio: RatioSlot?
    /// 「x / 14 天」——**唯一格式化处**（视图不再拼「天」之外的数）。
    public var observationDaySlot: SemanticSlot = .ratio(0, ObservationProgress.requiredDays)
    /// ⑤ 页门槛清单；`passed == nil` 表示**无法判定**（不是未通过）。
    public var gateChecks: [GateCheckRow] = []
    /// ⑤ 页逐来源样本进度条。
    public var sampleProgress: [SampleProgressRow] = []
    /// ⑥ 页批次预览清单（**只读，不可勾选**；见 CR-031 §三）。
    public var confirmRows: [ConfirmItemRow] = []
    /// ⑥ 页预览是否因上限被截断。
    public var confirmListTruncated: Bool = false

    /// ② 页候选行。
    public var candidateRows: [CandidateRow] = []
    /// ② 页当前页码（0 起）与总页数。
    public var pageIndex: Int = 0
    public var pageCount: Int = 1
    /// ② 页页码文案（**唯一格式化处**，视图不再做 `pageIndex + 1`）。
    public var pageIndicatorSlot: SemanticSlot = .text("—")

    /// ③ 页：自动删除开关当前是否处于「已启用」。
    public var autoDeleteEnabled: Bool = false
    /// ③ 页：开关是否可点亮（AC-08 组 B 的门槛是否全过）。
    ///
    /// **不可点亮时开关必须 disabled**——否则用户能点，但点了不生效，
    /// 这比「不能点」更糟（AC-08 组 B 的全部意义就是「未达线不得点亮」）。
    public var canLightUp: Bool = false

    /// ③ 页：未达项文案（带轮次）。
    public var unmetNotice: SemanticSlot?
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
    /// ⑤ 页「上一轮」行（**仅轮次 ≥ 2 时非 nil**）。
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

    /// 来源键（`Source.rawValue`）：视图据此取**来源识别色**。
    /// 默认空串 = 未知来源（视图画中性圆点，不猜颜色）。
    public let sourceKey: String
    /// 该条目占全量扫描字节的比例。
    ///
    /// 只用于② 页占比条；总量为 0 时 `nil`（不画 0%）。
    public let share: RatioSlot?

    public init(
        name: String,
        participation: CandidateParticipation,
        bytes: SemanticSlot,
        blockReason: SemanticSlot? = nil,
        sourceKey: String = "",
        share: RatioSlot? = nil
    ) {
        self.name = name
        self.participation = participation
        self.bytes = bytes
        self.blockReason = blockReason
        self.sourceKey = sourceKey
        self.share = share
    }
}

// MARK: - v2 行类型（CR-031）

/// ① 页来源明细行。
public struct SourceShareRow: Identifiable, Sendable {
    /// 稳定身份 = 来源键。
    public var id: String { sourceKey }
    /// `Source.rawValue`（视图映射识别色；不使用展示名做键）。
    public let sourceKey: String
    public let displayName: String
    /// 规范缓存路径（来源身份的一部分，不是用户数据）。
    public let path: String
    public let itemCount: SemanticSlot
    public let bytes: SemanticSlot
    /// 占全量字节的比例；总量为 0 时 `nil`。
    public let share: RatioSlot?
    public let inDecisionDomain: Bool

    public init(
        sourceKey: String,
        displayName: String,
        path: String,
        itemCount: SemanticSlot,
        bytes: SemanticSlot,
        share: RatioSlot?,
        inDecisionDomain: Bool
    ) {
        self.sourceKey = sourceKey
        self.displayName = displayName
        self.path = path
        self.itemCount = itemCount
        self.bytes = bytes
        self.share = share
        self.inDecisionDomain = inDecisionDomain
    }
}

/// ⑤ 页一条门槛检查。
public struct GateCheckRow: Identifiable, Sendable {
    public var id: String { kind.rawValue }
    public let kind: GateCheckKind
    /// `true` = 通过，`false` = 未通过，`nil` = **无法判定**。
    ///
    /// `nil` 在界面上必须是中性色 + 时钟图标，**不得显示成失败**。
    public let passed: Bool?
    /// 这一项针对的对象（最差来源名）；全局项为 `nil`。
    public let subject: String?
    /// 已格式化好的明细（比例 / 次数），视图不换算。
    public let detail: SemanticSlot

    public init(
        kind: GateCheckKind,
        passed: Bool?,
        subject: String? = nil,
        detail: SemanticSlot
    ) {
        self.kind = kind
        self.passed = passed
        self.subject = subject
        self.detail = detail
    }
}

/// ⑤ 页逐来源样本进度。
public struct SampleProgressRow: Identifiable, Sendable {
    public var id: String { sourceKey }
    public let sourceKey: String
    public let displayName: String
    /// `min(K, H) / H`；未结算 / 无门槛时 `nil`。
    public let ratio: RatioSlot?
    /// `K`（未结算 → `.unavailable`）。
    public let sample: SemanticSlot
    /// `H`（未取快照 → `.unavailable`）。
    public let threshold: SemanticSlot
    /// `nil` = 无法判定。
    public let passed: Bool?

    public init(
        sourceKey: String,
        displayName: String,
        ratio: RatioSlot?,
        sample: SemanticSlot,
        threshold: SemanticSlot,
        passed: Bool?
    ) {
        self.sourceKey = sourceKey
        self.displayName = displayName
        self.ratio = ratio
        self.sample = sample
        self.threshold = threshold
        self.passed = passed
    }
}

/// ⑥ 页批次预览行（**只读**：没有 `isSelected`，见 CR-031 §三）。
public struct ConfirmItemRow: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let sourceKey: String
    public let bytes: SemanticSlot
    /// 占全量字节的比例。
    public let share: RatioSlot?

    public init(path: String, sourceKey: String, bytes: SemanticSlot, share: RatioSlot?) {
        self.path = path
        self.sourceKey = sourceKey
        self.bytes = bytes
        self.share = share
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
    ///
    /// CR-033 / M-9 由 150 收窄到 130：④ / ⑥ 两列要装下非判定域行的整句契约文案，
    /// 七列合计必须仍 ≤ 695 pt（可用宽度 751 − 单元格内边距 56）。
    public static let sampleColumnWidth: CGFloat = 130

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
