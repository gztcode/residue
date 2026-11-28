import Foundation

// ============================================================
// Residue · L0 逐候选判定层（CR-031 §3.4 · `a` 写入路径的上游）
//
// 契约来源：
//   Residue-PRD-v5.6.md（M4 误判 · P-L0 判据）
//   Residue-R2-技术方案-v1.9.md（ADR-03 判定域 = 同 uid）
//
// ## 为什么单独成层
//
// 写回层（`ObservationWriteback`）只吃**判定结果**，不做探测 ——
// 探测（`lstat` + 快照查表）在这里，判定结果由写回层消费。
// 两层分开 ⇒ 写回层可纯函数单测；判定层可注入身份探针单测。
//
// ## 纪律
//
// - `lstat` 失败 ⇒ `.undetermined`（**不是**「无活引用」）：
//   看不见的东西不能说它安全（不变量③）。
// - **每个候选都要有判定** —— 静默跳过会让 `b` 少算、`a` 漏判，且看不出来。
// - 降级快照 ⇒ 全部 `.undetermined`：据不可信的快照说「没有活引用」= 伪造证据。
// ============================================================

/// L0 逐候选判定。
public enum L0Judge {

    /// 逐候选判定 L0 活引用。
    ///
    /// - Parameters:
    ///   - candidates: 本轮候选（**逐个**判定，不按来源聚合）。
    ///   - snapshot: 一次 L0 快照（判定域 = 同 uid 进程）。
    ///   - identityOf: 路径 → 文件身份的三态探针；
    ///     默认走真文件系统 `lstat`（**不跟随 symlink**）。
    ///     只有 `.resolved` 能支持「无活引用」的结论 —— `.absent`（确定不存在）
    ///     与 `.unreadable`（读不到）都不够格（不变量③）。
    /// - Returns: 身份键 → 判定结果（**每个候选一项**）。
    public static func judge(
        candidates: [ScanEngine.Candidate],
        snapshot: L0Snapshot,
        identityOf: (String) -> L0Probe.IdentityState = { L0Probe.identityState(atPath: $0) }
    ) -> [CandidateID: L0Verdict] {
        var verdicts: [CandidateID: L0Verdict] = [:]
        verdicts.reserveCapacity(candidates.count)

        for candidate in candidates {
            let key = CandidateID(path: candidate.path, birthtime: candidate.birthtime)

            // 降级 ⇒ 不判定（不据不可信的快照下结论）
            if snapshot.degraded {
                verdicts[key] = .undetermined
                continue
            }

            // 取不到身份 ⇒ 不判定（不许说「安全」）
            // **「确定不存在」与「读不到」都不构成「无活引用」的证据** ⇒ 都是 `.undetermined`
            guard case .resolved(let identity) = identityOf(candidate.path) else {
                verdicts[key] = .undetermined
                continue
            }

            let held = L0Probe.isHeld(
                identity: identity,
                isDirectory: candidate.isDirectory,
                path: candidate.path,
                by: snapshot
            )
            verdicts[key] = held ? .hasLiveReference : .noLiveReference
        }

        return verdicts
    }
}
