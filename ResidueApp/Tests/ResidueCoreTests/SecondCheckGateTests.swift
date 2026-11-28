import XCTest
@testable import ResidueCore

// ============================================================
// SecondCheckGate · 删除前总闸（AC-17 · fail-closed）
//
// ## 这一组测试在钉什么
//
// 二次检查有两问（还是不是当初那个 / 有没有被活引用持有），
// 两问都答不上来时**唯一安全的答案是「不删」**。
//
// 总闸把两问收成一个值域封闭的结论，判定只有这一处实现 ——
// 这一组测试就是那道闸的**规格**：
//
// - `.unreadable`（读不到）⇒ **必须**阻断（P-027 / P-028）；
// - `.absent`（确定不存在）⇒ 阻断，且原因串不得写成「无法读取」；
// - 活引用 ⇒ 阻断；
// - 一切正常 ⇒ 放行（**别把闸修成恒真**，那等于没闸）。
//
// ## 为什么「放行」也要测
//
// 安全闸最常见的退化方向是「什么都拦」（恒真误报 ⇒ 永不删 ⇒ 产品没用）。
// 只测阻断方向的闸，测不出这种退化。
// ============================================================

final class SecondCheckGateTests: XCTestCase {

    private let identity = FileIdentity(dev: 42, ino: 7)

    // MARK: - 身份复核侧

    /// 确定不存在 ⇒ 阻断（没东西可删）。
    func testVanishedIdentityBlocks() {
        let decision = SecondCheckGate.decide(
            identityStatus: .vanished,
            identityState: .resolved(identity),
            isLiveHeld: { _ in false }
        )
        XCTAssertEqual(decision, .blocked(.vanished))
    }

    /// 同名重建 ⇒ 阻断（现在这个不是当初判定的那个）。
    func testRebuiltIdentityBlocks() {
        let decision = SecondCheckGate.decide(
            identityStatus: .rebuilt,
            identityState: .resolved(identity),
            isLiveHeld: { _ in false }
        )
        XCTAssertEqual(decision, .blocked(.rebuilt))
    }

    /// **读不到属性** ⇒ 阻断，**不得**放行（P-028：不能当成「已不存在」）。
    func testUnreadableIdentityBlocksAndDoesNotProceed() {
        let decision = SecondCheckGate.decide(
            identityStatus: .unreadable(errno: 13),
            identityState: .resolved(identity),
            isLiveHeld: { _ in false }
        )
        XCTAssertEqual(decision, .blocked(.unreadable(errno: 13)))
        if case .proceed = decision {
            XCTFail("读不到属性时不得放行删除")
        }
    }

    /// 读不到属性时**不该**做活引用判定（无从判定，也没有意义）。
    func testUnreadableIdentitySkipsLiveHeldCheck() {
        var called = false
        _ = SecondCheckGate.decide(
            identityStatus: .unreadable(errno: 13),
            identityState: .resolved(identity),
            isLiveHeld: { _ in
                called = true
                return false
            }
        )
        XCTAssertFalse(called, "属性读不到时应直接阻断，不必再查活引用")
    }

    // MARK: - L0 侧

    /// **取不到身份** ⇒ 阻断（P-027 的 fail-open 现场）。
    ///
    /// 旧写法把 `lstat` 失败的 `nil` 当成「没有活引用」⇒ 继续删。
    func testUnreadableIdentityStateBlocksAndDoesNotProceed() {
        var called = false
        let decision = SecondCheckGate.decide(
            identityStatus: .unchanged,
            identityState: .unreadable(errno: 13),
            isLiveHeld: { _ in
                called = true
                return false
            }
        )
        XCTAssertEqual(decision, .blocked(.unreadable(errno: 13)))
        XCTAssertFalse(called, "拿不到身份时无从查表，不该做活引用判定")
        if case .proceed = decision {
            XCTFail("取不到身份时不得放行删除（P-027）")
        }
    }

    /// 身份复核说「还是它」，取身份时却没了 ⇒ 阻断（期间被删）。
    func testAbsentIdentityStateBlocks() {
        let decision = SecondCheckGate.decide(
            identityStatus: .unchanged,
            identityState: .absent,
            isLiveHeld: { _ in false }
        )
        XCTAssertEqual(decision, .blocked(.vanished))
    }

    /// 有活引用 ⇒ 阻断（AC-17）。
    func testLiveHeldBlocks() {
        let decision = SecondCheckGate.decide(
            identityStatus: .unchanged,
            identityState: .resolved(identity),
            isLiveHeld: { _ in true }
        )
        XCTAssertEqual(decision, .blocked(.liveHeld))
    }

    /// 一切正常 ⇒ **放行**（闸不能修成恒真）。
    func testUnchangedAndNotHeldProceeds() {
        let decision = SecondCheckGate.decide(
            identityStatus: .unchanged,
            identityState: .resolved(identity),
            isLiveHeld: { _ in false }
        )
        XCTAssertEqual(decision, .proceed)
    }

    // MARK: - 原因串写实情

    /// 「读不到」的原因串必须写**读不到**，不得写「已不存在」。
    ///
    /// 这是举证链（AC-18）不失真的关键：假事实比没有事实更糟。
    func testUnreadableReasonStatesUnreadableNotVanished() {
        let reason = SecondCheckGate.BlockReason.unreadable(errno: 13).blockedReason
        XCTAssertTrue(reason.contains("无法读取"), "原因串必须写明读不到：\(reason)")
        XCTAssertTrue(reason.contains("EACCES"), "原因串必须带上 errno：\(reason)")
        XCTAssertFalse(reason.contains("已不存在"), "读不到不得写成「已不存在」：\(reason)")
    }

    /// 「确定不存在」的原因串保持原样（不回归）。
    func testVanishedReasonKeepsOriginalWording() {
        XCTAssertEqual(
            SecondCheckGate.BlockReason.vanished.blockedReason,
            "二次检查：文件已不存在（已自行删除）"
        )
    }
}
