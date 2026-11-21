import Foundation

// ============================================================
// Residue · 状态载体 `state.residue`（二进制格式）
//
// 契约落点：技术方案 §5.1 / IF-09 / §10.3；PRD v5.4 · M4「写入时刻」/ M6。
//
// ## 载体性质（契约 M4）
//   - 落**应用状态目录**下的本机状态文件
//   - **不属 N7 的 `.jsonl` 记录目录、不计入 N7 计量与容量回收**
//   - **N7「一键清除全部采集物与日志」不作用于它**
//     ⇒ 用户的清除动作**不构成 `a` 的重置路径**
//   - **应用版本变更时，载体字段（F / C_done / 位槽占用表 / a）一并清零**
//   - **轮次切换时不清零**（跨轮次累计，天然实现「错 1 次永久」）
//
// ## 文件格式（§5.1）
//   [ Magic "RSD1" 4B ][ schemaVersion u32 ][ headerLen u32 ][ headerJSON ]
//   [ segCount u32 ]
//   [ seg i: offset u64 | length u64 | kind u8 | sourceIndex u8 |
//            reserved u16 | reserved u32 ] × segCount      // 固定 24 B
//   [ payload ... ]
//   [ CRC32 of (header + segTable + payload) u32 ]
//
// ## 四条硬约束（照抄 §5.1，改动前先读 §5.1）
//   1. **段序固定**：`sources` 是数组，顺序 = `Source.allCases` 的**声明序**，
//      **不用 `Dictionary`**（Swift 每进程随机哈希种子 → 段序漂移 → 读方串段）。
//      读方按 `(sourceIndex, kind)` 索引，**不按位置猜**。`sourceIndex` 取
//      `Source.stableIndex`（显式 ABI，**不是**声明序下标这种隐式巧合），
//      改动由 `SourceABITests` 守着。
//   2. **段长恒由 `slotCount` 决定，与置位情况无关**：`F` 段长 `= ceil(slotCount/8)`。
//      加载期断言 `bitmapBytes == (slotCount + 7) / 8`，不等即 `E-304`。
//   3. **加载期校验三连**：尺寸恒等式 / 越界与重叠 / CRC32 一致。任一失败 → `E-304`，
//      **不猜、不部分加载**。
//   4. **原子写**：写临时文件 → fsync → rename。**短写 / ENOSPC 时不得 rename**
//      （否则半份文件覆盖好数据 → `a` 直接错）。
//
// 本文件不引用任何 UI；纯 IO + 序列化，便于单测。
// ============================================================

/// 状态载体的段种类（§5.1 payload：schema 1 三段、schema 2 四段）。
public enum SegmentKind: UInt8, Sendable, CaseIterable {
    /// `0x01 F` · 每来源：位图。
    case fBitmap = 0x01
    /// `0x02 C_done` · 每来源：已计过误判的槽号。
    case countedDone = 0x02
    /// `0x03 Slots` · 每来源：位槽占用表。
    case slots = 0x03
    /// `0x04 Snapshot` · 每来源：快照成员集合（**schema 2 起**）。
    case snapshot = 0x04

    /// 该段种类在给定 schema 版本中**是否存在**。
    ///
    /// schema 1 只有前三段；读到 schema 1 声称的 `0x04` 段 → `E-304`
    /// （**不猜、不部分加载**）。
    public func exists(inSchema version: Int) -> Bool {
        switch self {
        case .fBitmap, .countedDone, .slots:
            return true
        case .snapshot:
            return version >= 2
        }
    }
}

/// 状态载体的错误码（§6 错误码表）。
public enum StateFileError: Error, Sendable, Equatable {
    /// `E-301` · schema 更高 → **只读降级**（不拒绝）。
    case schemaTooNew(found: Int, supported: Int)
    /// `E-302` · 状态文件损坏（CRC / 结构失败，且无可用 `.bak`）。
    case corruptNoBackup(detail: String)
    /// `E-303` · 写短写 / `ENOSPC` / `EDQUOT`。
    case writeFailed(detail: String)
    /// `E-304` · 段校验失败（越界 / 重叠 / CRC / 位图长度不符）。
    case segmentValidationFailed(detail: String)
    /// `E-305` · 迁移空间预检不足。
    case migrationSpaceInsufficient(requiredBytes: Int, availableBytes: Int)
    /// `E-306` · 迁移恢复失败（从 `.bak` 恢复也失败）。
    case migrationRestoreFailed(detail: String)
    /// `E-308` · **已从 `.bak` 恢复成功**（提示级）。
    case restoredFromBackup

    /// 对应的诊断码。
    ///
    /// 契约评审（R3 契约维度）指出：`"E-xxx"` 字面量在源码出现 0 次，
    /// 23 个码全部只活在注释里 → 「码 ↔ 用例」逐条核对无法机器化。
    /// 这个映射与 `ScanError.diagnostic` 一起，让码进了代码。
    public var diagnostic: DiagnosticCode {
        switch self {
        case .schemaTooNew: return .e301
        case .corruptNoBackup: return .e302
        case .writeFailed: return .e303
        case .segmentValidationFailed: return .e304
        case .migrationSpaceInsufficient: return .e305
        case .migrationRestoreFailed: return .e306
        case .restoredFromBackup: return .e308
        }
    }
}

/// 段表项（**固定 24 B**，字段序与 §5.1 校验① 完全一致）。
///
/// ⚠️ 字段序不可改：读写各按一处时**必然字段错位、且 CRC 查不出**
/// （错位读到的是合法字节）。
public struct SegmentDescriptor: Sendable, Equatable {
    /// payload 在文件中的绝对偏移。
    public var offset: UInt64
    /// payload 字节数。
    public var length: UInt64
    /// 段种类。
    public var kind: SegmentKind
    /// 来源序号（= `Source.stableIndex`，载体 ABI，见 `Source.stableIndex`）。
    public var sourceIndex: UInt8
    /// 保留（写 0）。
    public var reservedU16: UInt16
    /// 保留（写 0）。
    public var reservedU32: UInt32

    public init(offset: UInt64, length: UInt64, kind: SegmentKind, sourceIndex: UInt8) {
        self.offset = offset
        self.length = length
        self.kind = kind
        self.sourceIndex = sourceIndex
        self.reservedU16 = 0
        self.reservedU32 = 0
    }

    /// **固定 24 B**。
    public static let byteCount = 24
}

/// 一个来源在载体中的段内容（schema 2 四段）。
public struct SourcePayload: Sendable, Equatable {
    /// `F` 位图（长度 = `ceil(slotCount/8)`，与置位数无关）。
    public var bitmap: Data
    /// `C_done` 已计过误判的**槽号**集合（升序）。
    public var countedDoneSlots: [UInt32]
    /// 位槽占用表：槽号 → 身份键。
    public var slots: [UInt32: CandidateID]
    /// 本轮快照的候选清单（`T` 的成员，逐条归因的对象）。
    ///
    /// **只在「本轮首次成功 full 扫描」时写入一次**，此后冻结。
    /// 与 `slots` 的区别见 CR-031 §1.3 —— 不能互相顶替。
    public var snapshotMembers: [CandidateID]

    public init(
        bitmap: Data = Data(),
        countedDoneSlots: [UInt32] = [],
        slots: [UInt32: CandidateID] = [:],
        snapshotMembers: [CandidateID] = []
    ) {
        self.bitmap = bitmap
        self.countedDoneSlots = countedDoneSlots
        self.slots = slots
        self.snapshotMembers = snapshotMembers
    }

    /// 还原成运行期状态（`SourceL0State`）——**载荷 ⇄ 状态互逆的唯一桥**。
    ///
    /// - Parameter missCount: 累计误判数 `a`（**载体里没有这一项**：它只活在文件头）。
    ///
    /// ## 位容量的口径
    /// 位图按**字节长度**反解（`bitmap.count * 8` 位）——载体里存的是**位槽域**
    /// 的大小，域大小再由 `slots` 的最大槽号 + 1 交叉核对（解码端已验过恒等式）。
    public func l0State(missCount: Int) -> SourceL0State {
        let table = SlotTable(assignments: Dictionary(
            uniqueKeysWithValues: slots.map { (slot: UInt32, id: CandidateID) in (id, Int(slot)) }
        ))
        let done = Set(countedDoneSlots.compactMap { slots[$0] })
        return SourceL0State(
            negativeSeen: NegativeBitmap(data: bitmap, bitCount: bitmap.count * 8),
            countedDone: done,
            slotTable: table,
            missCount: missCount
        )
    }

    /// `F` 位图的**置位数**（取证字段 `fSetBits` 的唯一来源）。
    ///
    /// 数的是**载体里这串字节本身** —— 不是重新推算的（不变量②：
    /// 同一判定只有一个实现处）。位图的字节表示与位槽表示无损互逆，
    /// 所以这个数就是「被判过阴性的候选数」。
    public var fSetBitCount: Int {
        NegativeBitmap.setBitCount(ofBytes: bitmap)
    }
}

extension SourcePayload {
    /// 轮次切换时清本轮快照成员集合（**不动 `a` 的三项载体**）。
    ///
    /// `bitmap`（`F`）/ `countedDoneSlots`（`C_done`）/ `slots`（位槽占用表）**必须保留** ——
    /// 它们是 `a` 的载体，保留 `a` 就必须保留它们（PRD v5.6 :68 / :71〔R7〕）。
    public mutating func clearSnapshotMembers() {
        snapshotMembers = []
    }
}

/// 上一轮的结算记录（**开轮时写入，覆盖式单槽**）。
///
/// ## 为什么必须落盘
/// 开轮时本轮的 `T` / `K` 被清零（下一轮重新取快照、重新结算），
/// 若不留存，⑤ 页的「上一轮」行就没有可显示的结算值（PRD v5.6 :69 ③）。
///
/// ## 为什么是单槽而不是按来源留档
/// 契约只要求**一行**（DAC-50（修订）四要素、TC-045 ③），
/// 且「直到下一轮开轮时才由本轮结算值替换」（PRD :69 ③）⇒ 单槽覆盖即可。
public struct PreviousRoundRecord: Codable, Sendable, Equatable {
    /// 被结算的那一轮的轮次号（显示为「第 `<N>` 轮」）。
    public var round: Int

    /// 触发开轮的来源（**只供审计，不显示**）。
    public var source: Source

    /// 样本量 `K`（该来源本轮的归因命中数）。
    public var sample: Int

    /// 快照总量 `T`（该来源本轮的快照成员数）。
    public var total: Int

    /// 冻结时刻 = 该来源完成结算的时刻。
    public var settledAt: Date

    public init(round: Int, source: Source, sample: Int, total: Int, settledAt: Date) {
        self.round = round
        self.source = source
        self.sample = sample
        self.total = total
        self.settledAt = settledAt
    }
}

/// 载体文件头（可读 JSON，供审计）。
public struct StateHeader: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var appVersion: String
    /// **判定域成员指纹**（CR-038）—— 载体写它是为了记住「这轮观察期是在
    /// **哪个判定域**下积累的」。
    ///
    /// - `nil` = **旧载体没有这个键** ⇒ 无法证明判定域未变 ⇒ 必须重置。
    /// - 判定域成员一变（新增来源进/出判定域）⇒ 指纹变 ⇒ 观察期自动重置。
    ///
    /// ⚠️ 可选属性是**向后兼容的关键**：合成 `Decodable` 对它用 `decodeIfPresent`，
    /// 旧载体解码出来是 `nil` 而不是「解码失败」（那会让载体被判损坏、整个应用进只读）。
    public var decisionDomainSignature: String?
    public var round: Int
    public var roundStartAnchor: Date?
    public var countedDays: Int
    public var countedDaysCap: Int
    public var autoDeleteEnabled: Bool
    public var lastScanAt: Date?

    /// 各来源的可读状态（**顺序 = `Source.allCases` 声明序**）。
    public var sources: [SourceHeaderEntry]

    /// 结算状态。
    public var settlement: SettlementHeader

    /// 上一轮结算记录（**单槽**；无上一轮 = `nil` ⇒ 首轮不显示「上一轮」行）。
    public var previousRound: PreviousRoundRecord?

    /// 各段的字节数（供审计；不参与加载校验）。
    public var bytes: ByteCounts

    public init(
        schemaVersion: Int = StateFileCodec.currentSchemaVersion,
        appVersion: String = "",
        decisionDomainSignature: String? = nil,
        round: Int = 1,
        roundStartAnchor: Date? = nil,
        countedDays: Int = 0,
        countedDaysCap: Int = 14,
        autoDeleteEnabled: Bool = false,
        lastScanAt: Date? = nil,
        sources: [SourceHeaderEntry] = [],
        settlement: SettlementHeader = SettlementHeader(),
        previousRound: PreviousRoundRecord? = nil,
        bytes: ByteCounts = ByteCounts()
    ) {
        self.schemaVersion = schemaVersion
        self.appVersion = appVersion
        self.decisionDomainSignature = decisionDomainSignature
        self.round = round
        self.roundStartAnchor = roundStartAnchor
        self.countedDays = countedDays
        self.countedDaysCap = countedDaysCap
        self.autoDeleteEnabled = autoDeleteEnabled
        self.lastScanAt = lastScanAt
        self.sources = sources
        self.settlement = settlement
        self.previousRound = previousRound
        self.bytes = bytes
    }
}

// MARK: - 观察期凭证清零（共享原语）

extension StateHeader {

    /// 清零**本轮观察期凭证**（PRD v5.6 M1「写入时刻」①–⑦）。
    ///
    /// ## 为什么是共享原语
    ///
    /// 「版本变更」与「schema 迁移」都要把观察期打回起点 —— 两处各写一遍必然漂移：
    /// 迁移漏清一项 = 旧快照的 `K` 被新格式继承 = 门槛拿旧证据放行。
    /// 不变量②：**同一判定只有一个实现处**。
    ///
    /// ## 清什么 / 不清什么
    ///
    /// | 清零 | 保留 |
    /// |---|---|
    /// | 计数日、起算点、结算凭证 | `appVersion`（应用版本 ≠ 载体格式） |
    /// | `T` / `K` / `J` / `H` / 快照标志 | `round`（重置当前轮次，不产生新轮次） |
    /// | `a` / `b` / 位槽数 / 已计误判数 | `autoDeleteEnabled`（用户设置） |
    /// | 取快照时刻 / 结算时刻 / 无法归因条数 / 上次判定时刻 | `countedDaysCap`（用户设置） |
    ///
    /// 载荷侧（`F` 位图 / `C_done` / 位槽占用表 / 快照成员集合）随 `a` 清零 ——
    /// 由**载荷全空**实现，不在本方法内。
    ///
    /// - Parameter clearingMissCount: 是否连 `a`（误判累计）一起清。
    ///   `true` = 应用版本变更（M4：`a` 只在应用版本变更时清零）；
    ///   `false` = 判定域指纹变更（版本没变 ⇒ `a` 保留）。
    ///
    /// ⚠️ 不变量③：尚未结算的量回到 `nil`，**不留 `0`**
    /// （`nil` = 无从归因；`0` = 已结算但无失联）。
    public mutating func resetObservationCredentials(clearingMissCount: Bool = true) {
        // ① 计数日归零 + 起算点重置
        countedDays = 0
        roundStartAnchor = nil
        // ③ 结算凭证（报告产出时刻与报告标识）随 `K` / `J` 一并清零
        settlement = SettlementHeader()

        for index in sources.indices {
            // ② `T` 待重取（快照成员集合随 `T` 一并待重取）
            sources[index].snapshotTaken = false
            sources[index].T = nil
            // ③ `K` / `J` 清零
            sources[index].K = nil
            sources[index].J = nil
            // ④ `b` 清零
            sources[index].b = 0
            // ⑥ `a` 清零（位图 / `C_done` / 位槽占用表随 `a` 一并清零）
            //
            // ⚠️ **保留 `a` 时必须同时保留它的三项载体**（`F` 位图 / `C_done` /
            //    位槽占用表）—— 那是 `a` 的载荷载体。头说「误判 2 次」而载荷里
            //    没有对应的阴性记录 ⇒ 头与载荷自相矛盾 ⇒ 误判记录凭空消失。
            //    载荷侧的保留由 `StateFile.clearCarrierForObservationReset` 负责。
            if clearingMissCount {
                sources[index].a = 0
                sources[index].slotCount = 0
                sources[index].doneCount = 0
            }
            // ⑦ `H` 随新 `T` 重算 ⇒ 先回到「未取快照」态
            sources[index].H = nil
            // 取快照时刻 / 结算时刻 / 无法归因条数 / 上次判定时刻随量一并清零
            sources[index].snapshotDate = nil
            sources[index].settlementDate = nil
            sources[index].unattributableCount = nil
            sources[index].lastJudgmentAt = nil
        }
    }

    /// 轮次切换（**未达标自动开下一轮**）——清本轮派生量，**保留 `a`**。
    ///
    /// ## 与 `resetObservationCredentials()` 的区别（**不可复用**）
    /// 那条是「应用版本变更」用的，**会清 `a`**（M4：`a` 只在应用版本变更时清零）；
    /// 本条是「轮次切换」用的，**必须保留 `a`**（PRD v5.6 :68 / :71〔R7〕/ G-3）。
    ///
    /// ## 清 / 不清对照表
    ///
    /// | 字段 | 处理 | 依据 |
    /// |---|---|---|
    /// | `round` | **+1** | PRD :110「开轮时归零（并轮次 +1）」 |
    /// | `countedDays` | 归零 | PRD :68「计时器归零（本轮计数日归零）」 |
    /// | `roundStartAnchor` | 清空 | PRD :62〔R4〕起算点 = 新轮首次成功扫描完成时刻 |
    /// | `settlement`（结算凭证） | 清零 | PRD :110「结算凭证随 `K`/`J` 一并清零」 |
    /// | 每来源 `snapshotTaken` | 清 false | 新轮要重新取快照（PRD :68「重新取快照」） |
    /// | 每来源 `T` / `H` | 清 nil | `H` 随新 `T` 重算（PRD :68 / :110⑦） |
    /// | 每来源 `K` / `J` | 清 nil | 新轮要重新结算 |
    /// | 每来源 `snapshotDate` / `settlementDate` / `unattributableCount` | 清 nil | 上一轮的时刻与条数不适用于新轮 |
    /// | 每来源 `b` | 归零 | PRD :68「计时器归零」+ R2 :1394「`b` 按来源累加…轮次切换时归零」 |
    /// | 每来源 `a` / `slotCount` / `doneCount` | **保留** | PRD :68 / :71〔R7〕「保留 L0 误判计数 `a`」（S2「错 1 次永久」） |
    /// | 每来源 `lastJudgmentAt` | **保留** | 判定记录随 `a` 一并保留 ⇒ 其时刻仍然成立 |
    /// | `appVersion` / `autoDeleteEnabled` / `countedDaysCap` | **保留** | PRD :110⑧「用户设置类字段不清零」 |
    /// | `lastScanAt` | **保留** | 本次扫描确实发生过 |
    /// | `previousRound` | **写入新记录（覆盖）** | PRD :69 ③「直到下一轮开轮时才由本轮结算值替换」 |
    public mutating func beginNextRound(previous: PreviousRoundRecord) {
        var progress = ObservationProgress(
            round: round,
            startAnchor: roundStartAnchor,
            countedDays: countedDays
        )
        progress.beginNextRound()
        round = progress.round
        roundStartAnchor = progress.startAnchor
        countedDays = progress.countedDays

        settlement = SettlementHeader()
        self.previousRound = previous

        for index in sources.indices {
            sources[index].snapshotTaken = false
            sources[index].T = nil
            sources[index].H = nil
            sources[index].K = nil
            sources[index].J = nil
            sources[index].b = 0
            sources[index].snapshotDate = nil
            sources[index].settlementDate = nil
            sources[index].unattributableCount = nil
            // `a` / `slotCount` / `doneCount` / `lastJudgmentAt` —— 保留
        }
    }

    /// 幂等补齐每个来源的行（**顺序 = `Source.allCases` 声明序**）。
    ///
    /// 已有行**原样保留**（不重置任何值）；缺失的来源补一行空行。
    ///
    /// ## 为什么需要它
    /// 载体里「每来源一行」是**载荷段表的锚**（每来源 4 段）——
    /// 行缺了就对不上段，界面上该来源的读数也整列消失。
    /// 补齐必须是**幂等**的：写回层每轮都调用它，重复调用不得改动任何既有值。
    public mutating func ensureSourceRows() {
        var existing: [Source: SourceHeaderEntry] = [:]
        for row in sources { existing[row.source] = row }
        sources = Source.allCases.map { existing[$0] ?? SourceHeaderEntry(source: $0) }
    }
}

/// 单来源的可读状态。
public struct SourceHeaderEntry: Codable, Sendable, Equatable {
    public var source: Source
    /// 快照是否已取（本轮）。
    public var snapshotTaken: Bool
    /// `T` 快照总量（**null = 本轮尚未取快照**）。
    public var T: Int?
    /// `K` 样本量（**null = 本轮报告尚未产出**）。
    public var K: Int?
    /// `J` 失联量（**null = 本轮报告尚未产出**）。
    public var J: Int?
    /// `H` 门槛（`null` 随 `T` 为 null）。
    public var H: Int?
    /// 累计误判数 `a`。
    public var a: Int
    /// 本轮 L0 检查次数 `b`。
    public var b: Int
    /// 位槽数（`slotCount`）。
    public var slotCount: Int
    /// 已计过误判的候选数（`doneCount`）。
    public var doneCount: Int
    /// 取快照时刻（M3「取快照时刻唯一」）。
    public var snapshotDate: Date?
    /// 结算时刻。
    public var settlementDate: Date?
    /// 「有 N 条无法归因」（裁决 ③）。
    ///
    /// **`nil` = 尚未结算，无从归因**；`0` = 已结算但无无法归因条目。
    /// 二者**不等价**（不变量③：`nil ≠ 0`）。
    public var unattributableCount: Int?
    /// 上次判定时刻。
    public var lastJudgmentAt: Date?

    public init(
        source: Source,
        snapshotTaken: Bool = false,
        T: Int? = nil,
        K: Int? = nil,
        J: Int? = nil,
        H: Int? = nil,
        a: Int = 0,
        b: Int = 0,
        slotCount: Int = 0,
        doneCount: Int = 0,
        snapshotDate: Date? = nil,
        settlementDate: Date? = nil,
        unattributableCount: Int? = nil,
        lastJudgmentAt: Date? = nil
    ) {
        self.source = source
        self.snapshotTaken = snapshotTaken
        self.T = T
        self.K = K
        self.J = J
        self.H = H
        self.a = a
        self.b = b
        self.slotCount = slotCount
        self.doneCount = doneCount
        self.snapshotDate = snapshotDate
        self.settlementDate = settlementDate
        self.unattributableCount = unattributableCount
        self.lastJudgmentAt = lastJudgmentAt
    }
}

/// 结算状态。
public struct SettlementHeader: Codable, Sendable, Equatable {
    public var producedAt: Date?
    public var reportId: String?

    public init(producedAt: Date? = nil, reportId: String? = nil) {
        self.producedAt = producedAt
        self.reportId = reportId
    }
}

/// 字节数（供审计）。
public struct ByteCounts: Codable, Sendable, Equatable {
    public var header: Int
    public var segTable: Int
    public var payload: Int

    public init(header: Int = 0, segTable: Int = 0, payload: Int = 0) {
        self.header = header
        self.segTable = segTable
        self.payload = payload
    }
}

/// 载体文件（解析后的完整内容）。
public struct StateFileContents: Sendable, Equatable {
    public var header: StateHeader
    /// 段表（**顺序 = 文件内顺序**）。
    public var segments: [SegmentDescriptor]
    /// 各来源的段内容（按 `Source` 索引；schema 2 = 每来源四段）。
    public var payloads: [Source: SourcePayload]
    /// 文件总字节数。
    public var fileLength: Int

    public init(
        header: StateHeader = StateHeader(),
        segments: [SegmentDescriptor] = [],
        payloads: [Source: SourcePayload] = [:],
        fileLength: Int = 0
    ) {
        self.header = header
        self.segments = segments
        self.payloads = payloads
        self.fileLength = fileLength
    }
}

/// birthtime 在二进制段里的**记录基准**（决定 f64 位模式怎么解读）。
///
/// | schema | 基准 | 为什么 |
/// |---|---|---|
/// | 1 | Unix 纪元（`timeIntervalSince1970`） | 已发布格式 —— 存量文件按此解读，不得改动 |
/// | 2 | 参考纪元 2001-01-01（`timeIntervalSinceReferenceDate`） | 往返逐位无损 |
///
/// ## 为什么 schema 2 必须换基准
///
/// `Date` 的内部表示是「相对 2001-01-01 的秒」（一个 `Double`），
/// 而 `timeIntervalSince1970` 与它之间隔着 978307200 秒
/// ⇒ 两者落在**不同的 f64 网格**上（当前量级：内部值刻度 2^-23 秒、
/// Unix 值刻度 2^-22 秒）⇒ 用 Unix 基准编码、用内部基准解读，
/// **往返必然丢 1 位**（1 ULP ≈ 1.19e-7 秒）。
///
/// 丢位的后果不是「精度略差」，而是**身份键不再相等**：
/// 1. 归因判据「路径 + birthtime 命中」不命中 ⇒ 同路径但 birthtime 不同
///    ⇒ 判「同名重建」⇒ `K = 0`、`J = T`（一份全是假失联的报告）；
/// 2. 位槽占用表的身份键被破坏 ⇒ 每轮扫描都分配新位槽 ⇒ `F` 位永不命中
///    ⇒ `a` 恒为 0。
///
/// 参考纪元基准 = `Date` 自身的 `Double` 表示 ⇒ 位模式往返 **100% 无损**。
public enum BirthtimeBase: Sendable {
    /// Unix 纪元（schema 1 存量格式）。
    case unixEpoch
    /// 参考纪元 2001-01-01（schema 2 起）。
    case referenceDate

    /// 该 schema 版本用的基准。
    public static func forSchema(_ schemaVersion: Int) -> BirthtimeBase {
        schemaVersion >= 2 ? .referenceDate : .unixEpoch
    }

    /// 编码：日期 → 待写入的 f64 值。
    public func encode(_ date: Date) -> Double {
        switch self {
        case .unixEpoch: return date.timeIntervalSince1970
        case .referenceDate: return date.timeIntervalSinceReferenceDate
        }
    }

    /// 解码：f64 值 → 日期。
    public func decode(_ value: Double) -> Date {
        switch self {
        case .unixEpoch: return Date(timeIntervalSince1970: value)
        case .referenceDate: return Date(timeIntervalSinceReferenceDate: value)
        }
    }
}

// ============================================================
// 序列化 / 反序列化
// ============================================================

/// `state.residue` 的编解码器（纯函数，无 IO）。
public enum StateFileCodec {

    /// Magic 4 B。
    public static let magic: [UInt8] = Array("RSD1".utf8)
    /// 当前支持的 schema 版本（schema 2 = 每来源四段，含 `0x04 Snapshot`）。
    public static let currentSchemaVersion = 2

    /// 当前 schema 版本（供 `StateFile` 引用）。
    public static var schemaVersion: Int { currentSchemaVersion }

    // MARK: - 写入

    /// 把载体内容编码成文件字节。
    ///
    /// **写出的 schema 版本 = `header.schemaVersion`**（不是常量）——
    /// 迁移要能造出旧版载体，读方才有东西可迁移。
    ///
    /// - Parameter payloads: 各来源的段内容。
    /// - Returns: 完整文件字节。
    public static func encode(header: StateHeader, payloads: [Source: SourcePayload]) throws -> Data {
        // 版本闸门：写不出版本不支持的载体（写出来的文件读方必然拒绝 = 在制造坏文件）。
        guard header.schemaVersion <= currentSchemaVersion else {
            throw StateFileError.schemaTooNew(
                found: header.schemaVersion,
                supported: currentSchemaVersion
            )
        }
        guard header.schemaVersion >= 1 else {
            throw StateFileError.segmentValidationFailed(
                detail: "非法 schema 版本 \(header.schemaVersion)"
            )
        }
        // schema 2 起才有第 4 段（`0x04 Snapshot`）。
        let writesSnapshot = header.schemaVersion >= 2
        // birthtime 基准随 schema 版本走（schema 1 = Unix 纪元，schema 2 = 参考纪元）。
        let birthtimeBase = BirthtimeBase.forSchema(header.schemaVersion)

        // 段序固定：按 `Source.allCases` 声明序遍历，
        // **每来源三段（schema 1）或四段（schema 2）、顺序 F → C_done → Slots → Snapshot**
        //
        // ⚠️ 段索引**必须**取 `source.stableIndex`，不能用 `enumerated()` 的序号 ——
        // 那个序号只是「恰好等于 stableIndex」，是隐式 ABI 而不是显式声明
        // （见 `Source.stableIndex` 与 `SourceABITests`）。
        var segments: [SegmentDescriptor] = []
        var payloadBytes = Data()

        for source in Source.allCases {
            guard let p = payloads[source] else { continue }
            let index = source.stableIndex

            // ① F 位图
            let fLen = UInt64(p.bitmap.count)
            segments.append(SegmentDescriptor(offset: 0, length: fLen, kind: .fBitmap, sourceIndex: index))
            payloadBytes.append(p.bitmap)

            // ② C_done（count u32 + count × u32 slot，升序）
            let done = p.countedDoneSlots.sorted()
            var doneBytes = Data()
            var doneCount = UInt32(done.count).littleEndian
            withUnsafeBytes(of: &doneCount) { doneBytes.append(contentsOf: $0) }
            for slot in done {
                var s = slot.littleEndian
                withUnsafeBytes(of: &s) { doneBytes.append(contentsOf: $0) }
            }
            segments.append(SegmentDescriptor(offset: 0, length: UInt64(doneBytes.count), kind: .countedDone, sourceIndex: index))
            payloadBytes.append(doneBytes)

            // ③ Slots（count u32 + count × { slot u32, birthtime f64, pathLen u16, path UTF8 }）
            var slotsBytes = Data()
            var slotCount = UInt32(p.slots.count).littleEndian
            withUnsafeBytes(of: &slotCount) { slotsBytes.append(contentsOf: $0) }
            // 按槽号升序写（确定性）
            for slot in p.slots.keys.sorted() {
                guard let id = p.slots[slot] else { continue }
                var s = slot.littleEndian
                withUnsafeBytes(of: &s) { slotsBytes.append(contentsOf: $0) }
                var bt = birthtimeBase.encode(id.birthtime).bitPattern
                withUnsafeBytes(of: &bt) { slotsBytes.append(contentsOf: $0) }
                let pathBytes = Array(id.path.utf8)
                var pathLen = UInt16(min(pathBytes.count, Int(UInt16.max))).littleEndian
                withUnsafeBytes(of: &pathLen) { slotsBytes.append(contentsOf: $0) }
                slotsBytes.append(contentsOf: pathBytes.prefix(Int(pathLen)))
            }
            segments.append(SegmentDescriptor(offset: 0, length: UInt64(slotsBytes.count), kind: .slots, sourceIndex: index))
            payloadBytes.append(slotsBytes)

            // ④ Snapshot（count u32 + count × { birthtime f64, pathLen u16, path UTF8 }）
            //    顺序 = 快照顺序（语义有序，不排序）。
            if writesSnapshot {
                var snapBytes = Data()
                var snapCount = UInt32(p.snapshotMembers.count).littleEndian
                withUnsafeBytes(of: &snapCount) { snapBytes.append(contentsOf: $0) }
                for member in p.snapshotMembers {
                    var bt = birthtimeBase.encode(member.birthtime).bitPattern
                    withUnsafeBytes(of: &bt) { snapBytes.append(contentsOf: $0) }
                    let pathBytes = Array(member.path.utf8)
                    var pathLen = UInt16(min(pathBytes.count, Int(UInt16.max))).littleEndian
                    withUnsafeBytes(of: &pathLen) { snapBytes.append(contentsOf: $0) }
                    snapBytes.append(contentsOf: pathBytes.prefix(Int(pathLen)))
                }
                segments.append(SegmentDescriptor(offset: 0, length: UInt64(snapBytes.count), kind: .snapshot, sourceIndex: index))
                payloadBytes.append(snapBytes)
            }
        }

        // 段表偏移：payload 起点 = 头部 + 段表之后（**此刻段数已知**）
        let headerData = try encodeHeader(header, segmentCount: segments.count)
        let headerLen = headerData.count
        let segTableLen = segments.count * SegmentDescriptor.byteCount
        let payloadStart = 4 + 4 + 4 + headerLen + 4 + segTableLen

        // 回填段偏移
        var running = UInt64(payloadStart)
        var finalSegments: [SegmentDescriptor] = []
        var segIndex = 0
        for seg in segments {
            var s = seg
            s.offset = running
            running += seg.length
            finalSegments.append(s)
            segIndex += 1
        }
        _ = segIndex

        // 段表字节
        var segTable = Data()
        for seg in finalSegments {
            var off = seg.offset.littleEndian
            withUnsafeBytes(of: &off) { segTable.append(contentsOf: $0) }
            var len = seg.length.littleEndian
            withUnsafeBytes(of: &len) { segTable.append(contentsOf: $0) }
            segTable.append(seg.kind.rawValue)
            segTable.append(seg.sourceIndex)
            var r16 = seg.reservedU16.littleEndian
            withUnsafeBytes(of: &r16) { segTable.append(contentsOf: $0) }
            var r32 = seg.reservedU32.littleEndian
            withUnsafeBytes(of: &r32) { segTable.append(contentsOf: $0) }
        }

        // CRC 覆盖 header + segTable + payload（**不含 magic / 长度字段 / CRC 自身**）
        var crcInput = Data()
        crcInput.append(headerData)
        crcInput.append(segTable)
        crcInput.append(payloadBytes)
        let crc = CRC32.checksum(crcInput)

        var out = Data()
        out.append(contentsOf: magic)
        var ver = UInt32(header.schemaVersion).littleEndian
        withUnsafeBytes(of: &ver) { out.append(contentsOf: $0) }
        var hlen = UInt32(headerLen).littleEndian
        withUnsafeBytes(of: &hlen) { out.append(contentsOf: $0) }
        out.append(headerData)
        var sc = UInt32(finalSegments.count).littleEndian
        withUnsafeBytes(of: &sc) { out.append(contentsOf: $0) }
        out.append(segTable)
        out.append(payloadBytes)
        var crcLE = crc.littleEndian
        withUnsafeBytes(of: &crcLE) { out.append(contentsOf: $0) }

        return out
    }

    /// 编码头部 JSON（**不含 bytes** —— 那是写完才知道的）。
    private static func encodeHeader(_ header: StateHeader, segmentCount: Int) throws -> Data {
        var h = header
        h.bytes = ByteCounts()   // 写时未知；读时校验不依赖它
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(h)
    }

    // MARK: - 读取

    /// 解析文件字节 → 载体内容。**任一校验失败即抛 `E-304`，不猜、不部分加载**。
    public static func decode(_ data: Data) throws -> StateFileContents {
        let fileLen = data.count

        // 前置：最小长度 = magic(4) + ver(4) + hlen(4) + segCount(4) + CRC(4) = 20
        guard fileLen >= 20 else {
            throw StateFileError.segmentValidationFailed(detail: "文件过短：\(fileLen) B < 20 B")
        }
        let bytes = [UInt8](data)

        // magic
        guard Array(bytes[0..<4]) == magic else {
            throw StateFileError.segmentValidationFailed(detail: "magic 不匹配")
        }

        func u32(at off: Int) -> UInt32 {
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(bytes[off + i]) << (8 * UInt32(i)) }
            return v
        }
        func u64(at off: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(bytes[off + i]) << (8 * UInt64(i)) }
            return v
        }

        let schemaVersion = Int(u32(at: 4))
        let headerLen = Int(u32(at: 8))

        // schema 更高 → 只读降级（E-301，**不拒绝**）
        if schemaVersion > currentSchemaVersion {
            throw StateFileError.schemaTooNew(found: schemaVersion, supported: currentSchemaVersion)
        }
        // schema 更低 → 迁移（由 `StateFile.load()` 负责，**不在 codec 层做**）；
        // 但 schema < 1 是非法版本 → 判 E-304。
        guard schemaVersion >= 1 else {
            throw StateFileError.segmentValidationFailed(
                detail: "非法 schema 版本 \(schemaVersion)"
            )
        }

        let headerEnd = 12 + headerLen
        guard headerEnd + 4 <= fileLen else {
            throw StateFileError.segmentValidationFailed(detail: "headerLen 越界")
        }
        let headerData = Data(bytes[12..<headerEnd])

        let segCountOffset = headerEnd
        let segCount = Int(u32(at: segCountOffset))
        let segTableStart = segCountOffset + 4
        let segTableEnd = segTableStart + segCount * SegmentDescriptor.byteCount
        guard segTableEnd <= fileLen else {
            throw StateFileError.segmentValidationFailed(detail: "段表越界")
        }

        // 校验① 尺寸恒等式：
        // fileLen == 4 + 4 + 4 + headerLen + 4 + 24×segCount + Σpayload + 4
        // 解析段表，拿 Σpayload
        var segments: [SegmentDescriptor] = []
        var sumPayload: UInt64 = 0
        for i in 0..<segCount {
            let base = segTableStart + i * SegmentDescriptor.byteCount
            let off = u64(at: base)
            let len = u64(at: base + 8)
            let kindRaw = bytes[base + 16]
            guard let kind = SegmentKind(rawValue: kindRaw) else {
                throw StateFileError.segmentValidationFailed(detail: "未知段种类 \(kindRaw)")
            }
            // 段种类必须**存在于该 schema 版本** —— 文件头谎称 schema 1 却带
            // schema 2 才有的 `0x04 Snapshot` 段 → 判 E-304（**不猜、不部分加载**）。
            guard kind.exists(inSchema: schemaVersion) else {
                throw StateFileError.segmentValidationFailed(
                    detail: "段种类 \(kindRaw) 不存在于 schema \(schemaVersion)"
                )
            }
            let sourceIndex = bytes[base + 17]
            let r16 = UInt16(bytes[base + 18]) | (UInt16(bytes[base + 19]) << 8)
            let r32 = u32(at: base + 20)
            segments.append(SegmentDescriptor(
                offset: off, length: len, kind: kind, sourceIndex: sourceIndex
            ))
            segments[segments.count - 1].reservedU16 = r16
            segments[segments.count - 1].reservedU32 = r32
            sumPayload += len
        }

        let expected = 4 + 4 + 4 + headerLen + 4
            + segCount * SegmentDescriptor.byteCount
            + Int(sumPayload) + 4
        guard expected == fileLen else {
            throw StateFileError.segmentValidationFailed(
                detail: "尺寸恒等式不成立：期望 \(expected) B，实为 \(fileLen) B"
            )
        }

        // 校验② 越界 / 重叠 / offset ≥ 段表末尾
        let payloadRegionStart = segTableEnd
        var intervals: [(UInt64, UInt64)] = []
        for seg in segments {
            guard seg.offset >= UInt64(payloadRegionStart) else {
                throw StateFileError.segmentValidationFailed(
                    detail: "段 offset \(seg.offset) 早于段表末尾 \(payloadRegionStart)"
                )
            }
            guard seg.offset + seg.length <= UInt64(fileLen - 4) else {
                throw StateFileError.segmentValidationFailed(detail: "段越界")
            }
            intervals.append((seg.offset, seg.offset + seg.length))
        }
        let sortedIntervals = intervals.sorted { $0.0 < $1.0 }
        for i in 1..<max(sortedIntervals.count, 1) where !sortedIntervals.isEmpty {
            if sortedIntervals[i].0 < sortedIntervals[i - 1].1 {
                throw StateFileError.segmentValidationFailed(detail: "段间重叠")
            }
        }

        // 校验③ CRC32 一致（覆盖 header + segTable + payload）
        let crcStored = u32(at: fileLen - 4)
        var crcInput = Data()
        crcInput.append(headerData)
        crcInput.append(Data(bytes[segTableStart..<segTableEnd]))
        crcInput.append(Data(bytes[payloadRegionStart..<(fileLen - 4)]))
        let crcComputed = CRC32.checksum(crcInput)
        guard crcStored == crcComputed else {
            throw StateFileError.segmentValidationFailed(
                detail: "CRC 不一致：存 \(crcStored) vs 算 \(crcComputed)"
            )
        }

        // 解析头部 JSON
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var header = try? decoder.decode(StateHeader.self, from: headerData) else {
            throw StateFileError.segmentValidationFailed(detail: "header JSON 解析失败")
        }
        // **文件里的版本优先** —— header JSON 里的 `schemaVersion` 只是冗余副本。
        // 旧载体（schema 1）的 JSON 无新字段 → 合成的 `decodeIfPresent` 天然可解。
        header.schemaVersion = schemaVersion
        header.bytes = ByteCounts(
            header: headerLen,
            segTable: segCount * SegmentDescriptor.byteCount,
            payload: Int(sumPayload)
        )

        // 解析各段内容（**按 (sourceIndex, kind) 索引，不按位置猜**）
        //
        // birthtime 基准随**文件里的 schema 版本**走 —— schema 1 的存量文件
        // 用 Unix 纪元，schema 2 用参考纪元（往返逐位无损）。
        let birthtimeBase = BirthtimeBase.forSchema(schemaVersion)
        var payloads: [Source: SourcePayload] = [:]
        for seg in segments {
            // 只认 `stableIndex` 这一个入口（见 `Source.stableIndex`）。
            guard let source = Source(stableIndex: seg.sourceIndex) else {
                throw StateFileError.segmentValidationFailed(
                    detail: "sourceIndex \(seg.sourceIndex) 越界或未知"
                )
            }
            var payload = payloads[source] ?? SourcePayload()
            let start = Int(seg.offset)
            let end = start + Int(seg.length)
            let segBytes = Data(bytes[start..<end])

            switch seg.kind {
            case .fBitmap:
                payload.bitmap = segBytes
            case .countedDone:
                payload.countedDoneSlots = try decodeCountedDone(segBytes)
            case .slots:
                payload.slots = try decodeSlots(segBytes, base: birthtimeBase)
            case .snapshot:
                payload.snapshotMembers = try decodeSnapshot(segBytes, base: birthtimeBase)
            }
            payloads[source] = payload
        }

        // 段长恒等式：F 段长 == ceil(slotCount/8)（**与置位数无关**）
        for entry in header.sources {
            guard let payload = payloads[entry.source] else { continue }
            let expectedBitmapBytes = (entry.slotCount + 7) / 8
            guard payload.bitmap.count == expectedBitmapBytes else {
                throw StateFileError.segmentValidationFailed(
                    detail: "来源 \(entry.source.displayName) 的 F 段长 \(payload.bitmap.count) B "
                          + "≠ ceil(slotCount \(entry.slotCount)/8) = \(expectedBitmapBytes) B"
                )
            }
        }

        return StateFileContents(
            header: header,
            segments: segments,
            payloads: payloads,
            fileLength: fileLen
        )
    }

    private static func decodeCountedDone(_ data: Data) throws -> [UInt32] {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return [] }
        var count: UInt32 = 0
        for i in 0..<4 { count |= UInt32(bytes[i]) << (8 * UInt32(i)) }
        let expected = 4 + Int(count) * 4
        guard bytes.count == expected else {
            throw StateFileError.segmentValidationFailed(
                detail: "C_done 段长不符：\(bytes.count) B ≠ \(expected) B"
            )
        }
        var out: [UInt32] = []
        out.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            let base = 4 + i * 4
            var v: UInt32 = 0
            for j in 0..<4 { v |= UInt32(bytes[base + j]) << (8 * UInt32(j)) }
            out.append(v)
        }
        return out
    }

    private static func decodeSlots(_ data: Data, base: BirthtimeBase) throws -> [UInt32: CandidateID] {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return [:] }
        var count: UInt32 = 0
        for i in 0..<4 { count |= UInt32(bytes[i]) << (8 * UInt32(i)) }
        var out: [UInt32: CandidateID] = [:]
        var off = 4
        for _ in 0..<Int(count) {
            guard off + 14 <= bytes.count else {
                throw StateFileError.segmentValidationFailed(detail: "Slots 段被截断")
            }
            var slot: UInt32 = 0
            for j in 0..<4 { slot |= UInt32(bytes[off + j]) << (8 * UInt32(j)) }
            var btBits: UInt64 = 0
            for j in 0..<8 { btBits |= UInt64(bytes[off + 4 + j]) << (8 * UInt64(j)) }
            var pathLen: UInt16 = 0
            pathLen |= UInt16(bytes[off + 12])
            pathLen |= UInt16(bytes[off + 13]) << 8
            off += 14
            let pl = Int(pathLen)
            guard off + pl <= bytes.count else {
                throw StateFileError.segmentValidationFailed(detail: "Slots 段路径被截断")
            }
            let pathBytes = Array(bytes[off..<(off + pl)])
            off += pl
            let path = String(decoding: pathBytes, as: UTF8.self)
            let birthtime = base.decode(Double(bitPattern: btBits))
            out[slot] = CandidateID(path: path, birthtime: birthtime)
        }
        guard off == bytes.count else {
            throw StateFileError.segmentValidationFailed(
                detail: "Slots 段有尾随字节：解析到 \(off)，全长 \(bytes.count)"
            )
        }
        return out
    }

    /// 解析 `0x04 Snapshot` 段：`count u32` + `count × { birthtime f64, pathLen u16, path UTF8 }`。
    ///
    /// **顺序 = 快照顺序**（语义有序，不排序）—— 结算逐条归因依赖顺序可核对。
    private static func decodeSnapshot(_ data: Data, base: BirthtimeBase) throws -> [CandidateID] {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return [] }
        var count: UInt32 = 0
        for i in 0..<4 { count |= UInt32(bytes[i]) << (8 * UInt32(i)) }
        var out: [CandidateID] = []
        out.reserveCapacity(Int(count))
        var off = 4
        for _ in 0..<Int(count) {
            guard off + 10 <= bytes.count else {
                throw StateFileError.segmentValidationFailed(detail: "Snapshot 段被截断")
            }
            var btBits: UInt64 = 0
            for j in 0..<8 { btBits |= UInt64(bytes[off + j]) << (8 * UInt64(j)) }
            var pathLen: UInt16 = 0
            pathLen |= UInt16(bytes[off + 8])
            pathLen |= UInt16(bytes[off + 9]) << 8
            off += 10
            let pl = Int(pathLen)
            guard off + pl <= bytes.count else {
                throw StateFileError.segmentValidationFailed(detail: "Snapshot 段路径被截断")
            }
            let pathBytes = Array(bytes[off..<(off + pl)])
            off += pl
            let path = String(decoding: pathBytes, as: UTF8.self)
            let birthtime = base.decode(Double(bitPattern: btBits))
            out.append(CandidateID(path: path, birthtime: birthtime))
        }
        guard off == bytes.count else {
            throw StateFileError.segmentValidationFailed(
                detail: "Snapshot 段有尾随字节：解析到 \(off)，全长 \(bytes.count)"
            )
        }
        return out
    }
}

/// CRC32（IEEE 多项式，与 zlib 一致）。
public enum CRC32 {
    /// 查表（延迟初始化，线程安全由 Swift 的全局 `let` 保证）。
    private static let table: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            t[i] = c
        }
        return t
    }()

    /// 计算 CRC32。
    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let idx = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ table[idx]
        }
        return crc ^ 0xFFFF_FFFF
    }
}
