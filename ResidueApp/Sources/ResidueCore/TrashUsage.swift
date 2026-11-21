import Foundation

// ============================================================
// Residue · 回收站占用（CR-042）
//
// ## 口径（**只算本产品移入、且尚未恢复的条目**）
//
// 产品只会「rename 到废纸篓」，**从不真正删除** —— 所以一次清理之后，
// 磁盘并没有被腾出来，条目仍然占着废纸篓的空间。用户需要看到这个数，
// 否则「已移入废纸篓」会被读成「已释放」。
//
// ## 为什么这是「本产品账」而不是系统废纸篓总量
//
// 用户可能自己往废纸篓里扔东西、也可能在 Finder 里清空废纸篓。
// 前者我们不知道，后者我们感知不到（没有废纸篓监听）。
// 所以这里记的是**本产品成功移入且未恢复的条目累计**：
// - 是系统废纸篓占用量的**下界**；
// - 用户清空废纸篓后这个数会偏大 —— 台账里如实写明该局限。
//
// ## `nil ≠ 0`（不变量③）
//
// `TrashUsage?` 为 `nil` = **没有记录**（旧载体 / 首启 / 从没执行过清理），
// 界面显示「未知」。**不得**拿 0 当缺省：0 会被读成「回收站是空的」。
// ============================================================

/// 回收站占用（本产品移入、尚未恢复的条目）。
public struct TrashUsage: Codable, Sendable, Equatable {
    /// 占用字节数（`t2` 实测值的累计）。
    public var bytes: Int64
    /// 条目数。
    public var items: Int
    /// 最近一次变动时刻（审计用）。
    public var updatedAt: Date

    public init(bytes: Int64, items: Int, updatedAt: Date) {
        self.bytes = bytes
        self.items = items
        self.updatedAt = updatedAt
    }
}

/// 回收站占用的**运行期缓存**。
///
/// `TrashExecutor` 在每次成功 `moveItem` 后调用 `recordMoved`；
/// 恢复 / 回滚成功时调用 `recordRestored`。`AppModel` 负责把 `usage`
/// 写进现有载体（`StateHeader.trashUsage`）并落盘 —— 不新开存储。
///
/// **线程安全**：`TrashExecutor` 在 `Task.detached` 里执行，
/// 而 `AppModel` 在主 actor 读 `usage`，故用 `NSLock` 保护。
public final class TrashUsageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TrashUsage?

    /// - Parameter usage: 从载体读回的初始值（`nil` = 未知）。
    public init(usage: TrashUsage? = nil) {
        self.stored = usage
    }

    /// 当前记录（`nil` = 未知，**不是 0**）。
    public var usage: TrashUsage? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// 从载体读回时覆盖一次（启动时调用）。
    public func seed(_ usage: TrashUsage?) {
        lock.lock()
        defer { lock.unlock() }
        stored = usage
    }

    /// 成功移入废纸篓一条。
    public func recordMoved(bytes: Int64, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        // 未知 → 从这条开始建账（口径就是「本产品移入的条目」）。
        let current = stored ?? TrashUsage(bytes: 0, items: 0, updatedAt: now)
        stored = TrashUsage(
            bytes: current.bytes + max(0, bytes),
            items: current.items + 1,
            updatedAt: now
        )
    }

    /// 成功从废纸篓移回一条（用户恢复 / `t2` 超限回滚）。
    ///
    /// **未知保持未知**：账都没建过，就不知道这一条是不是账里的，
    /// 凭空造一个 0 等于声称「回收站空了」。
    public func recordRestored(bytes: Int64, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard let current = stored else { return }
        stored = TrashUsage(
            bytes: max(0, current.bytes - max(0, bytes)),
            items: max(0, current.items - 1),
            updatedAt: now
        )
    }
}
