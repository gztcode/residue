import XCTest
@testable import ResidueCore

/// CR-031 §3.2 · 归因判定（Core，纯函数）。
///
/// 判据封闭为七行 + 兜底，**按序判定、首个命中者生效**（PRD v5.6 · M3）。
/// 路径探针可注入 ⇒ 本文件不碰真文件系统；真文件系统用例在 §3.7 单测里。
final class SettlementTests: XCTestCase {

    // MARK: - 夹具

    private func candidate(_ path: String, _ birthtime: TimeInterval) -> CandidateID {
        CandidateID(path: path, birthtime: Date(timeIntervalSince1970: birthtime))
    }

    /// 探针：字典里没有的路径一律判「确定不存在」。
    private func probe(_ states: [String: Settlement.PathState]) -> (String) -> Settlement.PathState {
        { path in states[path] ?? .absent }
    }

    private let epoch = Date(timeIntervalSince1970: 0)
    private let later = Date(timeIntervalSince1970: 1_000)

    // MARK: - 判据 ① 身份键命中 → 不属失联

    func testIdentityKeyMatchIsAttributable() {
        let item = candidate("/cache/a", 100)

        let result = Settlement.attribute(snapshot: [item], current: [item], probe: probe([:]))

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].status, .attributable)
    }

    // MARK: - 判据 ② 同名重建（路径相同、birthtime 变化）

    func testSamePathDifferentBirthtimeIsDirectoryRestructured() {
        let before = candidate("/cache/a", 100)
        let rebuilt = candidate("/cache/a", 200)

        let result = Settlement.attribute(
            snapshot: [before],
            current: [rebuilt],
            probe: probe(["/cache/a": .exists])
        )

        XCTAssertEqual(result[0].status, .lost(.directoryRestructured))
    }

    // MARK: - 判据 ③ 改名（同 birthtime、不同路径、唯一命中）

    func testSameBirthtimeAtNewPathIsRenamed() {
        let before = candidate("/cache/a", 100)
        let after = candidate("/cache/b", 100)

        let result = Settlement.attribute(
            snapshot: [before],
            current: [after],
            probe: probe(["/cache/a": .absent, "/cache/b": .exists])
        )

        XCTAssertEqual(result[0].status, .lost(.renamed))
    }

    // MARK: - 判据 ④ 同 birthtime 命中不止一条 → 无法归因

    func testSameBirthtimeMatchingMultipleCandidatesIsUnattributable() {
        let before = candidate("/cache/a", 100)
        let one = candidate("/cache/b", 100)
        let two = candidate("/cache/d", 100)

        let result = Settlement.attribute(
            snapshot: [before],
            current: [one, two],
            probe: probe(["/cache/a": .absent])
        )

        XCTAssertEqual(result[0].status, .lost(.unattributable))
    }

    // MARK: - 判据 ⑤ 路径不可读 → 无法归因

    func testUnreadablePathIsUnattributable() {
        let item = candidate("/cache/a", 100)

        let result = Settlement.attribute(
            snapshot: [item],
            current: [],
            probe: probe(["/cache/a": .inaccessible, "/cache": .exists])
        )

        XCTAssertEqual(result[0].status, .lost(.unattributable))
    }

    // MARK: - 判据 ⑥ 父目录仍在、条目确定已不存在 → 用户手删

    func testEntryGoneWhileParentStillExistsIsUserDeleted() {
        let item = candidate("/cache/a", 100)

        let result = Settlement.attribute(
            snapshot: [item],
            current: [],
            probe: probe(["/cache/a": .absent, "/cache": .exists])
        )

        XCTAssertEqual(result[0].status, .lost(.userDeleted))
    }

    // MARK: - 判据 ⑦ 父目录确定已不在 → 目录拆分合并

    func testParentGoneIsDirectoryRestructured() {
        let item = candidate("/cache/a", 100)

        let result = Settlement.attribute(
            snapshot: [item],
            current: [],
            probe: probe(["/cache/a": .absent, "/cache": .absent])
        )

        XCTAssertEqual(result[0].status, .lost(.directoryRestructured))
    }

    // MARK: - 判据 ⑦ 条目仍在但已不再是候选 → 目录拆分合并

    func testEntryStillPresentButNoLongerCandidateIsDirectoryRestructured() {
        let item = candidate("/cache/a", 100)

        let result = Settlement.attribute(
            snapshot: [item],
            current: [],
            probe: probe(["/cache/a": .exists, "/cache": .exists])
        )

        XCTAssertEqual(result[0].status, .lost(.directoryRestructured))
    }

    // MARK: - 兜底 父目录不可读 → 无法归因

    func testUnreadableParentIsUnattributable() {
        let item = candidate("/cache/a", 100)

        let result = Settlement.attribute(
            snapshot: [item],
            current: [],
            probe: probe(["/cache/a": .absent, "/cache": .inaccessible])
        )

        XCTAssertEqual(result[0].status, .lost(.unattributable))
    }

    // MARK: - 判据按序判定（② 先于 ③）

    func testSamePathRebuildWinsOverRenamedWhenBothMatch() {
        let before = candidate("/cache/a", 100)
        let rebuilt = candidate("/cache/a", 200)
        let renamed = candidate("/cache/b", 100)

        let result = Settlement.attribute(
            snapshot: [before],
            current: [rebuilt, renamed],
            probe: probe(["/cache/a": .exists, "/cache/b": .exists])
        )

        XCTAssertEqual(result[0].status, .lost(.directoryRestructured))
    }

    // MARK: - 归因结果与快照条目一一对应、顺序一致

    func testAttributionsFollowSnapshotOrder() {
        let first = candidate("/cache/a", 100)
        let second = candidate("/cache/b", 200)

        let result = Settlement.attribute(snapshot: [first, second], current: [], probe: probe([:]))

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].candidate, first)
        XCTAssertEqual(result[1].candidate, second)
    }

    // MARK: - 恒等式 K + J = T

    func testIdentityHoldsWhenNothingLost() {
        let items = [candidate("/cache/a", 100), candidate("/cache/b", 200)]

        let outcome = Settlement.settle(
            snapshot: items,
            current: items,
            probe: probe([:]),
            snapshotDate: epoch,
            settlementDate: later
        )

        XCTAssertEqual(outcome.metrics.total, 2)
        XCTAssertEqual(outcome.metrics.attributable, 2)
        XCTAssertEqual(outcome.metrics.lost, 0)
        XCTAssertTrue(outcome.metrics.identityHolds)
    }

    func testIdentityHoldsWhenEverythingLost() {
        let items = [candidate("/cache/a", 100), candidate("/cache/b", 200)]

        let outcome = Settlement.settle(
            snapshot: items,
            current: [],
            probe: probe([:]),
            snapshotDate: epoch,
            settlementDate: later
        )

        XCTAssertEqual(outcome.metrics.total, 2)
        XCTAssertEqual(outcome.metrics.attributable, 0)
        XCTAssertEqual(outcome.metrics.lost, 2)
        XCTAssertTrue(outcome.metrics.identityHolds)
    }

    // MARK: - 无法归因条数如实披露

    func testUnattributableCountIsReported() {
        let items = [candidate("/cache/a", 100), candidate("/cache/b", 200)]

        // a：不可读 → 无法归因；b：父目录仍在、条目消失 → 用户手删
        let outcome = Settlement.settle(
            snapshot: items,
            current: [],
            probe: probe(["/cache/a": .inaccessible, "/cache/b": .absent, "/cache": .exists]),
            snapshotDate: epoch,
            settlementDate: later
        )

        XCTAssertEqual(outcome.unattributableCount, 1)
        XCTAssertEqual(outcome.metrics.lost, 2)
        XCTAssertEqual(outcome.attributions.count, 2)
    }

    // MARK: - 改名检测不依赖 inode

    func testRenamedDetectionUsesOnlyBirthtimeAndDifferentPath() {
        let before = candidate("/cache/a", 100)
        let after = candidate("/cache/b", 100)

        // 两侧都给 .exists —— 全程不提供任何 inode / inode 变化信息
        let result = Settlement.attribute(
            snapshot: [before],
            current: [after],
            probe: probe(["/cache/a": .exists, "/cache/b": .exists])
        )

        XCTAssertEqual(result[0].status, .lost(.renamed))
    }
}
