import XCTest
@testable import ResidueCore

/// `RatioSlot`：**视图唯一允许的比例来源**。
///
/// 这一组断言守的是「界面禁止算术」的类型级实现：
/// 视图拿不到分子分母，只能拿到已算好的 `fraction` / `percentTenths`。
final class RatioSlotTests: XCTestCase {

    func testFractionAndPercentAreComputedInCore() {
        let slot = RatioSlot(numerator: 3, denominator: 10)
        XCTAssertNotNil(slot)
        XCTAssertEqual(slot?.fraction ?? -1, 0.3, accuracy: 0.0001)
        XCTAssertEqual(slot?.percentTenths, 300)
    }

    func testPercentTenthsRoundsToOneDecimal() {
        // 1 / 3 = 33.333…% → 333（即 33.3%）
        XCTAssertEqual(RatioSlot(numerator: 1, denominator: 3)?.percentTenths, 333)
    }

    func testZeroNumeratorIsAValidZero() {
        // 0 是**真实值**（这一来源确实没占用），不是「未知」。
        let slot = RatioSlot(numerator: 0, denominator: 10)
        XCTAssertEqual(slot?.fraction, 0)
        XCTAssertEqual(slot?.percentTenths, 0)
    }

    func testZeroDenominatorIsUnknownNotZero() {
        // 总量为 0 时「占比」无定义 → nil（界面显示「—」，不显示 0%）。
        XCTAssertNil(RatioSlot(numerator: 0, denominator: 0))
        XCTAssertNil(RatioSlot(numerator: 5, denominator: 0))
        XCTAssertNil(RatioSlot(numerator: 5, denominator: -1))
    }

    func testNegativeNumeratorIsRejected() {
        XCTAssertNil(RatioSlot(numerator: -1, denominator: 10))
    }

    func testOverflowIsClampedToOne() {
        // `K` 可以大于 `H`（门槛是下界，不是上限）→ 进度条封顶，不越界。
        let slot = RatioSlot(numerator: 300, denominator: 30)
        XCTAssertEqual(slot?.fraction, 1.0)
        XCTAssertEqual(slot?.percentTenths, 1000)
    }
}
