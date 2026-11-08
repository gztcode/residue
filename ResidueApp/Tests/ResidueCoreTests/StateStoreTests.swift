import XCTest
@testable import ResidueCore

/// 状态存储层单测：落点、清零边界、损坏恢复。
final class StateStoreTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("residue-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func id(_ p: String, _ t: TimeInterval = 0) -> CandidateID {
        CandidateID(path: p, birthtime: Date(timeIntervalSince1970: t))
    }

    func testSaveAndLoadRoundTrip() throws {
        let store = StateStore(directory: tmpDir)
        var st = PersistedAppState(progress: ObservationProgress(round: 2, startAnchor: Date(), countedDays: 5))
        st.appVersion = "1.0"
        st.sources[.uvCache] = PersistedSourceState(
            source: .uvCache,
            l0: {
                var bm = NegativeBitmap()
                bm.set(7)
                return SourceL0State(
                    negativeSeen: bm,
                    countedDone: [],
                    slotTable: { var t = SlotTable(); _ = t.slot(for: id("/a")); return t }(),
                    missCount: 0
                )
            }(),
            checkCountThisRound: 42
        )
        try store.save(st)
        let loaded = store.load()
        XCTAssertEqual(loaded.progress.round, 2)
        XCTAssertEqual(loaded.progress.countedDays, 5)
        XCTAssertEqual(loaded.sources[.uvCache]?.checkCountThisRound, 42)
        XCTAssertNotNil(loaded.sources[.uvCache]?.l0.slotTable.slotIfAssigned(for: id("/a")))
    }

    func testLoadMissingFileReturnsInitialState() {
        let store = StateStore(directory: tmpDir)
        let st = store.load()
        XCTAssertEqual(st.progress.round, 1)
        XCTAssertFalse(st.autoDeleteEnabled)
        XCTAssertTrue(st.sources.isEmpty)
    }

    func testCorruptFileIsBackedUpNotSilentlyDropped() throws {
        let store = StateStore(directory: tmpDir)
        try Data("not json at all".utf8).write(to: store.fileURL)
        let st = store.load()
        XCTAssertEqual(st.progress.round, 1, "损坏时应回落初始态")
        let backups = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
            .filter { $0.hasPrefix("state.corrupt-") }
        XCTAssertEqual(backups.count, 1, "损坏文件应改名保留供诊断，不静默丢弃")
    }

    // MARK: - 清零边界（契约 M4）

    func testVersionChangeClearsWholeCarrier() throws {
        let store = StateStore(directory: tmpDir)
        var st = PersistedAppState(progress: ObservationProgress(round: 3, startAnchor: Date(), countedDays: 9))
        st.appVersion = "1.0"
        st.sources[.uvCache] = PersistedSourceState(
            source: .uvCache,
            l0: {
                var bm = NegativeBitmap()
                bm.set(1); bm.set(2)
                return SourceL0State(
                    negativeSeen: bm,
                    countedDone: [id("/a")],
                    slotTable: { var t = SlotTable(); _ = t.slot(for: id("/a")); _ = t.slot(for: id("/b")); return t }(),
                    missCount: 1
                )
            }(),
            checkCountThisRound: 128
        )

        let didReset = store.resetIfVersionChanged(state: &st, currentVersion: "1.1")

        XCTAssertTrue(didReset)
        XCTAssertEqual(st.sources[.uvCache]?.l0.missCount, 0, "版本变更 a 清零")
        XCTAssertEqual(st.sources[.uvCache]?.l0.negativeSeen.capacityBits, 0, "F 位图清零")
        XCTAssertTrue(st.sources[.uvCache]?.l0.countedDone.isEmpty ?? false, "C_done 清零")
        XCTAssertEqual(st.sources[.uvCache]?.l0.slotTable.count, 0, "位槽占用表清零")
        XCTAssertEqual(st.sources[.uvCache]?.checkCountThisRound, 0, "b 清零")
        XCTAssertEqual(st.progress.round, 3, "版本变更不产生新轮次")
        XCTAssertEqual(st.appVersion, "1.1")
    }

    func testSameVersionDoesNotReset() throws {
        let store = StateStore(directory: tmpDir)
        var st = PersistedAppState()
        st.appVersion = "1.0"
        st.sources[.uvCache] = PersistedSourceState(
            source: .uvCache,
            l0: SourceL0State(missCount: 1)
        )
        let didReset = store.resetIfVersionChanged(state: &st, currentVersion: "1.0")
        XCTAssertFalse(didReset)
        XCTAssertEqual(st.sources[.uvCache]?.l0.missCount, 1, "同版本不得清零")
    }

    func testRoundSwitchKeepsMissAndNegativeButClearsCounters() {
        // 契约：轮次切换时 F / C_done / a 三者均不清零；计数日与 b 随轮归零
        var st = PersistedAppState(progress: ObservationProgress(round: 1, startAnchor: Date(), countedDays: 14))
        st.sources[.uvCache] = PersistedSourceState(
            source: .uvCache,
            l0: {
                var t = SlotTable()
                let slot = t.slot(for: id("/a"))
                var bm = NegativeBitmap()
                bm.set(slot)
                return SourceL0State(
                    negativeSeen: bm,
                    countedDone: [id("/a")],
                    slotTable: t,
                    missCount: 1
                )
            }(),
            checkCountThisRound: 128
        )

        st.beginNextRound()

        XCTAssertEqual(st.progress.round, 2)
        XCTAssertEqual(st.progress.countedDays, 0, "计数日归零")
        XCTAssertNil(st.progress.startAnchor, "起算点待重锚")
        XCTAssertEqual(st.sources[.uvCache]?.checkCountThisRound, 0, "b 随轮归零")
        XCTAssertEqual(st.sources[.uvCache]?.l0.missCount, 1, "a 跨轮保留（错 1 次永久）")
        XCTAssertTrue(st.sources[.uvCache]?.l0.hasBeenJudgedClean(id("/a")) ?? false, "F 跨轮保留")
        XCTAssertEqual(st.sources[.uvCache]?.l0.countedDone, [id("/a")], "C_done 跨轮保留")
    }

    func testStateDirectoryIsNotJSONLRecordDirectory() {
        // 契约：载体落应用状态目录，**不属 N7 的 .jsonl 记录目录**
        let dir = StateStore.defaultDirectory()
        XCTAssertTrue(dir.path.contains("Application Support"), "应在应用状态目录")
        XCTAssertTrue(dir.path.hasSuffix("Residue"), "应在 Residue 子目录")
        XCTAssertFalse(dir.path.contains(".jsonl"), "不应落在记录目录")
        let store = StateStore(directory: dir)
        XCTAssertEqual(store.fileURL.lastPathComponent, "state.json")
    }
}
