import XCTest
@testable import ResidueCore

/// A-8 测试：上游只读命令白名单（AC-19）+ 记录落盘（§5.4）。
///
/// A-8 验收口径（K2 台账）：
/// ① 每次上游调用落一行
/// ② 未落盘 → 验收按「无法证明」不通过
final class UpstreamAndRecordTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("residue-rec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // ========================================================================
    // MARK: - AC-19 白名单（全称命题：任何删文件命令必须被拒）
    // ========================================================================

    /// **所有已知的「直接删文件」上游命令必须被拒。**
    ///
    /// 这是 AC-19 的核心：`直接删文件的上游命令出现次数 = 0`。
    /// 白名单是**封闭**的——不在其中即拒，故这条是**全称**而不是枚举。
    func testAllDestructiveCommandsAreRejected() {
        let destructive: [(String, [String])] = [
            ("uv", ["cache", "clean"]),
            ("uv", ["cache", "prune"]),
            ("npm", ["cache", "clean", "--force"]),
            ("brew", ["cleanup"]),
            ("brew", ["cleanup", "--prune=all"]),
            ("pip", ["cache", "purge"]),
            ("pip3", ["cache", "purge"]),
            ("python3", ["-m", "pip", "cache", "purge"]),
            ("rm", ["-rf", "/tmp/x"]),
            ("trash-put", ["/tmp/x"]),
            ("mv", ["/tmp/a", "/tmp/b"]),
            ("z-clean", ["audit"]),
            ("find", ["/tmp", "-delete"]),
            ("sh", ["-c", "rm -rf /tmp/x"]),
        ]
        for (exe, args) in destructive {
            let reason = UpstreamWhitelist.rejectionReason(executable: exe, args: args)
            XCTAssertNotNil(reason, "`\(exe) \(args.joined(separator: " "))` 必须被拒（AC-19）")
        }
    }

    /// **只读定位 / 举证命令必须放行**（否则产品取不到缓存目录）。
    func testReadOnlyCommandsAreAllowed() {
        let allowed: [(String, [String])] = [
            ("uv", ["cache", "dir"]),
            ("npm", ["cache", "ls"]),
            ("npm", ["config", "get", "cache"]),
            ("brew", ["--cache"]),
            ("pipx", ["list"]),
            ("pipx", ["environment"]),
            // CR-032：pip 缓存定位三形态（只读）
            ("pip", ["cache", "dir"]),
            ("pip3", ["cache", "dir"]),
            ("python3", ["-m", "pip", "cache", "dir"]),
        ]
        for (exe, args) in allowed {
            XCTAssertNil(
                UpstreamWhitelist.rejectionReason(executable: exe, args: args),
                "`\(exe) \(args.joined(separator: " "))` 是只读命令，应放行"
            )
        }
    }

    /// **同一可执行、不同参数要区分开**——只按可执行名放行会把 `cache clean` 也放行。
    ///
    /// `uv cache dir` 放行、`uv cache clean` 必须拒。
    func testSameExecutableDifferentArgsAreDistinguished() {
        XCTAssertNil(UpstreamWhitelist.rejectionReason(executable: "uv", args: ["cache", "dir"]))
        XCTAssertNotNil(UpstreamWhitelist.rejectionReason(executable: "uv", args: ["cache", "clean"]))
        XCTAssertNotNil(UpstreamWhitelist.rejectionReason(executable: "uv", args: ["cache", "prune"]))

        XCTAssertNil(UpstreamWhitelist.rejectionReason(executable: "npm", args: ["cache", "ls"]))
        XCTAssertNotNil(UpstreamWhitelist.rejectionReason(executable: "npm", args: ["cache", "clean"]))
    }

    /// **参数前缀必须**从头**匹配**——不能因为「参数里含有 `cache dir`」就放行。
    ///
    /// 否则 `uv --force cache dir` 这种变体会被当成只读命令放行。
    func testPrefixMustMatchFromStart() {
        XCTAssertNotNil(
            UpstreamWhitelist.rejectionReason(executable: "uv", args: ["--verbose", "cache", "dir"]),
            "前缀必须从头匹配，`--verbose cache dir` 不是白名单条目"
        )
    }

    /// **绝对路径也要能识别**（`/opt/homebrew/bin/uv` 与 `uv` 等价）。
    func testAbsolutePathIsNormalized() {
        XCTAssertNil(
            UpstreamWhitelist.rejectionReason(
                executable: "/opt/homebrew/bin/uv", args: ["cache", "dir"]
            ),
            "绝对路径的 `uv` 也应命中白名单"
        )
        XCTAssertNotNil(
            UpstreamWhitelist.rejectionReason(
                executable: "/opt/homebrew/bin/uv", args: ["cache", "clean"]
            ),
            "绝对路径的 `uv cache clean` 也必须拒"
        )
    }

    // ========================================================================
    // MARK: - ① 每次上游调用落一行
    // ========================================================================

    /// **被白名单拒绝的调用也要产生一条记录**（不能静默丢弃）。
    ///
    /// 若拒绝时不留痕，「有人试图跑删除命令」这件事就查不出来。
    func testRejectedCallStillProducesRecord() {
        let runner = UpstreamRunner()
        let outcome = runner.run(executable: "uv", args: ["cache", "clean"])

        XCTAssertTrue(outcome.record.rejectedByWhitelist, "应标记为被白名单拒绝")
        XCTAssertNil(outcome.record.exitCode, "被拒的调用不应有退出码（未真正执行）")
        XCTAssertNotNil(outcome.record.failure, "被拒必须给出原因")
        XCTAssertNil(outcome.stdout)
    }

    /// **可执行不存在时也有记录**（能力缺失 → P4「无法判定」，不挂 AC-14）。
    func testMissingExecutableProducesRecord() {
        let runner = UpstreamRunner()
        let outcome = runner.run(
            executable: "pipx", args: ["list"],
            searchPath: ["/nonexistent-dir-\(UUID().uuidString)"]
        )
        XCTAssertFalse(outcome.record.rejectedByWhitelist, "白名单内，只是找不到可执行")
        XCTAssertNil(outcome.record.exitCode)
        XCTAssertNotNil(outcome.record.failure)
        XCTAssertTrue(outcome.record.failure?.contains("未找到") ?? false)
    }

    /// **总预算耗尽时拒绝执行**（N6：总探测 ≤ 10 s）。
    func testTotalBudgetExhaustionRejects() {
        let runner = UpstreamRunner(perProbeTimeout: 2.0, totalBudget: 3.0, consumed: 4.0)
        let outcome = runner.run(executable: "uv", args: ["cache", "dir"])
        XCTAssertNil(outcome.record.exitCode)
        XCTAssertNotNil(outcome.record.failure)
        XCTAssertTrue(outcome.record.failure?.contains("总预算") ?? false)
    }

    /// **总预算必须跨调用累加**（N6：总探测 ≤ 10 s）。
    ///
    /// 这曾是静默缺陷：`UpstreamRunner` 是 `struct`，`consumed` 构造后永不增加，
    /// `consumed + 2 > 10` 恒为假 → 总预算形同虚设。
    /// 用**自造的可执行**（临时目录里一个名为 `uv` 的脚本）做真执行，
    /// 不依赖本机装没装 uv / brew / pip。
    func testBudgetAccumulatesAcrossCalls() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("residue-upstream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fakeUV = dir.appendingPathComponent("uv")
        try "#!/bin/sh\nsleep 0.05\nexit 0\n".write(to: fakeUV, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeUV.path
        )

        // 单探测预算 = 总预算：第一次恰好卡在边界内放行，之后必须被累计耗时挡住。
        let runner = UpstreamRunner(perProbeTimeout: 2.0, totalBudget: 2.0)
        let first = runner.run(executable: "uv", args: ["cache", "dir"], searchPath: [dir.path])
        XCTAssertNil(first.record.failure, "第一次调用应在预算内正常执行")
        XCTAssertGreaterThan(runner.consumedTime, 0, "调用耗时必须计入 consumedTime")

        let second = runner.run(executable: "uv", args: ["cache", "dir"], searchPath: [dir.path])
        XCTAssertNil(second.record.exitCode, "预算耗尽后不得再执行")
        XCTAssertTrue(
            second.record.failure?.contains("总预算") ?? false,
            "第二次调用应因累计超预算被拒，实为：\(second.record.failure ?? "nil")"
        )
    }

    /// **预算是「每次扫描」的，不是「进程生命周期」的**（CR-032 · P1-3）。
    ///
    /// N6 写的是「总探测 ≤ 10 s」——**一次扫描**的总探测。
    /// 若同一个 runner 被复用（`AppModel` 曾持有单例），预算会**跨扫描累计**：
    /// 第一次扫描用掉 9 s → 第二次扫描只剩 1 s → 第三次起全部探测被拒
    /// → 探测失败回退默认路径 → 用户自定义的缓存目录被静默当成 0
    /// → **来源静默退出判定域**。
    ///
    /// 本测试锁住「新建 runner = 预算归零」这一语义。
    func testFreshRunnerStartsWithFullBudget() {
        let exhausted = UpstreamRunner(perProbeTimeout: 2.0, totalBudget: 2.0, consumed: 4.0)
        XCTAssertNotNil(
            exhausted.run(executable: "uv", args: ["cache", "dir"]).record.failure,
            "预算耗尽的 runner 必须拒绝执行"
        )

        let fresh = UpstreamRunner(perProbeTimeout: 2.0, totalBudget: 2.0)
        XCTAssertEqual(fresh.consumedTime, 0, "新建 runner 的预算必须是满的")
        XCTAssertEqual(
            fresh.consumedTime, 0,
            "预算不跨 runner 累计（否则第二次扫描起全部探测被拒）"
        )
    }

    /// **两个 runner 之间预算互不影响**（各自独立计账）。
    func testBudgetIsPerRunnerNotGlobal() {
        let a = UpstreamRunner(perProbeTimeout: 2.0, totalBudget: 2.0, consumed: 1.9)
        let b = UpstreamRunner(perProbeTimeout: 2.0, totalBudget: 2.0)
        XCTAssertEqual(b.consumedTime, 0, "B runner 不得继承 A runner 的消耗")
        XCTAssertNotNil(
            a.run(executable: "uv", args: ["cache", "dir"]).record.failure,
            "A runner 接近上限时应拒绝"
        )
    }

    /// **真跑一条绝对只读命令**（`/bin/echo` 不在白名单 → 应被拒；验证不放行任意命令）。
    ///
    /// 这条断言「白名单不是摆设」——不因为可执行真实存在就执行。
    func testWhitelistBlocksEvenWhenExecutableExists() {
        let runner = UpstreamRunner()
        let outcome = runner.run(executable: "echo", args: ["hello"])
        XCTAssertTrue(outcome.record.rejectedByWhitelist, "/bin/echo 不在白名单，必须拒")
        XCTAssertNil(outcome.stdout)
    }

    // ========================================================================
    // MARK: - ② 落盘（未落盘 = 无法证明）
    // ========================================================================

    /// **`scan.jsonl` 必须真落盘**，且 `upstreamCommands` / `diagnostics` 均在其中。
    func testScanLogIsPersistedWithUpstreamAndDiagnostics() throws {
        let writer = RecordWriter(directory: tmpDir)

        let upstream = UpstreamCommand(
            cmd: "uv", args: ["cache", "dir"],
            exitCode: 0, durationMs: 42,
            invokedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let diag = ScanLogRecord.Diagnostics(
            degraded: false,
            coverage: .init(sameUIDTotal: 100, sameUIDRead: 100, statOtherUID: 20),
            pNowCount: 5, fSetBits: 90, doneCount: 2,
            a: 0, b: 12, round: 2, countedDays: 3,
            contentReads: 0
        )
        let record = ScanLogRecord(
            at: Date(timeIntervalSince1970: 1_700_000_100),
            mode: "full",
            sources: [Source.uvCache.rawValue, Source.npmNpx.rawValue],
            filesScanned: 1234,
            bytesScanned: 5_000_000,
            durationMs: 880,
            upstreamCommands: [upstream],
            diagnostics: diag
        )
        try writer.appendScan(record)

        // 文件存在且有一行
        let path = tmpDir.appendingPathComponent("scan.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))

        let lines = try writer.readLines(kind: .scan)
        XCTAssertEqual(lines.count, 1)

        let obj = lines[0]
        XCTAssertEqual(obj["mode"] as? String, "full")
        XCTAssertEqual(obj["filesScanned"] as? Int, 1234)

        // upstreamCommands 必须在
        let upstreamArr = obj["upstreamCommands"] as? [[String: Any]]
        XCTAssertEqual(upstreamArr?.count, 1, "upstreamCommands 必须落盘（AC-19 的唯一载体）")
        XCTAssertEqual(upstreamArr?[0]["cmd"] as? String, "uv")
        XCTAssertEqual(upstreamArr?[0]["exitCode"] as? Int, 0)

        // diagnostics 必须在，且 contentReads 可读
        let diagObj = obj["diagnostics"] as? [String: Any]
        XCTAssertNotNil(diagObj, "diagnostics 必须落盘")
        XCTAssertEqual(diagObj?["contentReads"] as? Int, 0, "contentReads 必须可读（AC-07 载体）")
        XCTAssertEqual(diagObj?["a"] as? Int, 0)
        XCTAssertEqual(diagObj?["b"] as? Int, 12)
    }

    /// **`contentReads = 0` 是正常态；非 0 必须能被读出来**（否则 AC-07 又变恒真）。
    func testNonZeroContentReadsIsObservable() throws {
        let writer = RecordWriter(directory: tmpDir)
        let diag = ScanLogRecord.Diagnostics(contentReads: 7)
        let record = ScanLogRecord(
            at: Date(), mode: "full", sources: [], filesScanned: 1,
            bytesScanned: 1, durationMs: 1, diagnostics: diag
        )
        try writer.appendScan(record)

        let lines = try writer.readLines(kind: .scan)
        let diagObj = lines[0]["diagnostics"] as? [String: Any]
        XCTAssertEqual(
            diagObj?["contentReads"] as? Int, 7,
            "非 0 的 contentReads 必须可读出（否则越界读内容无法被发现）"
        )
    }

    /// **追加写不覆盖**（`O_APPEND` 语义）：多次写得到多行。
    func testAppendDoesNotOverwrite() throws {
        let writer = RecordWriter(directory: tmpDir)
        for i in 0..<5 {
            let r = ScanLogRecord(
                at: Date(), mode: "incremental", sources: [], filesScanned: i,
                bytesScanned: Int64(i), durationMs: 1
            )
            try writer.appendScan(r)
        }
        XCTAssertEqual(try writer.readLines(kind: .scan).count, 5)
    }

    // MARK: - 启动时读回「上次完整扫描」

    /// 读回最近一条**完整**扫描；中止行与坏行都必须跳过。
    ///
    /// 现有 `readLines` 只给字典，App 层无法还原 `bytesScanned` 的类型；
    /// 这条测试钉住「重启后能拿到上次扫描的总量」这一能力。
    func testLastCompletedScanSkipsAbortedAndMalformedLines() throws {
        let writer = RecordWriter(directory: tmpDir)
        let complete = ScanLogRecord(
            at: Date(timeIntervalSince1970: 1_700_000_000),
            mode: "full", sources: [Source.uvCache.rawValue],
            filesScanned: 100, bytesScanned: 1_000_000, durationMs: 10
        )
        let aborted = ScanLogRecord(
            at: Date(timeIntervalSince1970: 1_700_000_100),
            mode: "full", sources: [Source.uvCache.rawValue],
            filesScanned: 10, bytesScanned: 90_000, durationMs: 5,
            aborted: "E-104"
        )
        try writer.appendScan(complete)
        try writer.appendScan(aborted)
        // 末行写坏（例如进程在追加中途被杀）：不能让它阻断读取
        try writer.append(["broken": true], kind: .scan)

        let last = try XCTUnwrap(writer.lastCompletedScanRecord())
        XCTAssertEqual(last.bytesScanned, 1_000_000, "中止扫描的字节数是部分值，不能当总量")
        XCTAssertEqual(last.filesScanned, 100)
        XCTAssertNil(last.aborted)
        XCTAssertEqual(last.at, complete.at, "ISO-8601 编解码必须对称")
    }

    /// 没有 `scan.jsonl`（首次启动）→ `nil`，**不是 0 字节的汇总**。
    func testLastCompletedScanReturnsNilWhenNoLog() {
        let writer = RecordWriter(directory: tmpDir)
        XCTAssertNil(writer.lastCompletedScanRecord())
    }

    /// **三类记录各自独立文件**。
    func testThreeKindsAreSeparateFiles() throws {
        let writer = RecordWriter(directory: tmpDir)
        try writer.append(["k": "scan"], kind: .scan)
        try writer.append(["k": "exec"], kind: .execution)
        try writer.append(["k": "evi"], kind: .evidence)

        for kind in RecordWriter.Kind.allCases {
            let p = tmpDir.appendingPathComponent(kind.fileName)
            XCTAssertTrue(FileManager.default.fileExists(atPath: p.path), "\(kind.fileName) 应存在")
        }
        XCTAssertEqual(try writer.readLines(kind: .scan).first?["k"] as? String, "scan")
        XCTAssertEqual(try writer.readLines(kind: .execution).first?["k"] as? String, "exec")
        XCTAssertEqual(try writer.readLines(kind: .evidence).first?["k"] as? String, "evi")
    }

    /// **`totalJSONLBytes` 只算 `.jsonl`**（M6 的被减项基础）。
    func testTotalJSONLBytesCountsOnlyJSONL() throws {
        let writer = RecordWriter(directory: tmpDir)
        try writer.append(["x": 1], kind: .scan)
        // 混入一个非 jsonl 文件，不应被计入
        try Data(repeating: 0x41, count: 5000)
            .write(to: tmpDir.appendingPathComponent("not-a-log.txt"))

        let total = try writer.totalJSONLBytes()
        XCTAssertGreaterThan(total, 0, "应统计到 jsonl 字节")
        XCTAssertLessThan(total, 5000, "非 .jsonl 文件不得计入（5000 B 的那份应被排除）")
    }

    /// **记录目录必须在 `records/` 下**（M4 载体与 `state/` 不得混进来）。
    func testDefaultRecordsDirectoryIsUnderRecords() {
        let dir = RecordWriter.defaultRecordsDirectory()
        XCTAssertTrue(dir.path.hasSuffix("/records"), "记录目录应为 .../records，实为 \(dir.path)")
        // 不能与 state.residue 同目录（否则 M6 会把载体算进可回收字节）
        let stateDir = StateFile.defaultDirectory()
        XCTAssertNotEqual(dir.path, stateDir.path)
        XCTAssertTrue(dir.path.hasPrefix(stateDir.path), "records 应在状态根之下")
    }
}
