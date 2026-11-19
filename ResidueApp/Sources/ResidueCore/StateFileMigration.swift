import Foundation

// ============================================================
// Residue · schema 迁移的执行与回退（R2 v1.9 §10.3）
//
// ## 为什么迁移不复用 `save()`
//
// `save()` 的顺序是「写 `.tmp` → 复制 `.bak` → rename」，
// 而 §10.3「低」行要求的是「写 `.bak` → 写新件 → rename」：
// **备份必须先于新件落盘** —— 否则新件写失败时磁盘上没有任何回退点，
// `E-308` 那条分支永远走不到（用户只剩一个半新半旧的载体）。
//
// ## 峰值与空间预检
//
// 峰值 = 原件 + `.bak` + 新件 ⇒ 需 `3 × 状态文件 + 64 MB`。
// v1.1 的「2× + 20%」**少算了新件** ⇒ 迁移末段必 `ENOSPC`。
//
// ## 失败处置（三分支 · §10.3「低」行 ⑥）
//
// | 现场 | 处置 | 错误码 | 只读 |
// |---|---|---|---|
// | `.bak` 可用且写回成功 | 从 `.bak` 原子恢复 | `E-308`（提示级） | 否 |
// | 无可用 `.bak` | 旧件原样保留 | `E-302` | 是 |
// | 恢复过程本身失败 | 无可加载内容 | `E-306` | 是 |
//
// ⚠️ **迁移失败时不得把主文件移成 `.corrupt`** —— 原子替换失败 ⇒ 目标未动 ⇒ 它没坏。
//    把完好的旧数据当损坏丢掉 = 数据损失。
// ============================================================

/// 迁移的空间预检口径（R2 v1.9 §10.3「低」行 ①）。
public enum MigrationSpacePolicy {

    /// 余量（64 MB）。
    public static let headroomBytes = 64 * 1024 * 1024

    /// 迁移所需字节数 = `3 × 状态文件 + 64 MB`。
    ///
    /// 三份 = 原件 + `.bak` + 新件（峰值同时在盘）。
    ///
    /// - Parameter carrierBytes: 现有 `state.residue` 的字节数（0 = 尚无载体）。
    public static func requiredBytes(carrierBytes: Int) -> Int {
        carrierBytes * 3 + headroomBytes
    }
}

/// 迁移进度游标（`<stateDir>/state/migrating.json`）。
///
/// R2 v1.9 §10.3 —— `step` 只在特定时刻被**原子写入 + `fsync`**，
/// 它本身就是断电/崩溃后的恢复判据（**不按 CRC 二分**）。
///
/// | step | 含义 |
/// |---|---|
/// | 1 | 已通过空间预检（无副作用） |
/// | 2 | 已写 `.bak` 并 `fsync` |
/// | 3 | 已写完新件临时文件（**未 rename**，目标仍是旧件） |
/// | 4 | **即将 `rename`**（新件已写完且已校验可加载） |
/// | 5 | `rename` 已完成（目标已是新件、`.bak` 仍在） |
public struct MigrationProgress: Codable, Sendable, Equatable {

    /// 已完成到哪一步（1…5）。
    public var step: Int
    /// 迁移前的 schema 版本。
    public var fromSchema: Int
    /// 迁移后的 schema 版本。
    public var toSchema: Int
    /// `.bak` 的路径（回退点）。
    public var bakPath: String
    /// 迁移开始时刻（全程不变）。
    public var startedAt: Date

    public init(
        step: Int,
        fromSchema: Int,
        toSchema: Int,
        bakPath: String,
        startedAt: Date
    ) {
        self.step = step
        self.fromSchema = fromSchema
        self.toSchema = toSchema
        self.bakPath = bakPath
        self.startedAt = startedAt
    }

    /// 原子写入 + `fsync`（`step` 落盘后才允许做该步之后的事）。
    ///
    /// - Parameters:
    ///   - progress: 进度游标。
    ///   - url: 目标文件（`<stateDir>/state/migrating.json`）。
    public static func write(_ progress: MigrationProgress, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(progress)
        try data.write(to: url, options: [.atomic])

        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
    }

    /// 读回（不存在或读不出 → `nil`）。
    ///
    /// ⚠️ 解码策略必须与编码**成对**（`.iso8601`）——
    ///    不对称 ⇒ `write` 成功、`read` 永远失败 ⇒ 恢复判据永久失效（CLAUDE.md §七第 6 条）。
    public static func read(from url: URL) -> MigrationProgress? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MigrationProgress.self, from: data)
    }
}

extension StateFile {

    // MARK: - 迁移执行

    /// 把旧 schema 载体**就地升级**到当前 schema（R2 v1.9 §10.3「低一档」行）。
    ///
    /// ## 为什么是「就地升级」而不是「丢弃重建」
    ///
    /// 载体里装着 `a`（L0 误判累计）与观察期凭证。**丢弃载体 = 把「判错过 N 次」
    /// 抹成「一次都没错」** ⇒ 直接放行自动删除（不变量④）。
    /// 丢弃与静默重建是同一件事。
    ///
    /// ## 语义（§10.3 低一档行）
    ///
    /// | # | 契约 | 实现落点 |
    /// |---|---|---|
    /// | ① | 段表由每来源三段扩到四段 → 旧载体无 `0x04` ⇒ **快照成员集合为空** | 载荷全空 |
    /// | ② | **观察期从头开始** | `resetObservationCredentials()` |
    /// | ③ | **用户设置类字段原样保留**（**不得造全新 `StateHeader()`**） | 基于现有 header 改字段 |
    /// | ④ | 升级后首次成功扫描重新取快照 | 置「待重取」，由扫描路径取新快照 |
    /// | ⑤ | 空间预检同「低」行 | `MigrationSpacePolicy` |
    ///
    /// - Parameter contents: 已解码的旧载体。
    /// - Returns: 升级后的载体；失败时按 §10.3「低」行 ⑥ 三分支处置。
    func migrateCarrierInPlace(_ contents: StateFileContents) -> LoadResult {
        let fm = FileManager.default
        let fromSchema = contents.header.schemaVersion
        let toSchema = StateFileCodec.currentSchemaVersion

        // ① 空间预检（§10.3「低」行 ①）
        //
        //    峰值 = 原件 + `.bak` + 新件 ⇒ `3 × 状态文件 + 64 MB`。
        //
        //    ⚠️ 预检**必须发生在写 `migrating.json` 之前** —— step 1 的前提
        //       就是「空间预检已过」；预检没过 ⇒ 磁盘上不该出现任何迁移痕迹。
        let carrierBytes = ((try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? Int) ?? 0
        let requiredBytes = MigrationSpacePolicy.requiredBytes(carrierBytes: carrierBytes)
        if let available = availableBytes(at: fileURL), available < requiredBytes {
            // E-305 **可恢复**（用户腾空间后重试）⇒ **不进只读**，
            // 旧载体照常可读（不把用户挡在门外）。
            return LoadResult(
                contents: contents,
                readOnly: false,
                error: .migrationSpaceInsufficient(
                    requiredBytes: requiredBytes,
                    availableBytes: available
                )
            )
        }

        // ② 升级后的载体内容
        //
        // **基于现有载体改字段** —— 不造全新 `StateHeader()`（否则用户设置被抹）。
        var header = contents.header
        header.schemaVersion = toSchema
        // 观察期从头开始（`appVersion` / `round` / `autoDeleteEnabled` /
        // `countedDaysCap` **不动** —— 用户设置类字段原样保留）
        header.resetObservationCredentials()

        // 每来源四段全空（`F` / `C_done` / 位槽占用表 / 快照成员集合）。
        //
        // ⚠️ 必须给**全部** `Source.allCases` 造载荷：编码器对缺载荷的来源
        //    直接 `continue`（不写它的段）⇒ 解码后该来源的载荷整个缺失。
        let payloads = Dictionary(
            uniqueKeysWithValues: Source.allCases.map { ($0, SourcePayload()) }
        )

        let newData: Data
        do {
            newData = try StateFileCodec.encode(header: header, payloads: payloads)
        } catch {
            return migrationFailed(contents, backupWritten: false,
                                   detail: "编码失败：\(String(describing: error))")
        }

        // ③ 写 `migrating.json`（step 1 = 已通过空间预检，无副作用）
        var progress = MigrationProgress(
            step: 1,
            fromSchema: fromSchema,
            toSchema: toSchema,
            bakPath: backupURL.path,
            startedAt: Date()
        )
        do {
            try MigrationProgress.write(progress, to: migrationProgressURL)
        } catch {
            return migrationFailed(contents, backupWritten: false,
                                   detail: "写 `migrating.json` 失败：\(String(describing: error))")
        }

        // ④ 写 `.bak`（**先于新件** —— 否则新件写失败时磁盘上没有任何回退点）
        let oldData: Data
        do {
            oldData = try Data(contentsOf: fileURL)
        } catch {
            return migrationFailed(contents, backupWritten: false,
                                   detail: "读取旧载体失败：\(String(describing: error))")
        }
        do {
            try oldData.write(to: backupURL, options: [.atomic])
            let handle = try FileHandle(forWritingTo: backupURL)
            try handle.synchronize()
            try handle.close()
        } catch {
            return migrationFailed(contents, backupWritten: false,
                                   detail: "写 `.bak` 失败：\(String(describing: error))")
        }

        // step 2 = 已写 `.bak` 并 `fsync`（**从此刻起才有回退点**）
        progress.step = 2
        do {
            try MigrationProgress.write(progress, to: migrationProgressURL)
        } catch {
            return migrationFailed(contents, backupWritten: true,
                                   detail: "更新 `migrating.json` 失败：\(String(describing: error))")
        }

        // ⑤ 写新件到 `.tmp`（`fsync` + 短写检测），并**回读校验可加载**
        do {
            try writeTempFile(newData)
            let written = try Data(contentsOf: tempURL)
            guard (try? StateFileCodec.decode(written)) != nil else {
                throw StateFileError.writeFailed(detail: "新件回读校验失败（不可加载）")
            }
        } catch {
            return migrationFailed(contents, backupWritten: true,
                                   detail: "写新件失败：\(String(describing: error))")
        }

        // step 3 = 已写完新件临时文件（**未 rename**，目标仍是旧件）
        progress.step = 3
        do {
            try MigrationProgress.write(progress, to: migrationProgressURL)
        } catch {
            return migrationFailed(contents, backupWritten: true,
                                   detail: "更新 `migrating.json` 失败：\(String(describing: error))")
        }

        // step 4 = **即将 `rename`**（新件已写完且已校验可加载；rename 前写入）
        //
        // ⚠️ step 4 必须写在 rename **之前**：写在之后会出现
        //    「rename 已成功但 step 仍是 3」→ 断电恢复时按 step=3 无条件删 `.bak`
        //    → **唯一备份消失**。把风险窗口改成「step=4 已写但 rename 未发生」
        //    （可安全回退），再用「目标.schemaVersion == fromSchema」断言兜住反向情况。
        progress.step = 4
        do {
            try MigrationProgress.write(progress, to: migrationProgressURL)
        } catch {
            return migrationFailed(contents, backupWritten: true,
                                   detail: "更新 `migrating.json` 失败：\(String(describing: error))")
        }

        // rename（原子替换）
        do {
            try replaceWithTempFile()
        } catch {
            return migrationFailed(contents, backupWritten: true,
                                   detail: "rename 失败：\(String(describing: error))")
        }

        // step 5 = `rename` 已完成（目标已是新件、`.bak` 仍在）
        progress.step = 5
        try? MigrationProgress.write(progress, to: migrationProgressURL)

        // ⑤ 迁移成功 → 删 `.bak` 与 `migrating.json`
        //    （N7：迁移成功后 `.bak` 立即删除，正常态下不存在）。
        try? fm.removeItem(at: backupURL)
        try? fm.removeItem(at: migrationProgressURL)

        // 回读新件（写后校验）
        do {
            let written = try StateFileCodec.decode(try Data(contentsOf: fileURL))
            return LoadResult(contents: written)
        } catch {
            return LoadResult(
                readOnly: true,
                error: .writeFailed(detail: "迁移后回读失败：\(String(describing: error))")
            )
        }
    }

    // MARK: - 失败处置

    /// 迁移失败的处置（§10.3「低」行 ⑥ 三分支）。
    ///
    /// - Parameters:
    ///   - contents: 迁移前已解码的旧载体（**主文件没坏**，它还在盘上）。
    ///   - backupWritten: 本次迁移是否**已经**写好 `.bak`（= 有回退点）。
    ///   - detail: 失败原因（进错误详情）。
    private func migrationFailed(
        _ contents: StateFileContents,
        backupWritten: Bool,
        detail: String
    ) -> LoadResult {
        // 清理残留的 `.tmp`（**不动主文件** —— 原子替换失败 ⇒ 目标仍是旧件，没坏）。
        try? FileManager.default.removeItem(at: tempURL)

        guard backupWritten else {
            // 无可用 `.bak` → `E-302`（只读）。
            // ⚠️ 主文件**没坏** ⇒ **不得**把它当损坏移走成 `.corrupt`。
            return LoadResult(
                contents: contents,
                readOnly: true,
                error: .corruptNoBackup(detail: "迁移失败且无可用 `.bak`：\(detail)")
            )
        }

        switch restoreFromBackup() {
        case .restored(let restored):
            // 恢复成功 → `E-308`（**提示级**：数据已回到升级前，观察期进度未受影响）。
            return LoadResult(
                contents: restored,
                readOnly: false,
                error: .restoredFromBackup
            )

        case .backupUnavailable:
            return LoadResult(
                contents: contents,
                readOnly: true,
                error: .corruptNoBackup(detail: "迁移失败且无可用 `.bak`：\(detail)")
            )

        case .writeFailed(let reason):
            // 恢复过程本身失败 → `E-306`（只读，无可加载内容）。
            return LoadResult(
                readOnly: true,
                error: .migrationRestoreFailed(detail: "恢复失败：\(reason)；\(detail)")
            )
        }
    }

    // MARK: - 回退

    /// 从 `.bak` 恢复的结果（**三态** —— 区分「无可用 `.bak`」与「写回失败」）。
    enum RestoreOutcome {
        /// 恢复成功（`.bak` 的内容已写回主文件）。
        case restored(StateFileContents)
        /// 没有可用的 `.bak`（不存在 / 读不出 / 解不开）。
        case backupUnavailable
        /// `.bak` 可读，但**写回主文件失败**。
        case writeFailed(String)
    }

    /// 从 `.bak` 原子恢复（**不删 `.bak`** —— 它仍是唯一可回退点）。
    ///
    /// ⚠️ 写回用 `.atomic`（同卷临时文件 + rename）⇒ **主文件任何时刻都不缺席**。
    ///    「先删主文件再写」的话，一旦写入失败，主文件就**永久消失**了。
    internal func restoreFromBackup() -> RestoreOutcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupURL.path),
              let data = try? Data(contentsOf: backupURL),
              let contents = try? StateFileCodec.decode(data)
        else { return .backupUnavailable }
        do {
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            return .writeFailed(error.localizedDescription)
        }
        return .restored(contents)
    }

    // MARK: - 崩溃恢复（§10.3 · 按 `step` 判定）

    /// 目标文件的探针结果（**四态** —— 「可加载 / 不可加载」两态不够）。
    enum TargetProbe {
        /// 目标文件不存在。
        case missing
        /// 目标可解码。
        case readable(StateFileContents)
        /// 目标的 schema 比程序更新（用户降级了应用）。
        case tooNew(found: Int)
        /// 目标存在但读不出（损坏 / 段校验失败 / 根本读不出来）。
        case unreadable(detail: String)
    }

    /// 崩溃恢复前置（R2 v1.9 §10.3 · 恢复判定表）。
    ///
    /// ## 为什么按 `step` 判，不按 CRC 二分
    ///
    /// 迁移是「写 `.bak` → 写新件 → `rename`」的多步过程，断电可能停在**任何**一步。
    /// `state/migrating.json` 的 `step` 游标是**唯一**能区分「目标没动过」与
    /// 「`rename` 已经发生」的信息 —— CRC 只能说明「文件好不好」，说明不了
    /// 「这个文件是迁移前那个还是迁移后那个」。
    ///
    /// ## 两条禁止（§10.3）
    ///
    /// ① **禁止「见 `.bak` 即删」** —— `.bak` 可能是唯一可用的副本。
    /// ② **禁止「见 `.bak` 即回滚」** —— 已成功的迁移会被退回旧 schema（数据倒退）。
    ///
    /// ## 恢复一律「不重做迁移」
    ///
    /// 恢复分支返回旧载体（迁移下次启动自然重做：盘上仍是旧 schema ⇒ 走正常路径
    /// 即触发就地升级）。这也让 `E-308` 的文案「本次数据升级未完成」保持为真。
    ///
    /// - Returns: 需要恢复时的结果；**没有迁移痕迹**时返回 `nil`（走正常路径）。
    func recoverFromInterruptedMigrationIfNeeded() -> LoadResult? {
        let fm = FileManager.default

        // 没有 `migrating.json` ⇒ 迁移从未开始（或已收口）⇒ 正常路径。
        //
        // ⚠️ 此时**不得**因为「盘上有 `.bak`」就回滚 —— 没有游标就没有
        //    「迁移发生过」的事实，`.bak` 只是上一次成功写入留下的普通备份。
        guard fm.fileExists(atPath: migrationProgressURL.path) else { return nil }

        // 读不出 ⇒ **未知 step**（≠ 不存在）⇒ 迁移确实发生过（只是游标坏了）
        // ⇒ 保守处置：按「`rename` 可能已发生」处理。
        let progress = MigrationProgress.read(from: migrationProgressURL)

        switch probeTarget() {
        case .tooNew(let found):
            // 目标的 schema 比程序新（用户降级了应用）⇒ `E-301` 只读。
            //
            // ⚠️ 不得把它当「损坏」从 `.bak` 恢复 —— 那会用旧数据覆盖用户的新数据
            //    （数据回退，比损坏更严重）。也不得删 `.bak` / `migrating.json`。
            return LoadResult(
                readOnly: true,
                error: .schemaTooNew(found: found, supported: StateFileCodec.currentSchemaVersion)
            )

        case .readable(let contents):
            let schema = contents.header.schemaVersion
            if schema == StateFileCodec.currentSchemaVersion {
                // 迁移实际已完成（`rename` 已发生）⇒ 收口。
                //
                // ⚠️ 这里删 `.bak` 是安全的：目标已确认**存在且可加载**（前置守卫）。
                removeBackupAndProgress()
                return LoadResult(contents: contents)
            }
            if let progress, schema != progress.fromSchema {
                // 既不是 `fromSchema` 也不是当前 schema ⇒ 跨多档的边缘状态 ⇒ 保守恢复。
                return restoreAfterInterruptedMigration(
                    detail: "目标 schema \(schema) 与迁移前后都不一致"
                )
            }
            // `rename` 未发生（目标仍是旧件）⇒ 回退：删 `.tmp` + `.bak` + `migrating.json`，
            // 加载旧件（迁移下次重做）。
            //
            // ⚠️ 目标已确认**存在且可加载** ⇒ 删 `.bak` 不违反「禁止见 `.bak` 即删」。
            removeTempBackupAndProgress()
            return LoadResult(contents: contents)

        case .missing, .unreadable:
            // 目标不可加载 ⇒ 唯一可用副本是 `.bak` ⇒ 从 `.bak` 恢复。
            return restoreAfterInterruptedMigration(detail: "迁移中断后目标文件不可加载")
        }
    }

    /// 探针目标文件的可加载性（**四态**）。
    func probeTarget() -> TargetProbe {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return .missing }
        do {
            let data = try Data(contentsOf: fileURL)
            return .readable(try StateFileCodec.decode(data))
        } catch let err as StateFileError {
            switch err {
            case .schemaTooNew(let found, _):
                return .tooNew(found: found)
            default:
                return .unreadable(detail: String(describing: err))
            }
        } catch {
            return .unreadable(detail: String(describing: error))
        }
    }

    /// 目标不可加载 ⇒ 从 `.bak` 恢复（§10.3「低」行 ⑥ 的三分支）。
    ///
    /// - Parameter detail: 触发恢复的原因（进错误详情）。
    private func restoreAfterInterruptedMigration(detail: String) -> LoadResult {
        switch restoreFromBackup() {
        case .restored(let restored):
            // 恢复成功 ⇒ 迁移收口 ⇒ 删 `migrating.json`。
            //
            // ⚠️ **保留 `.bak`**（禁止「见 `.bak` 即删」：它仍是唯一可回退点）。
            try? FileManager.default.removeItem(at: migrationProgressURL)
            return LoadResult(
                contents: restored,
                readOnly: false,
                error: .restoredFromBackup
            )

        case .backupUnavailable:
            // 无可用 `.bak` ⇒ `E-302` + 只读。
            //
            // ⚠️ **保留 `migrating.json`** —— 迁移未收口，下次启动仍能按 `step` 重试判定。
            //    目标**可能没坏**（`rename` 未发生时它是旧件）⇒ 不移成 `.corrupt`。
            return LoadResult(
                readOnly: true,
                error: .corruptNoBackup(detail: "迁移中断且无可用 `.bak`：\(detail)")
            )

        case .writeFailed(let reason):
            // 恢复过程本身失败 ⇒ `E-306` + 只读（无可加载内容）。
            return LoadResult(
                readOnly: true,
                error: .migrationRestoreFailed(detail: "恢复失败：\(reason)；\(detail)")
            )
        }
    }

    /// 收口：删 `.bak` + 删 `migrating.json`（迁移已完成）。
    private func removeBackupAndProgress() {
        let fm = FileManager.default
        try? fm.removeItem(at: backupURL)
        try? fm.removeItem(at: migrationProgressURL)
    }

    /// 回退：删 `.tmp` + 删 `.bak` + 删 `migrating.json`（`rename` 未发生）。
    private func removeTempBackupAndProgress() {
        let fm = FileManager.default
        try? fm.removeItem(at: tempURL)
        try? fm.removeItem(at: backupURL)
        try? fm.removeItem(at: migrationProgressURL)
    }
}
