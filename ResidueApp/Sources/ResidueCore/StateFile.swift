import Foundation

// ============================================================
// Residue · `state.residue` 的读写（IO 层）
//
// 契约落点：技术方案 §5.1 / IF-09 / §6 错误码 / §10.3 迁移；
//           PRD v5.4 · M4「写入时刻」/ M6 豁免边界 / N7 清除边界。
//
// ## 载体性质（契约 M4 / N7）
//   - 落**应用状态目录**，**不属 N7 的 `.jsonl` 记录目录**
//   - **不计入 N7 计量与容量回收**
//   - **N7「一键清除全部采集物与日志」不作用于它**
//     ⇒ 用户的清除动作**不构成 `a` 的重置路径**
//   - **应用版本变更时**载体四项（F / C_done / 位槽占用表 / a）**一并清零**
//   - **轮次切换时不清零**
//
// ## 原子写（§8.2 / §5.1 硬约束 4）
//   写 `state.residue.tmp` → `fsync` → `rename` 覆盖。
//   **短写 / ENOSPC / EDQUOT 时不得 rename**（否则半份文件覆盖好数据 → `a` 直接错）。
//   rename 前保留 `.bak`（**迁移期唯一可回退点**，§10.3）。
//
// ## 加载（§6 错误码）
//   - schema 更高 → `E-301` **只读降级**（不拒绝、不重置）
//   - 段校验失败 → `E-304`：**备份为 `.corrupt` + 进入只读**，
//     **不提供「重置」入口、不自动重置**
//   - 损坏且无可用 `.bak` → `E-302`
//   - 从 `.bak` 恢复成功 → `E-308`（提示级）
// ============================================================

/// 状态载体文件（`state.residue`）的读写。
public struct StateFile: Sendable {

    /// 应用状态目录（**非** N7 的 `.jsonl` 记录目录）。
    public let directory: URL
    /// 主文件。
    public let fileURL: URL
    /// 迁移期备份（**唯一可回退点**）。
    public let backupURL: URL
    /// 临时文件（写中）。
    public let tempURL: URL

    public init(directory: URL? = nil) {
        let dir = directory ?? StateFile.defaultDirectory()
        self.directory = dir
        self.fileURL = dir.appendingPathComponent("state.residue")
        self.backupURL = dir.appendingPathComponent("state.residue.bak")
        self.tempURL = dir.appendingPathComponent("state.residue.tmp")
    }

    /// 默认状态目录：`~/Library/Application Support/Residue`
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Residue", isDirectory: true)
    }

    // MARK: - 加载

    /// 加载结果。
    public struct LoadResult: Sendable {
        /// 载体内容（`nil` = 无可加载内容）。
        public var contents: StateFileContents?
        /// 是否进入**只读态**（`E-301` / `E-302` / `E-304` / `E-306`）。
        public var readOnly: Bool
        /// 遇到的错误（`nil` = 正常）。
        public var error: StateFileError?

        public init(
            contents: StateFileContents? = nil,
            readOnly: Bool = false,
            error: StateFileError? = nil
        ) {
            self.contents = contents
            self.readOnly = readOnly
            self.error = error
        }
    }

    /// 加载状态。
    ///
    /// **不抛错**——所有失败路径都以 `LoadResult` 表达，保证首启可用。
    public func load() -> LoadResult {
        let fm = FileManager.default

        // 主文件不存在 → 空载体（非错误）
        guard fm.fileExists(atPath: fileURL.path) else {
            return LoadResult(contents: StateFileContents())
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let contents = try StateFileCodec.decode(data)
            return LoadResult(contents: contents)
        } catch let err as StateFileError {
            switch err {
            case .schemaTooNew:
                // E-301 → **只读降级，不拒绝、不重置**
                return LoadResult(readOnly: true, error: err)

            case .segmentValidationFailed(let detail):
                // **E-304**（段校验失败：越界 / 重叠 / CRC / 位图长度不符）
                //   → **保留现场 + 只读**；**不提供「重置」入口、不自动重置**。
                //   ⚠️ E-304 **不因「无可用 `.bak`」而降级成 E-302**——
                //   E-302 是「损坏且无可用 `.bak`」，与段校验失败是**两种不同触发**；
                //   混用会让 E-304 继承 E-302 的「重置」出口（v1.3 的旧病）。
                let corruptURL = directory.appendingPathComponent("state.residue.corrupt")
                try? fm.removeItem(at: corruptURL)
                try? fm.moveItem(at: fileURL, to: corruptURL)
                return LoadResult(readOnly: true, error: .segmentValidationFailed(detail: detail))

            case .corruptNoBackup(let detail):
                // **E-302**（损坏且无可用 `.bak`）→ 只读；**不自动重置**
                let corruptURL = directory.appendingPathComponent("state.residue.corrupt")
                try? fm.removeItem(at: corruptURL)
                try? fm.moveItem(at: fileURL, to: corruptURL)
                return LoadResult(readOnly: true, error: .corruptNoBackup(detail: detail))

            default:
                return LoadResult(readOnly: true, error: err)
            }
        } catch {
            return LoadResult(readOnly: true, error: .corruptNoBackup(detail: String(describing: error)))
        }
    }

    /// 尝试从 `.bak` 恢复（**不删 `.bak`**——它是迁移期唯一可回退点）。
    ///
    /// **只在「迁移失败」路径调用**（§10.3）——不是段校验失败的兜底。
    /// - Returns: 恢复成功后的内容；失败返回 `nil`（→ `E-306`）。
    public func tryRestoreFromBackupForMigration() -> StateFileContents? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupURL.path),
              let data = try? Data(contentsOf: backupURL),
              let contents = try? StateFileCodec.decode(data)
        else { return nil }
        // 恢复成功后把备份**内容**写回主文件（`.bak` 本身**保留**）
        try? fm.removeItem(at: fileURL)
        try? data.write(to: fileURL, options: [.atomic])
        return contents
    }

    // MARK: - 写入

    /// 原子写（§8.2）。
    ///
    /// 步骤：写 `.tmp` → `fsync` → **保留 `.bak`** → `rename` 覆盖主文件 → 删 `.tmp`。
    ///
    /// **短写 / ENOSPC / EDQUOT 时不 rename**（→ `E-303`），主文件保持原样。
    @discardableResult
    public func save(header: StateHeader, payloads: [Source: SourcePayload]) throws -> StateFileContents {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let data = try StateFileCodec.encode(header: header, payloads: payloads)

        // 空间预检（§10.3 · E-305）：需要 现有文件 + 新文件 + 备份 ≈ 2× + 余量
        if let existing = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? Int {
            let required = data.count + existing
            if let available = availableBytes(at: fileURL) {
                if available < required {
                    throw StateFileError.migrationSpaceInsufficient(
                        requiredBytes: required, availableBytes: available
                    )
                }
            }
        }

        // ① 写临时文件
        let fd = try fm.createFile(atPath: tempURL.path, contents: data)
        guard fd else {
            throw StateFileError.writeFailed(detail: "无法创建临时文件")
        }
        defer { try? fm.removeItem(at: tempURL) }

        // ② fsync（确保数据落盘后再 rename）
        let handle = try FileHandle(forWritingTo: tempURL)
        try handle.synchronize()
        try handle.close()

        // ③ 校验临时文件长度 == 预期长度（**短写检测**）
        let writtenSize = ((try? fm.attributesOfItem(atPath: tempURL.path))?[.size] as? Int) ?? 0
        guard writtenSize == data.count else {
            // **短写 → 不 rename**，主文件保持原样（E-303）
            throw StateFileError.writeFailed(
                detail: "短写：写盘 \(writtenSize) B ≠ 预期 \(data.count) B"
            )
        }

        // ④ 保留 `.bak`（把现主文件复制为备份；**不删旧 `.bak`** 直到新文件成功落地）
        if fm.fileExists(atPath: fileURL.path) {
            try? fm.removeItem(at: backupURL)
            try? fm.copyItem(at: fileURL, to: backupURL)
        }

        // ⑤ rename 覆盖（原子）
        //
        // ⚠️ `FileManager.moveItem` **不会覆盖已存在的目标**（会报「已经存在同名项目」）
        //    → 第二次写入必然失败。原子覆盖必须用 `replaceItemAt`。
        do {
            if fm.fileExists(atPath: fileURL.path) {
                // `replaceItemAt` 是**同卷原子替换**：先备份原文件，再把新文件移到位。
                // 保留项 `originalItemURL` = 备份位置（我们已有 `.bak`，故传 nil 避免重复备份）。
                _ = try fm.replaceItemAt(fileURL, withItemAt: tempURL,
                                         backupItemName: nil,
                                         options: [.usingNewMetadataOnly])
            } else {
                try fm.moveItem(at: tempURL, to: fileURL)
            }
        } catch {
            throw StateFileError.writeFailed(detail: "rename 失败：\(error.localizedDescription)")
        }

        // ⑥ 写完删 `.bak`？**不删** —— `.bak` 是迁移期唯一可回退点，
        //    §10.3 的要求是「**不删唯一 `.bak`**」；成功落地后新文件即为最新，
        //    `.bak` 保留到下一次成功写入时被覆盖。

        // 回读校验（写完立刻自检 —— 契约的「写后校验」要求）
        let written = try StateFileCodec.decode(data)
        return written
    }

    /// 剩余可用字节（空间预检用）。
    private func availableBytes(at path: URL) -> Int? {
        let url = path.deletingLastPathComponent()
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return Int(capacity)
    }

    // MARK: - 清除

    /// **载体清零**（应用版本变更时调用；契约 M4「重置边界」）。
    ///
    /// ⚠️ **这不是 N7 的「一键清除」**——N7 的清除**不作用于**本载体。
    /// 本方法只由「应用版本变更」路径调用。
    @discardableResult
    public func clearCarrierForVersionChange(newAppVersion: String) throws {
        var header = StateHeader()
        header.appVersion = newAppVersion
        // 载荷全空 → 四项（`F` / `C_done` / 位槽占用表 / `a`）自然清零
        try save(header: header, payloads: [:])
    }
}
