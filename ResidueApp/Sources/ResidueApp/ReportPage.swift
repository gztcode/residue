import SwiftUI
import ResidueCore

// MARK: - ⑤ 影子观察期报告
//
// 骨架：矩阵 + 页级状态行 + 「上一轮」行
// 必须有的语义位：矩阵**七项**全部 `.metric` / `.ratio`；
//                 ③ 列两个冻结时点分行标注；只读态显示「只读，不结算」
struct ReportPage: View {
    let model: PageModel
    @Environment(\.residueRenderMode) private var renderMode

    var body: some View {
        Group {
            if renderMode {
                content
            } else {
                ScrollView { content }
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(alignment: .top, spacing: Tokens.Spacing.s) {
                observationCard
                gateCard
            }
            .frame(height: 196)

            sampleCard

            if model.readOnly {
                readOnlyCard
            } else if model.reportRows.isEmpty {
                Card {
                    EmptyStateView(
                        message: L.pick("本轮尚无矩阵数据", "No matrix data this round"),
                        hint: L.pick("观察期结束扫描完成后生成。", "Generated after the observation period ends and the scan completes.")
                    )
                    .frame(height: 120)
                }
            } else {
                ReportMatrixView(rows: model.reportRows)
            }
        }
        .padding(Tokens.Layout.contentPadding)
    }

    private var observationCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                SectionHeader(
                    title: L.pick("本轮观察期", "This round"),
                    trailing: model.reportProduced
                        ? L.pick("报告已产出", "Report produced")
                        : L.pick("待结算", "Awaiting settlement")
                )

                HStack(alignment: .center, spacing: Tokens.Spacing.m) {
                    ObservationRing(ratio: model.observationRatio, lineWidth: 7, diameter: 76)
                        .overlay(
                            SemanticSlotView(
                                slot: model.observationDaySlot,
                                font: Tokens.Typography.numberMedium
                            )
                        )

                    VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                        if model.readOnly {
                            // 只读态不得用读不到的数值下结论（与「显示 0」同类错误）。
                            SemanticSlotView(
                                slot: .unavailable(reason: UICopy.readOnlyNoSettlement)
                            )
                        } else if let pageLevel = model.pageLevelSlot {
                            SemanticSlotView(slot: pageLevel)
                        }

                        if !model.readOnly, let previous = model.previousRoundSlot {
                            SemanticSlotView(
                                slot: previous,
                                font: Tokens.Typography.secondary
                            )
                            .foregroundStyle(Tokens.Color.textTertiary)
                        }

                        if !model.readOnly, !model.reportProduced {
                            SemanticSlotView(
                                slot: .unavailable(reason: UICopy.notSettledThisRound),
                                font: Tokens.Typography.secondary
                            )
                        }
                    }
                }
            }
        }
        .frame(width: 330)
    }

    private var gateCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(
                    title: L.pick("点亮检查", "Gate checks"),
                    trailing: model.canLightUp
                        ? L.pick("全部通过", "All passed")
                        : L.pick("未全部通过", "Not all passed")
                )
                .padding(.bottom, Tokens.Spacing.xs)

                ForEach(model.gateChecks) { row in
                    GateCheckRowView(row: row)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 逐来源样本进度（`min(K, H) / H`）。
    private var sampleCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                SectionHeader(
                    title: L.pick("样本 / 门槛", "Samples / threshold"),
                    subtitle: L.pick("分子取 min(K, H)；报告产出前不判定。", "Numerator is min(K, H); no verdict before the report is produced.")
                )
                .padding(.bottom, Tokens.Spacing.xxs)

                ForEach(model.sampleProgress) { row in
                    HStack(spacing: Tokens.Spacing.xs) {
                        HStack(spacing: Tokens.Spacing.xxs) {
                            SourceDot(sourceKey: row.sourceKey)
                            Text(row.displayName)
                                .font(Tokens.Typography.body)
                                .foregroundStyle(Tokens.Color.textPrimary)
                        }
                        .frame(width: 110, alignment: .leading)

                        RatioBarView(
                            slot: row.ratio,
                            // 样本未过门槛是「还没到」而非危险：用 warn，不用 danger。
                            color: row.passed == false
                                ? Tokens.Color.warn
                                : Tokens.Color.source(for: row.sourceKey),
                            height: 5
                        )

                        HStack(spacing: 3) {
                            SemanticSlotView(slot: row.sample, font: Tokens.Typography.numberSmall)
                            Text("/")
                                .font(Tokens.Typography.secondary)
                                .foregroundStyle(Tokens.Color.textTertiary)
                            SemanticSlotView(slot: row.threshold, font: Tokens.Typography.numberSmall)
                        }
                        .frame(width: 110, alignment: .trailing)

                        if let share = row.ratio {
                            SemanticSlotView(slot: share.percentSlot, font: Tokens.Typography.numberSmall)
                                .foregroundStyle(Tokens.Color.textTertiary)
                                .frame(width: 50, alignment: .trailing)
                        } else {
                            Text("—")
                                .font(Tokens.Typography.secondary)
                                .foregroundStyle(Tokens.Color.textTertiary)
                                .frame(width: 50, alignment: .trailing)
                        }
                    }
                    .frame(height: 26)
                }
            }
        }
    }

    private var readOnlyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                // 只读成因不同，话也不同（版本降级 vs 权限降级）。
                if model.readOnlyReason == UICopy.permissionDegradedReadOnly {
                    SemanticSlotView(slot: .unavailable(reason: UICopy.notSettledThisRound))
                    Text(UICopy.permissionDegradedReadOnly)
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(Tokens.Color.textSecondary)
                } else {
                    SemanticSlotView(slot: .unavailable(reason: UICopy.maintainedByNewerVersion))
                    Text(L.pick("数据由更高版本创建；本版本只显示结构，不显示数值。", "Data was created by a newer version; this version shows structure only, no values."))
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(Tokens.Color.textSecondary)
                }
            }
        }
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
                    // 列间距 4 pt：7 列 × 2 边 = 56 pt，加列宽 688 pt 仍 ≤ 可用 751 pt。
                    // 用 8 pt 时总宽 800 pt，整页会被撑宽并向左挤出侧栏。
                    .padding(.horizontal, 4)
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
                                if cell.count == 1 {
                                    // **非判定域行整格一句**（「不适用 · 未执行 L0 检查」，PRD AC-09 逐字）：
                                    // 拆成两个 62 pt 子格会把它截成「不适用 · 未…」。
                                    SemanticSlotView(slot: cell[0], font: Tokens.Typography.secondary)
                                } else {
                                    HStack(spacing: 0) {
                                        ForEach(Array(cell.enumerated()), id: \.offset) { _, slot in
                                            SemanticSlotView(slot: slot)
                                                .frame(width: ReportMatrix.l0SubWidth, alignment: .leading)
                                        }
                                    }
                                }
                            } else {
                                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                                    ForEach(Array(cell.enumerated()), id: \.offset) { _, slot in
                                        SemanticSlotView(slot: slot, font: cellFont(index: idx, slot: slot))
                                    }
                                }
                            }
                        }
                        .frame(width: columnWidth(for: ReportMatrix.columns[min(idx, ReportMatrix.columns.count - 1)]),
                               alignment: .leading)
                        .padding(.horizontal, 4)
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

    /// 单元格字号：**④ 门槛列的非数值槽位取 11 pt**（CR-033 / M-9）。
    ///
    /// 该列宽按数值 `H` 定。非判定域行放的是整句契约文案「不适用（不入判定域）」，
    /// 13 pt 在这个宽度下折成两行会超出 32 pt 的固定行高（v2 契约值，不动）——
    /// 11 pt 两行 28.6 pt 装得下，且与 ⑥ 列整句同字号。
    private func cellFont(index: Int, slot: SemanticSlot) -> Font {
        if index == 3, case .text = slot { return Tokens.Typography.secondary }
        return Tokens.Typography.body
    }

    /// 列宽（**加总必须 ≤ 可用宽度**，否则整页被撑宽、右侧截断）。
    ///
    /// 可用宽度 = 1000（窗口）− 208（侧栏）− 1（分隔线）− 40（页内边距）≈ **751 pt**。
    /// 7 列合计 **695 pt** + 单元格左右内边距 56 pt = **751 pt**（顶格，不再留余量）。
    ///
    /// **CR-033 / M-9 重排**：④ / ⑥ 两列要装下非判定域行的整句契约文案
    /// （「不适用（不入判定域）」/「不适用 · 未执行 L0 检查」），各自加宽；
    /// 差额从 ① 来源、② 判定域、③ 样本、⑤ 观察期、⑦ 结论 匀出。
    ///
    /// ⚠️ 按**列序**取值，不按列名。列名是多语言的（`ReportMatrix.columns`
    /// 随 `L.current` 变化），拿中文列名去 `case` 匹配在英文界面下会全部落到
    /// `default`，列宽退化成 90 —— 表头与数据列就错位了。
    private func columnWidth(for column: String) -> CGFloat {
        guard let idx = ReportMatrix.columns.firstIndex(of: column) else { return 90 }
        switch idx {
        case 0: return 86                               // 来源
        case 1: return 56                               // 判定域
        case 2: return ReportMatrix.sampleColumnWidth   // 样本 / 总量（130）
        case 3: return 144                              // 门槛（整句文案，11 pt 单行）
        case 4: return 62                               // 观察期
        case 5: return 141                              // L0 误判 · 检查（整句文案，11 pt 单行）
        case 6: return 76                               // 结论
        default: return 90
        }
    }
}
