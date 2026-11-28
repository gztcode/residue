import Foundation

/// 一条管道（stdout / stderr）的**抽干**读取器。
///
/// ## 为什么必须抽干（不能事后一次性读）
///
/// macOS 的管道缓冲只有 64 KB 量级。子进程写满缓冲后会阻塞在 `write` 上、
/// **永远不退出**；父进程若「等它退出才读」，父子互等 ⇒ 必然拖到超时，
/// 然后只读到半截输出，还把这次调用判成失败。
///
/// 实测：`npm cache ls` 输出 352101 B / 3498 行，远超缓冲 —— 这条路径
/// **在白名单里**（`UpstreamWhitelist`），随时可能被调用。
///
/// ## 抽干 ≠ 停止读
///
/// 超过 `cap` 之后**只停止保留**，**继续读**直到 EOF：
/// 一旦停止读，子进程会重新堵死在 `write` 上，问题原样复现。
/// 所以「上限」只约束**内存**，不约束**读取**。
///
/// ## 线程与生命周期
///
/// 抽干跑在一条独立 `Thread` 上：`start()` 启动，
/// `waitForCompletion(timeout:)` 等它读到 EOF。
/// 线程闭包强持有本对象 ⇒ 抽干未结束时对象不会被释放，
/// `FileHandle` 也不会在读的过程中被释放；
/// 累计量由 `NSLock` 保护，跨线程可见，且**边读边发布**
/// ⇒ 调用方随时能看到「已经收到多少」。
final class UpstreamPipeDrainer: @unchecked Sendable {

    /// 抽干结果（快照）。
    struct Output: Sendable {
        /// 保留的前缀（最多 `cap` 字节；可能为空）。
        let retained: Data
        /// 输出是否**不完整**：超过 `cap` 被截断，或没来得及抽完。
        let truncated: Bool
    }

    /// 单次 `read` 的字节数（够大以少做系统调用，又不至于让内存峰值失控）。
    static let chunkBytes = 64 * 1024

    /// 累计量（只在锁内读写）。
    private struct Accumulator {
        var retained = Data()
        var truncated = false
    }

    private let handle: FileHandle
    private let cap: Int
    private let lock = NSLock()
    private var acc = Accumulator()
    private var stopRequested = false
    private let finished = DispatchSemaphore(value: 0)

    /// - Parameters:
    ///   - handle: 管道读端。
    ///   - cap: 最多保留多少字节（`0` = 只抽干、不保留）。
    init(handle: FileHandle, cap: Int) {
        self.handle = handle
        self.cap = max(0, cap)
    }

    /// 启动后台抽干线程（幂等前提：只调一次）。
    func start() {
        let thread = Thread { [self] in drain() }
        thread.stackSize = 256 * 1024
        thread.start()
    }

    /// 等抽干读到 EOF（最多 `timeout` 秒）。
    ///
    /// - Returns: `true` = 正常读到 EOF；`false` = 超时（输出可能不完整）。
    @discardableResult
    func waitForCompletion(timeout: TimeInterval) -> Bool {
        finished.wait(timeout: .now() + max(0, timeout)) == .success
    }

    /// 当前抽干到的内容（线程安全；**边读边发布**，不是读完才可见）。
    var currentOutput: Output {
        lock.lock()
        defer { lock.unlock() }
        return Output(retained: acc.retained, truncated: acc.truncated)
    }

    /// 兜底：请求停止抽干（仅用于「子进程已死、却迟迟等不到 EOF」的异常路径）。
    ///
    /// ★ **不 `close()` 读端**：正在阻塞的 `read` 不会因此被唤醒，
    /// 反而可能让**下一次** `read` 打在已关闭的 `FileHandle` 上 ——
    /// `FileHandle` 抛的是 ObjC 异常（`NSFileHandleOperationException`），
    /// Swift 的 `catch` **接不住** ⇒ 直接崩。
    /// 停在一次 `read` 上的代价（一条后台线程）远小于崩溃。
    func stop() {
        lock.lock()
        stopRequested = true
        // 提前收手 ⇒ 拿到的不是全部 ⇒ 如实标「不完整」。
        acc.truncated = true
        lock.unlock()
    }

    /// 抽干循环（跑在后台线程上）。
    private func drain() {
        while true {
            if isStopRequested { break }
            let chunk: Data
            do {
                // `read(upToCount:)` 返回 `nil` 即 EOF（写端全部关闭）。
                guard let data = try handle.read(upToCount: UpstreamPipeDrainer.chunkBytes) else {
                    break
                }
                chunk = data
            } catch {
                // 读端被关 / 出错：停止（子进程已死或管道已拆）。
                break
            }
            if chunk.isEmpty {
                break // EOF：写端全部关闭
            }
            // ★ 边读边发布：调用方随时能看到「已经收到多少」
            // （兜底 `stop()` 后线程可能永远停在一次 `read` 上 ⇒ 已收数据不能丢）。
            lock.lock()
            if !acc.truncated {
                let room = cap - acc.retained.count
                if chunk.count <= room {
                    acc.retained.append(chunk)
                } else {
                    acc.retained.append(chunk.prefix(room))
                    acc.truncated = true
                }
            }
            lock.unlock()
            // 已超上限：**继续抽干**，只是不再保留
            // （停了子进程照样堵死在 `write` 上 ⇒ 问题原样复现）。
        }
        lock.lock()
        if stopRequested {
            acc.truncated = true
        }
        lock.unlock()
        finished.signal()
    }

    /// 是否已被请求停止（线程安全）。
    private var isStopRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }
}
