import XCTest
@testable import ResidueCore

// ============================================================
// SecondCheck · 删除前二次检查（AC-17）
//
// ## 这些测试用真文件系统
//
// `MemoryFS` 是扁平的，永远造不出「同名重建」「birthtime 变化」这类
// 时间相关的态。而 AC-17 的全部意义就在这些时间相关态上
// （「扫描 → 执行之间世界变了」）。所以这里用临时目录 + 真文件。
//
// ## 最关键的一条是 testUnchangedFileReadsConsistentBirthtime
//
// 它钉的是**整个 birthtime 复核的地基**：同一未变文件，两次读
// `.creationDate` 必须完全相等。若这个前提不成立（文件系统抖动），
// `checkIdentity` 会**恒判 rebuilt → 永不删** —— 安全闸退化成恒真误报。
// 先用测试证明前提，再依赖它。
// ============================================================

final class SecondCheckTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondCheckTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func makeFile(_ name: String, content: String = "x") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - unchanged（地基）

    /// **地基**：同一未变文件，扫描期读的 birthtime 与执行期读的必须完全相等。
    ///
    /// 这是 `checkIdentity` 不恒判 `rebuilt` 的前提。真文件系统实测。
    func testUnchangedFileReadsConsistentBirthtime() throws {
        let url = try makeFile("stable")
        // 扫描期：用与 ScanEngine 相同的方式读
        let scanAttrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let scanBirthtime = (scanAttrs[.creationDate] as? Date) ?? Date(timeIntervalSince1970: 0)

        // 执行期：走 checkIdentity
        let status = SecondCheck.checkIdentity(path: url.path, recordedBirthtime: scanBirthtime)

        XCTAssertEqual(status, .unchanged, "同一未变文件必须判 unchanged（否则 birthtime 复核恒误报）")
    }

    /// 目录候选同样判 unchanged（目录也是候选，且走递归删除）。
    func testUnchangedDirectoryReadsConsistentBirthtime() throws {
        let sub = dir.appendingPathComponent("cachedir")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "x".write(to: sub.appendingPathComponent("f"), atomically: true, encoding: .utf8)

        let attrs = try FileManager.default.attributesOfItem(atPath: sub.path)
        let bt = (attrs[.creationDate] as? Date) ?? Date(timeIntervalSince1970: 0)

        XCTAssertEqual(
            SecondCheck.checkIdentity(path: sub.path, recordedBirthtime: bt),
            .unchanged
        )
    }

    // MARK: - rebuilt（同名重建）

    /// 文件被删掉又重建 → birthtime 变化 → 判 rebuilt（不得删，是新建的）。
    func testRebuiltFileDetected() throws {
        let url = try makeFile("rebuilt")
        let originalAttrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let originalBirthtime = (originalAttrs[.creationDate] as? Date) ?? Date(timeIntervalSince1970: 0)

        // 同名重建
        try FileManager.default.removeItem(at: url)
        try "new content".write(to: url, atomically: true, encoding: .utf8)

        let status = SecondCheck.checkIdentity(path: url.path, recordedBirthtime: originalBirthtime)
        // 若这个文件系统上重建后 creationDate 恰好相同（亚秒精度问题），
        // 这个测试会失败并告诉我们「birthtime 复核在此环境不可用」——
        // 那是必须知道的事实，不是可以忽略的 flake。
        XCTAssertEqual(status, .rebuilt, "同名重建必须被判出（否则会误删新装的文件）")
    }

    // MARK: - vanished

    /// 文件已被删 → 判 vanished（没东西可删）。
    func testVanishedFileDetected() throws {
        let url = try makeFile("gone")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let bt = (attrs[.creationDate] as? Date) ?? Date(timeIntervalSince1970: 0)

        try FileManager.default.removeItem(at: url)

        XCTAssertEqual(
            SecondCheck.checkIdentity(path: url.path, recordedBirthtime: bt),
            .vanished
        )
    }

    /// 从未存在过的路径 → vanished。
    func testNonexistentPathIsVanished() {
        XCTAssertEqual(
            SecondCheck.checkIdentity(
                path: dir.appendingPathComponent("never-existed").path,
                recordedBirthtime: Date(timeIntervalSince1970: 0)
            ),
            .vanished
        )
    }

    // MARK: - isLiveHeld（L0 二次检查复用）

    /// 被同 uid 进程持有的 inode → isLiveHeld 为真（AC-17：发现活引用并放弃）。
    func testLiveHeldReflectsSnapshot() {
        let identity = FileIdentity(dev: 1, ino: 42)
        var snapshot = L0Snapshot()
        snapshot.inodes[identity] = [1234]

        XCTAssertTrue(
            SecondCheck.isLiveHeld(identity: identity, isDirectory: false, path: "/x", by: snapshot)
        )
    }

    /// 未被持有的 inode → isLiveHeld 为假。
    func testNotHeldWhenAbsentFromSnapshot() {
        let identity = FileIdentity(dev: 1, ino: 999)
        let snapshot = L0Snapshot()

        XCTAssertFalse(
            SecondCheck.isLiveHeld(identity: identity, isDirectory: false, path: "/x", by: snapshot)
        )
    }
}
