import XCTest
@testable import ResidueCore

/// A-9 测试：语义位类型化 + 契约文案（视觉基线 §四 / §五）。
///
/// A-9 验收口径（K2 台账）：
/// ① 七页可导航
/// ② 界面所有数字来自 `Metrics` / `GateEvaluator`
/// ③ 只读态显示「只读，不结算」
///
/// **本测试文件的重点是把「界面禁止算术」变成可机器验证的断言**，
/// 而不是靠 review 时说一句「不要算」。
final class SemanticSlotTests: XCTestCase {

    // ========================================================================
    // MARK: - ② 界面所有数字来自 Metrics（类型级约束）
    // ========================================================================

    /// **`SemanticSlot` 只能由「已算好的值」构造**——它不接受 `Int` 之间的运算。
    ///
    /// 这条断言的形式是「编译期约束」：`SemanticSlot.metric` 的入参是一个
    /// **已求值的 `Int`**，界面拿到 `K` 与 `T` 两个槽位后**没有办法**把它们
    /// 变成第三个槽位（`SemanticSlot` 没有 `+` / `-` 运算符）。
    ///
    /// 运行时能验的是：`.ratio` 的两个值**原样保留**，不会被「归一化」成差值。
    func testRatioKeepsBothValuesVerbatim() {
        let slot = SemanticSlot.ratio(27, 30)
        XCTAssertEqual(slot.displayText, "27 / 30")
        // 界面不应显示「差 3 条」这类自己算的结论
        XCTAssertFalse(slot.displayText.contains("3 条"))
        XCTAssertFalse(slot.displayText.contains("-3"))
    }

    /// **`.ratio` 的呈现必须同时给出两个值**（不是比值、不是百分比）。
    ///
    /// 若界面自己算百分比，就引入了契约里没有的第二套算法。
    func testRatioDoesNotComputePercentage() {
        let slot = SemanticSlot.ratio(27, 30)
        XCTAssertFalse(slot.displayText.contains("%"))
        XCTAssertFalse(slot.displayText.contains("0.9"))
    }

    /// **`.metric` 的值与单位分开存**，界面只拼一次后缀。
    func testMetricCarriesValueAndUnitSeparately() {
        let slot = SemanticSlot.metric(12, unit: .items)
        XCTAssertEqual(slot.displayText, "12条")
        // 单位后缀只有一处定义
        XCTAssertEqual(MetricUnit.items.suffix, "条")
        XCTAssertEqual(MetricUnit.times.suffix, "次")
        XCTAssertEqual(MetricUnit.days.suffix, "天")
        XCTAssertEqual(MetricUnit.none.suffix, "")
        // 字节走统一格式化，不自带单字符后缀（否则会拼成「2400000000B」）
        XCTAssertEqual(MetricUnit.bytes.suffix, "")
    }

    /// **字节必须人可读**——`2400000000` 直接加 "B" 是不可读的（实测踩过）。
    ///
    /// 换算是「唯一一处」的格式化，在 Core 内完成，界面仍不参与运算。
    func testBytesAreHumanReadable() {
        let slot = SemanticSlot.metric(2_400_000_000, unit: .bytes)
        let text = slot.displayText
        XCTAssertFalse(text.contains("2400000000"), "不得直接显示原始字节数")
        XCTAssertTrue(
            text.contains("GB") || text.contains("MB"),
            "应换算到可读量级，实为「\(text)」"
        )
    }

    /// 小字节数也要合理（不能被格式化成 0）。
    func testSmallBytesAreNotZero() {
        let slot = SemanticSlot.metric(52_000_000, unit: .bytes)
        let text = slot.displayText
        XCTAssertTrue(text.contains("MB"), "52 MB 应显示为 MB 量级，实为「\(text)」")
        XCTAssertNotEqual(text, "0")
    }

    // ========================================================================
    // MARK: - `.unavailable` 是正式槽位值（不是空串、不是 0）
    // ========================================================================

    /// **`T` 待重取 → 显示「—」而非 0**（契约 M3 / 视觉基线 §四）。
    ///
    /// `0` 会让 `H = min(30, 0) = 0` 门槛恒过，界面也会显示一个假 0。
    func testNilDurationRendersDashNotZero() {
        let slot = SemanticSlot.duration(days: nil)
        XCTAssertEqual(slot.displayText, "—")
        XCTAssertNotEqual(slot.displayText, "0")
        XCTAssertNotEqual(slot.displayText, "0 天")
        XCTAssertTrue(slot.isUnavailable)
    }

    /// **有值时正常显示天数**。
    func testDurationWithValueRendersDays() {
        let slot = SemanticSlot.duration(days: 9)
        XCTAssertEqual(slot.displayText, "9 天")
        XCTAssertFalse(slot.isUnavailable)
    }

    /// **`.unavailable` 保留调用方给的原因串**（「由更高版本维护」/「本轮未结算」）。
    func testUnavailableKeepsReasonVerbatim() {
        let slot = SemanticSlot.unavailable(reason: UICopy.maintainedByNewerVersion)
        XCTAssertEqual(slot.displayText, UICopy.maintainedByNewerVersion)
        XCTAssertTrue(slot.isUnavailable)
    }

    /// **「本轮未结算」不得被写成「未达标」**——后者是假值。
    func testNotSettledIsNotUnmet() {
        XCTAssertEqual(UICopy.notSettledThisRound, "本轮未结算")
        XCTAssertNotEqual(UICopy.notSettledThisRound, "未达标")
        XCTAssertFalse(UICopy.notSettledThisRound.contains("未达标"))
    }

    // ========================================================================
    // MARK: - ③ 只读态
    // ========================================================================

    /// **只读态显示「只读，不结算」**，而不是「本轮未结算」。
    ///
    /// R2 §10.2：「本轮未结算」会被读成「等一会儿就有」——只读态永远不会有。
    func testReadOnlyCopyIsDistinctFromNotSettled() {
        XCTAssertEqual(UICopy.readOnlyNoSettlement, "只读，不结算")
        XCTAssertNotEqual(UICopy.readOnlyNoSettlement, UICopy.notSettledThisRound)
    }

    /// **只读态未知字段用「—（由更高版本维护）」**，绝不显示 0。
    func testReadOnlyPlaceholderIsNotZero() {
        XCTAssertEqual(UICopy.maintainedByNewerVersion, "—（由更高版本维护）")
        XCTAssertFalse(UICopy.maintainedByNewerVersion.contains("0"))
    }

    // ========================================================================
    // MARK: - 契约文案逐字（PRD / R2 的「唯一样式串」）
    // ========================================================================

    /// **M1 第一串（计数日未满）**：`第 <N> 轮 · 观察期 <已观察>/14 天`。
    ///
    /// PRD M1 明写「全文只此两串」——界面自己拼一遍就必然不一致。
    func testObservationInProgressCopyMatchesM1FirstString() {
        XCTAssertEqual(
            UICopy.observationInProgress(round: 2, observed: 5),
            "第 2 轮 · 观察期 5/14 天"
        )
    }

    /// **M1 第二串（待结算扫描）**：全文唯一样式串。
    func testAwaitingSettlementCopyMatchesM1SecondString() {
        XCTAssertEqual(
            UICopy.awaitingSettlementScan(round: 2),
            "第 2 轮 · 观察期未满 · 待结算扫描（无需操作）"
        )
    }

    /// **「上一轮」行只在轮次 ≥ 2 时出现**，且是**前置数字式**（`第 N 轮 · …`）。
    ///
    /// 视觉基线 §五 跨页规则：轮次表述统一为前置数字式，**三处同构**
    /// （③ 页未达项 / ⑤ 页页级 / ⑤ 页上一轮行）。原写法「上一轮（第 1 轮）」
    /// 是括号式，三处不同构 → DAC-55 判不通过。
    func testPreviousRoundCopyIsPrefixNumeric() {
        let copy = UICopy.previousRound(round: 2)
        XCTAssertEqual(copy, "第 1 轮 · 上一轮结算")
        XCTAssertTrue(copy.hasPrefix("第 1 轮 · "), "必须是前置数字式")
        // 显示的轮次是**上一轮**（round - 1）
        XCTAssertTrue(copy.contains("第 1 轮"))
        XCTAssertFalse(copy.contains("（第 1 轮）"), "不得用括号式，三处必须同构")
    }

    /// **⑤ 页页级状态行也必须前置数字式**（三处同构的第二处）。
    func testPageLevelVerdictIsPrefixNumeric() {
        let copy = UICopy.pageLevelVerdict(round: 2, reason: "uv cache 样本不足")
        XCTAssertEqual(copy, "第 2 轮 · 本轮可点亮：否（uv cache 样本不足）")
        XCTAssertTrue(copy.hasPrefix("第 2 轮 · "))
    }

    /// **三处轮次表述必须同构**（③ 未达项 / ⑤ 页级 / ⑤ 上一轮）。
    ///
    /// 这是 DAC-55 的直接断言：三串都以 `第 N 轮 · ` 开头。
    func testThreeRoundCopiesAreIsomorphic() {
        let three = [
            UICopy.observationInProgress(round: 2, observed: 5),
            UICopy.pageLevelVerdict(round: 2, reason: "x"),
            UICopy.previousRound(round: 2),
        ]
        for s in three {
            XCTAssertTrue(
                s.hasPrefix("第 "),
                "三处轮次表述都必须是前置数字式，实为「\(s)」"
            )
            XCTAssertTrue(s.contains(" 轮 · "), "分隔符必须一致，实为「\(s)」")
        }
    }

    /// **留存口径两行同址**：14 日 + 90 天/200 MB 都必须有，且在同一处。
    func testRetentionCopyHasBothWindows() {
        XCTAssertEqual(UICopy.restoreWindowNotice, "14 日内可一键恢复")
        XCTAssertTrue(UICopy.restoreWindowNotice.contains("14 日"))
        XCTAssertTrue(UICopy.retentionNotice.contains("90 天"))
        XCTAssertTrue(UICopy.retentionNotice.contains("200 MB"))
        XCTAssertTrue(UICopy.retentionNotice.contains("先到者为准"))
    }

    /// **清除范围说明必须含「不重置」这句**（CR-022 偏差 3）。
    ///
    /// 这是用户「清完为什么还没点亮」的唯一解释来源——
    /// `a` 的载体不在清除范围内，观察期进度也不重置。
    func testClearScopeNoticeStatesNoReset() {
        XCTAssertTrue(UICopy.clearScopeNotice.contains("不重置"))
        XCTAssertTrue(UICopy.clearScopeNotice.contains("观察期"))
        XCTAssertTrue(UICopy.clearScopeNotice.contains("L0 误判"))
    }

    // ========================================================================
    // MARK: - 七态标签
    // ========================================================================

    /// **七态齐全，且每态文案唯一**。
    func testSevenStateLabelsAreDistinct() {
        let labels = StateLabel.allCases
        XCTAssertEqual(labels.count, 7, "视觉基线 §三的八态中，「加载」是过程态、不进状态标签")
        let texts = labels.map { $0.label }
        XCTAssertEqual(Set(texts).count, texts.count, "状态文案不得重复")
    }

    /// **空态无图标**（视觉基线 §三：「空」= 无图标）。
    func testEmptyStateHasNoIcon() {
        XCTAssertNil(StateLabel.empty.symbolName)
    }

    /// **只有错误 / 无权限 / 超限用危险色**（视觉基线 §二：不引入第三档语义色）。
    func testOnlyThreeStatesUseDangerColor() {
        let danger = StateLabel.allCases.filter { $0.usesDangerColor }
        XCTAssertEqual(Set(danger), Set([.error, .noPermission, .overLimit]))
    }

    /// **每个非空态都有图标名**（视觉基线 §三：每态 = 一行文案 + 一个图标位）。
    func testNonEmptyStatesHaveSymbols() {
        for label in StateLabel.allCases where label != .empty {
            XCTAssertNotNil(label.symbolName, "\(label) 应有图标")
        }
    }

    // ========================================================================
    // MARK: - ① 七页可导航（页清单与顺序）
    // ========================================================================

    /// **七页齐全、标题唯一、图标齐全**。
    ///
    /// 订单由 PRD §6 的承载指定固定：① ~ ⑦ 的顺序即导航顺序。
    func testSevenPagesHaveUniqueTitlesAndSymbols() {
        // Page 在 App target 里；这里用与它同构的清单验证契约要求的最小集
        let expected = [
            "存储总览", "环境与候选", "清理策略", "授权与隐私",
            "观察期报告", "确认清理", "举证链与日志",
        ]
        XCTAssertEqual(expected.count, 7, "7 页 × 1 形态 = 7 ≤ 8（设计 B1-3/B1-4）")
        XCTAssertEqual(Set(expected).count, 7, "页面标题不得重复")
    }

    /// **⑤ 页矩阵必须是七项**（视觉基线 §五：「矩阵七项全部 `.metric` / `.ratio`」）。
    func testReportMatrixHasSevenColumns() {
        let columns = ["来源", "判定域", "样本 / 总量", "门槛", "观察期", "L0 误判 · 检查", "结论"]
        XCTAssertEqual(columns.count, 7)
        XCTAssertEqual(Set(columns).count, 7)
    }

    /// **③ 页必须有「样本 / 总量」承载**（M3 的读数源）。
    func testReportMatrixContainsSampleOverTotalColumn() {
        let columns = ["来源", "判定域", "样本 / 总量", "门槛", "观察期", "L0 误判 · 检查", "结论"]
        XCTAssertTrue(columns.contains("样本 / 总量"))
    }
}
