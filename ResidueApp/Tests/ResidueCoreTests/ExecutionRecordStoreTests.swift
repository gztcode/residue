import Darwin
import XCTest
@testable import ResidueCore

// ============================================================
// 执行记录的落盘责任方（CR-045 · P-018 + P-031）
//
// ## 这组用例在守什么
//
// `TrashExecutor` 在返回前就把文件 `moveItem` 进了废纸篓 —— **删除动作已经发生**。
// 而恢复路径 `restorePath` **只有执行记录能提供**
// （`TrashExecutor.restore` 的入口就是 `guard let restorePath else throw .noRestorePath`）。
//
// 于是「执行记录写不下去」= **恢复入口永久消失**，
// 而原实现用 `try?` 把写盘失败吞掉，界面却照样报「已清理 N 条」——
// **用户被告知一切都好，恢复入口却没了**（P-018 + P-031 同一根因）。
//
// 这组用例把三条保证钉死：
// 1. **写盘失败绝不静默**：落盘结果分三档（已落盘 / 待补写 / 彻底丢失），逐档可区分。
// 2. **恢复信息不丢**：写失败的记录进待补写队列，`restorePath` 还在。
// 3. **补写幂等**：补过的不会重复补（重复的举证链行会污染 M6 计量）。
//
// ## 为什么用真文件系统
//
// 「写盘失败」这个故障**在内存里造不出来** —— 必须让真实的 `open(2)` / `rename(2)`
// 真的失败，测试才算数（CLAUDE.md §八：真文件系统相关缺陷只在真 FS 上暴露）。
// ============================================================

final class ExecutionRecordStoreTests: XCTestCase {

    private var dir: URL!
    private var recordsDirectory: URL!
    private var pendingURL: URL!
    private var writer: RecordWriter!
    private var store: ExecutionRecordStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExecutionRecordStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        recordsDirectory = dir.appendingPathComponent("records", isDirectory: true)
        pendingURL = dir
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("pending-execution.jsonl")
        writer = RecordWriter(directory: recordsDirectory)
        store = ExecutionRecordStore(writer: writer, pendingURL: pendingURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: - 造现场

    private func makeRecord(
        path: String = "/tmp/uv/cache/pkg.bin",
        action: ExecutionAction = .renameToTrash,
        restorePath: String? = "/Users/test/.Trash/pkg.bin",
        at: Date = Date(timeIntervalSince1970: 1_700_000_000),
        bytes: Int64 = 1024
    ) -> ExecutionRecord {
        ExecutionRecord(
            id: CandidateID(path: path, birthtime: at),
            source: .uvCache,
            action: action,
            originalPath: path,
            restorePath: restorePath,
            executedAt: at,
            bytes: bytes
        )
    }

    /// 造一个**写不进去**的目录（父路径是普通文件 ⇒ `createDirectory` 必失败）。
    @discardableResult
    private func blockDirectory(named name: String) throws -> URL {
        let blocker = dir.appendingPathComponent(name)
        try Data("not-a-directory".utf8).write(to: blocker)
        return blocker.appendingPathComponent("records", isDirectory: true)
    }

    // MARK: - 成功路径（行为不变）

    /// 成功路径：**行为不变** —— 记录写进 `execution.jsonl`，不产生待补写队列。
    func testPersistSuccessWritesRecordIntoExecutionLog() throws {
        let record = makeRecord()
        let result = store.persist([record])

        XCTAssertTrue(result.isClean, "全部落盘时不该报任何问题")
        XCTAssertEqual(result.deleted.persistedCount, 1)
        XCTAssertEqual(result.deleted.queuedCount, 0)
        XCTAssertEqual(result.deleted.lostCount, 0)

        let onDisk = try writer.readRecords(ExecutionRecord.self, kind: .execution)
        XCTAssertEqual(onDisk.count, 1)
        XCTAssertEqual(onDisk.first?.restorePath, record.restorePath, "恢复路径必须落盘")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: pendingURL.path),
            "成功路径不该留下待补写队列"
        )
    }

    /// 非删除类记录（拦下 / 失败）落盘后归「其余」档，**不占删除档的计数**。
    func testPersistKeepsNonDeletionRecordsOutOfTheDeletedBucket() throws {
        let blocked = makeRecord(path: "/tmp/uv/cache/b.bin", action: .blockedSecondCheck)
        let result = store.persist([blocked])

        XCTAssertTrue(result.isClean)
        XCTAssertEqual(result.other.persistedCount, 1)
        XCTAssertEqual(result.deleted.persistedCount, 0, "拦下记录不是删除")
    }

    // MARK: - 写盘失败（不许静默）

    /// 写盘失败 ⇒ 记录进**待补写队列**，**恢复路径不丢**。
    func testPersistFailureQueuesRecordAndKeepsRestorePath() throws {
        let blockedRecords = try blockDirectory(named: "blocked-records")
        let blockedStore = ExecutionRecordStore(
            writer: RecordWriter(directory: blockedRecords),
            pendingURL: pendingURL
        )
        let record = makeRecord()

        let result = blockedStore.persist([record])

        XCTAssertFalse(result.isClean, "写盘失败必须被报出来")
        XCTAssertEqual(result.deleted.persistedCount, 0, "没落盘就不许算「已清理」")
        XCTAssertEqual(result.deleted.queuedCount, 1, "写盘失败必须进待补写队列")
        XCTAssertEqual(result.deleted.lostCount, 0)

        let queued = try JSONLStore(url: pendingURL).readAll(ExecutionRecord.self)
        XCTAssertEqual(queued.count, 1, "队列里必须留着那条记录")
        XCTAssertEqual(
            queued.first?.restorePath,
            record.restorePath,
            "**恢复路径不能丢** —— 它是恢复入口的唯一依据"
        )
    }

    /// 连队列都写不进去 ⇒ **如实登记为「彻底丢失」**（不许假装还在队列里）。
    func testPersistFailureWhenQueueAlsoFailsIsReportedAsLost() throws {
        let blocker = try blockDirectory(named: "blocked-everything")
        let blockedStore = ExecutionRecordStore(
            writer: RecordWriter(directory: blocker),
            pendingURL: blocker.appendingPathComponent("state/pending-execution.jsonl")
        )

        let result = blockedStore.persist([makeRecord()])

        XCTAssertEqual(result.deleted.persistedCount, 0)
        XCTAssertEqual(result.deleted.queuedCount, 0)
        XCTAssertEqual(
            result.deleted.lostCount,
            1,
            "连队列都写不进去 ⇒ 必须如实登记为「恢复信息彻底丢失」"
        )
        XCTAssertFalse(result.isClean)
    }

    /// 部分成功：**能写的写了，写不进的进队列** —— 两档互不吞并。
    func testPersistSplitsPartialFailure() throws {
        try XCTSkipIf(getuid() == 0, "root 无视权限位，造不出写失败")

        let first = makeRecord(path: "/tmp/uv/cache/a.bin", at: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeRecord(path: "/tmp/uv/cache/b.bin", at: Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertEqual(store.persist([first]).deleted.persistedCount, 1)

        // 把日志文件改成只读 ⇒ 之后的追加必失败（`EACCES`）。
        let logURL = writer.url(for: .execution)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: logURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        }

        let result = store.persist([second])

        XCTAssertEqual(result.deleted.persistedCount, 0)
        XCTAssertEqual(result.deleted.queuedCount, 1, "写不进的必须进队列")
        XCTAssertEqual(result.deleted.lostCount, 0)
        let queued = try JSONLStore(url: pendingURL).readAll(ExecutionRecord.self)
        XCTAssertEqual(queued.map(\.originalPath), ["/tmp/uv/cache/b.bin"])
    }

    // MARK: - 补写（恢复信息回到举证链）

    /// 补写：上次写失败的记录**回到 `execution.jsonl`**（恢复入口恢复可用）。
    func testDrainWritesQueuedRecordBackIntoExecutionLog() throws {
        let blockedRecords = try blockDirectory(named: "blocked-records")
        let record = makeRecord()
        _ = ExecutionRecordStore(
            writer: RecordWriter(directory: blockedRecords),
            pendingURL: pendingURL
        ).persist([record])

        let load = store.loadAndDrain()

        XCTAssertEqual(load.drain.recoveredCount, 1, "队列里的记录必须补写回去")
        XCTAssertTrue(load.drain.isClean)
        let onDisk = try writer.readRecords(ExecutionRecord.self, kind: .execution)
        XCTAssertEqual(onDisk.count, 1)
        XCTAssertEqual(onDisk.first?.restorePath, record.restorePath, "补写必须带回恢复路径")
        XCTAssertEqual(load.records.count, 1, "补写进来的记录必须一并回填")
        let stillQueued = try JSONLStore(url: pendingURL).readAll(ExecutionRecord.self)
        XCTAssertTrue(stillQueued.isEmpty, "补写成功后队列必须清空")
    }

    /// 补写**幂等**：补过的不会重复补（重复的举证链行会污染 M6 计量）。
    func testDrainIsIdempotent() throws {
        let blockedRecords = try blockDirectory(named: "blocked-records")
        _ = ExecutionRecordStore(
            writer: RecordWriter(directory: blockedRecords),
            pendingURL: pendingURL
        ).persist([makeRecord()])

        _ = store.loadAndDrain()
        let second = store.loadAndDrain()

        XCTAssertEqual(second.drain.recoveredCount, 0, "补写必须幂等")
        let onDisk = try writer.readRecords(ExecutionRecord.self, kind: .execution)
        XCTAssertEqual(onDisk.count, 1, "同一条记录不许写两行")
    }

    /// `execution.jsonl` 读不出来 ⇒ **不补写**（无从判断是否已补写过），
    /// 且**队列不许被清空** —— 恢复信息还在，下次启动再试。
    func testDrainKeepsRecordsWhenExecutionLogUnreadable() throws {
        let blockedRecords = try blockDirectory(named: "blocked-records")
        _ = ExecutionRecordStore(
            writer: RecordWriter(directory: blockedRecords),
            pendingURL: pendingURL
        ).persist([makeRecord()])

        // 把日志文件变成目录 ⇒ `Data(contentsOf:)` 读不出来。
        try FileManager.default.createDirectory(
            at: writer.url(for: .execution),
            withIntermediateDirectories: true
        )

        let load = store.loadAndDrain()

        XCTAssertEqual(load.drain.failure, .logUnreadable)
        XCTAssertEqual(load.drain.remainingCount, 1, "补不成就必须留在队列里")
        let queued = try JSONLStore(url: pendingURL).readAll(ExecutionRecord.self)
        XCTAssertEqual(queued.count, 1, "队列里的恢复路径不许丢")
    }

    /// 队列里有**解不开的行** ⇒ 如实计数，**不许悄悄丢掉**（它可能含恢复路径）。
    func testDrainCountsUnparsablePendingLinesWithoutDroppingThem() throws {
        try FileManager.default.createDirectory(
            at: pendingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{ not json\n".utf8).write(to: pendingURL)

        let load = store.loadAndDrain()

        XCTAssertEqual(load.drain.corruptLineCount, 1, "解不开的行必须如实计数")
        XCTAssertFalse(load.drain.isClean)
        let raw = try JSONLStore(url: pendingURL).rawLines()
        XCTAssertEqual(raw.count, 1, "解不开的行必须原样留在队列里")
    }

    // MARK: - 落点

    /// 待补写队列落 `state/`（**不计入 M6 计量**），不进 `records/`。
    func testPendingQueueLivesUnderStateDirectory() {
        let url = StateFile.pendingExecutionURL(in: dir)
        XCTAssertEqual(url.lastPathComponent, "pending-execution.jsonl")
        XCTAssertEqual(
            url.deletingLastPathComponent().lastPathComponent,
            "state",
            "待补写队列必须落 `state/`（`records/` 下的 `.jsonl` 计入 M6 计量）"
        )
    }

    /// 待补写队列**不计入 M6 的「可回收字节」**（它不是垃圾，是还没写出去的恢复信息）。
    func testPendingQueueIsNotCountedAsRecoverableBytes() throws {
        try FileManager.default.createDirectory(
            at: pendingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(String(repeating: "x", count: 4096).utf8).write(to: pendingURL)

        XCTAssertEqual(
            try writer.totalJSONLBytes(),
            0,
            "待补写队列落在 `state/` ⇒ 不计入 `records/` 的字节合计"
        )
    }
}
