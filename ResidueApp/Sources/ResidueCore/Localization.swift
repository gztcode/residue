import Foundation

// ============================================================
// Residue · 多语言（简体中文 / English）
//
// ## 为什么不用 `.lproj` + `NSLocalizedString`
// 本项目是 SwiftPM 包 + `make_app.sh` 手工组 bundle，没有 Xcode 工程。
// 走 `.lproj` 要额外把 `*.strings` 编进 bundle（还要处理 `Bundle.module` 的
// 资源包路径），**多一条只在打包期才暴露的失败路径**。
//
// 更重要的原因是本项目自己的不变量（`CLAUDE.md` §四.2）：
// **同一文案只有一个实现处**。把译文放在 `Localizable.strings` 里，
// 键名与代码分居两处 —— 「改了一边忘了另一边」正是这个项目反复复发的病。
// 所以译文与中文**写在同一个调用点**，缺一边编译不过。
//
// ## 为什么默认语言写死 `zhHans`
// `L.current` 的默认值必须是**确定的**：单测与 `--verify-wiring` 会断言
// 中文契约文案，如果默认值跟着开发机语言走，同一份代码在 CI（en_US）
// 与本地（zh_CN）会得出不同结果 —— 测试变成「看机器脸色」。
// 跟随系统语言这件事由 App 启动时调用 `applyEnvironment()` 完成（IO 层），
// Core 侧保持确定。
// ============================================================

/// 产品支持的语言。
///
/// 值域**封闭**：多一种语言就要同步补齐所有 `L.pick` 的译文，
/// 而 `L.pick` 是双参数 —— 加语言会让编译器指出全部需要改的地方。
public enum AppLanguage: String, Sendable, CaseIterable {
    case zhHans = "zh-Hans"
    case en = "en"

    /// 从系统「首选语言」列表里挑一个支持的语言（**纯函数，可单测**）。
    ///
    /// 规则：按顺序取第一个能映射的语言标签；都不认识 → `zhHans`（产品母语）。
    /// 不认识的标签**不报错、不猜成英文** —— 回到母语是唯一不会说谎的选项。
    public static func resolve(preferredLanguages: [String]) -> AppLanguage {
        for raw in preferredLanguages {
            let tag = raw.lowercased()
            if tag.hasPrefix("zh") { return .zhHans }
            if tag.hasPrefix("en") { return .en }
        }
        return .zhHans
    }

    /// 语言在界面上的自称（切换菜单用，**永远用该语言自己的写法**）。
    public var nativeName: String {
        switch self {
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }
}

/// 语言选择 + 取词。
public enum L {

    /// 当前语言。
    ///
    /// 默认 `zhHans`（见文件头：默认值必须确定，否则单测随机器变红）。
    /// App 启动时调用 `applyEnvironment()` 覆盖。
    ///
    /// `nonisolated(unsafe)`：这是启动期写一次、之后只读的进程级设置。
    /// 用锁包一层会让每次取词都付一次同步开销，而收益为零 ——
    /// 真正需要并发安全的是扫描状态，不是语言。
    nonisolated(unsafe) public static var current: AppLanguage = .zhHans

    /// 按当前语言取词（**唯一的取词入口**）。
    ///
    /// 双参数而不是「键 + 字典」：缺一种语言的译文是**编译错误**，
    /// 不是运行期回退到中文这种静默失败。
    public static func pick(_ zhHans: String, _ en: String) -> String {
        current == .en ? en : zhHans
    }

    /// 按「环境变量 > 系统首选语言 > 母语」的优先级决定当前语言。
    ///
    /// - `RESIDUE_LANG=en` / `RESIDUE_LANG=zh-Hans`：显式指定。
    ///   截图、设计稿重渲染、验证脚本用它固定语言，避免结果随机器变化。
    /// - 否则跟随系统首选语言（App 启动时传入 `Locale.preferredLanguages`）。
    public static func applyEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        if let raw = environment["RESIDUE_LANG"], !raw.isEmpty {
            current = AppLanguage.resolve(preferredLanguages: [raw])
        } else {
            current = AppLanguage.resolve(preferredLanguages: preferredLanguages)
        }
    }
}
