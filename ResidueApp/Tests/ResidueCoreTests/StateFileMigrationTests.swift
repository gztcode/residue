import XCTest
@testable import ResidueCore

/// CR-031 §3.2 · schema 1 → 2 **就地升级**（R2 v1.9 §10.3「低一档」行）。
///
/// 契约落点：
///   - R2 v1.9 §10.3 低一档行 —— 就地升级 / 观察期从头开始 / 用户设置保留 / 快照成员集合为空
///   - R2 v1.9 §10.3「低」行 —— 空间预检 / `state/migrating.json` 游标 / `.bak` / 失败回退
///   - PRD v5.6 M1「写入时刻」—— 版本变更八项终值（迁移共用同一套清零语义）
///
/// **为什么必须就地升级而不是丢弃**：载体里装着 `a`（L0 误判累计）与观察期凭证，
/// 丢弃 = 把「判错过 N 次」抹成「一次都没错」→ 放行自动删除（不变量④）。
/// 丢弃载体与静默重建是同一件事。
final class StateFileMigrationTests: XCTestCase {

    private var dir: URL!
    private var stateFile: StateFile!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StateFileMigrationTests-\(UUID().uuidString)")
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
    ///    复制出来的旧载体与生产编码器会各自腐坏 —— 测的就不是真载体了。
    private func saveSchemaOneCarrier(configure: (inout StateHeader) -> Void = { _ in }) throws {
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
        configure(&header)

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

    /// 文件字节数。
    private func fileSize(at url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? Int) ?? 0
    }

    /// 迁移后的载体头（迁移后 `load()` 必须直接给出 schema 2）。
    private func migratedHeader() throws -> StateHeader {
        let result = stateFile.load()
        XCTAssertNil(result.error, "迁移不应报错：\(String(describing: result.error))")
        return try XCTUnwrap(result.contents?.header)
    }

    // MARK: - 触发与载体语义

    /// **schema 1 载体必须被就地升级**（不丢弃载体）。
    func testSchemaOneCarrierIsUpgradedInPlace() throws {
        try saveSchemaOneCarrier()

        let result = stateFile.load()

        XCTAssertNil(result.error, "迁移不应报错：\(String(describing: result.error))")
        XCTAssertEqual(result.contents?.header.schemaVersion, 2, "载体必须被升级到 schema 2")

        let onDisk = try StateFileCodec.decode(Data(contentsOf: stateFile.fileURL))
        XCTAssertEqual(onDisk.header.schemaVersion, 2, "磁盘上的载体必须已经是 schema 2")
    }

    /// **schema 2 载体不被触碰**（不重复迁移、不重置凭证）。
    func testSchemaTwoCarrierIsNotMigrated() throws {
        var header = StateHeader(appVersion: "2.0.0 (1)", round: 3)
        header.countedDays = 5
        header.autoDeleteEnabled = true
        header.sources = Source.allCases.map {
            SourceHeaderEntry(source: $0, snapshotTaken: true, T: 100, K: 90, J: 10, H: 30, a: 0, b: 7)
        }
        try stateFile.save(header: header, payloads: [:])

        let result = stateFile.load()

        XCTAssertNil(result.error, "schema 2 载体不该报错：\(String(describing: result.error))")
        let after = try XCTUnwrap(result.contents?.header)
        XCTAssertEqual(after.schemaVersion, 2)
        XCTAssertEqual(after.round, 3, "已是 schema 2 的载体不得被重置")
        XCTAssertEqual(after.countedDays, 5, "已是 schema 2 的载体不得被重置观察期")
        XCTAssertTrue(after.autoDeleteEnabled, "已是 schema 2 的载体不得被重置用户设置")
        for entry in after.sources {
            XCTAssertEqual(entry.K, 90, "\(entry.source) 的结算值不得被无故清零")
            XCTAssertEqual(entry.b, 7, "\(entry.source) 的 b 不得被无故清零")
        }
    }

    // MARK: - 观察期从头开始（§10.3 低一档行 ②）

    /// **观察期从头开始**：计数日归零 + 起算点重置 + `T` 待重取 + `K`/`J` 清零
    /// + 结算凭证清零 + `b` 清零 + `a` 的四项载体清零。
    func testMigrationResetsObservationCredentials() throws {
        try saveSchemaOneCarrier()

        let header = try migratedHeader()

        XCTAssertEqual(header.countedDays, 0, "本轮计数日必须归零")
        XCTAssertNil(header.roundStartAnchor, "本轮计数日起算点必须重置")
        XCTAssertNil(header.settlement.producedAt, "结算凭证（报告产出时刻）必须清零")
        XCTAssertNil(header.settlement.reportId, "结算凭证（报告标识）必须清零")

        XCTAssertEqual(header.sources.count, Source.allCases.count, "来源条目不得被迁移抹掉")
        for entry in header.sources {
            XCTAssertFalse(entry.snapshotTaken, "\(entry.source) 的快照标志必须清零")
            XCTAssertNil(entry.T, "\(entry.source) 的 T 必须回到「待重取」")
            XCTAssertNil(entry.K, "\(entry.source) 的 K 必须清零")
            XCTAssertNil(entry.J, "\(entry.source) 的 J 必须清零")
            XCTAssertNil(entry.H, "\(entry.source) 的 H 随新 T 重算 ⇒ 先回到 nil")
            XCTAssertEqual(entry.b, 0, "\(entry.source) 的 b 必须清零")
            XCTAssertEqual(entry.a, 0, "\(entry.source) 的 a 必须清零")
            XCTAssertEqual(entry.slotCount, 0, "\(entry.source) 的位槽占用表必须清零")
            XCTAssertEqual(entry.doneCount, 0, "\(entry.source) 的 C_done 必须清零")
            XCTAssertNil(entry.snapshotDate, "\(entry.source) 的取快照时刻必须清零")
            XCTAssertNil(entry.settlementDate, "\(entry.source) 的结算时刻必须清零")
            XCTAssertNil(entry.unattributableCount, "\(entry.source) 的无法归因条数必须回到「尚未结算」")
            XCTAssertNil(entry.lastJudgmentAt, "\(entry.source) 的上次判定时刻必须清零")
        }
    }

    // MARK: - 用户设置原样保留（§10.3 低一档行 ③）

    /// **用户设置类字段原样保留**（**不得造全新 `StateHeader()`**）。
    ///
    /// 造全新 header = 把 `autoDeleteEnabled` 静默置 `false` ⇒
    /// 用户升级应用 = 被替用户改主意（PRD v5.6 M1 写入时刻 ⑧）。
    func testMigrationPreservesUserSettings() throws {
        try saveSchemaOneCarrier()

        let header = try migratedHeader()

        // 前提：迁移**确实发生了** —— 否则「没迁移也保留设置」会让本用例失去鉴别力。
        XCTAssertEqual(header.schemaVersion, 2, "前置：载体必须已被升级到 schema 2")
        XCTAssertTrue(header.autoDeleteEnabled, "自动删除总开关不得被迁移悄悄关掉")
        XCTAssertEqual(header.round, 2, "轮次不变（迁移不产生新轮次）")
        XCTAssertEqual(header.appVersion, "1.0.0 (1)", "应用版本不变（迁移改的是载体格式，不是应用版本）")
        XCTAssertEqual(header.countedDaysCap, 14, "计数日上限属用户设置类字段")
    }

    // MARK: - 快照成员集合为空（§10.3 低一档行 ①）

    /// **快照成员集合为空**（旧载体无 `0x04` 段 → 无成员可归因）。
    ///
    /// ⚠️ `nil` 与「空集合」不等价：空集合 = 已取快照、成员为零；
    /// 未取快照必须靠 `snapshotTaken = false` 表达（不变量③）。
    func testMigrationEmptiesSnapshotMembers() throws {
        try saveSchemaOneCarrier()

        let result = stateFile.load()

        for source in Source.allCases {
            let payload = try XCTUnwrap(result.contents?.payloads[source], "\(source) 的段必须存在")
            XCTAssertEqual(payload.snapshotMembers.count, 0, "\(source) 的快照成员集合必须为空")
            XCTAssertEqual(payload.slots.count, 0, "\(source) 的位槽占用表必须清零")
            XCTAssertEqual(payload.countedDoneSlots.count, 0, "\(source) 的 C_done 必须清零")
            XCTAssertEqual(payload.bitmap.count, 0, "\(source) 的 F 位图必须清零")
        }
    }

    // MARK: - 收口（§10.3「低」行 ⑤）

    /// **迁移成功后不留 `.bak` 与 `migrating.json`**。
    ///
    /// §10.3 ⑤：成功后删 `.bak` 与 `migrating.json`；
    /// N7 清除范围里也写明「迁移成功后 `.bak` 立即删除，正常态下不存在」。
    func testMigrationLeavesNoBackupOrProgressFile() throws {
        try saveSchemaOneCarrier()

        _ = stateFile.load()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stateFile.backupURL.path),
            "迁移成功后 `.bak` 必须删除"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stateFile.migrationProgressURL.path),
            "迁移成功后 `migrating.json` 必须删除"
        )
    }

    // MARK: - 空间预检（R2 v1.9 §10.3「低」行 ①）

    /// **迁移的空间预检算式 = `3 × 状态文件 + 64 MB`**。
    ///
    /// 峰值 = 原件 + `.bak` + 新件。v1.1 的 `2× + 20%` **少算了新件**
    /// ⇒ 336 MB 状态下缺口 200+ MB ⇒ 迁移末段必 `ENOSPC`。
    func testMigrationSpaceRequirementIsThreeTimesCarrierPlus64MB() {
        XCTAssertEqual(
            MigrationSpacePolicy.requiredBytes(carrierBytes: 0),
            64 * 1024 * 1024,
            "空载体也要留 64 MB 余量"
        )
        XCTAssertEqual(
            MigrationSpacePolicy.requiredBytes(carrierBytes: 1_000_000),
            3_000_000 + 64 * 1024 * 1024,
            "峰值 = 原件 + `.bak` + 新件 ⇒ 三份，再加 64 MB 余量"
        )
    }

    /// **空间不足 → `E-305`（给出所需字节数），旧载体原样保留**。
    ///
    /// E-305 是**可恢复**错误（用户腾空间后重试）⇒ **不得把产品锁进只读**。
    func testMigrationStopsWithE305WhenSpaceIsInsufficient() throws {
        try saveSchemaOneCarrier()
        let carrierBytes = try fileSize(at: stateFile.fileURL)
        XCTAssertGreaterThan(carrierBytes, 0, "前置：旧载体必须非空")

        let limited = StateFile(directory: dir, availableBytesProvider: { _ in 1024 })
        let result = limited.load()

        guard case .migrationSpaceInsufficient(let required, let available) = result.error else {
            XCTFail("空间不足必须报 E-305，实际：\(String(describing: result.error))")
            return
        }
        XCTAssertEqual(available, 1024, "必须如实报出可用字节数")
        XCTAssertEqual(
            required,
            MigrationSpacePolicy.requiredBytes(carrierBytes: carrierBytes),
            "必须报出所需字节数（用户据此判断要腾多少空间）"
        )
        XCTAssertFalse(result.readOnly, "E-305 可恢复（腾空间后重试），不得把产品锁进只读")
        XCTAssertEqual(
            result.contents?.header.schemaVersion, 1,
            "旧载体必须照常可读（预检失败不得把用户挡在门外）"
        )

        // 磁盘上仍是旧件 —— 预检失败**不得动数据**。
        let onDisk = try StateFileCodec.decode(Data(contentsOf: stateFile.fileURL))
        XCTAssertEqual(onDisk.header.schemaVersion, 1, "预检失败不得改动旧载体")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stateFile.migrationProgressURL.path),
            "预检未过 ⇒ 不得写 `migrating.json`（step 1 的前提是预检已过）"
        )
    }

    // MARK: - 迁移失败处置（R2 v1.9 §10.3「低」行 ⑥）

    /// **迁移失败 → 从 `.bak` 原子恢复 + `E-308`**（恢复成功）。
    ///
    /// 造法：把 `.tmp` 路径占成目录 → 新件写不出来 → 迁移失败；
    /// `.bak` 已在迁移里写好 ⇒ 可恢复 ⇒ `E-308`（提示级）+ 旧载体内容。
    func testMigrationFailureRestoresFromBackupAndReportsE308() throws {
        try saveSchemaOneCarrier()
        try FileManager.default.createDirectory(
            at: stateFile.tempURL, withIntermediateDirectories: true
        )

        let result = stateFile.load()

        XCTAssertEqual(result.error, .restoredFromBackup, "迁移失败但 `.bak` 可用 ⇒ E-308")
        XCTAssertEqual(
            result.contents?.header.schemaVersion, 1,
            "恢复后应回到旧载体（schema 1）"
        )

        // 目标文件必须**真的**被写回（不是只在内存里「恢复」）。
        let onDisk = try StateFileCodec.decode(Data(contentsOf: stateFile.fileURL))
        XCTAssertEqual(onDisk.header.schemaVersion, 1, "`.bak` 必须真的原子写回主文件")
    }

    /// **迁移失败且无可用 `.bak` → `E-302` + 只读**。
    ///
    /// 造法：把 `.bak` 路径占成目录 → 备份写不出来 → 迁移失败 → 无可用 `.bak`。
    ///
    /// ⚠️ 主文件**没坏**（原子替换失败 ⇒ 目标未动）⇒ **不得把它当损坏移走**：
    /// 移走 = 把完好的旧数据当成损坏丢掉。
    func testMigrationFailureWithoutBackupReportsE302() throws {
        try saveSchemaOneCarrier()
        try FileManager.default.createDirectory(
            at: stateFile.backupURL, withIntermediateDirectories: true
        )

        let result = stateFile.load()

        guard case .corruptNoBackup = result.error else {
            XCTFail("无可用 `.bak` 必须报 E-302，实际：\(String(describing: result.error))")
            return
        }
        XCTAssertTrue(result.readOnly, "E-302 ⇒ 只读")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: stateFile.fileURL.path),
            "主文件未损坏，不得被当成 `.corrupt` 移走"
        )
        let onDisk = try StateFileCodec.decode(Data(contentsOf: stateFile.fileURL))
        XCTAssertEqual(onDisk.header.schemaVersion, 1, "旧载体必须完好无损")
    }
}
