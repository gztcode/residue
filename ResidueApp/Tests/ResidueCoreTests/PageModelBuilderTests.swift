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
        entries: [SourceHeaderEntry]? = nil
    ) -> StateHeader {
        var h = StateHeader()
        h.round = round
        h.countedDays = countedDays
        h.countedDaysCap = 14
        h.autoDeleteEnabled = autoDelete
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
        // ⑥ 左值（a）
        XCTAssertEqual(row.cells[5][0].displayText, UICopy.notSettledThisRound)
        // ⑥ 右值（b）**照常填**
        XCTAssertEqual(row.cells[5][1].displayText, "7次", "b 在报告产出前照常填实际值")
        // ⑦ 结论
        XCTAssertEqual(row.cells[6][0].displayText, UICopy.notSettledThisRound)
    }

    /// **`pipx` 行恒「仅报告」**，门槛取「不适用」。
    func testReportOnlySourceRow() {
        let entries = [
            SourceHeaderEntry(source: .pipxRun, snapshotTaken: true,
                              T: 5, K: 5, J: 0, H: 5, a: 0, b: 1, slotCount: 5, doneCount: 0),
        ]
        let input = PageModelBuilder.Input(contents: makeContents(makeHeader(entries: entries)))
        let m = PageModelBuilder.build(input)
        let row = m.reportRows[0]

        XCTAssertEqual(row.cells[1][0].displayText, "仅报告")
        XCTAssertEqual(row.cells[3][0].displayText, "不适用")
        XCTAssertEqual(row.cells[6][0].displayText, "仅报告")
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

    // MARK: - ① 三区块聚合

    /// 三区块的字节 = **该来源候选字节之和**（聚合在 Core，界面不参与）。
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
        XCTAssertEqual(m.overviewBlocks.count, 3, "三区块 = Source.allCases 三个")
        XCTAssertEqual(m.overviewBlocks[0].slot.displayText, MetricUnit.formatBytes(3_000_000))
        XCTAssertEqual(m.overviewBlocks[1].slot.displayText, MetricUnit.formatBytes(3_000_000))
        XCTAssertEqual(m.overviewBlocks[2].slot.displayText, MetricUnit.formatBytes(0))
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

}
