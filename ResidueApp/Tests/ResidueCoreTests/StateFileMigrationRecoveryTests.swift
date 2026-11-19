import XCTest
@testable import ResidueCore

/// CR-031 §3.2 · schema 迁移的**崩溃恢复判定**（R2 v1.9 §10.3 · 恢复判定表）。
///
/// ## 为什么必须按 `step` 判，不能按 CRC 二分
///
/// 迁移是「写 `.bak` → 写新件 → `rename`」的多步过程，断电可能停在**任何**一步。
/// 落盘的 `state/migrating.json` 里的 `step` 游标（R2 v1.9 §10.3 的 step 表）是
/// 唯一能区分「目标没动过」与「`rename` 已经发生」的信息 ——
/// CRC 只能说明「文件好不好」，说明不了「文件是迁移前那个还是迁移后那个」。
///
/// ## 两条禁止（R2 v1.9 §10.3）
///
/// ① **禁止「见 `.bak` 即删」** —— `.bak` 可能是唯一可用的副本。
/// ② **禁止「见 `.bak` 即回滚」** —— 已成功的迁移会被退回旧 schema（数据倒退）。
final class StateFileMigrationRecoveryTests: XCTestCase {

    private var dir: URL!
    private var stateFile: StateFile!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StateFileMigrationRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stateFile = StateFile(directory: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: - 夹具

    /// 造一个 **schema 1** 旧载体：观察期已满、`a` / `b` 非零、结算凭证齐全。
    ///
    /// ⚠️ 用**生产编码器**造旧载体（`StateFileCodec.encode` 认 `header.schemaVersion`），
    ///    不在测试里复制一份编码逻辑（CLAUDE.md §七第 8 条）。
    private func saveSchemaOneCarrier() throws {
        var header = StateHeader(schemaVersion: 1)
        header.appVersion = "1.0.0 (1)"
        header.round = 2
        header.countedDays = 14
        header.roundStartAnchor = Date(timeIntervalSince1970: 1_700_000_000)
        header.autoDeleteEnabled = true
        header.settlement = SettlementHeader(
            producedAt: Date(timeIntervalSince1970: 1_700_000_500),
            reportId: "report-old"
        )
        header.sources = Source.allCases.map {
            SourceHeaderEntry(
                source: $0, snapshotTaken: true,
                T: 100, K: 90, J: 10, H: 30,
                a: 3, b: 12, slotCount: 16, doneCount: 2,
                snapshotDate: Date(timeIntervalSince1970: 1_700_000_100),
                settlementDate: Date(timeIntervalSince1970: 1_700_000_400),
                unattributableCount: 4
            )
        }

        var payloads: [Source: SourcePayload] = [:]
        for source in Source.allCases {
            payloads[source] = SourcePayload(
                bitmap: Data(count: 2),          // ceil(16/8)
                countedDoneSlots: [0, 2],
                slots: [
                    0: CandidateID(
                        path: "/old/\(source.rawValue)",
                        birthtime: Date(timeIntervalSince1970: 1_700_000_000)
                    )
                ],
                snapshotMembers: []              // schema 1 无 `0x04` 段
            )
        }
        try stateFile.save(header: header, payloads: payloads)
    }

    /// 造一个 **schema 2** 载体（迁移后的形态）。
    private func saveSchemaTwoCarrier() throws {
        var header = StateHeader(schemaVersion: 2)
        header.appVersion = "2.0.0 (1)"
        header.round = 2
        header.countedDays = 14
        header.roundStartAnchor = Date(timeIntervalSince1970: 1_700_000_000)
        header.autoDeleteEnabled = true
        header.settlement = SettlementHeader(
            producedAt: Date(timeIntervalSince1970: 1_700_000_500),
            reportId: "report-new"
        )
        header.sources = Source.allCases.map {
            SourceHeaderEntry(
                source: $0, snapshotTaken: true,
                T: 100, K: 90, J: 10, H: 30,
                a: 0, b: 12, slotCount: 16, doneCount: 2,
                snapshotDate: Date(timeIntervalSince1970: 1_700_000_100),
                settlementDate: Date(timeIntervalSince1970: 1_700_000_400),
                unattributableCount: 0
            )
        }

        var payloads: [Source: SourcePayload] = [:]
        for source in Source.allCases {
            payloads[source] = SourcePayload(
                bitmap: Data(count: 2),
                countedDoneSlots: [0, 2],
                slots: [
                    0: CandidateID(
                        path: "/new/\(source.rawValue)",
                        birthtime: Date(timeIntervalSince1970: 1_700_000_000)
                    )
                ],
                snapshotMembers: [
                    CandidateID(
                        path: "/new/\(source.rawValue)",
                        birthtime: Date(timeIntervalSince1970: 1_700_000_000)
                    )
                ]
            )
        }
        try stateFile.save(header: header, payloads: payloads)
    }

    /// 把当前主文件复制成 `.bak`（迁移期唯一回退点）。
    private func copyTargetToBackup() throws {
        try fm.copyItem(at: stateFile.fileURL, to: stateFile.backupURL)
    }

    /// 写迁移进度游标（用**生产原语** `MigrationProgress.write` 造现场）。
    private func writeProgress(
        step: Int,
        fromSchema: Int = 1,
        toSchema: Int = StateFileCodec.currentSchemaVersion
    ) throws {
        try MigrationProgress.write(
            MigrationProgress(
                step: step,
                fromSchema: fromSchema,
                toSchema: toSchema,
                bakPath: stateFile.backupURL.path,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            to: stateFile.migrationProgressURL
        )
    }

    /// 造「迁移残留的新件」（`.tmp` 写了一半）。
    private func writeLeftoverTempFile() throws {
        try Data("half-written-new-carrier".utf8).write(to: stateFile.tempURL)
    }

    /// 破坏主文件（magic 不匹配 ⇒ 不可加载）。
    private func damageTarget() throws {
        try Data(repeating: 0x5A, count: 64).write(to: stateFile.fileURL)
    }

    /// 把主文件的 schema 版本改成比程序更新的值（用户降级应用）。
    private func raiseTargetSchema(to schema: Int) throws {
        var bytes = [UInt8](try Data(contentsOf: stateFile.fileURL))
        bytes[4] = UInt8(schema & 0xFF)
        bytes[5] = UInt8((schema >> 8) & 0xFF)
        bytes[6] = UInt8((schema >> 16) & 0xFF)
        bytes[7] = UInt8((schema >> 24) & 0xFF)
        try Data(bytes).write(to: stateFile.fileURL)
    }

    /// 主文件在盘上的 schema 版本（直读字节 4..8，不解码 —— 解码会先撞上 CRC）。
    private func targetSchemaOnDisk() throws -> Int {
        let bytes = [UInt8](try Data(contentsOf: stateFile.fileURL))
        var value = 0
        for i in 0..<4 { value |= Int(bytes[4 + i]) << (8 * i) }
        return value
    }

    // MARK: - step 1 / 2（目标尚未被迁移动过）

    /// **step 1 + 目标完好** ⇒ 删 `.bak` + 删 `migrating.json`，加载旧载体。
    ///
    /// 迁移**不在本次恢复里重做**（R2 v1.9 §10.3「加载旧件（迁移下次重做）」）：
    /// 盘上仍是 schema 1 ⇒ 下次启动走正常路径自然触发就地升级。
    func testStepOneWithIntactTargetLoadsOldCarrierAndCleansUp() throws {
        try saveSchemaOneCarrier()
        try copyTargetToBackup()
        try writeProgress(step: 1)

        let result = stateFile.load()

        XCTAssertNil(result.error, "目标完好 ⇒ 恢复不应报错：\(String(describing: result.error))")
        XCTAssertEqual(result.contents?.header.schemaVersion, 1, "step 1 目标未被迁移动过 ⇒ 加载旧载体")
        XCTAssertFalse(fm.fileExists(atPath: stateFile.backupURL.path), "`.bak` 必须删除（目标已确认可加载）")
        XCTAssertFalse(fm.fileExists(atPath: stateFile.migrationProgressURL.path), "`migrating.json` 必须删除")
    }

    /// **step 1 + 目标缺失** ⇒ 目标不可加载 ⇒ 从 `.bak` 恢复 + `E-308`。
    ///
    /// ⚠️ `.bak` **必须保留**（禁止「见 `.bak` 即删」）—— 它仍是唯一可回退点。
    func testStepOneWithMissingTargetRestoresFromBackupAndReportsE308() throws {
        try saveSchemaOneCarrier()
        try copyTargetToBackup()
        try fm.removeItem(at: stateFile.fileURL)
        try writeProgress(step: 1)

        let result = stateFile.load()

        XCTAssertEqual(result.error, .restoredFromBackup, "从 `.bak` 恢复成功 ⇒ E-308")
        XCTAssertEqual(result.contents?.header.schemaVersion, 1, "恢复后应回到旧载体")
        XCTAssertTrue(fm.fileExists(atPath: stateFile.fileURL.path), "`.bak` 必须真的写回主文件")
        XCTAssertEqual(try targetSchemaOnDisk(), 1, "主文件必须被写回旧载体")
        XCTAssertTrue(fm.fileExists(atPath: stateFile.backupURL.path), "`.bak` 必须保留（禁止「见 `.bak` 即删」）")
        XCTAssertFalse(fm.fileExists(atPath: stateFile.migrationProgressURL.path), "恢复成功 ⇒ 迁移收口 ⇒ 删 `migrating.json`")
    }

    // MARK: - step 3（目标未动，但新件已写完）

    /// **step 3 + 目标仍是旧件**（`目标.schemaVersion == fromSchema`）⇒ 回退：
    /// 删 `.tmp` + 删 `.bak` + 删 `migrating.json`，加载旧件。
    func testStepThreeWithUnmovedTargetRollsBackToOldCarrier() throws {
        try saveSchemaOneCarrier()
        try copyTargetToBackup()
        try writeLeftoverTempFile()
        try writeProgress(step: 3)

        let result = stateFile.load()

        XCTAssertNil(result.error, "回退成功不应报错：\(String(describing: result.error))")
        XCTAssertEqual(result.contents?.header.schemaVersion, 1, "step 3 目标未动 ⇒ 加载旧件")
        XCTAssertFalse(fm.fileExists(atPath: stateFile.tempURL.path), "回退必须删掉迁移残留的新件")
        XCTAssertFalse(fm.fileExists(atPath: stateFile.backupURL.path), "回退必须删 `.bak`")
        XCTAssertFalse(fm.fileExists(atPath: stateFile.migrationProgressURL.path), "回退必须删 `migrating.json`")
    }

    /// **step 3 + 目标已是新 schema** ⇒ **不得回退**。
    ///
    /// 鉴别点：`rename` 已发生而 `step` 未及时更新 ⇒ 「目标.schemaVersion == fromSchema」
    /// 断言不成立 ⇒ 不得按 step 3 回退（旧数据覆盖新数据 = 数据倒退）。
    func testStepThreeWithAlreadyMigratedTargetKeepsNewSchema() throws {
        try saveSchemaOneCarrier()
        try saveSchemaTwoCarrier()          // `save()` 副作用：`.bak` = schema 1 副本
        try writeProgress(step: 3, fromSchema: 1, toSchema: 2)

        let result = stateFile.load()

        XCTAssertNil(result.error, "`rename` 已发生 ⇒ 不应报错：\(String(describing: result.error))")
        XCTAssertEqual(result.contents?.header.schemaVersion, 2, "`rename` 已发生 ⇒ 不得回退成旧件")
        XCTAssertFalse(fm.fileExists(atPath: stateFile.backupURL.path), "收口 ⇒ 删 `.bak`")
        XCTAssertFalse(fm.fileExists(atPath: stateFile.migrationProgressURL.path), "收口 ⇒ 删 `migrating.json`")
    }

    // MARK: - step 5（`rename` 已完成）

    /// **step 5 + 目标仍是旧件** ⇒ 回退（`rename` 没发生，等价 step 3）。
    func testStepFiveWithUnmovedTargetRollsBackToOldCarrier() throws {
        try saveSchemaOneCarrier()
        try copyTargetToBackup()
        try writeLeftoverTempFile()
        try writeProgress(step: 5)

        let result = stateFile.load()

        XCTAssertNil(result.error, "回退成功不应报错：\(String(describing: result.error))")
        XCTAssertEqual(result.contents?.header.schemaVersion, 1, "目标仍是旧件 ⇒ 加载旧件")
        XCTAssertFalse(fm.fileExists(atPath: stateFile.tempURL.path), "回退必须删掉迁移残留的新件")
        XCTAssertFalse(fm.fileExists(atPath: stateFile.backupURL.path), "回退必须删 `.bak`")
        XCTAssertFalse(fm.fileExists(atPath: stateFile.migrationProgressURL.path), "回退必须删 `migrating.json`")
    }

    /// **step 5 + 目标已是新件** ⇒ 迁移实际已完成 ⇒ 删 `.bak` + 删 `migrating.json`，
    /// 按新 schema 加载。
    func testStepFiveWithMigratedTargetKeepsNewSchema() throws {
        try saveSchemaOneCarrier()
        try saveSchemaTwoCarrier()          // `save()` 副作用：`.bak` = schema 1 副本
        try writeProgress(step: 5, fromSchema: 1, toSchema: 2)

        let result = stateFile.load()

        XCTAssertNil(result.error, "迁移已完成 ⇒ 不应报错：\(String(describing: result.error))")
        XCTAssertEqual(result.contents?.header.schemaVersion, 2, "目标已是新件 ⇒ 按新 schema 加载")
        XCTAssertFalse(fm.fileExists(atPath: stateFile.backupURL.path), "收口 ⇒ 删 `.bak`")
        XCTAssertFalse(fm.fileExists(atPath: stateFile.migrationProgressURL.path), "收口 ⇒ 删 `migrating.json`")
    }

    // MARK: - step 4（`rename` 可能已发生、也可能没）

    /// **step 4 + 目标损坏 + `.bak` 可用** ⇒ 从 `.bak` 恢复 + `E-308`。
    func testStepFourWithDamagedTargetRestoresFromBackupAndReportsE308() throws {
        try saveSchemaOneCarrier()
        try copyTargetToBackup()
        try damageTarget()
        try writeProgress(step: 4)

        let result = stateFile.load()

        XCTAssertEqual(result.error, .restoredFromBackup, "`.bak` 可用 ⇒ E-308（恢复成功）")
        XCTAssertEqual(result.contents?.header.schemaVersion, 1, "恢复后应回到旧载体")
        XCTAssertEqual(try targetSchemaOnDisk(), 1, "`.bak` 必须真的原子写回主文件")
        XCTAssertTrue(fm.fileExists(atPath: stateFile.backupURL.path), "`.bak` 必须保留（禁止「见 `.bak` 即删」）")
        XCTAssertFalse(fm.fileExists(atPath: stateFile.migrationProgressURL.path), "恢复成功 ⇒ 迁移收口 ⇒ 删 `migrating.json`")
    }

    /// **step 4 + 目标损坏 + 无可用 `.bak`** ⇒ `E-302` + 只读。
    ///
    /// ⚠️ `migrating.json` **必须保留** —— 迁移未收口，下次启动仍能按 `step` 重试判定。
    func testStepFourWithDamagedTargetAndNoBackupReportsE302() throws {
        try saveSchemaOneCarrier()
        try copyTargetToBackup()
        try fm.removeItem(at: stateFile.backupURL)
        try damageTarget()
        try writeProgress(step: 4)

        let result = stateFile.load()

        guard case .corruptNoBackup = result.error else {
            XCTFail("无可用 `.bak` 必须报 E-302，实际：\(String(describing: result.error))")
            return
        }
        XCTAssertTrue(result.readOnly, "E-302 ⇒ 只读")
        XCTAssertTrue(
            fm.fileExists(atPath: stateFile.migrationProgressURL.path),
            "迁移未收口 ⇒ `migrating.json` 必须保留（下次启动仍能重试判定）"
        )
    }

    /// **step 4 + 目标写不回去**（主文件路径被目录占位）+ `.bak` 有效 ⇒ `E-306` + 只读。
    func testStepFourWithUnwritableTargetReportsE306() throws {
        try saveSchemaOneCarrier()
        try copyTargetToBackup()
        try fm.removeItem(at: stateFile.fileURL)
        try fm.createDirectory(at: stateFile.fileURL, withIntermediateDirectories: true)
        try writeProgress(step: 4)

        let result = stateFile.load()

        guard case .migrationRestoreFailed = result.error else {
            XCTFail("恢复本身失败必须报 E-306，实际：\(String(describing: result.error))")
            return
        }
        XCTAssertTrue(result.readOnly, "E-306 ⇒ 只读")
    }

    // MARK: - 进度文件缺失 / 不可读

    /// **无 `migrating.json` + 陈旧 `.bak`** ⇒ 走正常路径。
    ///
    /// 鉴别点：**禁止「见 `.bak` 即回滚」** —— 没有进度游标就没有迁移发生过的事实，
    /// 此时 `.bak` 只是上一次成功写入留下的普通备份，不得据此退回旧 schema。
    func testStaleBackupWithoutProgressFileDoesNotRollBack() throws {
        try saveSchemaOneCarrier()
        try copyTargetToBackup()

        let result = stateFile.load()

        XCTAssertNil(result.error, "正常路径不应报错：\(String(describing: result.error))")
        XCTAssertEqual(result.contents?.header.schemaVersion, 2, "没有进度游标 ⇒ 正常路径走就地升级，不得回滚")
    }

    /// **`migrating.json` 存在但读不出** ⇒ **未知 step** ⇒ 保守处置。
    ///
    /// 读不出 ≠ 不存在：文件在 ⇒ 迁移**确实发生过**（只是游标坏了）⇒
    /// 不得当作「无进度文件」走正常路径（那会让半迁移状态被当成正常态）。
    func testUnreadableProgressFileFallsBackToConservativeRollback() throws {
        try saveSchemaOneCarrier()
        try copyTargetToBackup()
        try fm.createDirectory(
            at: stateFile.migrationProgressURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{ not json".utf8).write(to: stateFile.migrationProgressURL)

        let result = stateFile.load()

        XCTAssertNil(result.error, "目标完好 ⇒ 保守处置不应报错：\(String(describing: result.error))")
        XCTAssertEqual(result.contents?.header.schemaVersion, 1, "未知 step + 目标完好 ⇒ 保守回退加载旧件")
        XCTAssertFalse(fm.fileExists(atPath: stateFile.migrationProgressURL.path), "收口 ⇒ 删 `migrating.json`")
        XCTAssertFalse(fm.fileExists(atPath: stateFile.backupURL.path), "收口 ⇒ 删 `.bak`")
    }

    // MARK: - 目标 schema 比程序更新

    /// **目标 schema 比程序新**（用户降级应用）⇒ `E-301` 只读，**不动任何文件**。
    ///
    /// ⚠️ 不得把它当「损坏」并从 `.bak` 恢复 —— 那会用旧数据覆盖用户的新数据
    ///    （数据回退，比损坏更严重）。
    func testTargetWithNewerSchemaIsReadOnlyAndUntouched() throws {
        try saveSchemaOneCarrier()
        try copyTargetToBackup()
        try raiseTargetSchema(to: StateFileCodec.currentSchemaVersion + 1)
        try writeProgress(step: 4)

        let result = stateFile.load()

        guard case .schemaTooNew(let found, _) = result.error else {
            XCTFail("schema 更高必须报 E-301，实际：\(String(describing: result.error))")
            return
        }
        XCTAssertEqual(found, StateFileCodec.currentSchemaVersion + 1)
        XCTAssertTrue(result.readOnly, "E-301 ⇒ 只读")
        XCTAssertTrue(fm.fileExists(atPath: stateFile.backupURL.path), "E-301 不得动 `.bak`")
        XCTAssertTrue(fm.fileExists(atPath: stateFile.migrationProgressURL.path), "E-301 不得动 `migrating.json`")
        XCTAssertEqual(
            try targetSchemaOnDisk(),
            StateFileCodec.currentSchemaVersion + 1,
            "目标文件不得被改动（不得用 `.bak` 覆盖用户的新数据）"
        )
    }
}
