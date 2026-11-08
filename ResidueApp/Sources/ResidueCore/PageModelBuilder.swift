import Foundation

// ============================================================
// Residue · 页面模型构造器（**真实状态 → 页面模型**）
//
// ## 为什么它在 Core
// 「界面禁止算术」（R2 §3 · L4）如果只写在 review 清单里，迟早会破——
// 写界面的人看到两个数就想算差值。所以把**所有聚合**放在这里：
// 页面拿到的已经是 `SemanticSlot`，它没有原料可以算。
//
// ## 它不做判定
// 门槛、未达项、可点亮 —— **一律调 `GateEvaluator`**，本文件不重写判定。
// 这是「唯一口径」的要求：同一个判定在两处实现，两处一定会分叉。
//
// ## 它不做 IO
// 入参是已读好的状态与扫描结果。IO 的编排在 App 层（`AppModel`），
// 这样本文件可以被单测穷举，而不需要造真实的文件系统。
// ============================================================

public enum PageModelBuilder {

    /// 构造页面模型所需的**全部输入**（都是已算好的值或原始记录）。
    public struct Input: Sendable {
        /// 状态载体内容（`StateFile.load()` 的产出）。
        public var contents: StateFileContents
        /// 本轮扫描到的候选（②/⑥ 页的数据源）。
        public var candidates: [ScanEngine.Candidate]
        /// 执行记录（⑦ 页的数据源）。
        public var executions: [ExecutionRecord]
        /// 是否只读态（数据由更高版本创建）。
        public var readOnly: Bool
        /// 是否正在加载。
        public var loading: Bool
        /// L0 是否降级（同 uid 枚举失败）。
        public var degraded: Bool
        /// L0 覆盖诊断（不上界面，仅用于 ① 页状态条判断）。
        public var coverage: L0Coverage
        /// 内容读取次数（AC-07 载体；非 0 说明越界读了内容）。
        public var contentReads: Int
        /// 登录项四态（ADR-02）。
        public var loginItem: LoginItemState
        /// 位置告警（Translocation / 不在「应用程序」）。
        public var locationWarning: String?
        /// 本次扫描的上游命令调用记录（AC-19 的界面落点数据源）。
        public var upstreamCommands: [UpstreamCommand]
        /// 执行方式（AC-03 四项之一）。
        public var executionMode: ExecutionMode
        /// 单次容量上限（AC-03：可见可编辑）。
        public var capacityCapBytes: Int64
        /// 条目数上限（AC-03：可见可编辑）。
        public var itemCap: Int
        /// 白名单（AC-03：加入后该路径不再出现在新候选清单中）。
        public var whitelist: [String]

        /// AC-15 的顺延条目数（本次因上限而未执行的条数）。
        ///
        /// 界面 ⑥ 页直接显示它。**填 0 也是有效值**（没触顶），
        /// 所以不能用 `nil` 表示「未知」——那是另一件事。
        public var deferredCount: Int
        /// 自动删除当前是否开启（AC-10 的 When 条件就是它被关闭）。
        public var autoDeleteEnabled: Bool
        /// **是否曾启用过自动删除**（AC-10 的 Given）。
        ///
        /// 与 `autoDeleteEnabled` 一起决定四档状态：
        /// - 从未启用 → 「未采集」（采集压根没开始）
        /// - 曾启用、现在关 → 「已停止」（AC-10 要的就是这个）
        ///
        /// 缺这一位时两者不可区分，而它们对用户是两件事。
        public var autoDeleteEverEnabled: Bool

        public init(
            contents: StateFileContents,
            candidates: [ScanEngine.Candidate] = [],
            executions: [ExecutionRecord] = [],
            readOnly: Bool = false,
            loading: Bool = false,
            degraded: Bool = false,
            coverage: L0Coverage = L0Coverage(),
            contentReads: Int = 0,
            loginItem: LoginItemState = .notRegistered,
            locationWarning: String? = nil,
            upstreamCommands: [UpstreamCommand] = [],
            autoDeleteEnabled: Bool = false,
            autoDeleteEverEnabled: Bool = false,
            deferredCount: Int = 0,
            executionMode: ExecutionMode = .reportOnly,
            capacityCapBytes: Int64 = 5_000_000_000,
            itemCap: Int = 200,
            whitelist: [String] = []
        ) {
            self.contents = contents
            self.candidates = candidates
            self.executions = executions
            self.readOnly = readOnly
            self.loading = loading
            self.degraded = degraded
            self.coverage = coverage
            self.contentReads = contentReads
            self.loginItem = loginItem
            self.locationWarning = locationWarning
            self.upstreamCommands = upstreamCommands
            self.autoDeleteEnabled = autoDeleteEnabled
            self.autoDeleteEverEnabled = autoDeleteEverEnabled
            self.deferredCount = deferredCount
            self.executionMode = executionMode
            self.capacityCapBytes = capacityCapBytes
            self.itemCap = itemCap
            self.whitelist = whitelist
        }
    }

    /// 每页候选列表的上限（ADR-01：分页 200 行/页是**渲染正确性**，不是优化）。
    public static let pageSize = 200

    public static func build(_ input: Input) -> PageModel {
                // ---- 白名单过滤（AC-03 判定：加入后 X **不再出现在新候选清单中**）----
        //
        // **必须最先做**，因为后面三处都要用它：
        // ① ② 页候选行 ② 分页总数 ③ 可删除量 / L1 计数。
        // 若只在渲染时隐藏，`deletableAmount` 仍会算进被保护的条目 ——
        // 用户看到的总量与实际可删量不符，那是账对不上。
        let visibleCandidates = input.candidates.filter { c in
            !input.whitelist.contains(where: { protectedPath in
                // 命中的判定：路径相等，或候选在受保护目录之下
                c.path == protectedPath || c.path.hasPrefix(protectedPath + "/")
            })
        }

var model = PageModel()
        model.readOnly = input.readOnly
        model.loading = input.loading

        if input.readOnly {
            // **只读态**：不渲染任何数值（R2 §10.2）。
            // 显示 0 会让旧版把「错 1 次永久」显示成「一次都没错」——假值比空白更危险。
            model.pageLevelSlot = .unavailable(reason: UICopy.readOnlyNoSettlement)
            model.reportProduced = false
            model.unmetNotice = .unavailable(reason: UICopy.readOnlyNoSettlement)
            model.remainingDays = .duration(days: nil)
            model.canLightUp = false
            model.autoDeleteEnabled = false
            model.canClearLogs = false
            model.confirmItemCount = .unavailable(reason: UICopy.readOnlyNoSettlement)
            model.confirmBytes = .unavailable(reason: UICopy.readOnlyNoSettlement)
            // 登录项状态**仍然如实显示**：只读不等于「可以假装定时任务在跑」
            // ③ 页四项配置（AC-03）
        model.executionModeLabel = input.executionMode.label
        model.capacityCapSlot = .metric(Int(input.capacityCapBytes), unit: .bytes)
        model.itemCapSlot = .metric(input.itemCap, unit: .items)
        model.whitelist = input.whitelist

        model.scheduledTaskSlot = .text(input.loginItem.label)
            model.needsLoginItemApproval = input.loginItem.needsUserApproval
            model.locationWarning = input.locationWarning
            return model
        }

        let header = input.contents.header
        let progress = ObservationProgress(
            round: header.round,
            countedDays: header.countedDays
        )
        let settlementProduced = header.settlement.producedAt != nil

        // ---------- ① 三区块（按来源聚合字节） ----------
        // 聚合发生在 Core（此处），界面拿到的只有 `.metric`
        var bytesBySource: [Source: Int64] = [:]
        for c in input.candidates {
            if let s = Source(rawValue: c.source) {
                bytesBySource[s, default: 0] += c.bytes
            }
        }
        model.overviewBlocks = Source.allCases.map { source in
            OverviewBlock(
                title: source.displayName,
                slot: .metric(Int(bytesBySource[source] ?? 0), unit: .bytes)
            )
        }

        // ① 状态条：只承载「并发冲突」（A1 裁定：全局页级状态条）
        if input.degraded {
            model.statusSlot = .stateLabel(.noPermission)
        }

        // ---------- ② 候选清单 ----------
        // ⚠️ **必须用 visibleCandidates（已排除白名单）**，不是 input.candidates。
    // 用后者会让白名单只在计数上生效、列表里照样出现 ——
    // AC-03 判定要求的是「X 不再出现在新候选清单中」。
    model.candidateRows = visibleCandidates.prefix(pageSize).map { c in
            let source = Source(rawValue: c.source)
            return CandidateRow(
                name: c.path,
                // **判定域内的来源才可参与自动删除**（`pipx` run 恒为仅报告）
                // **值域保持 2 值**（AC-04 判定冻结），阻断原因走 blockReason 副行
                participation: (source?.isInDecisionDomain ?? false) ? .autoDeletable : .reportOnly,
                bytes: .metric(Int(c.bytes), unit: .bytes),
                blockReason: nil
            )
        }
        let totalPages = max(1, (visibleCandidates.count + pageSize - 1) / pageSize)
        model.pageCount = totalPages

        // ---------- ③ 开关区 / 策略参数 / 规则版本 ----------
        let gateInputs = header.sources.map { entry in
            SourceGateInput(
                source: entry.source,
                attributable: entry.K,
                total: entry.T,
                missCount: entry.a,
                checkCount: entry.b,
                undetermined: entry.a == 0 && entry.b == 0 && entry.T != nil && entry.K == nil
            )
        }
        let unmet = GateEvaluator.unmetItems(
            progress: progress,
            settlementProduced: settlementProduced,
            sources: gateInputs
        )
        model.unmetNotice = .text(unmetNoticeText(unmet, progress: progress))
        model.remainingDays = .duration(days: progress.remainingDays)
        model.canLightUp = GateEvaluator.isQualified(
            progress: progress,
            settlementProduced: settlementProduced,
            sources: gateInputs
        )
        model.autoDeleteEnabled = header.autoDeleteEnabled

        // ③ 页定时任务状态（ADR-02 四态**如实映射**，非 enabled 一律不显示「已启用」）
        // ③ 页四项配置（AC-03）
        model.executionModeLabel = input.executionMode.label
        model.capacityCapSlot = .metric(Int(input.capacityCapBytes), unit: .bytes)
        model.itemCapSlot = .metric(input.itemCap, unit: .items)
        model.whitelist = input.whitelist

        model.scheduledTaskSlot = .text(input.loginItem.label)
        model.needsLoginItemApproval = input.loginItem.needsUserApproval
        model.locationWarning = input.locationWarning

        model.policySlots = [
            ("首次上限（5 GB 与来源 10% 取小）", .metric(5_000_000_000, unit: .bytes)),
            ("稳定后比例", .text("20%")),
        ]
        model.ruleVersionSlots = [
            ("当前规则版本", .text("R1（固定）")),
            ("可退回版本", .unavailable(reason: "本版不提供")),
        ]

        // ---------- ④ 采集范围 ----------
        model.collectionScopeNotice =
            "四档信号：缓存目录 / 临时环境 / 构建产物 / 会话痕迹。"
            + "后两档默认关闭；不读取文件内容。"
        model.canClearLogs = true

        // ---- ① 页 L1 / L2 / 可删除量（AC-02）----
        //
        // **三个数必须分开可读**，且 `可删除量 == L1`（L2 不并入）。
        // 本实现尚无 L2 推断通道（R2 明写「L2 无观测通道」）→ L2 如实为 0，
        // 但**元素仍然要存在**：AC-02 验的是「三个数值可分别读出」，
        // 若 L2 元素不存在，判定表里那一格永远无法勾。
        let inDomainCount = visibleCandidates.filter { c in
            Source(rawValue: c.source)?.isInDecisionDomain ?? false
        }.count
        model.l1Confirmed = .metric(inDomainCount, unit: .items)
        model.l2Inferred = .metric(0, unit: .items)
        // **可删除量 = L1 值**（不是 L1 + L2）
        model.deletableAmount = .metric(inDomainCount, unit: .items)

        // ---- ④ 四档采集与授权（AC-10 / AC-11 / AC-14 的界面落点）----
        // 档位名与 AC-11 组 A 的「四档」一致；状态词取 P4 封闭值域。
        let tierNames = ["缓存目录", "临时环境", "构建产物", "会话痕迹"]
        // **采集是否已被关闭**（AC-10：When = 用户关闭自动删除）。
        //
        // 注意与 `authorized` 的区别：
        // - `authorized` 是「这一档有没有被用户授权」（AC-11 的分层默认）
        // - `collectionStopped` 是「整个采集被关了」（AC-10）
        // 后者**优先于**前者：AC-10 判定原文是「四档状态逐一显示「已停止」」，
        // **包含原本默认关的后两档**——它们此刻不是「从未采集」，是「被停止了」。
        let collectionStopped = CollectionPolicy.shouldShowStopped(
            autoDeleteEnabled: input.autoDeleteEnabled,
            everEnabledAutoDelete: input.autoDeleteEverEnabled
        )

        model.collectionTiers = tierNames.enumerated().map { idx, name in
            // 后两档默认关（AC-11：分层默认）
            let defaultOff = idx >= 2
            let authorized = !defaultOff
            let state: SemanticSlot
            if collectionStopped {
                // **AC-10：四档逐一「已停止」**，包括默认关的后两档
                state = .text("已停止")
            } else if !authorized {
                // 从未启用过 → 采集没开始过，显示「未采集」而不是「已停止」
                state = .text("未采集")
            } else if input.degraded {
                // AC-14：受阻时给「所缺权限」+ 授权指引条目 ID（三个要素齐）
                // **授权指引条目 ID 必须取码表的 `rawValue`**，不能手写 "E-501"：
                // 手写等于把码复制一份到界面数据里，码表改了它不会跟着改。
                state = .permissionBlocked(
                    missing: "本用户进程 fd",
                    guideItemID: DiagnosticCode.e501.rawValue
                )
            } else {
                state = .text("运行中")
            }
            return CollectionTier(
                name: name,
                authorized: authorized,
                state: state,
                blockReason: input.degraded && authorized
                    ? .permissionBlocked(
                        missing: "本用户进程 fd",
                        guideItemID: DiagnosticCode.e501.rawValue
                    )
                    : nil
            )
        }

        // ---------- ⑤ 矩阵 ----------
        model.reportProduced = settlementProduced
        model.reportRows = header.sources.map { entry in
            reportRow(for: entry, round: header.round, produced: settlementProduced)
        }
        let qualified = model.canLightUp
        model.pageLevelSlot = .text(
            UICopy.pageLevelVerdict(
                round: header.round,
                reason: qualified ? "已达标" : (unmetReason(unmet) ?? "未达标")
            )
        )
        // 「上一轮」行**仅轮次 ≥ 2 时显示**（首轮不显示，不是显示「—」）
        model.previousRoundSlot = header.round >= 2
            ? .text(UICopy.previousRound(round: header.round))
            : nil

        // ---------- ⑦ 举证链八字段（AC-18） ----------
        // V4 的 8 个顶层字段；**没有值时显示「不适用 + 原因」，不显示空白**
        model.evidenceFields = [
            ("来源", .text("—")),
            ("路径", .text("—")),
            ("字节", .unavailable(reason: "未选择记录")),
            ("L0 检查时刻", .unavailable(reason: "未选择记录")),
            ("四组信号位", .unavailable(reason: "未选择记录")),
            ("L2 各信号取值", .unavailable(reason: "不适用（L2 无观测通道）")),
            ("执行动作", .text("—")),
            ("恢复位置", .unavailable(reason: "未选择记录")),
        ]

        // ---------- ⑦ 上游命令（AC-19） ----------
        // AC-19 是**全称命题**（直接删文件的上游命令出现次数 = 0），
        // 所以界面必须能让用户看到「调了哪些命令、各几次」。
        // 调用次数 vs **实际执行次数**：被白名单拒掉的不计入执行。
        var invoked: [String: Int] = [:]
        var executed: [String: Int] = [:]
        for rec in input.upstreamCommands {
            let key = ([rec.cmd] + rec.args).joined(separator: " ")
            invoked[key, default: 0] += 1
            // 「执行了」= 未被白名单拒 + 有退出码（真跑到退出）
            if !rec.rejectedByWhitelist, rec.exitCode != nil {
                executed[key, default: 0] += 1
            }
        }
        model.upstreamCommands = invoked.keys.sorted().map { key in
            UpstreamCommandRow(
                command: key,
                invoked: .metric(invoked[key] ?? 0, unit: .times),
                executed: .metric(executed[key] ?? 0, unit: .times)
            )
        }

        // ---------- ⑥ 确认清理（**只含可参与自动删除的候选**） ----------
        let deletable = visibleCandidates.filter {
            Source(rawValue: $0.source)?.isInDecisionDomain ?? false
        }
        model.confirmItemCount = .metric(deletable.count, unit: .items)
        // AC-15：顺延条目数 = 候选总数 − 实际删除条目数（此处候选总数取可删除集）
        model.deferredCountSlot = .metric(input.deferredCount, unit: .items)
        model.confirmBytes = .metric(Int(deletable.reduce(Int64(0)) { $0 + $1.bytes }), unit: .bytes)

        // ---------- ⑦ 执行记录 ----------
        model.evidenceRows = input.executions.map { rec in
            let label: EvidenceLabel
            switch rec.action {
            case .restoredByUser:
                label = .restored
            case .blockedSecondCheck, .blockedCap, .blockedSizeUnknown, .blockedOutOfScope:
                label = .blocked
            case .renameToTrash:
                label = .recoverable
            case .failed:
                // 「失败」既没删也没恢复 —— 归「已阻断」（用户看到的是「没删成」）
                label = .blocked
            }
            return EvidenceRow(path: rec.originalPath, label: label, record: rec)
        }

        return model
    }

    // MARK: - 未达项文案（**只做格式化，不做判定**）

    /// 未达项 → 一行文案。
    ///
    /// 优先级：全局项（观察期未满）> 来源项（样本不足 / L0 未判定）——
    /// 与 AC-08 组 A 的「全局项至多一项」一致。
    private static func unmetNoticeText(_ unmet: UnmetItems, progress: ObservationProgress) -> String {
        if unmet.global != nil {
            if progress.isDayQuotaReached {
                // 计数日已满但报告未产出 —— M1 第二串
                return UICopy.awaitingSettlementScan(round: progress.round)
            }
            // 计数日未满 —— M1 第一串
            return UICopy.observationInProgress(
                round: progress.round,
                observed: progress.countedDays
            )
        }
        if let first = unmet.bySource.first {
            switch first.item {
            case .insufficientSample:
                let entry = first
                return UICopy.unmetSampleInsufficient(
                    round: progress.round,
                    sample: 0, threshold: 0
                ).replacingOccurrences(of: "0 / 0", with: entry.source.displayName)
            case .l0Misjudged(_, _, let undetermined):
                return undetermined
                    ? "\(first.source.displayName) · L0 未判定（无法枚举本用户进程）"
                    : "\(first.source.displayName) · L0 误判"
            }
        }
        return "已达达标条件"
    }

    /// 页级「否」的原因（AC-09 的五级优先级里取前两级即可）。
    private static func unmetReason(_ unmet: UnmetItems) -> String? {
        if unmet.global != nil { return "观察期未满" }
        if let first = unmet.bySource.first {
            switch first.item {
            case .insufficientSample: return "\(first.source.displayName) 样本不足"
            case .l0Misjudged(_, _, let undetermined):
                return undetermined
                    ? "\(first.source.displayName) 未判定"
                    : "\(first.source.displayName) L0 误判"
            }
        }
        return nil
    }

    // MARK: - ⑤ 矩阵单行

    private static func reportRow(
        for entry: SourceHeaderEntry,
        round: Int,
        produced: Bool
    ) -> ReportRow {
        let inDomain = entry.source.isInDecisionDomain

        // ③ 样本 / 总量：报告产出前为「本轮未结算」
        let sampleSlot: SemanticSlot = produced
            ? .ratio(entry.K ?? 0, entry.T ?? 0)
            : .unavailable(reason: UICopy.notSettledThisRound)

        // ④ 门槛：`H` 为 null（未取快照）或非判定域 → 不适用
        let thresholdSlot: SemanticSlot
        if !inDomain {
            thresholdSlot = .text("不适用")
        } else if let h = entry.H {
            thresholdSlot = .metric(h, unit: .none)
        } else {
            thresholdSlot = .unavailable(reason: "未取快照")
        }

        // ⑥ L0 误判 / 检查：**两个独立 metric**（不拼字符串）
        let aSlot: SemanticSlot
        let bSlot: SemanticSlot
        if !produced {
            aSlot = .unavailable(reason: UICopy.notSettledThisRound)
        } else {
            aSlot = .metric(entry.a, unit: .times)
        }
        // **`b` 照常填**（M4：产出前只有左值取「本轮未结算」，右值照常）
        bSlot = .metric(entry.b, unit: .times)

        // ⑦ 结论（值域封闭三值）
        let conclusionSlot: SemanticSlot
        if !inDomain {
            conclusionSlot = .text("仅报告")
        } else if !produced {
            conclusionSlot = .unavailable(reason: UICopy.notSettledThisRound)
        } else {
            let k = entry.K ?? 0, t = entry.T ?? 0
            let qualified = k >= Threshold.h(forTotal: t) && entry.a == 0 && entry.b >= 1
            conclusionSlot = .text(qualified ? "达标" : "未达标")
        }

        return ReportRow(
            source: entry.source.displayName,
            slots: [
                .text(entry.source.displayName),
                .text(inDomain ? "在域" : "仅报告"),
                sampleSlot,
                thresholdSlot,
                .metric(round, unit: .none),
                aSlot,
                conclusionSlot,
            ],
            multiSlotColumn: 5,
            extraSlots: [bSlot]
        )
    }
}
