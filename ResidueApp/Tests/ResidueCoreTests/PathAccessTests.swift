import XCTest
import Foundation
import Darwin
@testable import ResidueCore

// ============================================================
// PathAccess · 路径可读性三态（fail-closed 的前提）
//
// ## 这一组测试在钉什么
//
// 「确定不存在」与「读不到」是**两件不同的事**。混同它们会同时造成：
//
// - P-028：把「权限不足」写进举证链成「文件已自行删除」（假事实）；
// - P-027：把「取不到身份」当成「没有活引用」（fail-open ⇒ 可能删掉在用文件）。
//
// 所以这里把**分类规则本身**单独钉死：哪些 `errno` 算「不存在」，
// 哪些算「读不到」，以及 Cocoa 错误里的 `errno` 到底怎么取。
//
// ## 真文件系统用例与 root
//
// 权限用例靠 `chmod 000` 制造 `EACCES`（当前用户是文件属主 ⇒ 权限位生效）。
// root 会绕过权限位 ⇒ 用例在 root 下 `XCTSkip`（不是静默通过）。
// ============================================================

final class PathAccessTests: XCTestCase {

    // MARK: - 夹具

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PathAccessTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 让目录**不可进入** ⇒ 里面的文件读不到属性（`EACCES`）。
    ///
    /// 注意：给**文件**本身 `chmod 000` 不影响 `stat`（读权限与 `stat` 无关），
    /// 必须拿掉**父目录**的执行权限才会 `EACCES`。
    private func lockDirectory() {
        chmod(dir.path, 0)
    }

    private func unlockDirectory() {
        chmod(dir.path, 0o755)
    }

    // MARK: - errno 分类

    /// `ENOENT` ⇒ **确定不存在**。
    func testENOENTIsClassifiedAsAbsent() {
        XCTAssertEqual(PathAccess.classify(errno: ENOENT), .absent)
    }

    /// `ENOTDIR` ⇒ 路径的某一段不是目录 ⇒ **确定不存在**。
    func testENOTDIRIsClassifiedAsAbsent() {
        XCTAssertEqual(PathAccess.classify(errno: ENOTDIR), .absent)
    }

    /// `EACCES` ⇒ **读不到**（不是「不存在」）。
    func testEACCESIsClassifiedAsUnreadable() {
        XCTAssertEqual(PathAccess.classify(errno: EACCES), .unreadable(errno: EACCES))
    }

    /// `EPERM` ⇒ **读不到**（不是「不存在」）。
    func testEPERMIsClassifiedAsUnreadable() {
        XCTAssertEqual(PathAccess.classify(errno: EPERM), .unreadable(errno: EPERM))
    }

    /// 其它 `errno`（如 `EIO`）⇒ 一律「读不到」（宁可保守）。
    func testUnknownErrnoIsClassifiedAsUnreadable() {
        XCTAssertEqual(PathAccess.classify(errno: EIO), .unreadable(errno: EIO))
    }

    // MARK: - Cocoa 错误 → errno

    /// Cocoa 错误里的 `errno` 在 `NSUnderlyingErrorKey` 里。
    ///
    /// ⚠️ `NSCocoaErrorDomain` 下的 `.code` 不是 `errno`（CLAUDE.md §七-3）：
    /// 直接拿 `.code` 比 `EACCES` 永远不相等 ⇒ 分类静默失效。
    func testUnderlyingPOSIXErrorProvidesErrno() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadNoPermissionError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))]
        )
        XCTAssertEqual(PathAccess.posixErrno(from: error), EACCES)
        XCTAssertEqual(PathAccess.classify(error: error), .unreadable(errno: EACCES))
    }

    /// 没有 underlying 错误时按 Cocoa 码兜底（实测 Cocoa 错误都带 underlying）。
    func testCocoaCodeFallbackWhenUnderlyingIsMissing() {
        let missing = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        XCTAssertEqual(PathAccess.classify(error: missing), .absent)

        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        XCTAssertEqual(PathAccess.classify(error: denied), .unreadable(errno: EACCES))
    }

    /// 完全不认识的错误 ⇒ 归「读不到」（**不猜**它是不是「不存在」）。
    func testUnknownErrorIsClassifiedAsUnreadable() {
        let error = NSError(domain: "SomeUnknownDomain", code: 42)
        XCTAssertEqual(PathAccess.classify(error: error), .unreadable(errno: EIO))
    }

    // MARK: - 身份三态（lstat）

    /// 存在的文件 ⇒ 拿到身份。
    func testExistingPathYieldsResolvedIdentity() throws {
        let url = try makeFile("resolved")
        guard case .resolved(let identity) = L0Probe.identityState(atPath: url.path) else {
            return XCTFail("存在的文件必须拿到身份")
        }
        XCTAssertNotEqual(identity.ino, 0)
        XCTAssertNotEqual(identity.dev, 0)
    }

    /// 不存在的路径 ⇒ **确定不存在**（不是「读不到」）。
    func testMissingPathYieldsAbsent() {
        let missing = dir.appendingPathComponent("never-\(UUID().uuidString)").path
        XCTAssertEqual(L0Probe.identityState(atPath: missing), .absent)
    }

    /// 权限不足 ⇒ **读不到**（P-027 的核心：不能当成「没有活引用」）。
    func testPermissionDeniedPathYieldsUnreadableNotAbsent() throws {
        try XCTSkipIf(geteuid() == 0, "root 绕过权限位，造不出 EACCES")
        let url = try makeFile("denied")
        lockDirectory()
        defer { unlockDirectory() }

        guard case .unreadable(let errno) = L0Probe.identityState(atPath: url.path) else {
            return XCTFail("权限不足必须判「读不到」，不是「不存在」")
        }
        XCTAssertEqual(errno, EACCES)
    }
}
