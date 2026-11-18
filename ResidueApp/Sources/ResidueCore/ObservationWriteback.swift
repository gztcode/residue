import Foundation

// ============================================================
// Residue · 观察期写回层（CR-031 §3.3–§3.6）
//
// 契约来源：
//   Residue-PRD-v5.6.md（M1 观察期进度 / M3 结算 / M4 误判 / M5 检查次数）
//   Residue-R2-技术方案-v1.9.md（§5.1 载体 · §26.2 判据表）
//   docs/changes/Residue-CR-031-KJ结算写入.md（§3.3–§3.6）
//
// ## 为什么单独成层（不变量②）
//
// 写回层是「一次扫描 → 载体」的**唯一转换处**：
// 取快照、结算、`a` 写入、`b` 累计、计数日推进，全在这里发生。
// 编排层（`AppModel`）只负责把扫描结果**收集齐**再交给它 ——
// 编排层一旦自己算 `a` / `b` / `countedDays`，就出现了第二套实现，
// 两处必然分叉（这正是 CR-031 要修的断链）。
//
// ## 纯函数（不碰真文件系统）
//
// 路径探针（`probe`）与 L0 判定结果（`judgments`）都是**注入**的：
//   · 归因判据是纯函数 ⇒ 可单测、不依赖真 FS；
//   · L0 判定在 `L0Judge` 里做（那一层才碰真 FS）。
// ============================================================

/// 观察期写回层。
public enum ObservationWriteback {

    /// 一次扫描的输入（**全部判定结果都在这里**，本层不做任何探测）。
    public struct Input: Sendable {
        /// 本次扫描时刻（计数日推进 / 结算时刻 / 取快照时刻都用它）。
        public var now: Date
        /// 扫描是否**成功完成**（中止 ⇒ 不取快照、不结算、不推进计数日）。
        public var succeeded: Bool
        /// 扫描模式（`T` 快照只能由 `full` 取，见 M3）。
        public var mode: ScanEngine.Mode
        /// L0 是否降级（**同 uid** 进程枚举失败）。
        ///
        /// 降级时 `a` / `b` / 判定时刻**一律不动** ——
        /// 降级态下的判定结果不可信，写进去等于伪造证据。
        /// （跨 uid 恒 `EPERM` 不算降级，那是 APFS/TCC 正常行为。）
        public var degraded: Bool
        /// 本轮**真正扫过**的来源（不是「有权限扫的来源」）。
        ///
        /// ⚠️ 没扫过的来源**不得**参与结算：拿空 `current` 去归因
        /// 会把整份快照判成失联（= 假报告）。
        public var scannedSources: Set<Source>
        /// 本轮各来源的候选（身份键 = 路径 + birthtime）。
        public var candidates: [Source: [CandidateID]]
        /// 本轮各来源的 L0 判定结果（**逐候选**）。
        public var judgments: [Source: [CandidateID: L0Verdict]]
        /// 路径探针（三态）—— 归因用；默认走真文件系统 `lstat`。
        public var probe: @Sendable (String) -> Settlement.PathState

        public init(
            now: Date,
            succeeded: Bool,
            mode: ScanEngine.Mode,
            degraded: Bool = false,
            scannedSources: Set<Source> = [],
            candidates: [Source: [CandidateID]] = [:],
            judgments: [Source: [CandidateID: L0Verdict]] = [:],
            probe: @escaping @Sendable (String) -> Settlement.PathState = Settlement.systemPathState
        ) {
            self.now = now
            self.succeeded = succeeded
            self.mode = mode
            self.degraded = degraded
            self.scannedSources = scannedSources
            self.candidates = candidates
            self.judgments = judgments
            self.probe = probe
        }
    }

    /// 写回结果。
    public struct Outcome: Sendable {
        /// 新的载体头。
        public var header: StateHeader
        /// 新的载荷（**每来源一份**，段表每来源四段）。
        public var payloads: [Source: SourcePayload]
        /// 本次**取了快照**的来源。
        public var snapshotSources: [Source]
        /// 本次**完成结算**的来源。
        public var settledSources: [Source]

        public init(
            header: StateHeader,
            payloads: [Source: SourcePayload],
            snapshotSources: [Source] = [],
            settledSources: [Source] = []
        ) {
            self.header = header
            self.payloads = payloads
            self.snapshotSources = snapshotSources
            self.settledSources = settledSources
        }
    }

    /// 把一次扫描的结果写回载体。
    ///
    /// ## 写入顺序（契约 M1 / M3 / M4 / M5）
    ///
    /// | 步 | 做什么 | 条件 |
    /// |---|---|---|
    /// | ① | 补齐每来源的行（幂等） | 总是 |
    /// | ② | `a` 写入 + `b` 累计 | 该来源本轮扫过 ∧ **不降级** |
    /// | ③ | 取快照（写 `T` / `H` / `snapshotDate` / 快照成员集合） | 成功 ∧ `full` ∧ 判定域内 ∧ 本轮未取过 ∧ 候选非空 |
    /// | ④ | 结算（写 `K` / `J` / `settlementDate` / 无法归因条数） | 成功 ∧ 观察期已满 ∧ 已取快照 ∧ 未结算过 ∧ 本轮扫过 ∧ **本轮没取快照** |
    /// | ⑤ | 计数日推进 | **成功**（中止不推进） |
    /// | ⑥ | 结算凭证（`producedAt` / `reportId`） | 本次有来源完成结算 |
    ///
    /// ## 取快照与结算**互斥**
    ///
    /// 同一次扫描里两者可能同时成立（观察期已满 ∧ 本轮还没取过快照）。
    /// **快照优先** —— 先把本轮样本冻结下来，结算推到下一次扫描：
    /// 否则会拿「刚冻结的样本」立刻对「当下这一轮」归因，
    /// 等于用同一份数据既当样本又当现状，`K` 恒等于 `T`（失联恒为 0）。
    public static func apply(
        input: Input,
        header: StateHeader,
        payloads: [Source: SourcePayload]
    ) -> Outcome {
        var header = header
        var payloads = payloads

        // ① 每来源一行（幂等）—— 顺序 = `Source.allCases` 声明序
        header.ensureSourceRows()
        var rows: [Source: SourceHeaderEntry] = [:]
        for row in header.sources { rows[row.source] = row }

        // 观察期是否已满 —— 取**推进前**的值（结算发生在计数日推进之前）
        let observationFull = header.countedDays >= ObservationProgress.requiredDays

        var snapshotSources: [Source] = []
        var settledSources: [Source] = []

        for source in Source.allCases {
            var entry = rows[source] ?? SourceHeaderEntry(source: source)
            let payload = payloads[source] ?? SourcePayload()
            let scanned = input.scannedSources.contains(source)
            let current = input.candidates[source] ?? []

            // ② `a` 写入路径 + `b` 累计
            //
            // `b`（M5）= 本轮该来源**参与 L0 判定的候选数**。
            // 降级态下本轮**没有真正执行检查** ⇒ `a` / `b` / 判定时刻一律不动
            // （不写 0 —— 写 0 等于把「没查」说成「查了 0 条」，是伪造证据）。
            var state = payload.l0State(missCount: entry.a)
            if scanned && !input.degraded {
                MissCounter.apply(
                    state: &state,
                    judgments: input.judgments[source] ?? [:],
                    now: input.now
                )
                entry.b += current.count
                entry.lastJudgmentAt = input.now
            }
            // 位槽域大小与已计误判数**始终**与载荷对齐
            // （位图长度恒等式由它导出：不齐 ⇒ 解码端报 `E-304`）。
            entry.a = state.missCount
            entry.slotCount = state.slotTable.slotDomainSize
            entry.doneCount = state.countedDone.count

            // ③ 取快照
            //
            // 只在「本轮首次成功的 `full` 扫描」取一次，此后冻结。
            // 判定域外的来源（`pipx`）**不取快照** —— 它不参与自动删除。
            let wantsSnapshot = input.succeeded
                && input.mode == .full
                && source.isInDecisionDomain
                && !entry.snapshotTaken
                && !current.isEmpty
            if wantsSnapshot {
                entry.snapshotTaken = true
                entry.T = current.count
                entry.H = Threshold.h(forTotal: current.count)
                entry.snapshotDate = input.now
                snapshotSources.append(source)
            }

            // ④ 结算
            //
            // 样本 = **已冻结的快照成员集合**（不是本轮候选）。
            // 本轮没扫这个来源 ⇒ 不结算（拿空 `current` 归因 = 把整份快照判失联）。
            // **增量扫描不结算**：本轮 `current` 是**子集**，
            // 拿子集去归因快照 ⇒ 没扫到的那几条被误判失联 ⇒ `J` 虚高、`K` 虚低
            // ⇒ 产出一份**假报告**。结算只认 `full` 扫描。
            let members = wantsSnapshot ? current : payload.snapshotMembers
            let canSettle = input.succeeded
                && input.mode == .full
                && observationFull
                && entry.snapshotTaken
                && entry.K == nil
                && !members.isEmpty
                && scanned
                && !wantsSnapshot
            if canSettle {
                let outcome = Settlement.settle(
                    snapshot: members,
                    current: current,
                    probe: input.probe,
                    snapshotDate: entry.snapshotDate ?? input.now,
                    settlementDate: input.now
                )
                entry.K = outcome.metrics.attributable
                entry.J = outcome.metrics.lost
                entry.settlementDate = input.now
                // 无法归因条数**如实写**（不变量③：看不见的不当成 0）。
                // `nil` = 尚未结算；`0` = 已结算但无一条无法归因。
                entry.unattributableCount = outcome.unattributableCount
                settledSources.append(source)
            }

            rows[source] = entry
            payloads[source] = state.payload(snapshotMembers: members)
        }

        header.sources = Source.allCases.map { rows[$0] ?? SourceHeaderEntry(source: $0) }

        // ⑥ 结算凭证（报告产出时刻 + 报告标识）
        //
        // 凭证与结算值**同源**：有来源完成结算才写凭证
        // （凭证先行 ⇒ 界面出现「有报告、无样本」的假态）。
        if !settledSources.isEmpty {
            header.settlement.producedAt = input.now
            header.settlement.reportId = reportID(round: header.round, now: input.now)
        }

        // ⑤ 计数日推进 —— **调 Core 的 M1 唯一实现，本层不自行加一**。
        //
        // 中止扫描**不推进**（`succeeded == false`）：中止的那天不是「完成了一天观察」。
        if input.succeeded {
            var progress = ObservationProgress(
                round: header.round,
                startAnchor: header.roundStartAnchor,
                countedDays: header.countedDays
            )
            progress.advanceCountedDay(on: input.now)
            header.round = progress.round
            header.roundStartAnchor = progress.startAnchor
            header.countedDays = progress.countedDays
        }
        header.lastScanAt = input.now

        // ⑦ 未达标自动开下一轮（PRD v5.6 :68 · 〔CR-010 · R6〕）
        //
        // **顺序铁律**：必须放在「⑤ 计数日推进」**之后**。
        // 反过来（先开轮再推进）会把起算点重新锚到**结算当天**，
        // 于是「结算扫描」被误算成新轮的第 1 计数日 —— 违反 PRD :62〔R4〕
        // （新一轮的第 1 计数日 = 上一轮结束扫描完成后的**下一次**成功扫描）。
        //
        // **开轮时不取快照**（B1 TC-045 ⑤）：新轮的快照由它自己的首次成功扫描取。
        //
        // 触发判据只认「存在任一来源 `K < H`」（样本不足）；
        // `a ≠ 0` **不单独触发**（PRD :68 G-3 / TC-046）。
        if !settledSources.isEmpty {
            // 判定域内按 `Source.allCases` 序**首个** `K < H` 的来源
            // （`header.sources` 的顺序由上面的重排保证 = `Source.allCases` 序）
            let failing = header.sources.first { row in
                guard let k = row.K, let t = row.T else { return false }
                return SampleSufficiency.isInsufficient(k: k, t: t)
            }
            if let failing, let k = failing.K, let t = failing.T {
                let record = PreviousRoundRecord(
                    round: header.round,          // **开轮前**的轮次 = 被结算的那一轮
                    source: failing.source,
                    sample: k,
                    total: t,
                    settledAt: failing.settlementDate ?? input.now
                )
                header.beginNextRound(previous: record)
                // 载荷侧：清本轮快照成员集合
                // （`F` / `C_done` / 位槽占用表**保留** —— 它们是 `a` 的载体）
                for source in Source.allCases {
                    guard var payload = payloads[source] else { continue }
                    payload.clearSnapshotMembers()
                    payloads[source] = payload
                }
            }
        }

        return Outcome(
            header: header,
            payloads: payloads,
            snapshotSources: snapshotSources,
            settledSources: settledSources
        )
    }

    /// 报告标识：`R<轮次>-<unix 秒>`。
    ///
    /// 轮次 + 时刻 ⇒ **同一轮内多次结算可区分**，跨轮也不会撞。
    static func reportID(round: Int, now: Date) -> String {
        "R\(round)-\(Int(now.timeIntervalSince1970))"
    }
}
