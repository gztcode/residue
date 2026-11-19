import Foundation

// ============================================================
// Residue · 观察期重置的**判定**（CR-038 §3.8）
//
// ## 为什么要有这一层
//
// 「要不要把观察期打回起点」是**判定**，不是 IO ——
// 它必须住在 Core（可单测、纯函数、**只有一处实现**），不能散在 App 层的
// `if` 里（不变量②）。
//
// ## 两条重置路径的**区别**（PRD v5.6 M4）
//
// | 触发 | `a`（误判累计） | 载荷（`F` / `C_done` / 位槽占用表） |
// |---|---|---|
// | 应用版本变更 | **清零** | 清空 |
// | 判定域指纹变更 | **保留** | **保留** |
//
// 判错过一次不会因为「判定域变了」就变成没发生过（S2「错 1 次永久」）——
// 所以第二条路径**必须保留 `a`**，而 `a` 的载体也必须一并保留，
// 否则头与载荷自相矛盾。
// ============================================================

/// 观察期重置的**原因**。
public enum ObservationResetReason: String, Codable, Sendable, Equatable {
    /// 不需要重置（首启 / 版本与指纹都没变）。
    case none
    /// 应用版本变更 ⇒ `a` 与载荷一并清零。
    case appVersionChanged
    /// 判定域成员指纹变更 ⇒ 观察期凭证重置，但 `a` 保留。
    case decisionDomainChanged
}

/// 「要不要重置观察期」的**纯判定**。
public enum ObservationResetPolicy {

    /// 判定观察期是否需要重置。
    ///
    /// - Parameters:
    ///   - storedAppVersion: 载体里记的应用版本（**空 = 首启**）。
    ///   - currentAppVersion: 当前应用版本。
    ///   - storedDecisionDomainSignature: 载体里记的判定域成员指纹（**`nil` = 旧载体，没这个键**）。
    ///   - currentDecisionDomainSignature: 当前代码算出的判定域成员指纹。
    ///
    /// - Returns: 重置原因；`.none` 表示不动载体。
    ///
    /// ## 判定顺序（顺序本身是契约的一部分）
    ///
    /// 1. **首启**（`storedAppVersion` 为空）⇒ `.none`
    ///    —— 载体里没有「旧版本」可比，清不清都一样；此时清反而会造出
    ///    「什么都不曾发生」的假态。
    /// 2. **应用版本变更** ⇒ `.appVersionChanged`
    ///    —— 优先于指纹判定：版本变更的重置更彻底（`a` 也清），
    ///    两者同时成立时一次重置就够，不必写两次载体。
    /// 3. **判定域指纹变更** ⇒ `.decisionDomainChanged`
    ///    —— 版本没变但判定域成员变了 ⇒ 观察期凭证必须重新积累，
    ///    但 `a` 保留（M4：「`a` 只在应用版本变更时清零」）。
    ///
    /// ## 旧载体（`storedDecisionDomainSignature == nil`）为什么算「变更」
    ///
    /// 旧版本写出的载体里**根本没有**这个键 ⇒ **无法证明**判定域没变过。
    /// 「无法证明」不等于「没变」——按不变量③（不把未知判为安全），
    /// 这里必须判**变更** ⇒ 触发一次重置。
    /// 若判「没变」，旧凭证（对应旧判定域）会被新判定域继承 ⇒
    /// 新来源带着零观察证据进自动删除候选集 ⇒ **误删**。
    public static func reason(
        storedAppVersion: String,
        currentAppVersion: String,
        storedDecisionDomainSignature: String?,
        currentDecisionDomainSignature: String
    ) -> ObservationResetReason {
        // ① 首启：没有旧凭证可清
        guard !storedAppVersion.isEmpty else { return .none }

        // ② 应用版本变更（优先）
        guard storedAppVersion == currentAppVersion else { return .appVersionChanged }

        // ③ 判定域成员指纹：缺失 ⇒ 无法证明没变 ⇒ 按变更处置
        guard let stored = storedDecisionDomainSignature else { return .decisionDomainChanged }
        return stored == currentDecisionDomainSignature ? .none : .decisionDomainChanged
    }
}
