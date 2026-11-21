import XCTest
@testable import ResidueCore

// ============================================================
// 回收站占用 · 独立指标（CR-042）
//
// ## 这组测试守的是什么
//
// 1. **移到废纸篓后指标真的涨了** —— 否则「已移入废纸篓」只是个说法，
//    用户看不到回收站里还占着多少。
// 2. **缓存缺失时报未知，不是 0** —— `nil ≠ 0` 是核心不变量③：
//    没记录过（旧载体 / 首启）不等于「回收站是空的」。
// 3. **恢复 / 回滚要递减** —— 条目已经不在废纸篓里了，
//    指标还挂在上面就是虚高。
// 4. **指标范围只含本产品移入的条目** —— 用户自己清空废纸篓我们感知不到，
//    所以这永远是「本产品账」的下界，不是系统废纸篓的真实总量。
// ============================================================

final class TrashUsageTests: XCTestCase {

    private var root: URL!
    private var cacheDir: URL!
    private var trashDir: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("residue-usage-\(UUID().uuidString)", isDirectory: true)
        cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        trashDir = root.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFile(_ name: String, bytes: Int) throws -> CandidateID {
        let url = cacheDir.appendingPathComponent(name)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let bt = (attrs[.creationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        return CandidateID(path: url.path, birthtime: bt)
    }

    // MARK: - 需求 1：移到废纸篓后指标真的涨了

    func testMoveToTrashIncreasesUsage() throws {
        let recorder = TrashUsageRecorder()
        XCTAssertNil(recorder.usage, "没有任何记录时是未知，不是 0")

        let executor = TrashExecutor(trashDirectory: trashDir, usageRecorder: recorder)
        let first = try executor.moveToTrash(try makeFile("a.bin", bytes: 2048), source: .uvCache)

        let afterFirst = try XCTUnwrap(recorder.usage, "成功 move 后必须有记录")
        XCTAssertEqual(afterFirst.bytes, first.bytes)
        XCTAssertEqual(afterFirst.bytes, 2048)
        XCTAssertEqual(afterFirst.items, 1)

        let second = try executor.moveToTrash(try makeFile("b.bin", bytes: 1024), source: .uvCache)
        let afterSecond = try XCTUnwrap(recorder.usage)
        XCTAssertEqual(afterSecond.bytes, first.bytes + second.bytes)
        XCTAssertEqual(afterSecond.items, 2)
    }

    /// 被拦下的条目**没有进废纸篓**，不得让指标上涨。
    func testBlockedMoveDoesNotIncreaseUsage() throws {
        let recorder = TrashUsageRecorder()
        let executor = TrashExecutor(trashDirectory: trashDir, usageRecorder: recorder)

        let missing = CandidateID(
            path: cacheDir.appendingPathComponent("missing.bin").path,
            birthtime: Date(timeIntervalSince1970: 0)
        )
        XCTAssertThrowsError(try executor.moveToTrash(missing, source: .uvCache))
        XCTAssertNil(recorder.usage, "没移成功就不该有账")
    }

    // MARK: - 需求 3 的数据面：恢复要递减

    func testRestoreDecreasesUsage() throws {
        let recorder = TrashUsageRecorder()
        let executor = TrashExecutor(trashDirectory: trashDir, usageRecorder: recorder)
        let rec = try executor.moveToTrash(try makeFile("c.bin", bytes: 777), source: .npmNpx)
        XCTAssertEqual(recorder.usage?.items, 1)

        _ = try executor.restore(rec)

        let after = try XCTUnwrap(recorder.usage)
        XCTAssertEqual(after.bytes, 0)
        XCTAssertEqual(after.items, 0)
    }

    /// `t2` 实测超限 → 回滚成功 → 指标必须跟着退回去（否则虚高）。
    func testCapRollbackDecreasesUsage() throws {
        let recorder = TrashUsageRecorder()
        let executor = TrashExecutor(trashDirectory: trashDir, usageRecorder: recorder)
        let id = try makeFile("d.bin", bytes: 4096)

        // 预检值谎报 1 B → 通过预检；实测 4096 B 超上限 → 回滚。
        let outcome = executor.execute(
            candidates: [id],
            source: .uvCache,
            capacityCap: 100,
            countCap: 10,
            preflightBytes: [id: 1]
        )

        XCTAssertEqual(outcome.records.map(\.action), [.blockedCap])
        XCTAssertTrue(FileManager.default.fileExists(atPath: id.path), "应已移回原位")
        let after = try XCTUnwrap(recorder.usage)
        XCTAssertEqual(after.bytes, 0, "回滚后条目不在废纸篓，指标不得留着")
        XCTAssertEqual(after.items, 0)
    }

    /// 缓存本来就是未知（`nil`）时，恢复不能让未知变成 0 ——
    /// 我们不知道这条是不是账里的，不能假装知道。
    func testRestoreWithoutKnownUsageStaysUnknown() {
        let recorder = TrashUsageRecorder()
        recorder.recordRestored(bytes: 1234)
        XCTAssertNil(recorder.usage, "未知保持未知，不能凭空造一个 0")
    }

    // MARK: - 需求 2：缓存缺失时报未知，不是 0

    func testMissingCacheIsUnknownNotZero() {
        var model = PageModelBuilder.build(
            PageModelBuilder.Input(contents: StateFileContents(), trashUsage: nil)
        )
        XCTAssertTrue(model.trashUsageBytes.isUnavailable, "缓存缺失 → 未知")
        XCTAssertTrue(model.trashUsageItems.isUnavailable, "缓存缺失 → 未知")

        model = PageModelBuilder.build(
            PageModelBuilder.Input(
                contents: StateFileContents(),
                trashUsage: TrashUsage(bytes: 0, items: 0, updatedAt: Date())
            )
        )
        XCTAssertEqual(model.trashUsageBytes, .metric(0, unit: .bytes), "已知为空才是 0")
        XCTAssertEqual(model.trashUsageItems, .metric(0, unit: .items))
    }

    func testKnownUsageIsProjectedToSlots() {
        let usage = TrashUsage(bytes: 3_000_000, items: 7, updatedAt: Date())
        let model = PageModelBuilder.build(
            PageModelBuilder.Input(contents: StateFileContents(), trashUsage: usage)
        )
        XCTAssertEqual(model.trashUsageBytes, .metric(3_000_000, unit: .bytes))
        XCTAssertEqual(model.trashUsageItems, .metric(7, unit: .items))
    }

    // MARK: - 需求 2：扫描快照带上回收站占用

    func testScanResultCarriesTrashUsage() throws {
        let scanRoot = root.appendingPathComponent("scanroot", isDirectory: true)
        let uvDir = scanRoot.appendingPathComponent(".cache/uv", isDirectory: true)
        try FileManager.default.createDirectory(at: uvDir, withIntermediateDirectories: true)
        try Data(repeating: 0xCD, count: 32).write(to: uvDir.appendingPathComponent("pkg"))

        let engine = ScanEngine(
            fileSystem: ScanEngine.DefaultFileSystem(),
            rules: [ScanEngine.SourceRule(source: .uvCache, pathFragments: ["/.cache/uv/"])]
        )
        let usage = TrashUsage(bytes: 4096, items: 2, updatedAt: Date())
        let result = try engine.scan(root: scanRoot.path, mode: .full, trashUsage: usage)
        XCTAssertEqual(result.trashUsage, usage, "快照必须带上回收站占用")

        let unknown = try engine.scan(root: scanRoot.path, mode: .full)
        XCTAssertNil(unknown.trashUsage, "没给缓存 → 未知，不是 0")
    }

    // MARK: - 持久化：现有状态文件（不新开存储）

    func testStateHeaderRoundTripPreservesTrashUsage() throws {
        let usage = TrashUsage(bytes: 8192, items: 3, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        var header = StateHeader()
        header.trashUsage = usage

        let encoded = try StateFileCodec.encode(header: header, payloads: [:])
        let decoded = try StateFileCodec.decode(encoded)
        XCTAssertEqual(decoded.header.trashUsage, usage)
    }

    /// 旧载体没有这个键 → 解码为 `nil`（未知），**不得判损坏**。
    func testOldHeaderWithoutTrashUsageDecodesAsNil() throws {
        // 造一份「旧版本写的 header」：先编一份完整的，再把新键摘掉。
        var header = StateHeader()
        header.trashUsage = TrashUsage(bytes: 1, items: 1, updatedAt: Date())
        let full = try JSONEncoder().encode(header)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: full) as? [String: Any]
        )
        object.removeValue(forKey: "trashUsage")

        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(StateHeader.self, from: old)
        XCTAssertNil(decoded.trashUsage, "旧载体没有这个键 → 未知，不是 0")
    }

    /// 回写到**现有载体**后能读回来（AppModel 落盘路径的数据面）。
    func testUsagePersistsThroughStateFile() throws {
        let stateFile = StateFile(directory: root.appendingPathComponent("state", isDirectory: true))
        // `.iso8601` 只到秒 —— 用整秒时间，避免拿亚秒精度去比。
        let usage = TrashUsage(
            bytes: 2048,
            items: 1,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        var header = StateHeader()
        header.trashUsage = usage
        _ = try stateFile.save(header: header, payloads: [:])

        let loaded = try XCTUnwrap(stateFile.load().contents)
        XCTAssertEqual(loaded.header.trashUsage, usage)
    }
}
