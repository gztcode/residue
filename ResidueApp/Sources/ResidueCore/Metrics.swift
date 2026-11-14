import Foundation

// ============================================================
// Residue · 指标定义层
//
// 本文件是 PRD「指标定义表」M1–M6 的**唯一代码映射点**。
// 契约每一条定义都在此有一个常量或一个公式；正文（AC / §6 / §9）
// 引用的是这些量，不是各自的措辞。
//
// 契约来源：Residue-PRD-v5.1.md
//   M1 观察期进度量（轮次 / 本轮计数日）
//   M2 门槛量 H
//   M3 样本量 K / 失联量 J / 快照总量 T
//   M4 L0 误判量 a
//   M5 L0 检查次数 b
//   M6 留存计量量（可回收字节）
//
// **纪律**：本文件不得出现任何「第二套式子」。若契约改动，
// 改这里 + 改 PRD，不在此处打补丁。
// ============================================================

// ---------- 身份键（M3 / M4 共用 · 契约 AC-09 既有「路径 + birthtime」） ----------

/// 候选身份键 = 路径 + birthtime。
/// 同一路径重建 ⇒ 新身份（新位槽、不继承旧的 `F` 位与 `C_done` 记录）。
public struct CandidateID: Hashable, Codable, Sendable, Comparable {
    public let path: String
    public let birthtime: Date

    public init(path: String, birthtime: Date) {
        self.path = path
        self.birthtime = birthtime
    }

    public static func < (lhs: CandidateID, rhs: CandidateID) -> Bool {
        if lhs.path != rhs.path { return lhs.path < rhs.path }
        return lhs.birthtime < rhs.birthtime
    }
}

// ---------- 来源（M3 / M4 的分组键第一维） ----------

/// 上游来源。首版封闭枚举（契约：判定域 = `uv` cache / `npm/_npx` 两类；
/// `pipx` run 只报告、不自动删、不进判定域）。
public enum Source: String, Codable, Sendable, CaseIterable {
    case uvCache = "uv_cache"
    case npmNpx = "npm_npx"
    case pipxRun = "pipx_run"

    /// 是否属判定域（参与自动删除的来源）。
    /// 契约：判定域 = 本轮观察期开始快照内命中的来源（封闭枚举两类）。
    public var isInDecisionDomain: Bool {
        switch self {
        case .uvCache, .npmNpx: return true
        case .pipxRun: return false
        }
    }

    /// 展示名（界面用）。
    public var displayName: String {
        switch self {
        case .uvCache: return "uv cache"
        case .npmNpx: return "npm/_npx"
        case .pipxRun: return "pipx run"
        }
    }

    /// 规范缓存路径（**来源身份的一部分**，不是用户数据）。
    ///
    /// 只用于 ① 页来源明细表的「目录」列。扫描根由 `SourceRule` 决定，
    /// 这里给的是用户能认出来的规范位置；两者不一致时以扫描记录为准。
    public var canonicalCachePath: String {
        switch self {
        case .uvCache: return "~/.cache/uv"
        case .npmNpx: return "~/.npm/_npx"
        case .pipxRun: return "~/.local/pipx/venv"
        }
    }
}

// ---------- M1 · 观察期进度量 ----------

/// M1 观察期进度量。
public struct ObservationProgress: Codable, Sendable, Equatable {
    /// 轮次 = 观察期窗口序号（首轮 = 1）。唯一递增事件 = 「未达标自动开下一轮」。
    /// 应用版本变更**不**产生新轮次（它重置当前轮次）。
    public var round: Int

    /// 本轮计数日起算点 = 本轮首次成功扫描完成时刻。
    public var startAnchor: Date?

    /// 本轮计数日 = 自起算点起计的「有成功扫描的日历日数」（一天最多 +1）。
    public var countedDays: Int

    /// 观察期长度（V1，已由 C2 裁决确认 14 天）。
    public static let requiredDays = 14

    public init(round: Int = 1, startAnchor: Date? = nil, countedDays: Int = 0) {
        self.round = round
        self.startAnchor = startAnchor
        self.countedDays = countedDays
    }

    /// 剩余天数 = 14 − 计数日（下界 0）。
    /// **计数日已满而报告未产出时该格显示 `—` 而非 `0`**（契约 M1）。
    public var remainingDays: Int? {
        guard countedDays < ObservationProgress.requiredDays else { return nil }
        return ObservationProgress.requiredDays - countedDays
    }

    /// 计数日在第 14 个计数日后**封顶为 14**（契约 M1 · 质量 Q16）。
    public var displayCountedDays: Int {
        min(countedDays, ObservationProgress.requiredDays)
    }

    /// 计数日已满（天数侧）。注意：**已满**还须「结束扫描已完成且已产出报告」，
    /// 那属于 `ObservationState`，不在本结构内。
    public var isDayQuotaReached: Bool {
        countedDays >= ObservationProgress.requiredDays
    }
    /// 计数日推进（**M1 的唯一实现处**）。
    ///
    /// 规则：**一天最多 +1**（计数对象 = 有成功扫描的日历日，同一天多次成功扫描只计 1 日）。
    /// 上限 = `requiredDays`（14，C2 已裁决）。
    ///
    /// **为什么放在 Core 而不是 App 编排层**：这是 M1 的判定口径，
    /// 放在界面上就是「第二套算法」（R2 §3 · L4「界面禁止算术」）。
    public mutating func advanceCountedDay(on day: Date, calendar: Calendar = .current) {
        if let anchor = startAnchor {
            guard !calendar.isDate(anchor, inSameDayAs: day) else { return }
            countedDays = Swift.min(countedDays + 1, ObservationProgress.requiredDays)
            startAnchor = day
        } else {
            // 首日：起算点锚定，计数日从 1 开始
            startAnchor = day
            countedDays = Swift.max(countedDays, 1)
        }
    }

}

// ---------- M2 · 门槛量 H ----------


public enum Threshold {
    /// H = min(30, T)。**全文唯一式子**（契约 M2）。
    public static let cap = 30

    /// H = min(30, T)；H ≥ 1（因入域来源 T ≥ 1）。
    public static func h(forTotal t: Int) -> Int {
        min(cap, t)
    }
}

// ---------- M3 · 样本量 K / 失联量 J / 快照总量 T ----------

/// M3 一轮快照的结算值。
public struct SnapshotMetrics: Codable, Sendable, Equatable {
    /// T = 该来源观察期开始快照的候选总量（固定，不因失联缩小）。
    public let total: Int
    /// K = 快照内仍可归因的条目数。
    public let attributable: Int
    /// J = 失联 = 快照内被排除的条目数。**派生量**：`J = T − K`。
    public let lost: Int
    /// 快照日（观察期开始日）——`T` 的冻结时点。
    public let snapshotDate: Date
    /// 结算日（观察期结束扫描日）——`K` / `J` 的冻结时点。
    public let settlementDate: Date

    public init(total: Int, attributable: Int, snapshotDate: Date, settlementDate: Date) {
        self.total = total
        self.attributable = attributable
        self.lost = total - attributable
        self.snapshotDate = snapshotDate
        self.settlementDate = settlementDate
    }

    /// 恒等式 `K + J = T`（契约 M3 唯一式）。
    public var identityHolds: Bool {
        attributable + lost == total
    }
}

// ---------- M4 / M5 · L0 相关量 ----------

/// M4 · 按来源的误判状态载体（**四项字段**，契约 CR-019）。
///
/// 载体落**应用状态目录**下的本机状态文件：
/// - 不落 `.jsonl` 记录目录、不计入 N7 计量与容量回收
/// - N7 的「一键清除全部采集与日志」**不作用于**它 ⇒ 用户的清除动作不构成 `a` 的重置路径
/// - 随应用版本变更而**一并清零**（`F` / `C_done` / `a` 三项 + 本表）
/// `F` · 首检阴性位图（契约 M4 载体字段①）。
///
/// **位按「位槽号」分配**（不是按候选）——位槽只增不减时位图随位槽同步增长。
/// 稠密实现：`UInt64` 数组，1 bit / 位槽；位槽数达到当前容量时扩容一位。
/// 「300 万候选 ≈ 375 KB」是**候选数级**的量级估计，不是位图上限。
public struct NegativeBitmap: Codable, Sendable, Equatable {
    /// 稠密位图：word[i] 的第 b 位 = 位槽号 i*64+b。
    private var words: [UInt64]

    public init() { self.words = [] }

    /// 位槽容量（bit 数）。
    public var capacityBits: Int { words.count * 64 }

    /// 实际占用的字节数。
    public var byteSize: Int { words.count * 8 }

    public func isSet(_ slot: Int) -> Bool {
        guard slot >= 0 else { return false }
        let w = slot / 64, b = slot % 64
        guard w < words.count else { return false }
        return (words[w] >> UInt64(b)) & 1 == 1
    }

    /// 置位。**一经置位不再清除**（契约：候选首次判定为阴性时置位）。
    public mutating func set(_ slot: Int) {
        guard slot >= 0 else { return }
        let w = slot / 64, b = slot % 64
        while words.count <= w { words.append(0) }   // 按位槽扩容
        words[w] |= (1 << UInt64(b))
    }

    public mutating func clearAll() { words = [] }
}

/// M4 · 按来源的误判状态载体（**四项字段**，契约 CR-019 / CR-020）。
///
/// 载体落**应用状态目录**下的本机状态文件：
/// - 不落 `.jsonl` 记录目录、不计入 N7 计量与容量回收
/// - N7 的「一键清除全部采集与日志」**不作用于**它 ⇒ 用户的清除动作不构成 `a` 的重置路径
/// - 随应用版本变更而**一并清零**（四项全清）
public struct SourceL0State: Codable, Sendable, Equatable {
    /// ① `F` 首检阴性位图：曾被判为「无活引用」的候选，**按位槽号索引**。
    public var negativeSeen: NegativeBitmap

    /// ② `C_done` 已计过误判的候选集合（单调增长，命中后并入）。
    public var countedDone: Set<CandidateID>

    /// ③ 位槽占用表：身份键 → 位槽号。
    /// 位槽按身份键的**稳定哈希**分配（与排序名次无关）；
    /// 哈希冲突时以身份键全值比较消歧、**不共用位槽**；
    /// **候选被手删后其位槽不回收**（防位槽复用致新候选继承旧候选的 `F` 位）。
    ///
    /// **位槽号域无上限**（占用表随占用量单调增长）→ 任何时候新候选都能分到新槽位，
    /// **不存在「无空槽可用」的状态**，故判据始终可执行、`a` 在任何输入下可判。
    public var slotTable: SlotTable

    /// ④ 累计误判数 `a` 与上次扫描判定时刻。
    public var missCount: Int
    public var lastJudgmentAt: Date?

    public init(
        negativeSeen: NegativeBitmap = NegativeBitmap(),
        countedDone: Set<CandidateID> = [],
        slotTable: SlotTable = SlotTable(),
        missCount: Int = 0,
        lastJudgmentAt: Date? = nil
    ) {
        self.negativeSeen = negativeSeen
        self.countedDone = countedDone
        self.slotTable = slotTable
        self.missCount = missCount
        self.lastJudgmentAt = lastJudgmentAt
    }

    /// 某候选是否「曾判干净」——**经位槽号查位图**（不是按路径查集合）。
    public func hasBeenJudgedClean(_ id: CandidateID) -> Bool {
        guard let slot = slotTable.slotIfAssigned(for: id) else { return false }
        return negativeSeen.isSet(slot)
    }
}

/// L0 判定结果（对单条候选的一次判定）。
public enum L0Verdict: String, Codable, Sendable {
    /// 无活引用（P-L0「持有」判据未命中）。
    case noLiveReference
    /// 有活引用（P-L0「持有」判据命中：fd / 文件锁 / cwd 之一）。
    case hasLiveReference
    /// 无法判定（未取得 Full Disk Access 等权限受阻）。
    case undetermined
}

/// M4 · 判据计算（**唯一口径**）。
public enum MissCounter {

    /// 判据：`a` += |`F` ∩ `P_now` − `C_done`|
    ///
    /// - `F`       = 曾被判为「无活引用」的候选（**按位槽号索引的位图**）
    /// - `P_now`   = 本次扫描判定为「有活引用」的候选集合
    /// - `C_done`  = 已计过误判的候选集合
    ///
    /// 语义 = 「曾判干净、而这次扫描被持有」的候选 = **L0 误判**。
    /// `− C_done` 保证同一条候选只计一次（持续持有、间歇持有均不重复计）。
    public static func computeNewMisses(
        state: SourceL0State,
        currentHeld: Set<CandidateID>
    ) -> Set<CandidateID> {
        var hit: Set<CandidateID> = []
        for id in currentHeld where state.hasBeenJudgedClean(id) && !state.countedDone.contains(id) {
            hit.insert(id)
        }
        return hit
    }

    /// 应用一次扫描的判定结果，更新载体。
    ///
    /// 时序（契约 M4 写入时刻）：`P_now` 的求取、`F` 的置位、`C_done` 的并入、
    /// `a` 的写入 —— **四者一律在同一次扫描的全部 L0 判定完成后一次性完成**。
    ///
    /// - 参数 `judgments`：本次扫描对每条候选的判定结果
    /// - 未取得 FDA 的来源：调用方不应把该来源的判定传进来（`a` / `b` 均不判定）
    public static func apply(
        state: inout SourceL0State,
        judgments: [CandidateID: L0Verdict],
        now: Date
    ) {
        var currentHeld: Set<CandidateID> = []
        for (id, verdict) in judgments {
            // 每条候选先拿位槽号（稳定哈希 + 冲突消歧 + 不回收）
            let slot = state.slotTable.slot(for: id)
            switch verdict {
            case .noLiveReference:
                // 首检阴性 → **按位槽号置位** `F`，一经置位不再清除
                state.negativeSeen.set(slot)
            case .hasLiveReference:
                currentHeld.insert(id)
            case .undetermined:
                break
            }
        }
        let newMisses = computeNewMisses(state: state, currentHeld: currentHeld)
        state.missCount += newMisses.count
        state.countedDone.formUnion(newMisses)
        state.lastJudgmentAt = now
    }
}

/// 位槽分配器（契约 M4 · 载体字段③ · CR-020 / CR-021）。
///
/// 规则：
/// - **位槽号 = 分配序号（稠密、从 0 递增）**——这样 `F` 位图 1 bit/位槽，
///   3M 位槽 = 3M bit ≈ 375 KB，与契约量级一致。
///   （**不能**用哈希值当位槽号：哈希空间 10 亿 → 稠密位图会膨胀到 128 MB 级，
///   实测 10 万候选即 134 MB。哈希只作「身份键 → 位槽」查找表的散列。）
/// - **不共用位槽**：同一身份键恒得同一槽位（幂等查找）
/// - **位槽不回收**：候选被手删后其位槽保留 → 位槽号域只增不减
/// - **无上限**：任何时候都能分到新槽位，不存在「无空槽可用」
/// - **不受他人增删影响**：槽位一旦分配永不改变，故其它候选增删/排序变化不影响本位
///
/// **性能**：O(1) 均摊（字典查找 + 计数器自增）。
public struct SlotTable: Codable, Sendable, Equatable {
    /// 身份键 → 位槽号（契约字段③的对外形态）。
    public private(set) var assignments: [CandidateID: Int]
    /// 下一个可用位槽号（**稠密递增**，不回收）。
    private var nextSlot: Int

    enum CodingKeys: String, CodingKey { case assignments, nextSlot }

    public init() {
        self.assignments = [:]
        self.nextSlot = 0
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.assignments = try c.decode([CandidateID: Int].self, forKey: .assignments)
        if let n = try c.decodeIfPresent(Int.self, forKey: .nextSlot) {
            self.nextSlot = max(n, (assignments.values.max() ?? -1) + 1)
        } else {
            self.nextSlot = (assignments.values.max() ?? -1) + 1
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(assignments, forKey: .assignments)
        try c.encode(nextSlot, forKey: .nextSlot)
    }

    public var count: Int { assignments.count }
    /// 已分配的最大位槽号 + 1（= 位图需要的 bit 数）。
    public var slotDomainSize: Int { nextSlot }

    /// 为候选分配位槽号（幂等）。O(1) 均摊。
    public mutating func slot(for id: CandidateID) -> Int {
        if let existing = assignments[id] { return existing }
        let s = nextSlot
        assignments[id] = s
        nextSlot += 1
        return s
    }

    public func slotIfAssigned(for id: CandidateID) -> Int? { assignments[id] }

    public mutating func clearAll() {
        assignments = [:]
        nextSlot = 0
    }

    /// 稳定哈希：仅用于对外一致性校验（不作位槽号）。
    public static func stableHash(_ id: CandidateID) -> Int {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.path.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01B3
        }
        let bits = UInt64(bitPattern: Int64(id.birthtime.timeIntervalSince1970.bitPattern))
        for shift in stride(from: 0, to: 64, by: 8) {
            h ^= (bits >> UInt64(shift)) & 0xFF
            h = h &* 0x0000_0100_0000_01B3
        }
        return Int(h & 0x3FFF_FFFF)
    }
}

/// M5 · L0 检查次数 `b`。
public enum CheckCounter {
    /// `b` = 本轮内、对该来源全部候选执行 L0 判定的次数之和（按来源分组）。
    /// **影子期内每次扫描对判定域内每条可再生物料候选至少执行一次 L0 判定**
    /// → 本期内 `b = 0` 对判定域内来源**不可达**（判定域 = 首次扫描取的快照）。
    public static func count(from judgments: [CandidateID: L0Verdict]) -> Int {
        judgments.count
    }
}

// ---------- 判定域（M3 / AC-04 ②） ----------

public enum DecisionDomain {
    /// 判定域成员 = **本轮观察期开始快照内命中的来源**（契约：判定域以快照内命中为准）。
    /// 新入域但无本轮快照的来源**不属于判定域**，不参与逐来源判定、不阻断点亮。
    public static func members(snapshotSources: Set<Source>) -> Set<Source> {
        Set(snapshotSources.filter { $0.isInDecisionDomain })
    }
}

// ---------- 门槛判定（AC-08 组 A / 组 B） ----------

/// AC-08 组 A 的来源项（未达项的类型）。
public enum UnmetSourceItem: Equatable, Sendable {
    /// 样本不足（`K < H`）。
    case insufficientSample
    /// L0 误判（`a ≠ 0`）· 或 `b = 0`（本期不可达）· 或未取得 FDA（`a`/`b` 未判定）。
    case l0Misjudged(missCount: Int?, checkCount: Int?, undetermined: Bool)

    public var text: String {
        switch self {
        case .insufficientSample:
            return L.pick("样本不足", "Insufficient samples")
        case .l0Misjudged(let miss, let check, let undetermined):
            if undetermined {
                return L.pick("L0 未判定（未取得 Full Disk Access）", "L0 undetermined (Full Disk Access not granted)")
            }
            if let miss, let check {
                return L.pick(
                    "L0 误判 \(miss) 次（检查 \(check) 次）",
                    "L0 misjudgment \(miss) times (\(check) checks)"
                )
            }
            if let check {
                return L.pick("L0 未检查（检查 \(check) 次）", "L0 not checked (\(check) checks)")
            }
            return L.pick("L0 误判", "L0 misjudgment")
        }
    }
}

/// AC-08 组 A 的全局项（至多一项，不带来源）。
public enum UnmetGlobalItem: Equatable, Sendable {
    /// 观察期未满。
    case observationUnfinished

    /// 未达项文案（唯一样式串 · M1）。
    /// - 计数日未满 → 「第 N 轮 · 观察期 x/14 天」
    /// - 计数日已满而报告未产出 → 「第 N 轮 · 观察期未满 · 待结算扫描（无需操作）」
    public static func text(round: Int, countedDays: Int) -> String {
        if countedDays < ObservationProgress.requiredDays {
            // **不在这里重新拼一遍**：多语言后两处译文必然分叉。
            return UICopy.observationInProgress(round: round, observed: countedDays)
        }
        return UICopy.awaitingSettlementScan(round: round)
    }
}

/// AC-08 组 A 的判定结果。
public struct UnmetItems: Sendable {
    public var global: UnmetGlobalItem?
    /// 来源项（按判定域顺序分组逐行）。
    public var bySource: [UnmetSourceEntry]

    public init(global: UnmetGlobalItem?, bySource: [UnmetSourceEntry] = []) {
        self.global = global
        self.bySource = bySource
    }

    public var isEmpty: Bool { global == nil && bySource.isEmpty }
}

/// 一条来源未达项。
public struct UnmetSourceEntry: Equatable, Sendable {
    public let source: Source
    public let item: UnmetSourceItem

    public init(source: Source, item: UnmetSourceItem) {
        self.source = source
        self.item = item
    }
}

/// 单个来源的门槛判定输入。
public struct SourceGateInput: Sendable {
    public var source: Source
    /// `K`（报告产出后才有值；产出前为 nil）
    public var attributable: Int?
    /// `T`
    public var total: Int?
    /// `a`
    public var missCount: Int?
    /// `b`
    public var checkCount: Int?
    /// 该来源是否未取得 FDA（→ `a`/`b` 均不判定）
    public var undetermined: Bool

    public init(
        source: Source,
        attributable: Int?,
        total: Int?,
        missCount: Int?,
        checkCount: Int?,
        undetermined: Bool
    ) {
        self.source = source
        self.attributable = attributable
        self.total = total
        self.missCount = missCount
        self.checkCount = checkCount
        self.undetermined = undetermined
    }
}

/// 门槛清单的六个检查项（CR-031）。
///
/// 顺序即界面顺序：**全局条件在前，逐来源条件在后**。
public enum GateCheckKind: String, Sendable, CaseIterable {
    case observation
    case settlement
    case decisionDomain
    case sample
    case misses
    case checks

    public var title: String {
        switch self {
        case .observation:
            return L.pick("观察期已满 14 天", "Observation period reached 14 days")
        case .settlement:
            return L.pick("结算报告已产出", "Settlement report produced")
        case .decisionDomain:
            return L.pick("判定域非空", "Decision domain is not empty")
        case .sample:
            return L.pick("样本 K ≥ 门槛 H", "Samples K ≥ threshold H")
        case .misses:
            return L.pick("L0 误判 a = 0", "L0 misjudgments a = 0")
        case .checks:
            return L.pick("L0 检查 b ≥ 1", "L0 checks b ≥ 1")
        }
    }
}

/// AC-08 组 A / 组 B 的判定（**唯一定义处**）。
public enum GateEvaluator {

    /// 门槛清单（**组 B 的展示投影**）。
    ///
    /// ## 为什么它必须和 `isQualified` 同源
    /// 界面上「五个勾是否全绿」与「开关能不能点亮」必须是**同一个判定**。
    /// 若各写一遍，迟早出现「清单全绿但开关是灰的」——那会让用户
    /// 以为产品坏了，而且没有错误可看。
    ///
    /// 所以 `isQualified` 直接由本清单推导：**全部 `passed == true`**。
    ///
    /// `passed == nil` = 无法判定（未结算 / 未取得 FDA / 数据缺失）。
    /// 它**不是失败**：界面用中性色 + 时钟，而不是红叉。
    public static func checklist(
        progress: ObservationProgress,
        settlementProduced: Bool,
        sources: [SourceGateInput]
    ) -> [GateCheckRow] {
        let domain = sources.filter { $0.source.isInDecisionDomain }

        let observation = GateCheckRow(
            kind: .observation,
            passed: progress.isDayQuotaReached,
            detail: .ratio(progress.displayCountedDays, ObservationProgress.requiredDays)
        )

        let settlement = GateCheckRow(
            kind: .settlement,
            passed: settlementProduced,
            detail: .text(
                settlementProduced
                    ? L.pick("已产出", "Produced")
                    : L.pick("未产出", "Not produced")
            )
        )

        let domainRow = GateCheckRow(
            kind: .decisionDomain,
            passed: !domain.isEmpty,
            detail: .metric(domain.count, unit: .items)
        )

        // ---- 样本：取最差来源 ----
        var sampleUnknown = false
        var worstSample: (source: Source, k: Int, h: Int)?
        for input in domain {
            guard let k = input.attributable, let t = input.total else {
                sampleUnknown = true
                continue
            }
            let h = Threshold.h(forTotal: t)
            if let current = worstSample {
                // 比较「达标程度」：k/h 越小越差；h = 0 时视为已达标
                let currentScore = current.h == 0 ? Double.greatestFiniteMagnitude
                                                  : Double(current.k) / Double(current.h)
                let newScore = h == 0 ? Double.greatestFiniteMagnitude
                                      : Double(k) / Double(h)
                if newScore < currentScore {
                    worstSample = (input.source, k, h)
                }
            } else {
                worstSample = (input.source, k, h)
            }
        }
        let samplePassed: Bool?
        if let worst = worstSample, worst.k < worst.h {
            samplePassed = false
        } else if sampleUnknown || worstSample == nil {
            // `worstSample == nil` 且 domain 非空 = 所有来源都缺 K/T → 无法判定
            samplePassed = nil
        } else {
            samplePassed = true
        }
        let sampleDetail: SemanticSlot
        if let worst = worstSample,
           let ratio = RatioSlot(numerator: Swift.min(worst.k, worst.h), denominator: worst.h) {
            sampleDetail = .ratio(ratio.numerator, ratio.denominator)
        } else {
            sampleDetail = .unavailable(reason: UICopy.notSettledThisRound)
        }
        let sampleRow = GateCheckRow(
            kind: .sample,
            passed: samplePassed,
            subject: worstSample?.source.displayName,
            detail: sampleDetail
        )

        // ---- L0 误判 / 检查：逐来源取最差 ----
        var missesUnknown = false
        var worstMiss: (source: Source, value: Int)?
        var checksUnknown = false
        var worstCheck: (source: Source, value: Int)?
        for input in domain {
            if input.undetermined {
                missesUnknown = true
                checksUnknown = true
                continue
            }
            if let a = input.missCount {
                if worstMiss == nil || a > worstMiss!.value {
                    worstMiss = (input.source, a)
                }
            } else {
                missesUnknown = true
            }
            if let b = input.checkCount {
                if worstCheck == nil || b < worstCheck!.value {
                    worstCheck = (input.source, b)
                }
            } else {
                checksUnknown = true
            }
        }
        let missPassed: Bool? = (worstMiss?.value ?? 0) != 0
            ? false
            : (missesUnknown || worstMiss == nil ? nil : true)
        let checkPassed: Bool? = (worstCheck?.value ?? 1) == 0
            ? false
            : (checksUnknown || worstCheck == nil ? nil : true)

        let missRow = GateCheckRow(
            kind: .misses,
            passed: missPassed,
            subject: worstMiss?.source.displayName,
            detail: worstMiss.map { .metric($0.value, unit: .times) }
                ?? .unavailable(reason: L.pick("本轮未判定", "Not judged this round"))
        )
        let checkRow = GateCheckRow(
            kind: .checks,
            passed: checkPassed,
            subject: worstCheck?.source.displayName,
            detail: worstCheck.map { .metric($0.value, unit: .times) }
                ?? .unavailable(reason: L.pick("本轮未判定", "Not judged this round"))
        )

        return [observation, settlement, domainRow, sampleRow, missRow, checkRow]
    }

    /// 组 A：未达项集合（与实际不满足项全等）。
    ///
    /// - 全局项：至多一项（观察期未满）
    /// - 来源项：按判定域顺序分组逐行
    ///
    /// **来源项只在报告产出后判定**（`K`/`T`/`J`/`a`/`b` 同前置）。
    public static func unmetItems(
        progress: ObservationProgress,
        settlementProduced: Bool,
        sources: [SourceGateInput]
    ) -> UnmetItems {
        var global: UnmetGlobalItem? = nil
        if !settlementProduced || !progress.isDayQuotaReached {
            global = .observationUnfinished
        }
        var items: [UnmetSourceEntry] = []
        guard settlementProduced else {
            return UnmetItems(global: global, bySource: items)
        }
        for input in sources {
            // 样本不足：`K < H` —— **与 FDA 态无关**，必须先判
            // （第 18 轮 ②‴：未取得 FDA 且手删 1 条 → 必须列「样本不足」+「L0 未判定」两项两行）
            if let k = input.attributable, let t = input.total, k < Threshold.h(forTotal: t) {
                items.append(UnmetSourceEntry(source: input.source, item: .insufficientSample))
            }
            if input.undetermined {
                items.append(UnmetSourceEntry(
                    source: input.source,
                    item: .l0Misjudged(missCount: nil, checkCount: nil, undetermined: true)
                ))
                continue
            }
            // L0 误判：`a ≠ 0` 或 `b = 0`（后者本期不可达，保留为防御性表述）
            if let a = input.missCount, a != 0 {
                items.append(UnmetSourceEntry(source: input.source, item: .l0Misjudged(missCount: a, checkCount: input.checkCount, undetermined: false)))
            } else if let b = input.checkCount, b == 0 {
                items.append(UnmetSourceEntry(source: input.source, item: .l0Misjudged(missCount: 0, checkCount: 0, undetermined: false)))
            }
        }
        return UnmetItems(global: global, bySource: items)
    }

    /// 组 B：是否达标（可点亮）。
    ///
    /// 三项**同时**满足：观察期已满 ∧ `K ≥ H` ∧ `a = 0`（且 `b ≥ 1`）。
    /// 判定域为空时**不适用**（不判为达标）——全称量词在空集上恒真。
    public static func isQualified(
        progress: ObservationProgress,
        settlementProduced: Bool,
        sources: [SourceGateInput]
    ) -> Bool {
        // **同一实现**：清单全绿 ⇔ 可点亮。见 `checklist(...)` 的注释。
        checklist(
            progress: progress,
            settlementProduced: settlementProduced,
            sources: sources
        ).allSatisfy { $0.passed == true }
    }
}

// ---------- M6 · 留存计量量 ----------

public enum RetentionPolicy {
    /// 日志保留期限 = 90 天（C3 已裁决）。
    public static let retentionDays = 90

    /// 容量阈值 = 200 MB = **200 × 10⁶** 字节（不取 2²⁰）。
    public static let capacityBytes: Int = 200 * 1_000_000

    /// 14 日内的**执行记录**不计入 200 MB 容量回收范围。
    public static let exemptionDays = 14

    /// 可回收字节 = 目录内全部 `.jsonl` 字节合计 − 14 日内**执行记录**字节合计。
    ///
    /// **减数项只含执行记录**（与 14 日豁免同侧）；
    /// **举证链 / 扫描日志不豁免**。
    public static func reclaimableBytes(
        totalJSONLBytes: Int,
        exemptExecutionRecordBytes: Int
    ) -> Int {
        max(0, totalJSONLBytes - exemptExecutionRecordBytes)
    }

    /// 回收触发条件：可回收字节 ≥ 200 × 10⁶。
    public static func shouldReclaim(reclaimableBytes: Int) -> Bool {
        reclaimableBytes >= capacityBytes
    }

    /// 14 日豁免**只作用于容量阈值，不作用于 90 天期限**。
    public static func isWithinCapacityExemption(recordAgeDays: Int) -> Bool {
        recordAgeDays < exemptionDays
    }

    /// 90 天期限对**全部记录**适用（含 14 日内记录：满 90 天仍按期限删除）。
    public static func isExpiredByTerm(recordAgeDays: Int) -> Bool {
        recordAgeDays >= retentionDays
    }
}
