import SwiftUI

// ============================================================
// Residue · 设计令牌（视觉基线 v2 · CR-031）
//
// **v1.1 的色板 / 圆角 / 字号三节由 CR-031 取代**，其余条款继续有效。
// 每个值的注释写明它来自 v2 §一 的哪一条 —— R3.8 设计走查逐条对照。
//
// ## 三条纪律
// 1. **信号色仍然最多出现一次**：主行动或焦点，二选一。
// 2. **来源识别色不是状态色**：它只回答「这是谁的缓存」，不表达好坏；
//    不得用于按钮、导航选中态、检查项。
// 3. **成功 / 警示色不是第三档状态色**：它们只用于门槛清单与过程态；
//    危险色仍只给「不可逆 / 错误 / 无权限 / 超限」。
// ============================================================

enum Tokens {

    // MARK: - 颜色

    enum Color {
        /// 页面底 `#0D0F13`（v2 #1）。
        static let background = SwiftUI.Color(hex: 0x0D0F13)
        /// 卡片 / 表格容器 `#15181E`（v2 #2）。
        static let surface = SwiftUI.Color(hex: 0x15181E)
        /// 抬升面 `#1B1F27`（v2 #3）：控件、行内块、输入框。
        static let elevated = SwiftUI.Color(hex: 0x1B1F27)
        /// 正文 `#ECEEF2`（v2 #5）。
        static let textPrimary = SwiftUI.Color(hex: 0xECEEF2)
        /// 辅助 / 单位 / 说明 `#9AA1AC`（v2 #6）。
        static let textSecondary = SwiftUI.Color(hex: 0x9AA1AC)
        /// 轴标 / 列副标 / 页脚 `#6E7681`（v2 #7）。
        static let textTertiary = SwiftUI.Color(hex: 0x6E7681)

        /// **信号色（唯一强调）** `#6C79F0`（v2 #8）。
        ///
        /// 规则不变：**一个界面上信号色最多出现一次**（主行动或焦点，二选一）。
        /// 侧栏选中态、行内标签、来源圆点**不得**使用它。
        static let signal = SwiftUI.Color(hex: 0x6C79F0)
        /// **危险色** `#E5534B`（v2 #9）——删除确认 / 错误态 / 不可逆提示。
        static let danger = SwiftUI.Color(hex: 0xE5534B)
        /// **成功色** `#46B98A`（v2 #10）——只用于门槛检查项「通过」。
        static let success = SwiftUI.Color(hex: 0x46B98A)
        /// **警示色** `#E8A84C`（v2 #11）——「待结算 / 未开始 / 需授权」。
        static let warn = SwiftUI.Color(hex: 0xE8A84C)

        /// 分隔线：1 px，白 7%（v2 #4）。
        static let divider = SwiftUI.Color.white.opacity(0.07)
        /// 卡片的描边（比分隔线略强，让卡片边界在深底上可辨）。
        static let stroke = SwiftUI.Color.white.opacity(0.07)

        // ---- 来源识别色（**不是状态色**）----

        static let sourceUV = SwiftUI.Color(hex: 0x7C8CF8)
        static let sourceNPM = SwiftUI.Color(hex: 0xE8A84C)
        static let sourcePipx = SwiftUI.Color(hex: 0x56C596)
        /// CR-032 新增：Homebrew（琥珀棕）与 pip（青蓝）。
        /// **识别色不是状态色**：两者都不得与信号色 / 危险色 / 成功色混用。
        static let sourceBrew = SwiftUI.Color(hex: 0xB37A4E)
        static let sourcePip = SwiftUI.Color(hex: 0x5FB3C9)
        /// 未知来源（不猜颜色）。
        static let sourceUnknown = SwiftUI.Color(hex: 0x6E7681)

        /// 来源键 → 识别色（**唯一映射处**）。
        ///
        /// 键是 `Source.rawValue`，不是展示名——展示名会随语言变。
        static func source(for key: String) -> SwiftUI.Color {
            switch key {
            case "uv_cache": return sourceUV
            case "npm_npx": return sourceNPM
            case "pipx_run": return sourcePipx
            case "brew_cache": return sourceBrew
            case "pip_cache": return sourcePip
            default: return sourceUnknown
            }
        }
    }

    // MARK: - 排版

    enum Typography {
        /// 页标题 20 pt，Semibold（v2 #14）。
        static let pageTitle = Font.system(size: 20, weight: .semibold)
        /// 区块标题 14 pt，Semibold（v2 #14）。
        static let title = Font.system(size: 14, weight: .semibold)
        /// 正文 13 pt，行高 1.4。
        static let body = Font.system(size: 13)
        static let bodyLineSpacing: CGFloat = 13 * 0.4
        /// 次要 / 辅助 11 pt，行高 1.3。
        static let secondary = Font.system(size: 11)
        static let secondaryLineSpacing: CGFloat = 11 * 0.3
        /// 表格行高 **32 pt 固定**（契约值，v2 不变）。
        static let tableRowHeight: CGFloat = 32

        // ---- 数值刻度（等宽数字：数字不跳动）----
        static let numberHero = Font.system(size: 34, weight: .semibold).monospacedDigit()
        static let numberLarge = Font.system(size: 22, weight: .semibold).monospacedDigit()
        static let numberMedium = Font.system(size: 15, weight: .medium).monospacedDigit()
        static let numberSmall = Font.system(size: 12, weight: .medium).monospacedDigit()
    }

    // MARK: - 间距（4 的倍数）

    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
    }

    // MARK: - 图标
    enum Icon {
        static let badge: CGFloat = 9
        static let nav: CGFloat = 12
    }

    // MARK: - 圆角（v2 #13）
    enum Radius {
        /// 卡片 10 pt。
        static let card: CGFloat = 10
        /// 控件 7 pt。
        static let control: CGFloat = 7
        /// 徽标 4 pt。
        static let badge: CGFloat = 4
    }

    // MARK: - 布局
    enum Layout {
        /// 侧栏宽度（v2 #16：中英文同宽）。
        static let sidebarWidth: CGFloat = 208
        /// 内容区水平内边距。
        static let contentPadding: CGFloat = 20
    }
}

// MARK: - Hex 初始化

extension SwiftUI.Color {
    /// 由 `0xRRGGBB` 构造。
    ///
    /// 视觉基线里的色值都是 hex，直接用整数写比字符串少一层解析、也不会写错位数。
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}
