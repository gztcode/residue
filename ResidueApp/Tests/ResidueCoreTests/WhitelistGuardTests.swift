import XCTest
@testable import ResidueCore

// ============================================================
// WhitelistGuard · 白名单保护的唯一原语（AC-03）
//
// ## 为什么这组测试值得单独存在
//
// 白名单是**用户唯一的主动保护动作**。原先匹配逻辑只活在
// `PageModelBuilder.build`（展示层），执行路径根本不读 →
// 「用户以为保护生效了，而它在执行路径上不存在」。
//
// 提成 Core 原语后，展示层与执行层调同一个函数。这里钉的
// 就是那条匹配口径 —— 写错一个边界，删的就是用户明确说要保护的文件。
//
// ## 关键边界（每条都能区分「对」与「错」的实现）
//
// | 用例 | 为什么能区分 |
// |---|---|
// | 精确相等命中 | 最基本 |
// | 子路径命中 | `+ "/"` 前缀，不是裸前缀 |
// | `/a/bc` **不**被 `/a/b` 保护 | 裸前缀会误伤 —— 这是本测试最该钉的一条 |
// | 空白名单 → 全不保护 | 执行路径默认态 |
// ============================================================

final class WhitelistGuardTests: XCTestCase {

    // MARK: - isProtected

    /// 精确相等命中。
    func testExactPathMatch() {
        XCTAssertTrue(WhitelistGuard.isProtected(path: "/a/b", whitelist: ["/a/b"]))
    }

    /// 子路径命中（候选在受保护目录之下）。
    func testSubPathMatch() {
        XCTAssertTrue(WhitelistGuard.isProtected(path: "/a/b/c/d", whitelist: ["/a/b"]))
    }

    /// **最关键的一条**：`/a/bc` 不得被 `/a/b` 保护。
    ///
    /// 若用裸 `hasPrefix("/a/b")`，`/a/bc` 会误命中 —— 那是**反向错误**：
    /// 不是误删，而是**过度保护**（把用户没保护的文件也当成保护的）。
    /// 虽然安全侧 errs on the side of caution，但它会让白名单语义失真：
    /// 用户保护 `/a/b`，结果 `/a/bc` 也删不掉了，且界面上看不出为什么。
    func testSiblingPathNotProtected() {
        XCTAssertFalse(WhitelistGuard.isProtected(path: "/a/bc", whitelist: ["/a/b"]))
    }

    /// 空白名单 → 什么都不保护。
    func testEmptyWhitelistProtectsNothing() {
        XCTAssertFalse(WhitelistGuard.isProtected(path: "/a/b", whitelist: []))
    }

    /// 多条白名单，命中任意一条即保护。
    func testAnyEntryProtects() {
        XCTAssertTrue(
            WhitelistGuard.isProtected(path: "/x/y", whitelist: ["/p", "/x/y", "/q"])
        )
    }

    /// 根路径 `/` 保护一切（合法用法：用户想保护整个根下的东西）。
    func testRootPathProtectsEverything() {
        XCTAssertTrue(WhitelistGuard.isProtected(path: "/anything", whitelist: ["/"]))
    }

    // MARK: - filter

    /// filter 只剔除被保护的，保留其余，**保持顺序**。
    func testFilterRemovesProtectedKeepsOrder() {
        let paths = ["/keep/1", "/prot/a", "/keep/2", "/prot/b/c", "/a/bc"]
        let out = WhitelistGuard.filter(candidates: paths, whitelist: ["/prot", "/a/b"], path: { $0 })
        XCTAssertEqual(out, ["/keep/1", "/keep/2", "/a/bc"])
    }

    /// 空白名单 → 原样返回（执行路径默认态不该丢东西）。
    func testFilterEmptyWhitelistReturnsAll() {
        let paths = ["/a", "/b"]
        XCTAssertEqual(
            WhitelistGuard.filter(candidates: paths, whitelist: [], path: { $0 }),
            paths
        )
    }
}
