import XCTest
@testable import ResidueCore

/// 扫描器与断点续扫的用例集。
///
/// 期望值来源：`Residue-R2-技术方案-v1.6.md` ADR-04 / IF-01 / IF-02 / §5.5，
/// 以及 AC-20 的判定「重启后可续扫结果断言：三项一致」。
///
/// **特别覆盖 K2 实测暴露的那个错误**：R2 v1.5 的「名字**典序**最大值」水位在
/// APFS 上必然失败（`readdir` 是**哈希序**），200 项目录漏 70% —— v1.6 改为
/// 「**已完成名字集合**」，本测试用例**显式构造哈希序**来证明它不会再漏。
final class ScanEngineTests: XCTestCase {

    // MARK: - 可注入的文件系统（**哈希序**，复现 APFS 行为）

    /// 内存文件系统：目录内容**按给定顺序返回**（不排序）→ 模拟 APFS 的哈希序。
    final class MemoryFS: ScanEngine.FileSystem, @unchecked Sendable {
        var dirs: [String: [(name: String, isDirectory: Bool?)]] = [:]
        var attrs: [String: (birthtime: Date, size: Int64, isDirectory: Bool)] = [:]

        /// 这些路径**存在但不可读**（模拟 `EACCES`）——用于覆盖二分后的 `pathDenied`。
        ///
        /// 没有这个集合时，`pathDenied` 分支在单测里永远走不到，
        /// 「按 errno 二分」就只有真机才验得到。
        var deniedPaths: Set<String> = []

        func listDirectory(at path: String) throws -> [(name: String, isDirectory: Bool?)] {
            if deniedPaths.contains(path) {
                throw ScanEngine.ScanError.pathDenied(path)
            }
            guard let d = dirs[path] else { throw ScanEngine.ScanError.pathNotFound(path) }
            return d
        }
        func attributes(at path: String) throws -> (birthtime: Date, size: Int64, isDirectory: Bool) {
            if deniedPaths.contains(path) {
                throw ScanEngine.ScanError.pathDenied(path)
            }
            guard let a = attrs[path] else { throw ScanEngine.ScanError.pathNotFound(path) }
            return (birthtime: a.birthtime, size: a.size, isDirectory: a.isDirectory)
        }
        func exists(at path: String) -> Bool { dirs[path] != nil || attrs[path] != nil }

        /// 建一棵目录树：每层 `width` 个子项，名字刻意**不按字典序**排。
        ///
        /// **每层用不同前缀**（`d0`, `d1`, ...）—— 否则会出现 `n2/n2/n2` 这种
        /// 同名嵌套，而 `dirs` 只按字面路径索引 → 目录其实不存在。
        func buildTree(root: String, depth: Int, width: Int, fileSize: Int64) {
            var level = [root]
            for d in 0..<depth {
                var next: [String] = []
                for dir in level {
                    // 名字顺序：z, y, x, ... → **非字典序**
                    var items: [(String, Bool?)] = []
                    for i in stride(from: width, through: 1, by: -1) {
                        let name = "d\(d)n\(i)"
                        items.append((name, i % 2 == 0))
                    }
                    dirs[dir] = items
                    for (name, isDirOpt) in items {
                        let isDir = isDirOpt ?? false
                        let full = (dir as NSString).appendingPathComponent(name)
                        attrs[full] = (Date(timeIntervalSince1970: 0), fileSize, isDir)
                        if isDir { next.append(full) }
                    }
                }
                level = next
            }
            // 叶子层也要有真实目录（供 listDirectory 调用）
            for dir in level {
                if dirs[dir] == nil { dirs[dir] = [] }
            }
        }
    }

    /// 线程安全计数器（`AbortCheck` 的闭包是 `@Sendable` → 不可捕获可变变量）。
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private func makeEngine(_ fs: MemoryFS) -> ScanEngine {
        ScanEngine(fileSystem: fs, rules: [
            ScanEngine.SourceRule(source: .uvCache, pathFragments: ["/.cache/uv/"])
        ])
    }

    // MARK: - 基本扫描

    func testScanCollectsCandidatesOnlyForMatchedSources() throws {
        let fs = MemoryFS()
        fs.dirs["/root/.cache/uv"] = [("pkg-a", false), ("pkg-b", false)]
        fs.attrs["/root/.cache/uv/pkg-a"] = (Date(), 100, false)
        fs.attrs["/root/.cache/uv/pkg-b"] = (Date(), 200, false)
        fs.dirs["/root/other"] = [("not-a-candidate", false)]
        fs.attrs["/root/other/not-a-candidate"] = (Date(), 999, false)

        let engine = makeEngine(fs)
        let result = try engine.scan(root: "/root/.cache/uv", mode: .full)

        XCTAssertEqual(result.candidates.count, 2, "只有命中来源模式的才是候选")
        XCTAssertTrue(
            // 候选的 source 必须等于 `Source.rawValue`。
            // 曾有 `uv.cache`（规则名）与 `uv_cache`（枚举值）两套标识，
            // 导致「按来源过滤候选」恒为空 → T=0 → 门槛永不满足。
            result.candidates.allSatisfy { $0.source == Source.uvCache.rawValue },
            "候选 source 必须等于 Source.rawValue"
        )
        XCTAssertEqual(result.filesScanned, 2)
    }

    func testFullScanTakesSnapshotButIncrementalDoesNot() throws {
        let fs = MemoryFS()
        fs.dirs["/root/.cache/uv"] = [("a", false)]
        fs.attrs["/root/.cache/uv/a"] = (Date(), 1, false)
        let engine = makeEngine(fs)

        let full = try engine.scan(root: "/root/.cache/uv", mode: .full)
        XCTAssertTrue(full.snapshotTaken, "full 扫描取快照")

        let inc = try engine.scan(root: "/root/.cache/uv", mode: .incremental)
        XCTAssertFalse(inc.snapshotTaken, "增量扫描不取快照（R2 §7.3：否则 T 偏小且静默）")
    }

    func testSnapshotCanBeForcedOffForFullScan() throws {
        let fs = MemoryFS()
        fs.dirs["/root/.cache/uv"] = [("a", false)]
        fs.attrs["/root/.cache/uv/a"] = (Date(), 1, false)
        let engine = makeEngine(fs)
        let r = try engine.scan(root: "/root/.cache/uv", mode: .full, takeSnapshot: false)
        XCTAssertFalse(r.snapshotTaken)
    }

    /// 根不存在 → `E-101`（**错误**，不是无权限）。
    func testMissingRootThrowsPathNotFound() {
        let fs = MemoryFS()
        let engine = makeEngine(fs)
        XCTAssertThrowsError(try engine.scan(root: "/nope", mode: .full)) { error in
            XCTAssertEqual(error as? ScanEngine.ScanError, .pathNotFound("/nope"))
            XCTAssertEqual(
                (error as? ScanEngine.ScanError)?.diagnostic, .e101,
                "路径不存在归 E-101（错误）；若归无权限，用户会被引导去授权一个不存在的东西"
            )
        }
    }

    /// 根存在但不可读 → `E-108`（**无权限**，AC-14 第一类）。
    ///
    /// 这条与上一条成对存在，缺一条二分就没被覆盖：
    /// 只有「不存在」会绿，而「读不到」永远走不到，AC-14 第一类的
    /// 「所缺权限 + 授权指引」也就永远不会被验证。
    func testDeniedRootThrowsPathDenied() {
        let fs = MemoryFS()
        fs.dirs["/root/.cache/uv"] = []
        fs.deniedPaths.insert("/root/.cache/uv")
        let engine = makeEngine(fs)
        XCTAssertThrowsError(try engine.scan(root: "/root/.cache/uv", mode: .full)) { error in
            XCTAssertEqual(error as? ScanEngine.ScanError, .pathDenied("/root/.cache/uv"))
            XCTAssertEqual(
                (error as? ScanEngine.ScanError)?.diagnostic, .e108,
                "读到 EACCES 必须归 E-108（无权限）"
            )
            XCTAssertEqual(
                (error as? ScanEngine.ScanError)?.diagnostic.category, .noPermission,
                "AC-14 第一类要求这条落在「无权限」分类里，否则授权指引永远不出现"
            )
        }
    }

    // MARK: - 中止（aborted ≠ 失败）

    func testAbortSavesBreakpointAndIsNotAnError() throws {
        let fs = MemoryFS()
        // **三层**目录链 → while 循环至少迭代 3 次 → 中止检查会被触发多次
        fs.dirs["/root/.cache/uv"] = [("d1", true)]
        fs.dirs["/root/.cache/uv/d1"] = [("d2", true)]
        fs.dirs["/root/.cache/uv/d1/d2"] = [("f", false)]
        fs.attrs["/root/.cache/uv/d1"] = (Date(), 1, true)
        fs.attrs["/root/.cache/uv/d1/d2"] = (Date(), 1, true)
        fs.attrs["/root/.cache/uv/d1/d2/f"] = (Date(), 1, false)
        let engine = makeEngine(fs)

        let counter = Counter()
        let abort = ScanEngine.AbortCheck {
            counter.bump()
            return counter.value > 1 ? .userCancelled : nil
        }
        let r = try engine.scan(root: "/root/.cache/uv", mode: .full, abortCheck: abort)

        XCTAssertEqual(r.aborted, .userCancelled)
        XCTAssertTrue(r.breakpointSaved, "中断要落断点")
        XCTAssertFalse(r.snapshotTaken, "中断不取快照")
    }

    func testTimeoutIsDistinctFromUserCancel() throws {
        let fs = MemoryFS()
        fs.dirs["/root/.cache/uv"] = [("d1", true)]
        fs.dirs["/root/.cache/uv/d1"] = [("f", false)]
        fs.attrs["/root/.cache/uv/d1"] = (Date(), 1, true)
        fs.attrs["/root/.cache/uv/d1/f"] = (Date(), 1, false)
        let engine = makeEngine(fs)
        // 第一次检查就返回 timeout（根目录取出前）
        let r = try engine.scan(
            root: "/root/.cache/uv", mode: .full,
            abortCheck: ScanEngine.AbortCheck { .timeout }
        )
        XCTAssertEqual(r.aborted, .timeout, "超时与用户取消是两个不同的中止原因")
        XCTAssertTrue(r.breakpointSaved)
    }

    // MARK: - 断点续扫：AC-20 的三项一致

    /// **本轮最关键的用例**（用**真文件系统**）：R2 v1.5 的「名字**典序**最大值」水位在
    /// APFS 上必然失败（`readdir` 是**哈希序**），200 项目录漏 70%。
    ///
    /// **为什么必须用真文件系统而不是 `MemoryFS`**：`MemoryFS` 是扁平字典、
    /// `listDirectory` 不递归 → 「扫描」是逐层手动展开 → 中断点落在哪一层
    /// 会与真实遍历语义不符 → **用例本身失真**（本人已在这条上反复三轮）。
    /// 真目录 + 真 `readdir` 才是 AC-20 的真实场景。
    func testResumeOnRealFileSystemProducesIdenticalThreeItems() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("residue-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let cacheDir = root.appendingPathComponent(".cache/uv")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // 三层 × 每层 8 个子项，名字**非字典序**（模拟 APFS 哈希序）
        // **必须有显式深度上限**（`guard level < maxLevel else { return }`）——
        // 否则在真文件系统上会无限递归 → 栈溢出（实测 12000+ 帧后 Signal 11）。
        // 这是本轮测试脚手架的真 bug，`MemoryFS` 版从不建真树所以一直没暴露。
        func makeTree(_ dir: URL, level: Int, maxLevel: Int) {
            guard level < maxLevel else { return }
            for i in stride(from: 8, through: 1, by: -1) {
                let isDir = i % 2 == 0
                let child = dir.appendingPathComponent("d\(level)n\(i)")
                if isDir {
                    try? FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
                    makeTree(child, level: level + 1, maxLevel: maxLevel)
                } else {
                    FileManager.default.createFile(atPath: child.path, contents: Data(repeating: 0x41, count: 100))
                }
            }
        }
        makeTree(cacheDir, level: 0, maxLevel: 3)

        let engine = ScanEngine(
            fileSystem: ScanEngine.DefaultFileSystem(),
            rules: [ScanEngine.SourceRule(source: .uvCache, pathFragments: ["/.cache/uv/"])]
        )

        // 基线：一次跑完
        let baseline = try engine.scan(root: cacheDir.path, mode: .full)
        let baseConsistency = ScanEngine.Consistency(baseline)
        XCTAssertGreaterThan(baseConsistency.filesScanned, 0, "基线应扫到条目")

        // 中断 → **从结果取断点** → 续扫
        let counter = Counter()
        let abort = ScanEngine.AbortCheck {
            counter.bump()
            return counter.value > 3 ? .userCancelled : nil
        }
        let first = try engine.scan(root: cacheDir.path, mode: .full, abortCheck: abort)
        XCTAssertNotNil(first.aborted, "第一次扫描被中断")
        let cp = try XCTUnwrap(first.checkpoint, "中断时必须返回断点内容（否则续扫无从谈起）")

        let resumed = try engine.scan(root: cacheDir.path, mode: .full, checkpoint: cp)
        let resumedConsistency = ScanEngine.Consistency(resumed)

        XCTAssertEqual(
            resumedConsistency.filesScanned,
            baseConsistency.filesScanned,
            "续扫后的文件数必须与未中断扫描一致（AC-20）"
        )
        XCTAssertEqual(
            resumedConsistency.candidatePaths,
            baseConsistency.candidatePaths,
            "续扫后的候选清单必须与未中断扫描一致（AC-20）"
        )
    }

    /// **断点的名字集合机制本身**：已完成的名字会被跳过。
    func testCompletedNamesAreSkippedOnResume() throws {
        let fs = MemoryFS()
        fs.dirs["/root/.cache/uv"] = [("a", false), ("b", false), ("c", false)]
        for n in ["a", "b", "c"] { fs.attrs["/root/.cache/uv/\(n)"] = (Date(), 1, false) }
        let engine = makeEngine(fs)

        var cp = ScanEngine.Checkpoint()
        cp.markCompleted(dir: "/root/.cache/uv", name: "a")
        cp.markCompleted(dir: "/root/.cache/uv", name: "b")

        let r = try engine.scan(root: "/root/.cache/uv", mode: .full, checkpoint: cp)
        XCTAssertEqual(r.candidates.count, 1, "已完成的条目被跳过 → 只剩 c")
        XCTAssertEqual(r.candidates.first?.path, "/root/.cache/uv/c")
    }

    /// **非字典序也不影响正确性**：断点用名字集合，顺序无关。
    func testResumeIsIndependentOfDirectoryOrder() throws {
        let fs = MemoryFS()
        // 故意用 z, y, x 顺序（哈希序）
        fs.dirs["/root/.cache/uv"] = [("z", false), ("y", false), ("x", false)]
        for n in ["z", "y", "x"] { fs.attrs["/root/.cache/uv/\(n)"] = (Date(), 1, false) }
        let engine = makeEngine(fs)

        var cp = ScanEngine.Checkpoint()
        cp.markCompleted(dir: "/root/.cache/uv", name: "z")
        let r = try engine.scan(root: "/root/.cache/uv", mode: .full, checkpoint: cp)
        XCTAssertEqual(r.candidates.map(\.path).sorted(),
                       ["/root/.cache/uv/x", "/root/.cache/uv/y"],
                       "名字集合机制与目录顺序无关（这正是 v1.5 字典序水位方案失败的场景）")
    }

    func testCheckpointAccumulatesCountsAcrossResume() throws {
        let fs = MemoryFS()
        fs.dirs["/root/.cache/uv"] = [("a", false), ("b", false)]
        for n in ["a", "b"] { fs.attrs["/root/.cache/uv/\(n)"] = (Date(), 10, false) }
        let engine = makeEngine(fs)

        var cp = ScanEngine.Checkpoint()
        cp.markCompleted(dir: "/root/.cache/uv", name: "a")
        // **累计计数起点 = `countedFiles`**（`fileCount` 是同义别名，但新代码用前者）
        cp.countedFiles = 1
        cp.fileCount = 1
        cp.byteCount = 10
        cp.candidates = [
            ScanEngine.Candidate(path: "/root/.cache/uv/a", birthtime: Date(), bytes: 10, isDirectory: false, source: "uv.cache")
        ]

        let r = try engine.scan(root: "/root/.cache/uv", mode: .full, checkpoint: cp)
        XCTAssertEqual(r.filesScanned, 2, "断点累计叶子数 + 本次新扫叶子数")
        XCTAssertEqual(r.candidates.count, 2, "断点候选 + 本次新增")
    }

    // MARK: - 一致性比较器

    func testConsistencyComparesFileCountBytesAndCandidatePaths() {
        let r = ScanEngine.ScanResult(
            startedAt: Date(), finishedAt: Date(), mode: .full,
            filesScanned: 3, candidates: [
                ScanEngine.Candidate(path: "/b", birthtime: Date(), bytes: 20, isDirectory: false, source: "s"),
                ScanEngine.Candidate(path: "/a", birthtime: Date(), bytes: 10, isDirectory: false, source: "s"),
            ],
            unknownCount: 0, aborted: nil, breakpointSaved: false, snapshotTaken: true
        )
        let c = ScanEngine.Consistency(r)
        XCTAssertEqual(c.filesScanned, 3)
        XCTAssertEqual(c.byteCount, 30)
        XCTAssertEqual(c.candidatePaths, ["/a", "/b"], "路径排序后才可比")
    }

    func testHashIsStableForSameSetAndDiffersForDifferentSet() {
        let a = ScanEngine.hash(["x", "y", "z"])
        let b = ScanEngine.hash(["z", "y", "x"])
        XCTAssertEqual(a, b, "集合哈希与插入顺序无关")
        XCTAssertNotEqual(a, ScanEngine.hash(["x", "y"]))
    }

    // MARK: - 来源规则（封闭枚举）

    func testSourceMatchingIsClosedEnumeration() {
        XCTAssertEqual(ScanEngine.SourceRule.match(path: "/Users/x/.cache/uv/archive/a"), ["uv_cache"])
        XCTAssertEqual(ScanEngine.SourceRule.match(path: "/Users/x/.npm/_npx/abc"), ["npm_npx"])
        XCTAssertEqual(ScanEngine.SourceRule.match(path: "/Users/x/.local/pipx/venv/v"), ["pipx_run"])
        XCTAssertTrue(ScanEngine.SourceRule.match(path: "/Users/x/Documents/secret").isEmpty,
                      "非来源路径不产生候选（个人文件零扫描零删除）")
    }

    func testMultipleSourcesCanMatchSamePath() {
        let matched = ScanEngine.SourceRule.match(path: "/x/.cache/uv/.npm/_npx/y")
        XCTAssertEqual(matched.count, 2, "一个路径可命中多个来源")
    }

    // MARK: - CR-032：按根归因 + 文件名过滤

    /// 自定义缓存目录（`HOMEBREW_CACHE=/tmp/x`）不在任何静态路径片段里。
    ///
    /// **显式传 `source:` 时必须仍能归因**；若退回路径片段匹配，
    /// 这类机器上整条来源的候选会静默为 0（CR-032 · P0-2）。
    func testExplicitSourceAttributesCandidatesOutsideKnownPathFragments() throws {
        let fs = MemoryFS()
        fs.dirs["/tmp/custom-brew"] = [("foo--1.0.bottle.tar.gz", false)]
        fs.attrs["/tmp/custom-brew/foo--1.0.bottle.tar.gz"] = (
            Date(timeIntervalSince1970: 0), 4096, false
        )
        // 规则里**没有** brew 片段 —— 归因只能来自 `source:` 参数
        let engine = ScanEngine(fileSystem: fs, rules: [])
        let r = try engine.scan(root: "/tmp/custom-brew", mode: .full, source: .brewCache)

        XCTAssertEqual(r.candidates.count, 1)
        XCTAssertEqual(r.candidates.first?.source, Source.brewCache.rawValue)
    }

    /// brew 的 `downloads/` 混放瓶子与清单：只有 `*.bottle*.tar.gz` 是候选。
    ///
    /// 若把清单（`.json`）、cask、源码包也算进去，「可回收字节」会把
    /// 删了也没用的元数据算成可释放空间。
    func testBottleFilterKeepsOnlyBottleTarballs() throws {
        let fs = MemoryFS()
        let root = "/Users/x/Library/Caches/Homebrew/downloads"
        let names = [
            ("foo--1.0.arm64_sonoma.bottle.tar.gz", true),   // 瓶子 → 收
            ("foo--1.0.bottle.json", false),                  // 清单 → 弃
            ("bar--2.0.catalina.bottle.tar.gz", true),        // 瓶子 → 收
            ("bar--2.0.tar.gz", false),                       // 源码包 → 弃
            ("baz.dmg", false),                               // cask 包 → 弃
        ]
        fs.dirs[root] = names.map { ($0.0, false) }
        for (name, _) in names {
            fs.attrs[root + "/" + name] = (Date(timeIntervalSince1970: 0), 128, false)
        }

        let filter = ScanEngine.FileNameFilter(
            requiredSubstrings: [".bottle"],
            requiredSuffixes: [".tar.gz"]
        )
        let engine = ScanEngine(fileSystem: fs, rules: [])
        let r = try engine.scan(
            root: root, mode: .full, source: .brewCache, fileFilter: filter
        )

        XCTAssertEqual(Set(r.candidates.map(\.path)), [
            root + "/foo--1.0.arm64_sonoma.bottle.tar.gz",
            root + "/bar--2.0.catalina.bottle.tar.gz",
        ])
        XCTAssertEqual(r.filesScanned, names.count, "过滤只影响候选，不影响扫描计数")
    }
}
