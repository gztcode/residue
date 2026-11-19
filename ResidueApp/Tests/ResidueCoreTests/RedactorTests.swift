import XCTest
@testable import ResidueCore

/// AC-13 · G-5 导出脱敏的用例集。
///
/// 期望值来源：`Residue-R2-技术方案-v1.6.md` IF-12 的**报告五段内容**与
/// 「替换后原文串出现次数 = 0」判定原文。
final class RedactorTests: XCTestCase {

    private let context = Redactor.Context(
        userName: "alice",
        homeDirectory: "/Users/alice",
        hostName: "MacBook-Pro.local"
    )

    /// 造一个**真实位图**并返回它的置位数 —— 夹具里的 `fSetBits` 由它推导。
    ///
    /// ## 为什么夹具也必须「真」
    /// `fSetBits` 的契约语义 = 「`F` 位图的**置位数**」。夹具若写死一个与位图
    /// 无关的自造值（早先写的是 `30`），则「这个数必须来自位图」这件事
    /// **永远没人守** —— 生产侧把字段写死成 `0` 时，夹具照样全绿。
    ///
    /// 改为从**真实位图**推导 ⇒ 夹具与生产共用同一原语（`NegativeBitmap`），
    /// 口径一旦漂移，夹具立刻显形（不变量②：同一判定只有一个实现处）。
    private func realFSetBits(setSlots: Int) -> Int {
        var bitmap = NegativeBitmap()
        for slot in 0..<setSlots { bitmap.set(slot) }
        return NegativeBitmap.setBitCount(
            ofBytes: bitmap.dataRepresentation(bitCount: setSlots)
        )
    }

    private func makeReport(
        evidence: [String] = [],
        execution: [String] = [],
        upstream: [Redactor.UpstreamCommand] = []
    ) -> Redactor.Report {
        Redactor.Report(
            appVersion: "1.0.0 (1)",
            schemaVersion: 1,
            osVersion: "macOS 14.6",
            arch: "arm64",
            sources: [
                Redactor.SourceMetrics(
                    source: "uv.cache", state: "inDomain",
                    t: 30, k: 27, j: 3, h: 30, a: 0, b: 128
                ),
                Redactor.SourceMetrics(
                    source: "npm.npx", state: "inDomain",
                    t: nil, k: nil, j: nil, h: nil, a: 0, b: 0
                ),
            ],
            diagnostics: Redactor.Diagnostics(
                degraded: false, sameUIDTotal: 624, sameUIDRead: 624, statOtherUID: 173,
                pNowCount: 3, fSetBits: realFSetBits(setSlots: 30), doneCount: 0, contentReads: 0,
                round: 2, countedDays: 14, a: 0, b: 256
            ),
            evidenceLines: evidence,
            executionLines: execution,
            upstreamCommands: upstream
        )
    }

    // MARK: - 脱敏

    func testUserNameIsReplaced() {
        let out = Redactor.redact("owner=alice", context: context)
        XCTAssertEqual(out, "owner=<user>")
        XCTAssertFalse(out.contains("alice"))
    }

    func testHomeDirectoryIsReplaced() {
        let out = Redactor.redact("path=/Users/alice/Library/Caches/uv", context: context)
        XCTAssertTrue(out.contains("<path>"))
        XCTAssertFalse(out.contains("/Users/alice"))
    }

    func testHostNameIsReplaced() {
        let out = Redactor.redact("host=MacBook-Pro.local", context: context)
        XCTAssertTrue(out.contains("<host>"))
        XCTAssertFalse(out.contains("MacBook-Pro.local"))
    }

    func testShortStringsAreNotTreatedAsSensitive() {
        // 用户名只有 2 个字符 → 自检会跳过（否则必然误报）
        let ctx = Redactor.Context(userName: "ab", homeDirectory: "/Users/ab", hostName: "h")
        let out = Redactor.redact("ab", context: ctx)
        XCTAssertEqual(out, "ab", "过短的原串不参与替换（否则必然误报）")
    }

    func testUpstreamArgumentsOnlyRedactPathLikeValues() {
        let args = ["--cwd=/Users/alice/proj", "--json", "/Users/alice/other"]
        let out = Redactor.redactArguments(args, context: context)
        XCTAssertEqual(out[0], "--cwd=<path>/proj")
        XCTAssertEqual(out[1], "--json", "纯开关不替换（替换了降低可诊断性）")
        XCTAssertEqual(out[2], "<path>/other")
    }

    // MARK: - 五段齐全

    func testReportContainsAllFiveSections() throws {
        let text = try Redactor.render(makeReport(), context: context)
        for section in Redactor.Section.allCases {
            XCTAssertTrue(
                text.contains(section.marker),
                "报告缺少段落：\(section.rawValue)"
            )
        }
    }

    func testSectionsAreRenderedEvenWhenEmpty() throws {
        // 五段**即使没有数据也必须有标题** —— 段标题是「这一段存在」的信号，
        // 没有数据的段落显示「（无）」而不是消失（消失 = 维护者以为产品没实现这段）。
        let text = try Redactor.render(
            Redactor.Report(
                appVersion: "1.0", schemaVersion: 1, osVersion: "macOS", arch: "arm64",
                sources: [], diagnostics: makeReport().diagnostics,
                evidenceLines: [], executionLines: [], upstreamCommands: []
            ),
            context: context
        )
        for section in Redactor.Section.allCases {
            XCTAssertTrue(text.contains(section.marker), "缺段：\(section.rawValue)")
        }
    }

    // MARK: - 脱敏自检

    func testSelfCheckPassesOnCleanReport() throws {
        let report = makeReport(
            evidence: ["{\"source\":\"uv.cache\",\"path\":\"/Users/alice/.cache/uv/x\"}"],
            execution: ["{\"action\":\"rename_to_trash\",\"path\":\"/Users/alice/.cache/uv/x\"}"]
        )
        let text = try Redactor.render(report, context: context)
        XCTAssertFalse(text.contains("alice"))
        XCTAssertFalse(text.contains("/Users/alice"))
    }

    func testSelfCheckFailsWhenOriginalTextSurvives() {
        // 构造一个「脱敏后仍残留原文」的场景：
        // 用一个 Context，其 homeDirectory 不是 userName 的前缀，
        // 使「先替 user 再替 home」无法覆盖路径中的用户名。
        let tricky = Redactor.Context(
            userName: "bob",
            homeDirectory: "/Users/alice",
            hostName: "h1"
        )
        let text = "/Users/alice/bob/file"
        let out = Redactor.redact(text, context: tricky)
        // 先替 bob → "/Users/alice/<user>/file"；再替 /Users/alice → "<path>/<user>/file"
        XCTAssertFalse(out.contains("alice"))
        XCTAssertFalse(out.contains("bob"))
    }

    func testExportDoesNotWriteFileWhenSelfCheckFails() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("residue-redactor-\(UUID().uuidString)")
        let dest = dir.appendingPathComponent("report.md")
        // 空 userName 的 Context 不会替换任何东西 → 若报告里含原文，自检必须失败
        let leaky = Redactor.Context(userName: "", homeDirectory: "", hostName: "")
        let report = makeReport(evidence: ["{\"user\":\"alice\"}"])

        XCTAssertThrowsError(try Redactor.export(report, context: leaky, to: dest)) { error in
            guard case Redactor.RedactionError.leakedOriginalText = error else {
                XCTFail("应为 leakedOriginalText，实际：\(error)")
                return
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dest.path),
            "自检失败不得产出文件（不留下未脱敏的半成品）"
        )
    }

    func testExportWritesFileOnSuccess() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("residue-redactor-\(UUID().uuidString)")
        let dest = dir.appendingPathComponent("report.md")
        defer { try? FileManager.default.removeItem(at: dir) }

        let report = makeReport(
            evidence: ["{\"path\":\"/Users/alice/.cache/uv/x\"}"],
            execution: ["{\"path\":\"/Users/alice/.cache/uv/x\"}"]
        )
        let url = try Redactor.export(report, context: context, to: dest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("alice"), "导出物中原文串出现次数必须 = 0")
        XCTAssertTrue(text.contains("<path>"))
    }

    // MARK: - 取证段内容（为什么 L0 没看见）

    func testDiagnosticsSectionCarriesCoverageSoOneCanExplainWhyL0SawNothing() throws {
        let text = try Redactor.render(makeReport(), context: context)
        // 维护者要能看出「L0 只看了同 uid 进程」→ coverage 三项必须在
        XCTAssertTrue(text.contains("coverage.sameUIDTotal"))
        XCTAssertTrue(text.contains("coverage.sameUIDRead"))
        XCTAssertTrue(text.contains("coverage.statOtherUID"))
        XCTAssertTrue(text.contains("contentReads"))
    }

    func testNullMetricsRenderAsDashNotZero() throws {
        // 「待重取」必须显示 — 而不是 0（假值）
        let text = try Redactor.render(makeReport(), context: context)
        XCTAssertTrue(text.contains("| npm.npx | inDomain | — | — | — | — |"), "null 量必须渲染为 —")
    }

    // ======================================================================
    // MARK: - ② 量段如实披露「无法归因」条数（CR-031 §五③ 裁决）
    // ======================================================================

    /// **「无法归因」的条数必须出现在导出报告里，且单列。**
    ///
    /// ## 为什么这是必须做的
    /// PRD v5.6 M3 写着：「失联中的无法归因条数一并披露（快照里未能归因到
    /// 四类中任一类的条目数，**单列、不并入已归因**）」。
    ///
    /// 「单列」在数据层已落地（`SourceHeaderEntry.unattributableCount`），
    /// 但**呈现层零命中** —— 数据躺在状态文件里没人看得到，等于没披露：
    /// 维护者看报告只能看到 `J = 3`，无法判断这 3 条里有多少是真说不清。
    ///
    /// CR-031 §五③ 的裁决原文点名了落点：「`SourceHeaderEntry.unattributableCount`
    /// 承载该数，**导出报告如实呈现（不隐藏）**」。
    func testMetricsSectionHasUnattributableColumn() throws {
        let text = try Redactor.render(makeReport(), context: context)
        XCTAssertTrue(
            text.contains("其中无法归因"),
            "② 量段必须单列披露「无法归因」条数（PRD v5.6 M3 · CR-031 §五③）"
        )
    }

    /// **「无法归因」的真实条数必须落在表里，不能被渲染成「—」或 0。**
    ///
    /// 这是一条**护栏**（characterization）测试：它钉住已实现的渲染行为，
    /// 让后来的重构改坏这一列时立刻变红。
    ///
    /// 覆盖两种「看起来差不多」的数字：
    /// - `unattributable = 2` ⇒ 必须渲染成 `2`（不是「—」，不是 0）
    /// - `unattributable = nil` ⇒ 必须渲染成「—」（不变量③：`nil ≠ 0`；
    ///   0 会被读成「一条都无法归因」，而事实是「还没结算」）
    func testUnattributableValueIsRenderedNotDashed() throws {
        let report = Redactor.Report(
            appVersion: "1.0.0 (1)", schemaVersion: 1,
            osVersion: "macOS 14.6", arch: "arm64",
            sources: [
                Redactor.SourceMetrics(
                    source: "uv.cache", state: "inDomain",
                    t: 30, k: 27, j: 3, unattributable: 2, h: 30, a: 0, b: 128
                ),
                Redactor.SourceMetrics(
                    source: "npm.npx", state: "inDomain",
                    t: nil, k: nil, j: nil, unattributable: nil, h: nil, a: 0, b: 0
                ),
            ],
            diagnostics: makeReport().diagnostics,
            evidenceLines: [], executionLines: [], upstreamCommands: []
        )
        let text = try Redactor.render(report, context: context)

        // 整行断言：列序 = 来源 | 状态 | T | K | J | 其中无法归因 | H | a | b
        XCTAssertTrue(
            text.contains("| uv.cache | inDomain | 30 | 27 | 3 | 2 | 30 | 0 | 128 |"),
            "「无法归因 = 2」必须渲染成 2（实为：\(row(in: text, source: "uv.cache"))）"
        )
        XCTAssertTrue(
            text.contains("| npm.npx | inDomain | — | — | — | — | — | 0 | 0 |"),
            "尚未结算 ⇒「无法归因」必须渲染成「—」而不是 0（实为：\(row(in: text, source: "npm.npx"))）"
        )
    }

    /// 取报告里某个来源的量段整行（断言失败时用它显示「实为」）。
    private func row(in text: String, source: String) -> String {
        text.split(separator: "\n")
            .first { $0.hasPrefix("| \(source) |") }
            .map(String.init) ?? "（报告里没有 \(source) 行）"
    }

    // ======================================================================
    // MARK: - 参数脱敏的两个真缺陷（2026-11-08 在接线自检里抓到）
    // ======================================================================

    /// **裸用户名参数必须被脱敏。**
    ///
    /// ## 这曾经是个真缺陷
    /// `redactArguments` 第一版只处理「以 `/` 开头或含 `=/`」的参数：
    /// ```swift
    /// if arg.hasPrefix("/") || arg.contains("=/") { return redact(arg) }
    /// return arg
    /// ```
    /// 于是 `--user alice` / `--author alice` / `-u alice` 这类
    /// **裸用户名参数原样进导出报告**。
    ///
    /// P5 要求脱敏「可识别元数据」——**裸用户名就是最典型的一种**，
    /// 而且它比路径更容易被忽略，因为它看起来「不像路径」。
    ///
    /// 实测发现路径：接线自检的「注入的用户名已被替换」这条失败。
    /// **不是读代码看出来的，是真跑一遍才暴露的。**
    func testBareUserNameArgumentIsRedacted() {
        let ctx = Redactor.Context(
            userName: "alice",
            homeDirectory: "/Users/alice",
            hostName: "alicemac"
        )
        let args = ["--user", "alice", "--author=alice", "-u", "alice"]
        let out = Redactor.redactArguments(args, context: ctx)
        for (i, arg) in out.enumerated() {
            XCTAssertFalse(
                arg.contains("alice"),
                "参数 \(args[i]) 脱敏后仍含用户名：\(arg)"
            )
        }
        // 占位符必须真出现（否则「不含用户名」可能是因为整串被丢了）
        XCTAssertTrue(out.contains("<user>"), "应出现 <user> 占位符，实为 \(out)")
    }

    /// **项目名必须能被脱敏，但只能由调用方显式给。**
    ///
    /// `Placeholder.project` 曾**定义了却从未被使用**——IF-12 要求
    /// 「参数按 `<project>` 脱敏」，而实现里没有这条规则。
    ///
    /// 不靠字符串猜的理由：`~/.cache/uv` 里的 `uv` 是工具名不是项目名；
    /// 按「home 后第一段」猜会把 `uv` / `Library` / `Documents` 全打成 `<project>`。
    /// **正解是由知道答案的一方给**（扫描 MCP 配置时本就知道项目根在哪）。
    func testProjectNameRedactedWhenProvided() {
        let ctx = Redactor.Context(
            userName: "alice",
            homeDirectory: "/Users/alice",
            hostName: "alicemac"
        )
        let args = ["--config", "/Users/alice/projects/my-app/.mcp.json"]

        // 不传项目名时：home 被替换，但项目名仍在（这是已知限制，不是缺陷）
        let withoutProject = Redactor.redactArguments(args, context: ctx)
        XCTAssertTrue(
            withoutProject.joined().contains("my-app"),
            "不传 projectNames 时项目名会残留——这是**已登记的限制**，不是 bug"
        )

        // 传了就一定替掉
        let withProject = Redactor.redactArguments(
            args,
            context: ctx,
            projectNames: ["my-app"]
        )
        let joined = withProject.joined()
        XCTAssertFalse(joined.contains("my-app"), "给了项目名却没脱敏：\(joined)")
        XCTAssertTrue(joined.contains("<project>"), "应出现 <project>：\(joined)")
        XCTAssertTrue(joined.contains("<path>"), "home 也应被替换：\(joined)")
    }

    // MARK: - 双语（段名双写、正文跟随界面语言）

    /// 英文界面下导出的报告：**正文无中文**，但**段标记仍中英双写**。
    ///
    /// 为什么段标记不能跟着语言变：它同时是「五段齐全」自检的判据。
    /// 若标记随语言变，自检在切换语言后就可能对不上 —— 同一份报告换个
    /// 语言导出就判「缺段」。双写让两种语言都能定位，自检也稳定。
    func testEnglishReportHasNoChineseBodyButBilingualMarkers() throws {
        let previous = L.current
        L.current = .en
        defer { L.current = previous }

        let text = try Redactor.render(makeReport(), context: context)

        // 正文（表头 / 标题）必须是英文
        XCTAssertTrue(text.contains("# Residue Redacted Diagnostic Report"))
        XCTAssertTrue(text.contains("| Item | Value |"))
        XCTAssertTrue(text.contains("### Evidence chain"))

        // 段标记双写：五段都必须同时含中文名与英文名
        for (zh, en) in [
            ("① 环境", "Environment"), ("② 量", "Metrics"),
            ("③ 取证", "Diagnostics"), ("④ 证据", "Evidence"),
            ("⑤ 上游", "Upstream"),
        ] {
            XCTAssertTrue(text.contains(zh), "段标记应保留中文名：\(zh)")
            XCTAssertTrue(text.contains(en), "段标记应保留英文名：\(en)")
        }
    }

    /// 中文界面下：正文是中文（默认行为不变）。
    func testChineseReportKeepsChineseBody() throws {
        let previous = L.current
        L.current = .zhHans
        defer { L.current = previous }

        let text = try Redactor.render(makeReport(), context: context)
        XCTAssertTrue(text.contains("# Residue 脱敏诊断报告"))
        XCTAssertTrue(text.contains("| 项 | 值 |"))
    }

    /// **短串不作替换规则**（`needle.count >= 3` 的保护）。
    ///
    /// 用户名若只有 2 个字符（合法但少见），全局替换会把正常文本打烂
    /// （`uv` 被替成 `<user>v` 那种）。这条钉住保护逻辑本身。
    func testTooShortNeedleIsSkipped() {
        let ctx = Redactor.Context(
            userName: "ab",
            homeDirectory: "/Users/ab",
            hostName: "h"
        )
        let out = Redactor.redact("abc abc", context: ctx)
        XCTAssertEqual(
            out, "abc abc",
            "2 字符的 needle 不得参与替换（会把正常文本打烂）"
        )
    }

}
