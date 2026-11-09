import SwiftUI
import ResidueCore

// ============================================================
// Residue · 应用入口（ADR-02：单进程 + 菜单栏常驻）
//
// 「无常驻」的准确表述是**任务级**——「无常驻采样任务在运行」，
// 不是「无常驻进程」（本产品是单进程 + 菜单栏常驻，进程本来就该在）。
// 见 PRD v5.4 · AC-10 与 R2 ADR-02。
//
// 主界面（七页）从菜单栏打开；`LSUIElement = true` ⇒ 无 Dock 图标。
// ============================================================

@main
struct ResidueApp: App {
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// **AppModel 在 App 级持有**（不在 RootView 里）。
    ///
    /// 客户端审查 C4：原来 `@State private var app = AppModel()` 放在 `RootView`，
    /// 用户关窗（菜单栏 App 的常态动作）即销毁它 → 扫描状态、登录项状态、
    /// 排程器全部丢失 → 接真实数据后等于「关窗即取消扫描且无提示」。
    @State private var app = AppModel()

    init() {
        // 语言必须在**任何文案被求值之前**定下来：`PageModel` 的默认值、
        // `UICopy` 都是按 `L.current` 在构造期取词的。
        // 优先级：`RESIDUE_LANG` > 系统首选语言 > 简体中文（见 `Localization.swift`）。
        L.applyEnvironment()

        #if DEBUG
        // 开发期渲染入口：`--render-pages <dir>` 渲染七页 PNG 后直接退出。
        // **不随发布版分发**（整段在 `#if DEBUG` 内，Release 不编译）。
        if PageRenderer.runIfRequested() {
            exit(0)
        }
        // 接线自检：真的走一遍「首启落盘 → 扫描 → 落盘 → 清除」
        if WiringSelfCheck.runIfRequested() {
            exit(0)
        }
        #endif
    }

    var body: some Scene {
        // ---- 菜单栏常驻 ----
        MenuBarExtra("Residue", systemImage: "internaldrive") {
            Button(L.pick("打开主界面…", "Open main window…")) {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("o")

            Divider()

            Text(L.pick("本机 · 零外发", "On-device · No outbound"))
                .font(.caption)

            Divider()

            Button(L.pick("退出", "Quit")) {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)

        // ---- 主窗口（七页）----
        Window("Residue", id: "main") {
            RootView(app: app)
                .onAppear {
                    // 注册重开窗口的通道（AppDelegate 在 open -a 时用它）
                    WindowOpener.shared.open = {
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
        }
        .defaultSize(width: 1000, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {}   // 本产品无「新建」语义
        }
    }
}
