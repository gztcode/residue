import XCTest
@testable import ResidueCore

/// 「应用版本变更 → 是否清零载体」的判定（CR-032 · P1-1）。
///
/// ## 这个判定为什么必须有单测
///
/// 它原本写在 `AppModel`（界面编排层），而**单测只覆盖 `ResidueCore`**
/// → 写在 AppModel 的判定**无法被单测覆盖** → 于是它在真实升级场景下
/// 从未生效过也没人发现（`!stored.isEmpty` 恒假）。
///
/// 现在判定下沉到 Core，判据的每一格都有断言。
final class VersionChangePolicyTests: XCTestCase {

    /// **首启**（载体不在）→ **不清零**。
    ///
    /// 清零 = 把「什么都没有」当成「变了」→ 首启就无意义地写一次盘。
    func testFirstLaunchDoesNotReset() {
        XCTAssertFalse(
            VersionChangePolicy.shouldResetCarrier(
                carrierPresent: false,
                storedVersion: "",
                currentVersion: "1.2.0",
                readOnly: false
            ),
            "首启不是版本变更"
        )
    }

    /// **基线遗留**（载体在、版本号为空）→ **必须清零**。
    ///
    /// 这是 P1-1 的核心：基线从未写过 `appVersion`，
    /// 旧判据 `!stored.isEmpty` 因此恒假 → 重置路径**一次都没走过**。
    func testLegacyCarrierWithEmptyVersionIsTreatedAsVersionChange() {
        XCTAssertTrue(
            VersionChangePolicy.shouldResetCarrier(
                carrierPresent: true,
                storedVersion: "",
                currentVersion: "1.2.0",
                readOnly: false
            ),
            "基线遗留载体（从未写版本号）必须按版本变更处理"
        )
    }

    /// **正常升级**（版本号不同）→ 清零。
    func testDifferentVersionResets() {
        XCTAssertTrue(
            VersionChangePolicy.shouldResetCarrier(
                carrierPresent: true,
                storedVersion: "1.0.0",
                currentVersion: "1.2.0",
                readOnly: false
            )
        )
    }

    /// **版本未变** → 不清零。
    func testSameVersionDoesNotReset() {
        XCTAssertFalse(
            VersionChangePolicy.shouldResetCarrier(
                carrierPresent: true,
                storedVersion: "1.2.0",
                currentVersion: "1.2.0",
                readOnly: false
            ),
            "版本没变就不该重置（否则每次启动都丢一次观察期）"
        )
    }

    /// **只读降级态 → 不清零**。
    ///
    /// 降级路径的契约是「只读、不拒绝、不重置」（`E-301` / `E-302` / `E-304`）。
    func testReadOnlyNeverResets() {
        for stored in ["", "1.0.0"] {
            XCTAssertFalse(
                VersionChangePolicy.shouldResetCarrier(
                    carrierPresent: true,
                    storedVersion: stored,
                    currentVersion: "1.2.0",
                    readOnly: true
                ),
                "只读降级态不得写入（stored=\(stored.isEmpty ? "空" : stored)）"
            )
        }
    }
}
