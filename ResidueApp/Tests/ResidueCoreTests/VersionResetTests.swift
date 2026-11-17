import XCTest
@testable import ResidueCore

// ============================================================
// 应用版本变更 → 载体清零（M4「重置边界」）
//
// ## 为什么这条规则是安全要求，不是清洁工作
//
// `a`（L0 误判累计）是**门槛项**，必须为 0 才允许点亮自动删除。
// 它是「本应用版本内、该产品判错过几次」的累计 —— **跨版本没有可比性**：
//
// - 新版本改了判定规则 → 旧版本的「零误判」不能证明新版本判得准
// - 不重置 = **旧版本攒下的安全凭证被新版本继承**
//
// 那是「删之前先证明判得准」（不变量④）在版本边界上的失效：
// 用户升级后立刻就能点亮，而新规则一次都没被观察过。
//
// ## 两个边界都要钉
//
// | 情形 | 期望 |
// |---|---|
// | 首次运行（appVersion 为空） | **不清零**（没有旧版本可比，清不清都一样，但不应多写一次盘） |
// | 同版本重启 | **不清零**（否则每次启动都把观察期重置 → 产品永远点不亮） |
// | 版本变了 | **清零** `F` / `C_done` / 位槽表 / `a`，轮次不变 |
// ============================================================

final class VersionResetTests: XCTestCase {

    private var dir: URL!
    private var stateFile: StateFile!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VersionResetTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stateFile = StateFile(directory: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// 造一个「有安全凭证」的载体：`a = 0`、`b = 12`、已取快照。
    private func saveCarrier(
        appVersion: String,
        round: Int = 2,
        configure: (inout StateHeader) -> Void = { _ in }
    ) throws {
        var header = StateHeader()
        header.appVersion = appVersion
        header.round = round
        header.countedDays = 14
        header.roundStartAnchor = Date(timeIntervalSince1970: 1_700_000_000)
        header.settlement = SettlementHeader(
            producedAt: Date(timeIntervalSince1970: 1_700_000_500),
            reportId: "report-1"
        )
        header.sources = Source.allCases.map {
            SourceHeaderEntry(
                source: $0, snapshotTaken: true,
                T: 100, K: 90, J: 10, H: 30,
                a: 0, b: 12, slotCount: 100, doneCount: 0,
                snapshotDate: Date(timeIntervalSince1970: 1_700_000_100),
                settlementDate: Date(timeIntervalSince1970: 1_700_000_400),
                unattributableCount: 3
            )
        }
        configure(&header)
        try stateFile.save(header: header, payloads: [:])
    }

    private func loadHeader() throws -> StateHeader {
        let result = stateFile.load()
        guard let c = result.contents else {
            throw XCTSkip("载体未加载：\(String(describing: result.error))")
        }
        return c.header
    }

    // MARK: - 版本变了 → 清零

    /// **核心用例**：版本变更后，`a` / `b` / `T` / `K` / 快照标志全部清零。
    func testVersionChangeClearsCredentials() throws {
        try saveCarrier(appVersion: "1.0.0")
        XCTAssertEqual(try loadHeader().sources.first?.K, 90, "前置：旧版本有 K")

        try stateFile.clearCarrierForVersionChange(newAppVersion: "1.1.0")
        let after = try loadHeader()

        XCTAssertEqual(after.appVersion, "1.1.0")
        for entry in after.sources {
            XCTAssertEqual(entry.a, 0, "\(entry.source) 的 a 必须清零")
            XCTAssertEqual(entry.b, 0, "\(entry.source) 的 b 必须清零")
            XCTAssertNil(entry.K, "\(entry.source) 的 K 必须回到「未结算」")
            XCTAssertNil(entry.T, "\(entry.source) 的 T 必须回到「未取快照」")
            XCTAssertFalse(entry.snapshotTaken, "\(entry.source) 的快照标志必须清零")
        }
    }

    /// **轮次不变**：版本升级不产生新轮次（它重置当前轮次，不是开下一轮）。
    ///
    /// 原实现无条件造 `StateHeader()`（round 默认 1）→ 已经跑到第 3 轮的用户
    /// 升级后被打回第 1 轮。那不是重置，是倒退。
    func testVersionChangeKeepsRound() throws {
        try saveCarrier(appVersion: "1.0.0", round: 3)
        try stateFile.clearCarrierForVersionChange(newAppVersion: "2.0.0", preservedRound: 3)
        XCTAssertEqual(try loadHeader().round, 3, "轮次必须保留（M1：不产生新轮次）")
    }

    // MARK: - 〔v5.6 · CR-031〕版本变更七量终值（穷举式 · PRD v5.6 M1「写入时刻」）

    /// **用户设置类字段不随版本变更清零**（M1 写入时刻 ⑧）。
    ///
    /// 原实现无条件造 `StateHeader()` → `autoDeleteEnabled` 被静默置 `false`：
    /// 用户升级后，自动删除总开关被**替用户改主意**关掉。
    func testVersionChangePreservesAutoDeleteEnabled() throws {
        try saveCarrier(appVersion: "1.0.0", configure: { $0.autoDeleteEnabled = true })

        try stateFile.clearCarrierForVersionChange(newAppVersion: "1.1.0")

        XCTAssertTrue(
            try loadHeader().autoDeleteEnabled,
            "版本变更只清观察期凭证与误判凭证，不碰用户的开关选择"
        )
    }

    /// **来源条目必须留在载体里** —— 版本变更清的是「量」，不是「来源本身」。
    ///
    /// 原实现造全新 `StateHeader()` → `sources` 为空 → 界面上的每来源读数全部消失。
    ///
    /// ⚠️ 既有断言 `for entry in after.sources { ... }` 在 `sources` 为空时
    /// **一次都不执行** → 假绿。测试要造出能区分两者的样本（CLAUDE.md §七第 1 条）。
    func testVersionChangeKeepsAllSourceEntries() throws {
        try saveCarrier(appVersion: "1.0.0")

        try stateFile.clearCarrierForVersionChange(newAppVersion: "1.1.0")

        let after = try loadHeader()
        XCTAssertEqual(after.sources.count, Source.allCases.count, "来源条目不得被版本变更抹掉")
        XCTAssertEqual(after.sources.map(\.source), Source.allCases, "来源条目顺序 = `Source.allCases` 声明序")
    }

    /// **计数日归零 + 起算点重置**（M1 写入时刻 ①）。
    ///
    /// 起算点重置 = 版本变更后的**下一次**成功扫描完成所在日 ⇒ 重置瞬间无起算点。
    func testVersionChangeResetsCountedDaysAndAnchor() throws {
        try saveCarrier(appVersion: "1.0.0", configure: {
            $0.countedDays = 9
            $0.roundStartAnchor = Date(timeIntervalSince1970: 1_700_000_000)
        })

        try stateFile.clearCarrierForVersionChange(newAppVersion: "1.1.0")

        let after = try loadHeader()
        XCTAssertEqual(after.countedDays, 0, "本轮计数日必须归零")
        XCTAssertNil(after.roundStartAnchor, "本轮计数日起算点必须重置")
    }

    /// **结算凭证随 `K` / `J` 一并清零**（M1 写入时刻 ③）。
    ///
    /// 凭证与结算值不同源 → 会造出「有报告、无样本」的假态。
    func testVersionChangeClearsSettlementCredential() throws {
        try saveCarrier(appVersion: "1.0.0")

        try stateFile.clearCarrierForVersionChange(newAppVersion: "1.1.0")

        let after = try loadHeader()
        XCTAssertNil(after.settlement.producedAt, "报告产出时刻必须清零")
        XCTAssertNil(after.settlement.reportId, "报告标识必须清零")
    }

    /// **每来源的快照/结算时刻、「无法归因条数」、门槛 `H` 随量一并清零**。
    ///
    /// 不变量③：`nil`（尚未结算，无从归因）≠ `0`（已结算但无失联）——
    /// 旧快照的归因结论对新快照无效 ⇒ 必须回到 `nil`，不能留 `0`。
    func testVersionChangeClearsPerSourceDatesAndUnattributable() throws {
        try saveCarrier(appVersion: "1.0.0")

        try stateFile.clearCarrierForVersionChange(newAppVersion: "1.1.0")

        for entry in try loadHeader().sources {
            XCTAssertNil(entry.snapshotDate, "\(entry.source) 的取快照时刻必须清零")
            XCTAssertNil(entry.settlementDate, "\(entry.source) 的结算时刻必须清零")
            XCTAssertNil(entry.unattributableCount, "\(entry.source) 的无法归因条数必须回到「尚未结算」")
            XCTAssertNil(entry.H, "\(entry.source) 的门槛 H 随新 T 重算 ⇒ 先回到 nil")
        }
    }
}
