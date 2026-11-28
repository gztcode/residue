import XCTest
@testable import ResidueCore

/// P-012 测试：**等待上游命令期间不读 stdout** ⇒ 输出超过管道缓冲必然超时。
///
/// ## 缺陷原形
///
/// `UpstreamRunner` 原实现：先 `while proc.isRunning { usleep(10 ms) }` 等退出，
/// **期间一次都不读** stdout；退出之后才 `readDataToEndOfFile()`。
/// macOS 管道缓冲只有 64 KB 量级 ⇒ 子进程写满后阻塞在 `write`、永不退出
/// ⇒ 父子互等 ⇒ 必然拖到 `perProbeTimeout`，还把这次调用判成失败。
///
/// ## 验收口径
///
/// ① 大输出（200000 行 ≈ 1.29 MB ≫ 64 KB）**完整**拿到，且**没有**等到超时；
/// ② 大 stderr 同样不堵死（stderr 也必须抽干 —— 只读 stdout 一样会死锁）；
/// ③ 超过保留上限 ⇒ 被截断 + **有明确标记**，且命令**仍然正常结束**（抽干没停）；
/// ④ 超时时**已经收到的输出要保留**（超时不等于没读到，丢掉就是丢证据）。
final class UpstreamPipeDrainTests: XCTestCase {

    /// 大输出参数：200000 行 ≈ 1.29 MB（远大于 64 KB 管道缓冲，小于 8 MiB 保留上限）。
    private static let bigSeq = ["1", "200000"]

    private func makeRunner(
        perProbeTimeout: TimeInterval = 5.0,
        maxOutputBytes: Int = 8 * 1024 * 1024
    ) -> UpstreamRunner {
        UpstreamRunner(perProbeTimeout: perProbeTimeout, totalBudget: 30.0, maxOutputBytes: maxOutputBytes)
    }

    /// ① 大 stdout：完整拿到 + 不超时。
    func testLargeStdoutIsFullyDrainedAndDoesNotTimeOut() {
        let runner = makeRunner()
        let outcome = runner.execute(
            cmd: "/usr/bin/seq",
            path: "/usr/bin/seq",
            args: UpstreamPipeDrainTests.bigSeq,
            started: Date(),
            now: Date()
        )

        XCTAssertNil(outcome.record.failure, "大输出不该被判失败（原实现必然超时）")
        XCTAssertEqual(outcome.record.exitCode, 0)
        XCTAssertFalse(outcome.stdoutTruncated, "1.29 MB < 8 MiB 上限，不该被截断")

        let lines = outcome.stdout?.split(separator: "\n", omittingEmptySubsequences: false) ?? []
        XCTAssertEqual(lines.count, 200_001, "200000 行 + 末尾空串，一行都不能少")
        XCTAssertEqual(lines.first, "1")
        XCTAssertEqual(lines[lines.count - 2], "200000")

        XCTAssertLessThan(
            outcome.record.durationMs,
            Int(runner.perProbeTimeout * 1000),
            "耗时必须远小于超时预算 —— 等到了超时说明没在抽干"
        )
    }

    /// ② 大 stderr：同样不能把子进程堵死。
    func testLargeStderrDoesNotDeadlock() {
        let runner = makeRunner()
        let outcome = runner.execute(
            cmd: "/bin/sh",
            path: "/bin/sh",
            args: ["-c", "/usr/bin/seq 1 200000 >&2"],
            started: Date(),
            now: Date()
        )

        XCTAssertNil(outcome.record.failure, "stderr 写满缓冲一样会堵死子进程 ⇒ 必须抽干 stderr")
        XCTAssertEqual(outcome.record.exitCode, 0)
        XCTAssertLessThan(outcome.record.durationMs, Int(runner.perProbeTimeout * 1000))
    }

    /// ③ 超过保留上限：截断 + 明确标记 + **命令仍然正常结束**（抽干不能停）。
    func testOutputBeyondCapIsTruncatedMarkedAndStillFinishes() {
        let runner = makeRunner(maxOutputBytes: 1024)
        let outcome = runner.execute(
            cmd: "/usr/bin/seq",
            path: "/usr/bin/seq",
            args: UpstreamPipeDrainTests.bigSeq,
            started: Date(),
            now: Date()
        )

        XCTAssertNil(outcome.record.failure, "抽干若在上限处停下，子进程会堵死 ⇒ 必然超时")
        XCTAssertEqual(outcome.record.exitCode, 0, "命令本身应当正常结束")
        XCTAssertTrue(outcome.stdoutTruncated, "截断必须有明确标记")
        XCTAssertEqual(outcome.stdout?.utf8.count, 1024, "只保留上限内的字节")
        XCTAssertTrue(outcome.stdout?.hasPrefix("1\n2\n3\n") == true, "保留的是前缀")
        XCTAssertLessThan(outcome.record.durationMs, Int(runner.perProbeTimeout * 1000))
    }

    /// ④ 超时：**已经收到的输出要保留**（不因超时丢证据）。
    func testTimeoutKeepsAlreadyReceivedOutput() {
        let runner = makeRunner(perProbeTimeout: 0.5)
        let outcome = runner.execute(
            cmd: "/bin/sh",
            path: "/bin/sh",
            args: ["-c", "printf 'hello\\n'; sleep 5"],
            started: Date(),
            now: Date()
        )

        XCTAssertNotNil(outcome.record.failure)
        XCTAssertTrue(outcome.record.failure?.contains("超时") == true, "超时口径不变")
        XCTAssertNil(outcome.record.exitCode, "超时时不给退出码")
        XCTAssertEqual(
            outcome.stdout?.trimmingCharacters(in: .whitespacesAndNewlines),
            "hello",
            "超时时已收到的输出必须保留"
        )
        XCTAssertLessThan(outcome.record.durationMs, 3000, "超时要及时收尾，不能死等")
    }

    /// ⑤ 抽干原语自身：超过上限后**停止保留但继续抽干**（写端不被堵死）。
    func testDrainerKeepsDrainingAfterCapReached() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/seq")
        proc.arguments = UpstreamPipeDrainTests.bigSeq
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()

        let drainer = UpstreamPipeDrainer(handle: pipe.fileHandleForReading, cap: 1024)
        drainer.start()
        XCTAssertTrue(drainer.waitForCompletion(timeout: 10.0), "抽干应读到 EOF")
        proc.waitUntilExit()

        XCTAssertEqual(proc.terminationStatus, 0, "写端不能被堵死（否则子进程不会退出）")
        XCTAssertTrue(drainer.currentOutput.truncated, "超上限 ⇒ 标记截断")
        XCTAssertEqual(drainer.currentOutput.retained.count, 1024, "只保留上限内的字节")
    }

    /// ⑥ 兜底路径：等不到 EOF 时 `stop()` **只停「保留」**。
    ///
    /// ★ 这里**不能关读端**：`FileHandle` 抛的是 ObjC 异常
    /// （`NSFileHandleOperationException`），Swift 的 `catch` **接不住** ⇒ 直接崩。
    /// 所以兜底只能「请求停止」，让线程最多挂在一次 `read` 上。
    func testStopWithoutEOFDoesNotCrash() {
        let pipe = Pipe()
        let drainer = UpstreamPipeDrainer(handle: pipe.fileHandleForReading, cap: 1024)
        drainer.start()

        // 写端一直开着 ⇒ 永远等不到 EOF ⇒ 必然走兜底分支。
        XCTAssertFalse(drainer.waitForCompletion(timeout: 0.2), "写端开着就等不到 EOF")
        drainer.stop()
        XCTAssertTrue(drainer.currentOutput.truncated, "提前收手 ⇒ 如实标「不完整」")
    }
}
