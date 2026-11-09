import SwiftUI
import ResidueCore

// ============================================================
// Residue · 共享组件
//
// **关键约束**：页面上所有「数值 / 状态」都经 `SemanticSlotView` 渲染。
// 这意味着界面代码里**不可能出现算术**——它拿到的只是 `SemanticSlot`，
// 而 `SemanticSlot` 只能由 `Metrics` / `GateEvaluator` 构造（ResidueCore）。
// 这比「在 review 时说一句不要算」可靠。
// ============================================================

// MARK: - 语义位渲染（**界面唯一的取值出口**）

/// 渲染一个 `SemanticSlot`。
///
/// 页面里**不得**自己把 `Int` 拼成字符串——必须先在 `Metrics` 侧构造成
/// `SemanticSlot`，再交给本视图。
struct SemanticSlotView: View {
    let slot: SemanticSlot
    /// 是否用次要文字色（用于单位、辅助说明）。
    var muted: Bool = false
    /// 字号覆盖（默认正文 13 pt；① 页数值用 17 pt 强调）。
    var font: Font = Tokens.Typography.body

    var body: some View {
        if let state = slot.stateLabel {
            StateLabelView(label: state)
        } else {
            Text(slot.displayText)
                .font(font)
                .foregroundStyle(textColor)
        }
    }

    private var textColor: SwiftUI.Color {
        if slot.isUnavailable { return Tokens.Color.textSecondary }
        return muted ? Tokens.Color.textSecondary : Tokens.Color.textPrimary
    }
}

/// 七态标签（视觉基线 §三：**每态 = 一行文案 + 一个图标位**）。
struct StateLabelView: View {
    let label: StateLabel

    var body: some View {
        HStack(spacing: Tokens.Spacing.xxs) {
            if let symbol = label.symbolName {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(tint)
            }
            Text(label.label)
                .font(Tokens.Typography.secondary)
                .foregroundStyle(tint)
        }
        .padding(.horizontal, Tokens.Spacing.xs)
        .padding(.vertical, Tokens.Spacing.xxs)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Tokens.Radius.badge))
    }

    private var tint: SwiftUI.Color {
        // 视觉基线 §二：危险色只用于「不可逆 / 错误 / 无权限 / 超限」
        label.usesDangerColor ? Tokens.Color.danger : Tokens.Color.textSecondary
    }
}

// MARK: - 容器

/// 卡片（`#16191F`，圆角 8）。
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Tokens.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.Color.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
    }
}

/// 区块标题（15 pt Semibold）。
struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Tokens.Typography.title)
            .foregroundStyle(Tokens.Color.textPrimary)
    }
}

/// 键值一行（左侧标签 11 pt 次文字，右侧语义位）。
struct KeyValueRow: View {
    let label: String
    let slot: SemanticSlot

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(Tokens.Typography.secondary)
                .foregroundStyle(Tokens.Color.textSecondary)
            Spacer(minLength: Tokens.Spacing.s)
            SemanticSlotView(slot: slot)
        }
        .frame(minHeight: Tokens.Typography.tableRowHeight)
    }
}

/// 1 px 分隔线（透明度 8%）。
struct DividerLine: View {
    var body: some View {
        Rectangle()
            .fill(Tokens.Color.divider)
            .frame(height: 1)
    }
}

/// 只读态顶部固定说明条（视觉基线 §三「只读」）。
struct ReadOnlyBanner: View {
    /// **只读的成因文案**（必填，有默认值仅为兼容旧调用）。
    ///
    /// ## 为什么必须传进来
    ///
    /// 原来这句是硬编码的「数据由更高版本创建」—— 那是 **`E-301` 版本降级**。
    /// 而 AC-14 的**权限降级**（`E-501`，无法枚举本用户进程）是另一条路径：
    /// 成因不同、用户该做的事不同（装回更高版本 vs 去授权）、
    /// 能否自行解除也不同（否 vs 是）。
    ///
    /// 硬编码一种文案的后果：**权限降级的用户会被告知「装回更高版本」，
    /// 而他本来就装着最新版** —— 那是一条走不通的指引。
    /// （设计走查 DAC v2.0 §8.2 C-4 / R1.5 B-09 指出）
    var reason: String = UICopy.versionDegradedReadOnly

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Image(systemName: "pencil.slash")
                .font(.system(size: 11))
            Text(reason)
                .font(Tokens.Typography.secondary)
        }
        .foregroundStyle(Tokens.Color.textSecondary)
        .padding(.vertical, Tokens.Spacing.xs)
        .padding(.horizontal, Tokens.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Color.surface)
    }
}

/// 状态条（并发冲突 / 后台任务提示，视觉基线 §五「状态条」）。
struct StatusBar: View {
    let slot: SemanticSlot

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            SemanticSlotView(slot: slot)
            Spacer()
        }
        .padding(.vertical, Tokens.Spacing.xs)
        .padding(.horizontal, Tokens.Spacing.s)
        .background(Tokens.Color.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.control))
    }
}

// MARK: - 按钮样式（**不用系统 `.bordered` / `.borderedProminent`**）
//
// 两个理由：
// 1. **设计一致性**：系统按钮自带圆角与配色，不符合视觉基线
//    （只允许两档状态色、圆角 6 pt）。用系统样式就等于让系统决定视觉。
// 2. **可渲染性**：`.bordered` 在 `ImageRenderer` 离屏渲染下会退化成
//    黄色「禁止」占位符（实测），导致设计走查看不到按钮真实样子。
//
// 视觉基线 §二：一个界面上**信号色最多出现一次**；危险色只给不可逆动作。

/// 主行动按钮（信号色 `#5E6AD2`）。
struct PrimaryButtonStyle: ButtonStyle {
    var enabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Tokens.Typography.body)
            .foregroundStyle(enabled ? SwiftUI.Color.white : Tokens.Color.textSecondary)
            .padding(.horizontal, Tokens.Spacing.s)
            .padding(.vertical, Tokens.Spacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.control)
                    .fill(enabled ? Tokens.Color.signal : Tokens.Color.surface)
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

/// 危险动作按钮（危险色 `#D9534F`，只用于不可逆动作）。
struct DangerButtonStyle: ButtonStyle {
    var enabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Tokens.Typography.body)
            .foregroundStyle(enabled ? SwiftUI.Color.white : Tokens.Color.textSecondary)
            .padding(.horizontal, Tokens.Spacing.s)
            .padding(.vertical, Tokens.Spacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.control)
                    .fill(enabled ? Tokens.Color.danger : Tokens.Color.surface)
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

/// 次要按钮（描边，无填充）。
struct SecondaryButtonStyle: ButtonStyle {
    var enabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Tokens.Typography.body)
            .foregroundStyle(enabled ? Tokens.Color.textPrimary : Tokens.Color.textSecondary)
            .padding(.horizontal, Tokens.Spacing.xs)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.control)
                    .stroke(Tokens.Color.divider, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}


// MARK: - 开关（**自建，不用系统 Toggle**）
//
// 两个理由，与按钮同源：
// 1. **设计一致性**：系统开关用系统强调色，不符合视觉基线的「只有信号色 + 危险色」；
//    圆角 / 尺寸也由系统决定，token 不起作用。
// 2. **可渲染性**：`.toggleStyle(.switch)` 在 `ImageRenderer` 离屏渲染下
//    同样退化成黄色「禁止」占位符（实测），设计走查看不到真实形态。
//
// 语义：**不可点亮时必须 disabled** —— 否则用户能点但点了不生效，
// 那比「不能点」更糟（AC-08 组 B 的全部意义就是「未达线不得点亮」）。

struct TokenSwitch: View {
    let isOn: Bool
    var enabled: Bool = true

    private let trackWidth: CGFloat = 34
    private let trackHeight: CGFloat = 19
    private let knobSize: CGFloat = 15

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            // ⚠️ 不用 `Capsule`：半径 = 高/2 = 9.5 pt = 凭空第 4 个圆角档
            //    （视觉基线 §一 只有 8 / 6 / 4 三档）。改用控件档 6 pt。
            RoundedRectangle(cornerRadius: Tokens.Radius.control)
                .fill(trackColor)
                .frame(width: trackWidth, height: trackHeight)

            Circle()
                .fill(knobColor)
                .frame(width: knobSize, height: knobSize)
                .padding(.horizontal, 2)
        }
        .frame(width: trackWidth, height: trackHeight)
        .opacity(enabled ? 1.0 : 0.45)
        // 无动画：视觉基线 §六 明确「动效时长曲线」不在最小集内
    }

    private var trackColor: SwiftUI.Color {
        guard enabled else { return Tokens.Color.textSecondary.opacity(0.25) }
        // ⚠️ 「关」态**不能用 `surface` 色**——卡片背景就是 `surface`，
        //    同色叠加会让轨道完全看不见（实测踩过：只剩一个孤立圆点）。
        //    用次文字色的低透明度：仍在既定色板内，不引入第三种色。
        return isOn ? Tokens.Color.signal : Tokens.Color.textSecondary.opacity(0.35)
    }

    private var knobColor: SwiftUI.Color {
        if !enabled { return Tokens.Color.textSecondary }
        return isOn ? .white : Tokens.Color.textSecondary
    }
}


struct LoadingView: View {
    let message: String
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(spacing: Tokens.Spacing.s) {
            ProgressView()
                .progressViewStyle(.circular)
                // 视觉基线 §三：加载态 = 中性 + 信号色（进度环）
                .tint(Tokens.Color.signal)
            Text(message)
                .font(Tokens.Typography.secondary)
                .foregroundStyle(Tokens.Color.textSecondary)
            if let onCancel {
                Button(L.pick("取消", "Cancel"), action: onCancel)
                    .buttonStyle(.plain)
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(Tokens.Color.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 空态（视觉基线 §三「空」：无图标 + 一句主文案 + 一句操作指引）

struct EmptyStateView: View {
    let message: String
    let hint: String

    var body: some View {
        VStack(spacing: Tokens.Spacing.xs) {
            Text(message)
                .font(Tokens.Typography.body)
                // 视觉基线 §二：空态 / 加载文案属「中性提示」= **次文字色**，
                // 不得用主文字色（那是正文的颜色，会让空态看起来像内容）
                .foregroundStyle(Tokens.Color.textSecondary)
            Text(hint)
                .font(Tokens.Typography.secondary)
                .foregroundStyle(Tokens.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 错误态（视觉基线 §三：**错误码 + 一句可执行动作**）

struct ErrorStateView: View {
    let code: String
    let action: String

    var body: some View {
        VStack(spacing: Tokens.Spacing.xs) {
            HStack(spacing: Tokens.Spacing.xxs) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                Text(code)
                    .font(Tokens.Typography.body)
            }
            .foregroundStyle(Tokens.Color.danger)

            Text(action)
                .font(Tokens.Typography.secondary)
                .foregroundStyle(Tokens.Color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Tokens.Spacing.m)
    }
}

// MARK: - 渲染模式环境开关（**修正一个架构性错误**）
//
// ## 为什么需要它
// `ImageRenderer` 不渲染 `ScrollView` 的内容。我最初的处理是**把产品里的
// ScrollView 全删掉**——让渲染工具能看见，代价是产品里 200 行的候选列表
// 只能显示 17 行、且无法滚动。**这是让验证工具反向决定了产品版式，方向错了。**
//
// ## 正确解法
// 两条路径都保留，用环境开关切换：
//   - **产品路径**（默认）：`ScrollView` + `LazyVStack` —— 能滚、能懒加载
//   - **渲染路径**（仅 `PageRenderer` 置 true）：`VStack` 直排 —— 只渲前 N 行做版式核对
//
// 渲染路径**只用于设计走查取色/测量**，不承担「滚动可用性」的验证；
// 滚动可用性需真实 GUI 会话验（已登记为 A-9 遗留第 1 条）。

private struct ResidueRenderModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// `true` 时表示当前处于离屏渲染（`ImageRenderer`），界面应避开 `ScrollView`。
    var residueRenderMode: Bool {
        get { self[ResidueRenderModeKey.self] }
        set { self[ResidueRenderModeKey.self] = newValue }
    }
}

// MARK: - 错误提示条（视觉基线 §三：**错误码 + 一句可执行动作**）

/// 顶部错误条。
///
/// 契约硬要求：错误态**必须给可执行动作**，不能只报错码。
/// 文案由 `AppModel.describe(...)` 给全（含「释放磁盘后重试」这类动作），
/// 本视图只负责呈现，不再拼文案——否则又会变成「同一事实两处写」。
struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
            Text(message)
                .font(Tokens.Typography.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Tokens.Color.danger)
        .padding(.horizontal, Tokens.Spacing.m)
        .padding(.vertical, Tokens.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Color.danger.opacity(0.10))
    }
}

// MARK: - 位置告警条（**中性色，不是错误**）

/// 安装位置提示（Translocation / 不在「应用程序」）。
///
/// 为什么用中性色而不是危险色：视觉基线 §二 规定危险色只给「不可逆 / 错误」。
/// 「App 放错地方」既不可逆也不错误，它是一个待办提示——用危险色会与
/// 真正的错误（状态文件损坏、磁盘满）混在一起，用户就分不出轻重了。
struct WarningBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.xs) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
            Text(message)
                .font(Tokens.Typography.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Tokens.Color.textSecondary)
        .padding(.horizontal, Tokens.Spacing.m)
        .padding(.vertical, Tokens.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Color.textSecondary.opacity(0.08))
    }
}


// MARK: - 输入框（**系统 TextField 在离屏渲染下会退化成占位符**）

/// 带 token 外观的单行输入框。
///
/// ## 为什么需要它
///
/// 与 `.bordered` 按钮、`.toggleStyle(.switch)` 是同一类问题：
/// **系统控件在 `ImageRenderer` 下会渲染成黄色「禁止」占位符**，
/// 于是设计走查看到的是一块黄条，而不是输入框。
///
/// 处置方式与按钮一致但有一点不同：按钮可以自绘（因为交互只是「点」），
/// 而输入框**必须保留真实输入能力**，不能自绘一个假的。
///
/// 所以这里走 `residueRenderMode`：产品路径用真 `TextField`（有光标、能输入），
/// 渲染路径画一个**外观一致**的静态框（只为走查取色与版式核对）。
///
/// **诚实边界**：渲染图里它是静态的 —— 走查看的是「它长什么样、占多宽」，
/// 不是「能不能打字」。后者需要真实 GUI 会话（已登记为长期遗留）。
struct TokenTextField: View {
    let placeholder: String
    @Binding var text: String
    @Environment(\.residueRenderMode) private var renderMode

    var body: some View {
        Group {
            if renderMode {
                // 渲染路径：静态外观（文字与产品路径一致，便于走查核字号与内边距）
                HStack {
                    Text(text.isEmpty ? placeholder : text)
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(Tokens.Color.textSecondary)
                    Spacer(minLength: 0)
                }
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(Tokens.Color.textPrimary)
            }
        }
        .padding(.horizontal, Tokens.Spacing.xs)
        .padding(.vertical, Tokens.Spacing.xxs)
        .frame(height: 24)
        .background(
            Tokens.Color.surface,
            in: RoundedRectangle(cornerRadius: Tokens.Radius.control)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.control)
                .stroke(Tokens.Color.textSecondary.opacity(0.25), lineWidth: 1)
        )
    }
}
