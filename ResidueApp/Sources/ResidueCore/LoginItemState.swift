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
            return L.pick("定时任务已启用", "Scheduled task enabled")
        case .requiresApproval:
            return L.pick(
                "待你在系统设置中允许（系统设置 → 通用 → 登录项）",
                "Waiting for your approval in System Settings (System Settings → General → Login Items)"
            )
        case .notRegistered:
            return L.pick("未注册为登录项", "Not registered as a login item")
        case .notFound:
            return L.pick("登录项注册丢失，需重新安装", "Login item registration is missing; reinstall required")
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

    /// 是否该给出「设为登录项」的按钮（`.notRegistered` 态）。
    ///
    /// ## 为什么这个态必须有可执行动作
    /// `.notRegistered` 是**首启默认态**。`ScheduledRunner.start` 对它直接 return
    /// （ADR-02：非 enabled 不排程）→ 定时任务永不排 → 观察期轮次永不推进。
    /// 界面上若只有一句「未注册为登录项」而没有任何动作，用户就**没有任何
    /// 路径把产品接上定时链**——这是原先「登录项从不注册」的结构性根因。
    ///
    /// `.requiresApproval` 走「去系统设置」（系统已注册、只差用户允许）；
    /// `.notRegistered` 走「设为登录项」（主动调 `SMAppService.register`）；
    /// `.notFound` 需重装，两个按钮都不给。
    public var canRegister: Bool {
        self == .notRegistered
    }
}
