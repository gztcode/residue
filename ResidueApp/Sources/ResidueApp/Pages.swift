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
// 视觉基线 v2：**主数字 + 来源占比 + 可释放比例 + 观察期环 + 门槛摘要**。
// 必须有的语义位（不变）：三区块各一个 `.metric`；状态条承载「并发冲突」；
// L1 / L2 / 可删除量三个数**分别可读**，L2 不并入可删除量（AC-02）。
struct OverviewPage: View {
    let model: PageModel
    @Environment(\.residueRenderMode) private var renderMode

    var body: some View {
        if model.loading {
            LoadingView(message: model.loadingMessage)
        } else if !model.hasScanned {
            // **重启后不再走这里**：只要读过 `scan.jsonl` 的汇总（或载体里
            // 有上次扫描时刻），`hasScanned` 就为 true —— 那时显示「上次扫描」
            // 的总量 + 「—」明细，而不是假装从未扫描过。
            EmptyStateView(
                message: L.pick("还没有扫描过", "No scan yet"),
                hint: L.pick("首次扫描会在观察期内进行，不读取文件内容。", "The first scan runs during the observation period and never reads file contents.")
            )
        } else {
            Group {
                if renderMode {
                    content
                } else {
                    ScrollView { content }
                }
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            if let status = model.statusSlot {
                StatusBar(slot: status)
            }

            // 重启后：总量是上次扫描的，逐来源明细尚不可知 —— 必须说明，
            // 否则用户会把「—」读成「这一来源是空的」。
            if let notice = model.lastScanNotice {
                WarningBanner(message: notice)
            }

            summaryCard

            HStack(alignment: .top, spacing: Tokens.Spacing.s) {
                reclaimableCard
                gateSummary
            }

            sourceTable
        }
        .padding(Tokens.Layout.contentPadding)
    }

    /// 顶部汇总卡：总量 | 来源构成 | 观察期（一张卡三栏，避免三张窄卡把图例挤断）。
    private var summaryCard: some View {
        Card(padding: Tokens.Spacing.m) {
            HStack(alignment: .top, spacing: Tokens.Spacing.m) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.pick("本机缓存总计", "Total on this Mac"))
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(Tokens.Color.textSecondary)

                    SemanticSlotView(slot: model.totalScannedSlot, font: Tokens.Typography.numberHero)
                        .foregroundStyle(Tokens.Color.textPrimary)

                    Text(L.pick("只读统计 · 不读取文件内容", "Read-only · file contents never read"))
                        .font(.system(size: 9))
                        .foregroundStyle(Tokens.Color.textTertiary)
                }
                .frame(width: 190, alignment: .leading)

                compactDivider

                composition

                compactDivider

                observation
                    .frame(width: 180, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var compactDivider: some View {
        Rectangle()
            .fill(Tokens.Color.divider)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
    }

    /// 来源构成：堆叠条 + 每来源「名称 / 大小 + 占比」。
    private var composition: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L.pick("来源构成", "Composition"))
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(Tokens.Color.textSecondary)
                Spacer(minLength: Tokens.Spacing.xs)
                Text(L.pick("按字节占比", "By bytes"))
                    .font(.system(size: 9))
                    .foregroundStyle(Tokens.Color.textTertiary)
            }

            StackedShareBar(rows: model.sourceShares, height: 8)

            HStack(alignment: .top, spacing: Tokens.Spacing.m) {
                ForEach(model.sourceShares) { row in
                    // 三列等宽（每列约 83 pt）。**字节与占比必须竖排**：
                    // 真实数据 `847.7 MB 97.0%` 横排需要约 92 pt，
                    // 会在三列布局里被截成「847.7…」（真机走查发现）。
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Tokens.Spacing.xxs) {
                            SourceDot(sourceKey: row.sourceKey)
                            Text(row.displayName)
                                .font(Tokens.Typography.secondary)
                                .foregroundStyle(Tokens.Color.textSecondary)
                                .lineLimit(1)
                        }
                        SemanticSlotView(slot: row.bytes, font: Tokens.Typography.numberSmall)
                            .foregroundStyle(Tokens.Color.textPrimary)
                        if let share = row.share {
                            SemanticSlotView(slot: share.percentSlot, font: Tokens.Typography.secondary)
                                .foregroundStyle(Tokens.Color.textTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 观察期环（与侧栏、⑤ 页同源）。
    private var observation: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L.pick("观察期", "Observation"))
                .font(Tokens.Typography.secondary)
                .foregroundStyle(Tokens.Color.textSecondary)

            HStack(spacing: Tokens.Spacing.xs) {
                ObservationRing(ratio: model.observationRatio, lineWidth: 5, diameter: 50)
                    .overlay(
                        Image(systemName: "hourglass")
                            .font(.system(size: 13))
                            .foregroundStyle(Tokens.Color.textPrimary)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 3) {
                        SemanticSlotView(
                            slot: model.observationDaySlot,
                            font: Tokens.Typography.numberMedium
                        )
                        Text(L.pick("天", "days"))
                            .font(Tokens.Typography.secondary)
                            .foregroundStyle(Tokens.Color.textTertiary)
                    }
                    Text(
                        model.canLightUp
                            ? L.pick("已达达标条件", "Gate met")
                            : L.pick("影子期内只读", "Read-only")
                    )
                    .font(.system(size: 9))
                    .foregroundStyle(Tokens.Color.textTertiary)
                }
            }
        }
    }

    /// 可释放量（= 可删除量 = L1；L2 单列且不并入）。
    private var reclaimableCard: some View {
        Card(padding: Tokens.Spacing.m) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L.pick("可释放", "Reclaimable"))
                        .font(Tokens.Typography.title)
                        .foregroundStyle(Tokens.Color.textPrimary)
                    Spacer()
                    if let share = model.reclaimableShare {
                        Text(L.pick("字节占比", "Byte share"))
                            .font(Tokens.Typography.secondary)
                            .foregroundStyle(Tokens.Color.textTertiary)
                        SemanticSlotView(slot: share.percentSlot, font: Tokens.Typography.secondary)
                            .foregroundStyle(Tokens.Color.textTertiary)
                    }
                }

                SemanticSlotView(slot: model.deletableAmount, font: Tokens.Typography.numberHero)
                    .foregroundStyle(Tokens.Color.textPrimary)

                RatioBarView(slot: model.reclaimableShare, color: Tokens.Color.textPrimary)
                    .padding(.bottom, 2)

                levelRow(L.pick("确定可释放（L1）", "Confirmed (L1)"), slot: model.l1Confirmed)
                levelRow(L.pick("推断可释放（L2）", "Inferred (L2)"), slot: model.l2Inferred)

                Text(model.l2Label)
                    .font(.system(size: 9))
                    .foregroundStyle(Tokens.Color.textTertiary)

                DividerLine().padding(.vertical, 2)

                HStack {
                    Text(L.pick("单次容量上限", "Per-run size cap"))
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(Tokens.Color.textTertiary)
                    Spacer()
                    SemanticSlotView(slot: model.capacityCapSlot, font: Tokens.Typography.numberSmall)
                }
                HStack {
                    Text(L.pick("条目数上限", "Item count cap"))
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(Tokens.Color.textTertiary)
                    Spacer()
                    SemanticSlotView(slot: model.itemCapSlot, font: Tokens.Typography.numberSmall)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func levelRow(_ label: String, slot: SemanticSlot) -> some View {
        HStack {
            Text(label)
                .font(Tokens.Typography.secondary)
                .foregroundStyle(Tokens.Color.textSecondary)
            Spacer()
            SemanticSlotView(slot: slot, font: Tokens.Typography.numberSmall)
                .foregroundStyle(Tokens.Color.textPrimary)
        }
    }

    /// 来源明细表（回答「哪些目录、多少条、占多少、在不在判定域」）。
    private var sourceTable: some View {
        Card(padding: Tokens.Spacing.s) {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(
                    title: L.pick("来源明细", "Sources"),
                    trailing: L.pick("自动删除只作用于判定域内的来源", "Auto-delete only touches sources in the decision domain")
                )
                .padding(.bottom, Tokens.Spacing.xs)

                HStack(spacing: Tokens.Spacing.xs) {
                    TableHeaderText(text: L.pick("来源", "Source"))
                        .frame(width: 120, alignment: .leading)
                    TableHeaderText(text: L.pick("目录", "Path"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TableHeaderText(text: L.pick("项数", "Items"), alignment: .trailing)
                        .frame(width: 80, alignment: .trailing)
                    TableHeaderText(text: L.pick("大小", "Size"), alignment: .trailing)
                        .frame(width: 88, alignment: .trailing)
                    TableHeaderText(text: L.pick("占比", "Share"), alignment: .trailing)
                        .frame(width: 150, alignment: .trailing)
                    TableHeaderText(text: L.pick("判定域", "Domain"), alignment: .trailing)
                        .frame(width: 70, alignment: .trailing)
                }
                .padding(.vertical, 4)

                DividerLine()

                ForEach(model.sourceShares) { row in
                    HStack(spacing: Tokens.Spacing.xs) {
                        HStack(spacing: Tokens.Spacing.xxs) {
                            SourceDot(sourceKey: row.sourceKey)
                            Text(row.displayName)
                                .font(Tokens.Typography.body)
                                .foregroundStyle(Tokens.Color.textPrimary)
                        }
                        .frame(width: 120, alignment: .leading)

                        Text(row.path)
                            .font(Tokens.Typography.secondary)
                            .foregroundStyle(Tokens.Color.textTertiary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        SemanticSlotView(slot: row.itemCount, font: Tokens.Typography.numberSmall)
                            .frame(width: 80, alignment: .trailing)

                        SemanticSlotView(slot: row.bytes, font: Tokens.Typography.numberSmall)
                            .frame(width: 88, alignment: .trailing)

                        HStack(spacing: 6) {
                            RatioBarView(
                                slot: row.share,
                                color: Tokens.Color.source(for: row.sourceKey),
                                height: 4
                            )
                            if let share = row.share {
                                SemanticSlotView(slot: share.percentSlot, font: Tokens.Typography.numberSmall)
                                    .foregroundStyle(Tokens.Color.textTertiary)
                            } else {
                                Text("—")
                                    .font(Tokens.Typography.secondary)
                                    .foregroundStyle(Tokens.Color.textTertiary)
                            }
                        }
                        .frame(width: 150, alignment: .trailing)

                        if row.inDecisionDomain {
                            Pill(text: L.pick("在域", "In domain"), color: Tokens.Color.success)
                                .frame(width: 70, alignment: .trailing)
                        } else {
                            Pill(text: L.pick("仅报告", "Report only"), color: Tokens.Color.textSecondary)
                                .frame(width: 70, alignment: .trailing)
                        }
                    }
                    .frame(height: Tokens.Typography.tableRowHeight)

                    DividerLine()
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 门槛摘要（与 ⑤ 页同源；点不亮时这里先告诉用户差哪一条）。
    private var gateSummary: some View {
        Card(padding: Tokens.Spacing.m) {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(
                    title: L.pick("点亮检查", "Gate checks"),
                    trailing: model.canLightUp
                        ? L.pick("已达标", "Passed")
                        : L.pick("未达标", "Not yet")
                )
                .padding(.bottom, Tokens.Spacing.xxs)

                ForEach(model.gateChecks) { row in
                    GateCheckRowView(row: row)
                }

                if !model.canLightUp, let unmet = model.unmetNotice {
                    DividerLine().padding(.vertical, 4)
                    SemanticSlotView(slot: unmet, font: Tokens.Typography.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - ② 环境明细与候选清单
//
// 视觉基线 v2：**表头 + 来源点 + 标签 + 大小 + 占比条**。
// 必须有的语义位（不变）：每行一个标签（可参与自动删除 / 仅报告）+ `.metric(bytes)`。
struct EnvironmentsPage: View {
    let model: PageModel
    @Environment(\.residueRenderMode) private var renderMode

    var body: some View {
        if model.loading {
            // 扫描进行中：候选清单尚未生成。**不能走空态文案**——
            // 「重启后尚未扫描」在扫描进行时会变成一句谎话。
            LoadingView(message: model.loadingMessage)
        } else if model.candidateRows.isEmpty {
            // 「列表为空」有三种完全不同的原因，不能都说成「没有可清理的候选」：
            // 从未扫描 / 重启后尚未扫描（不知道）/ 扫描了但确实没有。
            if !model.hasScanned {
                EmptyStateView(
                    message: L.pick("还没有扫描过", "No scan yet"),
                    hint: L.pick("首次扫描会在观察期内进行，不读取文件内容。", "The first scan runs during the observation period and never reads file contents.")
                )
            } else if model.lastScanNotice != nil {
                EmptyStateView(
                    message: L.pick("重启后尚未扫描", "Not scanned since launch"),
                    hint: UICopy.candidatesNeedRescan
                )
            } else {
                EmptyStateView(
                    message: L.pick("没有可清理的候选", "No candidates to clean up"),
                    hint: L.pick("扫描范围内未发现缓存、临时环境或构建产物。", "No caches, temporary environments, or build artifacts were found in the scan scope.")
                )
            }
        } else {
            VStack(spacing: 0) {
                listHeader
                    .padding(.horizontal, Tokens.Layout.contentPadding)
                    .padding(.top, Tokens.Spacing.s)

                protectionStrip
                    .padding(.horizontal, Tokens.Layout.contentPadding)
                    .padding(.bottom, Tokens.Spacing.s)

                // 产品路径用 ScrollView（200 行/页必须能滚）；渲染路径直排。
                if renderMode {
                    candidateList
                        .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    ScrollView { candidateList }
                }

                HStack {
                    Text(L.pick("当前页最多 200 条；分页是渲染边界，不是采样。", "Up to 200 rows per page; paging is a rendering boundary, not sampling."))
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(Tokens.Color.textTertiary)
                    Spacer()
                    SemanticSlotView(slot: model.pageIndicatorSlot, muted: true)
                }
                .padding(.horizontal, Tokens.Layout.contentPadding)
                .padding(.vertical, Tokens.Spacing.xs)
            }
        }
    }

    private var listHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L.pick("候选清单", "Candidates"))
                    .font(Tokens.Typography.title)
                    .foregroundStyle(Tokens.Color.textPrimary)
                Text(L.pick("白名单中的路径不会出现在这里。", "Paths on the allowlist never appear here."))
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(Tokens.Color.textTertiary)
            }
            Spacer()
            SemanticSlotView(slot: model.totalScannedSlot, font: Tokens.Typography.numberMedium)
                .foregroundStyle(Tokens.Color.textSecondary)
        }
    }

    /// 保护边界条：哪些来源在判定域（可被自动删除）、白名单是否生效。
    ///
    /// 数据与 ① 页同源（`sourceShares.inDecisionDomain`），**不在视图里分组或计数**。
    private var protectionStrip: some View {
        HStack(spacing: Tokens.Spacing.s) {
            HStack(spacing: Tokens.Spacing.xxs) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 10))
                Text(L.pick("自动删除只作用于判定域", "Auto-delete only in the decision domain"))
                    .font(Tokens.Typography.secondary)
            }
            .foregroundStyle(Tokens.Color.textSecondary)

            Rectangle()
                .fill(Tokens.Color.divider)
                .frame(width: 1, height: 12)

            ForEach(model.sourceShares) { row in
                HStack(spacing: 4) {
                    SourceDot(sourceKey: row.sourceKey)
                    Text(row.displayName)
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(Tokens.Color.textSecondary)
                    Text(
                        row.inDecisionDomain
                            ? L.pick("在域", "In domain")
                            : L.pick("仅报告", "Report only")
                    )
                    .font(.system(size: 9))
                    .foregroundStyle(
                        row.inDecisionDomain ? Tokens.Color.success : Tokens.Color.textTertiary
                    )
                }
            }

            Spacer(minLength: 0)

            if model.hasWhitelist {
                HStack(spacing: Tokens.Spacing.xxs) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 10))
                    Text(L.pick("白名单已生效", "Allowlist active"))
                        .font(Tokens.Typography.secondary)
                }
                .foregroundStyle(Tokens.Color.textSecondary)
            }
        }
        .padding(.horizontal, Tokens.Spacing.s)
        .frame(height: 32)
        .background(
            Tokens.Color.surface,
            in: RoundedRectangle(cornerRadius: Tokens.Radius.control)
        )
    }

    /// 候选行列表（产品与渲染共用同一份内容，只有容器不同）。
    @ViewBuilder
    private var candidateList: some View {
        VStack(spacing: 0) {
            HStack(spacing: Tokens.Spacing.xs) {
                TableHeaderText(text: L.pick("来源", "Source"))
                    .frame(width: 88, alignment: .leading)
                TableHeaderText(text: L.pick("路径", "Path"))
                TableHeaderText(text: L.pick("标签", "Label"))
                    .frame(width: 120, alignment: .leading)
                TableHeaderText(text: L.pick("大小", "Size"), alignment: .trailing)
                    .frame(width: 80, alignment: .trailing)
                TableHeaderText(text: L.pick("占比", "Share"), alignment: .trailing)
                    .frame(width: 110, alignment: .trailing)
            }
            // **必须撑满**：否则表头与数据行按各自理想宽度**居中**，两套列位置错开。
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Tokens.Layout.contentPadding)
            .padding(.vertical, 6)

            DividerLine()

            LazyVStack(spacing: 0) {
                ForEach(model.candidateRows) { row in
                    HStack(spacing: Tokens.Spacing.xs) {
                        HStack(spacing: Tokens.Spacing.xxs) {
                            SourceDot(sourceKey: row.sourceKey)
                            Text(sourceName(for: row.sourceKey))
                                .font(Tokens.Typography.secondary)
                                .foregroundStyle(Tokens.Color.textSecondary)
                                .lineLimit(1)
                        }
                        .frame(width: 88, alignment: .leading)

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
                            .frame(width: 120, alignment: .leading)

                        SemanticSlotView(slot: row.bytes, font: Tokens.Typography.numberSmall)
                            .frame(width: 80, alignment: .trailing)

                        HStack(spacing: 5) {
                            RatioBarView(
                                slot: row.share,
                                color: Tokens.Color.source(for: row.sourceKey),
                                height: 4
                            )
                            if let share = row.share {
                                SemanticSlotView(slot: share.percentSlot, font: Tokens.Typography.numberSmall)
                                    .foregroundStyle(Tokens.Color.textTertiary)
                                    .frame(width: 42, alignment: .trailing)
                            } else {
                                Text("—")
                                    .font(Tokens.Typography.secondary)
                                    .foregroundStyle(Tokens.Color.textTertiary)
                                    .frame(width: 42, alignment: .trailing)
                            }
                        }
                        .frame(width: 110, alignment: .trailing)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: Tokens.Typography.tableRowHeight)
                    .padding(.horizontal, Tokens.Layout.contentPadding)

                    DividerLine()
                }
            }
        }
    }

    /// 来源键 → 展示名（**只做查表，不猜**；未知键显示「—」）。
    private func sourceName(for key: String) -> String {
        Source(rawValue: key)?.displayName ?? "—"
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
