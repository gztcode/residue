import XCTest
@testable import ResidueCore

/// 多语言选择与取词。
///
/// 这一层之所以要有单测，是因为**默认语言写死 `zhHans`** 是刻意的：
/// 如果它跟着机器语言走，同一份代码在 CI（en_US）与本地（zh_CN）会得到不同文案，
/// 而 276 个断言中文契约文案的测试会因此「看机器脸色」。
/// 这里的测试把「默认值确定」这件事钉住。
final class LocalizationTests: XCTestCase {

    override func tearDown() {
        // 全局状态必须还原，否则后面的测试会继承这里改过的语言。
        L.current = .zhHans
        super.tearDown()
    }

    func testDefaultLanguageIsDeterministic() {
        // 默认值不依赖 `Locale.preferredLanguages`
        XCTAssertEqual(L.current, .zhHans)
    }

    func testResolvePicksFirstSupportedLanguage() {
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["zh-Hans-CN"]), .zhHans)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["zh"]), .zhHans)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["en-US"]), .en)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["en"]), .en)
    }

    func testResolveSkipsUnsupportedThenUsesFirstMatch() {
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["fr-FR", "en-GB"]), .en)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["fr-FR", "zh-Hant"]), .zhHans)
    }

    func testResolveFallsBackToChineseForUnknownLanguages() {
        // 不认识的语言**不猜成英文**：回到母语是唯一不会说谎的选项。
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["fr-FR", "de-DE"]), .zhHans)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: []), .zhHans)
    }

    func testPickFollowsCurrentLanguage() {
        L.current = .zhHans
        XCTAssertEqual(L.pick("只读", "Read-only"), "只读")
        L.current = .en
        XCTAssertEqual(L.pick("只读", "Read-only"), "Read-only")
    }

    func testEnvironmentOverridesSystemLanguage() {
        L.applyEnvironment(environment: ["RESIDUE_LANG": "en"], preferredLanguages: ["zh-Hans-CN"])
        XCTAssertEqual(L.current, .en)

        L.applyEnvironment(environment: ["RESIDUE_LANG": "zh-Hans"], preferredLanguages: ["en-US"])
        XCTAssertEqual(L.current, .zhHans)
    }

    func testEmptyEnvironmentFallsBackToSystemLanguage() {
        L.applyEnvironment(environment: [:], preferredLanguages: ["en-US"])
        XCTAssertEqual(L.current, .en)

        L.applyEnvironment(environment: ["RESIDUE_LANG": ""], preferredLanguages: ["zh-Hans-CN"])
        XCTAssertEqual(L.current, .zhHans)
    }
}
