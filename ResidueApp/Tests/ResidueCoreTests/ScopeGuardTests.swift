import XCTest
@testable import ResidueCore

// ============================================================
// ScopeGuard · 执行范围守卫（AC-19 · R2:218）
//
// ## 用真文件系统
//
// 符号链接 / `realpath` / 同卷判定全部是文件系统语义，`MemoryFS` 造不出来。
// 这里全部用临时目录 + 真 symlink。
//
// ## 最关键的一条是 testSymlinkInsideRootIsRejected
//
// 它钉的正是审计里那个「会删到来源根之外」的口子：
// 来源根里放一个指向根外的 symlink，扫描端会跟着下探（已实测确认），
// 执行端必须拒绝 —— 否则根外的文件被移进废纸篓。
// ============================================================

final class ScopeGuardTests: XCTestCase {

    private var root: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScopeGuardTests-\(UUID().uuidString)")
        root = base.appendingPathComponent("root")
        outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        super.tearDown()
    }

    private func makeFile(_ url: URL, content: String = "x") throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - 通过

    /// 根内的普通文件 → 通过（`nil`）。
    func testRegularFileInsideRootPasses() throws {
        let f = root.appendingPathComponent("a.bin")
        try makeFile(f)
        XCTAssertNil(ScopeGuard.check(path: f.path, allowedRoot: root.path))
    }

    /// 根内的目录 → 通过。
    func testDirectoryInsideRootPasses() throws {
        let d = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        XCTAssertNil(ScopeGuard.check(path: d.path, allowedRoot: root.path))
    }

    // MARK: - 拒绝：符号链接（核心）

    /// **来源根内的 symlink 必须被拒**（`E-204`）。
    ///
    /// 这是「会删到根外」那个口子的执行端防线：即使扫描端错误地把
    /// symlink 当目录下了探、把根外文件收成了候选，执行端也拒绝执行。
    func testSymlinkInsideRootIsRejected() throws {
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertEqual(
            ScopeGuard.check(path: link.path, allowedRoot: root.path),
            .symlink,
            "指向根外的 symlink 必须被拒（否则根外文件被删）"
        )
    }

    /// 指向根内的 symlink 同样被拒（契约：不跟随 symlink，一律拒绝）。
    func testSymlinkToInsideRootAlsoRejected() throws {
        let target = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("innerLink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(ScopeGuard.check(path: link.path, allowedRoot: root.path), .symlink)
    }

    // MARK: - 拒绝：越界

    /// 根外的普通文件 → `outOfRoot`（`E-204`）。
    func testFileOutsideRootRejected() throws {
        let f = outside.appendingPathComponent("b.bin")
        try makeFile(f)
        XCTAssertEqual(
            ScopeGuard.check(path: f.path, allowedRoot: root.path), .outOfRoot
        )
    }

    /// `..` 逃逸 → `outOfRoot`（`realpath` 解析后不在根内）。
    func testDotDotEscapeRejected() throws {
        let f = outside.appendingPathComponent("c.bin")
        try makeFile(f)
        let escape = root.path + "/../outside/c.bin"
        XCTAssertEqual(
            ScopeGuard.check(path: escape, allowedRoot: root.path), .outOfRoot,
            "`..` 逃逸必须被 realpath 解析后判出"
        )
    }

    /// 前缀相邻但不相同的兄弟目录 → 不得被判在根内。
    func testSiblingPrefixNotConsideredInside() throws {
        let sibling = root.deletingLastPathComponent().appendingPathComponent("root2")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let f = sibling.appendingPathComponent("d.bin")
        try makeFile(f)
        XCTAssertEqual(
            ScopeGuard.check(path: f.path, allowedRoot: root.path), .outOfRoot
        )
    }

    // MARK: - 拒绝：不存在

    func testNonexistentRejected() {
        let f = root.appendingPathComponent("never")
        XCTAssertEqual(
            ScopeGuard.check(path: f.path, allowedRoot: root.path), .notFound
        )
    }

    // MARK: - 诊断码映射（值域闭合，不复用错误码）

    func testRejectionMapsToCorrectDiagnostic() {
        XCTAssertEqual(ScopeGuard.Rejection.notFound.diagnostic, .e201)
        XCTAssertEqual(ScopeGuard.Rejection.symlink.diagnostic, .e204)
        XCTAssertEqual(ScopeGuard.Rejection.outOfRoot.diagnostic, .e204)
        XCTAssertEqual(ScopeGuard.Rejection.crossVolume.diagnostic, .e203)
    }
}
