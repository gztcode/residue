import XCTest
@testable import ResidueCore

// ============================================================
// 登录项四态 → 界面动作（ADR-02）
//
// ## 为什么值得单独一组测试
//
// 这一组布尔属性看似微不足道，但它们的**组合就是「产品能不能接上定时链」**
// 的全部出路。写错一个，后果分层很清楚：
//
// | 写错的形态 | 后果 |
// |---|---|
// | `.notRegistered` 漏给「设为登录项」按钮 | **产品锁死**：首启永远接不上定时任务 |
// | `.requiresApproval` 给「设为登录项」而非「去系统设置」 | 用户点了没用，系统已经注册过，只是没被允许 |
// | `.enabled` 也给按钮 | 界面自相矛盾（「已启用」旁边一个「设为登录项」） |
// | `.notFound` 给任何动作按钮 | 注册路径已坏，重装才能解决；界面支使用户走死路 |
// ============================================================

final class LoginItemStateTests: XCTestCase {

    // MARK: - canRegister（`.notRegistered` → true）

    /// `.notRegistered` 是首启默认态，必须有注册入口。
    func testNotRegisteredCanRegister() {
        XCTAssertTrue(LoginItemState.notRegistered.canRegister)
    }

    /// `.requiresApproval` 走「去系统设置」，不给注册按钮（系统已注册过）。
    func testRequiresApprovalCannotRegister() {
        XCTAssertFalse(LoginItemState.requiresApproval.canRegister)
    }

    /// `.enabled` 已注册，不需要再注册。
    func testEnabledCannotRegister() {
        XCTAssertFalse(LoginItemState.enabled.canRegister)
    }

    /// `.notFound` 注册路径已坏，需要重装，不给注册按钮。
    func testNotFoundCannotRegister() {
        XCTAssertFalse(LoginItemState.notFound.canRegister)
    }

    // MARK: - 互斥性（`canRegister` 与 `needsUserApproval` 不会同时为真）

    /// 四态中任意一态，`canRegister` 与 `needsUserApproval` 不会同时为真。
    ///
    /// 这两个按钮分别接 `registerLoginItem()`（主动注册）与 `openLoginItemSettings()`
    /// （打开系统设置），同时显示会让用户不知道走哪条路。
    func testCanRegisterAndNeedsApprovalAreMutuallyExclusive() {
        let allCases: [LoginItemState] = [.enabled, .requiresApproval, .notRegistered, .notFound]
        for state in allCases {
            XCTAssertFalse(
                state.canRegister && state.needsUserApproval,
                "\(state) 不应同时 canRegister 与 needsUserApproval"
            )
        }
    }

    // MARK: - allowsScheduling（ADR-02：只有 `.enabled` 才执行）

    func testOnlyEnabledAllowsScheduling() {
        XCTAssertTrue(LoginItemState.enabled.allowsScheduling)
        XCTAssertFalse(LoginItemState.requiresApproval.allowsScheduling)
        XCTAssertFalse(LoginItemState.notRegistered.allowsScheduling)
        XCTAssertFalse(LoginItemState.notFound.allowsScheduling)
    }
}
