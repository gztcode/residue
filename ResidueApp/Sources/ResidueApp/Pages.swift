import SwiftUI
import ResidueCore

// ============================================================
// Residue · 七页视图（视觉基线 §五 的骨架逐页落点）
//
// 每页顶部注释写的是「本页必须有的语义位」——即视觉基线 §五 的那张表。
// R3.8 设计走查时逐条对照这张表，而不是凭观感。
//
// ## 本版**不使用 `ScrollView`**（一个踩过的坑）
// `ImageRenderer` 不渲染 `ScrollView` 的内容 → 用 ScrollView 包着的页
// 在离屏渲染里是**整页空白**（实测：③ 页与 ⑤ 页矩阵全空）。
// 本机是无头会话、`screencapture` 全黑，离屏渲染是唯一的视觉验证手段，
// 所以骨架阶段一律用 `VStack` 直排——7 页内容在 1000×640 下都放得下。
//
// **什么时候必须加回来**：② 页候选列表超过一屏（分页 200/页仍可能超）、
// ⑦ 页执行记录超一屏。届时需改用真实 GUI 会话验证（离屏渲染验不了滚动内容），
// 这一点写进 A-9 的遗留项，不假装已覆盖。
// ============================================================

// MARK: - ① 只读存储总览
//
// 骨架：三区块 + 状态条 + 加载态
// 必须有的语义位：三区块各一个 `.metric`；状态条承载「并发冲突」
struct OverviewPage: View {
    let model: PageModel

    var body: some View {
        if model.loading {
            LoadingView(message: model.loadingMessage)
        } else {
            VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                if let status = model.statusSlot {
                    StatusBar(slot: status)
                }

                if model.overviewBlocks.isEmpty {
                    EmptyStateView(
                        message: L.pick("还没有扫描过", "No scan yet"),
                        hint: L.pick("首次扫描会在观察期内进行，不读取文件内容。", "The first scan runs during the observation period and never reads file contents.")
                    )
                } else {
                    // 三区块横向并排（总览页的语义是「一眼看完三个来源的占用」）
                    HStack(alignment: .top, spacing: Tokens.Spacing.m) {
                        ForEach(model.overviewBlocks) { block in
                            OverviewBlockCard(block: block)
                        }
                    }
                }

                // ---- L1 / L2 / 可删除量（AC-02）----
                //
                // **三个数值必须分别可读**，且 L2 **不并入**可删除量。
                // L2 只有否决权、无许可权（决策 ⑦）—— 若把它并进来，
                // 用户看到的就是一个「推断值撑着」的可删除量，
                // 那是在用不确定的东西承诺确定性。
                Card {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                        SectionTitle(text: L.pick("可释放量", "Reclaimable"))
                        HStack(alignment: .top, spacing: Tokens.Spacing.l) {
                            // ① 确定可释放（L1）
                            VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                                Text(L.pick("确定可释放（L1）", "Confirmed reclaimable (L1)"))
                                    .font(Tokens.Typography.secondary)
                                    .foregroundStyle(Tokens.Color.textSecondary)
                                SemanticSlotView(slot: model.l1Confirmed)
                                    .font(Tokens.Typography.pageTitle)
                            }
                            // ② 推断可释放（L2）—— 带「不作为删除依据」标识
                            VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                                Text(L.pick("推断可释放（L2）", "Inferred reclaimable (L2)"))
                                    .font(Tokens.Typography.secondary)
                                    .foregroundStyle(Tokens.Color.textSecondary)
                                SemanticSlotView(slot: model.l2Inferred)
                                    .font(Tokens.Typography.pageTitle)
                                // AC-02 判定：「L2 元素标识文案非空」
                                Text(model.l2Label)
                                    .font(Tokens.Typography.secondary)
                                    .foregroundStyle(Tokens.Color.textSecondary)
                            }
                            // ③ 可删除量（= L1，**独立元素**）
                            VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                                Text(L.pick("可删除量", "Deletable amount"))
                                    .font(Tokens.Typography.secondary)
                                    .foregroundStyle(Tokens.Color.textSecondary)
                                SemanticSlotView(slot: model.deletableAmount)
                                    .font(Tokens.Typography.pageTitle)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                Spacer()
            }
            .padding(Tokens.Spacing.m)
        }
    }
}

/// 单块占用卡（**数值是本页的视觉主体**）。
struct OverviewBlockCard: View {
    let block: OverviewBlock

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text(block.title)
                .font(Tokens.Typography.secondary)
                .foregroundStyle(Tokens.Color.textSecondary)

            // 数值用页面标题字号（17 pt）——它是这一块的全部信息
            SemanticSlotView(slot: block.slot, font: Tokens.Typography.pageTitle)
        }
        .padding(Tokens.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Color.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
    }
}

// MARK: - ② 环境明细与候选清单
//
// 骨架：分页列表（≤ 200 行/页）
// 必须有的语义位：每行一个标签（可参与自动删除 / 仅报告）+ `.metric(bytes)`
struct EnvironmentsPage: View {
    let model: PageModel
    @Environment(\.residueRenderMode) private var renderMode

    var body: some View {
        if model.candidateRows.isEmpty {
            EmptyStateView(
                message: L.pick("没有可清理的候选", "No candidates to clean up"),
                hint: L.pick("扫描范围内未发现缓存、临时环境或构建产物。", "No caches, temporary environments, or build artifacts were found in the scan scope.")
            )
        } else {
            VStack(spacing: 0) {
                // 产品路径用 ScrollView（200 行/页必须能滚）；渲染路径直排。
                // 见 Components.swift 的「渲染模式环境开关」注释——不要为了渲染删产品能力。
                if renderMode {
                    candidateList
                } else {
                    ScrollView { candidateList }
                }

                HStack {
                    Spacer()
                    SemanticSlotView(
                        slot: .text(L.pick(
                            "第 \(model.pageIndex + 1) / \(model.pageCount) 页",
                            "Page \(model.pageIndex + 1) / \(model.pageCount)"
                        )),
                        muted: true
                    )
                }
                .padding(.horizontal, Tokens.Spacing.m)
                .padding(.vertical, Tokens.Spacing.xs)

                Spacer()
            }
        }
    }

    /// 候选行列表（产品与渲染共用同一份内容，只有容器不同）。
    @ViewBuilder
    private var candidateList: some View {
        LazyVStack(spacing: 0) {
                    ForEach(model.candidateRows) { row in
                        HStack(spacing: Tokens.Spacing.xs) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(row.name)
                                    .font(Tokens.Typography.body)
                                    .foregroundStyle(Tokens.Color.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                // **阻断原因副行**（AC-05 L0 / AC-06 L2 / AC-17 二次检查）。
                                // 放副行而不是标签，是因为 AC-04 把标签值域冻结成 2 值。
                                if let block = row.blockReason {
                                    SemanticSlotView(slot: block, font: Tokens.Typography.secondary)
                                }
                            }

                            ParticipationBadge(participation: row.participation)

                            Spacer(minLength: Tokens.Spacing.xs)

                            SemanticSlotView(slot: row.bytes, muted: true)
                        }
                        .frame(height: Tokens.Typography.tableRowHeight)
                        .padding(.horizontal, Tokens.Spacing.m)

                        DividerLine()
                    }
        }
    }
}

/// 参与度徽标（**视觉基线 v1.1 §二：逐行属性标记永久不进入信号色**）。
///
/// 靠**图标形状**区分，不靠颜色稀缺——这正是 §二 自己写的
/// 「七态靠图标与文案区分，不靠颜色堆叠」贯彻到行内标记。
struct ParticipationBadge: View {
    let participation: CandidateParticipation

    var body: some View {
        HStack(spacing: Tokens.Spacing.xxs) {
            Image(systemName: participation.symbolName)
                .font(.system(size: Tokens.Icon.badge))
            Text(participation.label)
                .font(Tokens.Typography.secondary)
        }
        .foregroundStyle(Tokens.Color.textSecondary)
        .padding(.horizontal, Tokens.Spacing.xs)
        .padding(.vertical, Tokens.Spacing.xxs)
        .background(
            Tokens.Color.textSecondary.opacity(0.12),
            in: RoundedRectangle(cornerRadius: Tokens.Radius.badge)
        )
    }
}

// MARK: - ③ 清理策略配置
//
// 骨架：表单 + **两个不重叠的语义位**（清理策略参数 / 规则版本）
// 必须有的语义位：开关区未达项文案（带轮次）；剩余天数 `.duration`
struct PolicyPage: View {
    let model: PageModel
    /// 「去系统设置允许」的动作（只在登录项 `.requiresApproval` 时出现）。
    var onOpenLoginSettings: () -> Void = {}
    /// 改执行方式（AC-03 四项之一）。
    var onSetExecutionMode: (ExecutionMode) -> Void = { _ in }
    /// 加入 / 移出白名单（AC-03：用户唯一的主动保护动作）。
    var onAddWhitelist: (String) -> Void = { _ in }
    var onRemoveWhitelist: (String) -> Void = { _ in }
    /// 白名单输入框的临时内容（页面局部状态）。
    @State private var whitelistDraft = ""
    /// 渲染模式（产品走 ScrollView、渲染走直排）。
    @Environment(\.residueRenderMode) private var renderMode

    var body: some View {
        // **本页内容远超一屏**（开关 + 清理策略 + 白名单 + 定时任务 + 规则版本）。
        // 产品路径必须可滚；渲染路径直排（离屏渲染不渲染 ScrollView 内容）。
        if renderMode {
            // 渲染路径：**顶部对齐**，让走查看到完整的第一屏顶部。
            // 不这么写的话 VStack 会居中，上下同时被切 —— 顶部标题看不见，
            // 走查就无法确认「页头是否存在」。（底部被裁是真实的：产品有 ScrollView。）
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
        } else {
            ScrollView { content }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {

            // ---- 开关区 ----
            Card {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    // 开关本体（AC-08 的核心对象：用户「尝试点亮」的那个开关）
                    HStack {
                        SectionTitle(text: L.pick("自动删除", "Auto-delete"))
                        Spacer()
                        // 自建开关（系统 `.switch` 在离屏渲染下不可用，且不符合 token 约束）
                        TokenSwitch(
                            isOn: model.autoDeleteEnabled,
                            enabled: model.canLightUp && !model.readOnly
                        )
                    }

                    // 未达项（带轮次，M1 唯一串）与剩余天数**同址**
                    HStack(alignment: .firstTextBaseline) {
                        if let unmet = model.unmetNotice {
                            SemanticSlotView(slot: unmet)
                        } else {
                            SemanticSlotView(slot: .text(L.pick("未达项读取中", "Loading unmet items")), muted: true)
                        }
                        Spacer(minLength: Tokens.Spacing.s)
                        // 视觉基线 §五：「剩余天数」与未达项同一语义位旁另设一格
                        SemanticSlotView(slot: model.remainingDays, muted: true)
                    }
                }
            }

            // ---- 清理策略参数（AC-03 四项 + 白名单）----
            //
            // 这一块是 AC-03 的全部落点。此前 ③ 页只有开关与两个数值，
            // 缺「执行方式 / 单次上限 / 条目数上限 / 白名单」四项 ——
            // 而白名单是**用户唯一的主动保护动作**（查必究 B-1 指出它
            // 在冒烟集与回归集里双双为零，原因就是界面上根本没有入口）。
            Card {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                    SectionTitle(text: L.pick("清理策略", "Cleanup policy"))

                    // ① 执行方式（默认「仅报告」）
                    HStack(spacing: Tokens.Spacing.xs) {
                        Text(L.pick("执行方式", "Execution mode"))
                            .font(Tokens.Typography.secondary)
                            .foregroundStyle(Tokens.Color.textSecondary)
                            .frame(width: 88, alignment: .leading)
                        ForEach(ExecutionMode.allCases, id: \.self) { mode in
                            Button(mode.label) { onSetExecutionMode(mode) }
                                .buttonStyle(
                                    SecondaryButtonStyle(
                                        enabled: model.executionModeLabel != mode.label
                                    )
                                )
                                .disabled(model.readOnly)
                        }
                        Spacer(minLength: 0)
                    }

                    // ② 单次容量上限（可见可编辑）
                    HStack(spacing: Tokens.Spacing.xs) {
                        Text(L.pick("单次容量上限", "Per-run size cap"))
                            .font(Tokens.Typography.secondary)
                            .foregroundStyle(Tokens.Color.textSecondary)
                            .frame(width: 88, alignment: .leading)
                        SemanticSlotView(slot: model.capacityCapSlot)
                        Spacer(minLength: 0)
                    }

                    // ③ 条目数上限（可见可编辑）
                    HStack(spacing: Tokens.Spacing.xs) {
                        Text(L.pick("条目数上限", "Item count cap"))
                            .font(Tokens.Typography.secondary)
                            .foregroundStyle(Tokens.Color.textSecondary)
                            .frame(width: 88, alignment: .leading)
                        SemanticSlotView(slot: model.itemCapSlot)
                        Spacer(minLength: 0)
                    }

                    // ④ AC-15 的两档规则（**只读说明，不是可编辑配置**）
                    //
                    // 与上面三项的区别要说清：上面是「用户可改的值」，
                    // 这里是「产品怎么用这些值的规则」。
                    // 放在同一张卡里分两组，比两张几乎同名的卡清楚得多。
                    DividerLine()
                    Text(L.pick("规则（只读）", "Rules (read-only)"))
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(Tokens.Color.textSecondary)
                    ForEach(Array(model.policySlots.enumerated()), id: \.offset) { _, pair in
                        KeyValueRow(label: pair.0, slot: pair.1)
                    }
                }
            }

            // ---- 白名单（AC-03：加入后不再出现在候选清单）----
            Card {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    SectionTitle(text: L.pick("白名单", "Allowlist"))
                    Text(L.pick("加入后该路径不再出现在候选清单中，也不会被自动删除。", "Once added, this path no longer appears in the candidate list and won't be auto-deleted."))
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(Tokens.Color.textSecondary)

                    if model.hasWhitelist {
                        ForEach(model.whitelist, id: \.self) { path in
                            HStack(spacing: Tokens.Spacing.xs) {
                                Text(path)
                                    .font(Tokens.Typography.secondary)
                                    .foregroundStyle(Tokens.Color.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: Tokens.Spacing.xs)
                                // **必须能撤回**：只增不减的白名单会变成新陷阱
                                Button(L.pick("移除", "Remove")) { onRemoveWhitelist(path) }
                                    .buttonStyle(SecondaryButtonStyle(enabled: !model.readOnly))
                                    .disabled(model.readOnly)
                            }
                            .frame(minHeight: 24)
                        }
                    } else {
                        Text(L.pick("还没有加入任何路径", "No paths added yet"))
                            .font(Tokens.Typography.secondary)
                            .foregroundStyle(Tokens.Color.textSecondary)
                    }

                    HStack(spacing: Tokens.Spacing.xs) {
                        TokenTextField(placeholder: L.pick("输入要保护的路径", "Path to protect"), text: $whitelistDraft)
                        Button(L.pick("加入", "Add")) {
                            onAddWhitelist(whitelistDraft)
                            whitelistDraft = ""
                        }
                        .buttonStyle(
                            SecondaryButtonStyle(
                                enabled: !model.readOnly && !whitelistDraft.isEmpty
                            )
                        )
                        .disabled(model.readOnly || whitelistDraft.isEmpty)
                    }
                }
            }

            // ---- 定时任务（登录项四态，ADR-02）----
            if let scheduled = model.scheduledTaskSlot {
                Card {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                        SectionTitle(text: L.pick("定时任务", "Scheduled task"))
                        HStack(spacing: Tokens.Spacing.xs) {
                            SemanticSlotView(slot: scheduled)
                            Spacer(minLength: Tokens.Spacing.s)
                            if model.needsLoginItemApproval {
                                // 只在 `.requiresApproval` 时给——其余三态给这个按钮
                                // 等于把用户支使到一个解决不了问题的地方
                                Button(L.pick("去系统设置允许", "Open System Settings")) { onOpenLoginSettings() }
                                    .buttonStyle(SecondaryButtonStyle())
                            }
                        }
                    }
                }
            }

            // ---- 语义位二：规则版本（**与上面不重叠、不同对象、不同命名**）----
            Card {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                    SectionTitle(text: L.pick("规则版本", "Rule version"))
                    if model.ruleVersionSlots.isEmpty {
                        SemanticSlotView(slot: .text(L.pick("首版规则集固定", "Rule set is fixed in the first release")), muted: true)
                    } else {
                        ForEach(Array(model.ruleVersionSlots.enumerated()), id: \.offset) { _, pair in
                            KeyValueRow(label: pair.0, slot: pair.1)
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(Tokens.Spacing.m)
    }
}

// MARK: - ④ 授权与隐私
//
// 骨架：表单 + 一键清除按钮
// 必须有的语义位：采集范围说明 + 清除范围说明（**含「不重置观察期与 L0 误判记录」一句**）
struct PrivacyPage: View {
    let model: PageModel
    /// 一键清除的动作（AC-12）。
    ///
    /// **原先是空实现**（按钮的 action 里只有一行「骨架阶段：动作由后续接」）。
    /// 空实现的按钮比没有按钮更糟：用户点了、什么都没发生、也不会报错。
    var onClearLogs: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {

            Card {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    SectionTitle(text: L.pick("采集范围", "Collection scope"))
                    Text(model.collectionScopeNotice)
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(Tokens.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // ---- 四档采集与授权（AC-10 / AC-11 / AC-14 的界面落点）----
            Card {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    SectionTitle(text: L.pick("采集档位与授权", "Collection tiers & authorization"))
                    ForEach(model.collectionTiers) { tier in
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: Tokens.Spacing.xs) {
                                Text(tier.name)
                                    .font(Tokens.Typography.body)
                                    .foregroundStyle(Tokens.Color.textPrimary)
                                // 授权状态（AC-11：四档独立授权）
                                Text(tier.authorized ? L.pick("已授权", "Authorized") : L.pick("未授权", "Not authorized"))
                                    .font(Tokens.Typography.secondary)
                                    .foregroundStyle(Tokens.Color.textSecondary)
                                Spacer(minLength: Tokens.Spacing.xs)
                                SemanticSlotView(slot: tier.state)
                            }
                            // AC-14：受阻时必须给「所缺权限」+ 授权指引条目 ID
                            if let block = tier.blockReason {
                                SemanticSlotView(slot: block, font: Tokens.Typography.secondary)
                            }
                        }
                        .frame(minHeight: Tokens.Typography.tableRowHeight)
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    SectionTitle(text: L.pick("清除数据", "Clear data"))
                    // **必须含「不重置观察期进度与 L0 误判记录」**
                    Text(UICopy.clearScopeNotice)
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(Tokens.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if model.canClearLogs {
                        Button(L.pick("一键清除采集物与日志", "Clear collected data and logs")) { onClearLogs() }
                        // **危险色**（产品裁定 DAC-46b）：一键清除**不可逆**——
                        // 它的清除范围含 14 日内的执行记录，而 AC-13 的「恢复位置」
                        // 正在这些记录里 → 清完即**丧失 14 日恢复能力**。
                        // 视觉基线 §二：危险色只用于「这一步不可逆」。
                        .buttonStyle(DangerButtonStyle(enabled: !model.readOnly))
                        .disabled(model.readOnly)
                    }
                }
            }

            Spacer()
        }
        .padding(Tokens.Spacing.m)
    }
}

// MARK: - ⑤ 影子观察期报告
//
// 骨架：矩阵 + 页级状态行 + 「上一轮」行
// 必须有的语义位：矩阵**七项**全部 `.metric` / `.ratio`；
//                 ③ 列两个冻结时点分行标注；只读态显示「只读，不结算」
struct ReportPage: View {
    let model: PageModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {

            // 页级状态行
            HStack(alignment: .firstTextBaseline) {
                if model.readOnly {
                    // **只读态不得给出「本轮可点亮：否（某来源样本不足）」这类判定**：
                    // 那是基于 `K` / `H` / `a` 的结论，而只读态读不到这些数值。
                    // 用读不到的数据下结论，与「显示 0」是同一类错误。
                    SemanticSlotView(
                        slot: .unavailable(reason: UICopy.readOnlyNoSettlement)
                    )
                } else if let pageLevel = model.pageLevelSlot {
                    SemanticSlotView(slot: pageLevel)
                }
                Spacer()
                if model.readOnly {
                    // ⚠️ **只读态显示「只读，不结算」**，不是「本轮未结算」（R2 §10.2）。
                    //    「本轮未结算」会被读成「等一会儿就有」——只读态永远不会有。
                    //    先前这两条文案只定义未引用（DAC-49/58 判不通过），此处接上。
                    SemanticSlotView(slot: .unavailable(reason: UICopy.readOnlyNoSettlement))
                } else if model.reportProduced {
                    SemanticSlotView(slot: .text(L.pick("报告已产出", "Report produced")), muted: true)
                } else {
                    // **报告未产出时不是「未达标」——那是假值**
                    SemanticSlotView(slot: .unavailable(reason: UICopy.notSettledThisRound))
                }
            }

            // 「上一轮」行（**仅轮次 ≥ 2 时显示；首轮不显示该行**，不是显示「—」）
            // 只读态不显示：它是**结算结果**，只读态读不到结算数据。
            if !model.readOnly, let previous = model.previousRoundSlot {
                StatusBar(slot: previous)
            }

            // 矩阵（七项，横向排布，不滚动——7 列在 1000 pt 内放得下）
            if model.readOnly {
                // 只读态：**不渲染数值**，未知字段一律「—（由更高版本维护）」。
                // 渲染 0 会让旧版把「错 1 次永久」显示成「一次都没错」——假值比空白更危险。
                Card {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                        // **只读成因不同，这里的话也不同**：
                        // - 版本降级 → 字段由更高版本维护，本版不显示数值
                        // - 权限降级 → 数值本轮压根没算出来（不是「由更高版本维护」）
                        // 用同一句会让权限降级的用户以为自己的数据是高版本写的。
                        if model.readOnlyReason == UICopy.permissionDegradedReadOnly {
                            SemanticSlotView(
                                slot: .unavailable(reason: UICopy.notSettledThisRound)
                            )
                            Text(UICopy.permissionDegradedReadOnly)
                                .font(Tokens.Typography.secondary)
                                .foregroundStyle(Tokens.Color.textSecondary)
                        } else {
                            SemanticSlotView(
                                slot: .unavailable(reason: UICopy.maintainedByNewerVersion)
                            )
                            Text(L.pick("数据由更高版本创建；本版本只显示结构，不显示数值。", "Data was created by a newer version; this version shows structure only, no values."))
                                .font(Tokens.Typography.secondary)
                                .foregroundStyle(Tokens.Color.textSecondary)
                        }
                    }
                }
            } else if model.reportRows.isEmpty {
                EmptyStateView(
                    message: L.pick("本轮尚无矩阵数据", "No matrix data this round"),
                    hint: L.pick("观察期结束扫描完成后生成。", "Generated after the observation period ends and the scan completes.")
                )
            } else {
                ReportMatrixView(rows: model.reportRows)
            }

            Spacer()
        }
        .padding(Tokens.Spacing.m)
    }
}

/// ⑤ 页矩阵（**七项，顺序唯一**；③ 列两行冻结时点标注）。
struct ReportMatrixView: View {
    let rows: [ReportRow]

    var body: some View {
        VStack(spacing: 0) {
            // 表头（**v1.1 · B1**：③ 列在表头内分三行——列名 + 两个冻结时点）
            HStack(alignment: .top, spacing: 0) {
                ForEach(ReportMatrix.columns, id: \.self) { col in
                    VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                        Text(col)
                            .font(Tokens.Typography.secondary)
                            .foregroundStyle(Tokens.Color.textSecondary)
                        // ③ 列带两行副标（冻结时点，列级元数据）
                        if col == ReportMatrix.sampleColumnTitle {
                            ForEach(ReportMatrix.freezeNotes, id: \.self) { note in
                                Text(note)
                                    .font(Tokens.Typography.secondary)
                                    .foregroundStyle(Tokens.Color.textSecondary.opacity(0.75))
                            }
                        }
                        // ⑥ 列带一行子标（误判 / 检查），与数据格左右对齐
                        if col == ReportMatrix.l0ColumnTitle {
                            HStack(spacing: 0) {
                                ForEach(ReportMatrix.l0SubLabels, id: \.self) { sub in
                                    Text(sub)
                                        .font(Tokens.Typography.secondary)
                                        .foregroundStyle(Tokens.Color.textSecondary.opacity(0.75))
                                        .frame(width: ReportMatrix.l0SubWidth, alignment: .leading)
                                }
                            }
                        }
                    }
                    .frame(width: columnWidth(for: col), alignment: .leading)
                    .padding(.horizontal, Tokens.Spacing.xs)
                }
            }
            .padding(.vertical, Tokens.Spacing.xxs)
            .frame(height: ReportMatrix.headerHeight, alignment: .center)
            .background(Tokens.Color.surface)

            DividerLine()

            ForEach(rows) { row in
                HStack(alignment: .center, spacing: 0) {
                    ForEach(Array(row.cells.enumerated()), id: \.offset) { idx, cell in
                        Group {
                            if ReportMatrix.columns[min(idx, ReportMatrix.columns.count - 1)] == ReportMatrix.l0ColumnTitle {
                                // ⑥ 列：两个独立 `.metric` **并肩**（不是拼成一个字符串，
                                // 也不是上下堆叠）——子标已在表头，此处只放数
                                HStack(spacing: 0) {
                                    ForEach(Array(cell.enumerated()), id: \.offset) { _, slot in
                                        SemanticSlotView(slot: slot)
                                            .frame(width: ReportMatrix.l0SubWidth, alignment: .leading)
                                    }
                                }
                            } else {
                                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                                    ForEach(Array(cell.enumerated()), id: \.offset) { _, slot in
                                        SemanticSlotView(slot: slot)
                                    }
                                }
                            }
                        }
                        .frame(width: columnWidth(for: ReportMatrix.columns[min(idx, ReportMatrix.columns.count - 1)]),
                               alignment: .leading)
                        .padding(.horizontal, Tokens.Spacing.xs)
                    }
                }
                // **v1.1 · B1：数据行固定 32 pt**（不再 minHeight + 竖向内边距；
                // 冻结时点已上移到表头，单元格只剩一行，32 pt 装得下）
                .frame(height: Tokens.Typography.tableRowHeight)

                DividerLine()
            }
        }
        .background(Tokens.Color.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
    }

    /// 列宽（**加总必须 ≤ 可用宽度**，否则整页被撑宽、右侧截断）。
    ///
    /// 可用宽度 = 1000（窗口）− 168（侧栏，英文 196）− 1（分隔线）− 32（页内边距）
    ///            − 24（矩阵内边距）≈ **775 pt**（英文 ≈ 747 pt）。
    /// 7 列合计：100+70+150+70+90+140+80 = **700 pt**，两种语言都留有余量。
    ///
    /// ⚠️ 按**列序**取值，不按列名。列名是多语言的（`ReportMatrix.columns`
    /// 随 `L.current` 变化），拿中文列名去 `case` 匹配在英文界面下会全部落到
    /// `default`，列宽退化成 90 —— 表头与数据列就错位了。
    private func columnWidth(for column: String) -> CGFloat {
        guard let idx = ReportMatrix.columns.firstIndex(of: column) else { return 90 }
        switch idx {
        case 0: return 100                              // 来源
        case 1: return 70                               // 判定域
        case 2: return ReportMatrix.sampleColumnWidth   // 样本 / 总量
        case 3: return 70                               // 门槛
        case 4: return 90                               // 观察期
        case 5: return ReportMatrix.l0SubWidth * 2 + Tokens.Spacing.xxs
        case 6: return 80                               // 结论
        default: return 90
        }
    }
}

// MARK: - ⑥ 确认清理（抽屉态）
//
// 骨架：抽屉 + 不可逆提示
// 必须有的语义位：本次将删除条目数与字节（`.metric`）+ **危险色**确认按钮
struct ConfirmDrawer: View {
    let model: PageModel
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {

            SectionTitle(text: L.pick("确认清理", "Confirm cleanup"))

            // **语义（CR-023 裁定）**：⑥ 是**自动执行批次的预览**，不是手动删除入口。
            // 契约里没有「用户手动删文件」这条路径（AC-04 只写「到达定时执行点」）。
            // 所以这个按钮做的是「把本次定时批次提前执行」，**受 AC-04 全部门槛约束**——
            // 因此不存在「手动清理绕过观察期门槛」这回事（原 S-8 消解）。
            Text(L.pick("本次为定时执行批次的预览。执行时仍逐来源复核门槛；未达标的来源不会被执行。", "This is a preview of the scheduled batch. Each source's gate is re-checked at execution time; sources that don't qualify are not executed."))
                .font(Tokens.Typography.secondary)
                .foregroundStyle(Tokens.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // 不可逆提示（视觉基线 §三：危险色只用于「这一步不可逆」）
            HStack(alignment: .top, spacing: Tokens.Spacing.xxs) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                Text(UICopy.irreversibleNotice)
                    .font(Tokens.Typography.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Tokens.Color.danger)

            DividerLine()

            // 本次将删除的规模（两个 `.metric`）
            HStack(spacing: Tokens.Spacing.xl) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                    Text(L.pick("条目", "Items"))
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(Tokens.Color.textSecondary)
                    SemanticSlotView(slot: model.confirmItemCount)
                }
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                    Text(L.pick("字节", "Bytes"))
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(Tokens.Color.textSecondary)
                    SemanticSlotView(slot: model.confirmBytes)
                }
                // AC-15：顺延条目数（超出上限而未执行的部分）
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                    Text(L.pick("顺延条目", "Deferred items"))
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(Tokens.Color.textSecondary)
                    SemanticSlotView(slot: model.deferredCountSlot)
                }
            }

            Spacer()

            HStack(spacing: Tokens.Spacing.s) {
                Button(L.pick("取消", "Cancel"), action: onCancel)
                    .buttonStyle(SecondaryButtonStyle())

                // **同门槛**：未达线不得执行（AC-04 ③ 逐来源复核 + AC-08 组 B）。
                // 门槛未过时按钮 disabled，并在下方显示原因 —— 不给「点了没反应」。
                let canExecute = model.canLightUp && !model.readOnly
                Button(L.pick("立即执行本次清理", "Run this cleanup now"), action: onConfirm)
                    // **危险色**——这是全应用唯一该用危险色的主动作
                    .buttonStyle(DangerButtonStyle(enabled: canExecute))
                    .disabled(!canExecute)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            if !model.canLightUp && !model.readOnly {
                // 门槛未过 → **说明为什么不能点**，而不是让它静默 disabled
                SemanticSlotView(
                    slot: .unavailable(reason: L.pick("未达达标条件，暂不能执行（逐来源复核未通过）", "Gate not met; can't run yet (per-source re-check failed)"))
                )
            }
        }
        .padding(Tokens.Spacing.m)
        .frame(minWidth: 380, minHeight: 260)
    }
}

// MARK: - ⑦ 举证链 / 执行日志
//
// 骨架：列表 + 恢复入口 + 导出按钮
// 必须有的语义位：每条执行记录带「可恢复 / 已恢复 / 已阻断」标签；
//                 **留存口径两行同址**（14 日 + 90 天/200 MB）
struct EvidencePage: View {
    let model: PageModel
    var onExport: () -> Void
    /// 恢复动作（AC-13）。**参数是整条执行记录**——没有它就接不上
    /// `TrashExecutor.restore`（那需要 `restorePath`）。
    var onRestore: (ExecutionRecord) -> Void = { _ in }
    @Environment(\.residueRenderMode) private var renderMode

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // 工具条：导出（恢复入口在每行上）
            HStack(spacing: Tokens.Spacing.s) {
                Text(L.pick("执行记录", "Execution records"))
                    .font(Tokens.Typography.title)
                    .foregroundStyle(Tokens.Color.textPrimary)

                Spacer()

                Button(L.pick("导出脱敏报告", "Export redacted report"), action: onExport)
                    .buttonStyle(SecondaryButtonStyle(enabled: !model.readOnly))
                    .disabled(model.readOnly)
            }
            .padding(.horizontal, Tokens.Spacing.m)
            .padding(.vertical, Tokens.Spacing.xs)

            DividerLine()

            // ⚠️ **本页内容远超一屏**（执行记录 + 8 个举证字段 + 上游命令表）。
            // 产品路径必须可滚；渲染路径直排（会按 640pt 高裁掉超出部分——
            // 那正是真实窗口的「首屏」，不是渲染 bug）。
            if renderMode {
                // 渲染路径：**ZStack 叠底**——内容裁切、留存口径浮在最上层。
                // 为什么不用 `.frame(maxHeight:)`：它在 VStack 里不生效（父容器会跟着长高），
                // 实测底栏仍被顶出 640pt 框。叠底是唯一能同时保证「内容裁切」与
                // 「底栏可见」的写法。
                ZStack(alignment: .bottom) {
                    scrollableBody
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .clipped()
                    retentionFooter
                }
            } else {
                ScrollView { scrollableBody }
                Spacer(minLength: 0)
                retentionFooter
            }
        }
    }

    /// 留存口径两行同址（AC-13 · G-4 的「14 日」+ M6 的「90 天/200 MB」）。
    ///
    /// **常驻不动**：它是唯一对外宣称落点，不该因为用户没滚到底就看不到。
    private var retentionFooter: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
            Text(UICopy.restoreWindowNotice)
            Text(UICopy.retentionNotice)
        }
        .font(Tokens.Typography.secondary)
        .foregroundStyle(Tokens.Color.textSecondary)
        .padding(.horizontal, Tokens.Spacing.m)
        .padding(.vertical, Tokens.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Color.surface)
    }

    /// 可滚区内容（执行记录 + 举证字段 + 上游命令）。
    @ViewBuilder
    private var scrollableBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.evidenceRows.isEmpty {
                EmptyStateView(
                    message: L.pick("还没有执行记录", "No execution records yet"),
                    hint: L.pick("自动删除启用并有条目被清理后，这里会出现记录。", "Records appear here after auto-delete is enabled and items are cleaned up.")
                )
                .frame(minHeight: 120)
            } else {
                evidenceList
            }

            // **举证链八字段**（AC-18：8 字段完整率 100%，无空白）
            if !model.evidenceFields.isEmpty {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                    Text(L.pick("举证链字段（8 项）", "Evidence fields (8)"))
                        .font(Tokens.Typography.title)
                        .foregroundStyle(Tokens.Color.textPrimary)
                    ForEach(Array(model.evidenceFields.enumerated()), id: \.offset) { _, pair in
                        KeyValueRow(label: pair.0, slot: pair.1)
                    }
                }
                .padding(.horizontal, Tokens.Spacing.m)
                .padding(.vertical, Tokens.Spacing.xs)

                DividerLine()
            }

            // **上游命令与出现次数**（AC-19：直接删文件的上游命令出现次数 = 0）
            if !model.upstreamCommands.isEmpty {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                    // ⚠️ **文案不能说「执行次数须为 0」**。
                    //
                    // AC-19 的原文是「**直接删文件的上游命令**出现次数 = 0」——
                    // 它约束的是**删除类**命令，不是全部命令。
                    // 只读定位命令（`uv cache dir` / `npm config get cache`）
                    // 本来就会执行，`执行` 列是 1 次才是**正确**的。
                    //
                    // 写成「执行次数须为 0」会造成字面冲突：表头说必须 0，
                    // 表内只读命令是 1 —— 用户会以为产品有问题，
                    // 或反过来以为这个指标不值得看。（查必究 B-1 复核指出）
                    Text(L.pick("上游命令（AC-19：删除类命令的执行次数须为 0）", "Upstream commands (AC-19: delete commands must execute 0 times)"))
                        .font(Tokens.Typography.title)
                        .foregroundStyle(Tokens.Color.textPrimary)
                    // 表头：两个数分列 —— 「调用」含被拒尝试，「执行」才是 AC-19 判的
                    HStack(spacing: Tokens.Spacing.xs) {
                        Text(L.pick("命令", "Command")).font(Tokens.Typography.secondary)
                            .foregroundStyle(Tokens.Color.textSecondary)
                        Spacer(minLength: Tokens.Spacing.s)
                        Text(L.pick("调用", "Invocations")).font(Tokens.Typography.secondary)
                            .foregroundStyle(Tokens.Color.textSecondary)
                            .frame(width: 56, alignment: .trailing)
                        Text(L.pick("执行", "Executed")).font(Tokens.Typography.secondary)
                            .foregroundStyle(Tokens.Color.textSecondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                    ForEach(model.upstreamCommands) { row in
                        HStack(spacing: Tokens.Spacing.xs) {
                            Text(row.command)
                                .font(Tokens.Typography.secondary)
                                .foregroundStyle(Tokens.Color.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: Tokens.Spacing.s)
                            SemanticSlotView(slot: row.invoked, muted: true)
                                .frame(width: 56, alignment: .trailing)
                            SemanticSlotView(slot: row.executed)
                                .frame(width: 56, alignment: .trailing)
                        }
                        .frame(minHeight: 24)
                    }
                }
                .padding(.horizontal, Tokens.Spacing.m)
                .padding(.vertical, Tokens.Spacing.xs)
            }
        }
    }

    @ViewBuilder
    private var evidenceList: some View {
                LazyVStack(spacing: 0) {
                    ForEach(model.evidenceRows) { row in
                        HStack(spacing: Tokens.Spacing.xs) {
                            Text(row.path)
                                .font(Tokens.Typography.body)
                                .foregroundStyle(Tokens.Color.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            EvidenceBadge(label: row.label)

                            Spacer(minLength: Tokens.Spacing.xs)

                            // 恢复入口（AC-13：14 日内一键恢复）。
                            //
                            // **两个条件都要**：① 标签是「可恢复」② 有完整执行记录。
                            // 只判 ① 的话，遇到「日志里有、但还原不出 restorePath」的行，
                            // 按钮会出现而点了没反应 —— 那正是我们要消灭的形态
                            // （空实现检测会在 verify_a9 第九节报出来）。
                            if case .recoverable = row.label, row.record != nil {
                                Button(L.pick("恢复", "Restore")) {
                                    if let rec = row.record {
                                        onRestore(rec)
                                    }
                                }
                                .buttonStyle(SecondaryButtonStyle(enabled: !model.readOnly))
                                .disabled(model.readOnly)
                            }
                        }
                        .frame(height: Tokens.Typography.tableRowHeight)
                        .padding(.horizontal, Tokens.Spacing.m)

                        DividerLine()
                    }
                }
    }
}

/// 执行记录标签（可恢复 / 已恢复 / 已阻断）。
///
/// **v1.1 §二**：与 `ParticipationBadge` 同一处理——图标 + 次文字色，
/// 不进信号色（逐行属性天然有 N 个，与「稀缺的一次」语义不相容）。
struct EvidenceBadge: View {
    let label: EvidenceLabel

    var body: some View {
        HStack(spacing: Tokens.Spacing.xxs) {
            Image(systemName: label.symbolName)
                .font(.system(size: Tokens.Icon.badge))
            Text(label.text)
                .font(Tokens.Typography.secondary)
        }
        .foregroundStyle(Tokens.Color.textSecondary)
        .padding(.horizontal, Tokens.Spacing.xs)
        .padding(.vertical, Tokens.Spacing.xxs)
        .background(
            Tokens.Color.textSecondary.opacity(0.12),
            in: RoundedRectangle(cornerRadius: Tokens.Radius.badge)
        )
    }
}
