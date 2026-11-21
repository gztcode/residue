import XCTest
@testable import ResidueCore

/// 逐来源扫描统计（CR-043 / 台账 P2-1）。
///
/// 要证明两件事：
/// ① 换算与排序是**确定性**的（同一份数据两次渲染不会换位置）；
/// ② `~/.npm/_npx` 的项数确实**单独**算出来、与别的来源互不串味。
///
/// 第三条（「加了统计之后判定完全不变」）在 `PageModelBuilderTests`
/// 里用「同一份载体 + 候选，有无统计两份模型逐槽对比」证明。
final class SourceScanStatsTests: XCTestCase {

    // MARK: - 毫秒换算

    /// **四舍五入，不是截断**。
    ///
    /// 截断会让 6.789 s 显示成 `6.78 秒` —— 度量值带系统性偏差，
    /// 与台账里 6.79 s 的口径对不上。
    func testMillisecondsRoundsToNearest() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            SourceScanStats.milliseconds(from: start, to: start.addingTimeInterval(6.789)),
            6_789
        )
        XCTAssertEqual(
            SourceScanStats.milliseconds(from: start, to: start.addingTimeInterval(1.2346)),
            1_235
        )
    }

    /// **负数钳到 0**：时钟回拨不该渲染出「−3 秒」。
    func testMillisecondsClampsNegativeToZero() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            SourceScanStats.milliseconds(from: start, to: start.addingTimeInterval(-0.2)),
            0
        )
    }

    // MARK: - 排序

    /// 耗时降序 —— 「慢在哪」第一眼就要看到。
    func testMakeSortsByDurationDescending() {
        let stats = SourceScanStats.make([
            (source: Source.pipxRun.rawValue, items: 10, durationMs: 100),
            (source: Source.npmNpx.rawValue, items: 20, durationMs: 9_000),
            (source: Source.uvCache.rawValue, items: 30, durationMs: 5_000),
        ])
        XCTAssertEqual(
            stats.map(\.source),
            [Source.npmNpx.rawValue, Source.uvCache.rawValue, Source.pipxRun.rawValue]
        )
        XCTAssertEqual(stats.map(\.items), [20, 30, 10], "items 必须跟着自己的来源走")
    }

    /// 同耗时 → 按 `Source` **声明序**，且与输入顺序无关。
    ///
    /// 不确定的话，同一份数据两次渲染会换位置 —— 用户会以为数字在跳。
    func testMakeBreaksTiesBySourceDeclarationOrder() {
        let stats = SourceScanStats.make([
            (source: Source.npmNpx.rawValue, items: 2, durationMs: 500),
            (source: Source.uvCache.rawValue, items: 1, durationMs: 500),
        ])
        XCTAssertEqual(
            stats.map(\.source),
            [Source.uvCache.rawValue, Source.npmNpx.rawValue],
            "`uvCache` 在 `Source.allCases` 里先于 `npmNpx`"
        )
    }

    /// 不认识的来源**不丢、不猜**：排在最后（按 rawValue），而不是被静默过滤掉。
    func testMakeKeepsUnknownSourceLast() {
        let stats = SourceScanStats.make([
            (source: "zzz-future-source", items: 3, durationMs: 500),
            (source: Source.npmNpx.rawValue, items: 2, durationMs: 500),
            (source: Source.uvCache.rawValue, items: 1, durationMs: 500),
        ])
        XCTAssertEqual(stats.count, 3, "未知来源不得被丢弃")
        XCTAssertEqual(stats.last?.source, "zzz-future-source")
    }

    // MARK: - 耗时文案

    /// `MetricUnit` 没有秒单位 ⇒ 耗时只能走 `.text`，这里守住它的**两位小数**。
    func testDurationTextKeepsTwoDecimals() {
        XCTAssertTrue(UICopy.scanSourceDuration(milliseconds: 6_790).contains("6.79"))
        XCTAssertTrue(UICopy.scanSourceDuration(milliseconds: 30).contains("0.03"))
    }

    // MARK: - `_npx` 单独统计（真引擎 + MemoryFS）

    /// **两棵树、两个来源，项数各自独立。**
    ///
    /// `_npx` 与 `uv` 的叶子数刻意不同：若统计把它们混成一个数，
    /// 或者把某棵树的条目算到另一个来源头上，这里的相等断言立刻失败。
    func testNpxAndUvCountedIndependently() throws {
        let fs = ScanEngineTests.MemoryFS()
        let npxRoot = "/home/u/.npm/_npx"
        let uvRoot = "/home/u/.cache/uv"
        // 两棵树形状不同 ⇒ 叶子数不同，混算必然对不上。
        fs.buildTree(root: npxRoot, depth: 2, width: 4, fileSize: 10)
        fs.buildTree(root: uvRoot, depth: 3, width: 2, fileSize: 20)

        let engine = ScanEngine(fileSystem: fs, rules: [
            ScanEngine.SourceRule(source: .npmNpx, pathFragments: ["/.npm/_npx/"]),
            ScanEngine.SourceRule(source: .uvCache, pathFragments: ["/.cache/uv/"]),
        ])

        let npxResult = try engine.scan(root: npxRoot, mode: .full)
        let uvResult = try engine.scan(root: uvRoot, mode: .full)

        XCTAssertGreaterThan(npxResult.filesScanned, 0)
        XCTAssertGreaterThan(uvResult.filesScanned, 0)
        XCTAssertNotEqual(
            npxResult.filesScanned, uvResult.filesScanned,
            "两棵树的形状必须不同，否则「混算」也碰巧能过"
        )

        let stats = SourceScanStats.make([
            (source: Source.npmNpx.rawValue, items: npxResult.filesScanned, durationMs: 6_790),
            (source: Source.uvCache.rawValue, items: uvResult.filesScanned, durationMs: 6_440),
        ])

        XCTAssertEqual(
            stats.map(\.source),
            [Source.npmNpx.rawValue, Source.uvCache.rawValue],
            "`_npx` 更慢 ⇒ 排在第一条（它就是「扫描慢主要慢在这里」的答案）"
        )
        XCTAssertEqual(stats[0].items, npxResult.filesScanned, "`_npx` 的项数必须是它自己的")
        XCTAssertEqual(stats[1].items, uvResult.filesScanned)
        XCTAssertEqual(
            stats.reduce(0) { $0 + $1.items },
            npxResult.filesScanned + uvResult.filesScanned,
            "合计必须无损：逐来源统计不得丢条目"
        )
    }
}
