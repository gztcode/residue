import Foundation

// ============================================================
// Residue · 语义位类型化（视觉基线 v1.0 §四 / R2 §3「L4 禁止算术」）
//
// ## 为什么需要这一层
// R2 §3 定了「界面禁止任何算术」，但**靠纪律迟早破**——写界面的人
// 看到 `K` 与 `T` 两个数，很自然就写 `T - K` 显示「差 3 条」。
// 那个「差 3 条」是**第二套算法**，与 M3 的「`J = T − K` 派生」并列，
// 两边一旦不一致，界面上就会出现一个契约里没有的数。
//
// 所以改成**类型约束**：界面只能从下列封闭枚举里取内容，
// **数值必须在构造 `SemanticSlot` 之前由 `Metrics` / `GateEvaluator` 算好**。
//
// ## 三条硬约束（视觉基线 §四）
// 1. `SemanticSlot` **不接受闭包、不接受算术表达式**
// 2. **「不可用」是正式槽位值**（`.unavailable`），**不是空字符串、不是 0**
// 3. **比例型槽位的两个值分别来自 `K` 与 `T`**——界面不显示「差 3 条」这类
//    自己算出来的结论
// ============================================================

/// 度量单位（**界面不换算**，值由 `Metrics` 算好）。
public enum MetricUnit: String, Sendable, Equatable, Codable {
    /// 字节。**槽位内部负责人类可读格式化**（见 `formatBytes`）——
    /// 界面**不得**自己做 `/ 1024`，但「把 2400000000 显示成 2.4 GB」这件事
    /// 必须有一处做，且只能有一处。
    case bytes
    /// 条目数。
    case items
    /// 次数。
    case times
    /// 天。
    case days
    /// 无单位（纯数值）。
    case none

    /// 单位后缀（**唯一一处**，界面不得自行拼接）。
    public var suffix: String {
        switch self {
        case .bytes: return ""      // 由 `formatBytes` 自带单位
        case .items: return L.pick("条", " items")
        case .times: return L.pick("次", " times")
        case .days: return L.pick("天", " days")
        case .none: return ""
        }
    }

    /// 字节的人类可读格式化（**唯一一处**）。
    ///
    /// 为什么放在这里而不是界面：视觉基线 §四 要求「界面不换行算」，
    /// 但「2.4 GB」这个显示必须由某一层算出来。放在槽位类型里，
    /// 界面拿到的仍是字符串，运算被关在 Core 内、可被单测约束。
    public static func formatBytes(_ value: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(value))
    }
}

/// 七态标签（视觉基线 §三的八态中，可作为**状态标签**的七类；
/// 「加载」是过程态不是结论态，不在此枚举内）。
public enum StateLabel: String, Sendable, Equatable, Codable, CaseIterable {
    /// 空（无数据）。
    case empty
    /// 错误（**必须配可执行动作**）。
    case error
    /// 无权限（配「所缺权限」+ 授权指引条目）。
    case noPermission
    /// 超限（已触顶）。
    case overLimit
    /// 并发冲突。
    case conflict
    /// 超时（可续扫）。
    case timeout
    /// 只读（本产品特有：数据由更高版本创建）。
    case readOnly

    /// 状态文案（**唯一一处**）。
    public var label: String {
        switch self {
        case .empty: return L.pick("暂无数据", "No data yet")
        case .error: return L.pick("出错了", "Something went wrong")
        case .noPermission: return L.pick("无法判定（权限不足）", "Can’t tell (permission denied)")
        case .overLimit: return L.pick("已达上限", "At limit")
        case .conflict: return L.pick("正在被其它任务使用", "In use by another task")
        case .timeout: return L.pick("已超时", "Timed out")
        case .readOnly: return L.pick("只读", "Read-only")
        }
    }

    /// 图标语义（SF Symbol 名；**视觉基线 §三的图标位**）。
    public var symbolName: String? {
        switch self {
        case .empty: return nil                      // 空态无图标
        case .error: return "exclamationmark.triangle"
        case .noPermission: return "lock"
        case .overLimit: return "arrow.up.to.line"
        case .conflict: return "arrow.triangle.branch"
        case .timeout: return "clock"
        case .readOnly: return "pencil.slash"
        }
    }

    /// 是否用危险色（视觉基线 §二：危险色只用于「不可逆 / 错误 / 无权限 / 超限」）。
    public var usesDangerColor: Bool {
        switch self {
        case .error, .noPermission, .overLimit: return true
        default: return false
        }
    }
}

/// 语义位（**界面唯一的取值来源**，视觉基线 §四）。
///
/// **不接受闭包、不接受算术表达式**——这是「L4 禁止算术」的类型级实现。
public enum SemanticSlot: Sendable, Equatable {
    /// 静态文案。
    case text(String)

    /// 数值 + 单位。**值由 `Metrics` 算好，界面不换算**。
    case metric(Int, unit: MetricUnit)

    /// 「27 / 30」两值。**两个值分别来自 `K` 与 `T`**——
    /// 界面**不得**显示自己算出的「差 3 条」。
    case ratio(Int, Int)

    /// 百分比，单位 = 千分之一（`452` → 「45.2%」）。
    ///
    /// **值必须由 `RatioSlot.percentTenths` 算好**；界面只读字符串。
    /// 用整数存，避免浮点在等值断言里出现噪声。
    case percent(tenths: Int)

    /// 剩余天数。`nil` → 显示「—」（**不是 0**）。
    case duration(days: Int?)

    /// 七态标签之一。
    case stateLabel(StateLabel)

    /// **不可用是一个正式的槽位值**，不是空字符串、不是 0。
    ///
    /// 用于两种情形（视觉基线 §四 + R2 §10.2）：
    /// - 只读态未知字段：`.unavailable("—（由更高版本维护）")`
    /// - 报告未产出：`.unavailable("本轮未结算")`
    case unavailable(reason: String)

    /// **无权限态**（视觉基线 §三：必须给「所缺权限」+ 授权指引条目 ID）。
    ///
    /// 为什么单独一个 case 而不是用 `.stateLabel(.noPermission)`：
    /// 基线 §三 明确要求无权限态**必须**带「所缺权限」与「条目 ID」两个要素。
    /// 用无参数的 `.stateLabel` 只能显示「无法判定（权限不足）」——
    /// 那正是 DAC-33 判不通过的原因：**有状态没要素，用户不知道去开哪个权限**。
    case permissionBlocked(missing: String, guideItemID: String)

    // MARK: - 呈现

    /// 呈现用的字符串（**界面只读这一个属性**）。
    public var displayText: String {
        switch self {
        case .text(let s):
            return s
        case .metric(let v, let unit):
            // 字节走统一的人可读格式化（唯一一处），其余走单一位后缀
            if unit == .bytes { return MetricUnit.formatBytes(v) }
            return "\(v)\(unit.suffix)"
        case .ratio(let a, let b):
            return "\(a) / \(b)"
        case .percent(let tenths):
            // 452 → 「45.2%」；整数运算，不引入浮点噪声。
            return "\(tenths / 10).\(tenths % 10)%"
        case .duration(let days):
            // `nil` → 「—」；**不是 0**（0 会被读成「今天到期」）
            return days.map { L.pick("\($0) 天", "\($0) days") } ?? "—"
        case .stateLabel(let label):
            return label.label
        case .unavailable(let reason):
            return reason
        case .permissionBlocked(let missing, let guideItemID):
            // 三个要素齐：状态词 + 所缺权限 + 条目 ID（视觉基线 §三）
            return L.pick(
                "无法判定（所缺：\(missing)）· 授权指引 \(guideItemID)",
                "Can’t tell (missing: \(missing)) · Authorization guide \(guideItemID)"
            )
        }
    }

    /// 是否为「不可用」类（供界面决定用次文字色）。
    public var isUnavailable: Bool {
        if case .unavailable = self { return true }
        if case .duration(nil) = self { return true }
        return false
    }

    /// 是否为「无权限」类（供界面用危险色 + 锁图标）。
    public var isPermissionBlocked: Bool {
        if case .permissionBlocked = self { return true }
        return false
    }

    /// 若为状态标签，返回它（供界面决定图标与颜色）。
    public var stateLabel: StateLabel? {
        if case .stateLabel(let l) = self { return l }
        return nil
    }
}

// MARK: - 契约常量（**界面文案的唯一来源**）

/// 界面必须逐字使用的文案串。
///
/// **为什么集中在这里**：这些串在 PRD / R2 里被写死为「唯一样式串」，
/// 界面自己拼一遍就必然与契约不一致（同类错误已复发多轮）。
public enum UICopy {

    /// ③ 页开关区未达项（计数日未满）——**M1 第一串，全文唯一**。
    ///
    /// 形如「第 2 轮 · 观察期 5/14 天」。
    /// **前置数字式**：轮次在最前（视觉基线 §五 跨页规则）。
    public static func observationInProgress(round: Int, observed: Int) -> String {
        L.pick(
            "第 \(round) 轮 · 观察期 \(observed)/14 天",
            "Round \(round) · Observation \(observed)/14 days"
        )
    }

    /// ③ 页开关区未达项（计数日已满、报告未产出）——**M1 第二串，全文唯一**。
    public static func awaitingSettlementScan(round: Int) -> String {
        L.pick(
            "第 \(round) 轮 · 观察期未满 · 待结算扫描（无需操作）",
            "Round \(round) · Observation incomplete · Awaiting settlement scan (no action needed)"
        )
    }

    /// ⑤ 页页级状态行——**同构于 M1 的前置数字式**（DAC-55 要求三处轮次同构）。
    ///
    /// **原来写成「本轮可点亮：否（…）」没有轮次前缀 → 三处不同构，DAC-55 判不通过。**
    public static func pageLevelVerdict(round: Int, reason: String) -> String {
        L.pick(
            "第 \(round) 轮 · 本轮可点亮：否（\(reason)）",
            "Round \(round) · Can enable this round: No (\(reason))"
        )
    }

    /// ③ 页开关区未达项（**观察期已满但样本不足**）——AC-08 组 A 的来源项。
    ///
    /// 形如「第 2 轮 · 样本不足（27 / 30）」。
    /// **为什么需要单独一条**：M1 那两串只覆盖「观察期未满」；
    /// 而观察期已满、报告已产出、`K < H` 时，未达项是**样本不足**，
    /// 用「观察期 14/14 天」既不是未达项、也会让 ⑤ 页的「报告已产出」显得矛盾
    /// （复必现的 M-02 就是靠这个矛盾看出问题的）。
    public static func unmetSampleInsufficient(round: Int, sample: Int, threshold: Int) -> String {
        L.pick(
            "第 \(round) 轮 · 样本不足（\(sample) / \(threshold)）",
            "Round \(round) · Insufficient samples (\(sample) / \(threshold))"
        )
    }

    /// 重启后、本会话尚未扫描时的说明（① 页 / ⑥ 页）。
    ///
    /// **能展示的只有上次扫描的总量**：候选清单按契约不落盘，所以逐来源、
    /// 逐条目、可释放量都无从得知。它们显示「—」而不是 0 ——「未知 ≠ 0」。
    public static var lastScanRestoredNotice: String {
        L.pick(
            "本次启动尚未扫描：总量来自上次扫描；来源明细、候选与可释放量需重新扫描后显示。",
            "Not scanned since launch: the total is from the last scan; source details, candidates, and reclaimable size appear after a new scan."
        )
    }

    /// 重启后、上次扫描的汇总也读不到（例如日志已被「一键清除」）。
    ///
    /// 此时**连总量都不显示**：显示 0 会被读成「缓存是空的」。
    public static var lastScanSummaryUnavailable: String {
        L.pick(
            "本次启动尚未扫描，上次扫描的汇总不可用（记录可能已被清除）；重新扫描后显示。",
            "Not scanned since launch and the last scan summary is unavailable (records may have been cleared). Scan again to see numbers."
        )
    }

    /// 重启后候选清单为空时的**短说明**（② 页空态 / ⑥ 页批次空态）。
    ///
    /// 与 `lastScanRestoredNotice` 分开：那条解释「总量为什么还在」，
    /// 这两页要解释的是「清单为什么是空的」，用长句会答非所问。
    public static var candidatesNeedRescan: String {
        L.pick(
            "候选清单不会跨启动保留；重新扫描后即可看到。",
            "The candidate list isn’t kept across launches; scan again to see it."
        )
    }

    /// ⑤ 页在**只读态**显示这一串，而不是「本轮未结算」。
    ///
    /// R2 §10.2：只读态不产出 AC-09 报告、不写任何落盘物；
    /// 若显示「本轮未结算」会被读成「等一会儿就有」。
    public static var readOnlyNoSettlement: String { L.pick("只读，不结算", "Read-only, not settled") }

    /// **版本降级**只读的成因文案（`E-301`）。
    public static var versionDegradedReadOnly: String {
        L.pick(
            "数据由更高版本创建，本版本只读；不能执行清理。",
            "Data was created by a newer version. This version is read-only and can’t clean up."
        )
    }

    /// **权限降级**只读的成因文案（AC-14 / `E-501`）。
    ///
    /// ## 为什么必须与「版本降级只读」分开
    ///
    /// 两种只读态的**成因、用户该做的事、能否自行解除**全都不同：
    ///
    /// | | 版本降级（`E-301`） | 权限降级（`E-501`） |
    /// |---|---|---|
    /// | 成因 | 数据由更高版本创建 | 无法枚举本用户进程 |
    /// | 用户该做 | 装回更高版本 | 去授权 |
    /// | 能自行解除 | 否（除非升级） | 是（授权后即可） |
    ///
    /// 用同一句话覆盖两者，用户就会照着做一件**解决不了问题**的事。
    /// 设计走查（DAC v2.0 §8.2 C-4）指出：此前唯一的只读图是版本降级，
    /// **权限降级那条路径一张图都没有** → 等于用版本降级顶替了权限降级。
    public static var permissionDegradedReadOnly: String {
        L.pick(
            "无法枚举本用户进程，本轮不判定、不结算。请到系统设置允许本应用访问。",
            "Can’t enumerate this user’s processes. No verdict or settlement this round. Allow access for this app in System Settings."
        )
    }

    /// 只读态未知字段的占位（**绝不显示 0**）。
    public static var maintainedByNewerVersion: String {
        L.pick("—（由更高版本维护）", "— (maintained by a newer version)")
    }

    /// 报告产出前的结论列取值（**不得填「未达标」——那是假值**）。
    public static var notSettledThisRound: String { L.pick("本轮未结算", "Not settled this round") }

    /// ⑤ 页「上一轮」行的前缀（`轮次 ≥ 2` 时才显示该行）。
    ///
    /// **前置数字式**（视觉基线 §五 跨页规则：三处轮次同构）。
    /// 显示的轮次是**上一轮**，即 `round - 1`。
    public static func previousRound(round: Int) -> String {
        L.pick(
            "第 \(round - 1) 轮 · 上一轮结算",
            "Round \(round - 1) · Previous settlement"
        )
    }

    /// ⑦ 页留存口径两行同址（14 日 + 90 天/200 MB）。
    ///
    /// AC-13 · G-4 的「14 日」是**唯一对外宣称落点**；
    /// M6 的留存口径与它**同址**（R2 §10 的「时限口径两行同址」）。
    public static var restoreWindowNotice: String {
        L.pick("14 日内可一键恢复", "One-click restore within 14 days")
    }
    public static var retentionNotice: String {
        L.pick(
            "日志保留 90 天，或可回收字节满 200 MB，先到者为准",
            "Logs are kept for 90 days, or until reclaimable bytes reach 200 MB, whichever comes first"
        )
    }

    /// ④ 页清除范围说明（**必须含「不重置」这句**）。
    ///
    /// N7 / CR-022 偏差 3：清除范围 = 采集物与日志，**不含 `a` 的载体**。
    /// 这句话是用户「清完为什么还没点亮」的唯一解释来源。
    ///
    /// **逐字对齐视觉基线 §五 ④ 给的句子「不重置观察期与 L0 误判记录」**——
    /// 先前写成「不重置观察期**进度**与…」多一个字，DAC-45 按逐字判不通过。
    public static var clearScopeNotice: String {
        L.pick(
            "清除采集物与日志（记录目录 + 运行期态 + 备份）。"
            + "不重置观察期与 L0 误判记录。",
            "Clears collected data and logs (records directory + runtime state + backups). "
            + "Observation progress and L0 misjudgment records are not reset."
        )
    }

    /// ⑥ 页不可逆提示。
    public static var irreversibleNotice: String {
        L.pick(
            "以下条目将被移入废纸篓；14 日内可在第 ⑦ 页恢复。",
            "The following items will be moved to Trash; restorable from page ⑦ within 14 days."
        )
    }
}
