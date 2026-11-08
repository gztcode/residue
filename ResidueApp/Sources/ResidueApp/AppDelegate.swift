import AppKit
import SwiftUI

// ============================================================
// Residue · AppDelegate（ADR-02 的「关窗后驻留」）
//
// ## 它解决两个具体行为
// 1. **关窗后驻留**：`applicationShouldTerminateAfterLastWindowClosed = false`。
//    ADR-02 要求「关窗后驻留（NSStatusItem + 该值为 false）」——
//    否则用户点红叉就把整个定时任务关了，而他以为只是关了窗口。
// 2. **`open -a` 有反应**：没有这个回调时，App 已在跑、窗口已关的情况下
//    再从 Finder 双击 / `open -a` **什么都不发生**，用户会以为 App 坏了（客户端审查 C6）。
//
// ## 为什么不设 LSUIElement
// ADR-02 明确不设——需要主窗口与常规激活行为。菜单栏项由 SwiftUI 的
// `MenuBarExtra`（等价于 NSStatusItem）提供，不需要 LSUIElement。
// ============================================================

/// 跨层打开主窗口的通道。
///
/// SwiftUI 的 `openWindow` 只在 Scene 上下文里可用，而 AppDelegate 拿不到它。
/// 用一个极小的注册点把闭包传出来——比 NotificationCenter 少一层间接，
/// 且**注册点只有一个**（不会出现两处各自持有不同闭包）。
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    private init() {}
    /// 由 App Scene 在首次渲染时注册。
    var open: (() -> Void)?
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// 关窗不退出（ADR-02）。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 再次双击 / `open -a` 时把主窗口调回来（否则用户以为 App 坏了）。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            WindowOpener.shared.open?()
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}
