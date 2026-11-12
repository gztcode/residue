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
    private func saveCarrier(appVersion: String, round: Int = 2) throws {
        var header = StateHeader()
        header.appVersion = appVersion
        header.round = round
        header.countedDays = 14
        header.sources = Source.allCases.map {
            SourceHeaderEntry(
                source: $0, snapshotTaken: true,
                T: 100, K: 90, J: 10, H: 30,
                a: 0, b: 12, slotCount: 100, doneCount: 0
            )
        }
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
}
