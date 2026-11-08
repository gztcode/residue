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

        // ① 三区块
        m.overviewBlocks = [
            OverviewBlock(title: "uv cache", slot: .metric(2_400_000_000, unit: .bytes)),
            OverviewBlock(title: "npm/_npx", slot: .metric(860_000_000, unit: .bytes)),
            OverviewBlock(title: "pipx run", slot: .metric(140_000_000, unit: .bytes)),
        ]

        // ② 候选行
        m.candidateRows = [
            CandidateRow(name: "uv/archive-v0/3f9a…", participation: .autoDeletable,
                         bytes: .metric(180_000_000, unit: .bytes)),
            CandidateRow(name: "npm/_npx/9c1b…", participation: .autoDeletable,
                         bytes: .metric(64_000_000, unit: .bytes)),
            CandidateRow(name: "pipx/venvs/tool-a", participation: .reportOnly,
                         bytes: .metric(52_000_000, unit: .bytes)),
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
        m.unmetNotice = .text(
            UICopy.unmetSampleInsufficient(round: 2, sample: 27, threshold: 30)
        )
        m.remainingDays = .duration(days: 0)   // 观察期已满 → 14 − 14 = 0（此时「0 天」是正确值）
        m.policySlots = [
            ("首次上限（5 GB 与来源 10% 取小）", .metric(5_000_000_000, unit: .bytes)),
            ("稳定后比例", .text("20%")),
        ]
        m.ruleVersionSlots = [
            ("当前规则版本", .text("R1（固定）")),
            ("可退回版本", .unavailable(reason: "本版不提供")),
        ]

        // ④
        m.collectionScopeNotice = "四档信号：缓存目录 / 临时环境 / 构建产物 / 会话痕迹。"
            + "后两档默认关闭；不读取文件内容。"
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
            CollectionTier(name: "缓存目录", authorized: true, state: .text("运行中")),
            CollectionTier(name: "临时环境", authorized: true, state: .text("运行中")),
            CollectionTier(name: "构建产物", authorized: false, state: .text("未采集")),
            CollectionTier(name: "会话痕迹", authorized: false, state: .text("未采集")),
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
                    .text("在域"),
                    .ratio(27, 30),
                    .metric(30, unit: .none),
                    .metric(2, unit: .none),          // 观察期：第几轮（数值）
                    .metric(0, unit: .times),         // L0 误判 a
                    .text("未达标"),
                ],
                multiSlotColumn: 5,
                extraSlots: [.metric(12, unit: .times)]   // 检查次数 b
            ),
            ReportRow(
                source: "npm/_npx",
                slots: [
                    .text("npm/_npx"),
                    .text("在域"),
                    .ratio(30, 30),
                    .metric(30, unit: .none),
                    .metric(2, unit: .none),
                    .metric(0, unit: .times),
                    .text("达标"),
                ],
                multiSlotColumn: 5,
                extraSlots: [.metric(9, unit: .times)]
            ),
            ReportRow(
                source: "pipx run",
                slots: [
                    .text("pipx run"),
                    .text("仅报告"),
                    .ratio(0, 0),
                    .text("不适用"),
                    .metric(2, unit: .none),
                    .metric(0, unit: .times),
                    .text("仅报告"),
                ],
                multiSlotColumn: 5,
                extraSlots: [.metric(0, unit: .times)]
            ),
        ]
        // 页级状态行**必须与 M1 同构**（前置数字式），否则 DAC-55 判不通过
        m.pageLevelSlot = .text(
            UICopy.pageLevelVerdict(round: 2, reason: "uv cache 样本不足")
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

        // ⑦
        // 举证链八字段（AC-18）
        m.evidenceFields = [
            ("来源", .text("uv cache")),
            ("路径", .text("~/Library/Caches/uv/archive-v0/3f9a…")),
            ("字节", .metric(180_000_000, unit: .bytes)),
            ("L0 检查时刻", .text("首次 09:12 · 二次 09:14")),
            ("四组信号位", .text("T1 命中 · L2 无通道")),
            ("L2 各信号取值", .unavailable(reason: "不适用（L2 无观测通道）")),
            ("执行动作", .text("rename_to_trash")),
            ("恢复位置", .text("~/.Trash/…3f9a.1700000000")),
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
