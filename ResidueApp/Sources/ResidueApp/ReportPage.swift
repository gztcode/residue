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

    /// 列宽（**加总必须 ≤ 可用宽度**，否则整页被撑宽、右侧截断）。
    ///
    /// 可用宽度 = 1000（窗口）− 208（侧栏）− 1（分隔线）− 40（页内边距）≈ **751 pt**。
    /// 7 列合计 688 pt + 列间距 56 pt = **744 pt**，中英文都留有余量。
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
