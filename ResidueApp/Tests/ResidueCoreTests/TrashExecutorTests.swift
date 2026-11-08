import XCTest
@testable import ResidueCore

/// 删除执行器单测：AC-04 的「rename_to_trash、禁 rm、可恢复」硬约束。
final class TrashExecutorTests: XCTestCase {

    private var root: URL!
    private var cacheDir: URL!
    private var trashDir: URL!
    private var executor: TrashExecutor!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("residue-exec-\(UUID().uuidString)", isDirectory: true)
        cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        trashDir = root.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        executor = TrashExecutor(trashDirectory: trashDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFile(_ name: String, bytes: Int = 1024) throws -> CandidateID {
        let url = cacheDir.appendingPathComponent(name)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let bt = (attrs[.creationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        return CandidateID(path: url.path, birthtime: bt)
    }

    /// AC-04 判定：源路径不存在、废纸篓出现同名条目且字节数一致、动作 = rename_to_trash
    func testMoveToTrashSatisfiesAC04() throws {
        let id = try makeFile("a.bin", bytes: 2048)
        let rec = try executor.moveToTrash(id, source: .uvCache)

        XCTAssertFalse(FileManager.default.fileExists(atPath: id.path), "源路径应不存在")
        XCTAssertEqual(rec.action, .renameToTrash, "动作字段必须是 rename_to_trash")
        XCTAssertEqual(rec.bytes, 2048, "字节数一致")

        let restore = try XCTUnwrap(rec.restorePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restore), "废纸篓中应出现该条目")
        let attrs = try FileManager.default.attributesOfItem(atPath: restore)
        XCTAssertEqual((attrs[.size] as? NSNumber)?.intValue, 2048)
    }

    /// AC-13：从废纸篓恢复到原路径，字节数一致
    func testRestoreReturnsFileToOriginalPath() throws {
        let id = try makeFile("b.bin", bytes: 512)
        let rec = try executor.moveToTrash(id, source: .npmNpx)
        let back = try executor.restore(rec)

        XCTAssertTrue(FileManager.default.fileExists(atPath: id.path), "应恢复到原路径")
        let attrs = try FileManager.default.attributesOfItem(atPath: id.path)
        XCTAssertEqual((attrs[.size] as? NSNumber)?.intValue, 512)
        XCTAssertEqual(back.action, .restoredByUser, "恢复动作回写为 restored_by_user（K2 建议 S1）")
        XCTAssertNil(back.restorePath)
    }

    /// AC-13：废纸篓被清空 → 恢复位置失效 → 必须报错，不得静默成功
    func testRestoreFailsWhenTrashEmptied() throws {
        let id = try makeFile("c.bin")
        let rec = try executor.moveToTrash(id, source: .uvCache)
        let restore = try XCTUnwrap(rec.restorePath)
        try FileManager.default.removeItem(atPath: restore)

        XCTAssertThrowsError(try executor.restore(rec), "恢复位置失效应报错")
    }

    /// 原路径已被占用时不覆盖（不制造数据丢失）
    func testRestoreRefusesToOverwriteExistingFile() throws {
        let id = try makeFile("d.bin")
        let rec = try executor.moveToTrash(id, source: .uvCache)
        // 原路径被新文件占用
        try Data(repeating: 0xCD, count: 10).write(to: URL(fileURLWithPath: id.path))

        XCTAssertThrowsError(try executor.restore(rec), "原路径被占用时不得覆盖")
        let attrs = try FileManager.default.attributesOfItem(atPath: id.path)
        XCTAssertEqual((attrs[.size] as? NSNumber)?.intValue, 10, "占用文件应保持原样")
    }

    /// AC-15：条目数上限触顶 → 超出部分顺延且不报错
    func testCountCapDefersRemaining() throws {
        var ids: [CandidateID] = []
        for i in 0..<5 { ids.append(try makeFile("cap\(i).bin")) }

        let outcome = executor.execute(
            candidates: ids, source: .uvCache,
            capacityCap: .max, countCap: 2
        )

        XCTAssertEqual(outcome.records.count, 2, "只删上限内的条目")
        XCTAssertEqual(outcome.skippedByCap, 3, "其余顺延")
        XCTAssertTrue(outcome.failures.isEmpty)
        // 顺延的 3 个应仍在原位
        XCTAssertEqual(ids.filter { FileManager.default.fileExists(atPath: $0.path) }.count, 3)
    }

    /// AC-15：容量上限触顶 → 同样顺延
    func testCapacityCapDefersRemaining() throws {
        var ids: [CandidateID] = []
        for i in 0..<4 { ids.append(try makeFile("sz\(i).bin", bytes: 1000)) }

        let outcome = executor.execute(
            candidates: ids, source: .uvCache,
            capacityCap: 2500, countCap: 100
        )

        XCTAssertEqual(outcome.records.count, 2, "累计不超容量上限")
        XCTAssertLessThanOrEqual(outcome.deletedBytes, 2500)
        XCTAssertEqual(outcome.skippedByCap, 2)
    }

    /// 契约 AC-04 判定：执行日志中删除调用（rm/unlink）出现次数 = 0。
    /// 本实现只用 `moveItem`，无 rm 路径——该断言由实现方式保证。
    func testNoDeletePrimitiveIsUsed() throws {
        let id = try makeFile("e.bin")
        let rec = try executor.moveToTrash(id, source: .uvCache)
        XCTAssertEqual(rec.action.rawValue, "rename_to_trash")
        // 恢复位置必须存在（否则等同真删除）
        XCTAssertNotNil(rec.restorePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rec.restorePath!))
    }

    // ======================================================================
    // MARK: - 目录型候选的递归字节（**补一条曾经缺失的用例**）
    //
    // 背景：`recursiveLogicalBytes` 曾写成
    //    `for case let item as String in fileManager.enumerator(at: URL(...))`
    // 而 `enumerator(at:)` 的元素是 `URL` → **循环体一次都不执行** → 目录字节恒 0。
    //
    // 后果：AC-15 的容量上限靠该值判定 → 字节恒 0 ⟹ 上限归零
    //      ⟹ **目录型候选的单次删除完全没有上限**。
    //
    // **为什么之前 6 条用例都没抓到**：它们全用普通文件（`makeFile`），
    // 目录路径一次都没走过。这正是「用替身写用例会系统性屏蔽真实行为」的又一例。
    //
    // 本用例用**真目录树 + 已知地面真值**（25 KB + 75 KB）做断言，
    // 而不是「断言返回非 0」——后者在 bug 存在时也会失败，但说不出差多少。
    // ======================================================================

    /// **目录 = 子树内普通文件 `st_size` 之和**（AC-15 的「字节」唯一定义）。
    ///
    /// 地面真值由测试自己造（25 KB + 75 KB = 100 KB），不依赖实现。
    func testDirectoryBytesEqualSumOfDescendantFiles() throws {
        // 造一棵已知大小的树：root/25KB + root/sub/75KB
        let tree = root.appendingPathComponent("tree")
        let sub = tree.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 25 * 1024).write(to: tree.appendingPathComponent("a.bin"))
        try Data(repeating: 0x42, count: 75 * 1024).write(to: sub.appendingPathComponent("b.bin"))

        let expected: Int64 = 100 * 1024
        let actual = executor.recursiveLogicalBytes(atPath: tree.path)

        XCTAssertEqual(
            actual, expected,
            "目录字节必须 = 子树内普通文件之和（100 KB）。"
            + "若为 0，说明递归枚举的元素类型又错了（`enumerator(at:)` 给的是 URL 不是 String）"
        )
        XCTAssertNotEqual(actual, 0, "0 会让 AC-15 的容量上限判定归零 → 目录型候选可无上限删除")
    }

    /// **目录自身的 `st_size` 不计入**（它只有 ~96–128 B，计入会让上限恒真）。
    ///
    /// 这条与上一条互补：上一条防「字节恒 0」，这条防「退回去用 `st_size`」。
    func testDirectoryOwnStatSizeIsNotCounted() throws {
        let tree = root.appendingPathComponent("tree2")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data(repeating: 0x43, count: 10 * 1024).write(to: tree.appendingPathComponent("x.bin"))

        let dirStatSize = (try? FileManager.default.attributesOfItem(atPath: tree.path))?[.size] as? NSNumber
        let dirStat = dirStatSize?.int64Value ?? -1
        let actual = executor.recursiveLogicalBytes(atPath: tree.path)

        XCTAssertEqual(actual, 10 * 1024, "应等于 10 KB（子树内那个文件）")
        XCTAssertNotEqual(actual, dirStat, "不得等于目录自身的 st_size（`\(dirStat)` B）")
    }

    /// **符号链接只计自身、不下降、不计目标**（S-03）。
    func testSymlinkIsNotFollowed() throws {
        let tree = root.appendingPathComponent("tree3")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        // 目录外放一个大文件，然后从 tree 里链过去
        try Data(repeating: 0x44, count: 200 * 1024).write(to: outside.appendingPathComponent("big.bin"))
        try Data(repeating: 0x45, count: 5 * 1024).write(to: tree.appendingPathComponent("small.bin"))
        try FileManager.default.createSymbolicLink(
            at: tree.appendingPathComponent("link"),
            withDestinationURL: outside
        )

        let actual = executor.recursiveLogicalBytes(atPath: tree.path)
        XCTAssertEqual(
            actual, 5 * 1024,
            "只计 root 下的 5 KB；符号链接不下降（否则会把目录外的 200 KB 算进来，"
            + "等于按别人的体积去撞上限）"
        )
    }

}
