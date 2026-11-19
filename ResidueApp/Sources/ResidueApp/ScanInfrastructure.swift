import Foundation
import ResidueCore

// ============================================================
// Residue · 扫描的并发基础设施
//
// **这一整个文件的存在理由**：
// 扫描是**重 I/O**（实测本机 2026-11-09：`~/.cache/uv` 115,875 项 ≈ 6.44 s、
// `~/.npm/_npx` 106,983 项 ≈ 6.79 s —— 合计约 13 秒）。
//
// 而 `AppModel` 是 `@MainActor` 隔离的。**`@MainActor` 类上的 `async` 函数
// 并不会自动离开主线程** —— `async` 只让函数「可以被挂起」，
// 函数体里的**同步代码仍然在主 actor 上执行**。
//
// 于是扫描必须整体搬到主 actor 之外，同时满足三件事：
// 1. **搬走**（不在主线程）
// 2. **汇报**（用户看到它在动，而不是以为死了）
// 3. **可取消**（13 秒不能反悔）
//
// 缺任何一件，用户体验都是「卡住」——
// 只是第一种是**界面冻住**，第二种是**界面能动但没反馈**，第三种是**没得反悔**。
// ============================================================

// MARK: - 取消
//
// ⚠️ `ScanProgress` 已迁入 Core（CR-037 §3.1）——
// 进度环弧长与跨来源累计必须在 Core 可单测，且界面不得做除法。

/// 扫描的**取消令牌**（`Sendable`，主 actor 与后台任务共享）。
///
/// ## 为什么不是一个 `Bool`
///
/// 取消信号要**从主 actor 传到后台任务**。后台任务不能直接读主 actor 的属性
/// （那要 `await`，而扫描循环里每条都 await 会抵消掉后台化的收益）。
///
/// 所以用一个**线程安全的盒子**：主 actor 写、后台任务读，**不需要 await**。
///
/// ## 为什么不用 `Task.isCancelled`
///
/// 也可以用 `Task.checkCancellation()`，但那需要任务句柄从主 actor 传进后台任务，
/// 且要求取消时**主动抛错中断**。而扫描的 I/O 调用**不可中断**——
/// 一次 `contentsOfDirectory` 就要几毫秒。
/// 所以这里的语义是「**尽快在下一个检查点停下**」，
/// 而不是「立刻打断当前这次 I/O」。
final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var progress = ScanProgress()

    /// 是否已被请求取消。
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// 请求取消。
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /// 汇报进度（**后台任务调用**）。
    ///
    /// ## 为什么进度也要放进这个盒子
    ///
    /// 因为后台任务**不能直接写主 actor 的 `@Observable` 属性**
    /// （那需要 `await MainActor.run`，而 56 次跳转虽可接受，
    /// 但会让「进度」与「取消」分裂成两套机制）。
    ///
    /// 统一放在这里，主 actor 用一个定时器（或扫描结束前）**轮询**取走。
    func report(_ p: ScanProgress) {
        lock.lock()
        progress = p
        lock.unlock()
    }

    /// 取走当前进度（**主 actor 调用**）。
    func takeProgress() -> ScanProgress {
        lock.lock()
        defer { lock.unlock() }
        return progress
    }
}

/// 后台任务回传一个**非 `Sendable` 不可**的结果值（`@unchecked Sendable` + 锁）。
///
/// 只用于自检：`Task.detached` 里算出的结果要带回同步上下文，
/// 直接写外层局部变量会被 Swift 6 判为数据竞争。
final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ScanEngine.ScanResult?

    func store(_ v: ScanEngine.ScanResult?) {
        lock.lock()
        value = v
        lock.unlock()
    }

    func load() -> ScanEngine.ScanResult? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}


// MARK: - 来源根解析（**自由函数，不是 AppModel 的方法**）

/// 解析各来源的根目录（用上游只读命令定位；失败回退标准路径）。
///
/// ## 为什么是**自由函数**而不是 `AppModel` 的方法
///
/// `AppModel` 是 `@MainActor` 隔离的。**整个类上的每一个成员都是主 actor 隔离的** ——
/// 包括 `static` 方法。所以：
///
/// - 写成 `AppModel` 的实例方法 → 后台任务调它要 `await MainActor.run` → **又拉回主线程**
/// - 写成 `AppModel` 的 `static` 方法 → **同样不行**（主 actor 隔离对 `static` 一样成立）
/// - 写成**自由函数** → 无 actor 归属 → 后台任务直接调 ✅
///
/// 这就是「要离开主 actor，就不能把它放在主 actor 隔离的类型里」的含义。
///
/// ## 依赖显式传入
///
/// 不读隐式的 `self`（那也不允许）—— 需要的 `probe` / `override` 都由参数传入。
func resolveSourceRoots(
    override: [(String, String)]?,
    probe: UpstreamRunner,
    upstream: inout [UpstreamCommand]
) -> [(String, String)] {
    // 自检注入优先（不产生 upstreamCommands —— 因为压根没调上游命令）
    if let override { return override }

    let home = NSHomeDirectory()

    // uv：`uv cache dir`（白名单内，纯本地）
    let uv = probe.run(executable: "uv", args: ["cache", "dir"])
    upstream.append(uv.record)

    // npm：`npm config get cache`（白名单内）
    let npm = probe.run(executable: "npm", args: ["config", "get", "cache"])
    upstream.append(npm.record)

    // Homebrew：`brew --cache`（白名单内，纯本地定位；PRD v5.6 N6 已点名）
    let brew = probe.run(executable: "brew", args: ["--cache"])
    upstream.append(brew.record)

    // ★ **路径计算在 Core**（`SourceRoots.resolve`）——
    // 纯函数、可单测、**只有一处实现**（不变量②）。
    // cargo / pnpm / bun 走固定路径、零探测（零进程开销、零网络）。
    return SourceRoots.resolve(
        home: home,
        uvCacheDir: uv.stdout,
        npmCacheDir: npm.stdout,
        brewCacheDir: brew.stdout
    )
}
