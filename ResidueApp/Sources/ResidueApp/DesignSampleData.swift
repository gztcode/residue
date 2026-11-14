import Foundation
import ResidueCore

// ============================================================
// Residue · 渲染专用样例数据（**不是产品路径**）
//
// 只被 `PageRenderer`（`#if DEBUG`）使用，用于设计走查取色与版式核对。
// **产品路径的数据一律来自 `AppModel` → `PageModelBuilder`**，不读本文件。
//
// 保留它的理由：走查需要**可复现的确定性输入**（同一份样例出同一张图），
// 而真实状态随机器变化。但**它必须自洽**——复必现曾靠本文件的
// 三处矛盾（⑥ 待删含仅报告条目 / ③ 观察期 5-14 与 ⑤ 报告已产出互斥）
// 误判出「疑似 P0」，说明**占位数据也是产物，不自洽就会误导评审**。
// ============================================================

extension PageModel {
    static func skeleton() -> PageModel {
        var m = PageModel()

        // ① 五区块（CR-032：新增 Homebrew / pip）
        m.overviewBlocks = [
            OverviewBlock(title: "uv cache", slot: .metric(2_400_000_000, unit: .bytes)),
            OverviewBlock(title: "npm/_npx", slot: .metric(860_000_000, unit: .bytes)),
            OverviewBlock(title: "pipx run", slot: .metric(140_000_000, unit: .bytes)),
            OverviewBlock(title: Source.brewCache.displayName, slot: .metric(900_000_000, unit: .bytes)),
            OverviewBlock(title: "pip cache", slot: .metric(40_000_000, unit: .bytes)),
        ]
        // 总量与来源占比：**与上面五区块逐项相加自洽**
        // （2400 + 860 + 140 + 900 + 40 = 4340 MB）
        let totalBytes = 4_340_000_000
        m.totalScannedSlot = .metric(totalBytes, unit: .bytes)
        m.sourceShares = [
            SourceShareRow(
                sourceKey: Source.uvCache.rawValue,
                displayName: "uv cache",
                path: Source.uvCache.canonicalCachePath,
                itemCount: .metric(1_240, unit: .items),
                bytes: .metric(2_400_000_000, unit: .bytes),
                share: RatioSlot(numerator: 2_400_000_000, denominator: totalBytes),
                inDecisionDomain: true
            ),
            SourceShareRow(
                sourceKey: Source.npmNpx.rawValue,
                displayName: "npm/_npx",
                path: Source.npmNpx.canonicalCachePath,
                itemCount: .metric(430, unit: .items),
                bytes: .metric(860_000_000, unit: .bytes),
                share: RatioSlot(numerator: 860_000_000, denominator: totalBytes),
                inDecisionDomain: true
            ),
            SourceShareRow(
                sourceKey: Source.pipxRun.rawValue,
                displayName: "pipx run",
                path: Source.pipxRun.canonicalCachePath,
                itemCount: .metric(28, unit: .items),
                bytes: .metric(140_000_000, unit: .bytes),
                share: RatioSlot(numerator: 140_000_000, denominator: totalBytes),
                inDecisionDomain: false
            ),
            SourceShareRow(
                sourceKey: Source.brewCache.rawValue,
                displayName: Source.brewCache.displayName,
                path: Source.brewCache.canonicalCachePath,
                itemCount: .metric(113, unit: .items),
                bytes: .metric(900_000_000, unit: .bytes),
                share: RatioSlot(numerator: 900_000_000, denominator: totalBytes),
                inDecisionDomain: true
            ),
            SourceShareRow(
                sourceKey: Source.pipCache.rawValue,
                displayName: "pip cache",
                path: Source.pipCache.canonicalCachePath,
                itemCount: .metric(35, unit: .items),
                bytes: .metric(40_000_000, unit: .bytes),
                share: RatioSlot(numerator: 40_000_000, denominator: totalBytes),
                inDecisionDomain: false
            ),
        ]
        m.observationRatio = RatioSlot(numerator: 14, denominator: ObservationProgress.requiredDays)
        m.observationDaySlot = .ratio(14, ObservationProgress.requiredDays)

        // ② 候选行（`share` 的分母与 ① 页总占用一致）
        m.candidateRows = [
            CandidateRow(name: "uv/archive-v0/3f9a…", participation: .autoDeletable,
                         bytes: .metric(180_000_000, unit: .bytes),
                         sourceKey: Source.uvCache.rawValue,
                         share: RatioSlot(numerator: 180_000_000, denominator: totalBytes)),
            CandidateRow(name: "npm/_npx/9c1b…", participation: .autoDeletable,
                         bytes: .metric(64_000_000, unit: .bytes),
                         sourceKey: Source.npmNpx.rawValue,
                         share: RatioSlot(numerator: 64_000_000, denominator: totalBytes)),
            CandidateRow(name: "pipx/venvs/tool-a", participation: .reportOnly,
                         bytes: .metric(52_000_000, unit: .bytes),
                         sourceKey: Source.pipxRun.rawValue,
                         share: RatioSlot(numerator: 52_000_000, denominator: totalBytes)),
            // CR-032：pip 仅报告（不参与删除）——样例必须出现一行，
            // 否则走查看不到「pip 行恒『仅报告』」这条判据（DAC-109）。
            CandidateRow(name: "pip/http-v2/ab/cd/ef…", participation: .reportOnly,
                         bytes: .metric(28_000_000, unit: .bytes),
                         sourceKey: Source.pipCache.rawValue,
                         share: RatioSlot(numerator: 28_000_000, denominator: totalBytes)),
        ]
        m.pageIndex = 0
        m.pageCount = 1
        m.pageIndicatorSlot = .text(L.pick("第 1 / 1 页", "Page 1 / 1"))

        // ③ 未达项（M1 第一串，带轮次）+ 剩余天数
        // 定时任务状态（登录项四态之一）——**样例必须与构造器的结构对齐**，
        // 否则走查看不到这个卡，就会得出「界面没有定时任务状态」的错误结论。
        // 取 `.notRegistered`：本机 0 签名身份下的真实态，也最能暴露「未注册」文案是否够清楚。
        m.scheduledTaskSlot = .text(LoginItemState.notRegistered.label)
        m.needsLoginItemApproval = LoginItemState.notRegistered.needsUserApproval

        m.autoDeleteEnabled = false
        // 骨架样例：uv cache 样本不足 → 门槛未全过 → 开关不可点亮
        m.canLightUp = false
        // ⚠️ **必须与 ⑤ 页的「报告已产出」自洽**：
        //    报告只在「观察期结束扫描」时产出（M1）→ 报告已产出 ⟹ 观察期已满。
        //    故此处不能写「观察期 5/14 天」（那是未满），未达项应为**样本不足**。
        //    复必现的 M-02 正是靠这两页的矛盾发现「可能被实现成两次动作」。
        m.unmetNotice = .text(
            UICopy.unmetSampleInsufficient(round: 2, sample: 27, threshold: 30)
        )
        // 门槛清单（CR-031）：**与 canLightUp / 未达项逐条自洽** ——
        // 观察期已满、报告已产出、判定域非空、误判 0；唯一未过的是样本 27/30。
        m.gateChecks = [
            GateCheckRow(kind: .observation, passed: true,
                         detail: .ratio(14, ObservationProgress.requiredDays)),
            GateCheckRow(kind: .settlement, passed: true,
                         detail: .text(L.pick("已产出", "Produced"))),
            // 判定域 = uv / npm / Homebrew 三个（pipx 与 pip 仅报告）
            GateCheckRow(kind: .decisionDomain, passed: true,
                         detail: .metric(3, unit: .items)),
            GateCheckRow(kind: .sample, passed: false, subject: "uv cache",
                         detail: .ratio(27, 30)),
            GateCheckRow(kind: .misses, passed: true, subject: "uv cache",
                         detail: .metric(0, unit: .times)),
            GateCheckRow(kind: .checks, passed: true, subject: "npm/_npx",
                         detail: .metric(12, unit: .times)),
        ]
        m.sampleProgress = [
            SampleProgressRow(
                sourceKey: Source.uvCache.rawValue,
                displayName: "uv cache",
                ratio: RatioSlot(numerator: 27, denominator: 30),
                sample: .metric(27, unit: .items),
                threshold: .metric(30, unit: .none),
                passed: false
            ),
            SampleProgressRow(
                sourceKey: Source.npmNpx.rawValue,
                displayName: "npm/_npx",
                ratio: RatioSlot(numerator: 30, denominator: 30),
                sample: .metric(30, unit: .items),
                threshold: .metric(30, unit: .none),
                passed: true
            ),
            SampleProgressRow(
                sourceKey: Source.pipxRun.rawValue,
                displayName: "pipx run",
                ratio: nil,
                sample: .metric(0, unit: .items),
                threshold: .text(L.pick("不适用", "N/A")),
                passed: nil
            ),
            SampleProgressRow(
                sourceKey: Source.brewCache.rawValue,
                displayName: Source.brewCache.displayName,
                ratio: RatioSlot(numerator: 30, denominator: 30),
                sample: .metric(30, unit: .items),
                threshold: .metric(30, unit: .none),
                passed: true
            ),
            SampleProgressRow(
                sourceKey: Source.pipCache.rawValue,
                displayName: "pip cache",
                ratio: nil,
                sample: .metric(0, unit: .items),
                threshold: .text(L.pick("不适用", "N/A")),
                passed: nil
            ),
        ]
        m.remainingDays = .duration(days: 0)   // 观察期已满 → 14 − 14 = 0（此时「0 天」是正确值）
        m.policySlots = [
            (L.pick("首次上限（5 GB 与来源 10% 取小）", "First-run cap (lesser of 5 GB and 10% of source)"), .metric(5_000_000_000, unit: .bytes)),
            (L.pick("稳定后比例", "Steady-state ratio"), .text("20%")),
        ]
        m.ruleVersionSlots = [
            (L.pick("当前规则版本", "Current rule version"), .text(L.pick("R1（固定）", "R1 (fixed)"))),
            ("可退回版本", .unavailable(reason: L.pick("本版不提供", "Not available in this version"))),
        ]

        // ④
        m.collectionScopeNotice = L.pick("四档信号：缓存目录 / 临时环境 / 构建产物 / 会话痕迹。", "Four signal tiers: cache directories / temporary environments / build artifacts / session traces.")
            + L.pick("后两档默认关闭；不读取文件内容。", "The last two are off by default; file contents are never read.")
        m.canClearLogs = true
        // L1 / L2 / 可删除量（AC-02）：**三个数分开**，L2 不并入
        // AC-03 四项 + 白名单
        m.executionModeLabel = ExecutionMode.reportOnly.label
        m.capacityCapSlot = .metric(5_000_000_000, unit: .bytes)
        m.itemCapSlot = .metric(200, unit: .items)
        m.whitelist = ["~/.cache/uv/archive-v0/pinned"]

        // L1 / L2 / 可删除量：**与 ⑥ 批次（2 条 / 244 MB）自洽**。
        // L1 = 本次可确认删除的 2 条；L2 单列 1 条且**不并入**可删除量（AC-02）。
        m.l1Confirmed = .metric(2, unit: .items)
        m.l2Inferred = .metric(1, unit: .items)
        m.deletableAmount = .metric(2, unit: .items)
        m.reclaimableShare = RatioSlot(numerator: 244_000_000, denominator: totalBytes)

        // 四档采集与授权（AC-10 / AC-11 / AC-14）
        m.collectionTiers = [
            CollectionTier(name: L.pick("缓存目录", "Cache directories"), authorized: true, state: .text(L.pick("运行中", "Running"))),
            CollectionTier(name: L.pick("临时环境", "Temporary environments"), authorized: true, state: .text(L.pick("运行中", "Running"))),
            CollectionTier(name: L.pick("构建产物", "Build artifacts"), authorized: false, state: .text(L.pick("未采集", "Not collected"))),
            CollectionTier(name: L.pick("会话痕迹", "Session traces"), authorized: false, state: .text(L.pick("未采集", "Not collected"))),
        ]

        // ⑤ 七项矩阵（`K` / `T` 分别来自快照与样本，界面不自己算差）
        // 七列：来源 / 判定域 / 样本·总量 / 门槛 / 观察期 / L0 误判·检查 / 结论
        // ⚠️ 第 6 列是**两个独立数值**（`a` 与 `b`）→ 用 multiSlotColumn 拆成两个 `.metric`，
        //    不再拼成「0 次 · 检查 12 次」这种界面自造的数值串（DAC-47）。
        m.reportRows = [
            ReportRow(
                source: "uv cache",
                slots: [
                    .text("uv cache"),
                    .text(L.pick("在域", "In domain")),
                    .ratio(27, 30),
                    .metric(30, unit: .none),
                    .metric(2, unit: .none),          // 观察期：第几轮（数值）
                    .metric(0, unit: .times),         // L0 误判 a
                    .text(L.pick("未达标", "Not qualified")),
                ],
                multiSlotColumn: 5,
                extraSlots: [.metric(12, unit: .times)]   // 检查次数 b
            ),
            ReportRow(
                source: "npm/_npx",
                slots: [
                    .text("npm/_npx"),
                    .text(L.pick("在域", "In domain")),
                    .ratio(30, 30),
                    .metric(30, unit: .none),
                    .metric(2, unit: .none),
                    .metric(0, unit: .times),
                    .text(L.pick("达标", "Qualified")),
                ],
                multiSlotColumn: 5,
                extraSlots: [.metric(9, unit: .times)]
            ),
            // 非判定域两行：③ 两槽位（扫描值 + 标注）、④ / ⑥ 整句
            // **逐字取 PRD AC-09**（CR-033 / M-9 · R-2）：样例也是契约的一份证据，
            // 写旧值等于把缺陷画进设计稿
            ReportRow(
                source: "pipx run",
                cells: [
                    [.text("pipx run")],
                    [.text(L.pick("仅报告", "Report only"))],
                    [.metric(3, unit: .items), .unavailable(reason: UICopy.scanTimeNonSettled)],
                    [.text(UICopy.notInDecisionDomain)],
                    [.metric(2, unit: .none)],
                    [.text(UICopy.l0NotChecked)],
                    [.text(L.pick("仅报告", "Report only"))],
                ]
            ),
            ReportRow(
                source: Source.pipCache.displayName,
                cells: [
                    [.text(Source.pipCache.displayName)],
                    [.text(L.pick("仅报告", "Report only"))],
                    [.metric(7, unit: .items), .unavailable(reason: UICopy.scanTimeNonSettled)],
                    [.text(UICopy.notInDecisionDomain)],
                    [.metric(2, unit: .none)],
                    [.text(UICopy.l0NotChecked)],
                    [.text(L.pick("仅报告", "Report only"))],
                ]
            ),
        ]
        // 页级状态行**必须与 M1 同构**（前置数字式），否则 DAC-55 判不通过
        m.pageLevelSlot = .text(
            UICopy.pageLevelVerdict(round: 2, reason: L.pick("uv cache 样本不足", "uv cache: insufficient samples"))
        )
        // 「上一轮」行同样前置数字式；轮次 = 2 → 显示
        m.previousRoundSlot = .text(UICopy.previousRound(round: 2))
        m.reportProduced = true

        // ⑥
        // ⚠️ **待删集只含「可参与自动删除」的候选**（AC-04 ② / AC-09 ⑦）。
        //    ② 页三条里 `pipx/venvs/tool-a` 标的是「仅报告」→ **不得计入待删集**。
        //    原占位写 12 条 / 296 MB，而 180+64+52 恰好 = 296 → 复必现据此判「疑似疑似把仅报告条目计入了待删集（S-7）」。
        //    现改为：2 条（两个 autoDeletable）/ 244 MB（180+64）。
        m.confirmItemCount = .metric(2, unit: .items)
        m.confirmBytes = .metric(244_000_000, unit: .bytes)
        m.confirmRows = [
            ConfirmItemRow(
                path: "uv/archive-v0/3f9a…",
                sourceKey: Source.uvCache.rawValue,
                bytes: .metric(180_000_000, unit: .bytes),
                share: RatioSlot(numerator: 180_000_000, denominator: totalBytes)
            ),
            ConfirmItemRow(
                path: "npm/_npx/9c1b…",
                sourceKey: Source.npmNpx.rawValue,
                bytes: .metric(64_000_000, unit: .bytes),
                share: RatioSlot(numerator: 64_000_000, denominator: totalBytes)
            ),
        ]
        m.confirmListTruncated = false

        // ⑦
        // 举证链八字段（AC-18）
        m.evidenceFields = [
            (L.pick("来源", "Source"), .text("uv cache")),
            (L.pick("路径", "Path"), .text("~/Library/Caches/uv/archive-v0/3f9a…")),
            (L.pick("字节", "Bytes"), .metric(180_000_000, unit: .bytes)),
            (L.pick("L0 检查时刻", "L0 check time"), .text("首次 09:12 · 二次 09:14")),
            (L.pick("四组信号位", "Four signal bits"), .text("T1 命中 · L2 无通道")),
            (L.pick("L2 各信号取值", "L2 signal values"), .unavailable(reason: L.pick("不适用（L2 无观测通道）", "Not applicable (L2 has no observation channel)"))),
            (L.pick("执行动作", "Action"), .text("rename_to_trash")),
            (L.pick("恢复位置", "Restore location"), .text("~/.Trash/…3f9a.1700000000")),
        ]
        // 上游命令（AC-19）
        m.upstreamCommands = [
            UpstreamCommandRow(command: "uv cache dir",
                               invoked: .metric(1, unit: .times),
                               executed: .metric(1, unit: .times)),
            UpstreamCommandRow(command: "npm config get cache",
                               invoked: .metric(1, unit: .times),
                               executed: .metric(1, unit: .times)),
            // **被白名单拒掉**：调用 1 次、**执行 0 次** —— 这正是 AC-19 要的
            UpstreamCommandRow(command: "uv cache clean",
                               invoked: .metric(1, unit: .times),
                               executed: .metric(0, unit: .times)),
        ]
        m.deferredCountSlot = .metric(0, unit: .items)

        m.evidenceRows = [
            EvidenceRow(path: "~/Library/Caches/uv/archive-v0/3f9a…", label: .recoverable),
            EvidenceRow(path: "~/.npm/_npx/9c1b…", label: .restored),
            EvidenceRow(path: "~/Library/Caches/uv/archive-v0/7d2e…", label: .blocked),
        ]

        return m
    }
}
