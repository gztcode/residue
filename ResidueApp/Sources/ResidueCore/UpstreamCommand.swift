import Foundation

// ============================================================
// Residue · 上游只读命令（AC-19 / R2 §5.4 / N6）
//
// ## 唯一允许的上游能力 = 只读定位与举证
// AC-19 的可执行集合**封闭**为只读命令（用于取缓存目录、列条目、取证）。
// **不含任何直接删文件的上游命令**——删除动作一律由产品按 N5 原子
// `rename` 到废纸篓（`TrashExecutor`）。
//
// ## 白名单是**封闭**的，不是黑名单
// 不在白名单里的一律拒绝执行（`rejectedByWhitelist`）。
// 用黑名单的话，任何没被想到的删除命令都能漏过去 —— 而 AC-19 要求的是
// 「直接删文件的上游命令出现次数 = 0」，这是个**全称命题**，只有白名单能证。
//
// ## 每次调用必须落一行
// §5.4：`upstreamCommands` 是 AC-19 的唯一可判载体；
// **未落盘即视为「无法证明」，验收按不通过处理**。
// 故本 runner 的 `run()` **返回 `UpstreamCommand` 记录**，
// 调用方必须把它写进 `scan.jsonl` 的 `upstreamCommands`（`RecordWriter` 负责）。
//
// ## 环境约束（N6）
// - 单探测 ≤ 2 s、总探测 ≤ 10 s
// - 只读命令**全部纯本地**、不产生外发、不附带网络动作（CR-002 裁决）
// - 探测失败按 §8「错误」+ P4「无法判定」处理，**不挂 AC-14**
// ============================================================

/// 一次上游命令调用的记录（§5.4 `upstreamCommands` 的元素）。
public struct UpstreamCommand: Codable, Sendable, Equatable {
    /// 可执行文件（**绝对路径或 PATH 中的裸名**，见 `resolveExecutable`）。
    public var cmd: String
    /// 参数。
    public var args: [String]
    /// 退出码（未执行 / 超时用 `nil`）。
    public var exitCode: Int32?
    /// 耗时（毫秒）。
    public var durationMs: Int
    /// 调用时刻（**精确到调用开始**）。
    public var invokedAt: Date
    /// 是否被白名单拒绝（`true` 时 `exitCode` 为 `nil`、未真正执行）。
    public var rejectedByWhitelist: Bool
    /// 未执行 / 失败的原因（`nil` = 正常执行）。
    public var failure: String?

    public init(
        cmd: String,
        args: [String],
        exitCode: Int32?,
        durationMs: Int,
        invokedAt: Date,
        rejectedByWhitelist: Bool = false,
        failure: String? = nil
    ) {
        self.cmd = cmd
        self.args = args
        self.exitCode = exitCode
        self.durationMs = durationMs
        self.invokedAt = invokedAt
        self.rejectedByWhitelist = rejectedByWhitelist
        self.failure = failure
    }
}

/// 上游命令的白名单条目（**封闭集合**）。
public enum UpstreamWhitelist {

    /// 允许的「可执行 + 参数前缀」组合。
    ///
    /// 判据 = **可执行名匹配 且 参数以给定前缀开头**。
    /// 只匹配可执行名不够——`uv cache dir` 与 `uv cache clean` 是同一个可执行，
    /// 只按可执行名放行等于把 `cache clean` 也放行了。
    public struct Entry: Sendable {
        public let executable: String
        public let argumentPrefix: [String]
        /// 用途说明（写进代码，便于后续维护者理解为什么它在这个集合里）。
        public let purpose: String

        public init(executable: String, argumentPrefix: [String], purpose: String) {
            self.executable = executable
            self.argumentPrefix = argumentPrefix
            self.purpose = purpose
        }
    }

    /// AC-19 的可执行集合（**只读定位与举证**）。
    ///
    /// 每条都对应「取缓存目录 / 列条目」这类**只读**用途。
    /// 新增条目必须同时确认：① 纯本地无外发；② 不产生任何写 / 删动作；
    /// ③ 不与 §7 的第三方回调冲突。
    public static let entries: [Entry] = [
        .init(executable: "uv", argumentPrefix: ["cache", "dir"],
              purpose: "取 uv 缓存目录（只读定位）"),
        .init(executable: "npm", argumentPrefix: ["cache", "ls"],
              purpose: "列 npm 缓存条目（只读举证）"),
        .init(executable: "npm", argumentPrefix: ["config", "get", "cache"],
              purpose: "取 npm 缓存目录（只读定位）"),
        .init(executable: "brew", argumentPrefix: ["--cache"],
              purpose: "取 Homebrew 缓存目录（只读定位）"),
        .init(executable: "pipx", argumentPrefix: ["list"],
              purpose: "列 pipx 环境（只读举证；**不含过期清理**）"),
        .init(executable: "pipx", argumentPrefix: ["environment"],
              purpose: "取 pipx 环境目录（只读定位）"),
    ]

    /// **显式拒绝清单**（即便参数恰好匹配前缀也拒绝）。
    ///
    /// 这一层是**防御性冗余**：白名单已经足够（不在其中即拒），
    /// 但把已知的危险命令写下来，能让「为什么它被拒」在代码里可读，
    /// 也让后续维护者不会误把它加进白名单。
    public static let explicitlyForbidden: [Entry] = [
        .init(executable: "uv", argumentPrefix: ["cache", "clean"],
              purpose: "直接删文件的上游命令（AC-19 禁止）"),
        .init(executable: "uv", argumentPrefix: ["cache", "prune"],
              purpose: "直接删文件的上游命令（AC-19 禁止）"),
        .init(executable: "npm", argumentPrefix: ["cache", "clean"],
              purpose: "直接删文件的上游命令（AC-19 禁止）"),
        .init(executable: "brew", argumentPrefix: ["cleanup"],
              purpose: "直接删文件的上游命令（AC-19 禁止）"),
        .init(executable: "trash-put", argumentPrefix: [],
              purpose: "非 macOS 原生第三方命令，2C 不能假设已装（AC-19 已剔除）"),
    ]

    /// 判定一次调用是否在白名单内。
    ///
    /// - Returns: 放行返回 `nil`；拒绝返回原因串。
    public static func rejectionReason(executable: String, args: [String]) -> String? {
        let name = (executable as NSString).lastPathComponent

        // ① 显式拒绝优先（防御性冗余，先判）
        for e in explicitlyForbidden where e.executable == name {
            if startsWith(args, e.argumentPrefix) {
                return "`\(name) \(e.argumentPrefix.joined(separator: " "))` 被显式拒绝：\(e.purpose)"
            }
        }

        // ② 白名单
        for e in entries where e.executable == name {
            if startsWith(args, e.argumentPrefix) { return nil }
        }

        // ③ 不在白名单 → 拒（**封闭集合**）
        return "`\(name) \(args.joined(separator: " "))` 不在只读白名单内（AC-19 封闭集合）"
    }

    private static func startsWith(_ args: [String], _ prefix: [String]) -> Bool {
        guard args.count >= prefix.count else { return false }
        for (i, p) in prefix.enumerated() where args[i] != p { return false }
        return true
    }
}

/// 上游只读命令执行器。
///
/// **所有调用都返回一条 `UpstreamCommand` 记录**——调用方必须把它写进
/// `scan.jsonl.upstreamCommands`（§5.4）。未落盘即「无法证明」。
public struct UpstreamRunner: Sendable {

    /// 单次探测超时（N6：单探测 ≤ 2 s）。
    public let perProbeTimeout: TimeInterval
    /// 总探测预算（N6：总探测 ≤ 10 s）。
    public let totalBudget: TimeInterval

    /// 本次 runner 已消耗的时间（用于总预算判定）。
    private let consumed: TimeInterval

    public init(perProbeTimeout: TimeInterval = 2.0, totalBudget: TimeInterval = 10.0, consumed: TimeInterval = 0) {
        self.perProbeTimeout = perProbeTimeout
        self.totalBudget = totalBudget
        self.consumed = consumed
    }

    /// 一次调用的结果：记录 + 标准输出（若有）。
    public struct RunOutcome: Sendable {
        public var record: UpstreamCommand
        /// 标准输出（被截断到 `maxOutputBytes`）；拒绝 / 失败时为 `nil`。
        public var stdout: String?
    }

    /// 读上游命令输出时最多保留的字节数（防止超大输出占内存）。
    public let maxOutputBytes = 64 * 1024

    /// 执行一条上游只读命令。
    ///
    /// - Parameters:
    ///   - executable: 可执行名（如 `uv`）。
    ///   - args: 参数（如 `["cache", "dir"]`）。
    ///   - searchPath: 可执行文件的搜索路径（默认用环境 `PATH`）。
    ///
    /// **无论放行、拒绝还是失败，都返回一条记录**——这是「未落盘即无法证明」的前提。
    public func run(
        executable: String,
        args: [String],
        searchPath: [String]? = nil,
        now: Date = Date()
    ) -> RunOutcome {
        let started = Date()

        // ① 白名单判定（**先判，再执行**）
        if let reason = UpstreamWhitelist.rejectionReason(executable: executable, args: args) {
            return RunOutcome(
                record: UpstreamCommand(
                    cmd: executable, args: args,
                    exitCode: nil,
                    durationMs: 0,
                    invokedAt: now,
                    rejectedByWhitelist: true,
                    failure: reason
                ),
                stdout: nil
            )
        }

        // ② 总预算判定（N6）
        if consumed + perProbeTimeout > totalBudget + 1e-9 {
            return RunOutcome(
                record: UpstreamCommand(
                    cmd: executable, args: args,
                    exitCode: nil,
                    durationMs: 0,
                    invokedAt: now,
                    rejectedByWhitelist: false,
                    failure: "探测总预算 \(totalBudget) s 已耗尽（N6）"
                ),
                stdout: nil
            )
        }

        // ③ 解析可执行路径（找不到 = 能力缺失，按 P4「无法判定」处理，不挂 AC-14）
        guard let resolved = resolveExecutable(executable, searchPath: searchPath) else {
            return RunOutcome(
                record: UpstreamCommand(
                    cmd: executable, args: args,
                    exitCode: nil,
                    durationMs: Int(Date().timeIntervalSince(started) * 1000),
                    invokedAt: now,
                    rejectedByWhitelist: false,
                    failure: "可执行文件未找到：\(executable)（CLI 不存在 → P4 无法判定）"
                ),
                stdout: nil
            )
        }

        // ④ 执行
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: resolved)
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        var failure: String?
        var exitCode: Int32?
        do {
            try proc.run()
            // 超时保护：不阻塞主线程，轮询等待
            let deadline = started.addingTimeInterval(perProbeTimeout)
            while proc.isRunning && Date() < deadline {
                usleep(10_000)   // 10 ms
            }
            if proc.isRunning {
                proc.terminate()
                failure = "超时（>\(perProbeTimeout) s，N6 单探测预算）"
            } else {
                exitCode = proc.terminationStatus
            }
        } catch {
            failure = "启动失败：\(error.localizedDescription)"
        }

        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        var stdout: String?
        if failure == nil {
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let clipped = data.prefix(maxOutputBytes)
            stdout = String(decoding: clipped, as: UTF8.self)
        }

        return RunOutcome(
            record: UpstreamCommand(
                cmd: executable, args: args,
                exitCode: exitCode,
                durationMs: elapsedMs,
                invokedAt: now,
                rejectedByWhitelist: false,
                failure: failure
            ),
            stdout: stdout
        )
    }

    /// 在 `searchPath`（或环境 `PATH`）里找可执行文件。
    ///
    /// **只接受绝对路径解析结果**：不信任当前工作目录（防 PATH 劫持，
    /// 检查表 S-07 的那一类风险）。
    public func resolveExecutable(_ name: String, searchPath: [String]? = nil) -> String? {
        let fm = FileManager.default
        // 已是绝对路径
        if name.hasPrefix("/") {
            return fm.isExecutableFile(atPath: name) ? name : nil
        }
        let paths = searchPath
            ?? (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":").map(String.init)
        for dir in paths {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
