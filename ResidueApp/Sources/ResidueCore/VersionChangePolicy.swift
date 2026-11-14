import Foundation

// ============================================================
// Residue · 「应用版本变更 → 是否清零载体」的判定（CR-032 · P1-1）
//
// ## 为什么这个判定住在 Core
//
// 判定原本写在 `AppModel`（界面编排层）里，而**单测只覆盖 `ResidueCore`** ——
// 写在 AppModel 的判定**没法被单测覆盖**，于是它在真实升级场景下
// 从未生效过也没人发现：
//
// ```swift
// if !result.readOnly, !stored.isEmpty, stored != version { … }
// ```
//
// `!stored.isEmpty` 要求载体里写过版本号，而**基线从未写过** `appVersion`
// （写入方是 CR-032 才补上的）→ `stored` 恒为 `""` → **条件恒假**
// → 「版本变更 → 清零载体」这条路径**一次都没走过**。
//
// ## 判定必须区分两种「版本号读不出来」
//
// | 情形 | `carrierPresent` | `storedVersion` | 结论 |
// |---|---|---|---|
// | **首启**（压根没有载体） | `false` | `""` | **不是版本变更** → 不清零 |
// | **基线遗留**（载体在，从未写版本号） | `true` | `""` | **按版本变更处理** → 清零 |
// | 正常升级 | `true` | 旧版本号 | 版本号不同 → 清零 |
// | 未变更 | `true` | 当前版本号 | 版本号相同 → 不清零 |
//
// 两者在 `storedVersion` 上**长得一模一样**（都是空串），
// 所以「载体在不在」是这个判定的**必要输入**，不能靠版本号空不空去猜。
// ============================================================

/// 「应用版本变更 → 是否清零载体」的**唯一判定处**（CR-032 · P1-1）。
public enum VersionChangePolicy {

    /// 是否需要因应用版本变更而清零载体。
    ///
    /// - Parameters:
    ///   - carrierPresent: 载体文件（`state.residue`）是否存在。
    ///   - storedVersion: 载体里记录的 `appVersion`（空串 = 从未写过）。
    ///   - currentVersion: 当前应用版本号。
    ///   - readOnly: 载体是否处于只读降级态（`E-301` / `E-302` / `E-304` / `E-306`）。
    /// - Returns: `true` = 需要清零。
    public static func shouldResetCarrier(
        carrierPresent: Bool,
        storedVersion: String,
        currentVersion: String,
        readOnly: Bool
    ) -> Bool {
        // ① 只读降级态 → **不写**（降级路径的契约是「只读、不拒绝、不重置」）
        guard !readOnly else { return false }

        // ② 载体不在 → **首启**，不是版本变更
        //    （首启就清零 = 把「什么都没有」当成「变了」→ 无意义的写入）
        guard carrierPresent else { return false }

        // ③ 载体在：**版本号不同即版本变更**。
        //    这里**故意不排除空串**——空串 = 基线遗留（从未写过版本号），
        //    那正是最需要触发重置的情形（`a` 会跨版本永久累计）。
        return storedVersion != currentVersion
    }
}
