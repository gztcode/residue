import XCTest
@testable import ResidueCore

/// `PageModelBuilder` 测试：**真实状态 → 页面模型**。
///
/// 这一层是「界面禁止算术」的实际落点——所有聚合都在这里，
/// 页面拿到的只有 `SemanticSlot`。所以这里的断言就是那条约束的证据。
final class PageModelBuilderTests: XCTestCase {

    // MARK: - 构造输入

    private func makeHeader(
        round: Int = 2,
        countedDays: Int = 14,
        produced: Bool = true,
        autoDelete: Bool = false,
        lastScanAt: Date? = nil,
        entries: [SourceHeaderEntry]? = nil
    ) -> StateHeader {
        var h = StateHeader()
        h.round = round
        h.countedDays = countedDays
        h.countedDaysCap = 14
        h.autoDeleteEnabled = autoDelete
        h.lastScanAt = lastScanAt
        h.settlement = SettlementHeader(
            producedAt: produced ? Date(timeIntervalSince1970: 1_700_000_000) : nil,
            reportId: produced ? "r-1" : nil
        )
        h.sources = entries ?? Source.allCases.map {
            SourceHeaderEntry(
                source: $0, snapshotTaken: true,
                T: 100, K: 90, J: 10, H: 30,
                a: 0, b: 12, slotCount: 100, doneCount: 0
            )
        }
        return h
    }

    private func makeCandidate(
        path: String, bytes: Int64, source: Source
    ) -> ScanEngine.Candidate {
        ScanEngine.Candidate(
            path: path, birthtime: Date(timeIntervalSince1970: 0),
            bytes: bytes, isDirectory: false, source: source.rawValue
        )
    }

    private func makeContents(_ header: StateHeader) -> StateFileContents {
        var c = StateFileContents()
        c.header = header
        return c
    }

    // MARK: - 只读态：**不渲染任何数值**

    /// 只读态下，所有数值位必须是 `.unavailable`，**绝不能是 `.metric(0)`**。
    ///
    /// 显示 0 会让旧版把「错 1 次永久」显示成「一次都没错」——假值比空白更危险（R2 §10.2）。
    func testReadOnlyProducesNoNumericSlots() {
        let input = PageModelBuilder.Input(
            contents: makeContents(makeHeader()),
            candidates: [makeCandidate(path: "/a", bytes: 100, source: .uvCache)],
            readOnly: true
        )
        let m = PageModelBuilder.build(input)

        XCTAssertTrue(m.readOnly)
        XCTAssertEqual(m.pageLevelSlot?.displayText, UICopy.readOnlyNoSettlement)
        XCTAssertFalse(m.canLightUp, "只读态不得可点亮")
        XCTAssertFalse(m.canClearLogs, "只读态不得提供清除")
        XCTAssertEqual(m.remainingDays.displayText, "—", "只读态剩余天数必须是「—」不是 0")

        // ⑥ 待删规模也不得是数值
        XCTAssertTrue(m.confirmItemCount.isUnavailable)
        XCTAssertTrue(m.confirmBytes.isUnavailable)
    }

    /// 只读态的**空矩阵**：不渲染 reportRows（数值来自读不到的载体）。
    func testReadOnlyHasNoReportRows() {
        let input = PageModelBuilder.Input(
            contents: makeContents(makeHeader()),
            readOnly: true
        )
        let m = PageModelBuilder.build(input)
        XCTAssertTrue(m.reportRows.isEmpty, "只读态不得渲染矩阵行（读不到数值）")
        XCTAssertNil(m.previousRoundSlot, "只读态不得显示「上一轮」结算行")
    }

    // MARK: - ② 候选：判定域决定参与度

    /// **判定域内的来源 = 可参与自动删除；`pipx` run = 仅报告**（AC-04 ②）。
    func testParticipationFollowsDecisionDomain() {
        let input = PageModelBuilder.Input(
            contents: makeContents(makeHeader()),
            candidates: [
                makeCandidate(path: "/uv/a", bytes: 10, source: .uvCache),
                makeCandidate(path: "/npm/b", bytes: 20, source: .npmNpx),
                makeCandidate(path: "/pipx/c", bytes: 30, source: .pipxRun),
            ]
        )
        let m = PageModelBuilder.build(input)
        XCTAssertEqual(m.candidateRows.count, 3)
        XCTAssertEqual(m.candidateRows[0].participation, .autoDeletable)
        XCTAssertEqual(m.candidateRows[1].participation, .autoDeletable)
        XCTAssertEqual(m.candidateRows[2].participation, .reportOnly, "pipx run 不属判定域")
    }

    // MARK: - ⑥ 待删集：**只含可参与自动删除的候选**

    /// **待删集必须排除「仅报告」条目**（AC-04 ② / AC-09 ⑦）。
    ///
    /// 复必现曾靠「② 三行 180+64+52=296，⑥ 正好显示 296MB」判出
    /// 「疑似把仅报告条目计进了待删集」——那条虽然最终查明是占位数据不一致，
    /// 但**这个契约本身必须被断言住**，否则真接上数据时就会犯。
    func testConfirmExcludesReportOnlyCandidates() {
        let input = PageModelBuilder.Input(
            contents: makeContents(makeHeader()),
            candidates: [
                makeCandidate(path: "/uv/a", bytes: 180_000_000, source: .uvCache),
                makeCandidate(path: "/npm/b", bytes: 64_000_000, source: .npmNpx),
                makeCandidate(path: "/pipx/c", bytes: 52_000_000, source: .pipxRun),
            ]
        )
        let m = PageModelBuilder.build(input)

        XCTAssertEqual(m.confirmItemCount.displayText, "2条", "只算两个可参与自动删除的")
        // 244 MB = 180 + 64；**不含 pipx 的 52 MB**
        XCTAssertEqual(
            m.confirmBytes.displayText, MetricUnit.formatBytes(244_000_000),
            "待删字节不得包含「仅报告」的 52 MB"
        )
        XCTAssertNotEqual(
            m.confirmBytes.displayText, MetricUnit.formatBytes(296_000_000),
            "296 MB = 180+64+52，那是把仅报告条目算进来的错值"
        )
    }

    // MARK: - 门槛判定：**必须来自 GateEvaluator，不在此处重算**

    /// 样本不足（`K < H`）→ 不可点亮 + 未达项是**样本不足**。
    func testInsufficientSampleBlocksLightUp() {
        let entries = [
            SourceHeaderEntry(source: .uvCache, snapshotTaken: true,
                              T: 30, K: 27, J: 3, H: 30, a: 0, b: 12, slotCount: 30, doneCount: 0),
            SourceHeaderEntry(source: .npmNpx, snapshotTaken: true,
                              T: 30, K: 30, J: 0, H: 30, a: 0, b: 9, slotCount: 30, doneCount: 0),
        ]
        let input = PageModelBuilder.Input(
            contents: makeContents(makeHeader(entries: entries))
        )
        let m = PageModelBuilder.build(input)

        XCTAssertFalse(m.canLightUp, "K=27 < H=30 → 不可点亮")
        XCTAssertTrue(
            m.unmetNotice?.displayText.contains("样本不足") ?? false,
            "未达项必须是样本不足，实为「\(m.unmetNotice?.displayText ?? "nil")」"
        )
    }

    /// 三项全过 → 可点亮。
    func testQualifiedWhenAllThresholdsMet() {
        let entries = [
            SourceHeaderEntry(source: .uvCache, snapshotTaken: true,
                              T: 30, K: 30, J: 0, H: 30, a: 0, b: 5, slotCount: 30, doneCount: 0),
            SourceHeaderEntry(source: .npmNpx, snapshotTaken: true,
                              T: 30, K: 30, J: 0, H: 30, a: 0, b: 5, slotCount: 30, doneCount: 0),
        ]
        let input = PageModelBuilder.Input(
            contents: makeContents(makeHeader(entries: entries))
        )
        let m = PageModelBuilder.build(input)
        XCTAssertTrue(m.canLightUp, "K≥H ∧ a=0 ∧ b≥1 → 可点亮")
    }

    /// **`a ≠ 0` → 不可点亮**（L0 零容忍）。
    func testMissCountBlocksLightUp() {
        let entries = [
            SourceHeaderEntry(source: .uvCache, snapshotTaken: true,
                              T: 30, K: 30, J: 0, H: 30, a: 1, b: 5, slotCount: 30, doneCount: 1),
        ]
        let input = PageModelBuilder.Input(contents: makeContents(makeHeader(entries: entries)))
        let m = PageModelBuilder.build(input)
        XCTAssertFalse(m.canLightUp, "a=1 → 不可点亮（错 1 次永久）")
    }

    /// **空判定域 → 不可点亮**（全称量词在空集上恒真，必须显式排除）。
    func testEmptyDecisionDomainDoesNotQualify() {
        let input = PageModelBuilder.Input(contents: makeContents(makeHeader(entries: [])))
        let m = PageModelBuilder.build(input)
        XCTAssertFalse(m.canLightUp, "空判定域不得判为达标")
    }

    // MARK: - CR-032 · 5 来源下的判定域与行集合

    /// **没装的来源不得卡死门槛，也不得占 ⑤ 行**。
    ///
    /// `brew` 在用户机器上可能根本没装（无快照 / `T = nil` / `b = 0`）；
    /// `pip` 静态属仅报告。若它们进了门槛输入：
    /// 检查行取最差 `b = 0` → 直接失败 → 自动删除**永远点不亮**。
    func testAbsentSourcesDoNotBlockGateOrOccupyRows() {
        var entries = Source.allCases.map {
            SourceHeaderEntry(
                source: $0, snapshotTaken: true,
                T: 100, K: 90, J: 10, H: 30, a: 0, b: 12, slotCount: 100
            )
        }
        // brew 缺席；pip 缺席（仅报告且本轮没有任何候选）
        for (i, e) in entries.enumerated() where e.source == .brewCache || e.source == .pipCache {
            entries[i] = SourceHeaderEntry(source: e.source)
        }

        let m = PageModelBuilder.build(
            PageModelBuilder.Input(contents: makeContents(makeHeader(entries: entries)))
        )

        XCTAssertTrue(m.canLightUp, "缺席的 brew / pip 不得把门槛卡死")
        XCTAssertFalse(
            m.sampleProgress.contains { $0.sourceKey == Source.brewCache.rawValue },
            "T = 0 的来源不占 ⑤ 行"
        )
        XCTAssertFalse(
            m.sampleProgress.contains { $0.sourceKey == Source.pipCache.rawValue },
            "T = 0 的仅报告来源同样不占行"
        )
        // 其余三个来源（uv / npm）在域内 → 占行；pipx 默认 T = 100 → 也占行
        XCTAssertEqual(m.sampleProgress.count, 3)
    }

    /// **① 页显示的是本轮实际扫描的根，不是默认位置**（CR-032 · P2-6）。
    ///
    /// 用户用 `UV_CACHE_DIR` / `npm_config_cache` / `HOMEBREW_CACHE` 把缓存搬走后，
    /// `canonicalCachePath` 只是「默认位置」。照它显示 = 指着一个从没扫过的目录
    /// 说「它占了这么多」——数值是真的，路径是假的。
    func testSourceSharePathUsesActualScannedRoot() {
        var input = PageModelBuilder.Input(contents: makeContents(makeHeader()))
        input.sourceRoots = [
            Source.uvCache.rawValue: "/Volumes/ext/uv-cache",
            Source.brewCache.rawValue: "/Volumes/ext/brew-cache",
        ]
        let m = PageModelBuilder.build(input)

        let uv = m.sourceShares.first { $0.sourceKey == Source.uvCache.rawValue }
        XCTAssertEqual(uv?.path, "/Volumes/ext/uv-cache", "有实际根时必须显示它")
        XCTAssertNotEqual(uv?.path, Source.uvCache.canonicalCachePath,
                          "显示默认位置就是缺陷本身")

        let brew = m.sourceShares.first { $0.sourceKey == Source.brewCache.rawValue }
        XCTAssertEqual(brew?.path, "/Volumes/ext/brew-cache")

        // 没给实际根的来源仍回退默认位置（本轮扫的就是默认位置）
        let npm = m.sourceShares.first { $0.sourceKey == Source.npmNpx.rawValue }
        XCTAssertEqual(npm?.path, Source.npmNpx.canonicalCachePath)
    }

    /// 重启后（本会话未扫描）路径同样取实际根；缺项回退默认位置。
    ///
    /// 路径与「是否扫过」无关：搬家这件事一旦发生，默认位置就永远是错的。
    func testSourceSharePathKeepsActualRootAfterRestart() {
        var input = PageModelBuilder.Input(
            contents: makeContents(makeHeader()),
            hasSessionScan: false,
            lastScan: PageModelBuilder.LastScanSummary(
                at: Date(), bytes: 3_400_000_000, files: 100, sources: []
            )
        )
        input.sourceRoots = [Source.uvCache.rawValue: "/Volumes/ext/uv-cache"]
        let m = PageModelBuilder.build(input)

        let uv = m.sourceShares.first { $0.sourceKey == Source.uvCache.rawValue }
        XCTAssertEqual(uv?.path, "/Volumes/ext/uv-cache")
        XCTAssertEqual(uv?.bytes.displayText, "—", "字节仍未知")

        let npm = m.sourceShares.first { $0.sourceKey == Source.npmNpx.rawValue }
        XCTAssertEqual(npm?.path, Source.npmNpx.canonicalCachePath, "缺项回退默认位置")
    }

    /// **布局不认识 → 显示「无法判定」，不显示 0、不画占比**。
    func testUnrecognizedLayoutRendersUnavailableNotZero() {
        var input = PageModelBuilder.Input(contents: makeContents(makeHeader()))
        input.layoutUnrecognizedSources = [Source.pipCache.rawValue]
        let m = PageModelBuilder.build(input)

        let pip = m.sourceShares.first { $0.sourceKey == Source.pipCache.rawValue }
        XCTAssertEqual(pip?.bytes.displayText, UICopy.cacheLayoutUnrecognized)
        XCTAssertEqual(pip?.itemCount.displayText, UICopy.cacheLayoutUnrecognized)
        XCTAssertNil(pip?.share, "分母未知时不画占比")

        let uv = m.sourceShares.first { $0.sourceKey == Source.uvCache.rawValue }
        XCTAssertNotEqual(uv?.bytes.displayText, UICopy.cacheLayoutUnrecognized,
                          "未标记的条目字节不受影响")
    }

    /// **有来源布局未识别 → 总扫描量「无法判定」，不报确定值**（CR-032 · P2-3）。
    ///
    /// 未识别的来源扫不出候选，它的字节压根不在总量里。此时报一个确定的总量，
    /// 等于把「没看见」说成「没有」——正是「不把未知判为安全」禁止的。
    func testUnrecognizedLayoutMakesTotalUnavailable() {
        var input = PageModelBuilder.Input(contents: makeContents(makeHeader()))
        input.layoutUnrecognizedSources = [Source.pipCache.rawValue]
        let m = PageModelBuilder.build(input)

        XCTAssertEqual(
            m.totalScannedSlot.displayText,
            UICopy.cacheLayoutUnrecognized,
            "总量里缺了一块，就不能报成确定值"
        )
        XCTAssertEqual(m.totalScannedSlot, .unavailable(reason: UICopy.cacheLayoutUnrecognized))
    }

    /// **总量不可判定 → 所有来源的占比都不给**（含已识别的来源）。
    ///
    /// 分母残缺时算出的百分比是假精度：uv 占「已看见部分的 100%」会被读成「占全部」。
    func testUnrecognizedLayoutSuppressesAllShares() {
        var input = PageModelBuilder.Input(contents: makeContents(makeHeader()))
        input.layoutUnrecognizedSources = [Source.brewCache.rawValue]
        input.candidates = [
            ScanEngine.Candidate(
                path: "/tmp/uv-1", birthtime: Date(timeIntervalSince1970: 1),
                bytes: 100, isDirectory: false, source: Source.uvCache.rawValue
            )
        ]
        let m = PageModelBuilder.build(input)

        XCTAssertTrue(
            m.sourceShares.allSatisfy { $0.share == nil },
            "分母残缺时任何来源都不画占比"
        )
        XCTAssertTrue(
            m.candidateRows.allSatisfy { $0.share == nil },
            "② 候选行的占比同源，同样不给"
        )
    }

    /// **全部来源布局都能识别 → 总量与占比照常给**（回归：别把正常路径也压成「无法判定」）。
    func testRecognizedLayoutKeepsTotalAndShares() {
        var input = PageModelBuilder.Input(contents: makeContents(makeHeader()))
        input.candidates = [
            ScanEngine.Candidate(
                path: "/tmp/uv-1", birthtime: Date(timeIntervalSince1970: 1),
                bytes: 100, isDirectory: false, source: Source.uvCache.rawValue
            ),
            ScanEngine.Candidate(
                path: "/tmp/npm-1", birthtime: Date(timeIntervalSince1970: 2),
                bytes: 300, isDirectory: false, source: Source.npmNpx.rawValue
            ),
        ]
        let m = PageModelBuilder.build(input)

        XCTAssertEqual(m.totalScannedSlot, .metric(400, unit: .bytes))
        let uv = m.sourceShares.first { $0.sourceKey == Source.uvCache.rawValue }
        XCTAssertEqual(uv?.share?.numerator, 100)
        XCTAssertEqual(uv?.share?.denominator, 400)
    }

    // MARK: - ⑤ 矩阵：报告未产出时的取值

    /// **报告未产出**：③ 取「本轮未结算」、⑦ 取「本轮未结算」，
    /// 但 **⑥ 右值 `b` 照常填**（M4：只有左值取未结算）。
    func testNotSettledKeepsBCounted() {
        let entries = [
            SourceHeaderEntry(source: .uvCache, snapshotTaken: true,
                              T: 30, K: nil, J: nil, H: 30, a: 0, b: 7, slotCount: 30, doneCount: 0),
        ]
        let input = PageModelBuilder.Input(
            contents: makeContents(makeHeader(countedDays: 5, produced: false, entries: entries))
        )
        let m = PageModelBuilder.build(input)
        let row = m.reportRows[0]

        // ③ 样本 / 总量
        XCTAssertEqual(row.cells[2][0].displayText, UICopy.notSettledThisRound)
        // ④ 门槛：产出前 `H` 只是**待验门槛**，不是结算值（CR-033 / R-4）
        XCTAssertEqual(
            row.cells[3][0].displayText, UICopy.notSettledThisRound,
            "产出前显示 H 会被读成「已经按这个门槛判过了」"
        )
        // ⑥ 左值（a）
        XCTAssertEqual(row.cells[5][0].displayText, UICopy.notSettledThisRound)
        // ⑥ 右值（b）**照常填**
        XCTAssertEqual(row.cells[5][1].displayText, "7次", "b 在报告产出前照常填实际值")
        // ⑦ 结论
        XCTAssertEqual(row.cells[6][0].displayText, UICopy.notSettledThisRound)
    }

    /// **非判定域行的 ④ 不随「报告是否产出」变**（CR-033 / M-9 与 R-4 的边界）。
    ///
    /// 该行不参与门槛判定 —— 产出前也照样说「不适用（不入判定域）」，
    /// 不能因为「未结算」就把一句恒真的说明改成临时状态。
    func testReportOnlyRowThresholdIgnoresProducedFlag() {
        let entries = [
            SourceHeaderEntry(source: .pipxRun, snapshotTaken: true,
                              T: 5, K: nil, J: nil, H: 5, a: 0, b: 3, slotCount: 5, doneCount: 0),
        ]
        let input = PageModelBuilder.Input(
            contents: makeContents(makeHeader(countedDays: 5, produced: false, entries: entries))
        )
        let m = PageModelBuilder.build(input)

        XCTAssertEqual(m.reportRows[0].cells[3][0].displayText, UICopy.notInDecisionDomain)
    }

    /// **`pipx` 行：④ / ⑥ 逐字取 PRD AC-09**（CR-033 / M-9）。
    ///
    /// ④ 只写「不适用」读者分不清「不参与判定」与「门槛算出来是 0」；
    /// ⑥ 填 `0 / 0` 会被读成「检查了 0 次、误判 0 次 = 干净」——把未知说成安全。
    func testReportOnlySourceRow() {
        let entries = [
            SourceHeaderEntry(source: .pipxRun, snapshotTaken: true,
                              T: 5, K: 5, J: 0, H: 5, a: 0, b: 1, slotCount: 5, doneCount: 0),
        ]
        let input = PageModelBuilder.Input(contents: makeContents(makeHeader(entries: entries)))
        let m = PageModelBuilder.build(input)
        let row = m.reportRows[0]

        XCTAssertEqual(row.cells[1][0].displayText, "仅报告")
        XCTAssertEqual(row.cells[3][0].displayText, UICopy.notInDecisionDomain)
        XCTAssertEqual(row.cells[3][0].displayText, "不适用（不入判定域）")
        XCTAssertEqual(row.cells[6][0].displayText, "仅报告")
    }

    /// **非判定域行 ⑥ 是「整格一句」，不是两个数值**（CR-033 / M-9）。
    ///
    /// 该行从未执行 L0 检查 → 没有 `a` / `b` 可填。整格只留一个槽位，
    /// 视图据此按整列宽渲染（拆成两个 62 pt 子格会把句子截断）。
    func testReportOnlySourceRowHasSingleL0Slot() {
        let entries = [
            SourceHeaderEntry(source: .pipxRun, snapshotTaken: true,
                              T: 5, K: 5, J: 0, H: 5, a: 0, b: 1, slotCount: 5, doneCount: 0),
            SourceHeaderEntry(source: .pipCache, snapshotTaken: true,
                              T: 5, K: 5, J: 0, H: 5, a: 0, b: 1, slotCount: 5, doneCount: 0),
        ]
        let input = PageModelBuilder.Input(contents: makeContents(makeHeader(entries: entries)))
        let m = PageModelBuilder.build(input)

        for row in m.reportRows {
            XCTAssertEqual(row.cells[5].count, 1, "⑥ 整格一句，不拆左右值")
            XCTAssertEqual(row.cells[5][0].displayText, UICopy.l0NotChecked)
            XCTAssertEqual(row.cells[5][0].displayText, "不适用 · 未执行 L0 检查")
        }
    }

    /// **非判定域行 ③ = 扫描时点值 + 标注**（CR-033 · R-2）。
    ///
    /// 该行不取快照、`K` / `J` 无语义 → 不能套 `K / T`，也不套 `K + J = T`；
    /// 取本窗扫描到的条目数，并在同一格标注「扫描时点值 · 非结算值」。
    func testReportOnlyRowSampleCarriesScanTimeAnnotation() {
        let entries = [
            SourceHeaderEntry(source: .pipxRun, snapshotTaken: false,
                              T: nil, K: nil, J: nil, H: nil, a: 0, b: 0,
                              slotCount: 4, doneCount: 0),
        ]
        let input = PageModelBuilder.Input(contents: makeContents(makeHeader(entries: entries)))
        let m = PageModelBuilder.build(input)
        let row = m.reportRows[0]

        XCTAssertEqual(row.cells[2].count, 2, "③ 两槽位：扫描值 + 标注")
        XCTAssertEqual(row.cells[2][0].displayText, "4条", "取本窗扫描到的条目数")
        XCTAssertEqual(row.cells[2][1].displayText, UICopy.scanTimeNonSettled)
        XCTAssertEqual(row.cells[2][1].displayText, "扫描时点值 · 非结算值")
    }

    /// **判定域行 ③ 不受标注影响**（回归）。
    func testInDomainRowSampleHasNoScanTimeAnnotation() {
        let m = PageModelBuilder.build(
            PageModelBuilder.Input(contents: makeContents(makeHeader()))
        )
        let row = m.reportRows[0]

        XCTAssertEqual(row.cells[2].count, 1)
        XCTAssertNotEqual(row.cells[2][0].displayText, UICopy.scanTimeNonSettled)
    }

    /// **判定域行 ⑥ 仍是两个数值**（回归：别把整句套到判定域行上）。
    func testInDomainRowKeepsTwoL0Slots() {
        let entries = [
            SourceHeaderEntry(source: .uvCache, snapshotTaken: true,
                              T: 30, K: 30, J: 0, H: 30, a: 0, b: 7, slotCount: 30, doneCount: 0),
        ]
        let input = PageModelBuilder.Input(contents: makeContents(makeHeader(entries: entries)))
        let m = PageModelBuilder.build(input)
        let row = m.reportRows[0]

        XCTAssertEqual(row.cells[5].count, 2)
        XCTAssertEqual(row.cells[5][0].displayText, "0次")
        XCTAssertEqual(row.cells[5][1].displayText, "7次")
        XCTAssertEqual(row.cells[3][0].displayText, "30", "判定域行 ④ 仍取 H")
    }

    /// **「上一轮」行只在轮次 ≥ 2 时出现**（首轮不显示，不是显示「—」）。
    func testPreviousRoundOnlyFromRoundTwo() {
        let r1 = PageModelBuilder.build(
            PageModelBuilder.Input(contents: makeContents(makeHeader(round: 1)))
        )
        XCTAssertNil(r1.previousRoundSlot, "首轮不得有「上一轮」行")

        let r2 = PageModelBuilder.build(
            PageModelBuilder.Input(contents: makeContents(makeHeader(round: 2)))
        )
        XCTAssertNotNil(r2.previousRoundSlot)
        XCTAssertTrue(r2.previousRoundSlot?.displayText.hasPrefix("第 1 轮 · ") ?? false,
                      "必须是前置数字式（三处同构）")
    }

    // MARK: - ⑦ 执行记录标签

    /// 三个动作映射到三个标签，且 **`restoredByUser` 是「已恢复」不是「可恢复」**。
    func testExecutionLabels() {
        let base = CandidateID(path: "/x", birthtime: Date(timeIntervalSince1970: 0))
        func rec(_ a: ExecutionAction) -> ExecutionRecord {
            ExecutionRecord(
                id: base, source: .uvCache, action: a,
                originalPath: "/x", restorePath: "/trash/x",
                executedAt: Date(timeIntervalSince1970: 0),
                bytes: 1, bytesKind: .file, blockedReason: nil
            )
        }
        let input = PageModelBuilder.Input(
            contents: makeContents(makeHeader()),
            executions: [rec(.renameToTrash), rec(.restoredByUser), rec(.blockedCap)]
        )
        let m = PageModelBuilder.build(input)
        XCTAssertEqual(m.evidenceRows.map(\.label.text), ["可恢复", "已恢复", "已阻断"])
    }

    // MARK: - ① 来源区块聚合

    /// 每来源区块的字节 = **该来源候选字节之和**（聚合在 Core，界面不参与）。
    func testOverviewBlocksAggregatePerSource() {
        let input = PageModelBuilder.Input(
            contents: makeContents(makeHeader()),
            candidates: [
                makeCandidate(path: "/uv/a", bytes: 1_000_000, source: .uvCache),
                makeCandidate(path: "/uv/b", bytes: 2_000_000, source: .uvCache),
                makeCandidate(path: "/npm/c", bytes: 3_000_000, source: .npmNpx),
            ]
        )
        let m = PageModelBuilder.build(input)
        XCTAssertEqual(m.overviewBlocks.count, Source.allCases.count,
                       "区块数 = Source.allCases（CR-032 起为 5 个）")
        XCTAssertEqual(m.overviewBlocks[0].slot.displayText, MetricUnit.formatBytes(3_000_000))
        XCTAssertEqual(m.overviewBlocks[1].slot.displayText, MetricUnit.formatBytes(3_000_000))
        XCTAssertEqual(m.overviewBlocks[2].slot.displayText, MetricUnit.formatBytes(0))
    }

    // MARK: - 重启后：未知不是 0

    /// 重启后（本会话未扫描）+ 能读到上次扫描的汇总：
    /// **总量如实展示**（上次扫描的观测值），逐来源 / 候选 / 可释放量一律「—」。
    ///
    /// 这条是「重启后 0 KB」缺陷的回归测试：候选清单不落盘，重启后若照常聚合，
    /// ① 页会显示 `0 B`、⑥ 页会显示 `0 条` —— 那些是「没有数据」，不是观测值。
    func testRestartWithLastScanShowsTotalAndDashes() {
        let scannedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let last = PageModelBuilder.LastScanSummary(
            at: scannedAt,
            bytes: 3_400_000_000,
            files: 12_345,
            sources: Source.allCases.map(\.rawValue)
        )
        let m = PageModelBuilder.build(
            PageModelBuilder.Input(
                contents: makeContents(makeHeader(lastScanAt: scannedAt)),
                hasSessionScan: false,
                lastScan: last
            )
        )

        XCTAssertTrue(m.hasScanned, "有上次扫描的汇总 → 不该显示「还没有扫描过」")
        XCTAssertTrue(m.restoredFromLastScan)
        XCTAssertFalse(m.hasLiveScan, "本会话没扫过 → 不可执行批次")
        XCTAssertEqual(m.lastScanNotice, UICopy.lastScanRestoredNotice)

        // 总量 = 上次扫描的真实观测值
        XCTAssertEqual(m.totalScannedSlot.displayText, MetricUnit.formatBytes(3_400_000_000))

        // 逐来源 / 可释放 / 批次：全部「—」，不是 0
        XCTAssertEqual(m.sourceShares.count, Source.allCases.count)
        for row in m.sourceShares {
            XCTAssertEqual(row.bytes.displayText, "—", "来源「\(row.displayName)」的字节未知")
            XCTAssertEqual(row.itemCount.displayText, "—")
            XCTAssertNil(row.share, "分母未知时不画占比")
        }
        XCTAssertEqual(m.overviewBlocks.count, Source.allCases.count)
        XCTAssertEqual(m.overviewBlocks[0].slot.displayText, "—")
        XCTAssertEqual(m.l1Confirmed.displayText, "—")
        XCTAssertEqual(m.l2Inferred.displayText, "—")
        XCTAssertEqual(m.deletableAmount.displayText, "—")
        XCTAssertEqual(m.confirmItemCount.displayText, "—")
        XCTAssertEqual(m.confirmBytes.displayText, "—")
        XCTAssertEqual(m.deferredCountSlot.displayText, "—")
        XCTAssertTrue(m.confirmRows.isEmpty)
        XCTAssertNil(m.reclaimableShare)
        XCTAssertTrue(m.candidateRows.isEmpty)
        XCTAssertEqual(m.pageIndicatorSlot.displayText, "—")
    }

    /// 重启后、上次扫描的汇总也读不到（例如日志被「一键清除」）：
    /// **连总量都不显示** —— 显示 0 会被读成「缓存是空的」。
    func testRestartWithoutSummaryShowsDashes() {
        let scannedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let m = PageModelBuilder.build(
            PageModelBuilder.Input(
                contents: makeContents(makeHeader(lastScanAt: scannedAt)),
                hasSessionScan: false
            )
        )

        XCTAssertTrue(m.hasScanned, "载体里有上次扫描时刻 → 不是「从未扫描」")
        XCTAssertTrue(m.restoredFromLastScan)
        XCTAssertEqual(m.totalScannedSlot.displayText, "—")
        XCTAssertEqual(m.lastScanNotice, UICopy.lastScanSummaryUnavailable)
        XCTAssertEqual(m.deletableAmount.displayText, "—")
    }

    /// 从未扫描：没有「上次扫描」，页面走空态；数值位仍是「—」而不是 0。
    func testNeverScannedHasNoNumbers() {
        let m = PageModelBuilder.build(
            PageModelBuilder.Input(
                contents: makeContents(makeHeader()),
                hasSessionScan: false
            )
        )

        XCTAssertFalse(m.hasScanned)
        XCTAssertFalse(m.restoredFromLastScan)
        XCTAssertNil(m.lastScanNotice, "从未扫描不需要「上次扫描」说明")
        XCTAssertEqual(m.totalScannedSlot.displayText, "—")
        XCTAssertEqual(m.deletableAmount.displayText, "—")
    }

    /// 本会话扫描过：照常聚合，重启逻辑**不得覆盖**真实数值。
    func testSessionScanKeepsAggregates() {
        let scannedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let m = PageModelBuilder.build(
            PageModelBuilder.Input(
                contents: makeContents(makeHeader(lastScanAt: scannedAt)),
                candidates: [
                    makeCandidate(path: "/uv/a", bytes: 1_000_000, source: .uvCache),
                    makeCandidate(path: "/npm/b", bytes: 2_000_000, source: .npmNpx),
                ],
                hasSessionScan: true,
                lastScan: PageModelBuilder.LastScanSummary(
                    at: scannedAt, bytes: 999, files: 1, sources: []
                )
            )
        )

        XCTAssertTrue(m.hasLiveScan)
        XCTAssertNil(m.lastScanNotice)
        XCTAssertFalse(m.restoredFromLastScan)
        XCTAssertEqual(m.totalScannedSlot.displayText, MetricUnit.formatBytes(3_000_000))
        XCTAssertEqual(m.deletableAmount.displayText, "2条")
    }

    /// **分页上限 200**（ADR-01：分页是渲染正确性）。
    func testPageSizeIsTwoHundred() {
        XCTAssertEqual(PageModelBuilder.pageSize, 200)
        let many = (0..<450).map {
            makeCandidate(path: "/uv/\($0)", bytes: 1, source: .uvCache)
        }
        let m = PageModelBuilder.build(
            PageModelBuilder.Input(contents: makeContents(makeHeader()), candidates: many)
        )
        XCTAssertEqual(m.candidateRows.count, 200, "单页最多 200 行")
        XCTAssertEqual(m.pageCount, 3, "450 条 → 3 页")
    }

    // ======================================================================
    // MARK: - R1.5 补落点（AC-10 / 11 / 14 / 15 / 18 / 19）
    // ======================================================================

    /// **④ 页四档齐、且后两档默认关**（AC-11 分层默认）。
    func testCollectionTiersDefault() {
        let m = PageModelBuilder.build(
            PageModelBuilder.Input(contents: makeContents(makeHeader()))
        )
        XCTAssertEqual(m.collectionTiers.count, 4, "四档采集")
        XCTAssertEqual(m.collectionTiers[0].authorized, true)
        XCTAssertEqual(m.collectionTiers[1].authorized, true)
        XCTAssertEqual(m.collectionTiers[2].authorized, false, "构建产物默认关")
        XCTAssertEqual(m.collectionTiers[3].authorized, false, "会话痕迹默认关")
        XCTAssertEqual(m.collectionTiers[2].state.displayText, "未采集")
    }

    /// **采集被停 → 已授权档显示「已停止」**（AC-10 的 P4 状态位）。
    func testCollectionStoppedState() {
        let m = PageModelBuilder.build(
            PageModelBuilder.Input(
                contents: makeContents(makeHeader()),
                // AC-10 的 When：**曾启用过、现在关闭**
                autoDeleteEnabled: false,
                autoDeleteEverEnabled: true
            )
        )
        XCTAssertEqual(m.collectionTiers[0].state.displayText, "已停止")
    }

    /// **L0 枚举失败 → 四档给「所缺权限 + 授权指引条目 ID」**（AC-14 三要素）。
    func testDegradedGivesPermissionTriple() {
        let m = PageModelBuilder.build(
            PageModelBuilder.Input(contents: makeContents(makeHeader()), degraded: true)
        )
        let slot = m.collectionTiers[0].state
        XCTAssertTrue(slot.isPermissionBlocked)
        let text = slot.displayText
        XCTAssertTrue(text.contains("所缺"), "必须给「所缺权限」，实为「\(text)」")
        XCTAssertTrue(text.contains("E-501"), "必须给授权指引条目 ID，实为「\(text)」")
    }

    /// **举证链必须是 8 个字段**（AC-18：分母 = V4 的 8 个顶层字段）。
    func testEvidenceFieldsCountIsEight() {
        let m = PageModelBuilder.build(
            PageModelBuilder.Input(contents: makeContents(makeHeader()))
        )
        XCTAssertEqual(m.evidenceFields.count, 8, "V4 八顶层字段")
        // **没有值时必须「不适用 + 原因」，不能是空串**
        for (name, slot) in m.evidenceFields {
            XCTAssertFalse(
                slot.displayText.isEmpty,
                "字段「\(name)」不得为空（AC-18：无空白、无「以后再补」）"
            )
        }
    }

    /// **上游命令按「命令 + 参数」聚合计数**（AC-19 的界面落点）。
    func testUpstreamCommandCounts() {
        let cmd = UpstreamCommand(
            cmd: "uv", args: ["cache", "dir"], exitCode: 0, durationMs: 5,
            invokedAt: Date(timeIntervalSince1970: 0)
        )
        let forbidden = UpstreamCommand(
            cmd: "uv", args: ["cache", "clean"], exitCode: nil, durationMs: 0,
            invokedAt: Date(timeIntervalSince1970: 0),
            rejectedByWhitelist: true, failure: "拒绝"
        )
        let m = PageModelBuilder.build(
            PageModelBuilder.Input(
                contents: makeContents(makeHeader()),
                upstreamCommands: [cmd, cmd, forbidden]
            )
        )
        let dict = Dictionary(uniqueKeysWithValues: m.upstreamCommands.map { ($0.command, $0) })
        XCTAssertEqual(dict["uv cache dir"]?.invoked.displayText, "2次", "同一命令调用两次应聚合为 2")
        XCTAssertEqual(dict["uv cache dir"]?.executed.displayText, "2次", "两次都真执行了")
        // **关键**：被白名单拒掉的命令 —— 调用 1 次、**执行 0 次**
        XCTAssertEqual(dict["uv cache clean"]?.invoked.displayText, "1次", "尝试调用记 1 次")
        XCTAssertEqual(
            dict["uv cache clean"]?.executed.displayText, "0次",
            "被拒的调用**不得**计入执行 —— 否则「我们拦住了」会看起来像「违规了」"
        )
    }

    /// **② 页标签值域必须保持 2 值**（AC-04 判定冻结）。
    ///
    /// 这条防的是「为了表达阻断态而给标签加值」——那会直接违反 AC-04：
    /// 「每行带标签且取值 ∈ {可参与自动删除 / 仅报告}」。
    func testCandidateLabelDomainStaysTwoValues() {
        let m = PageModelBuilder.build(
            PageModelBuilder.Input(
                contents: makeContents(makeHeader()),
                candidates: [
                    makeCandidate(path: "/uv/a", bytes: 1, source: .uvCache),
                    makeCandidate(path: "/pipx/c", bytes: 1, source: .pipxRun),
                ]
            )
        )
        let labels = Set(m.candidateRows.map { $0.participation.label })
        XCTAssertEqual(
            labels, ["可参与自动删除", "仅报告"],
            "标签只能有这两个值（AC-04 判定冻结）；阻断原因须走 blockReason 副行"
        )
    }

    /// **⑥ 页顺延条目数存在**（AC-15 三项约束之一）。
    func testDeferredCountSlotExists() {
        let m = PageModelBuilder.build(
            PageModelBuilder.Input(contents: makeContents(makeHeader()))
        )
        XCTAssertFalse(m.deferredCountSlot.displayText.isEmpty)
    }

    // MARK: - 视觉基线 v2（CR-031）

    /// ① 页来源占比：**分子分母都在 Core 算好**，视图只拿 `RatioSlot`。
    func testSourceSharesArePrecomputed() {
        let m = PageModelBuilder.build(
            PageModelBuilder.Input(
                contents: makeContents(makeHeader()),
                candidates: [
                    makeCandidate(path: "/uv/a", bytes: 600, source: .uvCache),
                    makeCandidate(path: "/uv/b", bytes: 200, source: .uvCache),
                    makeCandidate(path: "/npm/c", bytes: 200, source: .npmNpx),
                ]
            )
        )

        XCTAssertEqual(m.totalScannedSlot.displayText, MetricUnit.formatBytes(1000))

        let uv = m.sourceShares.first { $0.sourceKey == Source.uvCache.rawValue }
        XCTAssertEqual(uv?.itemCount.displayText, "2条")
        XCTAssertEqual(uv?.bytes.displayText, MetricUnit.formatBytes(800))
        XCTAssertEqual(uv?.share?.percentTenths, 800)
        XCTAssertEqual(uv?.inDecisionDomain, true)

        let pipx = m.sourceShares.first { $0.sourceKey == Source.pipxRun.rawValue }
        XCTAssertEqual(pipx?.itemCount.displayText, "0条")
        XCTAssertEqual(pipx?.share?.fraction, 0, "真的没有占用 = 0，不是 nil")
        XCTAssertEqual(pipx?.inDecisionDomain, false)
    }

    /// 总量为 0 时，占比必须是 `nil`（**未知不等于 0**）。
    func testSourceShareIsNilWhenTotalIsZero() {
        let m = PageModelBuilder.build(
            PageModelBuilder.Input(contents: makeContents(makeHeader()))
        )
        XCTAssertTrue(m.sourceShares.allSatisfy { $0.share == nil })
        XCTAssertNil(m.reclaimableShare)
    }

    /// 可释放占比 = 可删除字节 / 全量扫描字节。
    func testReclaimableShareUsesDeletableBytes() {
        let m = PageModelBuilder.build(
            PageModelBuilder.Input(
                contents: makeContents(makeHeader()),
                candidates: [
                    makeCandidate(path: "/uv/a", bytes: 300, source: .uvCache),
                    makeCandidate(path: "/pipx/b", bytes: 100, source: .pipxRun),
                ]
            )
        )
        // 可删除只含判定域（uv 300），总量 400 → 75.0%
        XCTAssertEqual(m.reclaimableShare?.percentTenths, 750)
    }

    /// 观察期比例与「x / 14 天」文案**同源**。
    func testObservationProgressIsRatioSlot() {
        let m = PageModelBuilder.build(
            PageModelBuilder.Input(
                contents: makeContents(makeHeader(countedDays: 7, produced: false))
            )
        )
        XCTAssertEqual(m.observationRatio?.numerator, 7)
        XCTAssertEqual(m.observationRatio?.denominator, 14)
        XCTAssertEqual(m.observationDaySlot.displayText, "7 / 14")
    }

    /// 门槛清单与 `canLightUp` **必须同源**：清单全过 ⇔ 可点亮。
    func testGateChecklistAgreesWithCanLightUp() {
        let qualified = PageModelBuilder.build(
            PageModelBuilder.Input(contents: makeContents(makeHeader()))
        )
        XCTAssertTrue(qualified.canLightUp)
        XCTAssertTrue(qualified.gateChecks.allSatisfy { $0.passed == true })
        XCTAssertEqual(qualified.gateChecks.count, 6)

        var failing = makeHeader()
        failing.sources[0].K = 5   // 样本不足
        let blocked = PageModelBuilder.build(
            PageModelBuilder.Input(contents: makeContents(failing))
        )
        XCTAssertFalse(blocked.canLightUp)
        let sample = blocked.gateChecks.first { $0.kind == .sample }
        XCTAssertEqual(sample?.passed, false)
    }

    /// 未判定（`a` / `b` 都为 nil）的检查项是 `nil`，**不是 `false`**。
    func testUndeterminedGateCheckIsNilNotFalse() {
        var h = makeHeader()
        h.sources[0].K = nil
        h.sources[0].a = 0
        h.sources[0].b = 0
        let m = PageModelBuilder.build(
            PageModelBuilder.Input(contents: makeContents(h))
        )
        let misses = m.gateChecks.first { $0.kind == .misses }
        XCTAssertNil(misses?.passed, "「无法判定」不得显示成「未通过」")
        XCTAssertFalse(m.canLightUp)
    }

    /// ⑥ 页预览清单：**只含判定域内候选**，且带来源键与占比。
    func testConfirmRowsExcludeReportOnlySources() {
        let m = PageModelBuilder.build(
            PageModelBuilder.Input(
                contents: makeContents(makeHeader()),
                candidates: [
                    makeCandidate(path: "/uv/a", bytes: 300, source: .uvCache),
                    makeCandidate(path: "/pipx/b", bytes: 100, source: .pipxRun),
                ]
            )
        )
        XCTAssertEqual(m.confirmRows.map { $0.path }, ["/uv/a"])
        XCTAssertEqual(m.confirmRows.first?.sourceKey, Source.uvCache.rawValue)
        XCTAssertEqual(m.confirmRows.first?.share?.percentTenths, 750)
    }

    /// 只读态：**新增字段一个数值都不许露**（否则旧版本会显示假值）。
    func testReadOnlyHidesAllNewNumericFields() {
        let m = PageModelBuilder.build(
            PageModelBuilder.Input(
                contents: makeContents(makeHeader()),
                candidates: [makeCandidate(path: "/uv/a", bytes: 300, source: .uvCache)],
                readOnly: true
            )
        )
        XCTAssertTrue(m.sourceShares.isEmpty)
        XCTAssertTrue(m.gateChecks.isEmpty)
        XCTAssertTrue(m.confirmRows.isEmpty)
        XCTAssertTrue(m.sampleProgress.isEmpty)
        XCTAssertNil(m.reclaimableShare)
        XCTAssertNil(m.observationRatio)
        XCTAssertEqual(m.totalScannedSlot, .unavailable(reason: UICopy.readOnlyNoSettlement))
        XCTAssertEqual(m.observationDaySlot, .unavailable(reason: UICopy.readOnlyNoSettlement))
    }

    /// ⑤ 页逐来源样本进度：分子 = min(K, H)，分母 = H。
    func testSampleProgressCapsAtThreshold() {
        var h = makeHeader()
        h.sources[0].K = 90   // H = 30 → 封顶 100%
        h.sources[1].K = 15   // H = 30 → 50%
        let m = PageModelBuilder.build(
            PageModelBuilder.Input(contents: makeContents(h))
        )
        let uv = m.sampleProgress.first { $0.sourceKey == Source.uvCache.rawValue }
        let npm = m.sampleProgress.first { $0.sourceKey == Source.npmNpx.rawValue }
        XCTAssertEqual(uv?.ratio?.percentTenths, 1000)
        XCTAssertEqual(npm?.ratio?.percentTenths, 500)
    }
}
