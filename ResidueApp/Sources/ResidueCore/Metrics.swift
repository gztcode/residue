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

/// 上游来源。封闭枚举（CR-038 后七类：判定域四类 = `uv` cache / `npm/_npx` /
/// brew downloads / cargo cache；域外只报告三类 = `pipx` run / pnpm store / bun cache）。
public enum Source: String, Codable, Sendable, CaseIterable {
    case uvCache = "uv_cache"
    case npmNpx = "npm_npx"
    case pipxRun = "pipx_run"
    /// CR-038 · Homebrew 下载缓存（`~/Library/Caches/Homebrew/downloads`）。
    case homebrewDownloads = "brew_downloads"
    /// CR-038 · cargo registry 缓存（`~/.cargo/registry/cache`）。
    case cargoRegistryCache = "cargo_registry_cache"
    /// CR-038 · pnpm 内容寻址 store（`~/Library/pnpm/store`）—— **只报告、不自动删**。
    case pnpmStore = "pnpm_store"
    /// CR-038 · bun 安装缓存（`~/.bun/install/cache`）—— **只报告、不自动删**。
    case bunCache = "bun_cache"

    /// 是否属判定域（参与自动删除的来源）。
    /// 契约：判定域 = 本轮观察期开始快照内命中的来源（CR-038 后为封闭枚举四类）。
    public var isInDecisionDomain: Bool {
        switch self {
        case .uvCache, .npmNpx, .homebrewDownloads, .cargoRegistryCache: return true
        case .pipxRun, .pnpmStore, .bunCache: return false
        }
    }

    /// 展示名（界面用）。
    ///
    /// ⚠️ **长度受 ⑤ 页来源列宽约束**（`Pages.swift` `columnWidth` 的 `case 0`
    /// = 100 pt，扣掉两侧 padding 只剩 84 pt）⇒ 超过 ~13 字符会**换行**，
    /// 而数据行高是**固定 32 pt**（视觉基线 v1.1）⇒ 换行会撑破该行。
    /// 故此处取短名；精确路径由 ② 页候选行与 ⑦ 页举证链给出。
    public var displayName: String {
        switch self {
        case .uvCache: return "uv cache"
        case .npmNpx: return "npm/_npx"
        case .pipxRun: return "pipx run"
        case .homebrewDownloads: return "brew downloads"
        case .cargoRegistryCache: return "cargo cache"
        case .pnpmStore: return "pnpm store"
        case .bunCache: return "bun cache"
        }
    }

    /// 候选粒度：逐条列出，还是整块算一条。
    ///
    /// - `perEntry`：每个叶子条目各算一条候选（uv / npm / pipx / brew / cargo）。
    /// - `wholeBlock`：整个来源目录算**一条**候选（pnpm / bun）。
    ///
    /// pnpm / bun 是内容寻址 + 硬链接布局（同一份文件在 store 里按哈希散落、
    /// 实际项目里的实体是硬链接）⇒ 逐条列举会产出上万个哈希碎片，
    /// 且逐条删除会误伤仍在使用的硬链接 ⇒ 本期只按整块报告。
    public var candidateGranularity: CandidateGranularity {
        switch self {
        case .pnpmStore, .bunCache: return .wholeBlock
        case .uvCache, .npmNpx, .pipxRun, .homebrewDownloads, .cargoRegistryCache: return .perEntry
        }
    }

    /// ★ 判定域成员指纹（CR-038）。
    ///
    /// 编码**全部来源及其归属**（不只是判定域成员）⇒ 任何来源集合或归属变化
    /// 都会改变本值 ⇒ 载体里存的指纹与本值不一致 ⇒ 判定域成员变了 ⇒
    /// 必须重启全局观察期。
    ///
    /// 计时器是**全局单实例**、契约明令不可按来源分裂（PRD v5.6 `:1203`）⇒
    /// 「来源变化 ⇒ 观察期重置」只能靠全局重置实现，指纹就是这条重置的触发依据。
    public static var decisionDomainSignature: String {
        allCases
            .map { "\($0.rawValue)=\($0.isInDecisionDomain ? "1" : "0")" }
            .joined(separator: "|")
    }
}

/// 来源的候选粒度（CR-038）。
public enum CandidateGranularity: String, Codable, Sendable {
    /// 逐条：每个叶子条目各算一条候选。
    case perEntry = "per_entry"
    /// 整块：整个来源目录算一条候选。
    case wholeBlock = "whole_block"
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

    /// 轮次切换（**M1 写入时刻「开轮时归零（并轮次 +1）」的唯一实现处**）。
    ///
    /// 契约依据：PRD v5.6 :68（未达标自动开下一轮）/ :107（唯一递增事件）/ :110（开轮时归零并轮次 +1）。
    ///
    /// ## 起算点为什么清空
    /// 新一轮的起算点 = **该轮首次成功扫描完成时刻**（PRD :62 〔R4〕），
    /// 本方法在开轮当下**不知道**新轮第一次成功扫描是哪一天 —— 所以清空起算点，
    /// 交给下一次成功扫描重新锚定。
    /// ⇒ 「开轮当天的结算扫描」不会被误算成新轮的第 1 计数日。
    public mutating func beginNextRound() {
        round += 1
        countedDays = 0
        startAnchor = nil
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

// ---------- M3 · 样本充分性判据（`K` 与 `H` 的比较） ----------

/// 样本充分性判据（`K` 与 `H` 的比较）——**全文唯一的 `K` 与 `H` 比较处**。
///
/// ## 为什么要有这个原语
/// 「未达标自动开下一轮」的触发条件（PRD v5.6 :68 · G-3）与门槛判定
/// （`GateEvaluator.isQualified`）判的是**同一件事**：`K` 是否够 `H`。
/// 若在写回层再写一遍 `k < Threshold.h(forTotal: t)`，就出现了第二套实现，
/// 两套必然漂移（不变量②：同一判定只有一个实现处）。
public enum SampleSufficiency {
    /// 样本是否不足（`K < H`，其中 `H = min(30, T)`）。
    ///
    /// - Note: `K` 为 `nil`（该来源本轮尚未结算）**不等于**不足 ——
    ///   契约口径是「存在任一来源 `K < H`」，`nil` 不参与比较（不变量③：`nil ≠ 0`）。
    public static func isInsufficient(k: Int, t: Int) -> Bool {
        k < Threshold.h(forTotal: t)
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

    /// 位图的**字节表示**（LSB 优先：位槽 `i` → 第 `i/8` 字节的第 `i%8` 位）。
    ///
    /// ## 长度恒等式（解码端会验，违者报 `E-304`）
    /// 长度**必须恰为 `ceil(bitCount/8)`** —— 不能是 64 位字对齐的 `byteSize`
    /// （后者会多出 1~7 个字节，解码端立刻判「段长不符」）。
    ///
    /// - Parameter bitCount: **位槽域大小**（不是候选数、也不是置位数）。
    public func dataRepresentation(bitCount: Int) -> Data {
        let byteCount = (bitCount + 7) / 8
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for slot in 0..<bitCount where isSet(slot) {
            bytes[slot / 8] |= UInt8(1 << UInt8(slot % 8))
        }
        return Data(bytes)
    }

    /// 从字节表示还原（LSB 优先，与 `dataRepresentation(bitCount:)` 互逆）。
    ///
    /// - Parameter bitCount: 位槽域大小；**超出 `bitCount` 的位一律丢弃**
    ///   （字节对齐多出来的位恒为 0，丢弃无损）。
    public init(data: Data, bitCount: Int) {
        var words = [UInt64](repeating: 0, count: (bitCount + 63) / 64)
        let limit = min(bitCount, data.count * 8)
        for slot in 0..<limit {
            let byte = data[slot / 8]
            if byte & (UInt8(1) << UInt8(slot % 8)) != 0 {
                words[slot / 64] |= (UInt64(1) << UInt64(slot % 64))
            }
        }
        self.words = words
    }

    /// 字节表示里的**置位数** —— 置位数的**唯一实现处**（不变量②）。
    ///
    /// ## 为什么数「字节表示」而不是位槽表示
    /// 载体内 `F` 位图存的就是**字节**（`SourcePayload.bitmap`），
    /// 取证字段 `fSetBits` 必须与**盘上的字节**一致 —— 那是它唯一的口径。
    /// 两种表示互为无损映射（字节补齐位恒为 0），数出来的数必然相同。
    ///
    /// - Parameter bytes: `dataRepresentation(bitCount:)` 产出的字节表示。
    public static func setBitCount(ofBytes bytes: Data) -> Int {
        bytes.reduce(0) { $0 + $1.nonzeroBitCount }
    }
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

    /// 转成载体载荷（`SourcePayload`）——**载荷 ⇄ 状态互逆的唯一桥**。
    ///
    /// ## 位图长度恒等式（解码端会验，违者报 `E-304`）
    /// 长度 = `ceil(位槽域大小 / 8)` —— **不是** `NegativeBitmap.byteSize`
    /// （后者按 64 位字对齐，会多出 1~7 字节，解码端立刻判「段长不符」）。
    ///
    /// - Parameter snapshotMembers: 快照成员集合（**不属于 M4 四项**，
    ///   是 CR-031 新增的第 4 段）。
    public func payload(snapshotMembers: [CandidateID] = []) -> SourcePayload {
        let domain = slotTable.slotDomainSize
        let slotMap = Dictionary(
            uniqueKeysWithValues: slotTable.assignments.map { (id: CandidateID, slot: Int) in
                (UInt32(slot), id)
            }
        )
        let done = countedDone.compactMap { id -> UInt32? in
            guard let slot = slotTable.slotIfAssigned(for: id) else { return nil }
            return UInt32(slot)
        }.sorted()
        return SourcePayload(
            bitmap: negativeSeen.dataRepresentation(bitCount: domain),
            countedDoneSlots: done,
            slots: slotMap,
            snapshotMembers: snapshotMembers
        )
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
    /// - 未判定（无法枚举本用户进程）的来源：调用方不应把该来源的判定传进来（`a` / `b` 均不判定）
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

    /// 从「身份键 → 位槽号」映射构造（**载荷重建用**）。
    ///
    /// `nextSlot` 由映射里的最大槽号推导（与解码器口径一致）——
    /// 位槽**只增不减**，故域大小 = 最大槽号 + 1。
    public init(assignments: [CandidateID: Int]) {
        self.assignments = assignments
        self.nextSlot = (assignments.values.max() ?? -1) + 1
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
    /// 样本不足（`K < H`）· 载荷 = 四数（`K` / `T` / `H` / `J`）。
    case insufficientSample(sample: Int, total: Int, threshold: Int, lost: Int?)
    /// L0 误判（`a ≠ 0`）· 或 `b = 0`（本期不可达）· 或未判定（`a`/`b` 未判定，无法枚举本用户进程）。
    case l0Misjudged(missCount: Int?, checkCount: Int?, undetermined: Bool)
}

/// AC-08 组 A 的全局项（至多一项，不带来源）。
public enum UnmetGlobalItem: Equatable, Sendable {
    /// 观察期未满。
    case observationUnfinished

    /// 未达项文案（唯一样式串 · M1）。
    /// - 计数日未满 → 「第 N 轮 · 观察期 x/14 天」
    /// - 计数日已满而报告未产出 → 「第 N 轮 · 观察期未满 · 待结算扫描（无需操作）」
    ///
    /// - Parameter previous: 上一轮结算记录（**存在时**在第一串后追加括注 ·
    ///   PRD v5.6 :69 ①「（上一轮样本 K/T 未达标，已自动重开）」）。
    public static func text(
        round: Int,
        countedDays: Int,
        previous: PreviousRoundRecord? = nil
    ) -> String {
        if countedDays < ObservationProgress.requiredDays {
            // **不在这里重新拼一遍**：多语言后两处译文必然分叉。
            return UICopy.observationInProgress(
                round: round, observed: countedDays, previous: previous
            )
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
    /// `J`（失联数；未判定时为 nil —— `nil ≠ 0`）
    public var lost: Int?
    /// `a`
    public var missCount: Int?
    /// `b`
    public var checkCount: Int?
    /// 该来源是否未判定（→ `a`/`b` 均不判定；原因 = 无法枚举本用户进程）
    public var undetermined: Bool

    public init(
        source: Source,
        attributable: Int?,
        total: Int?,
        lost: Int? = nil,
        missCount: Int?,
        checkCount: Int?,
        undetermined: Bool
    ) {
        self.source = source
        self.attributable = attributable
        self.total = total
        self.lost = lost
        self.missCount = missCount
        self.checkCount = checkCount
        self.undetermined = undetermined
    }
}

/// AC-08 组 A / 组 B 的判定（**唯一定义处**）。
public enum GateEvaluator {

    /// 组 A：未达项集合（与实际不满足项全等）。
    ///
    /// - 全局项：至多一项（观察期未满）
    /// - 来源项：按判定域顺序分组逐行
    ///
    /// **来源项只在报告产出后判定**（`K`/`T`/`J`/`a`/`b` 同前置）。
    ///
    /// - Parameter decisionDomain: 判定域 = **本轮观察期开始快照内命中的来源**
    ///   （契约：PRD v5.6 R9 / 架构 A1）。域外来源**从未参与判定**，
    ///   既不产未达项、也不阻断点亮。
    public static func unmetItems(
        progress: ObservationProgress,
        settlementProduced: Bool,
        decisionDomain: Set<Source>,
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
        for input in sources where decisionDomain.contains(input.source) {
            // 样本不足：`K < H` —— **与 L0 未判定态无关**，必须先判
            // （第 18 轮 ②‴：未判定且手删 1 条 → 必须列「样本不足」+「L0 未判定」两项两行）
            if let k = input.attributable, let t = input.total, SampleSufficiency.isInsufficient(k: k, t: t) {
                items.append(UnmetSourceEntry(
                    source: input.source,
                    item: .insufficientSample(
                        sample: k,
                        total: t,
                        threshold: Threshold.h(forTotal: t),
                        lost: input.lost
                    )
                ))
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
    ///
    /// - Parameter decisionDomain: 判定域 = **本轮观察期开始快照内命中的来源**。
    ///   域外来源（无本轮快照）**不参与逐来源判定**、不阻断点亮。
    public static func isQualified(
        progress: ObservationProgress,
        settlementProduced: Bool,
        decisionDomain: Set<Source>,
        sources: [SourceGateInput]
    ) -> Bool {
        let domain = sources.filter { decisionDomain.contains($0.source) }
        guard !domain.isEmpty else { return false }
        guard settlementProduced, progress.isDayQuotaReached else { return false }
        for input in domain {
            if input.undetermined { return false }
            guard let k = input.attributable, let t = input.total else { return false }
            if SampleSufficiency.isInsufficient(k: k, t: t) { return false }
            guard let a = input.missCount, a == 0 else { return false }
            guard let b = input.checkCount, b >= 1 else { return false }
        }
        return true
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
