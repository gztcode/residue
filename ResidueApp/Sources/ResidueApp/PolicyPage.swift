import SwiftUI
import ResidueCore

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
                            let selected = model.executionModeLabel == mode.label
                            Button {
                                onSetExecutionMode(mode)
                            } label: {
                                HStack(spacing: 4) {
                                    if selected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9, weight: .bold))
                                    }
                                    Text(mode.label)
                                        .font(Tokens.Typography.secondary)
                                }
                                .foregroundStyle(
                                    selected ? Tokens.Color.textPrimary : Tokens.Color.textSecondary
                                )
                                .padding(.horizontal, 10)
                                .frame(height: 26)
                                .background(
                                    selected
                                        ? Tokens.Color.textPrimary.opacity(0.12)
                                        : Tokens.Color.surface,
                                    in: RoundedRectangle(cornerRadius: Tokens.Radius.control)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: Tokens.Radius.control)
                                        .stroke(
                                            selected
                                                ? Tokens.Color.textPrimary.opacity(0.25)
                                                : Tokens.Color.divider,
                                            lineWidth: 1
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(model.readOnly || selected)
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
