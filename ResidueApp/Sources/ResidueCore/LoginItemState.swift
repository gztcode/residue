import Foundation

// ============================================================
// Residue · 登录项状态（ADR-02 四态）
//
// **放在 Core 而不在 App**：它是纯数据 + 文案，`PageModelBuilder` 要用它
// 生成 ③ 页的状态位；放 App 层会导致构造器够不到（而构造器在 Core）。
// `SMAppService` 的封装仍留在 App（那部分依赖系统框架，无法单测）。
//
// ## 四态 → 文案（ADR-02 原表，逐字）
// 非 `.enabled` 的三种态：**定时任务一律不执行**，界面**不得假装在跑**。
// ============================================================

public enum LoginItemState: Equatable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound

    /// 界面文案（ADR-02 原表，**逐字**）。
    public var label: String {
        switch self {
        case .enabled:
            return "定时任务已启用"
        case .requiresApproval:
            return "待你在系统设置中允许（系统设置 → 通用 → 登录项）"
        case .notRegistered:
            return "未注册为登录项"
        case .notFound:
            return "登录项注册丢失，需重新安装"
        }
    }

    /// **定时任务是否允许执行**（ADR-02：只有 `.enabled` 才执行）。
    public var allowsScheduling: Bool {
        self == .enabled
    }

    /// 是否该给出「去系统设置」的按钮。
    public var needsUserApproval: Bool {
        self == .requiresApproval
    }
}
