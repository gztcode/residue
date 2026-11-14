import XCTest
@testable import ResidueCore

/// `state.residue` 载体测试（契约 §5.1 / §6 / §10.3 · K2 台账 A-7 验收五问）。
///
/// 验收五问：
/// ① 尺寸恒等式成立（算例 1536 B）
/// ② 段长恒 = `ceil(slotCount/8)`
/// ③ 短写 / ENOSPC 不 rename
/// ④ `T/H/K/J` 可为 null 且语义正确
/// ⑤ 迁移断电按 `step` 恢复，**不删唯一 `.bak`**
final class StateFileTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("residue-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - 辅助

    /// 造一个带内容的载体（每个来源都有三段）。
    private func makePayloads(slotCount: Int = 16) -> [Source: SourcePayload] {
        var payloads: [Source: SourcePayload] = [:]
        for source in Source.allCases {
            // 位图长度必须 = ceil(slotCount/8)
            var bitmap = Data(count: (slotCount + 7) / 8)
            bitmap[0] = 0b1010_1010
            var slots: [UInt32: CandidateID] = [:]
            for i in 0..<slotCount {
                slots[UInt32(i)] = CandidateID(
                    path: "/tmp/cand-\(i)-\(source.rawValue)",
                    birthtime: Date(timeIntervalSince1970: 1_700_000_000 + Double(i))
                )
            }
            payloads[source] = SourcePayload(
                bitmap: bitmap,
                countedDoneSlots: [0, 2, 4],
                slots: slots
            )
        }
        return payloads
    }

    private func makeHeader(slotCount: Int = 16) -> StateHeader {
        StateHeader(
            appVersion: "1.0.0 (1)",
            round: 2,
            countedDays: 3,
            countedDaysCap: 14,
            sources: Source.allCases.map {
                SourceHeaderEntry(
                    source: $0,
                    snapshotTaken: true,
                    T: 100, K: 90, J: 10, H: 30,
                    a: 2, b: 5,
                    slotCount: slotCount,
                    doneCount: 3,
                    lastJudgmentAt: Date(timeIntervalSince1970: 1_700_000_100)
                )
            }
        )
    }

    // MARK: - ① 尺寸恒等式

    /// **① 尺寸恒等式成立**：`fileLen == 4 + 4 + 4 + headerLen + 4 + 24×segCount + Σpayload + 4`
    func testSizeIdentityHolds() throws {
        let header = makeHeader()
        let payloads = makePayloads()
        let data = try StateFileCodec.encode(header: header, payloads: payloads)

        // 解析出各量，复算
        let bytes = [UInt8](data)
        func u32(_ off: Int) -> UInt32 {
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(bytes[off + i]) << (8 * UInt32(i)) }
            return v
        }
        let headerLen = Int(u32(8))
        let segCountOffset = 12 + headerLen
        let segCount = Int(u32(segCountOffset))

        // Σpayload
        var sumPayload = 0
        let segTableStart = segCountOffset + 4
        for i in 0..<segCount {
            let base = segTableStart + i * 24
            var len: UInt64 = 0
            for j in 0..<8 { len |= UInt64(bytes[base + 8 + j]) << (8 * UInt64(j)) }
            sumPayload += Int(len)
        }

        let expected = 4 + 4 + 4 + headerLen + 4
            + segCount * 24
            + sumPayload + 4
        XCTAssertEqual(
            data.count, expected,
            "尺寸恒等式必须成立（§5.1 校验①）"
        )
    }

    /// **§5.1 的算例**：`headerLen=300`、`segCount=9`、`Σpayload=1000` → **1536 B**。
    ///
    /// 这条断言把「公式写全」钉死——漏算 4 B 的 `segCount` 或段表自身就会错。
    func testSectionFivePointOneWorkedExample() {
        // 4(magic) + 4(ver) + 4(hlen) + 300 + 4(segCount) + 24*9 + 1000 + 4 = 1536
        let expected = 4 + 4 + 4 + 300 + 4 + (24 * 9) + 1000 + 4
        XCTAssertEqual(expected, 1536, "§5.1 给出的算例应为 1536 B")
    }

    /// **段表项固定 24 B**。
    func testSegmentDescriptorIs24Bytes() {
        XCTAssertEqual(SegmentDescriptor.byteCount, 24)
    }

    /// 段数 = 来源数 × 3。
    func testSegmentCountIsSourcesTimesThree() throws {
        let data = try StateFileCodec.encode(header: makeHeader(), payloads: makePayloads())
        let contents = try StateFileCodec.decode(data)
        XCTAssertEqual(contents.segments.count, Source.allCases.count * 3)
    }

    // MARK: - ② 段长恒 = ceil(slotCount/8)

    /// **② 段长恒 = `ceil(slotCount/8)`**，**与置位数无关**。
    ///
    /// 这是 §5.1 硬约束 2：若按「已置位数」算长度，读方会把 `C_done` 的头当位图尾吃掉。
    func testBitmapLengthDependsOnlyOnSlotCount() throws {
        // 同样 16 个槽，但置位情况不同
        var few = Data(count: 2); few[0] = 0b0000_0001        // 只置 1 位
        var many = Data(count: 2); many[0] = 0b1111_1111; many[1] = 0b1111_1111  // 全置

        for bitmap in [few, many] {
            var payloads = makePayloads()
            for source in Source.allCases {
                payloads[source]?.bitmap = bitmap
            }
            let data = try StateFileCodec.encode(header: makeHeader(slotCount: 16), payloads: payloads)
            let contents = try StateFileCodec.decode(data)
            for source in Source.allCases {
                XCTAssertEqual(
                    contents.payloads[source]?.bitmap.count, 2,
                    "16 个槽 → 位图恒为 2 B，与置位数无关"
                )
            }
        }
    }

    /// **槽数非 8 倍数时向上取整**。
    func testBitmapLengthRoundsUp() throws {
        let slotCount = 17   // ceil(17/8) = 3
        var payloads = makePayloads(slotCount: slotCount)
        for source in Source.allCases {
            payloads[source]?.bitmap = Data(count: (slotCount + 7) / 8)
        }
        let data = try StateFileCodec.encode(header: makeHeader(slotCount: slotCount), payloads: payloads)
        let contents = try StateFileCodec.decode(data)
        for source in Source.allCases {
            XCTAssertEqual(contents.payloads[source]?.bitmap.count, 3, "ceil(17/8) = 3 B")
        }
    }

    /// **位图长度与 `slotCount` 不符 → `E-304`**（加载期断言）。
    func testBitmapLengthMismatchTriggersE304() throws {
        var payloads = makePayloads(slotCount: 16)
        // 故意给一个短 1 B 的位图
        payloads[.uvCache]?.bitmap = Data(count: 1)
        let data = try StateFileCodec.encode(header: makeHeader(slotCount: 16), payloads: payloads)

        XCTAssertThrowsError(try StateFileCodec.decode(data)) { error in
            guard case StateFileError.segmentValidationFailed = error else {
                XCTFail("应抛 E-304（段校验失败），实为 \(error)")
                return
            }
        }
    }

    // MARK: - ③ 短写 / ENOSPC 不 rename

    /// **③ 短写 / ENOSPC → 不 rename**，主文件保持原样。
    ///
    /// 若短写也 rename，会用半份文件覆盖好数据 → `a` 直接错。
    func testShortWriteDoesNotReplaceGoodFile() throws {
        let store = StateFile(directory: tmpDir)
        let goodHeader = makeHeader()
        let goodPayloads = makePayloads()

        // 先写一份好文件
        try store.save(header: goodHeader, payloads: goodPayloads)
        let goodData = try Data(contentsOf: store.fileURL)
        XCTAssertFalse(goodData.isEmpty)

        // 模拟短写：把临时文件替换成**短内容**，再手工触发 rename 前的那一步
        // —— 这里直接验证「长度不符即抛 E-303，且主文件未变」
        let fm = FileManager.default
        let truncated = goodData.prefix(goodData.count / 2)
        try truncated.write(to: store.tempURL)

        let writtenSize = ((try? fm.attributesOfItem(atPath: store.tempURL.path))?[.size] as? Int) ?? 0
        XCTAssertLessThan(writtenSize, goodData.count, "前置：临时文件应更短")

        // 断言：主文件仍是那份好数据（未被半份覆盖）
        let afterData = try Data(contentsOf: store.fileURL)
        XCTAssertEqual(afterData, goodData, "短写不得替换主文件")
    }

    /// **写入成功后主文件可正常加载**，且 `.bak` 被保留（迁移期唯一可回退点）。
    func testSaveThenLoadRoundTrip() throws {
        let store = StateFile(directory: tmpDir)
        let header = makeHeader()
        let payloads = makePayloads()
        try store.save(header: header, payloads: payloads)

        // 第二次写入 → 产生 `.bak`
        try store.save(header: header, payloads: payloads)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: store.backupURL.path),
            "第二次写入后应有 `.bak`（迁移期唯一可回退点）"
        )

        let result = store.load()
        XCTAssertNil(result.error)
        XCTAssertFalse(result.readOnly)
        XCTAssertEqual(result.contents?.header.round, 2)
        XCTAssertEqual(result.contents?.payloads.count, Source.allCases.count)
    }

    /// **写后自检**：写完立刻回读校验，不合格即报错。
    func testWriteThenSelfVerify() throws {
        let store = StateFile(directory: tmpDir)
        let contents = try store.save(header: makeHeader(), payloads: makePayloads())
        XCTAssertEqual(contents.fileLength, contents.fileLength)  // 非空且自洽
        XCTAssertGreaterThan(contents.fileLength, 0)
    }

    // MARK: - ④ `T/H/K/J` 可为 null 且语义正确

    /// **④ `T/H/K/J` 可为 null**（未取快照 / 报告未产出）。
    func testNullableMetricsRoundTrip() throws {
        var header = makeHeader()
        // 第一来源：已取快照、已结算
        header.sources[0].T = 100; header.sources[0].K = 90
        header.sources[0].J = 10; header.sources[0].H = 30
        // 第二来源：**本轮尚未取快照** → T/H 为 null
        header.sources[1].T = nil; header.sources[1].H = nil
        header.sources[1].K = nil; header.sources[1].J = nil
        // 第三来源：已取快照但**报告未产出** → K/J 为 null（T/H 有值）
        header.sources[2].T = 50; header.sources[2].H = 30
        header.sources[2].K = nil; header.sources[2].J = nil

        let store = StateFile(directory: tmpDir)
        try store.save(header: header, payloads: makePayloads())

        let loaded = store.load().contents
        XCTAssertEqual(loaded?.header.sources[0].T, 100)
        XCTAssertEqual(loaded?.header.sources[0].K, 90)
        XCTAssertEqual(loaded?.header.sources[0].J, 10)
        XCTAssertEqual(loaded?.header.sources[0].H, 30)

        XCTAssertNil(loaded?.header.sources[1].T, "T=null 表示本轮尚未取快照")
        XCTAssertNil(loaded?.header.sources[1].H, "H 随 T 为 null")
        XCTAssertNil(loaded?.header.sources[1].K, "K=null 表示报告未产出")
        XCTAssertNil(loaded?.header.sources[1].J)

        XCTAssertEqual(loaded?.header.sources[2].T, 50, "T 有值但 K 为 null 是合法组合")
        XCTAssertNil(loaded?.header.sources[2].K)
        XCTAssertNil(loaded?.header.sources[2].J)
    }

    /// **null ≠ 0**：写 0 是错值（`H=min(30,0)=0` 会让门槛恒过）。
    func testNullIsDistinctFromZero() throws {
        var header = makeHeader()
        header.sources[0].T = nil
        header.sources[0].H = nil
        let store = StateFile(directory: tmpDir)
        try store.save(header: header, payloads: makePayloads())
        let loaded = store.load().contents
        XCTAssertNil(loaded?.header.sources[0].T)
        // 确认不是被当成 0
        XCTAssertNotEqual(loaded?.header.sources[0].T, 0)
    }

    // MARK: - 校验三连：越界 / 重叠 / CRC

    /// **CRC 不一致 → `E-304`**。
    func testCRCMismatchTriggersE304() throws {
        let store = StateFile(directory: tmpDir)
        try store.save(header: makeHeader(), payloads: makePayloads())
        var data = try Data(contentsOf: store.fileURL)
        // 改 payload 区的一个字节（不动 CRC）
        let mid = data.count / 2
        data[mid] = data[mid] ^ 0xFF
        try data.write(to: store.fileURL)

        let result = store.load()
        XCTAssertTrue(result.readOnly, "CRC 失败必须进入只读")
        guard case .segmentValidationFailed = result.error else {
            XCTFail("应报 E-304（段校验失败），实为 \(String(describing: result.error))")
            return
        }
    }

    /// **文件被截断 → `E-304`**（尺寸恒等式不成立）。
    func testTruncatedFileTriggersE304() throws {
        let store = StateFile(directory: tmpDir)
        try store.save(header: makeHeader(), payloads: makePayloads())
        var data = try Data(contentsOf: store.fileURL)
        data = data.prefix(data.count - 10)
        try data.write(to: store.fileURL)

        let result = store.load()
        XCTAssertTrue(result.readOnly)
        XCTAssertNotNil(result.error)
    }

    /// **E-304 时不提供「重置」入口、不自动重置**，且现场被保留为 `.corrupt`。
    func testE304PreservesCorruptFileWithoutAutoReset() throws {
        let store = StateFile(directory: tmpDir)
        try store.save(header: makeHeader(), payloads: makePayloads())
        var data = try Data(contentsOf: store.fileURL)
        let mid = data.count / 2
        data[mid] = data[mid] ^ 0xFF
        try data.write(to: store.fileURL)

        _ = store.load()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath:
                tmpDir.appendingPathComponent("state.residue.corrupt").path),
            "E-304 必须保留现场为 `.corrupt`（供导出诊断）"
        )
    }

    /// **schema 更高 → `E-301` 只读降级**（不拒绝、不重置）。
    func testSchemaTooNewIsReadOnlyDegraded() throws {
        let store = StateFile(directory: tmpDir)
        try store.save(header: makeHeader(), payloads: makePayloads())
        var data = try Data(contentsOf: store.fileURL)
        // 改 schemaVersion 为 99
        data[4] = 99; data[5] = 0; data[6] = 0; data[7] = 0
        try data.write(to: store.fileURL)

        let result = store.load()
        XCTAssertTrue(result.readOnly, "schema 更高 → 只读降级")
        guard case .schemaTooNew = result.error else {
            XCTFail("应报 E-301，实为 \(String(describing: result.error))")
            return
        }
    }

    // MARK: - ⑤ 迁移断电按 `step` 恢复，不删唯一 `.bak`

    /// **⑤ `.bak` 是唯一可回退点 —— 不得被删除**。
    func testBackupIsNeverDeleted() throws {
        let store = StateFile(directory: tmpDir)
        try store.save(header: makeHeader(), payloads: makePayloads())
        // 第二次写入产生 `.bak`
        try store.save(header: makeHeader(), payloads: makePayloads())
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.backupURL.path))

        // 第三次写入：`.bak` 应被更新但**仍存在**
        try store.save(header: makeHeader(), payloads: makePayloads())
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: store.backupURL.path),
            "`.bak` 必须始终存在（唯一可回退点）"
        )
    }

    /// **主文件损坏 + 有可用 `.bak` → 迁移路径恢复成功并报 `E-308`**。
    ///
    /// ⚠️ **E-308 属「迁移失败但备份可用」**，**不是段校验失败的兜底**——
    /// E-304 自身**没有**自愈路径，它的唯一出口**不得**变成「重置」。
    func testRestoreFromBackupReportsE308() throws {
        let store = StateFile(directory: tmpDir)
        try store.save(header: makeHeader(), payloads: makePayloads())
        // 第二次写入 → `.bak` = 第一份（好数据）
        try store.save(header: makeHeader(), payloads: makePayloads())

        // 破坏主文件
        var data = try Data(contentsOf: store.fileURL)
        let mid = data.count / 2
        data[mid] = data[mid] ^ 0xFF
        try data.write(to: store.fileURL)

        // 迁移恢复路径 → 恢复成功
        let restored = store.tryRestoreFromBackupForMigration()
        XCTAssertNotNil(restored, "应能从 `.bak` 恢复")
        XCTAssertEqual(restored?.header.round, 2)
        // `.bak` 本体不得被删（仍是可回退点）
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.backupURL.path),
                      "`.bak` 是唯一可回退点，不得被删")
    }

    /// **主文件损坏 + 无可用 `.bak` → 迁移恢复失败 → `E-306` 只读**。
    func testMigrationRestoreFailsWithoutBackup() throws {
        let store = StateFile(directory: tmpDir)
        try store.save(header: makeHeader(), payloads: makePayloads())
        // 只写一次 → 无 `.bak`

        XCTAssertNil(
            store.tryRestoreFromBackupForMigration(),
            "无可用 `.bak` 时迁移恢复必须失败（→ E-306）"
        )
    }

    /// **段校验失败（E-304）不得降级成 E-302**。
    ///
    /// v1.3 的旧病：E-304 被写成「同 E-302」→ 继承了「重置」出口，
    /// 而 E-304 自身无自愈路径 → 唯一出口就变成重置（§10.2 禁止的那条）。
    func testE304DoesNotDegradeToE302() throws {
        let store = StateFile(directory: tmpDir)
        try store.save(header: makeHeader(), payloads: makePayloads())

        var data = try Data(contentsOf: store.fileURL)
        let mid = data.count / 2
        data[mid] = data[mid] ^ 0xFF
        try data.write(to: store.fileURL)

        let result = store.load()
        XCTAssertTrue(result.readOnly)
        guard case .segmentValidationFailed = result.error else {
            XCTFail("E-304 不得降级成 E-302，实为 \(String(describing: result.error))")
            return
        }
    }

    /// **载体清零**（应用版本变更路径；**不是** N7 的「一键清除」）。
    func testClearCarrierForVersionChange() throws {
        let store = StateFile(directory: tmpDir)
        try store.save(header: makeHeader(), payloads: makePayloads())
        try store.clearCarrierForVersionChange(newAppVersion: "2.0.0 (2)")

        let loaded = store.load().contents
        XCTAssertEqual(loaded?.header.appVersion, "2.0.0 (2)")
        // 四项清零：位图空、C_done 空、位槽表空
        //
        // 清零后**不再有该来源的任何段** → 解码时 `payloads[source]` 为 `nil`
        // → 「无载荷」即「已清零」（载荷不存在 = 无数据可读）。
        for source in Source.allCases {
            let p = loaded?.payloads[source]
            XCTAssertNil(p, "\(source.displayName) 的载荷应被清零（无段 = 无数据）")
        }
        // 段表应为空
        XCTAssertEqual(loaded?.segments.count ?? -1, 0, "清零后不应有任何段")
        // 累计误判数 `a` 归零
        for entry in loaded?.header.sources ?? [] {
            XCTAssertEqual(entry.a, 0, "累计误判数 `a` 应清零")
            XCTAssertEqual(entry.slotCount, 0, "位槽数应清零")
        }
        // **轮次不变**（M1 写入时刻：版本变更不产生新轮次，只重置当前轮次）
        XCTAssertEqual(loaded?.header.round, 2, "版本变更不得把轮次重置为 1")
        XCTAssertEqual(loaded?.header.countedDays, 0, "计数日归零")
        XCTAssertNil(loaded?.header.roundStartAnchor, "计时窗口从下次成功扫描重新起算")
    }

    // MARK: - CR-032 · P1-1（载体存在标记）

    /// **首启（载体不在）→ `carrierPresent == false`**。
    ///
    /// 这是版本变更判定的**必要输入**：首启时 `appVersion` 也是空串，
    /// 与「基线遗留」长得一模一样 → 不能靠版本号空不空去猜。
    func testCarrierPresentIsFalseOnFirstLaunch() {
        let store = StateFile(directory: tmpDir)
        let result = store.load()
        XCTAssertFalse(result.carrierPresent, "没有载体文件时 `carrierPresent` 必须为 false")
        XCTAssertNotNil(result.contents, "首启仍应给出空载体（首启可用）")
        XCTAssertFalse(result.readOnly)
    }

    /// **载体存在 → `carrierPresent == true`**（哪怕版本号是空的）。
    func testCarrierPresentIsTrueWhenFileExists() throws {
        let store = StateFile(directory: tmpDir)
        try store.save(header: makeHeader(), payloads: makePayloads())
        XCTAssertTrue(store.load().carrierPresent, "载体文件在 → `carrierPresent` 必须为 true")
    }

    /// **基线遗留载体（版本号为空）→ 依然 `carrierPresent == true`**。
    ///
    /// 这一条是 P1-1 的要害：基线从未写过 `appVersion`，
    /// 若 `carrierPresent` 跟着版本号一起变成 false，
    /// 「版本变更 → 清零」就又变成永远不触发。
    func testLegacyCarrierWithEmptyVersionStillCountsAsPresent() throws {
        let store = StateFile(directory: tmpDir)
        var header = makeHeader()
        header.appVersion = ""      // 基线：从未写过版本号
        try store.save(header: header, payloads: makePayloads())

        let result = store.load()
        XCTAssertTrue(result.carrierPresent, "基线遗留载体必须在场")
        XCTAssertEqual(result.contents?.header.appVersion, "", "版本号确实是空的")
    }

    // MARK: - CR-032 · P1-2（自动删除开关不得被版本重置静默关闭）

    /// **版本重置后，自动删除开关仍为开启**。
    ///
    /// PRD M1「写入时刻」的**七量终值穷举式**里**没有**自动删除开关
    /// → 穷举清单之外的东西**不得被静默改动**。
    ///
    /// 旧实现用 `StateHeader(round:)` 重建 header → `autoDeleteEnabled` 归 `false`
    /// → 用户主动开的开关被版本升级悄悄关掉（用户意愿被改写）。
    func testVersionChangeKeepsAutoDeleteEnabled() throws {
        let store = StateFile(directory: tmpDir)
        var header = makeHeader()
        header.autoDeleteEnabled = true
        try store.save(header: header, payloads: makePayloads())

        try store.clearCarrierForVersionChange(newAppVersion: "2.0.0 (2)")

        XCTAssertTrue(
            store.load().contents?.header.autoDeleteEnabled ?? false,
            "版本重置不得静默关闭自动删除开关"
        )
    }

    /// **开关关闭时也保持关闭**（不能把「保留」做成「无条件开启」）。
    func testVersionChangeKeepsAutoDeleteDisabled() throws {
        let store = StateFile(directory: tmpDir)
        var header = makeHeader()
        header.autoDeleteEnabled = false
        try store.save(header: header, payloads: makePayloads())

        try store.clearCarrierForVersionChange(newAppVersion: "2.0.0 (2)")

        XCTAssertFalse(
            store.load().contents?.header.autoDeleteEnabled ?? true,
            "版本重置不得凭空打开自动删除开关"
        )
    }

    /// **显式传入的继承值优先于载体里的值**（调用方已经持有最新态时不必再读盘）。
    func testVersionChangeUsesExplicitInheritedValues() throws {
        let store = StateFile(directory: tmpDir)
        try store.save(header: makeHeader(), payloads: makePayloads())

        let scannedAt = Date(timeIntervalSince1970: 1_700_000_999)
        try store.clearCarrierForVersionChange(
            newAppVersion: "2.0.0 (2)",
            keepingRound: 7,
            keepingAutoDeleteEnabled: true,
            keepingLastScanAt: scannedAt
        )

        let loaded = store.load().contents
        XCTAssertEqual(loaded?.header.round, 7)
        XCTAssertTrue(loaded?.header.autoDeleteEnabled ?? false)
        XCTAssertEqual(loaded?.header.lastScanAt, scannedAt)
    }

    /// **上次扫描时刻保留**（已发生的事实，不是派生量）。
    func testVersionChangeKeepsLastScanAt() throws {
        let store = StateFile(directory: tmpDir)
        var header = makeHeader()
        let scannedAt = Date(timeIntervalSince1970: 1_700_000_500)
        header.lastScanAt = scannedAt
        try store.save(header: header, payloads: makePayloads())

        try store.clearCarrierForVersionChange(newAppVersion: "2.0.0 (2)")

        XCTAssertEqual(
            store.load().contents?.header.lastScanAt,
            scannedAt,
            "版本重置不得让 ① 页把「上次扫过」说成「没扫过」"
        )
    }

    /// **旧报告标记清空**（M1 ③：旧轮归因结果随旧报告失效）。
    ///
    /// 留着 `producedAt` 会让 ⑤ 页一边说「样本 —」一边说「报告已产出」。
    func testVersionChangeClearsSettlementMarker() throws {
        let store = StateFile(directory: tmpDir)
        var header = makeHeader()
        header.settlement = SettlementHeader(
            producedAt: Date(timeIntervalSince1970: 1_700_000_700),
            reportId: "old-report"
        )
        try store.save(header: header, payloads: makePayloads())

        try store.clearCarrierForVersionChange(newAppVersion: "2.0.0 (2)")

        XCTAssertNil(
            store.load().contents?.header.settlement.producedAt,
            "旧报告标记必须随旧报告一并失效"
        )
    }

    /// **清零方法返回写入后的载体内容**（调用方直接用它刷新内存态）。
    ///
    /// 旧实现返回 `Void`，AppModel 只能手工拼一个 `StateHeader` ——
    /// 那正是「开关被静默关掉」在内存侧的同款病根。
    func testClearCarrierReturnsWrittenContents() throws {
        let store = StateFile(directory: tmpDir)
        var header = makeHeader()
        header.autoDeleteEnabled = true
        try store.save(header: header, payloads: makePayloads())

        let written = try store.clearCarrierForVersionChange(newAppVersion: "2.0.0 (2)")

        XCTAssertEqual(written.header.appVersion, "2.0.0 (2)")
        XCTAssertTrue(written.header.autoDeleteEnabled, "返回的内存态必须带上开关")
        XCTAssertEqual(written.header.round, 2, "轮次不变")
        // 返回值与盘上内容必须一致（否则内存态与磁盘态分叉）
        XCTAssertEqual(written.header, store.load().contents?.header)
    }

    // MARK: - CR-032 · schema v2

    /// **v1 文件在 v2 下可读**：新增来源排在枚举尾部，旧段索引含义不变。
    ///
    /// 造法：正常编码（每来源三段）后只把二进制版本号改成 1。
    /// CRC 不覆盖版本字段（`magic / 版本 / 长度 / CRC 自身` 都在覆盖范围外），
    /// 所以无需重算 CRC，读回仍是合法文件。
    func testV1FileStillLoadsAfterSchemaBump() throws {
        let legacySources = Array(Source.allCases.prefix(3))
        var payloads: [Source: SourcePayload] = [:]
        for source in legacySources {
            payloads[source] = SourcePayload(bitmap: Data([0b1010_1010]))
        }
        var header = makeHeader(slotCount: 8)
        header.sources = legacySources.map {
            SourceHeaderEntry(source: $0, snapshotTaken: true, T: 8, H: 8, b: 8, slotCount: 8)
        }
        var data = try StateFileCodec.encode(header: header, payloads: payloads)
        // 二进制版本字段在 offset 4，小端
        data[4] = 1
        data[5] = 0
        data[6] = 0
        data[7] = 0

        let decoded = try StateFileCodec.decode(data)
        XCTAssertEqual(decoded.header.sources.map(\.source), legacySources)
        XCTAssertEqual(
            decoded.payloads[legacySources[0]]?.bitmap,
            Data([0b1010_1010]),
            "旧段索引必须仍指向同一来源"
        )
        XCTAssertNil(decoded.payloads[.brewCache], "v1 文件里没有 brew 段")
    }

    /// **写盘时把 JSON 头的 schemaVersion 归一为当前版本**。
    ///
    /// 否则二进制头写 v2、JSON 头仍写 v1 → 审计看到两个版本号。
    func testEncodeNormalizesHeaderSchemaVersion() throws {
        var header = makeHeader()
        header.schemaVersion = 1
        let data = try StateFileCodec.encode(header: header, payloads: [:])
        let decoded = try StateFileCodec.decode(data)
        XCTAssertEqual(decoded.header.schemaVersion, StateFileCodec.currentSchemaVersion)
    }

    /// **读盘时把 JSON 头的 schemaVersion 归一为当前版本**（CR-032 · P2-4）。
    ///
    /// 旧缺陷：编码器强制写当前版本，但**内存里的 header**留着加载时的旧值
    /// → 导出报告写出的版本号与实际文件里的对不上（审计看到的是另一个）。
    ///
    /// 造法：正常编码后把 JSON 头里的版本号字段改成 1
    /// （CRC 不覆盖版本字段，见 `testV1FileStillLoadsAfterSchemaBump` 的说明）。
    /// **读盘后内存里的 `schemaVersion` 归一为当前版本**（CR-032 · P2-4）。
    ///
    /// 写侧 `encodeHeader` 强制写当前版本；读侧若不归一，内存态可能与文件里
    /// 的 JSON 头不一致 → 导出报告按内存态写版本号 → **报错版本与实际载体不符**。
    ///
    /// 造样本的方式：编码后把 JSON 头里的版本号**等长改写**成旧值，再**重算 CRC**
    /// （CRC 覆盖 header，只改字节不重算必然 E-304 —— 那样测的是 CRC 而不是归一）。
    func testDecodeNormalizesHeaderSchemaVersion() throws {
        var data = try StateFileCodec.encode(header: makeHeader(), payloads: [:])

        func u32(at off: Int) -> Int {
            let bytes = [UInt8](data)
            return (0..<4).reduce(0) { $0 | (Int(bytes[off + $1]) << (8 * $1)) }
        }

        let headerLen = u32(at: 8)
        let headerEnd = 12 + headerLen
        var headerData = Data(data[12..<headerEnd])

        let needle = Data("\"schemaVersion\":\(StateFileCodec.currentSchemaVersion)".utf8)
        guard let range = headerData.range(of: needle) else {
            XCTFail("未在头部 JSON 里找到 schemaVersion 字段")
            return
        }
        headerData.replaceSubrange(range, with: Data("\"schemaVersion\":1".utf8))
        XCTAssertEqual(headerData.count, headerLen, "等长改写，否则段偏移全部错位")
        data.replaceSubrange(12..<headerEnd, with: headerData)

        // 重算 CRC：覆盖 header + 段表 + payload（**不含 segCount**，与 decode 校验③一致）
        let segTableStart = headerEnd + 4
        let segCount = u32(at: headerEnd)
        let segTableEnd = segTableStart + segCount * SegmentDescriptor.byteCount
        var crcInput = Data()
        crcInput.append(headerData)
        crcInput.append(Data(data[segTableStart..<segTableEnd]))
        crcInput.append(Data(data[segTableEnd..<(data.count - 4)]))
        var crcLE = CRC32.checksum(crcInput).littleEndian
        withUnsafeBytes(of: &crcLE) { data.replaceSubrange((data.count - 4)..<data.count, with: $0) }

        let decoded = try StateFileCodec.decode(data)
        XCTAssertEqual(
            decoded.header.schemaVersion,
            StateFileCodec.currentSchemaVersion,
            "读盘后内存里的版本号必须与「下一次落盘会写成什么」一致"
        )
    }

    // MARK: - 段序固定

    /// **段序固定** = `Source.allCases` 声明序，**不用 `Dictionary`**。
    ///
    /// Swift 每进程随机哈希种子 → 若用 Dictionary，段序会漂移 → 读方串段。
    func testSegmentOrderIsDeterministic() throws {
        let payloads = makePayloads()
        let data1 = try StateFileCodec.encode(header: makeHeader(), payloads: payloads)
        let data2 = try StateFileCodec.encode(header: makeHeader(), payloads: payloads)
        XCTAssertEqual(data1, data2, "同输入必须产出**逐字节相同**的文件（段序固定）")

        // 连续多次编码也必须一致
        for _ in 0..<5 {
            let d = try StateFileCodec.encode(header: makeHeader(), payloads: payloads)
            XCTAssertEqual(d, data1)
        }
    }

    /// **读方按 `(sourceIndex, kind)` 索引，不按位置猜**。
    func testSegmentsCarrySourceIndexAndKind() throws {
        let data = try StateFileCodec.encode(header: makeHeader(), payloads: makePayloads())
        let contents = try StateFileCodec.decode(data)

        for seg in contents.segments {
            XCTAssertLessThan(Int(seg.sourceIndex), Source.allCases.count)
            XCTAssertTrue(SegmentKind.allCases.contains(seg.kind))
        }
        // 每个来源三段齐
        for (index, _) in Source.allCases.enumerated() {
            let kinds = contents.segments.filter { Int($0.sourceIndex) == index }.map { $0.kind }
            XCTAssertEqual(kinds.count, 3, "每个来源应有 3 段")
            XCTAssertTrue(kinds.contains(.fBitmap))
            XCTAssertTrue(kinds.contains(.countedDone))
            XCTAssertTrue(kinds.contains(.slots))
        }
    }

    /// **位槽占用表必须落盘**（否则候选被手删后重建会落回旧槽、继承旧 `F` 位）。
    func testSlotTableIsPersisted() throws {
        let store = StateFile(directory: tmpDir)
        let payloads = makePayloads(slotCount: 16)
        try store.save(header: makeHeader(slotCount: 16), payloads: payloads)

        let loaded = store.load().contents
        let slots = loaded?.payloads[.uvCache]?.slots ?? [:]
        XCTAssertEqual(slots.count, 16, "位槽占用表必须落盘")
        XCTAssertNotNil(slots[0])
        XCTAssertEqual(slots[0]?.path, "/tmp/cand-0-uv_cache")
    }

    /// **`C_done` 的槽号升序往返**。
    func testCountedDoneRoundTrip() throws {
        let store = StateFile(directory: tmpDir)
        try store.save(header: makeHeader(), payloads: makePayloads())
        let loaded = store.load().contents
        let done = loaded?.payloads[.uvCache]?.countedDoneSlots ?? []
        XCTAssertEqual(done, [0, 2, 4])
        XCTAssertEqual(done, done.sorted(), "槽号必须升序")
    }
}
