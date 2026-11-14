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

// MARK: - 进度

/// 一次扫描的**进度快照**（`Sendable`，可跨 actor 边界传递）。
///
/// ## 为什么需要它
///
/// 若只是把扫描搬到后台线程而**不汇报进度**，用户看到的是「按了没反应」——
/// **那和卡死没有区别**，甚至更糟（用户会去重复点击）。
struct ScanProgress: Sendable, Equatable {
    /// 当前正在扫的来源（`Source.rawValue`）。
    var source: String = ""
    /// 已扫描的条目数。
    var filesScanned: Int = 0
    /// 已发现的候选数。
    var candidatesFound: Int = 0
    /// 已耗时（秒）。
    var elapsed: TimeInterval = 0
    /// 是否仍在运行。
    var isRunning: Bool = false

    /// **给用户看的进度文案**。
    ///
    /// ## 为什么写「已扫描 N 项」而不是「已完成 x%」
    ///
    /// 总条目数**事先不知道**（要先扫一遍才知道）→ 百分比是假的。
    /// 「已扫描 N 项 + 已用时」是**能如实说出口**的量。
    var displayText: String {
        guard isRunning else { return "" }
        var parts = [L.pick("已扫描 \(filesScanned.formatted()) 项", "\(filesScanned.formatted()) items scanned")]
        if candidatesFound > 0 {
            parts.append(L.pick(
                "发现 \(candidatesFound.formatted()) 个可回收条目",
                "\(candidatesFound.formatted()) reclaimable items found"
            ))
        }
        parts.append(L.pick(
            String(format: "已用时 %.1f 秒", elapsed),
            String(format: "%.1f s elapsed", elapsed)
        ))
        return parts.joined(separator: " · ")
    }
}

// MARK: - 取消

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


// MARK: - 来源根解析（**自由函数，不是 AppModel 的方法**）

/// 一个来源的扫描根（**根 + 可选文件名过滤**）。
///
/// ## 为什么要带 `fileFilter`
///
/// Homebrew 的 `downloads/` 里不只有瓶子，还有瓶子清单、cask 包和源包。
/// 只有 `*.bottle*.tar.gz` 是本产品认可的「下载缓存」——其余文件删了不会
/// 释放多少空间，却会让产品叙事变成「什么都敢删」。过滤在扫描层做，
/// 保证候选集合本身 = 可清理集合。
struct SourceRoot: Sendable {
    let sourceName: String
    let path: String
    let fileFilter: ScanEngine.FileNameFilter?

    init(sourceName: String, path: String, fileFilter: ScanEngine.FileNameFilter? = nil) {
        self.sourceName = sourceName
        self.path = path
        self.fileFilter = fileFilter
    }
}

/// 解析结果：扫描根 + 「缓存布局不认识」的来源集合。
struct ResolvedSourceRoots: Sendable {
    var roots: [SourceRoot]
    /// 根存在、但已知布局一个都不存在（当前用于 pip）→ 界面按「无法判定」呈现，不显示 0。
    var layoutUnrecognized: Set<String>
}

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
) -> ResolvedSourceRoots {
    // 自检注入优先（不产生 upstreamCommands —— 因为压根没调上游命令）
    // 注入根仍套用该来源的标准文件名过滤：否则自检里的 brew 根会把
    // 瓶子清单也当候选，与生产行为不一致（自检就不算证明）。
    if let override {
        return ResolvedSourceRoots(
            roots: override.map { pair in
                SourceRoot(
                    sourceName: pair.0,
                    path: pair.1,
                    fileFilter: Source(rawValue: pair.0).flatMap(defaultFileFilter(for:))
                )
            },
            layoutUnrecognized: []
        )
    }

    let home = NSHomeDirectory()
    var out: [SourceRoot] = []

    // uv：`uv cache dir`（白名单内，纯本地）
    let uv = probe.run(executable: "uv", args: ["cache", "dir"])
    upstream.append(uv.record)
    let uvRoot = nonEmpty(uv.stdout) ?? home + "/.cache/uv"
    out.append(SourceRoot(sourceName: Source.uvCache.rawValue, path: uvRoot))

    // npm：`npm config get cache`（白名单内）
    let npm = probe.run(executable: "npm", args: ["config", "get", "cache"])
    upstream.append(npm.record)
    let npmBase = nonEmpty(npm.stdout) ?? home + "/.npm"
    out.append(SourceRoot(sourceName: Source.npmNpx.rawValue, path: npmBase + "/_npx"))

    // pipx：规则目录固定（`.local/pipx/venv`，与 SourceRule 一致）
    out.append(SourceRoot(sourceName: Source.pipxRun.rawValue, path: home + "/.local/pipx/venv"))

    // Homebrew：`brew --cache`（白名单内）→ 只扫 `downloads/`，且只收瓶子。
    //
    // **为什么不是整个 cache 根**：`bootsnap/`（Ruby 启动缓存）、`api/`
    // （formula 元数据）、`tool-selection/` 都不是下载缓存；把它们算进
    // 「可回收字节」会让用户清完 brew 变慢。
    let brew = probe.run(executable: "brew", args: ["--cache"])
    upstream.append(brew.record)
    let brewCache = nonEmpty(brew.stdout) ?? home + "/Library/Caches/Homebrew"
    out.append(SourceRoot(
        sourceName: Source.brewCache.rawValue,
        path: brewCache + "/downloads",
        fileFilter: defaultFileFilter(for: .brewCache)
    ))

    // pip：`pip cache dir`（CR-032 新增白名单）→ 只扫已知布局。
    //
    // 依次尝试 `pip` / `pip3` / `python3 -m pip`：有些机器只有 `pip3`，
    // 有些 Python 环境不提供独立入口。**每次尝试都落一条 upstreamCommands**。
    var pipDir: String? = nil
    let pip = probe.run(executable: "pip", args: ["cache", "dir"])
    upstream.append(pip.record)
    pipDir = nonEmpty(pip.stdout)
    if pipDir == nil {
        let pip3 = probe.run(executable: "pip3", args: ["cache", "dir"])
        upstream.append(pip3.record)
        pipDir = nonEmpty(pip3.stdout)
    }
    if pipDir == nil {
        let py = probe.run(executable: "python3", args: ["-m", "pip", "cache", "dir"])
        upstream.append(py.record)
        pipDir = nonEmpty(py.stdout)
    }

    let pipCache = pipDir ?? home + "/Library/Caches/pip"
    var pipLayoutFound = false
    for sub in ["http-v2", "http", "wheels"] {
        let path = pipCache + "/" + sub
        if FileManager.default.fileExists(atPath: path) {
            pipLayoutFound = true
            out.append(SourceRoot(sourceName: Source.pipCache.rawValue, path: path))
        }
    }
    var unrecognized: Set<String> = []
    if !pipLayoutFound && FileManager.default.fileExists(atPath: pipCache) {
        // 目录在、但一个已知子目录都不在 → 布局可能已变（如 http-v3）。
        // **不显示 0**：没看见 ≠ 没有（N5 的对偶要求）。
        unrecognized.insert(Source.pipCache.rawValue)
    }

    return ResolvedSourceRoots(roots: out, layoutUnrecognized: unrecognized)
}

/// 某来源的**标准文件名过滤**（唯一实现处，生产与自检注入共用）。
///
/// 只有 Homebrew 需要：`downloads/` 里瓶子、瓶子清单、cask、源码包混放，
/// 只有 `*.bottle*.tar.gz` 是本产品认可的可回收下载缓存。
func defaultFileFilter(for source: Source) -> ScanEngine.FileNameFilter? {
    switch source {
    case .brewCache:
        return ScanEngine.FileNameFilter(
            requiredSubstrings: [".bottle"],
            requiredSuffixes: [".tar.gz"]
        )
    default:
        return nil
    }
}

/// 上游输出归一化：去空白；空串按「没拿到」处理。
private func nonEmpty(_ s: String?) -> String? {
    guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
    return t
}
