import SwiftUI
import ResidueCore

// MARK: - ⑥ 确认清理（抽屉态）
//
// 骨架：抽屉 + 不可逆提示
// 必须有的语义位：本次将删除条目数与字节（`.metric`）+ **危险色**确认按钮
struct ConfirmDrawer: View {
    let model: PageModel
    var onConfirm: () -> Void
    var onCancel: () -> Void
    /// 作为页面渲染时由页头承担标题；作为 sheet 时自己显示标题。
    var showsHeader: Bool = true
    @Environment(\.residueRenderMode) private var renderMode

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {

            HStack(alignment: .firstTextBaseline) {
                if showsHeader {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L.pick("确认清理", "Confirm cleanup"))
                            .font(Tokens.Typography.pageTitle)
                            .foregroundStyle(Tokens.Color.textPrimary)
                        Text(L.pick("定时执行批次的预览", "Preview of the scheduled batch"))
                            .font(Tokens.Typography.secondary)
                            .foregroundStyle(Tokens.Color.textTertiary)
                    }
                }
                Spacer()
                Pill(
                    text: L.pick("不可逆", "Irreversible"),
                    color: Tokens.Color.danger,
                    icon: "exclamationmark.triangle"
                )
            }

            // **语义（CR-023 裁定）**：⑥ 是**自动执行批次的预览**，不是手动删除入口。
            // 契约里没有「用户手动删文件」这条路径（AC-04 只写「到达定时执行点」）。
            Text(L.pick("本次为定时执行批次的预览。执行时仍逐来源复核门槛；未达标的来源不会被执行。", "This is a preview of the scheduled batch. Each source's gate is re-checked at execution time; sources that don't qualify are not executed."))
                .font(Tokens.Typography.secondary)
                .foregroundStyle(Tokens.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: Tokens.Spacing.xxs) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                Text(UICopy.irreversibleNotice)
                    .font(Tokens.Typography.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Tokens.Color.danger)

            DividerLine()

            // 本次将删除的规模（三个 `.metric`，**分开可读**）
            HStack(spacing: Tokens.Spacing.xl) {
                metricBlock(L.pick("条目", "Items"), model.confirmItemCount, emphasized: true)
                metricBlock(L.pick("字节", "Bytes"), model.confirmBytes, emphasized: true)
                metricBlock(L.pick("顺延条目", "Deferred"), model.deferredCountSlot, emphasized: false)
            }

            DividerLine()

            // 批次内条目（**只读清单**，CR-031 §三）
            HStack {
                Text(L.pick("批次内条目", "Items in this batch"))
                    .font(Tokens.Typography.title)
                    .foregroundStyle(Tokens.Color.textPrimary)
                Spacer()
                if model.confirmListTruncated {
                    Text(L.pick("仅显示前 50 条", "Showing first 50"))
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(Tokens.Color.textTertiary)
                }
            }

            if model.confirmRows.isEmpty {
                // 重启后候选清单不落盘 → 「空」不代表「没有可执行条目」，
                // 而是「还没扫描」。两者不能共用一句话。
                Text(
                    model.loading
                        ? model.loadingMessage
                        : (model.lastScanNotice != nil
                            ? UICopy.candidatesNeedRescan
                            : L.pick("本批次没有可执行条目。", "No runnable items in this batch."))
                )
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(Tokens.Color.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            } else if renderMode {
                itemList
            } else {
                ScrollView { itemList }
                    .frame(maxHeight: 230)
            }

            Spacer(minLength: 0)

            HStack(spacing: Tokens.Spacing.s) {
                Button(L.pick("取消", "Cancel"), action: onCancel)
                    .buttonStyle(SecondaryButtonStyle())

                Spacer()

                Button(L.pick("立即执行本次清理", "Run this cleanup now"), action: onConfirm)
                    // **危险色**——这是全应用唯一该用危险色的主动作
                    .buttonStyle(DangerButtonStyle(enabled: canExecute))
                    .disabled(!canExecute)
            }

            if !canExecute && !model.readOnly {
                // 门槛未过 / 扫描中 / 重启后未扫描 → **说明为什么不能点**，
                // 而不是让它静默 disabled。
                SemanticSlotView(slot: .unavailable(reason: disabledReason))
            }
        }
        .padding(Tokens.Spacing.l)
        .frame(minWidth: 460, minHeight: 420)
    }

    /// 是否允许执行本批次。
    ///
    /// **同门槛**：未达线不得执行（AC-04 ③ 逐来源复核 + AC-08 组 B）。
    /// 另加 **本会话必须扫描过**：重启后候选为空，批次没有成员，
    /// 此时「执行」只会产生一条空记录。
    private var canExecute: Bool {
        model.canLightUp && !model.readOnly && model.hasLiveScan && !model.loading
    }

    /// 不可执行时的原因（**必须与按钮的 disabled 条件一一对应**）。
    private var disabledReason: String {
        if model.loading {
            return model.loadingMessage
        }
        if model.hasLiveScan {
            return L.pick(
                "未达达标条件，暂不能执行（逐来源复核未通过）",
                "Gate not met; can't run yet (per-source re-check failed)"
            )
        }
        return L.pick(
            "本次启动尚未扫描：候选清单为空，扫描后才能生成批次。",
            "No scan since launch: the candidate list is empty. Scan first to build a batch."
        )
    }

    private func metricBlock(
        _ label: String,
        _ slot: SemanticSlot,
        emphasized: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Tokens.Typography.secondary)
                .foregroundStyle(Tokens.Color.textTertiary)
            SemanticSlotView(
                slot: slot,
                font: emphasized ? Tokens.Typography.numberLarge : Tokens.Typography.numberMedium
            )
            .foregroundStyle(emphasized ? Tokens.Color.textPrimary : Tokens.Color.textSecondary)
        }
    }

    private var itemList: some View {
        VStack(spacing: 0) {
            ForEach(model.confirmRows) { row in
                HStack(spacing: Tokens.Spacing.xs) {
                    SourceDot(sourceKey: row.sourceKey)

                    Text(row.path)
                        .font(Tokens.Typography.body)
                        .foregroundStyle(Tokens.Color.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: Tokens.Spacing.xs)

                    RatioBarView(
                        slot: row.share,
                        color: Tokens.Color.source(for: row.sourceKey),
                        height: 4
                    )
                    .frame(width: 70)

                    SemanticSlotView(slot: row.bytes, font: Tokens.Typography.numberSmall)
                        .frame(width: 76, alignment: .trailing)

                    Pill(text: L.pick("将执行", "Will run"), color: Tokens.Color.textSecondary)
                        .frame(width: 62, alignment: .trailing)
                }
                .frame(height: Tokens.Typography.tableRowHeight)

                DividerLine()
            }
        }
    }
}
