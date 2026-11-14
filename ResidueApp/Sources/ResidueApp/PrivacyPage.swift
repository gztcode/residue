import SwiftUI
import ResidueCore

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
                            // AC-14：受阻时必须给「所缺权限」+ 授权指引条目 ID。
                            // **与右侧状态相同时不重复**：`degraded` 下状态本身就带
                            // 「所缺 + 指引 ID」，再渲染一遍会让同一行出现两遍同样的话。
                            if let block = tier.blockReason, block != tier.state {
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
