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


    // ======================================================================
    // MARK: - 容量上限对**目录型候选**必须成立（P0 · CR-029）
    //
    // 这组用例的由来：AC-15 的「实际删除量不超过上限」是用户最主要的安全保证，
    // 而上限判定原本**只在普通文件上被测过**（`makeFile` 造的全是文件）。
    // 目录型候选一次都没走过 —— 于是口径不一致的缺陷完全隐身。
    //
    // 原缺陷（2026-11-09 实测确认）：
    //   预检用 `attributesOfItem[.size]` → 目录自身的 ~96 B
    //   记账用 `recursiveLogicalBytes`     → 子树真实体积
    // 两个各含 100 KB 的目录候选、上限 150 KB → 预检都说「不超限」
    // → **实际删除 200 KB，超上限 33%**。
    //
    // **判据设计**：不写「断言不超过」这种可能恒真的话，
    // 而是造出**能区分两种口径**的样本，并断言「实际删除量 ≤ 上限」**且**
    // 「至少有一个候选被顺延」——后者排除了「干脆一个都不删」这种假通过。
    // ======================================================================

    /// 造一个含指定字节数的**目录**候选（子树内一个普通文件）。
    private func makeDirCandidate(
        _ name: String,
        bytes: Int
    ) throws -> (url: URL, id: CandidateID) {
        let dir = cacheDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: bytes).write(to: dir.appendingPathComponent("payload.bin"))
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        let bt = (attrs[.creationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        return (dir, CandidateID(path: dir.path, birthtime: bt))
    }

    /// **目录型候选也必须受容量上限约束**（AC-15 Then 的核心）。
    ///
    /// ## 这条在旧实现下必然失败（不是恒真）
    ///
    /// 旧实现的预检看到目录自身 ~96 B，两个候选都「不超 150 KB」→
    /// 两个都被删 → `deletedBytes = 200 KB > 150 KB`。
    ///
    /// 修后：第一个候选（100 KB）删掉，第二个（100 KB）因
    /// 「100 + 100 > 150」被顺延 → 实际删除量 = 100 KB ≤ 150 KB，
    /// 且 `skippedByCap == 1`（证明不是「一个都没删」）。
    func testCapacityCapHoldsForDirectoryCandidates() throws {
        let a = try makeDirCandidate("dircap_a", bytes: 100 * 1024)
        let b = try makeDirCandidate("dircap_b", bytes: 100 * 1024)

        let outcome = executor.execute(
            candidates: [a.id, b.id],
            source: .uvCache,
            capacityCap: 150 * 1024,
            countCap: 100
        )

        XCTAssertLessThanOrEqual(
            outcome.deletedBytes, 150 * 1024,
            "实际删除量不得超过上限（AC-15 Then）。"
            + "旧实现的预检用目录自身的 st_size（约 96 B），两个候选都误判为「不超限」"
            + "→ 实际删除量会达到 200 KB"
        )
        XCTAssertEqual(
            outcome.skippedByCap, 1,
            "第二个候选（100 KB）应因「累计 100+100 > 150 KB」被顺延"
        )
        XCTAssertEqual(outcome.records.count, 1, "只删一个")
        XCTAssertEqual(outcome.deletedBytes, 100 * 1024, "删掉的那个记 100 KB（递归逻辑字节）")
        XCTAssertTrue(outcome.failures.isEmpty, "顺延不是失败")
    }

    /// **不传预检值时，预检也必须用递归逻辑字节**（口径统一的兜底）。
    ///
    /// ## 为什么单独一条
    ///
    /// `testCapacityCapHoldsForDirectoryCandidates` 已能抓住旧缺陷，
    /// 但它与「预检值缓存」这条路径是**两条不同的路径**：
    /// 一条走「调用方没给预检值 → 现算」，一条走「调用方给了 → 用给定的」。
    ///
    /// 若将来有人把「现算」那条改回目录自身 `st_size`，
    /// 而「用给定预检值」那条仍然正确，
    /// 那么**只有显式传预检值的调用点会被保护**——
    /// 而生产路径 `AppModel.executeBatch` 目前就是**不传**预检值的。
    ///
    /// 这条专门守住「不传预检值」这条路径。
    func testRecomputedPreflightUsesLogicalBytesNotDirectoryStatSize() throws {
        let a = try makeDirCandidate("recalc_a", bytes: 100 * 1024)
        let b = try makeDirCandidate("recalc_b", bytes: 100 * 1024)

        // **不传** preflightBytes → 走现算分支
        let outcome = executor.execute(
            candidates: [a.id, b.id],
            source: .uvCache,
            capacityCap: 150 * 1024,
            countCap: 100
        )

        XCTAssertLessThanOrEqual(
            outcome.deletedBytes, 150 * 1024,
            "现算的预检值也必须是递归逻辑字节（旧实现用目录自身 ~96 B → 会删到 200 KB）"
        )
        XCTAssertEqual(outcome.skippedByCap, 1, "第二个候选应顺延")
    }

    /// **预检值必须与记账值同口径**（AC-15 / CR-022 偏差 2）。
    ///
    /// 契约要求预检值是「随候选缓存到执行点」的逻辑字节，
    /// 且明文要求「预检通过 → 删除发生 → 实测超限」这条路径**可达**
    /// （否则判据失去判别力）。
    ///
    /// 这条钉住「传入的预检值被真正使用」，而不是被忽略。
    func testPreflightBytesAreUsedForCapDecision() throws {
        let a = try makeDirCandidate("pf_a", bytes: 100 * 1024)
        let b = try makeDirCandidate("pf_b", bytes: 100 * 1024)

        // 预检值明确给出（模拟「扫描时算好并缓存到执行点」）
        let preflight: [CandidateID: Int64] = [
            a.id: 100 * 1024,
            b.id: 100 * 1024,
        ]

        let outcome = executor.execute(
            candidates: [a.id, b.id],
            source: .uvCache,
            capacityCap: 150 * 1024,
            countCap: 100,
            preflightBytes: preflight
        )

        XCTAssertEqual(outcome.records.count, 1, "按预检值应只删一个")
        XCTAssertEqual(outcome.skippedByCap, 1, "第二个顺延")
        XCTAssertLessThanOrEqual(outcome.deletedBytes, 150 * 1024, "实际删除量不超上限")
    }

    /// **预检值与记账值不一致时，必须以预检值为准**（否则缓存形同虚设）。
    ///
    /// 构造一个「预检值偏大」的场景：预检说这条是 200 KB（超 150 KB 上限），
    /// 而实际目录只有 50 KB。此时**应当顺延**——
    /// 因为 AC-15 要求「预检值」决定是否删除，而不是「实测值」。
    ///
    /// 这条正是契约那句「预检通过 → 删除发生 → 实测超限」路径可达性的守门人：
    /// 若实现改回「用实测值预检」，这条会失败。
    func testPreflightValueDecidesNotRecomputedValue() throws {
        let a = try makeDirCandidate("pf_c", bytes: 50 * 1024)

        let outcome = executor.execute(
            candidates: [a.id],
            source: .uvCache,
            capacityCap: 150 * 1024,
            countCap: 100,
            // 预检值说 200 KB → 超过 150 KB 上限 → 应顺延
            preflightBytes: [a.id: Int64(200 * 1024)]
        )

        XCTAssertEqual(
            outcome.records.count, 0,
            "预检值超上限时不得删除（契约：预检值决定，不得实时重算）"
        )
        XCTAssertEqual(outcome.skippedByCap, 1, "顺延计数为 1")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: a.url.path),
            "被顺延的候选必须仍在原位"
        )
    }

    /// **容量上限恰好等于累计值时应放行**（边界：`<=` 而非 `<`）。
    ///
    /// 旧实现的比较是 `> capacityCap` 才顺延，边界是对的；
    /// 这条把它钉住 —— 防止有人「顺手改成 `>=`」导致每次都少删一条。
    /// 用普通文件（口径无争议）来测边界，避免与目录口径纠缠。
    func testCapacityCapBoundaryIsInclusive() throws {
        let a = try makeFile("edge_a.bin", bytes: 1024)
        let b = try makeFile("edge_b.bin", bytes: 1024)

        let outcome = executor.execute(
            candidates: [a, b],
            source: .uvCache,
            capacityCap: 2048,   // 恰好等于两条之和
            countCap: 100
        )

        XCTAssertEqual(
            outcome.records.count, 2,
            "累计恰好等于上限时应全部放行（上限是「不超过」，含等于）"
        )
        XCTAssertEqual(outcome.skippedByCap, 0)
        XCTAssertEqual(outcome.deletedBytes, 2048)
    }

    /// **条目数上限先于容量上限判定**（顺序契约）。
    ///
    /// 契约：条目数上限与容量上限是**两条独立约束**，任一触顶即停。
    /// 本条构造「条目数先触顶」的场景：上限 1 条、容量极宽 →
    /// 应只删 1 条，其余顺延。
    func testCountCapAppliesIndependentlyOfCapacityCap() throws {
        var ids: [CandidateID] = []
        for i in 0..<4 { ids.append(try makeFile("cc\(i).bin", bytes: 100)) }

        let outcome = executor.execute(
            candidates: ids,
            source: .uvCache,
            capacityCap: .max,   // 容量不构成约束
            countCap: 1
        )

        XCTAssertEqual(outcome.records.count, 1, "条目数上限 1 → 只删 1 条")
        XCTAssertEqual(outcome.skippedByCap, 3, "其余 3 条顺延")
        XCTAssertEqual(
            ids.filter { FileManager.default.fileExists(atPath: $0.path) }.count, 3,
            "顺延的 3 条必须仍在原位"
        )
    }


    // ======================================================================
    // MARK: - 单次容量上限的判定（AC-15）
    //
    // 抽到 Core 的原因：这个判定原先在 `AppModel`（App target）里，
    // **无法被单测约束** —— 而它决定「这次最多删多少字节」，
    // 是用户最主要的安全保证之一。
    // ======================================================================

    /// **稳定后档同样受用户配置的上限约束**（这条正是原来的缺陷）。
    ///
    /// 原实现在稳定后那一支只写 `T×20%`，把用户配置丢了 ——
    /// 用户把上限调到 1 GB 后，第一次执行按 1 GB 走，
    /// 第二次执行跳回 20% → **用户的设置静默失效**。
    func testSteadyTierStillHonorsUserConfiguredCap() {
        let userCap: Int64 = 1_000_000_000        // 用户设的 1 GB
        let total: Int64 = 100_000_000_000        // 来源总量 100 GB
        // 稳定后的比例档：100 GB × 20% = 20 GB —— 远大于用户的 1 GB
        let cap = TrashExecutor.capacityCap(
            userCapBytes: userCap,
            absoluteCapBytes: 5_000_000_000,
            sourceTotalBytes: total,
            tier: .steady
        )
        XCTAssertEqual(
            cap, userCap,
            "稳定后必须取「用户上限」与「T×20%」的较小者；"
            + "用户把上限调小后它在第二次执行时静默失效"
        )
    }

    /// **首次档：三条上界取最小**（每个分支各造一个样本）。
    func testFirstRunTierTakesMinOfThreeBounds() {
        // ① 比例档最小：总量 100 GB × 10% = 10 GB，
        //    而用户上限 50 GB、绝对上限 100 GB → 10 GB 最小
        let byRatio = TrashExecutor.capacityCap(
            userCapBytes: 50_000_000_000,
            absoluteCapBytes: 100_000_000_000,
            sourceTotalBytes: 100_000_000_000,
            tier: .firstRun
        )
        XCTAssertEqual(byRatio, 10_000_000_000, "比例档（10 GB）最小则取它")

        // ② 绝对上限最小：总量 100 GB → 比例档 10 GB，但绝对上限设成 1 GB
        let byAbsolute = TrashExecutor.capacityCap(
            userCapBytes: 50_000_000_000,
            absoluteCapBytes: 1_000_000_000,
            sourceTotalBytes: 100_000_000_000,
            tier: .firstRun
        )
        XCTAssertEqual(byAbsolute, 1_000_000_000, "绝对上限（1 GB）最小则取它")

        // ③ 比例档最小（总量小）：1 GB × 10% = 100 MB
        let bySmallRatio = TrashExecutor.capacityCap(
            userCapBytes: 50_000_000_000,
            absoluteCapBytes: 5_000_000_000,
            sourceTotalBytes: 1_000_000_000,
            tier: .firstRun
        )
        XCTAssertEqual(bySmallRatio, 100_000_000, "比例档（100 MB）最小则取它")

        // ④ 用户上限最小
        let byUser = TrashExecutor.capacityCap(
            userCapBytes: 1_000_000,
            absoluteCapBytes: 5_000_000_000,
            sourceTotalBytes: 100_000_000_000,
            tier: .firstRun
        )
        XCTAssertEqual(byUser, 1_000_000, "用户上限最小则取它")
    }

    /// **上限永不为负、且用户上限为 0 时不会给出荒谬值**。
    func testCapacityCapIsNeverNegative() {
        for total in [Int64(0), 1, 1_000_000] {
            for user in [Int64(0), 1, 5_000_000_000] {
                let cap = TrashExecutor.capacityCap(
                    userCapBytes: user,
                    absoluteCapBytes: 5_000_000_000,
                    sourceTotalBytes: total,
                    tier: .steady
                )
                XCTAssertGreaterThanOrEqual(cap, 0, "上限不得为负")
            }
        }
    }

    /// **稳定后的比例档比首次档宽**（20% vs 10%）——两档不能反。
    func testSteadyRatioIsWiderThanFirstRun() {
        let total: Int64 = 10_000_000_000
        let big: Int64 = 100_000_000_000   // 让比例档成为最小项
        let first = TrashExecutor.capacityCap(
            userCapBytes: big, absoluteCapBytes: big, sourceTotalBytes: total, tier: .firstRun
        )
        let steady = TrashExecutor.capacityCap(
            userCapBytes: big, absoluteCapBytes: big, sourceTotalBytes: total, tier: .steady
        )
        XCTAssertEqual(first, total / 10, "首次档 = T×10%")
        XCTAssertEqual(steady, total / 5, "稳定后档 = T×20%")
        XCTAssertGreaterThan(steady, first, "稳定后档必须比首次档宽")
    }

    // ======================================================================
    // MARK: - 来源总量字节（AC-15 比例档的分母 · CR-032 · P2-1）
    // ======================================================================

    /// **来源总量按「字节」算，不是按「条数」算**。
    ///
    /// 旧缺陷：`AppModel.sourceTotalBytes(for:)` 优先返回 `entry.T`
    /// ——而 `T` 是**快照条目数**（单位：条）。拿条数当字节，
    /// 上限就变成「条数 × 10% B」：113 个瓶子 → 上限 11 B → **几乎删不动**。
    func testSourceTotalBytesUsesBytesNotCounts() {
        let candidates = [
            ScanEngine.Candidate(
                path: "/tmp/a.tar.gz", birthtime: Date(timeIntervalSince1970: 1),
                bytes: 1_000_000, isDirectory: false, source: Source.brewCache.rawValue
            ),
            ScanEngine.Candidate(
                path: "/tmp/b.tar.gz", birthtime: Date(timeIntervalSince1970: 2),
                bytes: 2_000_000, isDirectory: false, source: Source.brewCache.rawValue
            ),
        ]
        XCTAssertEqual(
            TrashExecutor.sourceTotalBytes(candidates: candidates, source: .brewCache),
            3_000_000,
            "来源总量必须是候选字节之和，不是条目数"
        )
    }

    /// **不同来源互不相加**（分母必须是「该来源」的总量）。
    func testSourceTotalBytesIsPerSource() {
        let candidates = [
            ScanEngine.Candidate(
                path: "/tmp/uv1", birthtime: Date(timeIntervalSince1970: 1),
                bytes: 100, isDirectory: false, source: Source.uvCache.rawValue
            ),
            ScanEngine.Candidate(
                path: "/tmp/brew1", birthtime: Date(timeIntervalSince1970: 2),
                bytes: 700, isDirectory: false, source: Source.brewCache.rawValue
            ),
        ]
        XCTAssertEqual(TrashExecutor.sourceTotalBytes(candidates: candidates, source: .uvCache), 100)
        XCTAssertEqual(TrashExecutor.sourceTotalBytes(candidates: candidates, source: .brewCache), 700)
    }

    /// **该来源没有候选时总量为 0**（比例档为 0 → 无候选可删，不影响）。
    func testSourceTotalBytesIsZeroForAbsentSource() {
        let candidates = [
            ScanEngine.Candidate(
                path: "/tmp/uv1", birthtime: Date(timeIntervalSince1970: 1),
                bytes: 100, isDirectory: false, source: Source.uvCache.rawValue
            )
        ]
        XCTAssertEqual(
            TrashExecutor.sourceTotalBytes(candidates: candidates, source: .pipCache),
            0
        )
    }


    // ======================================================================
    // MARK: - `t1` 预检值 与 `t2` 实测值（IF-07 / B-02）
    //
    // AC-15 的判据是「实际删除量不超过上限」，而契约要求**两个取数时点**：
    //   t1 = 首检时刻的递归字节 → 预检用（决定删不删）
    //   t2 = rename 完成后对废纸篓条目重新实测的值 → 对账用（决定是否回滚）
    //
    // 两者都要落进 `execution.jsonl`（`bytesPreview` / `bytes` / `bytesMeasuredAt`），
    // 否则「实际删除量」没有唯一取数时点，判据退化成恒真断言。
    //
    // **原实现无载体**（R2 已记「❌ 无载体」）：只有一个 `bytes` 字段。
    // ======================================================================

    /// **`t1` 与 `t2` 必须分别落盘**（且同名普通文件两者相等）。
    func testPreviewAndMeasuredBytesAreRecordedSeparately() throws {
        let id = try makeFile("two_times.bin", bytes: 4096)
        let rec = try executor.moveToTrash(id, source: .uvCache)

        XCTAssertEqual(rec.bytesPreview, 4096, "`t1` 预检值应落盘")
        XCTAssertEqual(rec.bytes, 4096, "`t2` 实测值应落盘（普通文件两者相等）")
        XCTAssertNotNil(rec.bytesMeasuredAt, "`t2` 实测时刻必须有值（发生了 rename）")
    }

    /// **`t1` 与 `t2` 在目录内容变化时必须不同**（这正是要实测的理由）。
    ///
    /// 构造：预检值用**较小的** `preflightBytes`（模拟首检时刻目录还小），
    /// 而 rename 后目录里的实际内容更大 → `t2 > t1`。
    ///
    /// 这条守住「预检值与实测值不是同一个数」这个事实 ——
    /// 若实现偷懒用同一个数，这条会红。
    func testMeasuredBytesCanDifferFromPreviewBytes() throws {
        let dir = try makeDirCandidate("grew", bytes: 100 * 1024)
        let outcome = executor.execute(
            candidates: [dir.id],
            source: .uvCache,
            capacityCap: .max,
            countCap: 10,
            // 预检值说只有 10 KB（首检时刻的样子）
            preflightBytes: [dir.id: Int64(10 * 1024)]
        )

        XCTAssertEqual(outcome.records.count, 1)
        let rec = outcome.records[0]
        XCTAssertEqual(rec.bytesPreview, 10 * 1024, "`t1` 保留预检时的值")
        XCTAssertEqual(rec.bytes, 100 * 1024, "`t2` 是 rename 后重新实测的值")
        XCTAssertGreaterThan(
            rec.bytes, rec.bytesPreview,
            "实测值应大于预检值（目录在两次取数之间变大了）"
        )
    }

    /// **`t2` 实测超上限 → 移回原位 + 记 `blocked_cap` + 本轮停止**（IF-07）。
    ///
    /// ## 构造「预检通过但实测超限」
    ///
    /// 预检值给**小值**（所以预检放行），而实测值是真实体积（大），
    /// 加上上限本身很小 → 实测必然超限。
    ///
    /// 这条正是契约那句「预检通过 → `rename` 发生 → `t2` 实测超限 → 移回原位」
    /// 的可达性守门人 —— 若实现改回「用 `t1` 对账」，这条必然失败
    /// （用 `t1` 算就是 10 KB ≤ 上限，不会回滚）。
    func testMeasuredOverCapIsRolledBackToOriginalPath() throws {
        let dir = try makeDirCandidate("overrun", bytes: 100 * 1024)
        let outcome = executor.execute(
            candidates: [dir.id],
            source: .uvCache,
            capacityCap: 50 * 1024,      // 上限 50 KB
            countCap: 10,
            preflightBytes: [dir.id: Int64(10 * 1024)]   // 预检说 10 KB → 预检放行
        )

        // ① 必须被移回原位
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dir.url.path),
            "实测超上限的条目必须移回原位（不能留在废纸篓里）"
        )
        // ② 废纸篓里不能有残留
        let trashEntries = (try? FileManager.default.contentsOfDirectory(atPath: trashDir.path)) ?? []
        XCTAssertTrue(
            trashEntries.isEmpty,
            "移回后废纸篓不应有残留（实为 \(trashEntries)）"
        )
        // ③ 动作必须是 `blocked_cap`，且原因串是「实测」那一条
        XCTAssertEqual(outcome.records.count, 1)
        let rec = outcome.records[0]
        XCTAssertEqual(rec.action, ExecutionAction.blockedCap, "动作必须是 blocked_cap（不是 rename_to_trash）")
        XCTAssertEqual(
            rec.blockedReason, "实测超上限，已移回原位",
            "原因串必须区分「实测超上限」与「预检超上限」（IF-08：同一动作值、不同原因串）"
        )
        XCTAssertNil(rec.restorePath, "已移回原位 → 恢复位置作废")
        // ④ 实际删除量必须仍为 0（回滚的不算删了）
        XCTAssertEqual(outcome.deletedBytes, 0, "被回滚的条目不计入实际删除量")
    }

    /// **预检阶段拦截的原因串是「预检超上限」**（与实测那条区分开）。
    func testPreflightBlockReasonDiffersFromMeasured() throws {
        let dir = try makeDirCandidate("preblocked", bytes: 100 * 1024)
        let outcome = executor.execute(
            candidates: [dir.id],
            source: .uvCache,
            capacityCap: 50 * 1024,     // 上限 50 KB
            countCap: 10,
            preflightBytes: [dir.id: Int64(100 * 1024)]   // 预检就说超了
        )

        // 预检就拦下了 → **没有发生 rename** → 不该有 blocked_cap 记录
        XCTAssertEqual(outcome.records.count, 0, "预检阶段拦截不产生执行记录")
        XCTAssertEqual(outcome.skippedByCap, 1, "顺延计数为 1")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dir.url.path),
            "预检拦截的候选必须仍在原位"
        )
        XCTAssertEqual(outcome.deletedBytes, 0, "实际删除量为 0")
    }

    /// **`t2` 实测超限后本轮停止后续删除**（IF-07「宁可少删」）。
    func testMeasuredOverCapStopsRemainingDeletions() throws {
        let a = try makeDirCandidate("stop_a", bytes: 100 * 1024)
        let b = try makeDirCandidate("stop_b", bytes: 100 * 1024)
        let c = try makeDirCandidate("stop_c", bytes: 100 * 1024)

        let outcome = executor.execute(
            candidates: [a.id, b.id, c.id],
            source: .uvCache,
            capacityCap: 150 * 1024,
            countCap: 10,
            // 预检值都很小 → 三条都能过预检
            preflightBytes: [a.id: Int64(1), b.id: Int64(1), c.id: Int64(1)]
        )

        // 第一条：实测 100 KB，累计 100 KB ≤ 150 KB → 删
        // 第二条：实测 100 KB，累计 200 KB > 150 KB → **移回 + 停轮**
        // 第三条：**根本没轮到**（本轮已停）
        XCTAssertEqual(outcome.records.count, 2, "第一条删掉、第二条记 blocked_cap")
        XCTAssertEqual(outcome.records[0].action, .renameToTrash, "第一条正常删")
        XCTAssertEqual(outcome.records[1].action, ExecutionAction.blockedCap, "第二条被回滚")
        XCTAssertEqual(outcome.deletedBytes, 100 * 1024, "实际删除量 = 第一条")

        // 第二、第三条都必须在原位
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.url.path), "第二条已移回原位")
        XCTAssertTrue(FileManager.default.fileExists(atPath: c.url.path), "第三条未被触碰")
    }

}
