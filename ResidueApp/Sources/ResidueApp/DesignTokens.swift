import SwiftUI

// ============================================================
// Residue · 设计令牌（视觉基线 v1.0 §一 / §二 逐条落地）
//
// **这不是完整 R1.5 设计基线**——它只实现最小集的四件事：
// 排版刻度 / 两档语义色 / 八态视觉映射 / 语义位类型化（后者在 ResidueCore）。
//
// **每个值的注释里都写了它来自视觉基线的哪一条**——
// 这样 R3.8 设计走查时能逐条对照，而不是凭观感判断。
// ============================================================

enum Tokens {

    // MARK: - 颜色（视觉基线 §二：**只有两档状态色，不新增第三档**）

    enum Color {
        /// 页面底 `#0F1115`。
        static let background = SwiftUI.Color(hex: 0x0F1115)
        /// 卡片 / 表格容器 `#16191F`。
        static let surface = SwiftUI.Color(hex: 0x16191F)
        /// 正文 `#E6E8EC`。
        static let textPrimary = SwiftUI.Color(hex: 0xE6E8EC)
        /// 辅助 / 单位 / 说明 `#8B9099`。
        static let textSecondary = SwiftUI.Color(hex: 0x8B9099)
        /// **信号色（唯一强调）** `#5E6AD2`——主按钮 / 可点亮 / 焦点环 / 选中态。
        ///
        /// 视觉基线 §二 的规则：**一个界面上信号色最多出现一次**（主行动或焦点，二选一）。
        static let signal = SwiftUI.Color(hex: 0x5E6AD2)
        /// **危险色** `#D9534F`——删除确认 / 错误态 / 不可逆提示。
        static let danger = SwiftUI.Color(hex: 0xD9534F)
        /// 分隔线：1 px，透明度 8%。
        static let divider = SwiftUI.Color(hex: 0xE6E8EC).opacity(0.08)
    }

    // MARK: - 排版（视觉基线 §一）

    enum Typography {
        /// 正文 13 pt，行高 1.4。
        static let body = Font.system(size: 13)
        static let bodyLineSpacing: CGFloat = 13 * 0.4
        /// 次要 / 辅助 11 pt，行高 1.3。
        static let secondary = Font.system(size: 11)
        static let secondaryLineSpacing: CGFloat = 11 * 0.3
        /// 标题 15 pt，行高 1.3，**Semibold**。
        static let title = Font.system(size: 15, weight: .semibold)
        /// 页面标题 17 pt，**Semibold**。
        static let pageTitle = Font.system(size: 17, weight: .semibold)
        /// 表格行高 **32 pt 固定**（保证 7 页矩阵不跳动）。
        static let tableRowHeight: CGFloat = 32
    }

    // MARK: - 间距（视觉基线 §一：**4 的倍数**）

    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
    }

    // MARK: - 图标（v1.1 · B2 新增）
    //
    // 为什么单独一档 9 pt：逐行属性标记的图标位是**行内**元素，
    // 与正文 13 pt / 次文字 11 pt 都不同档，且必须与文字间距 4 pt 对齐。
    // 视觉基线 v1.1 §二 明确「图标 9 pt」，这是唯一来源。
    enum Icon {
        static let badge: CGFloat = 9
    }

    // MARK: - 圆角（视觉基线 §一）

    enum Radius {
        /// 卡片 8 pt。
        static let card: CGFloat = 8
        /// 控件 6 pt。
        static let control: CGFloat = 6
        /// 徽标 4 pt。
        static let badge: CGFloat = 4
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
