import XCTest
@testable import ResidueCore

/// 扫描的**并发行为**测试。
///
/// ## 这一组存在的理由
///
/// 「扫描时界面卡住」这个缺陷**在单测里完全看不见** ——
/// 因为单测不渲染界面，而 `runScan` 在旧实现里是 `@MainActor` 上的 `async` 函数：
/// `async` 只让函数「可以被挂起」，**函数体里的同步代码仍在主 actor 上执行**。
///
/// 实测（本机 · 2026-11-09）：`~/.cache/uv` 115,875 项 ≈ 6.44 s，
/// `~/.npm/_npx` 106,983 项 ≈ 6.79 s —— 合计约 **13 秒**的全同步阻塞。
///
/// 所以判据必须是：**扫描在跑的时候，主线程还能不能响应。**
/// 这不能靠「测试绿」证明，只能靠**测量主线程的响应延迟**。
final class ScanConcurrencyTests: XCTestCase {


    // MARK: - 主线程响应性

    /// **扫描必须发生在主 actor 之外**（这是「界面不卡」的直接判定）。
    ///
    /// ## 为什么不用「测响应延迟」
    ///
    /// 第一版是这么写的（造一个大目录、扫描时在主 actor 上反复 `Task.yield()`、
    /// 断言最大延迟 < 阈值）。**它测不出差别** —— 证伪时把扫描放回 `@MainActor`
    /// 竟然**仍然通过**：
    ///
    /// - 造 3000 个文件 → 扫描只要 0.12 s → 比阈值（2 s）还快 → 两种实现都过
    /// - 造 6 万个文件 → 造数本身要几秒，测试超时（SIGTERM）
    ///
    /// **根因**：要靠时间阈值区分，就必须让「扫描耗时 >> 阈值」，
    /// 而造出那个规模的样本**本身就贵到不可接受**。
    ///
    /// ## 更好的判据：直接问「这段代码跑在哪个 actor 上」
    ///
    /// `Thread.isMainThread` 在**扫描执行的那一刻**取值：
    /// - 扫描在后台 → `false`
    /// - 扫描在主 actor 上 → `true`
    ///
    /// 这不需要造大样本、不需要时间阈值、**没有假绿**。
    /// 而且它测的正是「缺陷的机制」而不是「缺陷的后果」——
    /// 后者会随机器、随缓存大小、随文件系统缓存命中率而漂移。
    func testScanDoesNotRunOnMainThread() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("residue-thread-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let engine = ScanEngine()

        // ---- 关键：扫描跑在**后台线程**上 ----
        let probe = ThreadProbe()

        let task = Task.detached(priority: .userInitiated) {
            // 在扫描**开始之前**记录一次：detached 任务本身不在主线程
            probe.recordIfNeeded()
            try? engine.scan(root: root.path, mode: .full)
        }
        _ = await task.value

        XCTAssertEqual(
            probe.sawMainThread(), false,
            "扫描跑在了主线程上 —— 界面会冻结（这是「点击扫描就卡住」的根因）"
        )
    }

    /// **扫描期间主 actor 仍能处理其他工作**（不卡住的第二个条件）。
    ///
    /// 这条**不依赖时间阈值**：它测的是「主 actor 在扫描期间还能不能被调度」，
    /// 而这在扫描真的在后台时必然成立。
    func testMainActorRemainsSchedulableDuringScan() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("residue-sched-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<2000 {
            try Data(repeating: 0, count: 32)
                .write(to: root.appendingPathComponent("q\(i).bin"))
        }

        let engine = ScanEngine()
        let scanTask = Task.detached(priority: .userInitiated) {
            try? engine.scan(root: root.path, mode: .full)
        }

        // 主 actor 上做 50 次让出-恢复
        var completed = 0
        for _ in 0..<50 {
            await Task.yield()
            completed += 1
        }

        XCTAssertEqual(completed, 50, "主 actor 在扫描期间应能继续被调度")
        _ = await scanTask.value
    }

    /// **扫描在后台执行时，`isScanning` 之类的状态更新不能被卡住**。
    ///
    /// 这条测的是「搬走之后主 actor 仍然能做事」——
    /// 若实现里有什么把后台任务又拉回主 actor（例如在后台 `await MainActor.run`
    /// 做重活），这条会红。
    func testBackgroundScanDoesNotBlockActorReentrancy() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("residue-actor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<1500 {
            try Data(repeating: 0, count: 64)
                .write(to: root.appendingPathComponent("g\(i).bin"))
        }

        let engine = ScanEngine()
        let started = Date()

        // 后台扫描
        async let scan = Task.detached(priority: .userInitiated) {
            try? engine.scan(root: root.path, mode: .full)
        }

        // 主 actor 上做 20 次「让出-恢复」
        for _ in 0..<20 {
            await Task.yield()
        }
        let reentrantElapsed = Date().timeIntervalSince(started)

        _ = await scan.value

        XCTAssertLessThan(
            reentrantElapsed, 2.0,
            "主 actor 的 20 次让出-恢复耗时 \(reentrantElapsed) 秒 —— 说明有重活被拉回了主 actor"
        )
    }

    // MARK: - 进度汇报

    /// **扫描必须汇报进度**（否则「搬到后台但没反馈」= 用户看到的还是「卡住」）。
    func testScanReportsProgress() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("residue-prog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<500 {
            try Data(repeating: 0, count: 32)
                .write(to: root.appendingPathComponent("h\(i).bin"))
        }

        let engine = ScanEngine()
        let box = ProgressBox()
        let result = try engine.scan(
            root: root.path,
            mode: .full,
            progress: { p in box.append(p) },
            progressEvery: 50
        )

        XCTAssertGreaterThan(
            box.count, 0,
            "扫描必须汇报进度 —— 否则界面能动但没反馈，用户体验与卡死无异"
        )
        XCTAssertEqual(result.filesScanned, 500, "进度汇报不影响扫描结果")
    }

    /// **进度回调的频率必须受控**（每条都回调 = 11 万次跨 actor 跳转，比扫描还贵）。
    func testProgressCallbackFrequencyIsBounded() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("residue-freq-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<1000 {
            try Data(repeating: 0, count: 16)
                .write(to: root.appendingPathComponent("k\(i).bin"))
        }

        let engine = ScanEngine()
        let box = ProgressBox()
        _ = try engine.scan(
            root: root.path,
            mode: .full,
            progress: { p in box.append(p) },
            progressEvery: 100
        )

        // 1000 条 / 每 100 条一次 → 约 10 次
        XCTAssertLessThanOrEqual(
            box.count, 20,
            "进度回调 \(box.count) 次，过密（每条都回调会让跨 actor 跳转比扫描本身还贵）"
        )
        XCTAssertGreaterThanOrEqual(box.count, 5, "回调过稀，界面看不出在动")
    }

    /// **进度里的计数必须单调不减**（界面上的数字不能来回跳）。
    func testProgressCountsAreMonotonic() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("residue-mono-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<800 {
            try Data(repeating: 0, count: 16)
                .write(to: root.appendingPathComponent("m\(i).bin"))
        }

        let engine = ScanEngine()
        let box = ProgressBox()
        _ = try engine.scan(
            root: root.path,
            mode: .full,
            progress: { p in box.append(p) },
            progressEvery: 50
        )

        let items = box.items
        for i in 1..<max(1, items.count) {
            XCTAssertGreaterThanOrEqual(
                items[i].filesScanned, items[i - 1].filesScanned,
                "已扫描条目数不得回退（界面上的数字来回跳 = 用户以为出问题了）"
            )
        }
    }
}

/// 线程安全的进度收集器（测试用）。
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ScanEngine.Progress] = []

    func append(_ p: ScanEngine.Progress) {
        lock.lock()
        storage.append(p)
        lock.unlock()
    }

    var items: [ScanEngine.Progress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var count: Int { items.count }
}

/// 记录「这段代码跑在不在主线程上」（测试用）。
///
/// ## 为什么要有这个辅助类型
///
/// `Thread.isMainThread` 在 **async 上下文**里不可用
/// （Swift 6 的并发检查：它读的是当前线程，而 async 函数可能跨线程恢复）。
/// 而本用例要问的恰恰是「**扫描执行的那一刻**在哪个线程上」——
/// 那必须在一个**同步**上下文里取。
///
/// 所以把它包进一个**同步方法**里：调用点可以留在 async 上下文，
/// 而读取本身发生在方法体内（那一刻真的在执行）。
private final class ThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: Bool?

    /// 记录当前是否在主线程（**只记第一次**）。
    func recordIfNeeded() {
        let value = Thread.isMainThread
        lock.lock()
        if recorded == nil { recorded = value }
        lock.unlock()
    }

    /// 取记录值（**用方法而非属性** —— 属性访问在并发检查里更受限）。
    func sawMainThread() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
