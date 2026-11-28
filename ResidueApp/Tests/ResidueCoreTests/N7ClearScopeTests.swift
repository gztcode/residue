import XCTest
@testable import ResidueCore

// ============================================================
// N7「一键清除采集物与日志」的作用域 · PRD v5.6 N7 / 偏差 3 · R2 v1.10 §10.3
//
// ## 为什么要有这组用例
//
// 契约要求「一键清除」清掉**运行期态与备份**，代码却只删了 `records/`：
// `journal.jsonl` / `checkpoints.json` / `migrating.json` / `*.bak` /
// `*.corrupt` / `*.tmp` 全都留在盘上 ——
// 「清除后仍留用户路径副本」（质量 B-07），且 R2 评审单**阻塞项 10**。
//
// 这组用例同时守住另一条**不能碰**的边界：
// **主载体 `state.residue` 不在清除范围内** —— 它存着 `a`（误判记录），
// 清掉它等于给用户开一条「一键洗掉误判记录」的旁路（不变量④ · S2）。
// ============================================================

final class N7ClearScopeTests: XCTestCase {

    private var dir: URL!
    private var stateFile: StateFile!
    private var checkpoints: CheckpointStore!
    private var recordsDirectory: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("N7ClearScopeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stateFile = StateFile(directory: dir)
        checkpoints = CheckpointStore(
            directory: dir.appendingPathComponent("state", isDirectory: true)
        )
        recordsDirectory = dir.appendingPathComponent("records", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: - 造现场

    /// 造出契约点名的**全部**在范围内的文件（外加主载体）。
    @discardableResult
    private func seedEverything() throws -> [URL] {
        let fm = FileManager.default
        var made: [URL] = []

        try fm.createDirectory(at: recordsDirectory, withIntermediateDirectories: true)
        for name in ["execution.jsonl", "scan.jsonl", "evidence.jsonl"] {
            let url = recordsDirectory.appendingPathComponent(name)
            try Data("{}".utf8).write(to: url)
            made.append(url)
        }

        try fm.createDirectory(
            at: dir.appendingPathComponent("state", isDirectory: true),
            withIntermediateDirectories: true
        )
        for url in [stateFile.journalURL, checkpoints.fileURL, stateFile.migrationProgressURL] {
            try Data("{}".utf8).write(to: url)
            made.append(url)
        }
        for url in [stateFile.backupURL, stateFile.tempURL, stateFile.corruptURL] {
            try Data("x".utf8).write(to: url)
            made.append(url)
        }

        // CR-045：待补写队列（**含用户路径副本** ⇒ 必须在清除范围内）
        try Data("{}".utf8).write(to: stateFile.pendingExecutionURL)
        made.append(stateFile.pendingExecutionURL)
        try Data("x".utf8).write(to: JSONLStore.temporaryURL(for: stateFile.pendingExecutionURL))
        made.append(JSONLStore.temporaryURL(for: stateFile.pendingExecutionURL))

        // 主载体（`a` 的载体）—— **不在**清除范围内
        try Data("carrier".utf8).write(to: stateFile.fileURL)
        made.append(stateFile.fileURL)
        return made
    }

    // MARK: - 范围

    /// 契约逐项列举的范围**一个都不能少**（R2 §10.3）。
    func testScopeContainsEveryContractItem() throws {
        try seedEverything()
        let scope = N7ClearScope.paths(
            stateFile: stateFile,
            checkpoints: checkpoints,
            recordsDirectory: recordsDirectory
        )
        let expected: [URL] = [
            recordsDirectory,
            stateFile.journalURL,
            checkpoints.fileURL,
            stateFile.migrationProgressURL,
            stateFile.backupURL,
            stateFile.tempURL,
            stateFile.corruptURL,
            stateFile.pendingExecutionURL,
            JSONLStore.temporaryURL(for: stateFile.pendingExecutionURL)
        ]
        for expected in expected {
            XCTAssertTrue(
                scope.contains(expected),
                "清除范围漏了 \(expected.lastPathComponent)"
            )
        }
    }

    /// CR-045：待补写队列（`state/pending-execution.jsonl`）**含用户路径副本**
    /// ⇒ 必须进清除范围（漏清即等于「清除后仍留用户路径副本」—— 质量 B-07）。
    func testScopeContainsPendingExecutionQueue() {
        let scope = N7ClearScope.paths(
            stateFile: stateFile,
            checkpoints: checkpoints,
            recordsDirectory: recordsDirectory
        )
        XCTAssertTrue(
            scope.contains(stateFile.pendingExecutionURL),
            "待补写队列漏清 ⇒ 清除后仍留用户路径副本"
        )
        XCTAssertTrue(
            scope.contains(JSONLStore.temporaryURL(for: stateFile.pendingExecutionURL)),
            "待补写队列的临时文件也漏清了"
        )
    }

    /// **主载体不在范围内**（不变量④ · S2 · PRD 偏差 3）。
    func testScopeExcludesCarrierItself() throws {
        try seedEverything()
        let scope = N7ClearScope.paths(
            stateFile: stateFile,
            checkpoints: checkpoints,
            recordsDirectory: recordsDirectory
        )
        XCTAssertFalse(
            scope.contains(stateFile.fileURL),
            "`state.residue` 存着 `a`，清掉它等于开了一条洗掉误判记录的旁路"
        )
    }

    // MARK: - 执行

    /// 范围内的东西**全被清掉**，主载体**活着**。
    func testClearRemovesRuntimeStateAndKeepsCarrier() throws {
        try seedEverything()
        let carrierBefore = try Data(contentsOf: stateFile.fileURL)

        N7ClearScope.clear(
            stateFile: stateFile,
            checkpoints: checkpoints,
            recordsDirectory: recordsDirectory
        )

        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: recordsDirectory.path), "记录目录没清掉")
        for url in [
            stateFile.journalURL,
            checkpoints.fileURL,
            stateFile.migrationProgressURL,
            stateFile.backupURL,
            stateFile.tempURL,
            stateFile.corruptURL,
            stateFile.pendingExecutionURL,
            JSONLStore.temporaryURL(for: stateFile.pendingExecutionURL)
        ] {
            XCTAssertFalse(fm.fileExists(atPath: url.path), "\(url.lastPathComponent) 没清掉")
        }
        XCTAssertTrue(fm.fileExists(atPath: stateFile.fileURL.path), "主载体被清了 —— 违反不变量④")
        XCTAssertEqual(try Data(contentsOf: stateFile.fileURL), carrierBefore, "主载体内容被改了")
    }

    /// 主载体不在时，`.corrupt` 是 `a` 的**唯一幸存副本** ⇒ **保留**。
    func testClearKeepsCorruptWhenCarrierMissing() throws {
        try seedEverything()
        try FileManager.default.removeItem(at: stateFile.fileURL)

        N7ClearScope.clear(
            stateFile: stateFile,
            checkpoints: checkpoints,
            recordsDirectory: recordsDirectory
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: stateFile.corruptURL.path),
            "主载体没了，`.corrupt` 就是 `a` 的唯一副本，不能清"
        )
    }

    /// 跑一遍没造过任何文件的目录 ⇒ 不报错、不删任何东西（幂等）。
    func testClearOnEmptyDirectoryIsNoop() {
        let removed = N7ClearScope.clear(
            stateFile: stateFile,
            checkpoints: checkpoints,
            recordsDirectory: recordsDirectory
        )
        XCTAssertTrue(removed.isEmpty, "空目录不该报出删掉了东西")
    }
}
