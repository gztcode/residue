import Foundation

/// 导出脱敏报告（AC-13 · G-5 / 技术方案 IF-12）。
///
/// **零遥测下的唯一排障通道**（K2 SRE 第 10 条）：产品不外发任何数据，
/// 用户自行导出脱敏报告贴到 GitHub Issue。因此这份报告必须能回答
/// **「为什么 L0 没看见」**——否则维护者只能看到「哪条 / 哪规则 / 哪时点」，看不到判定依据。
///
/// **两条硬约束**：
/// 1. **脱敏在导出时处理**（不是采集时），落盘的原始记录保持可诊断；
/// 2. **替换后原文串出现次数必须 = 0**，自检失败 → `E-401` → **不产出未脱敏文件**。
public enum Redactor {

    // MARK: - 替换标记

    public enum Placeholder: String, Sendable {
        case user = "<user>"
        case path = "<path>"
        case host = "<host>"
        case project = "<project>"
    }

    public enum RedactionError: Error, CustomStringConvertible {
        case leakedOriginalText([String])
        case missingSection(String)

        /// 对应的诊断码（**两者都是 `E-401`「导出脱敏自检失败」**）。
        ///
        /// 缺段与漏脱敏都是「导出物不可用」，用户可见结果同为「导出失败」。
        /// 之所以不拆两个码：`E-401` 的语义是「导出这一步没产出可用文件」，
        /// 两者在用户侧是同一件事；差异在日志细节里，不在码上。
        public var diagnostic: DiagnosticCode { .e401 }

        public var description: String {
            switch self {
            case .leakedOriginalText(let items):
                return "脱敏自检失败：以下原文串仍出现在导出物中：\(items.joined(separator: ", "))"
            case .missingSection(let name):
                return "报告缺少必需段落：\(name)（缺任一段即视为报告不可用）"
            }
        }
    }

    // MARK: - 报告的五段内容（IF-12）

    /// 报告的五个段落（**缺任一段即视为报告不可用**）。
    public enum Section: String, CaseIterable, Sendable {
        /// ① 环境段：appVersion / schemaVersion / macOS 版本 / arch（**不含主机名、不含用户名**）。
        case environment
        /// ② 量段：round / countedDays / 每来源的 T/K/J/H/a/b/state。
        case metrics
        /// ③ 取证段：degraded / coverage / pNowCount / fSetBits / doneCount（**来自 `scan.jsonl.diagnostics`**）。
        case diagnostics
        /// ④ 证据段：`evidence.jsonl` 与 `execution.jsonl` 的全量（逐行脱敏）。
        case evidence
        /// ⑤ 上游段：`upstreamCommands` 全量（**参数按 `<project>` 脱敏**）。
        case upstream
    }

    // MARK: - 输入

    /// 脱敏上下文：需要被替换的敏感片段。
    public struct Context: Sendable {
        /// 当前用户名（脱敏为 `<user>`）。
        public var userName: String
        /// 当前用户主目录（脱敏为 `<path>`）。
        public var homeDirectory: String
        /// 主机名（脱敏为 `<host>`）。
        public var hostName: String

        public init(userName: String, homeDirectory: String, hostName: String) {
            self.userName = userName
            self.homeDirectory = homeDirectory
            self.hostName = hostName
        }

        /// 默认上下文：从当前进程环境取。
        public static func current() -> Context {
            let nsUser = ProcessInfo.processInfo.environment["USER"]
                ?? NSUserName()
            let home = NSHomeDirectory()
            let host = ProcessInfo.processInfo.environment["HOSTNAME"]
                ?? ProcessInfo.processInfo.hostName
            return Context(userName: nsUser, homeDirectory: home, hostName: host)
        }
    }

    /// 一条诊断记录（`scan.jsonl.diagnostics` 的回显）。
    public struct Diagnostics: Codable, Sendable, Equatable {
        public var degraded: Bool
        public var sameUIDTotal: Int
        public var sameUIDRead: Int
        public var statOtherUID: Int
        public var pNowCount: Int
        public var fSetBits: Int
        public var doneCount: Int
        public var contentReads: Int
        public var round: Int
        public var countedDays: Int
        public var a: Int
        public var b: Int

        public init(
            degraded: Bool, sameUIDTotal: Int, sameUIDRead: Int, statOtherUID: Int,
            pNowCount: Int, fSetBits: Int, doneCount: Int, contentReads: Int,
            round: Int, countedDays: Int, a: Int, b: Int
        ) {
            self.degraded = degraded
            self.sameUIDTotal = sameUIDTotal
            self.sameUIDRead = sameUIDRead
            self.statOtherUID = statOtherUID
            self.pNowCount = pNowCount
            self.fSetBits = fSetBits
            self.doneCount = doneCount
            self.contentReads = contentReads
            self.round = round
            self.countedDays = countedDays
            self.a = a
            self.b = b
        }
    }

    /// 一个来源的量读数（② 量段）。
    public struct SourceMetrics: Codable, Sendable, Equatable {
        public var source: String
        public var state: String
        public var t: Int?
        public var k: Int?
        public var j: Int?
        public var h: Int?
        public var a: Int
        public var b: Int

        public init(source: String, state: String, t: Int?, k: Int?, j: Int?, h: Int?, a: Int, b: Int) {
            self.source = source
            self.state = state
            self.t = t
            self.k = k
            self.j = j
            self.h = h
            self.a = a
            self.b = b
        }
    }

    /// 一次上游只读命令的调用（⑤ 上游段）。
    public struct UpstreamCommand: Codable, Sendable, Equatable {
        public var cmd: String
        public var args: [String]
        public var exitCode: Int32
        public var durationMs: Int
        public var invokedAt: Date

        public init(cmd: String, args: [String], exitCode: Int32, durationMs: Int, invokedAt: Date) {
            self.cmd = cmd
            self.args = args
            self.exitCode = exitCode
            self.durationMs = durationMs
            self.invokedAt = invokedAt
        }
    }

    /// 报告的全部输入。
    public struct Report: Sendable {
        public var appVersion: String
        public var schemaVersion: Int
        public var osVersion: String
        public var arch: String
        public var sources: [SourceMetrics]
        public var diagnostics: Diagnostics
        public var evidenceLines: [String]
        public var executionLines: [String]
        public var upstreamCommands: [UpstreamCommand]

        public init(
            appVersion: String, schemaVersion: Int, osVersion: String, arch: String,
            sources: [SourceMetrics], diagnostics: Diagnostics,
            evidenceLines: [String], executionLines: [String],
            upstreamCommands: [UpstreamCommand]
        ) {
            self.appVersion = appVersion
            self.schemaVersion = schemaVersion
            self.osVersion = osVersion
            self.arch = arch
            self.sources = sources
            self.diagnostics = diagnostics
            self.evidenceLines = evidenceLines
            self.executionLines = executionLines
            self.upstreamCommands = upstreamCommands
        }
    }

    // MARK: - 脱敏

    /// 对一段文本做脱敏。
    ///
    /// **顺序必须「先长后短」**：先替 `homeDirectory`（`/Users/alice`）再替 `userName`（`alice`）。
    /// 反过来会先把路径里的用户名替掉 → home 原串被切碎 → `<path>` 占位符永远不出现，
    /// 且自检会因「原串已不存在」而**假通过**（K2 实测：这是「替换后原文出现次数 = 0」的
    /// 一个典型假绿 —— 断言过了，但数据没脱对）。
    ///
    /// **长度下限 = 3**：过短的串（1–2 字符）必然误报（如用户名恰为 "ab" 时全文命中），
    /// 故**替换与自检用同一套长度规则**，不允许一个判敏感另一个不判。
    public static func redact(
        _ text: String,
        context: Context,
        projectNames: [String] = []
    ) -> String {
        var out = text
        // 按长度降序替换（长的先替）
        var rules: [(String, String)] = [
            (context.homeDirectory, Placeholder.path.rawValue),
            (context.userName, Placeholder.user.rawValue),
            (context.hostName, Placeholder.host.rawValue),
        ]
        // **项目名由调用方显式给**，不靠字符串猜。
        //
        // ## 为什么不猜（这条是设计决定，不是偷懒）
        // `Placeholder.project` 一直定义了却从没被使用 —— IF-12 要求
        // 「参数按 `<project>` 脱敏」，而实现里没有这条规则（真缺陷）。
        //
        // 但「哪个词是项目名」无法从字符串可靠推断：
        // 路径 `~/.cache/uv` 里的 `uv` 是工具名不是项目名，
        // 而 `~/projects/my-app` 里的 `my-app` 是项目名。
        // 按「home 后第一段」猜会把 `uv` / `Library` / `Documents` 全打成 `<project>`。
        //
        // **正解是由知道答案的一方给**：产品在扫描 MCP 配置时本来就知道
        // 项目根在哪（那是解析出来的），把它传进来即可。这样既不猜、也不漏。
        for name in projectNames where name.count >= 3 {
            rules.append((name, Placeholder.project.rawValue))
        }
        for (needle, placeholder) in rules.sorted(by: { $0.0.count > $1.0.count }) {
            guard needle.count >= 3 else { continue }
            out = out.replacingOccurrences(of: needle, with: placeholder)
        }
        return out
    }

    /// 脱敏一条上游命令的**参数**（项目名 → `<project>`）。
    ///
    /// 只替换「看起来像路径参数」的值（`--cwd=/path`、`/abs/path`），
    /// 纯参数名与布尔开关**不动**（它们不含敏感信息，替换了反而降低可诊断性）。
    public static func redactArguments(
        _ args: [String],
        context: Context,
        projectNames: [String] = []
    ) -> [String] {
        // ⚠️ **所有参数都要脱敏**，不能只挑「像路径的」。
        //
        // 第一版写成 `if arg.hasPrefix("/") || arg.contains("=/")`，
        // 于是 `--user tom` / `--author tom` / `-u tom` 这类**裸用户名参数
        // 原样进报告**（实测：自检的「注入的用户名已被替换」这条失败）。
        //
        // P5 要求脱敏「可识别元数据」——**裸用户名就是最典型的一种**，
        // 而且它比路径更容易被忽略，因为它看起来「不像路径」。
        //
        // 代价：对 `--verbose` 这类纯开关参数也跑一次字符串替换。
        // 那只是几次 `replacingOccurrences`，与泄漏一个用户名相比不值一提。
        args.map { redact($0, context: context, projectNames: projectNames) }
    }

    // MARK: - 渲染

    /// 渲染完整报告（**五段齐全，缺任一段即报错**）。
    public static func render(_ report: Report, context: Context) throws -> String {
        var lines: [String] = []
        lines.append("# Residue 脱敏诊断报告")
        lines.append("")
        lines.append("> 本报告由用户在本地导出，已完成脱敏；产品不自动外发任何数据。")
        lines.append("")

        // ① 环境段
        lines.append("## ① 环境")
        lines.append("")
        lines.append("| 项 | 值 |")
        lines.append("|---|---|")
        lines.append("| appVersion | \(redact(report.appVersion, context: context)) |")
        lines.append("| schemaVersion | \(report.schemaVersion) |")
        lines.append("| osVersion | \(redact(report.osVersion, context: context)) |")
        lines.append("| arch | \(report.arch) |")
        lines.append("")

        // ② 量段
        lines.append("## ② 量")
        lines.append("")
        lines.append("| 来源 | 状态 | T | K | J | H | a | b |")
        lines.append("|---|---|---|---|---|---|---|---|")
        for s in report.sources {
            func cell(_ v: Int?) -> String { v.map(String.init) ?? "—" }
            lines.append("| \(s.source) | \(s.state) | \(cell(s.t)) | \(cell(s.k)) | \(cell(s.j)) | \(cell(s.h)) | \(s.a) | \(s.b) |")
        }
        lines.append("")

        // ③ 取证段
        let d = report.diagnostics
        lines.append("## ③ 取证")
        lines.append("")
        lines.append("| 项 | 值 |")
        lines.append("|---|---|")
        lines.append("| degraded | \(d.degraded) |")
        lines.append("| coverage.sameUIDTotal | \(d.sameUIDTotal) |")
        lines.append("| coverage.sameUIDRead | \(d.sameUIDRead) |")
        lines.append("| coverage.statOtherUID | \(d.statOtherUID) |")
        lines.append("| pNowCount | \(d.pNowCount) |")
        lines.append("| fSetBits | \(d.fSetBits) |")
        lines.append("| doneCount | \(d.doneCount) |")
        lines.append("| contentReads | \(d.contentReads) |")
        lines.append("| round | \(d.round) |")
        lines.append("| countedDays | \(d.countedDays) |")
        lines.append("| a | \(d.a) |")
        lines.append("| b | \(d.b) |")
        lines.append("")

        // ④ 证据段
        lines.append("## ④ 证据")
        lines.append("")
        lines.append("### 举证链")
        lines.append("")
        lines.append("```jsonl")
        for l in report.evidenceLines { lines.append(redact(l, context: context)) }
        lines.append("```")
        lines.append("")
        lines.append("### 执行日志")
        lines.append("")
        lines.append("```jsonl")
        for l in report.executionLines { lines.append(redact(l, context: context)) }
        lines.append("```")
        lines.append("")

        // ⑤ 上游段
        lines.append("## ⑤ 上游")
        lines.append("")
        lines.append("| 命令 | 参数 | 退出码 | 耗时 ms | 时刻 |")
        lines.append("|---|---|---|---|---|")
        for c in report.upstreamCommands {
            let args = redactArguments(c.args, context: context).joined(separator: " ")
            lines.append("| `\(c.cmd)` | \(args.isEmpty ? "—" : args) | \(c.exitCode) | \(c.durationMs) | \(c.invokedAt.ISO8601Format()) |")
        }
        lines.append("")

        let text = lines.joined(separator: "\n")

        // 五段齐全性检查（**缺任一段即不可用**）
        for section in Section.allCases {
            let marker = section.marker
            guard text.contains(marker) else {
                throw RedactionError.missingSection(section.rawValue)
            }
        }

        // 脱敏自检的前置：**至少有一个原串参与检查**。
        // 否则「Context 没配好 → 什么都没脱 → 自检通过」= 假绿通道（K2 用例实测命中）。
        guard hasRedactionBasis(context) else {
            throw RedactionError.leakedOriginalText(["<无任何原串参与自检>"])
        }

        // 脱敏自检：**替换后原文串出现次数必须 = 0**
        let stillPresent = originals(in: text, context: context).filter { text.contains($0) }
        if !stillPresent.isEmpty {
            throw RedactionError.leakedOriginalText(stillPresent)
        }
        return text
    }

    /// 参与自检的原文串（**跳过空串与过短串**——短到 1 个字符的串必然误报）。
    ///
    /// **「跳过」不等于「不检查」**：若三个原串**全部**被跳过（例如 Context 为空），
    /// 则**没有任何东西被检查过** —— 此时自检形同虚设，必须**报错而不是放行**。
    /// 否则「Context 没配好 → 什么都没脱 → 自检通过」会成为一条**假绿通道**。
    private static func originals(in text: String, context: Context) -> [String] {
        var items: [String] = []
        for s in [context.userName, context.homeDirectory, context.hostName] where s.count >= 3 {
            items.append(s)
        }
        return items
    }

    /// 自检的前置条件：**必须至少有一个原串参与检查**。
    public static func hasRedactionBasis(_ context: Context) -> Bool {
        !originals(in: "", context: context).isEmpty
    }

    /// 把报告写到文件；**自检失败时不产出文件**（不留下未脱敏的半成品）。
    public static func export(
        _ report: Report,
        context: Context,
        to destination: URL
    ) throws -> URL {
        let text = try render(report, context: context)
        let dir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }

}

extension Redactor.Section {
    /// 段落标记（用于「五段齐全」检查）。
    var marker: String {
        switch self {
        case .environment: return "## ① 环境"
        case .metrics: return "## ② 量"
        case .diagnostics: return "## ③ 取证"
        case .evidence: return "## ④ 证据"
        case .upstream: return "## ⑤ 上游"
        }
    }
}
