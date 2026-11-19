import XCTest
@testable import ResidueCore

// ============================================================
// 断点落盘（`state/checkpoints.json`）· R2 §5.5 / §6 `E-106` / AC-20
//
// ## 为什么要有这组用例
//
// 引擎侧的断点机制（名字集合、续扫三项一致）**早就有测试**。
// 但从「引擎能生产断点」到「用户取消一次之后，重启还能接着扫」之间
// 缺了一整环：**断点从来没落过盘**。
//
// 这组用例守的就是那一环，重点是三条**静默失败**：
//   · 写坏了却回读通过 → 续扫依据不可信，`T` 静默偏小
//   · 日期策略不对称 → save 成功、load 永远失败（本仓库已踩过一次）
//   · 坏断点被「尽力解析」→ 字段错位，续扫漏条目且无任何报错
// ============================================================

final class CheckpointStoreTests: XCTestCase {

    private var dir: URL!
    private var store: CheckpointStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CheckpointStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = CheckpointStore(directory: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func makeCheckpoint() -> ScanEngine.Checkpoint {
        var cp = ScanEngine.Checkpoint()
        cp.markCompleted(dir: "/root/.cache/uv", name: "a")
        cp.markCompleted(dir: "/root/.cache/uv", name: "b")
        cp.markExpanded(dir: "/root/.cache/uv")
        cp.candidates = [
            ScanEngine.Candidate(
                path: "/root/.cache/uv/wheel.whl",
                birthtime: Date(timeIntervalSince1970: 1_700_000_000),
                bytes: 4096, isDirectory: false, source: "uv_cache"
            )
        ]
        cp.countedFiles = 2
        cp.fileCount = 2
        cp.byteCount = 4096
        cp.seenHash = "deadbeef"
        return cp
    }

    // MARK: - 往返

    /// **往返必须逐字段一致**（尤其 `birthtime`：它进不了断点的话，
    /// 续扫出来的候选身份键就变了 → 同一文件被当成两个）。
    func testRoundTripPreservesEveryField() throws {
        let cp = makeCheckpoint()
        try store.save(["uv_cache": cp])

        guard case .usable(let loaded) = store.load() else {
            return XCTFail("应读到可用断点")
        }
        XCTAssertEqual(loaded["uv_cache"], cp, "断点往返必须逐字段一致")
    }

    /// **日期策略对称**：不对称会 save 成功、load 永远失败，且完全静默。
    func testCandidateBirthtimeSurvivesRoundTrip() throws {
        try store.save(["uv_cache": makeCheckpoint()])
        guard case .usable(let loaded) = store.load(),
              let c = loaded["uv_cache"]?.candidates.first else {
            return XCTFail("应读到候选")
        }
        XCTAssertEqual(c.birthtime, Date(timeIntervalSince1970: 1_700_000_000),
                       "birthtime 是候选身份键的一半，丢了就会把同一文件当两个")
    }

    // MARK: - 无断点

    func testMissingFileIsNotAnError() {
        XCTAssertEqual(store.load().diagnostic, nil, "没有断点不是错误")
        if case .none = store.load() {} else { XCTFail("应为 .none") }
    }

    /// 保存空映射 = 清除（正常完成后的语义）。
    func testSavingEmptyMapClearsTheFile() throws {
        try store.save(["uv_cache": makeCheckpoint()])
        try store.save([:])
        if case .none = store.load() {} else { XCTFail("空映射应等同清除") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    // MARK: - E-106：坏断点不得被「尽力解析」

    func testCorruptBytesReportE106() throws {
        try Data("not json at all".utf8).write(to: store.fileURL)
        XCTAssertEqual(store.load().diagnostic, .e106, "坏断点 → E-106")
        if case .corrupt = store.load() {} else { XCTFail("应为 .corrupt") }
    }

    /// **格式版本不符也判 `E-106`**（不尝试按旧格式读 —— 字段语义变了
    /// 还硬读，续扫会静默少算）。
    func testSchemaVersionMismatchReportsE106() throws {
        let payload = CheckpointStore.Payload(schemaVersion: 999, checkpoints: ["uv_cache": makeCheckpoint()])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(payload).write(to: store.fileURL)

        XCTAssertEqual(store.load().diagnostic, .e106)
    }

    /// 结构对、内容空 → 不是错误，是「没有可续的断点」。
    func testEmptyMapIsNotCorrupt() throws {
        let payload = CheckpointStore.Payload(checkpoints: [:])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(payload).write(to: store.fileURL)
        if case .none = store.load() {} else { XCTFail("空映射应为 .none 而非损坏") }
    }

    // MARK: - 落点

    /// **落盘位置 = `state/checkpoints.json`**，且**不在** `.jsonl` 记录目录里
    /// （R2 §5.5：不计入 N7 计量；但计入 N7 的清除范围）。
    func testLandsUnderStateDirectory() {
        let defaultStore = CheckpointStore()
        XCTAssertTrue(defaultStore.fileURL.path.hasSuffix("/Residue/state/checkpoints.json"),
                      "应落在 state/checkpoints.json，实为 \(defaultStore.fileURL.path)")
    }

    // MARK: - 清除

    func testClearRemovesTheFile() throws {
        try store.save(["uv_cache": makeCheckpoint()])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
        store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path),
                       "断点含候选路径 → 清除必须落到实处")
    }
}
