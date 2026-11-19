import XCTest
@testable import ResidueCore

/// CR-038 · 清理来源扩展（判定域 2 类 → 4 类、域外只报告 1 类 → 3 类）。
///
/// ## 为什么要单独一个文件
///
/// 本文件守的是**来源封闭枚举的形状**。而 `Source` 的声明序被烧进了载体文件的
/// 段索引（`ResidueStateFile.swift:613` 写 / `:892` 读）⇒ 枚举一变，载体格式、
/// 页面投影、扫描粒度全部跟着变 ⇒ 这几件事必须由**同一个守卫**同时看着，
/// 否则「加了 case 但忘了改某处」会静默退化（数量恒为 0、字节漏算、段索引错位）。
///
/// **尾部追加是硬约束**：在枚举中间插入 case ⇒ 存量载体的旧来源段索引整体错位 ⇒
/// 误判数 `a` 归错来源 ⇒ 违反不变量④「删之前先证明自己判得准」。
final class SourceExpansionTests: XCTestCase {

    // MARK: - 步骤 1 · 来源枚举

    func test_sourceAllCasesCountIsSeven() {
        XCTAssertEqual(Source.allCases.count, 7)
    }

    /// ★ 尾部追加的回归守卫：前三个 rawValue 不能变。
    ///
    /// 存量载体的段索引 0 / 1 / 2 仍须指向 `uv_cache` / `npm_npx` / `pipx_run`。
    func test_sourceRawValuesOfFirstThreeAreUnchanged() {
        XCTAssertEqual(Source.allCases[0].rawValue, "uv_cache")
        XCTAssertEqual(Source.allCases[1].rawValue, "npm_npx")
        XCTAssertEqual(Source.allCases[2].rawValue, "pipx_run")
    }

    func test_newSourcesRawValues() {
        XCTAssertEqual(Source.homebrewDownloads.rawValue, "brew_downloads")
        XCTAssertEqual(Source.cargoRegistryCache.rawValue, "cargo_registry_cache")
        XCTAssertEqual(Source.pnpmStore.rawValue, "pnpm_store")
        XCTAssertEqual(Source.bunCache.rawValue, "bun_cache")
    }

    func test_decisionDomainContainsFourSources() {
        let inDomain = Source.allCases.filter { $0.isInDecisionDomain }
        XCTAssertEqual(
            Set(inDomain),
            Set([.uvCache, .npmNpx, .homebrewDownloads, .cargoRegistryCache])
        )
    }

    func test_reportOnlySourcesAreThree() {
        let outOfDomain = Source.allCases.filter { !$0.isInDecisionDomain }
        XCTAssertEqual(Set(outOfDomain), Set([.pipxRun, .pnpmStore, .bunCache]))
    }

    /// 整块粒度**只给 pnpm / bun**（内容寻址 + 硬链接布局，逐条列举会产出上万个碎片）。
    func test_candidateGranularityIsWholeBlockOnlyForPnpmAndBun() {
        XCTAssertEqual(Source.pnpmStore.candidateGranularity, .wholeBlock)
        XCTAssertEqual(Source.bunCache.candidateGranularity, .wholeBlock)
        let perEntry: [Source] = [.uvCache, .npmNpx, .pipxRun, .homebrewDownloads, .cargoRegistryCache]
        for source in perEntry {
            XCTAssertEqual(source.candidateGranularity, .perEntry, "\(source.rawValue) 应为逐条粒度")
        }
    }

    // MARK: - 步骤 5 · 判定域成员指纹

    func test_decisionDomainSignatureIsStableAcrossCalls() {
        XCTAssertEqual(Source.decisionDomainSignature, Source.decisionDomainSignature)
    }

    /// 指纹必须覆盖**全部来源及其归属**（不只判定域）⇒ 任何来源集合变化都触发重置。
    func test_decisionDomainSignatureContainsAllSources() {
        let signature = Source.decisionDomainSignature
        for source in Source.allCases {
            XCTAssertTrue(
                signature.contains(source.rawValue),
                "指纹缺 \(source.rawValue)：\(signature)"
            )
        }
    }

    func test_decisionDomainSignatureEncodesMembership() {
        let signature = Source.decisionDomainSignature
        XCTAssertTrue(signature.contains("uv_cache=1"), signature)
        XCTAssertTrue(signature.contains("npm_npx=1"), signature)
        XCTAssertTrue(signature.contains("pipx_run=0"), signature)
        XCTAssertTrue(signature.contains("pnpm_store=0"), signature)
        XCTAssertTrue(signature.contains("bun_cache=0"), signature)
    }

    /// 指纹必须**区分归属** —— 否则「域内新增」与「域外新增」会撞出同一个指纹。
    func test_decisionDomainSignatureDistinguishesMembership() {
        let signature = Source.decisionDomainSignature
        XCTAssertTrue(signature.contains("brew_downloads=1"), signature)
        XCTAssertTrue(signature.contains("cargo_registry_cache=1"), signature)
    }

    // MARK: - 步骤 2 · 路径片段

    private static let samplePaths: [(path: String, source: Source)] = [
        ("/Users/x/.cache/uv/archive-v0/x", .uvCache),
        ("/Users/x/.npm/_npx/abc/node_modules/x", .npmNpx),
        ("/Users/x/.local/pipx/venv/x", .pipxRun),
        ("/Users/x/Library/Caches/Homebrew/downloads/foo.tar.gz", .homebrewDownloads),
        ("/Users/x/.cargo/registry/cache/index.crates.io-abc/foo.crate", .cargoRegistryCache),
        ("/Users/x/Library/pnpm/store/v11/files/00/abcd", .pnpmStore),
        ("/Users/x/.bun/install/cache/foo@1.0.0", .bunCache),
    ]

    func test_eachSamplePathMatchesExactlyOneSource() {
        for sample in Self.samplePaths {
            XCTAssertEqual(
                ScanEngine.SourceRule.match(path: sample.path),
                [sample.source.rawValue],
                "\(sample.path) 命中来源不对"
            )
        }
    }

    /// ★ `cargo registry` 的 `src`（解压后的源码）**不是缓存**，不能命中。
    func test_cargoRegistrySrcIsNotMatched() {
        XCTAssertTrue(
            ScanEngine.SourceRule.match(path: "/Users/x/.cargo/registry/src/index.crates.io-abc/foo").isEmpty
        )
    }

    /// ★ `brew` 的其它缓存（`api` / `Cask` / `git`）不能命中 —— 只有 `downloads` 可删。
    func test_brewNonDownloadCachesAreNotMatched() {
        for path in [
            "/Users/x/Library/Caches/Homebrew/api/formula.json",
            "/Users/x/Library/Caches/Homebrew/Cask/foo.zip",
            "/Users/x/Library/Caches/Homebrew/git/homebrew-core",
        ] {
            XCTAssertTrue(ScanEngine.SourceRule.match(path: path).isEmpty, "\(path) 不该命中")
        }
    }

    /// ★ 互斥的严密守卫：片段两两**互不包含** ⇒ 任意路径不可能同时命中两个片段。
    ///
    /// 依据字符串包含的传递性：若路径同时含片段 a 与 b，则 a 含 b 或 b 含 a。
    /// 所以「两两互不包含」是「片段互斥」的**充分条件** —— 抓到「`/.cargo/registry/cache/`
    /// 与 `/.cargo/registry/` 互相包含」这类错误。
    func test_noFragmentContainsAnotherFragment() {
        let fragments = ScanEngine.SourceRule.defaults.flatMap { $0.pathFragments }
        XCTAssertEqual(fragments.count, 7, "每个来源一条片段")
        for a in fragments {
            for b in fragments where a != b {
                XCTAssertFalse(a.contains(b), "片段 \(a) 含 \(b)")
                XCTAssertFalse(b.contains(a), "片段 \(b) 含 \(a)")
            }
        }
    }

    /// 片段必须**带尾斜杠** ⇒ 匹配的是根之下的路径，不是根本身（既有语义）。
    func test_fragmentsEndWithSlash() {
        for rule in ScanEngine.SourceRule.defaults {
            for fragment in rule.pathFragments {
                XCTAssertTrue(fragment.hasSuffix("/"), "\(fragment) 缺尾斜杠")
            }
        }
    }

    // MARK: - 步骤 3 · 来源根解析

    func test_sourceRootsResolveProducesSevenRoots() {
        let roots = SourceRoots.resolve(home: "/Users/x")
        XCTAssertEqual(roots.count, 7)
        XCTAssertEqual(roots.map(\.0), Source.allCases.map(\.rawValue))
    }

    func test_sourceRootsUsesProbedUvAndNpmDirs() {
        let roots = SourceRoots.resolve(
            home: "/Users/x",
            uvCacheDir: "/custom/uv",
            npmCacheDir: "/custom/npm"
        )
        XCTAssertEqual(roots.first { $0.0 == "uv_cache" }?.1, "/custom/uv")
        XCTAssertEqual(roots.first { $0.0 == "npm_npx" }?.1, "/custom/npm/_npx")
    }

    func test_sourceRootsFallsBackToHomeWhenProbeFails() {
        let roots = SourceRoots.resolve(home: "/Users/x", uvCacheDir: nil, npmCacheDir: nil)
        XCTAssertEqual(roots.first { $0.0 == "uv_cache" }?.1, "/Users/x/.cache/uv")
        XCTAssertEqual(roots.first { $0.0 == "npm_npx" }?.1, "/Users/x/.npm/_npx")
    }

    /// ★ `brew --cache` 输出可能带尾斜杠 ⇒ 直接拼 `/downloads` 会得到 `//downloads`
    /// ⇒ 后续叶子路径不含片段 ⇒ **一条候选都匹配不到**。
    func test_sourceRootsStripsTrailingSlashFromBrewCacheDir() {
        let roots = SourceRoots.resolve(home: "/Users/x", brewCacheDir: "/Users/x/Library/Caches/Homebrew/")
        XCTAssertEqual(
            roots.first { $0.0 == "brew_downloads" }?.1,
            "/Users/x/Library/Caches/Homebrew/downloads"
        )
    }

    func test_sourceRootsBrewAppendsDownloads() {
        let roots = SourceRoots.resolve(home: "/Users/x", brewCacheDir: "/Users/x/Library/Caches/Homebrew")
        XCTAssertEqual(
            roots.first { $0.0 == "brew_downloads" }?.1,
            "/Users/x/Library/Caches/Homebrew/downloads"
        )
    }

    func test_sourceRootsBrewFallsBackWhenProbeFails() {
        let roots = SourceRoots.resolve(home: "/Users/x", brewCacheDir: nil)
        XCTAssertEqual(
            roots.first { $0.0 == "brew_downloads" }?.1,
            "/Users/x/Library/Caches/Homebrew/downloads"
        )
    }

    /// cargo / pnpm / bun 走**固定路径、零探测**（零进程开销、零网络）。
    func test_sourceRootsFixedPathsForCargoPnpmBun() {
        let roots = SourceRoots.resolve(home: "/Users/x")
        XCTAssertEqual(
            roots.first { $0.0 == "cargo_registry_cache" }?.1,
            "/Users/x/.cargo/registry/cache"
        )
        XCTAssertEqual(roots.first { $0.0 == "pnpm_store" }?.1, "/Users/x/Library/pnpm/store")
        XCTAssertEqual(roots.first { $0.0 == "bun_cache" }?.1, "/Users/x/.bun/install/cache")
    }

    // MARK: - 步骤 6 · 页面投影

    /// 造一个**逐来源可控**的头部。
    ///
    /// ⚠️ `PageModelBuilder.build` **不调用** `ensureSourceRows()` ⇒
    /// `header.sources` 装了什么，行集合就以什么为准 ⇒ 夹具必须显式给全。
    private func makeHeader(
        entries: [SourceHeaderEntry],
        produced: Bool = true
    ) -> StateHeader {
        var h = StateHeader()
        h.round = 2
        h.countedDays = 14
        h.countedDaysCap = 14
        h.settlement = SettlementHeader(
            producedAt: produced ? Date(timeIntervalSince1970: 1_700_000_000) : nil,
            reportId: produced ? "r-1" : nil
        )
        h.sources = entries
        return h
    }

    /// 造一个来源的头部位（默认**无快照、未结算**）。
    private func makeEntry(
        _ source: Source,
        snapshot: Bool = false,
        T: Int? = nil,
        K: Int? = nil,
        J: Int? = nil,
        H: Int? = nil
    ) -> SourceHeaderEntry {
        SourceHeaderEntry(
            source: source,
            snapshotTaken: snapshot,
            T: T, K: K, J: J, H: H,
            a: 0, b: snapshot ? 3 : 0,
            slotCount: 0, doneCount: 0
        )
    }

    private func makeCandidate(_ source: Source, bytes: Int64 = 1024) -> ScanEngine.Candidate {
        ScanEngine.Candidate(
            path: "/tmp/\(source.rawValue)/item",
            birthtime: Date(timeIntervalSince1970: 0),
            bytes: bytes, isDirectory: false, source: source.rawValue
        )
    }

    private func makeContents(_ header: StateHeader) -> StateFileContents {
        StateFileContents(header: header)
    }

    /// ① 页的来源卡：**每个来源一张**（`Source.allCases` 的全集，不是「三来源」）。
    func test_overviewBlocksCountEqualsSourceCount() {
        let input = PageModelBuilder.Input(
            contents: makeContents(makeHeader(entries: Source.allCases.map { makeEntry($0) })),
            candidates: Source.allCases.map { makeCandidate($0) }
        )
        let m = PageModelBuilder.build(input)
        XCTAssertEqual(m.overviewBlocks.count, Source.allCases.count)
    }

    /// ⑤ 页矩阵行：全部来源都命中时，每个来源占一行。
    func test_reportRowsCountEqualsSourceCount() {
        let entries = Source.allCases.map {
            makeEntry($0, snapshot: true, T: 100, K: 90, J: 10, H: 30)
        }
        let input = PageModelBuilder.Input(
            contents: makeContents(makeHeader(entries: entries)),
            candidates: Source.allCases.map { makeCandidate($0) }
        )
        let m = PageModelBuilder.build(input)
        XCTAssertEqual(m.reportRows.count, Source.allCases.count)
    }

    /// 域外只报告来源（`pipx` run / `pnpm` store / `bun` cache）在 ⑤ 页恒「仅报告」。
    func test_reportOnlySourcesHaveReportOnlyParticipation() {
        let entries = Source.allCases.map {
            makeEntry($0, snapshot: true, T: 100, K: 90, J: 10, H: 30)
        }
        let input = PageModelBuilder.Input(
            contents: makeContents(makeHeader(entries: entries)),
            candidates: Source.allCases.map { makeCandidate($0) }
        )
        let m = PageModelBuilder.build(input)
        let reportOnlyNames = Source.allCases
            .filter { !$0.isInDecisionDomain }
            .map(\.displayName)
        XCTAssertEqual(reportOnlyNames.count, 3)
        for name in reportOnlyNames {
            let row = m.reportRows.first { $0.source == name }
            XCTAssertNotNil(row, "缺 \(name) 行")
            XCTAssertEqual(row?.cells[1][0].displayText, "仅报告", "\(name) 的参与列")
            XCTAssertEqual(row?.cells[6][0].displayText, "仅报告", "\(name) 的结论列")
        }
    }

    /// ① 页总量 = **全部来源**占用之和（含整块来源）。
    func test_totalFootprintIsSumAcrossAllSources() {
        let input = PageModelBuilder.Input(
            contents: makeContents(makeHeader(entries: Source.allCases.map { makeEntry($0) })),
            candidates: [
                makeCandidate(.uvCache, bytes: 1024),
                makeCandidate(.npmNpx, bytes: 2048),
                makeCandidate(.pnpmStore, bytes: 4096),
            ]
        )
        let m = PageModelBuilder.build(input)
        guard case .metric(let total, _) = m.totalFootprintBytes else {
            return XCTFail("总量必须是数值槽位")
        }
        XCTAssertEqual(total, 1024 + 2048 + 4096)
    }

    // MARK: - ⑤ 页行集合（PRD v5.6 :1094「行集合为条件式」）

    /// ★ 无快照 + 本窗无候选 ⇒ **不占行**（总量为 0 的来源不占行）。
    func test_reportRowsExcludeSourceWithoutCandidatesAndWithoutSnapshot() {
        let entries = Source.allCases.map { makeEntry($0) }
        let input = PageModelBuilder.Input(
            contents: makeContents(makeHeader(entries: entries)),
            candidates: [makeCandidate(.uvCache)]
        )
        let m = PageModelBuilder.build(input)
        XCTAssertEqual(m.reportRows.map(\.source), [Source.uvCache.displayName])
    }

    /// ★ 有快照但本窗没扫到 ⇒ **仍占行**（⑤ 页承载的是冻结的结算值，不能丢）。
    func test_reportRowsIncludeDecisionDomainSourceWithSnapshotButNoCandidates() {
        let entries: [SourceHeaderEntry] = [
            makeEntry(.uvCache, snapshot: true, T: 100, K: 90, J: 10, H: 30),
            makeEntry(.npmNpx, snapshot: true, T: 100, K: 90, J: 10, H: 30),
            makeEntry(.pipxRun),
            makeEntry(.homebrewDownloads),
            makeEntry(.cargoRegistryCache),
            makeEntry(.pnpmStore),
            makeEntry(.bunCache),
        ]
        let input = PageModelBuilder.Input(
            contents: makeContents(makeHeader(entries: entries)),
            candidates: [makeCandidate(.uvCache)]
        )
        let m = PageModelBuilder.build(input)
        XCTAssertEqual(
            m.reportRows.map(\.source),
            [Source.uvCache.displayName, Source.npmNpx.displayName]
        )
    }

    /// ★ 新入域来源（点亮后首次命中、本轮无快照）⇒ **占行**（PRD v5.6 :1094 A11）。
    func test_reportRowsIncludeNewlyHitSourceWithoutSnapshot() {
        let entries = Source.allCases.map { makeEntry($0) }
        let input = PageModelBuilder.Input(
            contents: makeContents(makeHeader(entries: entries)),
            candidates: [makeCandidate(.uvCache), makeCandidate(.homebrewDownloads)]
        )
        let m = PageModelBuilder.build(input)
        XCTAssertEqual(
            m.reportRows.map(\.source),
            [Source.uvCache.displayName, Source.homebrewDownloads.displayName]
        )
    }

    /// 全部来源都没有快照、也没有候选 ⇒ **无行**（不是 7 行空表）。
    func test_reportRowsEmptyWhenNoSourceHasCandidatesOrSnapshot() {
        let entries = Source.allCases.map { makeEntry($0) }
        let input = PageModelBuilder.Input(
            contents: makeContents(makeHeader(entries: entries))
        )
        let m = PageModelBuilder.build(input)
        XCTAssertTrue(m.reportRows.isEmpty, "无任何可报来源时不得渲染空行")
    }

    /// ★ 域外来源**不因快照占行** —— 它从不取快照，判定域语义不得外溢。
    func test_reportOnlySourceNeverOccupiesRowBySnapshotAlone() {
        // 全部七个来源都带快照（含三个域外来源）⇒ 只有四个判定域来源占行。
        let entries = Source.allCases.map {
            makeEntry($0, snapshot: true, T: 100, K: 90, J: 10, H: 30)
        }
        let input = PageModelBuilder.Input(
            contents: makeContents(makeHeader(entries: entries)),
            candidates: [makeCandidate(.uvCache)]
        )
        let m = PageModelBuilder.build(input)
        XCTAssertEqual(
            m.reportRows.map(\.source),
            [
                Source.uvCache.displayName,
                Source.npmNpx.displayName,
                Source.homebrewDownloads.displayName,
                Source.cargoRegistryCache.displayName,
            ]
        )
    }
}
