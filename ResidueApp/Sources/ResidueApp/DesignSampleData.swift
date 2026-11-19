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
    /// 设计稿里的「上一轮」冻结日期 —— **本地日历日**。
    ///
    /// 用 `.current` 日历构造 ⇒ 任何时区渲染都是同一天
    /// （设计稿要求「同一份样例出同一张图」；直接用时间戳会随时区漂一天）。
    private static var designFrozenDate: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.date(from: DateComponents(year: 2023, month: 11, day: 14))!
    }

    static func skeleton() -> PageModel {
        var m = PageModel()

        // ① 七区块（CR-038：来源从三类扩到七类）
        // 顺序与生产一致（`Source.allCases`）⇒ 走查时能一眼看出顺序错位。
        // 标题取 `Source.x.displayName` 而非字面量 ⇒ 改枚举时不会漏改。
        m.overviewBlocks = [
            OverviewBlock(title: Source.uvCache.displayName, slot: .metric(2_400_000_000, unit: .bytes)),
            OverviewBlock(title: Source.npmNpx.displayName, slot: .metric(860_000_000, unit: .bytes)),
            OverviewBlock(title: Source.pipxRun.displayName, slot: .metric(140_000_000, unit: .bytes)),
            OverviewBlock(title: Source.homebrewDownloads.displayName, slot: .metric(620_000_000, unit: .bytes)),
            OverviewBlock(title: Source.cargoRegistryCache.displayName, slot: .metric(310_000_000, unit: .bytes)),
            OverviewBlock(title: Source.pnpmStore.displayName, slot: .metric(540_000_000, unit: .bytes)),
            OverviewBlock(title: Source.bunCache.displayName, slot: .metric(90_000_000, unit: .bytes)),
        ]
        // ⚠️ **合计必须与七张卡自洽** —— ① 页「来源占用合计」读的就是它，
        //    不赋值则恒为默认值 0 B，与卡片字节数直接矛盾（复必现据此判「疑似 P0」）。
        //    这里写死七张卡之和 4_960_000_000（不写求和表达式：界面层禁止算术）。
        m.totalFootprintBytes = .metric(4_960_000_000, unit: .bytes)
        // 注意：必须显式置 false。`PageModel.isFirstRunEmpty` 的默认值是 `true`
        // （生产侧由 `PageModelBuilder` 按「无候选且无 lastScanAt」判定）。
        // 样例不赋值的话，设计稿恒走**空态分支**，七张来源卡一张都不渲染，
        // 自适应网格布局从未被目视验证过。本样例有卡、有合计、有候选，即「已扫过」的常态态。
        m.isFirstRunEmpty = false

        // ② 候选行（每来源一行；pnpm / bun 是**整块**候选 ⇒ 字节 = 该来源总量）
        m.candidateRows = [
            CandidateRow(name: "uv/archive-v0/3f9a…", participation: .autoDeletable,
                         bytes: .metric(180_000_000, unit: .bytes)),
            CandidateRow(name: "npm/_npx/9c1b…", participation: .autoDeletable,
                         bytes: .metric(64_000_000, unit: .bytes)),
            CandidateRow(name: "pipx/venvs/tool-a", participation: .reportOnly,
                         bytes: .metric(52_000_000, unit: .bytes)),
            CandidateRow(name: "brew/downloads/bottle-…", participation: .autoDeletable,
                         bytes: .metric(118_000_000, unit: .bytes)),
            CandidateRow(name: "cargo/registry/cache/…crate", participation: .autoDeletable,
                         bytes: .metric(36_000_000, unit: .bytes)),
            // pnpm / bun：**内容寻址 + 硬链接**布局 ⇒ 逐条列举会误伤 ⇒ 各算一个整块，
            // 且**只报告不参与删除**。
            CandidateRow(name: "pnpm/store", participation: .reportOnly,
                         bytes: .metric(540_000_000, unit: .bytes)),
            CandidateRow(name: "bun/install/cache", participation: .reportOnly,
                         bytes: .metric(90_000_000, unit: .bytes)),
        ]
        m.pageIndex = 0
        m.pageCount = 1

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
        m.unmetSection = .rows([
            // 第 1 行：**当前轮（第 2 轮）**的样本不足 —— 数字必须与 ⑤ 页 uv 行一致
            //    （样本 27 / 总量 30、门槛 30、失联 3），否则两页互相矛盾。
            .text(
                UICopy.unmetSampleInsufficient(
                    source: Source.uvCache.displayName, sample: 27, total: 30,
                    threshold: 30, lost: 3
                ) + " · " + UICopy.unmetSampleNote()
            ),
            // 第 2 行：**另一个来源**的「L0 误判」——
            // 走查要能看见「一项一行、逐行独立、来源项各带来源标识」（DAC-74），
            // 且开关区行数由 1 变 2（验收判据 26）。取不同来源 ⇒ 不触发
            // 「因存在 L0 误判…」的归因说明（归因只附在**同一来源**的样本不足行后）。
            // ⚠️ 该来源必须与 ⑤ 页矩阵的 `a` 一致：⑤ 页 npm 是 `a = 0`（达标），
            //    若这里写 npm 有 L0 误判 ⇒ 两页矛盾（复必现正是靠这类矛盾判 P0）。
            //    故取 cargo（⑤ 页 cargo `a = 1`、检查 128 次）。
            .text(
                UICopy.unmetL0Misjudged(
                    source: Source.cargoRegistryCache.displayName, missCount: 1, checkCount: 128
                )
            ),
        ])
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

        m.l1Confirmed = .metric(12, unit: .items)
        m.l2Inferred = .metric(3, unit: .items)   // 注入非零，验证不并入可删除量
        m.deletableAmount = .metric(12, unit: .items)

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
                source: Source.uvCache.displayName,
                slots: [
                    .text(Source.uvCache.displayName),
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
                source: Source.npmNpx.displayName,
                slots: [
                    .text(Source.npmNpx.displayName),
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
            // ⚠️ **行序必须与生产一致** —— 生产是 `Source.allCases.map`
            //    ⇒ 顺序 = 枚举声明序（域内域外**交错**，不是「域内 4 行在前」）。
            //    枚举顺序不可改（存量载体段索引按声明序对齐）⇒ 生产就是这个序。
            ReportRow(
                source: Source.pipxRun.displayName,
                slots: [
                    .text(Source.pipxRun.displayName),
                    .text(L.pick("仅报告", "Report only")),
                    .unavailable(reason: UICopy.sourceNotSettled),
                    .text(L.pick("不适用", "N/A")),
                    .metric(2, unit: .none),
                    .metric(0, unit: .times),
                    .text(L.pick("仅报告", "Report only")),
                ],
                multiSlotColumn: 5,
                extraSlots: [.metric(0, unit: .times)]
            ),
            ReportRow(
                source: Source.homebrewDownloads.displayName,
                slots: [
                    .text(Source.homebrewDownloads.displayName),
                    .text(L.pick("在域", "In domain")),
                    .ratio(24, 24),
                    .metric(24, unit: .none),
                    .metric(2, unit: .none),
                    .metric(0, unit: .times),
                    .text(L.pick("达标", "Qualified")),
                ],
                multiSlotColumn: 5,
                extraSlots: [.metric(6, unit: .times)]
            ),
            ReportRow(
                source: Source.cargoRegistryCache.displayName,
                slots: [
                    .text(Source.cargoRegistryCache.displayName),
                    .text(L.pick("在域", "In domain")),
                    .ratio(30, 30),
                    .metric(30, unit: .none),
                    .metric(2, unit: .none),
                    .metric(1, unit: .times),         // L0 误判 a（与 ③ 页未达项第 2 行同源）
                    .text(L.pick("未达标", "Not qualified")),
                ],
                multiSlotColumn: 5,
                extraSlots: [.metric(128, unit: .times)]
            ),
            // ↓↓↓ 域外只报告来源（pnpm / bun）—— 判定域外两行
            //    （pipx 同属域外，但按枚举序落在第 3 位 ⇒ 见上）
            //    ③ 样本列**填「本来源未结算」而不是 0 / 0**：
            //    域外来源从不取快照 ⇒ K、T 皆 nil ⇒ 0 是**假值**（`nil ≠ 0`），
            //    且 `.ratio(0, 0)` 会显示成「0 / 0」，被读成「一条都没归因成功」。
            //    这与生产 `PageModelBuilder.reportRow` 的取值一致。
            ReportRow(
                source: Source.pnpmStore.displayName,
                slots: [
                    .text(Source.pnpmStore.displayName),
                    .text(L.pick("仅报告", "Report only")),
                    .unavailable(reason: UICopy.sourceNotSettled),
                    .text(L.pick("不适用", "N/A")),
                    .metric(2, unit: .none),
                    .metric(0, unit: .times),
                    .text(L.pick("仅报告", "Report only")),
                ],
                multiSlotColumn: 5,
                extraSlots: [.metric(0, unit: .times)]
            ),
            ReportRow(
                source: Source.bunCache.displayName,
                slots: [
                    .text(Source.bunCache.displayName),
                    .text(L.pick("仅报告", "Report only")),
                    .unavailable(reason: UICopy.sourceNotSettled),
                    .text(L.pick("不适用", "N/A")),
                    .metric(2, unit: .none),
                    .metric(0, unit: .times),
                    .text(L.pick("仅报告", "Report only")),
                ],
                multiSlotColumn: 5,
                extraSlots: [.metric(0, unit: .times)]
            ),
        ]
        // 页级状态行**必须与 M1 同构**（前置数字式），否则 DAC-55 判不通过
        m.pageLevelSlot = .text(
            UICopy.pageLevelVerdict(round: 2, reason: L.pick("uv cache 样本不足", "uv cache: insufficient samples"))
        )
        // 「上一轮」行同样前置数字式，且**四要素齐全**（DAC-50（修订））。
        //
        // 样例自洽：第 1 轮样本 11/12 未达标 ⇒ 自动重开第 2 轮；
        // 第 2 轮走满 14 天后结算为 27/30（上方矩阵）⇒ 下一轮将在下次扫描时开启。
        m.previousRoundSlot = .text(UICopy.previousRoundSettlement(
            PreviousRoundRecord(
                round: 1,
                source: .uvCache,
                sample: 11,
                total: 12,
                settledAt: designFrozenDate
            )
        ))
        m.reportProduced = true

        // ⑥
        // ⚠️ **待删集只含「可参与自动删除」的候选**（AC-04 ② / AC-09 ⑦）。
        //    ② 页七条里 `pipx/venvs/tool-a` / `pnpm/store` / `bun/install/cache`
        //    标的是「仅报告」→ **不得计入待删集**。
        //    原占位写 12 条 / 296 MB，而 180+64+52 恰好 = 296 → 复必现据此判「疑似疑似把仅报告条目计入了待删集（S-7）」。
        //    现改为：4 条（uv / npm / brew / cargo 四个 autoDeletable）/ 398 MB（180+64+118+36）。
        m.confirmItemCount = .metric(4, unit: .items)
        m.confirmBytes = .metric(398_000_000, unit: .bytes)

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
