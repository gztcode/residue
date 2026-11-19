import XCTest
@testable import ResidueCore

/// `ScanProgress` 测试：**扫描进度的算式**。
///
/// 这一层是「① 页扫描进度环」的算术落点 —— 弧长（`fraction`）与
/// 跨来源累计（分子 / 分母 / 条目数）都在 Core 算好，
/// 界面只拿现成的数（不变量①：界面禁止算术）。
final class ScanProgressTests: XCTestCase {

    // MARK: - 步骤 1：`fraction`（进度环弧长）

    /// 分子 0 ⇒ 弧长 0（**但分母已知** ⇒ 不是「未知」）。
    func testFractionIsZeroWhenNoSourceCompleted() {
        let p = ScanProgress(completedSources: 0, totalSources: 3)
        XCTAssertEqual(p.fraction, 0.0)
    }

    /// 分子 1 / 分母 3 ⇒ 弧长 1/3。
    func testFractionIsOneThirdWhenOneSourceCompleted() {
        let p = ScanProgress(completedSources: 1, totalSources: 3)
        guard let f = p.fraction else {
            return XCTFail("分母已知 ⇒ 弧长不得为 nil")
        }
        XCTAssertEqual(f, 1.0 / 3.0, accuracy: 1e-9)
    }

    /// 全部来源扫完 ⇒ 弧长 1。
    func testFractionIsOneWhenAllSourcesCompleted() {
        let p = ScanProgress(completedSources: 3, totalSources: 3)
        XCTAssertEqual(p.fraction, 1.0)
    }

    /// **分母未知 ⇒ 弧长未知（`nil`），不得当成 0。**
    ///
    /// 守不变量③：不把未知判为安全/已知 —— 界面据此「只画轨道不画弧」，
    /// 而不是画一个看起来「没进度」的空环。
    func testFractionIsNilWhenDenominatorUnknown() {
        let p = ScanProgress(completedSources: 0, totalSources: 0)
        XCTAssertNil(p.fraction)
    }

    /// 分子超过分母（防御）⇒ 夹到 1，不得画出大于整圆的弧。
    func testFractionIsClampedWhenCompletedExceedsTotal() {
        let p = ScanProgress(completedSources: 5, totalSources: 3)
        XCTAssertEqual(p.fraction, 1.0)
    }

    // MARK: - 步骤 2：`displayText`（进度文案）

    /// **分母已知 ⇒ 首段报「已完成 x/y 个来源」。**
    ///
    /// 用户要看到的是「推进到哪儿了」，而不仅是「扫了多少条」。
    func testDisplayTextShowsCompletedSourcesWhenDenominatorKnown() {
        let p = ScanProgress(
            source: "uv",
            filesScanned: 120,
            candidatesFound: 0,
            elapsed: 2.5,
            isRunning: true,
            completedSources: 1,
            totalSources: 3
        )
        let text = p.displayText
        XCTAssertTrue(text.contains("1/3"), "首段应报「已完成 1/3 个来源」，实际：\(text)")
        XCTAssertTrue(text.contains("个来源"), "首段应含「个来源」，实际：\(text)")
    }

    /// **分母未知 ⇒ 文案非空，且不得出现「/0」。**
    ///
    /// 「0/0」会被读成「一个来源都扫不完」——那是编造（守不变量③）。
    func testDisplayTextIsNonEmptyWhenDenominatorUnknown() {
        let p = ScanProgress(
            source: "",
            filesScanned: 12,
            candidatesFound: 0,
            elapsed: 0.1,
            isRunning: true,
            completedSources: 0,
            totalSources: 0
        )
        let text = p.displayText
        XCTAssertFalse(text.isEmpty, "分母未知时文案仍须非空（否则横条一片空白）")
        XCTAssertFalse(text.contains("/0"), "分母未知不得写成「0/0」，实际：\(text)")
    }

    /// **不在运行 ⇒ 文案为空。**
    ///
    /// 扫描结束后页面上不得还挂着「正在扫描…」。
    func testDisplayTextIsEmptyWhenNotRunning() {
        let p = ScanProgress(
            filesScanned: 120,
            candidatesFound: 3,
            elapsed: 9.9,
            isRunning: false,
            completedSources: 3,
            totalSources: 3
        )
        XCTAssertTrue(p.displayText.isEmpty)
    }

    // MARK: - 步骤 3：跨来源累计（`ScanProgressAccumulator`）

    /// **跳过的来源也算完成** —— 分子照常推进。
    ///
    /// 「根不存在」的来源若不推进分子，进度环会永远停在中途
    /// （分母含它，分子不含它）⇒ 用户看不到「快扫完了」。
    func testCompletedSourcesAdvancesWhenSourceIsSkipped() {
        var acc = ScanProgressAccumulator(totalSources: 3)
        XCTAssertEqual(acc.completedSources, 0)
        // 根不存在 ⇒ 0 条目、0 候选，但**仍算完成**。
        let p = acc.completing(source: "pipx", files: 0, candidates: 0, elapsed: 0.5)
        XCTAssertEqual(p.completedSources, 1, "跳过的来源也算完成")
        XCTAssertEqual(p.totalSources, 3, "分母不得因跳过而变小")
    }

    /// **条目数跨来源累加** —— 不得各自从 0 起算。
    ///
    /// 这是缺陷 #7 的正解：第二来源的「已扫描 N 项」不得比第一来源结束时还小。
    func testFilesScannedAccumulatesAcrossSources() {
        var acc = ScanProgressAccumulator(totalSources: 2)
        let first = acc.completing(source: "uv", files: 100, candidates: 0, elapsed: 1.0)
        XCTAssertEqual(first.filesScanned, 100)
        let second = acc.completing(source: "npm", files: 50, candidates: 0, elapsed: 2.0)
        XCTAssertEqual(second.filesScanned, 150, "跨来源条目数必须累加")
    }

    /// **「已用时」跨来源不归零。**
    ///
    /// 守卫缺陷 #9 的**同源形态**（时间轴不得在来源边界上回卷）。
    func testElapsedDoesNotResetAcrossSources() {
        var acc = ScanProgressAccumulator(totalSources: 2)
        let first = acc.completing(source: "uv", files: 10, candidates: 0, elapsed: 5.0)
        XCTAssertEqual(first.elapsed, 5.0)
        let second = acc.completing(source: "npm", files: 10, candidates: 0, elapsed: 12.0)
        XCTAssertEqual(second.elapsed, 12.0, "「已用时」跨来源不得归零")
        XCTAssertGreaterThan(second.elapsed, first.elapsed)
    }

    /// **进行中的来源不得被数两遍。**
    ///
    /// `progressing` 只**临时叠加**当前来源的增量（供界面显示），
    /// 累加器自身保持不变 —— 否则该来源完成时 `completing` 会再计一次。
    func testProgressingDoesNotDoubleCountTheRunningSource() {
        var acc = ScanProgressAccumulator(totalSources: 2)
        _ = acc.completing(source: "uv", files: 100, candidates: 0, elapsed: 1.0)
        XCTAssertEqual(acc.filesScanned, 100)

        let mid = acc.progressing(source: "npm", deltaFiles: 30, deltaCandidates: 2, elapsed: 2.0)
        XCTAssertEqual(mid.filesScanned, 130, "进行中的来源条目数应临时叠加显示")
        XCTAssertEqual(acc.filesScanned, 100, "progressing 不得改累加器自身")

        let done = acc.completing(source: "npm", files: 30, candidates: 2, elapsed: 3.0)
        XCTAssertEqual(done.filesScanned, 130, "该来源只应被计入一次（不是 160）")
    }

    /// **起手点必须先报分母**（分子为 0）。
    ///
    /// 否则扫描一开始分母就是 0 ⇒ 进度环**一直画不出弧**
    /// （`fraction` 返回 `nil`），用户看不出环在推进。
    func testStartingReportsDenominatorBeforeAnySourceCompletes() {
        let acc = ScanProgressAccumulator(totalSources: 3)
        let p = acc.starting(elapsed: 0.0)
        XCTAssertEqual(p.totalSources, 3, "起手点就须知道分母")
        XCTAssertEqual(p.completedSources, 0)
        XCTAssertEqual(p.fraction, 0.0, "分母已知、分子为 0 ⇒ 弧长是 0（不是未知）")
    }
}
