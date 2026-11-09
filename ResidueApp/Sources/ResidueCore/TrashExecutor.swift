import Foundation

// ============================================================
// Residue · 删除执行器
//
// 契约硬约束（AC-04 / N5 / AC-19 / AC-13）：
//   - **禁止 `rm`**；一律**原子 rename 到废纸篓**
//   - 删除动作**唯一执行主体 = 产品**（非上游命令）
//   - 举证链须记录「执行动作 = rename_to_trash」与「恢复位置」（U2 文件恢复）
//   - 恢复 = 从废纸篓 rename 回原路径
//
// 本文件只做文件系统操作，**不做判定**——判定在 GateEvaluator。
// ============================================================

/// 执行动作枚举（契约 P3 / §5.3 · **动作字段的值域封闭**）。
///
/// **每个值对应一种「为什么没删 / 删了 / 恢复了」的事实**，不得复用：
/// - `failed` = 「尝试了但失败」（含执行期错误）；
/// - `blocked_out_of_scope` = 「按规则**拒绝执行**」（越界 / 符号链接，E-204）——
///   **不复用 `failed`**：两者的用例预期不同（K2 质量组指出这是三套判据互斥的根因）。
public enum ExecutionAction: String, Codable, Sendable {
    case renameToTrash = "rename_to_trash"
    case blockedSecondCheck = "blocked_second_check"
    case blockedCap = "blocked_cap"
    case blockedSizeUnknown = "blocked_size_unknown"
    case blockedOutOfScope = "blocked_out_of_scope"
    case failed = "failed"
    case restoredByUser = "restored_by_user"
}

/// 一条执行记录（举证链的「执行动作 / 恢复位置」来源）。
public struct ExecutionRecord: Codable, Sendable, Equatable {
    public let id: CandidateID
    public let source: Source
    public let action: ExecutionAction
    /// 原路径。
    public let originalPath: String
    /// 恢复位置（废纸篓中的路径）——U2 文件恢复的唯一依据。
    public let restorePath: String?
    public let executedAt: Date
    public let bytes: Int64

    /// **`t1` 预检值**（IF-07 / B-02：删除前预估用的递归逻辑字节）。
    ///
    /// ## 为什么必须有这个字段（**原本无载体**）
    ///
    /// AC-15 的判据是「实际删除量不超过上限」，而契约要求**两个取数时点**：
    /// - `t1` = **首检时刻**的递归字节 → 预检用（决定删不删）
    /// - `t2` = **rename 完成后**对废纸篓条目重新实测的值 → 对账用（决定是否回滚）
    ///
    /// 两者**都要写进 `execution.jsonl`**，否则「实际删除量」没有唯一取数时点，
    /// 判据就退化成恒真断言。
    ///
    /// 原实现只有一个 `bytes` 字段 → R2 已记「❌ 无载体」。
    public let bytesPreview: Int64

    /// **`t2` 实测时刻**（rename 完成后对废纸篓条目 `stat` 的时刻）。
    ///
    /// `nil` = 该条目**没有发生 rename**（预检阶段就被拦截），
    /// 此时 `bytes` 与 `bytesPreview` 相同（预检值即最终值）。
    public let bytesMeasuredAt: Date?

    /// 字节数的种类（**必填**）：目录的 `bytes` 是**递归逻辑字节**，
    /// 不标 kind 会让读者把目录的 ~96 B 当成真实体积（K2 质量组指出）。
    public enum BytesKind: String, Codable, Sendable {
        /// 普通文件的 `st_size`。
        case file
        /// 目录：子树内所有普通文件 `st_size` 之和（**不计目录自身 `st_size`**）。
        case dirRecursive
    }
    public let bytesKind: BytesKind

    /// 阻断原因（`action` 为 `blocked_*` 时有值；**值域封闭**，两个拦截场景不同串）。
    public let blockedReason: String?

    public init(
        id: CandidateID,
        source: Source,
        action: ExecutionAction,
        originalPath: String,
        restorePath: String?,
        executedAt: Date,
        bytes: Int64,
        bytesKind: BytesKind = .file,
        blockedReason: String? = nil,
        bytesPreview: Int64? = nil,
        bytesMeasuredAt: Date? = nil
    ) {
        self.id = id
        self.source = source
        self.action = action
        self.originalPath = originalPath
        self.restorePath = restorePath
        self.executedAt = executedAt
        self.bytes = bytes
        self.bytesKind = bytesKind
        self.blockedReason = blockedReason
        // **缺省**：没给预检值时，预检值 = 实测值（单条、无预检的场景）。
        // 给了就以调用方给的为准（那是 `t1`，与 `t2` 可能不同）。
        self.bytesPreview = bytesPreview ?? bytes
        self.bytesMeasuredAt = bytesMeasuredAt
    }
}

/// 执行结果。
public struct ExecutionOutcome: Sendable {
    public var records: [ExecutionRecord]
    public var failures: [(CandidateID, String)]
    public var skippedByCap: Int
    public var deletedBytes: Int64

    public init(
        records: [ExecutionRecord] = [],
        failures: [(CandidateID, String)] = [],
        skippedByCap: Int = 0,
        deletedBytes: Int64 = 0
    ) {
        self.records = records
        self.failures = failures
        self.skippedByCap = skippedByCap
        self.deletedBytes = deletedBytes
    }
}

/// 删除执行器。
public struct TrashExecutor {
    public let trashDirectory: URL
    nonisolated(unsafe) public let fileManager: FileManager

    public init(trashDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.trashDirectory = trashDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".Trash", isDirectory: true)
    }

    /// 把一个候选原子 rename 到废纸篓。
    ///
    /// - 目标名：`<原文件名>.<时间戳>.<随机后缀>`，避免与废纸篓既有条目冲突
    /// - **不调用 `rm` / `unlink`**：只用 `moveItem`
    /// - Parameters:
    ///   - previewBytes: **`t1` 预检值**（首检时刻的递归逻辑字节）。
    ///     传 `nil` 则移动前现算一次（口径仍相同）。
    ///     **契约要求它是「随候选缓存到执行点」的值**（IF-08）——
    ///     所以批量执行时应由 `execute` 把预检时的值传进来，
    ///     而不是在这里重算（重算 = 变成了「执行时刻的实时值」，正是契约禁止的）。
    public func moveToTrash(
        _ id: CandidateID,
        source: Source,
        now: Date = Date(),
        previewBytes: Int64? = nil
    ) throws -> ExecutionRecord {
        let src = URL(fileURLWithPath: id.path)
        let attrs = try fileManager.attributesOfItem(atPath: id.path)
        let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
        // **目录用递归逻辑字节**（IF-07）：目录的 `st_size` 只有 ~96 B，
        // 拿它当字节数会让 AC-15 的容量上限判定恒真。
        // **`t1` 预检值**：优先用调用方缓存的那份（契约要求），
        // 没有才现算（口径与 `logicalBytes(of:)` 一致）。
        let (preview, bytesKind): (Int64, ExecutionRecord.BytesKind) = isDir
            ? (previewBytes ?? recursiveLogicalBytes(atPath: id.path), .dirRecursive)
            : ((previewBytes ?? (attrs[.size] as? NSNumber)?.int64Value ?? 0), .file)

        let base = src.lastPathComponent
        let suffix = UUID().uuidString.prefix(8)
        let stamp = Int(now.timeIntervalSince1970)
        let destName = "\(base).\(stamp).\(suffix)"
        let dest = trashDirectory.appendingPathComponent(destName)

        try fileManager.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        // 原子 move（同一卷上等价 rename）
        try fileManager.moveItem(at: src, to: dest)

        // ---- `t2`：rename 完成后对废纸篓条目**重新实测**（IF-07 / B-02）----
        //
        // 契约要求「实际删除量」取 `rename` 后的实测值，而不是预检时的估算值 ——
        // 否则「预检通过 → 删除发生 → 实测超限」这条路径不可达，判据失去判别力。
        //
        // 为什么实测值可能与预检值不同：目录的内容在「扫描 → 执行」之间可能变化
        // （另一个进程正在往里写、或用户自己放了东西进去）。
        // **这正是要实测的理由** —— 用估算值对账等于拿自己的假设验自己。
        let (measuredBytes, measuredKind) = measureLogicalBytes(at: dest)

        return ExecutionRecord(
            id: id,
            source: source,
            action: .renameToTrash,
            originalPath: id.path,
            restorePath: dest.path,
            executedAt: now,
            bytes: measuredBytes,
            bytesKind: measuredKind,
            // **`t1` 预检值**（与 `t2` 实测值分别落盘）
            bytesPreview: preview,
            bytesMeasuredAt: now
        )
    }

    /// 测量某个路径的逻辑字节（`t1` 与 `t2` 共用同一口径）。
    ///
    /// **唯一的测量实现处** —— `t1`（移动前）与 `t2`（移动后）必须同口径，
    /// 否则两者的差值没有意义。
    ///
    /// ## 为什么不复用 `recursiveLogicalBytesResult`
    ///
    /// 最初这里是**又抄了一份**递归实现 —— 而「同一段逻辑存在两份、各自腐坏」
    /// 正是 CR-027 D-1 的温床（本项目第 5 次撞上这个病）。
    /// 故改为：`recursiveLogicalBytesResult` 是唯一实现，本函数调它。
    private func measureLogicalBytes(
        at url: URL
    ) -> (bytes: Int64, kind: ExecutionRecord.BytesKind) {
        let fileManager = self.fileManager
        let attrs = try? fileManager.attributesOfItem(atPath: url.path)
        let isDir = (attrs?[.type] as? FileAttributeType) == .typeDirectory
        guard isDir else {
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            return (size, .file)
        }
        // 目录：递归逻辑字节（目录自身 `st_size` 不计入、不跟随符号链接）
        let result = recursiveLogicalBytesResult(atPath: url.path)
        return (result.bytes, .dirRecursive)
    }

    /// **递归逻辑字节**（IF-07）：子树内所有普通文件 `st_size` 之和。
    ///
    /// - **不计目录自身的 `st_size`**（否则每个目录凭空加 ~96 B）。
    /// - **不跟随符号链接**（S-03：symlink 的目标不在子树内，不能计入）。
    /// - 遇到不可读的条目 → **跳过并计数**，不抛错（不让一条坏文件毁掉整个统计）。
    /// - 返回 `(字节数, 无法读取的条目数)`；调用方若不能接受「读不全」，
    ///   应改走 `E-207`（体积不可得 → 不删），而不是拿一个偏小的数去撞上限。
    public func recursiveLogicalBytes(atPath path: String) -> Int64 {
        recursiveLogicalBytesResult(atPath: path).bytes
    }

    /// 递归逻辑字节 + 不可读条目计数。
    ///
    /// **唯一的递归实现处** —— `t1`（移动前）、`t2`（移动后）、
    /// 以及公开的 `recursiveLogicalBytes` 全部走这里。
    public func recursiveLogicalBytesResult(atPath path: String) -> (bytes: Int64, unreadable: Int) {
        var total: Int64 = 0
        var unreadable = 0
        var stack = [path]

        // ⚠️⚠️ **必须用非递归列举**（`contentsOfDirectory`），不能用 `FileManager.enumerator(at:)`：
        //   `enumerator(at:)` **本身就是递归的** —— 在 `A` 上枚举会连 `A/sub/b.bin` 一起吐出来。
        //   若再手动 `stack.append(sub)` 下探一次，子目录里的文件会被**数两遍**。
        //
        //   实测（2026-11-08 · 25KB + sub/75KB）：期望 102400，实际 **179200**（多出正好 75KB）。
        //
        //   **这是同一个坑的第二次**：ScanEngine 的 `listDirectory` 也踩过
        //   （`enumerator` 递归 + 手动下探叠加 → 真文件系统栈溢出）。
        //   教训：**凡要手动控制下探（为了跳过符号链接 / 控制深度），列举 API 就必须是非递归的。**
        while let dir = stack.popLast() {
            let children: [String]
            do {
                children = try fileManager.contentsOfDirectory(atPath: dir)
            } catch {
                unreadable += 1
                continue
            }

            for name in children {
                let full = (dir as NSString).appendingPathComponent(name)
                // 用 lstat 语义：`attributesOfItem` 不跟随符号链接
                guard let a = try? fileManager.attributesOfItem(atPath: full) else {
                    unreadable += 1
                    continue
                }
                let type = a[.type] as? FileAttributeType

                // **符号链接：只计自身、不下降、不计目标**（S-03）
                if type == .typeSymbolicLink { continue }

                if type == .typeDirectory {
                    stack.append(full)          // 目录：下探，自身 st_size 不计入
                } else if let size = (a[.size] as? NSNumber)?.int64Value {
                    total += size               // 普通文件：计 st_size
                }
            }
        }

        return (total, unreadable)
    }

    /// 恢复失败的原因。
    ///
    /// ## 为什么原来用裸 `NSError(code: 1)`
    /// 因为「恢复」这条路径没有码。裸 `NSError` 的问题是它的 code 是
    /// 实现自定义的整数，**与 §6 码表没有任何对应关系** ——
    /// 「码 ↔ 用例」核对时，这三条错误在码表里查不到，等于三条无主的失败路径。
    ///
    /// 换成有类型的错误后，每条都挂上了码表里真实的码。
    public enum RestoreError: Error, Equatable, Sendable {
        /// 记录本身没有恢复位置（旧版记录 / 字段缺失）。
        ///
        /// 归 `E-201`「源不存在」：对用户而言「这条恢复不了」是同一件事——
        /// 废纸篓里那份拿不回来。**不是码表缺口，是「源没了」的一种成因。**
        case noRestorePath
        /// 废纸篓里已不存在该条目（用户在 Finder 里清空了废纸篓）。
        case goneFromTrash
        /// 原路径已被占用 → **不覆盖**（`E-205`）。
        ///
        /// 覆盖等于用旧文件打掉用户新装的东西，这是**不可逆的数据损坏**，
        /// 所以产品选择报错而不是自动改名或覆盖。
        case originalPathOccupied

        public var diagnostic: DiagnosticCode {
            switch self {
            case .noRestorePath: return .e201
            case .goneFromTrash: return .e201
            case .originalPathOccupied: return .e205
            }
        }
    }

    /// 从废纸篓恢复到原路径（U2 文件恢复 · AC-13）。
    ///
    /// 契约：恢复位置有效性 = 废纸篓中该条目存在。
    public func restore(_ record: ExecutionRecord, now: Date = Date()) throws -> ExecutionRecord {
        guard let restorePath = record.restorePath else {
            throw RestoreError.noRestorePath
        }
        let from = URL(fileURLWithPath: restorePath)
        guard fileManager.fileExists(atPath: restorePath) else {
            throw RestoreError.goneFromTrash
        }
        let to = URL(fileURLWithPath: record.originalPath)
        // 原路径若已被占用，不覆盖——如实报错，交用户处理
        if fileManager.fileExists(atPath: record.originalPath) {
            // **不覆盖**：覆盖等于用旧文件打掉用户新装的东西（不可逆数据损坏）
            throw RestoreError.originalPathOccupied
        }
        try fileManager.createDirectory(
            at: to.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: from, to: to)

        // **恢复动作回写为 `restored_by_user`**（K2 建议 S1）：
        // 不回写则「恢复过几次」不可追，也就无法判断「同一误删反复恢复」。
        return ExecutionRecord(
            id: record.id,
            source: record.source,
            action: .restoredByUser,
            originalPath: record.originalPath,
            restorePath: nil,
            executedAt: now,
            bytes: record.bytes,
            bytesKind: record.bytesKind
        )
    }

    // MARK: - 单次容量上限的判定（AC-15）

    /// 一次执行所处的阶段（AC-15 的「首次 / 稳定后」分界）。
    public enum ExecutionTier: Sendable, Equatable {
        /// **首次**：本机首次产生实际删除动作。
        case firstRun
        /// **稳定后**：已完成 ≥ 1 次实际删除后的后续执行。
        case steady
    }

    /// 一次执行的**单次容量上限**（AC-15）。
    ///
    /// ## 三条上界，取最小
    ///
    /// | 上界 | 来源 |
    /// |---|---|
    /// | `userCapBytes` | **用户自己配置的上限**（AC-03 四项之一） |
    /// | `absoluteCapBytes` | 首次档的绝对上限（5 GB） |
    /// | `sourceTotalBytes × ratio` | 来源总量按比例（首次 10% / 稳定后 20%） |
    ///
    /// ## 为什么「稳定后」也要受 `userCapBytes` 约束
    ///
    /// 原实现在稳定后那一支只写 `T×20%`，**把用户配置的上限丢了** ——
    /// 于是用户把上限调到 1 GB 之后，第一次执行按 1 GB 走（对），
    /// 第二次执行又跳回 20%（错），**用户的设置静默失效**。
    ///
    /// AC-15 的措辞是「**不超过**来源 20%」——「不超过」是**上界**，不是目标值。
    /// 用户自己设的上限同样是一个上界，两条上界取小才是对的。
    public static func capacityCap(
        userCapBytes: Int64,
        absoluteCapBytes: Int64,
        sourceTotalBytes: Int64,
        tier: ExecutionTier
    ) -> Int64 {
        // 来源总量为 0 时比例档为 0 —— 但那时没有候选可删，不影响。
        let ratioCap = Int64(Double(sourceTotalBytes) * (tier == .firstRun ? 0.10 : 0.20))
        switch tier {
        case .firstRun:
            return Swift.min(userCapBytes, Swift.min(absoluteCapBytes, ratioCap))
        case .steady:
            return Swift.min(userCapBytes, ratioCap)
        }
    }

    /// 某候选的**逻辑字节**（AC-15 / CR-022 偏差 2 的唯一定义）。
    ///
    /// - 普通文件 = `st_size`
    /// - 目录 = 子树内全部普通文件 `st_size` 之和（**目录自身的 `st_size` 不计入**）
    /// - 符号链接 = 按自身 `st_size` 计（不跟随）
    ///
    /// ## 为什么预检与记账必须共用这一个函数
    ///
    /// 原来预检用的是 `attributesOfItem[.size]`（**目录自身的 ~96 B**），
    /// 而记账用的是递归逻辑字节。**两个口径不一致**，后果不是「算得不准」，
    /// 而是**上限根本不成立**：
    ///
    /// 实测（2026-11-09）：两个各含 100 KB 的目录候选，上限 150 KB
    /// → 预检每次都看到 96 B → 两个都「不超限」→ **实际删除 200 KB，超上限 33%**。
    ///
    /// 而 `moveToTrash` 记的是 100 KB，所以 `deletedBytes` 一路累加到 200 KB。
    ///
    /// **这正是 AC-15 明文禁止的那种路径**：「预检通过 → 删除发生 → 实测超限」。
    /// 契约还额外要求预检值是「随候选缓存到执行点」的值、**不是执行时刻的实时重算**——
    /// 理由同款：实时重算会让「预检通过 → 超限」这条路径不可达，判据失去判别力。
    ///
    /// 所以这里做两件事：
    /// 1. 预检与记账**共用** `logicalBytes(of:)`（同一函数、同一口径）；
    /// 2. `execute` 接受**预检值**（由调用方在扫描时算好并缓存），缺省时现算一次。
    private func logicalBytes(of url: URL) -> (bytes: Int64, unreadable: Int) {
        let attrs = try? fileManager.attributesOfItem(atPath: url.path)
        let isDir = (attrs?[.type] as? FileAttributeType) == .typeDirectory
        guard isDir else {
            // 普通文件 / 符号链接：按自身 `st_size`（符号链接不跟随，`attributesOfItem` 亦不跟随）
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            return (size, 0)
        }
        return recursiveLogicalBytesResult(atPath: url.path)
    }

    /// 批量执行（含单次上限 · AC-15）。
    ///
    /// - 容量上限：`capacityCap` 字节 —— **删除前预估**，确保累计**不超过**上限
    ///   （AC-15：实际删除量不超过上限；不能「先删后判」，否则会超）
    /// - 条目数上限：`countCap`
    /// - 超出部分**顺延**（`skippedByCap` 计数），不报错
    /// - Parameters:
    ///   - preflightBytes: **预检值**（AC-15：随候选缓存到执行点的逻辑字节）。
    ///     传 `nil` 则在执行前现算一次（仍与记账同口径）。
    public func execute(
        candidates: [CandidateID],
        source: Source,
        capacityCap: Int64,
        countCap: Int,
        preflightBytes: [CandidateID: Int64]? = nil,
        now: Date = Date()
    ) -> ExecutionOutcome {
        var outcome = ExecutionOutcome()
        for id in candidates {
            if outcome.records.count >= countCap {
                outcome.skippedByCap += 1
                continue
            }
            // ---- 预检字节（与记账**同一口径**，见 `logicalBytes(of:)` 的说明）----
            let size: Int64
            if let preflightBytes, let cached = preflightBytes[id] {
                size = cached
            } else {
                size = logicalBytes(of: URL(fileURLWithPath: id.path)).bytes
            }
            // 累计 + 本条 > 上限 → 顺延（**预检**在删除发生之前）
            if outcome.deletedBytes + size > capacityCap {
                outcome.skippedByCap += 1
                continue
            }
            do {
                let rec = try moveToTrash(
                    id, source: source, now: now,
                    // **`t1` 传预检时算出的那一份**（IF-08：不是执行时刻实时值）
                    previewBytes: size
                )

                // ---- `t2` 实测超限 → **立即移回原位**（IF-07「超出则撤销」）----
                //
                // 契约原文：
                //   「若某条实测 `Σ bytes > capacityCap` → **立即把该条从废纸篓移回原位**、
                //   记 `blocked_cap`、**本轮停止后续删除**（宁可少删；AC-15 是硬上限，不是目标值）。」
                //
                // ## 为什么需要这一步（预检为什么不够）
                //
                // 预检用的是 `t1`（首检时刻）的值，而目录内容在
                // 「扫描 → 执行」之间可能变化 —— 别的进程正在往里写、
                // 或用户自己放了东西进去。**预检通过不等于实际没超。**
                //
                // 所以上限必须是**硬上限**：实测超了就回滚，而不是「记一笔超了就算了」。
                //
                // 而这恰恰是契约要求 `t2` 存在的理由 ——
                // 若用 `t1` 对账，等于拿自己的假设验自己，那条判据永远是绿的。
                let projected = outcome.deletedBytes + rec.bytes
                if projected > capacityCap {
                    // 移回原位（**必须成功**，移不回则记为失败并如实上报）
                    do {
                        try fileManager.moveItem(
                            at: URL(fileURLWithPath: rec.restorePath!),
                            to: URL(fileURLWithPath: rec.originalPath)
                        )
                        outcome.records.append(
                            ExecutionRecord(
                                id: rec.id,
                                source: rec.source,
                                action: .blockedCap,
                                originalPath: rec.originalPath,
                                // **恢复位置作废**（已移回原位，不再在废纸篓里）
                                restorePath: nil,
                                executedAt: now,
                                bytes: rec.bytes,
                                bytesKind: rec.bytesKind,
                                blockedReason: "实测超上限，已移回原位",
                                bytesPreview: rec.bytesPreview,
                                bytesMeasuredAt: rec.bytesMeasuredAt
                            )
                        )
                    } catch {
                        // **移回失败** = 条目留在废纸篓里但原位没有 → 状态不一致。
                        // 如实记为失败（不假装成功），让用户知道有东西需要手动处理。
                        outcome.failures.append((id, "实测超上限且移回原位失败：\(error.localizedDescription)"))
                    }
                    // **本轮停止后续删除**（IF-07：宁可少删）
                    outcome.skippedByCap += 1
                    break
                }

                outcome.records.append(rec)
                outcome.deletedBytes += rec.bytes
            } catch {
                outcome.failures.append((id, error.localizedDescription))
            }
        }
        return outcome
    }
}
