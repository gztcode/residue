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
        entries: [SourceHeaderEntry]? = nil,
        previousRound: PreviousRoundRecord? = nil
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
        h.previousRound = previousRound
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

    /// 造一个**本地日历日**的时刻（与 `SemanticSlotTests` 同法）。
    ///
    /// 用 `.current` 日历 ⇒ 断言与运行机器的时区无关：
    /// 「当天零点」在哪个时区都是「当天」。
    private func localDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// 提取一行展示串里的**全部 ASCII 数字**（按出现顺序）。
    ///
    /// 用于「行内数字恰 N 个」这类断言（TC-038）——
    /// 这是**对成品串的检查**，不是生产逻辑的第二份实现。
    ///
    /// ⚠️ **只认 ASCII 数字**：Swift 的 `Character.isNumber` 对中文数字字形
    /// （如「一」= U+4E00）同样为 `true`，而 `Int("一")` 是 `nil` ——
    /// 不限定 ASCII 就会在「下一轮」上崩掉。
    /// 契约说的「数字」= 基数形态里的那四个 ASCII 数（11 / 12 / 12 / 1）。
    private func digits(in text: String) -> [Int] {
        var out: [Int] = []
        var current = ""
        for ch in text {
            if ch.isASCII, ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                out.append(Int(current)!)
                current = ""
            }
        }
        if !current.isEmpty { out.append(Int(current)!) }
        return out
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

    // MARK: - 登录项动作投影（ADR-02 四态）

    /// `.notRegistered` → `canRegisterLoginItem`，且**只读态也如实投影**。
    ///
    /// 只读不等于可以假装定时任务在跑——登录项状态是系统真相，
    /// 与「载体能不能结算」是两件事，所以这条不走 `canClearLogs = false` 那条路。
    func testCanRegisterLoginItemProjectedinBothModes() {
        // 正常态
        let normal = PageModelBuilder.build(
            PageModelBuilder.Input(
                contents: makeContents(makeHeader()),
                loginItem: .notRegistered
            )
        )
        XCTAssertTrue(normal.canRegisterLoginItem, ".notRegistered 必须给注册入口")

        // 只读态：仍然如实投影（只读不改变登录项的系统真相）
        let ro = PageModelBuilder.build(
            PageModelBuilder.Input(
                contents: makeContents(makeHeader()),
                readOnly: true,
                loginItem: .notRegistered
            )
        )
        XCTAssertTrue(ro.canRegisterLoginItem, "只读态也要如实投影 canRegisterLoginItem")
    }

    /// `.enabled` / `.requiresApproval` 都不得给注册按钮（动作互斥，见 LoginItemStateTests）。
    func testCanRegisterLoginItemFalseForOtherStates() {
        for state in [LoginItemState.enabled, .requiresApproval, .notFound] {
            let m = PageModelBuilder.build(
                PageModelBuilder.Input(
                    contents: makeContents(makeHeader()),
                    loginItem: state
                )
            )
            XCTAssertFalse(
                m.canRegisterLoginItem,
                "\(state) 不应给「设为登录项」按钮"
            )
        }
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
        XCTAssertEqual(
            m.unmetNotices.map(\.displayText),
            ["uv cache · 样本不足 · 样本 27 / 总量 30（门槛 30，其中失联 3） · 失联不补足，下一轮以新快照重算"],
            "未达项必须是「样本不足」一行：来源标识 + 类名 + 四数齐 + 追加句"
        )
    }

    /// **样本不足 + L0 误判 ⇒ 两行不合并**；归因说明附在第 1 行内、**不单独成行**。
    ///
    /// 契约：AC-08 组 A Then（两项同时成立时**两项分行**）/ DAC-78（**2 行，0 容差**）。
    func testSampleInsufficientAndL0MisjudgedStayTwoRows() {
        let entries = [
            SourceHeaderEntry(source: .uvCache, snapshotTaken: true,
                              T: 30, K: 30, J: 0, H: 30, a: 0, b: 5, slotCount: 30, doneCount: 0),
            SourceHeaderEntry(source: .npmNpx, snapshotTaken: true,
                              T: 12, K: 11, J: 1, H: 12, a: 1, b: 128, slotCount: 12, doneCount: 0),
        ]
        let input = PageModelBuilder.Input(contents: makeContents(makeHeader(entries: entries)))
        let m = PageModelBuilder.build(input)

        XCTAssertEqual(m.unmetNotices.count, 2,
                       "样本不足与 L0 误判必须**分两行**，不得合并成一项（DAC-78，0 容差）")
        XCTAssertEqual(
            m.unmetNotices.map(\.displayText),
            [
                "npm/_npx · 样本不足 · 样本 11 / 总量 12（门槛 12，其中失联 1） · 失联不补足，下一轮以新快照重算 · 因存在 L0 误判，本版本不再提示可点亮进度",
                "npm/_npx · L0 误判 1 次（检查 128 次）",
            ],
            "归因说明必须**并入样本不足行内**，不得单独成行"
        )
    }

    /// **归因说明仅在真误判（`a ≠ 0`）时出现**。
    ///
    /// `a = 0` + `b = 0`（本期不可达的防御态）⇒ 有 L0 行、但**不是误判**
    /// ⇒ 样本不足行内**不得**出现「因存在 L0 误判」。
    func testNoAttributionNoteWithoutRealL0Miss() {
        let entries = [
            SourceHeaderEntry(source: .uvCache, snapshotTaken: true,
                              T: 30, K: 30, J: 0, H: 30, a: 0, b: 5, slotCount: 30, doneCount: 0),
            SourceHeaderEntry(source: .npmNpx, snapshotTaken: true,
                              T: 12, K: 11, J: 1, H: 12, a: 0, b: 0, slotCount: 12, doneCount: 0),
        ]
        let input = PageModelBuilder.Input(contents: makeContents(makeHeader(entries: entries)))
        let m = PageModelBuilder.build(input)

        XCTAssertEqual(m.unmetNotices.count, 2,
                       "样本不足 + L0 行仍是两行")
        XCTAssertFalse(
            m.unmetNotices[0].displayText.contains(UICopy.unmetL0AttributionNote()),
            "`a = 0` ⇒ 不是真误判 ⇒ 样本不足行内不得出现归因说明（实为「\(m.unmetNotices.map(\.displayText))」）"
        )
    }

    /// **固定顺序**：全局项在最前、来源项在后；同来源的行**连续**（DAC-74）。
    func testUnmetNoticesOrderGlobalFirstThenSources() {
        let entries = [
            SourceHeaderEntry(source: .uvCache, snapshotTaken: true,
                              T: 30, K: 30, J: 0, H: 30, a: 0, b: 5, slotCount: 30, doneCount: 0),
            SourceHeaderEntry(source: .npmNpx, snapshotTaken: true,
                              T: 12, K: 11, J: 1, H: 12, a: 1, b: 128, slotCount: 12, doneCount: 0),
        ]
        let input = PageModelBuilder.Input(
            contents: makeContents(makeHeader(round: 1, countedDays: 9, entries: entries))
        )
        let m = PageModelBuilder.build(input)

        XCTAssertEqual(
            m.unmetNotices.map(\.displayText),
            [
                "第 1 轮 · 观察期 9/14 天",
                "npm/_npx · 样本不足 · 样本 11 / 总量 12（门槛 12，其中失联 1） · 失联不补足，下一轮以新快照重算 · 因存在 L0 误判，本版本不再提示可点亮进度",
                "npm/_npx · L0 误判 1 次（检查 128 次）",
            ],
            "未达项固定顺序：全局项在前、来源项在后、同来源的行连续"
        )
        XCTAssertFalse(
            m.unmetNotices[0].displayText.contains(Source.npmNpx.displayName),
            "全局项不带来源标识"
        )
    }

    /// **空判定域 ⇒ 未达项行数 = 0**（TC-034 / DAC-79）。
    ///
    /// 观察期已满且报告已产出 ⇒ 既无全局项也无来源项 ⇒ **一行都不列**。
    func testEmptyDecisionDomainProducesNoUnmetRow() {
        let input = PageModelBuilder.Input(contents: makeContents(makeHeader(entries: [])))
        let m = PageModelBuilder.build(input)

        XCTAssertEqual(m.unmetNotices.count, 0,
                       "空判定域不得产生任何未达项行（DAC-79；实为「\(m.unmetNotices.map(\.displayText))」）")
    }

    /// **降级态 ⇒ 判定域内来源呈现「L0 未判定」**（CR-012 / R2 §25.1 裁定一）。
    ///
    /// `degraded = true` ⇒ 同 uid 进程枚举失败 ⇒ 该来源的 `a` / `b` **均不判定**
    /// ⇒ 未达项必须是「L0 未判定（无法枚举本用户进程）」，
    /// **不得**显示成「已达达标条件」（把未知判成安全 ⇒ 违反不变量 ③）。
    func testDegradedProducesL0UndeterminedRow() {
        let entries = [
            SourceHeaderEntry(source: .uvCache, snapshotTaken: true,
                              T: 30, K: 30, J: 0, H: 30, a: 0, b: 5, slotCount: 30, doneCount: 0),
        ]
        let input = PageModelBuilder.Input(
            contents: makeContents(makeHeader(entries: entries)),
            degraded: true
        )
        let m = PageModelBuilder.build(input)

        XCTAssertEqual(
            m.unmetNotices.map(\.displayText),
            ["uv cache · L0 未判定（无法枚举本用户进程）"],
            "降级态下该来源 `a` / `b` 未判定 ⇒ 必须列「L0 未判定」（实为「\(m.unmetNotices.map(\.displayText))」）"
        )
        XCTAssertFalse(m.canLightUp,
                       "未判定 ≠ 达标：降级态下不得判为可点亮")
    }

    /// ★ **回归护栏**：本轮**未结算**（`K == nil`）的来源**不得**被误标成「L0 未判定」。
    ///
    /// 「L0 未判定」的**唯一**成因是**同 uid 进程枚举失败**（`degraded == true`）。
    /// 「未结算」是**另一回事**（本轮没走到结算）—— 用 `a == 0 && b == 0` 反推未判定
    /// 会把两者混为一谈（**两个值相等不等于同义**）。
    func testUnsettledSourceIsNotLabeledL0Undetermined() {
        let entries = [
            SourceHeaderEntry(source: .uvCache, snapshotTaken: true,
                              T: 30, K: nil, J: nil, H: 30, a: 0, b: 0, slotCount: 30, doneCount: 0),
        ]
        let input = PageModelBuilder.Input(contents: makeContents(makeHeader(entries: entries)))
        let m = PageModelBuilder.build(input)

        XCTAssertFalse(
            m.unmetNotices.map(\.displayText).contains(UICopy.unmetL0Undetermined(source: Source.uvCache.displayName)),
            "未结算（`K == nil`）≠ 枚举失败 ⇒ 不得标「L0 未判定」（实为「\(m.unmetNotices.map(\.displayText))」）"
        )
    }

    /// **`b = 0` ⇒ 呈现「L0 未检查（检查 0 次）」**（PRD v5.6 M5 的防御性表述）。
    ///
    /// `b = 0` 表示**本轮一次 L0 都没做过** ⇒ 不是「误判」，是「没检查」——
    /// 两者的文案必须区分（误判 = `a ≠ 0`；未检查 = `b = 0`）。
    /// PRD :157 说这属**本期不可达**（判定域来源入域当轮即被 L0 判定 ⇒ `b ≥ 1` 恒成立），
    /// 故本例是**防御分支**的护栏：真到了该态，不得显示成「L0 误判 0 次」。
    func testZeroCheckCountShowsL0NeverChecked() {
        let entries = [
            SourceHeaderEntry(source: .uvCache, snapshotTaken: true,
                              T: 30, K: 30, J: 0, H: 30, a: 0, b: 0, slotCount: 30, doneCount: 0),
        ]
        let input = PageModelBuilder.Input(contents: makeContents(makeHeader(entries: entries)))
        let m = PageModelBuilder.build(input)

        XCTAssertEqual(
            m.unmetNotices.map(\.displayText),
            ["uv cache · L0 未检查（检查 0 次）"],
            "`b = 0` ⇒ 「L0 未检查」，不得显示成「L0 误判」（实为「\(m.unmetNotices.map(\.displayText))」）"
        )
        XCTAssertFalse(m.canLightUp,
                       "`b = 0` ⇒ 未做过检查 ⇒ 不得判为可点亮")
    }

    /// **追加句紧跟在四数形态之后，且行内数字恰 4 个**（TC-038 / DAC-76）。
    ///
    /// 「失联不补足，下一轮以新快照重算」必须**附在基数形态之后**，
    /// 且**自身不携带任何数字** —— 行内数字只有 `11 / 12 / 12 / 1` 四个。
    func testSampleNoteFollowsBaseFormAndAddsNoDigits() {
        let entries = [
            SourceHeaderEntry(source: .npmNpx, snapshotTaken: true,
                              T: 12, K: 11, J: 1, H: 12, a: 0, b: 12, slotCount: 12, doneCount: 0),
        ]
        let input = PageModelBuilder.Input(contents: makeContents(makeHeader(entries: entries)))
        let m = PageModelBuilder.build(input)

        XCTAssertEqual(
            m.unmetNotices.map(\.displayText),
            ["npm/_npx · 样本不足 · 样本 11 / 总量 12（门槛 12，其中失联 1） · 失联不补足，下一轮以新快照重算"],
            "追加句须在四数形态之后（实为「\(m.unmetNotices.map(\.displayText))」）"
        )
        XCTAssertEqual(
            digits(in: m.unmetNotices[0].displayText),
            [11, 12, 12, 1],
            "追加句不得携带数字：行内数字恰 4 个（TC-038）"
        )
    }

    /// **计数日已满而报告未产出 ⇒ 「剩余天数」格 = `—`**（TC-036 / DAC-77）。
    ///
    /// 计数日已满（14/14）但报告**还没产出** ⇒ 此时没有「还要等几天」可言
    /// （等的是结算扫描，不是天数）⇒ 该格显示 `—`，
    /// **不得显示「0 天」**（0 会被读成「今天到期」）。
    ///
    /// 同一场景下全局项逐字为「第 1 轮 · 观察期未满 · 待结算扫描（无需操作）」。
    func testDayQuotaReachedWithoutReportShowsDashForRemainingDays() {
        let input = PageModelBuilder.Input(
            contents: makeContents(makeHeader(round: 1, countedDays: 14, produced: false))
        )
        let m = PageModelBuilder.build(input)

        XCTAssertEqual(m.remainingDays.displayText, "—",
                       "计数日已满而报告未产出 ⇒ 剩余天数格必须是「—」，不得显示「0 天」")
        XCTAssertEqual(
            m.unmetNotices.map(\.displayText),
            ["第 1 轮 · 观察期未满 · 待结算扫描（无需操作）"],
            "同一场景下全局项逐字为「待结算扫描」（TC-036）"
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

    // MARK: - 判定域口径（CR-032）：**本轮快照内命中**

    /// **域内来源本轮无快照 → 不得阻断点亮**。
    ///
    /// 契约：判定域 = **本轮观察期开始快照内命中**的来源（PRD v5.6 架构 A1 / R9）——
    /// 「入域」与「本轮有快照」分列，新入域来源不阻断点亮。
    ///
    /// 旧口径按枚举取域（`uv` / `npm` 恒在域内）⇒ 无快照的 `npm`（`T = nil`）
    /// 在 `isQualified` 的 `guard let t = input.total` 处**直接判死**
    /// ⇒ **只用 `uv` 的用户永远点不亮**。
    func testDomainSourceWithoutSnapshotDoesNotBlockLightUp() {
        let entries = [
            SourceHeaderEntry(source: .uvCache, snapshotTaken: true,
                              T: 30, K: 30, J: 0, H: 30, a: 0, b: 5, slotCount: 30, doneCount: 0),
            // 本轮无快照 ⇒ `T` / `K` 皆 nil；`a` / `b` 皆 0（从未参与任何判定）
            SourceHeaderEntry(source: .npmNpx, snapshotTaken: false,
                              T: nil, K: nil, J: nil, H: nil, a: 0, b: 0, slotCount: 0, doneCount: 0),
        ]
        let input = PageModelBuilder.Input(contents: makeContents(makeHeader(entries: entries)))
        let m = PageModelBuilder.build(input)

        XCTAssertTrue(m.canLightUp, "域内但本轮无快照的来源不得阻断点亮")
        XCTAssertFalse(
            m.unmetNotices.contains { $0.displayText.contains(Source.npmNpx.displayName) },
            "无快照的来源从未参与判定，不得出现在未达项里（实为「\(m.unmetNotices.map(\.displayText))」）"
        )
    }

    /// **域内来源有快照但未结算 → 仍不得点亮**（口径修复不得把门槛放松成「只看 `uv`」）。
    ///
    /// `uv` 已取快照（`T = 30`）但**未结算**（`K = nil`）⇒ 不达标。
    func testDomainSourceWithSnapshotButNotSettledStillBlocks() {
        let entries = [
            SourceHeaderEntry(source: .uvCache, snapshotTaken: true,
                              T: 30, K: nil, J: nil, H: 30, a: 0, b: 0, slotCount: 30, doneCount: 0),
            SourceHeaderEntry(source: .npmNpx, snapshotTaken: false,
                              T: nil, K: nil, J: nil, H: nil, a: 0, b: 0, slotCount: 0, doneCount: 0),
        ]
        let input = PageModelBuilder.Input(contents: makeContents(makeHeader(entries: entries)))
        let m = PageModelBuilder.build(input)

        XCTAssertFalse(m.canLightUp, "有快照但未结算 → 不得判为达标")
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
    ///
    /// ⚠️ 须带**本窗候选**：`pipx` 是域外来源 ⇒ 永不取快照 ⇒ 行集合的判据
    /// 只有「本窗候选数 ≥ 1」（PRD v5.6 :1094「行集合为条件式」）。
    func testReportOnlySourceRow() {
        let entries = [
            SourceHeaderEntry(source: .pipxRun, snapshotTaken: true,
                              T: 5, K: 5, J: 0, H: 5, a: 0, b: 1, slotCount: 5, doneCount: 0),
        ]
        let input = PageModelBuilder.Input(
            contents: makeContents(makeHeader(entries: entries)),
            candidates: [makeCandidate(path: "/x/pipx/venv", bytes: 10, source: .pipxRun)]
        )
        let m = PageModelBuilder.build(input)
        let row = m.reportRows[0]

        XCTAssertEqual(row.cells[1][0].displayText, "仅报告")
        XCTAssertEqual(row.cells[3][0].displayText, "不适用")
        XCTAssertEqual(row.cells[6][0].displayText, "仅报告")
    }

    /// **「上一轮」行只在存在上一轮结算记录时出现**（首轮不显示，不是显示「—」）。
    ///
    /// ⚠️ 判据是「**有记录**」而不是「轮次 ≥ 2」：轮次 ≥ 2 但没有结算记录时，
    /// 那行会变成一个没有数据的壳（比不显示更糟）。
    ///
    /// 默认夹具就是 `round: 2` ⇒ **必须显式带上记录**，
    /// 否则断言 `nil` 通过却测的不是契约说的东西（假绿）。
    func testPreviousRoundOnlyFromRoundTwo() {
        let r1 = PageModelBuilder.build(
            PageModelBuilder.Input(contents: makeContents(makeHeader(round: 1)))
        )
        XCTAssertNil(r1.previousRoundSlot, "首轮不得有「上一轮」行")

        let record = PreviousRoundRecord(
            round: 1, source: .uvCache, sample: 11, total: 12,
            settledAt: localDate(2023, 11, 14)
        )
        let r2 = PageModelBuilder.build(
            PageModelBuilder.Input(
                contents: makeContents(makeHeader(round: 2, previousRound: record))
            )
        )
        XCTAssertNotNil(r2.previousRoundSlot)
        XCTAssertTrue(r2.previousRoundSlot?.displayText.hasPrefix("第 1 轮 · ") ?? false,
                      "必须是前置数字式（三处同构）")
    }

    // MARK: - CR-033 · 轮次自动推进的三处可见结果（PRD v5.6 :69）

    /// **③ 页未达项带轮次 + 上一轮括注**（PRD :69 ① / B1 TC-045 ①）。
    ///
    /// 契约原文：`第 2 轮 · 观察期 0/14 天（上一轮样本 11/12 未达标，已自动重开）`
    ///
    /// ⚠️ 括注里的斜杠**无空格**（`11/12`）——与 ⑤ 页「上一轮」行的
    /// `样本 11 / 总量 12`（**有空格**）是契约原文的两处不同写法，不可统一。
    func testUnmetNoticeCarriesRoundAndPreviousRoundNote() {
        let record = PreviousRoundRecord(
            round: 1, source: .uvCache, sample: 11, total: 12,
            settledAt: localDate(2023, 11, 14)
        )
        let m = PageModelBuilder.build(
            PageModelBuilder.Input(
                contents: makeContents(makeHeader(round: 2, countedDays: 0, previousRound: record))
            )
        )
        XCTAssertEqual(
            m.unmetNotices.map(\.displayText),
            ["第 2 轮 · 观察期 0/14 天（上一轮样本 11/12 未达标，已自动重开）"]
        )
    }

    /// **⑤ 页「上一轮」行四要素齐全**（PRD :69 ③ / B1 TC-045 ③ / DAC-50（修订））。
    ///
    /// 契约原文：`第 1 轮 · 样本 11 / 总量 12 · 未达标 · 冻结于 2023-11-14`
    /// 四要素缺一即不通过：①轮次 ②样本/总量 ③未达标 ④冻结于日期。
    func testPreviousRoundSlotCarriesFourElements() {
        let record = PreviousRoundRecord(
            round: 1, source: .uvCache, sample: 11, total: 12,
            settledAt: localDate(2023, 11, 14)
        )
        let m = PageModelBuilder.build(
            PageModelBuilder.Input(
                contents: makeContents(makeHeader(round: 2, previousRound: record))
            )
        )
        XCTAssertEqual(
            m.previousRoundSlot?.displayText,
            "第 1 轮 · 样本 11 / 总量 12 · 未达标 · 冻结于 2023-11-14"
        )
    }

    /// **无上一轮结算记录 ⇒ 不显示「上一轮」行**（B1 TC-054 / 视觉基线 §五）。
    ///
    /// 首轮不显示（**不是显示「—」，也不是灰行**）；
    /// 轮次 ≥ 2 但**没有结算记录**时同样不显示——
    /// 判据是「有记录」，不是「轮次数字 ≥ 2」，
    /// 否则那行会变成一个没有数据的壳（比不显示更糟）。
    func testPreviousRoundSlotAbsentWithoutRecord() {
        let r1 = PageModelBuilder.build(
            PageModelBuilder.Input(contents: makeContents(makeHeader(round: 1)))
        )
        XCTAssertNil(r1.previousRoundSlot, "首轮不得有「上一轮」行")

        let r2 = PageModelBuilder.build(
            PageModelBuilder.Input(contents: makeContents(makeHeader(round: 2)))
        )
        XCTAssertNil(r2.previousRoundSlot, "轮次 ≥ 2 但无结算记录 ⇒ 同样不显示")
    }

    // MARK: - ⑤ 矩阵：`nil` 不得被当成 0（CR-031 §1.1b）

    /// **报告已产出、但该来源 `K` 仍为 `nil`** → ③ 列不得显示「0 / 总量」。
    ///
    /// `0` 会被读成「一条都没归因成功」——那是**另一件事**。
    /// 不变量③：`nil ≠ 0`（不变量③ = 看不见的东西如实显示「无法判定」）。
    func testProducedButKNilIsNotRenderedAsZero() {
        let entries = [
            SourceHeaderEntry(source: .uvCache, snapshotTaken: true,
                              T: 30, K: nil, J: nil, H: 30, a: 0, b: 7, slotCount: 30, doneCount: 0),
        ]
        let input = PageModelBuilder.Input(
            contents: makeContents(makeHeader(countedDays: 14, produced: true, entries: entries))
        )
        let m = PageModelBuilder.build(input)
        let row = m.reportRows[0]

        XCTAssertNotEqual(row.cells[2][0].displayText, "0 / 30", "`nil` 不得渲染成 0")
        XCTAssertTrue(row.cells[2][0].isUnavailable, "③ 列必须是不可用态")
    }

    /// **报告已产出、但该来源 `T` 为 `nil`** → ⑦ 结论**不得**是「达标」。
    ///
    /// 这是 §1.1b 里比「未达标」更危险的一支：
    /// 旧写法 `k = K ?? 0, t = T ?? 0` ⇒ `h(0) = min(30, 0) = 0`
    /// ⇒ `0 >= 0` 成立 ⇒ 只要 `a == 0 && b >= 1` 就被判「**达标**」。
    ///
    /// 「达标」比「未达标」危险得多 —— 用户会以为可以删，程序却不会删。
    ///
    /// ⚠️ 须带**本窗候选**：`snapshotTaken: false` 且 `T: nil` ⇒ 无快照 ⇒
    /// 行集合的判据只剩「本窗候选数 ≥ 1」（PRD v5.6 :1094）。
    func testProducedButTNilDoesNotQualify() {
        let entries = [
            SourceHeaderEntry(source: .uvCache, snapshotTaken: false,
                              T: nil, K: nil, J: nil, H: nil, a: 0, b: 7, slotCount: 0, doneCount: 0),
        ]
        let input = PageModelBuilder.Input(
            contents: makeContents(makeHeader(countedDays: 14, produced: true, entries: entries)),
            candidates: [makeCandidate(path: "/x/uv/a", bytes: 10, source: .uvCache)]
        )
        let m = PageModelBuilder.build(input)
        let row = m.reportRows[0]

        XCTAssertNotEqual(row.cells[6][0].displayText, "达标", "未定量的来源不得判「达标」")
        XCTAssertTrue(row.cells[6][0].isUnavailable, "⑦ 结论必须是不可用态")
    }

    /// **守卫**：`K` / `T` 都有值时，③ 与 ⑦ 的取值不受影响。
    ///
    /// 本用例在改动前后都应通过 —— 挡住「一律改成不可用」这种过度修法。
    func testSettledRowStillRendersRatioAndConclusion() {
        let entries = [
            SourceHeaderEntry(source: .uvCache, snapshotTaken: true,
                              T: 100, K: 90, J: 10, H: 30, a: 0, b: 12, slotCount: 100, doneCount: 0),
        ]
        let input = PageModelBuilder.Input(
            contents: makeContents(makeHeader(countedDays: 14, produced: true, entries: entries))
        )
        let m = PageModelBuilder.build(input)
        let row = m.reportRows[0]

        XCTAssertEqual(row.cells[2][0].displayText, "90 / 100", "已结算来源的 ③ 列照常显示")
        XCTAssertEqual(row.cells[6][0].displayText, "达标", "已结算来源的 ⑦ 结论照常判")
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
        XCTAssertEqual(m.overviewBlocks.count, 7, "区块数 = Source.allCases 七个（CR-038）")
        XCTAssertEqual(m.overviewBlocks[0].slot.displayText, MetricUnit.formatBytes(3_000_000))
        XCTAssertEqual(m.overviewBlocks[1].slot.displayText, MetricUnit.formatBytes(3_000_000))
        XCTAssertEqual(m.overviewBlocks[2].slot.displayText, MetricUnit.formatBytes(0))
    }

    /// **总量 = 三来源之和**（先回答「一共占了多少」，再给分来源明细）。
    func testTotalFootprintIsSumOfAllSources() {
        let input = PageModelBuilder.Input(
            contents: makeContents(makeHeader()),
            candidates: [
                makeCandidate(path: "/uv/a", bytes: 1_000_000, source: .uvCache),
                makeCandidate(path: "/npm/c", bytes: 3_000_000, source: .npmNpx),
                makeCandidate(path: "/pipx/d", bytes: 500_000, source: .pipxRun),
            ]
        )
        let m = PageModelBuilder.build(input)
        XCTAssertEqual(
            m.totalFootprintBytes.displayText,
            MetricUnit.formatBytes(4_500_000),
            "总量必须含全部三个来源（含仅报告的 pipx）"
        )
    }

    /// **空态可达**：没扫过（无候选 + 无 lastScanAt）→ `isFirstRunEmpty` 为真。
    ///
    /// 原先 `overviewBlocks` 恒三块 → 空态分支永远进不来，首启显示三张 0 B 卡。
    func testFirstRunEmptyWhenNoCandidatesAndNoScan() {
        var header = makeHeader()
        header.lastScanAt = nil
        let m = PageModelBuilder.build(
            PageModelBuilder.Input(contents: makeContents(header), candidates: [])
        )
        XCTAssertTrue(m.isFirstRunEmpty, "从未扫描过必须是空态（要回答「现在该做什么」）")
        XCTAssertFalse(m.overviewBlocks.isEmpty, "三区块仍构建（渲染稿依赖它）")
    }

    /// 扫过之后（有 lastScanAt）→ 不是空态，即使候选为空也显示数据形态。
    func testNotFirstRunEmptyAfterScan() {
        var header = makeHeader()
        header.lastScanAt = Date(timeIntervalSince1970: 1_700_000_000)
        let m = PageModelBuilder.build(
            PageModelBuilder.Input(contents: makeContents(header), candidates: [])
        )
        XCTAssertFalse(m.isFirstRunEmpty, "扫过之后应显示数据形态（0 B 也是真实值）")
    }

    /// 有候选 → 不是空态。
    func testNotFirstRunEmptyWithCandidates() {
        let m = PageModelBuilder.build(
            PageModelBuilder.Input(
                contents: makeContents(makeHeader()),
                candidates: [makeCandidate(path: "/a", bytes: 1, source: .uvCache)]
            )
        )
        XCTAssertFalse(m.isFirstRunEmpty)
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

    // MARK: - CR-036 · 未达项区四态（`.rows` / `.none` / `.emptyDomain`）

    /// **态②：判定域非空且无未达项 ⇒ `.none`**（CR-036 §七 判据 9）。
    ///
    /// 样本：`produced: true`（报告已产出）+ `countedDays: 14`（观察期已满）
    /// ⇒ 无全局项；域内来源 `K ≥ H` / `a = 0` / `b ≥ 1` ⇒ 无来源项。
    /// **既有 `.rows([])` 一行都不能列** —— 空数组无法区分「无未达项」与
    /// 「还没判定」（不变量 ③：看不见的东西如实说「无法判定」）。
    func testUnmetSectionIsNoneWhenDecisionDomainNonEmptyAndNoUnmetItem() {
        let input = PageModelBuilder.Input(contents: makeContents(makeHeader()))
        let m = PageModelBuilder.build(input)

        XCTAssertEqual(m.unmetSection, .none,
                       "判定域非空且未达项为空 ⇒ 必须是 `.none`（实为「\(m.unmetSection)」）")
    }

    /// **态③：判定域为空且已扫过 ⇒ `.emptyDomain(.noScannableSource)`**
    /// （CR-036 §七 判据 1 / 2 / 3）。
    ///
    /// ⚠️ **必须显式设 `lastScanAt != nil`** —— 否则落进态④（从未扫描），
    /// 那时「尚未知」≠「已确定为空」（不变量 ③）。
    func testUnmetSectionIsEmptyDomainWhenDecisionDomainEmptyAfterScan() {
        var header = makeHeader(produced: false, entries: [])
        header.lastScanAt = Date(timeIntervalSince1970: 1_700_000_000)
        let input = PageModelBuilder.Input(contents: makeContents(header))
        let m = PageModelBuilder.build(input)

        XCTAssertEqual(m.unmetSection, .emptyDomain(.noScannableSource),
                       "扫过 + 判定域为空 + 无任何候选 ⇒ 「无可扫描来源」（实为「\(m.unmetSection)」）")
    }

    /// **态③的另一个成因：页面有候选但判定域内一个都没有 ⇒ `.noCleanupCandidate`**。
    ///
    /// `pipx run` 是**判定域外**来源（`Source.isInDecisionDomain == false`）⇒
    /// **有候选 ≠ 有可清理的判定域内候选**。
    /// ⚠️ 判据取 **`input.candidates`**（全部候选）而不是 `visibleCandidates`
    /// —— 白名单过滤后的可见集会把「被白名单挡掉」误报成「无来源」。
    func testUnmetSectionIsEmptyDomainNoCandidateWhenOnlyOutOfDomainCandidates() {
        var header = makeHeader(produced: false, entries: [])
        header.lastScanAt = Date(timeIntervalSince1970: 1_700_000_000)
        let input = PageModelBuilder.Input(
            contents: makeContents(header),
            candidates: [makeCandidate(path: "/pipx/venvs/t", bytes: 10, source: .pipxRun)]
        )
        let m = PageModelBuilder.build(input)

        XCTAssertEqual(m.unmetSection, .emptyDomain(.noCleanupCandidate),
                       "有候选但全是域外来源 ⇒ 「无清理候选」（实为「\(m.unmetSection)」）")
    }

    /// **空域成因的判据取「全部候选」，不是白名单过滤后的可见集**
    /// （CR-036 §3.4 口径 · 步骤 6 变异 2 的区分点）。
    ///
    /// 样本：唯一候选**被白名单挡掉** ⇒ `input.candidates` 非空、`visibleCandidates` 为空。
    /// 判据取未过滤的候选集 ⇒ 成因是「无清理候选」（**扫到了东西，只是没可清的**），
    /// 不是「无可扫描来源」（那是**把白名单过滤后的空**误当成「没来源」）。
    ///
    /// ⚠️ **白名单必须与候选路径匹配**（`WhitelistGuard` 按路径前缀匹配）——
    /// 否则过滤前后一致、两个口径区分不开，变异 2 会**全绿假过**
    /// （CR-036 §10.5 实测到的第二处假绿）。
    func testEmptyDomainCauseUsesUnfilteredCandidates() {
        var header = makeHeader(produced: false, entries: [])
        header.lastScanAt = Date(timeIntervalSince1970: 1_700_000_000)
        let input = PageModelBuilder.Input(
            contents: makeContents(header),
            candidates: [makeCandidate(path: "/uv/cache/abc", bytes: 10, source: .uvCache)],
            whitelist: ["/uv/cache"]
        )
        let m = PageModelBuilder.build(input)

        XCTAssertEqual(m.unmetSection, .emptyDomain(.noCleanupCandidate),
                       "候选被白名单挡掉仍算「有候选」⇒ 成因应是「无清理候选」（实为「\(m.unmetSection)」）")
    }

    /// **态④：从未扫描 ⇒ 保留全局项**（CR-036 §七 判据 14）。
    ///
    /// 「从未扫描」是**尚未知**，不是「已确定为空」⇒ 不得显示「无可扫描来源」，
    /// 也不得显示「无未达项」——**全局项必须留着**（全局项本身就是「还在观察期」）。
    func testUnmetSectionKeepsGlobalItemWhenNeverScanned() {
        let input = PageModelBuilder.Input(
            contents: makeContents(makeHeader(round: 2, countedDays: 0, produced: false, entries: []))
        )
        let m = PageModelBuilder.build(input)

        XCTAssertEqual(m.unmetSection, .rows([.text("第 2 轮 · 观察期 0/14 天")]),
                       "从未扫描 ⇒ 必须保留全局项，不得退成「无未达项」/「无可扫描来源」")
    }

    /// **空判定域的两串成因文案逐字固定**（CR-036 §七 判据 1）。
    ///
    /// ⚠️ **不得**写成「已达达标条件」——空判定域是**没有可判的东西**，
    /// 不是**判过了并且达标**（不变量 ③）。
    func testEmptyDomainCauseStringsAreExact() {
        XCTAssertEqual(UICopy.emptyDomainText(.noScannableSource), "无可扫描来源")
        XCTAssertEqual(UICopy.emptyDomainText(.noCleanupCandidate), "无清理候选")
    }

    /// **空判定域 ⇒ 未达项行数 = 0**（CR-036 §七 判据 2 / 3）。
    ///
    /// 空判定域**不列**全局项 —— 全局项是「判定域内某来源没达标」的归因，
    /// 域为空时它没有归属 ⇒ 一行都不列（DAC-79）。
    ///
    /// ⚠️ **样本必须让全局项真的存在**（`produced: false` ⇒ 报告未产出 ⇒
    /// `unmet.global != nil`）——否则本断言在「回退到旧行为（列出全局项）」
    /// 下**照样绿**，判据 2 形同虚设（防假绿步骤实测到的假绿）。
    func testEmptyDomainHasNoUnmetRows() {
        var header = makeHeader(produced: false, entries: [])
        header.lastScanAt = Date(timeIntervalSince1970: 1_700_000_000)
        let input = PageModelBuilder.Input(contents: makeContents(header))
        let m = PageModelBuilder.build(input)

        XCTAssertEqual(m.unmetSection, .emptyDomain(.noScannableSource),
                       "空判定域必须是 `.emptyDomain`，不得是 `.rows`")
        XCTAssertEqual(m.unmetNotices.count, 0,
                       "空判定域不得列任何未达项行（DAC-79；实为「\(m.unmetNotices.map(\.displayText))」）")
    }

    /// **「无未达项」逐字固定**（CR-036 §七 判据 9）。
    func testUnmetNoneTextIsExact() {
        XCTAssertEqual(UICopy.unmetNone, "无未达项")
    }

    /// **「无未达项」≠「可点亮」**（CR-036 §七 判据 9 · 不变量 ③）。
    ///
    /// 样本：域内来源 `K == nil`（**本轮未结算**）⇒ `unmetItems` 因
    /// `let k = input.attributable` 绑定失败而**不产来源项** ⇒ 未达项为空；
    /// 而 `isQualified` 在同一处 `guard let k = …` **判死** ⇒ 不可点亮。
    ///
    /// ⚠️ **造不出 `a == nil`** —— `SourceHeaderEntry.a` / `.b` 是**非可选 `Int`**；
    /// 「未达项为空但不可点亮」的真实成因是**未结算（`K == nil`）**。
    /// 另注：`b` 必须 ≥ 1，否则会多出一行「L0 未检查」，未达项就不空了。
    func testNoUnmetItemsDoesNotMeanQualified() {
        let entries = [
            SourceHeaderEntry(source: .uvCache, snapshotTaken: true,
                              T: 30, K: nil, J: nil, H: 30, a: 0, b: 5, slotCount: 30, doneCount: 0),
        ]
        let input = PageModelBuilder.Input(contents: makeContents(makeHeader(entries: entries)))
        let m = PageModelBuilder.build(input)

        XCTAssertEqual(m.unmetSection, .none,
                       "未结算来源不产来源项 ⇒ 未达项区为空")
        XCTAssertFalse(m.canLightUp,
                       "未达项为空 ≠ 可点亮：`K == nil`（未结算）时不得判为可点亮")
    }

    // MARK: - CR-037：扫描进度透传

    /// **扫描进度要进到页面模型里**（CR-037 §3.5 · §七 判据 3）。
    ///
    /// ① 页的进度环读的就是 `model.scanProgress` ⇒ 不透传则界面永远看不到环。
    func testBuilderCarriesScanProgressIntoModel() throws {
        let progress = ScanProgress(
            source: "uv",
            filesScanned: 12_847,
            candidatesFound: 42,
            elapsed: 3.2,
            isRunning: true,
            completedSources: 1,
            totalSources: 3
        )
        let input = PageModelBuilder.Input(
            contents: makeContents(makeHeader()),
            scanProgress: progress
        )
        let m = PageModelBuilder.build(input)
        XCTAssertEqual(m.scanProgress, progress, "扫描进度须原样透传到页面模型")
        // ⚠️ 不用 `?? 0` —— 那会把「分母未知」当成「0%」（不变量③）。
        let fraction = try XCTUnwrap(m.scanProgress?.fraction)
        XCTAssertEqual(fraction, 1.0 / 3.0, accuracy: 1e-9)
    }

    /// **「加载」只剩 `scanProgress` 一个事实源**（CR-037 §3.4）。
    ///
    /// 旧的 `loading: Bool` + `loadingMessage: String` 是**两个并列的事实源**
    /// （一个说「在加载」，一个说「加载到哪儿了」）⇒ 必然出现
    /// 「loading 为真但 message 是旧的」这类自相矛盾状态。
    ///
    /// ⚠️ 用 `Mirror` 反射检查**存储属性名**，而不是直接访问 `model.loading` ——
    /// 删掉字段后直接访问会**编译失败**（那就测不出「字段还在」了）。
    func testModelHasNoLoadingField() {
        let stored = Mirror(reflecting: PageModel()).children.compactMap { $0.label }
        XCTAssertFalse(stored.contains("loading"), "`loading` 字段须删除（事实源须唯一）")
        XCTAssertFalse(stored.contains("loadingMessage"), "`loadingMessage` 字段须删除")
        XCTAssertTrue(stored.contains("scanProgress"), "加载态的真值载体应是 `scanProgress`")
    }

}
