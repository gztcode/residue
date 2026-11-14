import SwiftUI
import ResidueCore

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

    /// 可滚区内容：执行记录 | 举证字段 两栏，上游命令另起一卡。
    @ViewBuilder
    private var scrollableBody: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(alignment: .top, spacing: Tokens.Spacing.s) {
                recordsCard
                fieldsCard
                    .frame(width: 380)
            }

            if !model.upstreamCommands.isEmpty {
                upstreamCard
            }
        }
        .padding(Tokens.Layout.contentPadding)
    }

    private var recordsCard: some View {
        Card(padding: Tokens.Spacing.s) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Tokens.Spacing.xs) {
                    Text(L.pick("执行记录", "Execution records"))
                        .font(Tokens.Typography.title)
                        .foregroundStyle(Tokens.Color.textPrimary)
                    Spacer(minLength: Tokens.Spacing.xs)
                    Button(L.pick("导出脱敏报告", "Export redacted report"), action: onExport)
                        .buttonStyle(SecondaryButtonStyle(enabled: !model.readOnly))
                        .disabled(model.readOnly)
                }
                .padding(.bottom, Tokens.Spacing.xxs)

                if model.evidenceRows.isEmpty {
                    EmptyStateView(
                        message: L.pick("还没有执行记录", "No execution records yet"),
                        hint: L.pick("自动删除启用并有条目被清理后，这里会出现记录。", "Records appear here after auto-delete is enabled and items are cleaned up.")
                    )
                    // **必须给上限**：`EmptyStateView` 自带 `maxHeight: .infinity`，
                    // 在卡片里会无限撑高（空态渲染图里记录卡被拉到 340 pt）。
                    .frame(minHeight: 120, maxHeight: 160)
                } else {
                    ForEach(model.evidenceRows) { row in
                        HStack(spacing: Tokens.Spacing.xs) {
                            Text(row.path)
                                .font(Tokens.Typography.body)
                                .foregroundStyle(Tokens.Color.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                // 撑满剩余宽度再截断：否则长路径按理想宽度参与布局，
                                // 整页会被撑宽（侧栏被挤出画布 4 pt）。
                                .frame(maxWidth: .infinity, alignment: .leading)

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
                        .frame(height: 40)
                        .padding(.horizontal, Tokens.Spacing.xxs)

                        DividerLine()
                    }
                }
            }
        }
    }

    /// **举证链八字段**（AC-18：8 字段完整率 100%，无空白）。
    private var fieldsCard: some View {
        Card(padding: Tokens.Spacing.s) {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(
                    title: L.pick("举证链字段", "Evidence fields"),
                    trailing: "AC-18"
                )
                .padding(.bottom, Tokens.Spacing.xxs)

                DividerLine()

                if model.evidenceFields.isEmpty {
                    EmptyStateView(
                        message: L.pick("还没有举证字段", "No evidence fields yet"),
                        hint: L.pick("每条执行记录都带完整的八个字段。", "Every execution record carries all eight fields.")
                    )
                    .frame(minHeight: 100, maxHeight: 140)
                } else {
                    ForEach(Array(model.evidenceFields.enumerated()), id: \.offset) { _, pair in
                        KeyValueRow(label: pair.0, slot: pair.1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// **上游命令与出现次数**（AC-19：删除类命令出现次数 = 0）。
    private var upstreamCard: some View {
        Card(padding: Tokens.Spacing.s) {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(
                    title: L.pick("上游命令", "Upstream commands"),
                    subtitle: L.pick(
                        "AC-19：删除类命令的执行次数须为 0；只读定位命令本就会执行。",
                        "AC-19: delete commands must execute 0 times; read-only locators normally do execute."
                    )
                )

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

                DividerLine()

                ForEach(model.upstreamCommands) { row in
                    HStack(spacing: Tokens.Spacing.xs) {
                        Text(row.command)
                            .font(Tokens.Typography.body)
                            .foregroundStyle(Tokens.Color.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: Tokens.Spacing.s)
                        SemanticSlotView(slot: row.invoked, muted: true)
                            .frame(width: 56, alignment: .trailing)
                        SemanticSlotView(slot: row.executed)
                            .frame(width: 56, alignment: .trailing)
                    }
                    .frame(height: 26)
                }
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
