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
    /// 迁移进度游标（`<stateDir>/state/migrating.json`）。
    ///
    /// R2 v1.9 §10.3 —— `step` 只在特定时刻被**原子写入 + `fsync`**，
    /// 它本身就是断电/崩溃后的恢复判据（**不按 CRC 二分**）。
    public let migrationProgressURL: URL
    /// 可用字节查询的**注入点**（`nil` = 用卷的真实剩余容量）。
    ///
    /// 空间预检必须能被测：没有注入点，`E-305` 那条分支就只能靠
    /// 「把磁盘塞满」来触发（不可自动化）。
    internal let availableBytesProvider: (@Sendable (URL) -> Int?)?

    public init(
        directory: URL? = nil,
        availableBytesProvider: (@Sendable (URL) -> Int?)? = nil
    ) {
        let dir = directory ?? StateFile.defaultDirectory()
        self.directory = dir
        self.fileURL = dir.appendingPathComponent("state.residue")
        self.backupURL = dir.appendingPathComponent("state.residue.bak")
        self.tempURL = dir.appendingPathComponent("state.residue.tmp")
        self.migrationProgressURL = dir
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("migrating.json")
        self.availableBytesProvider = availableBytesProvider
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
    ///
    /// ## 恢复前置（R2 v1.9 §10.3）
    ///
    /// 磁盘上留有 `state/migrating.json` ⇒ **迁移被中断过** ⇒ 必须**先按 `step`
    /// 判定恢复**，再谈加载目标。否则会拿半迁移状态当正常态。
    public func load() -> LoadResult {
        if let recovered = recoverFromInterruptedMigrationIfNeeded() {
            return recovered
        }
        return loadTarget()
    }

    /// 正常加载路径（**不含**崩溃恢复前置）。
    private func loadTarget() -> LoadResult {
        let fm = FileManager.default

        // 主文件不存在 → 空载体（非错误）**除非**有 `.corrupt` 留档
        //
        // ⚠️ 「主文件不存在」有**两种**含义，靠 `.corrupt` 区分：
        //   · 无 `.corrupt` → 真的首启 / 用户已显式清理 → 空载体
        //   · 有 `.corrupt` → **损坏待处理**（上次 `load()` 已把现场移走）。
        //     若当成首启，`AppModel` 会走「首启写默认 header」→ 磁盘上重新
        //     出现一个空载体，`a` 被静默清零，`.corrupt` 之外再无痕迹。
        //     那正是「静默重建」（不变量④）。恢复出口是用户显式动作。
        guard fm.fileExists(atPath: fileURL.path) else {
            let corruptURL = directory.appendingPathComponent("state.residue.corrupt")
            if fm.fileExists(atPath: corruptURL.path) {
                return LoadResult(
                    readOnly: true,
                    error: .corruptNoBackup(detail: "主文件缺失，存在 .corrupt 留档（损坏待处理）")
                )
            }
            return LoadResult(contents: StateFileContents())
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let contents = try StateFileCodec.decode(data)
            // schema 低一档 → **就地升级**（R2 v1.9 §10.3；codec 层不做迁移）
            if contents.header.schemaVersion < StateFileCodec.currentSchemaVersion {
                return migrateCarrierInPlace(contents)
            }
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
            // **兜底分支也必须保留现场**。
            //
            // 解码可能抛出**非 `StateFileError`** 的错误（例如文件短到读不出魔数时
            // 底层抛出的范围/解码错误）。原先这里直接返回只读、**不移动文件** →
            // 磁盘上留着一个读不出来的 `state.residue`，而它既不是有效载体、
            // 也没有被留档；下一次启动会再次走进同一分支，永远无法恢复。
            //
            // 与 E-302 / E-304 同一处置：移成 `.corrupt`（保留现场）→ 只读。
            let corruptURL = directory.appendingPathComponent("state.residue.corrupt")
            try? fm.removeItem(at: corruptURL)
            try? fm.moveItem(at: fileURL, to: corruptURL)
            return LoadResult(readOnly: true, error: .corruptNoBackup(detail: String(describing: error)))
        }
    }

    /// 尝试从 `.bak` 恢复（**不删 `.bak`**——它是迁移期唯一可回退点）。
    ///
    /// **只在「迁移失败」路径调用**（§10.3）——不是段校验失败的兜底。
    /// - Returns: 恢复成功后的内容；失败返回 `nil`（→ `E-306`）。
    public func tryRestoreFromBackupForMigration() -> StateFileContents? {
        // 三态判定在 `restoreFromBackup()` 里（区分「无可用 `.bak`」与「写回失败」）；
        // 对外仍只暴露「成功 / 失败」两态。
        if case .restored(let contents) = restoreFromBackup() { return contents }
        return nil
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

        // ① 写临时文件（fsync + 短写检测）
        defer { try? fm.removeItem(at: tempURL) }
        try writeTempFile(data)

        // ② 保留 `.bak`（把现主文件复制为备份；**不删旧 `.bak`** 直到新文件成功落地）
        if fm.fileExists(atPath: fileURL.path) {
            try? fm.removeItem(at: backupURL)
            try? fm.copyItem(at: fileURL, to: backupURL)
        }

        // ③ rename 覆盖（原子）
        try replaceWithTempFile()

        // ⑥ 写完删 `.bak`？**不删** —— `.bak` 是迁移期唯一可回退点，
        //    §10.3 的要求是「**不删唯一 `.bak`**」；成功落地后新文件即为最新，
        //    `.bak` 保留到下一次成功写入时被覆盖。

        // 回读校验（写完立刻自检 —— 契约的「写后校验」要求）
        let written = try StateFileCodec.decode(data)
        return written
    }

    /// 剩余可用字节（空间预检用）。
    ///
    /// 注入点优先（`availableBytesProvider`）—— 空间预检必须能被自动化测试。
    internal func availableBytes(at path: URL) -> Int? {
        if let availableBytesProvider { return availableBytesProvider(path) }
        let url = path.deletingLastPathComponent()
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return Int(capacity)
    }

    // MARK: - 原子写原语（§8.2）

    /// 写临时文件：`fsync` + **短写检测**（§8.2）。
    ///
    /// **不删 `.tmp`** —— 调用方要么把它 rename 到位，要么在失败时清理。
    /// （`save()` 与迁移流程共用本原语 —— 不变量②。）
    internal func writeTempFile(_ data: Data) throws {
        let fm = FileManager.default
        let fd = fm.createFile(atPath: tempURL.path, contents: data)
        guard fd else {
            throw StateFileError.writeFailed(detail: "无法创建临时文件")
        }

        // fsync（确保数据落盘后再 rename）
        let handle = try FileHandle(forWritingTo: tempURL)
        try handle.synchronize()
        try handle.close()

        // 校验临时文件长度 == 预期长度（**短写检测**）
        let writtenSize = ((try? fm.attributesOfItem(atPath: tempURL.path))?[.size] as? Int) ?? 0
        guard writtenSize == data.count else {
            // **短写 → 不 rename**，主文件保持原样（E-303）
            throw StateFileError.writeFailed(
                detail: "短写：写盘 \(writtenSize) B ≠ 预期 \(data.count) B"
            )
        }
    }

    /// 用 `.tmp` **原子替换**主文件（同卷 `replaceItemAt`）。
    ///
    /// ⚠️ `FileManager.moveItem` **不会覆盖已存在的目标** → 原子覆盖必须用
    ///    `replaceItemAt`（同卷原子替换：先备份原文件，再把新文件移到位）。
    internal func replaceWithTempFile() throws {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: fileURL.path) {
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
    }

    // MARK: - 清除

    /// **载体清零**（应用版本变更时调用；契约 M4「重置边界」）。
    ///
    /// ⚠️ **这不是 N7 的「一键清除」**——N7 的清除**不作用于**本载体。
    /// 本方法只由「应用版本变更」路径调用。
    ///
    /// ## 为什么必须**基于现有载体**改字段，而不是造全新 `StateHeader()`
    ///
    /// 造全新 header 会把**用户设置类字段**一并重置 ⇒ 用户升级应用 =
    /// **被替用户改主意**（自动删除总开关被静默关掉）。PRD v5.6 M1「写入时刻」⑧：
    /// **用户设置类字段不随版本变更清零**。
    ///
    /// 同时，造全新 header 还会把 `sources` 抹成空 ⇒ 界面上的每来源读数全部消失。
    ///
    /// - Parameters:
    ///   - newAppVersion: 新的应用版本号。
    ///   - preservedRound: **要保留的轮次**（`nil` = 沿用载体里的轮次）。
    ///
    ///   M4 写的是「应用版本变更时 `F` / `C_done` / 位槽占用表 / `a` 一并清零」，
    ///   而 **M1 写的是「版本变更重置当前轮次，不产生新轮次」**。
    ///   两处合起来的含义：**轮次号要留住**，只清这一轮的凭证。
    ///
    ///   原实现无条件造 `StateHeader()`（round 默认 1）→ 一个已经跑到第 3 轮的用户
    ///   升级后会被打回第 1 轮。那不是「重置」，是**倒退**。
    public func clearCarrierForVersionChange(
        newAppVersion: String,
        preservedRound: Int? = nil
    ) throws {
        // **基于现有载体改字段** —— 不造全新 `StateHeader()`。
        //
        // 载体读不出来（损坏 / 只读）时**抛错**，不静默新建空载体：
        // 那会把 `a` 清零（= 放行），是「静默重建」（不变量④）。
        let loaded = load()
        if let error = loaded.error { throw error }

        var header = loaded.contents?.header ?? StateHeader()
        // 写出的永远是**当前** schema 版本（载体可能是旧 schema）。
        header.schemaVersion = StateFileCodec.currentSchemaVersion
        header.appVersion = newAppVersion
        // **轮次不变**（M1：版本变更重置当前轮次，不产生新轮次）
        header.round = preservedRound ?? header.round

        // ① 本轮计数日归零 + 本轮计数日起算点重置
        //    （起算点重置 = 版本变更后的**下一次**成功扫描完成所在日 ⇒ 此刻无起算点）
        // ③ 结算凭证（报告产出时刻与报告标识）随 `K` / `J` 一并清零
        //    （凭证与结算值不同源 → 会造出「有报告、无样本」的假态）
        // ② `T` 待重取 / ③ `K`·`J` 清零 / ④ `b` 清零 / ⑥ `a` 清零 /
        // ⑦ `H` 回到 nil / 取快照·结算时刻与无法归因条数随量一并清零
        //
        // ⚠️ 走**共享原语**（不变量②）：schema 迁移要清的是同一套量，
        //    两处各写一遍必然漂移。
        header.resetObservationCredentials()

        // 载荷全空 → 四项（`F` / `C_done` / 位槽占用表 / `a`）自然清零
        try save(header: header, payloads: [:])
    }
}
