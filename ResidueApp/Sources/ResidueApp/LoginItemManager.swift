import Foundation
import ServiceManagement
import ResidueCore

// ============================================================
// Residue · 登录项管理（ADR-02）
//
// ## 为什么单独一个文件
// `SMAppService.status` 的**四态必须如实映射**——ADR-02 明确：
// 非 `.enabled` 的三种态，**定时任务一律不执行**，界面也**不得假装在跑**。
// 把这段逻辑从 AppModel 里拆出来，是为了让它只有一处、且能被逐态断言。
//
// ## 四态 → 界面文案 → 定时任务（ADR-02 原表，逐字）
// | status              | 文案                                              | 定时任务 |
// |---------------------|---------------------------------------------------|----------|
// | .enabled            | 「定时任务已启用」                                 | 正常     |
// | .requiresApproval   | 「待你在系统设置中允许（系统设置 → 通用 → 登录项）」 | **不执行** |
// | .notRegistered      | 「未注册为登录项」                                 | **不执行** |
// | .notFound           | 「登录项注册丢失，需重新安装」                      | **不执行** |
//
// ## Translocation 代价（ADR-02 如实登记）
// `.enabled` 但 App 从 `.dmg` 直接运行（未拖入「应用程序」）时，
// 迁移后路径变化可能导致「每日扫描 0 次仍显示已启用」。
// 故**启动时校验 `Bundle.main.bundlePath`**，不是 `/Applications/Residue.app` 就提示
// 「请先拖入「应用程序」」。这条不是洁癖——它是「显示已启用但从不跑」的唯一拦路。
// ============================================================

/// 登录项管理器。
struct LoginItemManager: Sendable {

    /// 读取当前状态（**如实映射四态**，不做任何「善意推断」）。
    func currentState() -> LoginItemState {
        // `SMAppService.mainApp.status` 是系统真相；不缓存、不推断
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered:
            return .notRegistered
        case .notFound:
            return .notFound
        @unknown default:
            // 未来新增状态：**按「不允许调度」处理**——
            // 未知状态判为「能跑」是拿用户数据赌一个没见过的枚举值。
            return .notFound
        }
    }

    /// 注册登录项（首次启用时调用）。
    @discardableResult
    func register() -> Result<Void, Error> {
        do {
            try SMAppService.mainApp.register()
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// 注销登录项。
    @discardableResult
    func unregister() -> Result<Void, Error> {
        do {
            try SMAppService.mainApp.unregister()
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// 打开「系统设置 → 通用 → 登录项」让用户手动允许。
    ///
    /// 只在 `.requiresApproval` 时该用——其余三态给这个按钮等于把用户支使到
    /// 一个解决不了问题的地方。
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - Translocation 校验（ADR-02 代价 ②）

    /// App 是否在「应用程序」目录。
    ///
    /// **为什么要查**：从 `.dmg` 直接运行时，macOS 会把 App 挂到
    /// `/private/var/folders/.../AppTranslocation/...` 下跑。
    /// 该路径每次启动都可能不同 → 登录项指向的路径失效 →
    /// **「每日扫描 0 次但界面仍显示已启用」**（ADR-02 明确登记此代价）。
    static func isInApplicationsFolder(bundlePath: String = Bundle.main.bundlePath) -> Bool {
        // 允许 /Applications 与 ~/Applications
        let p = bundlePath
        if p.hasPrefix("/Applications/") { return true }
        if p.hasPrefix(NSHomeDirectory() + "/Applications/") { return true }
        return false
    }

    /// 是否处于 App Translocation（只用于给出更准确的提示文案）。
    static func isTranslocated(bundlePath: String = Bundle.main.bundlePath) -> Bool {
        bundlePath.contains("/AppTranslocation/")
    }

    /// 位置问题的提示（`nil` = 位置正常）。
    static func locationWarning(bundlePath: String = Bundle.main.bundlePath) -> String? {
        if isInApplicationsFolder(bundlePath: bundlePath) { return nil }
        if isTranslocated(bundlePath: bundlePath) {
            return "请先把 Residue 拖入「应用程序」再运行——"
                + "从磁盘映像直接运行会导致登录项失效、定时任务不执行。"
        }
        return "Residue 当前不在「应用程序」文件夹，登录项可能失效。建议拖入「应用程序」后重开。"
    }
}
