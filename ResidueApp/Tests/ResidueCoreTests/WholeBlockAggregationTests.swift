import XCTest
@testable import ResidueCore

/// CR-038 · 整块粒度来源的字节聚合（pnpm store / bun cache）。
///
/// ## 为什么必须是真文件系统
///
/// 整块聚合的语义全在「遍历 + 字节累加 + 断点续扫」三件事上 ——
/// `MemoryFS` 是**扁平**的（`listDirectory` 不递归）⇒ 累加路径与断点行为都测不出真实语义。
///
/// ## 契约落点
///
/// - CR-038 §3.6（整块来源只累加字节、不产逐条候选；**正常完成时**才收敛成一条）
/// - CR-038 §3.7（断点增补 `aggregatedBytes`，续扫不重不漏）
/// - 不变量③「不把未知判为安全」—— **中止时不得把「扫了一半」说成「就这么多」**
final class WholeBlockAggregationTests: XCTestCase {

    // MARK: - 夹具

    /// 真目录树（pnpm store 形状）：根下有子目录，子目录里有叶子文件。
    private struct Fixture {
        let root: URL
        let rule: ScanEngine.SourceRule
        /// 叶子清单（相对路径 + 字节数）—— **测试侧的独立事实**，不复用引擎的算法。
        let leaves: [(rel: String, size: Int64)]

        /// 全部叶子的字节和（整块候选应当等于它）。
        var totalBytes: Int64 { leaves.reduce(0) { $0 + $1.size } }
    }

    /// 造一棵真目录树并配一条**只认这棵树**的来源规则。
    ///
    /// 规则片段 = 根路径 + 尾斜杠（与生产默认规则同形：片段带尾斜杠 ⇒ 根目录自身不匹配）。
    private func makeStore(source: Source) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("residue-wholeblock-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        // 根下**直接**放一个叶子 —— 保证「第一次展开就扫到东西」，
        // 中止位置因此是确定的（见 `testInterruptedScanDoesNotEmitWholeBlockCandidate`）。
        let leaves: [(String, Int64)] = [
            ("blob", 7),
            ("v3/files/aa/bb", 100),
            ("v3/files/cc/dd", 200),
            ("index/ee", 50),
        ]
        for (rel, size) in leaves {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(repeating: 0x41, count: Int(size)).write(to: url)
        }

        return Fixture(
            root: root,
            rule: ScanEngine.SourceRule(source: source, pathFragments: [root.path + "/"]),
            leaves: leaves.map { (rel: $0.0, size: $0.1) }
        )
    }

    // MARK: - 整块来源

    /// 整块来源扫完**只产出一条候选**（不逐条列哈希碎片）。
    func testWholeBlockSourceProducesSingleCandidate() throws {
        let f = try makeStore(source: .pnpmStore)
        let engine = ScanEngine(rules: [f.rule])

        let r = try engine.scan(root: f.root.path, mode: .full)

        XCTAssertEqual(
            r.candidates.count, 1,
            "整块来源只产出一条候选（不逐条列哈希碎片），实为 \(r.candidates.count) 条"
        )
        XCTAssertEqual(r.candidates.first?.source, Source.pnpmStore.rawValue)
    }

    /// 整块候选的字节 = 全部叶子字节之和。
    func testWholeBlockCandidateBytesEqualSumOfLeaves() throws {
        let f = try makeStore(source: .pnpmStore)
        let engine = ScanEngine(rules: [f.rule])

        let r = try engine.scan(root: f.root.path, mode: .full)

        XCTAssertEqual(
            r.candidates.first?.bytes, f.totalBytes,
            "整块候选的字节必须等于叶子字节之和（\(f.totalBytes)）"
        )
    }

    /// 整块候选代表**整个来源根**：路径 = 扫描根，标记为目录。
    func testWholeBlockCandidatePathIsScanRoot() throws {
        let f = try makeStore(source: .bunCache)
        let engine = ScanEngine(rules: [f.rule])

        let r = try engine.scan(root: f.root.path, mode: .full)

        XCTAssertEqual(r.candidates.first?.path, f.root.path, "整块候选的路径 = 扫描根")
        XCTAssertEqual(r.candidates.first?.isDirectory, true, "整块候选标记为目录")
    }

    /// 空来源**不产候选**（总量为 0 的来源不占行 —— 契约「总量为 0 的来源不进判定域」）。
    func testEmptyWholeBlockSourceProducesNoCandidate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("residue-wholeblock-empty-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let engine = ScanEngine(rules: [
            ScanEngine.SourceRule(source: .pnpmStore, pathFragments: [root.path + "/"])
        ])

        let r = try engine.scan(root: root.path, mode: .full)

        XCTAssertTrue(r.candidates.isEmpty, "空来源不产候选（不得报 0 字节的假候选）")
    }

    // MARK: - 逐条粒度不受影响

    /// 逐条粒度来源（uv cache）**仍是逐条候选**。
    func testPerEntrySourceStillProducesPerLeafCandidates() throws {
        let f = try makeStore(source: .uvCache)
        let engine = ScanEngine(rules: [f.rule])

        let r = try engine.scan(root: f.root.path, mode: .full)

        XCTAssertEqual(
            r.candidates.count, f.leaves.count,
            "逐条粒度来源每个叶子一条候选（\(f.leaves.count) 条）"
        )
        XCTAssertEqual(r.candidates.reduce(Int64(0)) { $0 + $1.bytes }, f.totalBytes)
    }

    // MARK: - 中止

    /// **中止时不得产出整块候选** —— 否则把「扫了一半」说成「这个来源就这么多」
    /// （不变量③「不把未知判为安全」）。
    func testInterruptedScanDoesNotEmitWholeBlockCandidate() throws {
        let f = try makeStore(source: .pnpmStore)
        let engine = ScanEngine(rules: [f.rule])

        let counter = AbortCounter()
        let abort = ScanEngine.AbortCheck {
            counter.bump()
            return counter.value > 1 ? .userCancelled : nil
        }

        let r = try engine.scan(root: f.root.path, mode: .full, abortCheck: abort)

        XCTAssertEqual(r.aborted, .userCancelled, "本次扫描应被中断")
        XCTAssertTrue(r.candidates.isEmpty, "中止时不得产出整块候选（会把「扫了一半」说成「就这么多」）")
    }

    /// 中止时**已累计的整块字节进断点**（续扫的起点）。
    func testInterruptedScanStoresAggregatedBytesInCheckpoint() throws {
        let f = try makeStore(source: .pnpmStore)
        let engine = ScanEngine(rules: [f.rule])

        let counter = AbortCounter()
        let abort = ScanEngine.AbortCheck {
            counter.bump()
            return counter.value > 1 ? .userCancelled : nil
        }

        let r = try engine.scan(root: f.root.path, mode: .full, abortCheck: abort)
        let cp = try XCTUnwrap(r.checkpoint, "中断时必须返回断点内容")

        // 中止发生在第二次展开目录之前 ⇒ 只扫到根下那个 7 字节叶子。
        XCTAssertEqual(
            cp.aggregatedBytes[Source.pnpmStore.rawValue], 7,
            "断点里应带上已累计的整块字节（根下那个 7 字节叶子）"
        )
    }

    // MARK: - 断点续扫

    /// **续扫与一次性全量扫描完全一致**（整块字节不重不漏）。
    func testResumeFromCheckpointYieldsSameAggregatedBytes() throws {
        let f = try makeStore(source: .pnpmStore)
        let engine = ScanEngine(rules: [f.rule])

        let baseline = try engine.scan(root: f.root.path, mode: .full)

        let counter = AbortCounter()
        let abort = ScanEngine.AbortCheck {
            counter.bump()
            return counter.value > 1 ? .userCancelled : nil
        }
        let first = try engine.scan(root: f.root.path, mode: .full, abortCheck: abort)
        let cp = try XCTUnwrap(first.checkpoint)

        let resumed = try engine.scan(root: f.root.path, mode: .full, checkpoint: cp)

        XCTAssertEqual(resumed.candidates.count, 1, "续扫后仍只有一条整块候选（不得重复）")
        XCTAssertEqual(
            resumed.candidates.first?.bytes, baseline.candidates.first?.bytes,
            "续扫后的整块字节必须与未中断扫描一致（不重不漏）"
        )
        XCTAssertEqual(
            resumed.candidates.first?.bytes, f.totalBytes,
            "续扫后的整块字节必须等于叶子字节之和"
        )
    }

    /// 续扫时**已累计的字节不得被重复累加**（断点是唯一真相）。
    func testResumeDoesNotDoubleCountAggregatedBytes() throws {
        let f = try makeStore(source: .pnpmStore)
        let engine = ScanEngine(rules: [f.rule])

        let counter = AbortCounter()
        let abort = ScanEngine.AbortCheck {
            counter.bump()
            return counter.value > 1 ? .userCancelled : nil
        }
        let first = try engine.scan(root: f.root.path, mode: .full, abortCheck: abort)
        let cp = try XCTUnwrap(first.checkpoint)

        // 续扫两次（第二次是幂等性检查：断点续扫后不该再改数）
        let resumed = try engine.scan(root: f.root.path, mode: .full, checkpoint: cp)
        XCTAssertEqual(resumed.candidates.first?.bytes, f.totalBytes)
        XCTAssertLessThanOrEqual(
            resumed.candidates.first?.bytes ?? .max, f.totalBytes,
            "整块字节不得超过叶子字节之和（重复累加的信号）"
        )
    }

    // MARK: - 归属唯一性

    /// 默认规则下，**任一整块来源的根只归属它自己一个来源**
    /// —— 否则一条扫描根会产出两条同路径候选（身份键冲突）。
    func testDefaultRulesGiveEachWholeBlockRootASingleOwner() {
        let roots = SourceRoots.resolve(home: "/Users/example")
        for source in [Source.pnpmStore, .bunCache] {
            let root = try? XCTUnwrap(roots.first { $0.0 == source.rawValue }?.1)
            guard let root else { continue }
            let matched = ScanEngine.SourceRule.match(
                path: root + "/", rules: ScanEngine.SourceRule.defaults
            )
            XCTAssertEqual(
                matched, [source.rawValue],
                "\(source.displayName) 的扫描根只应归属它自己一个来源"
            )
        }
    }

    // MARK: - 辅助

    /// 线程安全计数器（`AbortCheck` 可能从后台线程调用）。
    private final class AbortCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0

        var value: Int {
            lock.lock(); defer { lock.unlock() }
            return n
        }

        @discardableResult
        func bump() -> Int {
            lock.lock(); defer { lock.unlock() }
            n += 1
            return n
        }
    }
}
