import Foundation

// ============================================================
// Residue · 删除前二次检查的**总闸**（AC-17 · fail-closed）
//
// ## 为什么要有「总闸」这一层
//
// 执行期的二次检查有两问：
//
// ① 这个路径**还是不是当初判定的那一个**？（属性 / birthtime 口径）
// ② 它**现在有没有被活引用持有**？（inode 口径）
//
// 两问都答不上来时，**唯一安全的答案是「不删」**。此前这两问各自失败时
// 落到了不同的结论上：
//
// - ① 读不到属性 ⇒ 被当成「文件已不存在」⇒ 举证链写下**假事实**（P-028）；
// - ② 取不到身份 ⇒ 被当成「没有活引用」⇒ **fail-open**，继续删（P-027）。
//
// 总闸把两问的结果收成一个**值域封闭**的结论（`.proceed` / `.blocked`），
// 判定逻辑只有这一处实现，App 层只做接线（把结论落成执行记录）。
//
// ## 口径：fail-closed
//
// 任何一处「无法判定」⇒ 阻断。只有「确定可删」才 `.proceed`。
// 与同文件里 ScopeGuard 的「拿不到允许根 ⇒ 拒绝执行」同一口径
// （不把未知判为安全，不变量③）。
//
// ## 与契约的关系
//
// AC-17 只规定了「发现活引用 ⇒ 放弃该条目」的情形；本总闸在此之上
// **收窄**了两种「答不上来」的情形，不新增任何判定口径、不新增错误码。
// ============================================================

/// 删除前二次检查的总闸判定。
public enum SecondCheckGate {

    /// 总闸结论（**值域封闭**）。
    public enum Decision: Equatable, Sendable {
        /// 通过 ⇒ 允许进入删除流程。
        case proceed
        /// 阻断 ⇒ **不得删除**。
        case blocked(BlockReason)
    }

    /// 阻断原因（值域封闭 ⇒ 举证链里的原因串不会跑偏）。
    public enum BlockReason: Equatable, Sendable {
        /// 确定不存在（`ENOENT` / `ENOTDIR`）—— 没东西可删。
        case vanished
        /// 同名重建 —— 现在这个不是当初判定的那个。
        case rebuilt
        /// 存在活引用 —— 进程正在使用。
        case liveHeld
        /// 读不到属性 / 身份 —— **无法判定** ⇒ 不删。
        case unreadable(errno: Int32)
    }

    /// 身份复核 + L0 复核 → 总闸结论（**fail-closed**）。
    ///
    /// - Parameters:
    ///   - identityStatus: ① 身份复核结果（属性 / birthtime 口径）。
    ///   - identityState: ② 身份探测结果（inode 口径，三态）。
    ///   - isLiveHeld: 活引用判定（**只在拿到身份时才会被调用**）。
    /// - Returns: 总闸结论。
    public static func decide(
        identityStatus: SecondCheck.IdentityStatus,
        identityState: L0Probe.IdentityState,
        isLiveHeld: (FileIdentity) -> Bool
    ) -> Decision {
        switch identityStatus {
        case .unchanged:
            break
        case .vanished:
            // 确定不存在 ⇒ 没东西可删（如实留痕，不是失败）。
            return .blocked(.vanished)
        case .rebuilt:
            // 同名重建 ⇒ 现在这个不是当初判定的那个 ⇒ 放弃（误删防线）。
            return .blocked(.rebuilt)
        case .unreadable(let errno):
            // 读不到属性 ⇒ 无法确认「还是当初那个文件」⇒ 不删。
            // ⚠️ 这里**不能**当成「已不存在」——那是假事实（P-028）。
            return .blocked(.unreadable(errno: errno))
        }

        switch identityState {
        case .resolved(let identity):
            // 活引用判定只在**拿到身份**时才有意义（没有身份就无从查表）。
            return isLiveHeld(identity) ? .blocked(.liveHeld) : .proceed
        case .absent:
            // ① 说「还是它」，取身份时却没了 ⇒ 期间被删 ⇒ 不删。
            return .blocked(.vanished)
        case .unreadable(let errno):
            // 取不到身份 ⇒ 无从判活引用 ⇒ **不删**。
            // ⚠️ 这正是 P-027 的 fail-open 现场：旧写法把 `nil` 当成「没有活引用」。
            return .blocked(.unreadable(errno: errno))
        }
    }
}

extension SecondCheckGate.BlockReason {

    /// 举证链里的原因串（**写实情**：读不到就写读不到，不写「已不存在」）。
    ///
    /// 这三串原样来自 App 层（未改字面），只是搬到了 Core —— 判定与文案
    /// 放在一处，才能用单测守住「不写假事实」。
    ///
    /// - Returns: 写进 `ExecutionRecord.blockedReason` 的原因串。
    public var blockedReason: String {
        switch self {
        case .vanished:
            return "二次检查：文件已不存在（已自行删除）"
        case .rebuilt:
            return "二次检查：路径已被同名重建（birthtime 不一致），不是当初判定的文件"
        case .liveHeld:
            return "二次检查：删除前发现活引用（进程正在使用）"
        case .unreadable(let errno):
            return "二次检查：无法读取文件属性（\(PathAccess.errnoName(errno))），为安全未删除"
        }
    }
}
