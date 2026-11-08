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
        blockedReason: String? = nil
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
    public func moveToTrash(
        _ id: CandidateID,
        source: Source,
        now: Date = Date()
    ) throws -> ExecutionRecord {
        let src = URL(fileURLWithPath: id.path)
        let attrs = try fileManager.attributesOfItem(atPath: id.path)
        let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
        // **目录用递归逻辑字节**（IF-07）：目录的 `st_size` 只有 ~96 B，
        // 拿它当字节数会让 AC-15 的容量上限判定恒真。
        let (bytes, bytesKind): (Int64, ExecutionRecord.BytesKind) = isDir
            ? (try recursiveLogicalBytes(atPath: id.path), .dirRecursive)
            : ((attrs[.size] as? NSNumber)?.int64Value ?? 0, .file)

        let base = src.lastPathComponent
        let suffix = UUID().uuidString.prefix(8)
        let stamp = Int(now.timeIntervalSince1970)
        let destName = "\(base).\(stamp).\(suffix)"
        let dest = trashDirectory.appendingPathComponent(destName)

        try fileManager.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        // 原子 move（同一卷上等价 rename）
        try fileManager.moveItem(at: src, to: dest)

        return ExecutionRecord(
            id: id,
            source: source,
            action: .renameToTrash,
            originalPath: id.path,
            restorePath: dest.path,
            executedAt: now,
            bytes: bytes,
            bytesKind: bytesKind
        )
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

    /// 批量执行（含单次上限 · AC-15）。
    ///
    /// - 容量上限：`capacityCap` 字节 —— **删除前预估**，确保累计**不超过**上限
    ///   （AC-15：实际删除量不超过上限；不能「先删后判」，否则会超）
    /// - 条目数上限：`countCap`
    /// - 超出部分**顺延**（`skippedByCap` 计数），不报错
    public func execute(
        candidates: [CandidateID],
        source: Source,
        capacityCap: Int64,
        countCap: Int,
        now: Date = Date()
    ) -> ExecutionOutcome {
        var outcome = ExecutionOutcome()
        for id in candidates {
            if outcome.records.count >= countCap {
                outcome.skippedByCap += 1
                continue
            }
            // 删除前预估字节数：累计 + 本条 > 上限则顺延
            let size = (try? fileManager.attributesOfItem(atPath: id.path))
                .flatMap { ($0[.size] as? NSNumber)?.int64Value } ?? 0
            if outcome.deletedBytes + size > capacityCap {
                outcome.skippedByCap += 1
                continue
            }
            do {
                let rec = try moveToTrash(id, source: source, now: now)
                outcome.records.append(rec)
                outcome.deletedBytes += rec.bytes
            } catch {
                outcome.failures.append((id, error.localizedDescription))
            }
        }
        return outcome
    }
}
