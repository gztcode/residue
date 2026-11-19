import Foundation

// ============================================================
// Residue · 删除前二次检查（AC-17）
//
// ## 契约落点
// PRD:1138「删除前 L0 二次检查发现活引用并放弃该条目」。
// 候选身份键 = **路径 + birthtime**（PRD:365 / :626 / :1057 三处钉死）。
//
// ## 为什么要二次检查（扫描 → 执行之间世界会变）
//
// 候选是**扫描时刻**的快照，而删除发生在**之后的某个执行点**（可能跨天，
// 定时点尤其如此）。这中间文件系统可能已经变了：
//
// | 变化 | 后果 | 处置 |
// |---|---|---|
// | 路径被**同名重建**（删了又建） | 现在那个文件**不是当初判定的那个** | `rebuilt` → 放弃 |
// | 文件**已消失**（用户自己删了） | 没东西可删 | `vanished` → 放弃 |
// | 文件被**活引用持有**（进程打开） | 删了会打断正在用的人 | 由 L0 判定放弃 |
//
// **不复核就删 = 误删**：你以为删的是「观察期里证明没用的那个缓存」，
// 实际删的是用户刚重新装好的同名目录。这正是「删之前先证明判得准」
// （不变量④）在**执行时刻**的最后一道闸。
//
// ## 这个文件只做判定，不做文件操作
//
// 与 `TrashExecutor`（只做 moveItem）分工：这里判「该不该删」，
// 那边做「怎么删」。判定逻辑在 Core 可单测；文件操作在执行器。
// ============================================================

/// AC-17 删除前二次检查的判定。
public enum SecondCheck {

    /// 身份复核结果（**值域封闭**，每种结果对应一种明确事实）。
    public enum IdentityStatus: Equatable, Sendable {
        /// 路径存在且 birthtime 与候选记录一致 → 就是当初那个文件。
        case unchanged
        /// 路径存在但 birthtime 变了 → **同名重建**，不是当初判定的文件。
        case rebuilt
        /// 路径已不存在 → 用户已自行删除，无东西可删。
        case vanished
    }

    /// 执行前身份复核：路径下的文件**还是不是当初判定的那一个**。
    ///
    /// ## 口径必须与扫描期一致
    ///
    /// 扫描期（`ScanEngine.FileAttributes.attributes`）读的是
    /// `FileManager.attributesOfItem` 的 `.creationDate`。这里**必须读同一个
    /// 属性**，否则口径不同 → 恒判 `rebuilt` → **永不删** → 安全闸退化成恒真误报
    /// （与 M5「`b = 0` 恒真」同一类病：判据恒真就没有判别力）。
    ///
    /// fallback 也与扫描期一致（`.creationDate` 为 nil → `Date(timeIntervalSince1970: 0)`），
    /// 保证「两次都读不到」这种文件系统下两侧都是 0 → 判 `unchanged`（不误拦）。
    ///
    /// - Parameters:
    ///   - path: 候选路径。
    ///   - recordedBirthtime: 扫描期记录的 birthtime。
    ///   - fileManager: 可注入（单测用临时目录）。
    public static func checkIdentity(
        path: String,
        recordedBirthtime: Date,
        fileManager: FileManager = .default
    ) -> IdentityStatus {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path) else {
            return .vanished
        }
        let current = (attrs[.creationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        // **精确相等**，不加容差。理由：同一未变文件的 `.creationDate`
        // 来自同一个 inode 字段，两次读返回同一个 `Date`；APFS 上实测稳定。
        // 若某个文件系统导致抖动，正确做法是**修读取口径**，不是放宽比对
        // （放宽容差 = 给「短时间内被重建」留口子，那是误删方向）。
        return current == recordedBirthtime ? .unchanged : .rebuilt
    }

    /// 执行前 L0 二次检查：候选当前**是否被活引用持有**。
    ///
    /// 复用 `L0Probe.isHeld`（同一持有判据、同一实现处，不另立第二套）。
    /// 契约 AC-17 判的是「发现活引用并放弃」，所以返回 `true` = 放弃。
    ///
    /// - Parameters:
    ///   - identity: 候选的文件身份 `(dev, ino)`。
    ///   - isDirectory: 候选是否为目录（目录走 cwd 祖先判定）。
    ///   - path: 候选路径（cwd 祖先判定用）。
    ///   - snapshot: **执行时刻**新取的 L0 快照（不是扫描期那份 —— 那份已过期）。
    public static func isLiveHeld(
        identity: FileIdentity,
        isDirectory: Bool,
        path: String,
        by snapshot: L0Snapshot
    ) -> Bool {
        L0Probe.isHeld(identity: identity, isDirectory: isDirectory, path: path, by: snapshot)
    }
}
