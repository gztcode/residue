import Foundation

// ============================================================
// Residue · M3 结算（逐条归因 · `K` / `J` 的唯一实现处）
//
// 契约来源：
//   Residue-PRD-v5.6.md（M3 · 失联四类 · 归因判据封闭七行 + 兜底）
//   Residue-R2-技术方案-v1.9.md（§26.2 · 判据表）
//   docs/changes/Residue-CR-031-KJ结算写入.md（§3.2）
//
// **纪律**：本文件是 `K` 的**唯一算法实现处**（不变量②：同一判定只有一个实现处）。
// 判据按 ① → ② → ③ → ④ → ⑤ → ⑥ → ⑦ → 兜底 的顺序判定，**首个命中者生效**。
//
// **为什么探针可注入**：归因要区分「条目被删」与「父目录被改名/被删」，
// 二者只探条目路径时分不开（都表现为条目 `lstat` 失败）⇒ 必须**双探针**
// （条目路径 + 父目录路径，各三态）。探针可注入 ⇒ 归因判定是**纯函数**、
// 可单测，不碰真文件系统。
// ============================================================

/// M3 · 一轮结算的结果。
public struct SettlementOutcome: Sendable {
    /// `T` / `K` / `J`（`J = T − K` 派生，恒等式 `K + J = T`）。
    public let metrics: SnapshotMetrics
    /// **无法归因**的条数（失联四类之一）——必须如实披露：
    /// 不得并入已归因、也不得静默丢弃。
    public let unattributableCount: Int
    /// 逐条归因（顺序 = 快照顺序）。
    public let attributions: [Settlement.Attribution]

    public init(
        metrics: SnapshotMetrics,
        unattributableCount: Int,
        attributions: [Settlement.Attribution]
    ) {
        self.metrics = metrics
        self.unattributableCount = unattributableCount
        self.attributions = attributions
    }
}

/// M3 · 逐条归因。
public enum Settlement {

    /// 路径探针三态（可注入 ⇒ 归因判定是纯函数、可单测，不碰真文件系统）。
    public enum PathState: String, Sendable, Equatable {
        /// 路径存在。
        case exists
        /// 路径确定不存在。
        case absent
        /// 不可读（权限 / 跨 uid）——**不判定**。
        case inaccessible
    }

    /// 失联四类（**只作标签**，不改变 `J`）。
    public enum Label: String, Sendable, Equatable {
        /// 改名。
        case renamed
        /// 用户手删。
        case userDeleted
        /// 目录拆分合并（含同名重建）。
        case directoryRestructured
        /// 无法归因（**兜底**：不把未知判为安全，不变量③）。
        case unattributable
    }

    /// 单条快照条目的归因结论。
    public enum Status: Sendable, Equatable {
        /// 不属失联（计入 `K`）。
        case attributable
        /// 失联（只打标签，不计入 `K`）。
        case lost(Label)
    }

    /// 一条快照条目的归因结果。
    public struct Attribution: Sendable, Equatable {
        public let candidate: CandidateID
        public let status: Status

        public init(candidate: CandidateID, status: Status) {
            self.candidate = candidate
            self.status = status
        }
    }

    // ---------- 逐条归因 ----------

    /// 逐条归因。`K` 由结果直接得出，`J = T − K` 派生。
    ///
    /// `probe` 对「条目路径」与「父目录路径」各探一次。
    /// 结果顺序 = `snapshot` 顺序（稳定，便于逐条比对与落盘）。
    public static func attribute(
        snapshot: [CandidateID],
        current: [CandidateID],
        probe: (String) -> PathState
    ) -> [Attribution] {
        // 一次遍历建两张索引表 ⇒ 后续判据判定全是 O(1) 查表。
        let byPath = Dictionary(grouping: current, by: \.path)
        let byBirthtime = Dictionary(grouping: current, by: \.birthtime)

        return snapshot.map { item in
            Attribution(
                candidate: item,
                status: status(of: item, byPath: byPath, byBirthtime: byBirthtime, probe: probe)
            )
        }
    }

    // ---------- 结算 ----------

    /// 结算：产出 `T` / `K` / `J` + 失联标签 + **无法归因条数**。
    ///
    /// 这是 `K` 的**唯一**聚合实现处（不变量②）——调用方不得另行数一遍。
    public static func settle(
        snapshot: [CandidateID],
        current: [CandidateID],
        probe: (String) -> PathState,
        snapshotDate: Date,
        settlementDate: Date
    ) -> SettlementOutcome {
        let attributions = attribute(snapshot: snapshot, current: current, probe: probe)

        let attributable = attributions.filter { $0.status == .attributable }.count
        let unattributable = attributions.filter { $0.status == .lost(.unattributable) }.count

        let metrics = SnapshotMetrics(
            total: snapshot.count,
            attributable: attributable,
            snapshotDate: snapshotDate,
            settlementDate: settlementDate
        )

        return SettlementOutcome(
            metrics: metrics,
            unattributableCount: unattributable,
            attributions: attributions
        )
    }

    // ---------- 判据（私有：唯一实现处，外部只能经 attribute/settle 进入） ----------

    /// 单条判定的完整判据链（契约七行 + 兜底，按序、首个命中者生效）。
    private static func status(
        of item: CandidateID,
        byPath: [String: [CandidateID]],
        byBirthtime: [Date: [CandidateID]],
        probe: (String) -> PathState
    ) -> Status {
        let samePath = byPath[item.path] ?? []

        // ① 身份键（路径 + birthtime）在当前结果中命中 → **不属失联**（计入 `K`）。
        if samePath.contains(where: { $0.birthtime == item.birthtime }) {
            return .attributable
        }

        // ② 路径**相同**但 `birthtime` 变化（**同名重建**）→ 目录拆分合并。
        if !samePath.isEmpty {
            return .lost(.directoryRestructured)
        }

        // ③ 路径不同、同 `birthtime` 在当前结果中**唯一**命中一条 → 改名。
        // ④ 路径不同、同 `birthtime` **命中不止一条**（匹配不唯一）→ 无法归因。
        let sameBirthtime = byBirthtime[item.birthtime] ?? []
        if sameBirthtime.count == 1 {
            return .lost(.renamed)
        }
        if sameBirthtime.count > 1 {
            return .lost(.unattributable)
        }

        // 以下：无同 `birthtime` 命中者 —— 转入路径探针三态判定。

        // ⑤ 该路径**不可读**（`lstat` 失败：权限 / 跨 uid）→ 无法归因。
        switch probe(item.path) {
        case .inaccessible:
            return .lost(.unattributable)
        case .exists:
            // ⑦ 该路径**仍在但已不再是候选** → 目录拆分合并。
            return .lost(.directoryRestructured)
        case .absent:
            break
        }

        // ⑥ / ⑦ / 兜底：父目录探针。
        switch probe(parentDirectory(of: item.path)) {
        case .exists:
            // ⑥ 父目录**仍存在可读**、该路径**确定已不存在** → 用户手删。
            return .lost(.userDeleted)
        case .absent:
            // ⑦ 父目录**确定已不在**（父目录结构变化致路径失效）→ 目录拆分合并。
            return .lost(.directoryRestructured)
        case .inaccessible:
            // 兜底：父目录不可读 → **不判定** → 无法归因（不变量③）。
            return .lost(.unattributable)
        }
    }

    /// 条目路径的父目录路径。
    private static func parentDirectory(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// 真文件系统的路径探针（`lstat` · **不跟随 symlink**）。
    ///
    /// ## 纪律原文
    /// 「凡涉及『这条路径本身是什么』，一律不跟随 symlink」——
    /// 跟随会把符号链接判成目标，链接本身仍在却报「不存在」⇒ 误判为「用户手删」。
    ///
    /// ## 三态口径
    /// - `.exists`：`lstat` 成功（**含指向不存在目标的符号链接本身仍在**）。
    /// - `.absent`：**确定**不存在（`ENOENT` / `ENOTDIR`）。
    /// - `.inaccessible`：读不到（`EACCES` / `EPERM`）**或任何其它 errno** ——
    ///   归因失败时**宁可判「不判定」也不猜**（不变量③：不把未知判为安全）。
    public static func systemPathState(of path: String) -> PathState {
        var st = stat()
        if lstat(path, &st) == 0 { return .exists }
        switch errno {
        case ENOENT, ENOTDIR:
            return .absent
        default:
            return .inaccessible
        }
    }
}
