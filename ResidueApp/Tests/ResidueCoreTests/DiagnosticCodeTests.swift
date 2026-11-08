import XCTest
@testable import ResidueCore

// ============================================================
// 诊断码表的契约测试
//
// ## 这些测试要钉住的不是「代码能跑」，是 R2 §6 的四条契约
//
// 1. **码集合封闭且与 §6 一致**（多一个少一个都要失败）
// 2. **一个码只有一种归类**（§8 的封闭分类不得被打破）
// 3. **无权限类必须给授权指引**（AC-14 三要素）
// 4. **`E-101` / `E-108` 的二分必须由真实 errno 驱动**
//    —— 只测枚举等于没测：`classify` 若恒返回 `pathNotFound`，
//    枚举测试照样全绿，而 AC-14 第一类仍然永远不出现。
// ============================================================

final class DiagnosticCodeTests: XCTestCase {

    // MARK: - 一、码集合与 §6 一致

    /// **§6 的全部码，一个不多一个不少。**
    ///
    /// 这条断言的作用：以后有人加码/删码，必须同时改这里——
    /// 于是「码表变了」这件事无法悄悄发生。
    /// 原状态是相反的一面：**码只活在注释里，改了没人知道**。
    func testCodeSetMatchesSpec() {
        let expected: Set<String> = [
            "E-101", "E-102", "E-103", "E-104", "E-105", "E-106", "E-107", "E-108",
            "E-201", "E-202", "E-203", "E-204", "E-205", "E-206", "E-207",
            "E-301", "E-302", "E-303", "E-304", "E-305", "E-306", "E-308",
            "E-401", "E-501",
        ]
        let actual = Set(DiagnosticCode.allCases.map(\.rawValue))
        XCTAssertEqual(actual, expected, "码集合必须与 R2 §6 完全一致")
        XCTAssertEqual(DiagnosticCode.allCases.count, 24)
    }

    /// **`E-307` 与 `E-205` 的区别要留痕。**
    ///
    /// `E-307` 在 §6 里是跳号（不存在），本码表也不该有。
    /// `E-205` 曾经被我判成死码删除，后来发现它在**恢复**路径上是活的
    /// （原路径被占用）→ 已恢复。这条断言防的是「有人又把它当死码删掉」。
    func testNoGapCodeAndE205Exists() {
        XCTAssertNil(DiagnosticCode(rawValue: "E-307"), "E-307 在 §6 里是跳号，不得存在")
        XCTAssertNotNil(
            DiagnosticCode(rawValue: "E-205"),
            "E-205「同名冲突无法消解」在恢复路径上是活的（原路径被占用），不得删"
        )
    }

    // MARK: - 二、归类唯一且符合 §8

    /// **每个码的归类是确定的**（不是按入参变化的函数）。
    ///
    /// 这条看起来是废话，但它排除了「`E-101` 按成因返回不同归类」那种写法——
    /// 那会让「码 ↔ 归类」不再是函数，用例无法预期。
    func testCategoryIsDeterministic() {
        for code in DiagnosticCode.allCases {
            let a = code.category
            let b = code.category
            XCTAssertEqual(a, b, "\(code.rawValue) 的归类必须确定")
        }
    }

    /// **`E-204`（越界 / 符号链接）不得归「无权限」。**
    ///
    /// §6 原文：「不属 §8 封闭的三类 OS 权限受阻，不得归「无权限」」。
    /// 它读起来也像「不让做」，所以很容易被误归——这正是要机器断言的原因。
    func testOutOfScopeIsNotPermission() {
        XCTAssertEqual(DiagnosticCode.e204.category, .error)
        XCTAssertFalse(
            DiagnosticCode.e204.requiresAuthorizationGuide,
            "越界是**安全拒绝**，给授权指引等于让用户去授权一件产品本就不该做的事"
        )
    }

    /// **AC-14 的三类受阻必须各有一个「无权限」码。**
    ///
    /// 三类：来源不可读 / 废纸篓不可写 / 同 uid fd 枚举失败
    /// → `E-108` / `E-202` / `E-501`
    func testAC14ThreeBlockTypesHavePermissionCodes() {
        let blocks = [DiagnosticCode.e108, .e202, .e501]
        for code in blocks {
            XCTAssertEqual(code.category, .noPermission, "\(code.rawValue) 应归无权限")
            XCTAssertTrue(
                code.requiresAuthorizationGuide,
                "\(code.rawValue) 必须要求「所缺权限 + 授权指引条目 ID」三要素"
            )
        }
        // **反向**：所有要求授权指引的码，都必须真归无权限
        for code in DiagnosticCode.allCases where code.requiresAuthorizationGuide {
            XCTAssertEqual(
                code.category, .noPermission,
                "\(code.rawValue) 要求授权指引，却不归无权限——归类与要求不一致"
            )
        }
    }

    /// **`E-101` 与 `E-108` 必须归不同类。**
    ///
    /// 这是二分的目的：`ENOENT` 是「去找路径」，`EACCES` 是「去授权」。
    /// 归成一类时 AC-14 第一类的指引永远不会出现。
    func testE101AndE108HaveDifferentCategories() {
        XCTAssertEqual(DiagnosticCode.e101.category, .error, "路径不存在 = 错误（去检查路径）")
        XCTAssertEqual(DiagnosticCode.e108.category, .noPermission, "读不到 = 无权限（去授权）")
        XCTAssertNotEqual(DiagnosticCode.e101.category, DiagnosticCode.e108.category)

        // 动作也必须指向不同的出路：E-101 去检查路径，E-108 去授权。
        // 若两者的动作写成同一句，二分就只改了归类，没改用户看到的东西。
        let notFoundAction = DiagnosticCode.e101.suggestedAction ?? ""
        let deniedAction = DiagnosticCode.e108.suggestedAction ?? ""
        XCTAssertTrue(
            notFoundAction.contains("路径"),
            "E-101 的动作应指向检查路径，实为「\(notFoundAction)」"
        )
        XCTAssertFalse(
            notFoundAction.contains("授权"),
            "E-101（路径不存在）不得引导去授权——授权解决不了路径变了的问题"
        )
        XCTAssertTrue(
            deniedAction.contains("权限") || deniedAction.contains("允许"),
            "E-108 的动作应指向授权，实为「\(deniedAction)」"
        )
    }

    // MARK: - 三、文案与动作完整性

    /// **每个码都有用户可见的一句话**（不能是空串）。
    func testEveryCodeHasSummary() {
        for code in DiagnosticCode.allCases {
            XCTAssertFalse(
                code.summary.isEmpty,
                "\(code.rawValue) 缺用户可见文案"
            )
        }
    }

    /// **凡要求授权指引的码，都必须给可执行动作。**
    ///
    /// 逻辑：告诉用户「你缺权限」却不说「去哪给」，等于只说了一半。
    /// 视觉基线 §三：错误态必须给可执行动作。
    func testPermissionCodesHaveAction() {
        for code in DiagnosticCode.allCases where code.requiresAuthorizationGuide {
            XCTAssertNotNil(
                code.suggestedAction,
                "\(code.rawValue) 是无权限类，必须有可执行动作（否则用户知道缺权限但不知去哪授权）"
            )
        }
    }

    /// **`E-303`（磁盘满）的动作必须提到「释放 / 清理」**——这是它的语义。
    func testDiskFullActionIsSpecific() {
        let action = DiagnosticCode.e303.suggestedAction ?? ""
        XCTAssertTrue(
            action.contains("释放") || action.contains("清理"),
            "磁盘满的动作必须指向释放空间，实为「\(action)」"
        )
    }

    /// **`E-301`（schema 更高）的动作必须指向「装回更高版本」**。
    ///
    /// 这条容易写错成「重置数据」——那是 §6 明令禁止的默认出路
    /// （重置会清零 L0 误判记录，等于给自动删除放行）。
    func testSchemaTooNewActionDoesNotSuggestReset() {
        let action = DiagnosticCode.e301.suggestedAction ?? ""
        XCTAssertTrue(action.contains("更高版本"), "应指向装回更高版本，实为「\(action)」")
        XCTAssertFalse(action.contains("重置"), "不得引导重置（会清零 a，等于给自动删除放行）")
    }

    // MARK: - 四、二分必须由真实 errno 驱动
    //
    // 这一组是**本次改动的核心**：只测枚举等于没测。

    /// **`EACCES` → `E-108`（无权限）。用真实目录权限复现。**
    ///
    /// 造法：建一个目录，`chmod 000`，然后 `contentsOfDirectory` → 必得 `EACCES`。
    /// 判据不是「抛了错」，而是「**抛的是无权限那一支**」。
    func testClassifyEACCESAsDenied() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("residue-code-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            // 先把权限还回来，否则删不掉
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)

        // 复现一次真实的读取失败
        var caught: Error?
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: root.path)
        } catch {
            caught = error
        }
        let error = try XCTUnwrap(caught, "chmod 000 后读取应失败")
        let classified = ScanEngine.ScanError.classify(path: root.path, error: error)

        XCTAssertEqual(
            classified, .pathDenied(root.path),
            "EACCES 必须归 pathDenied（E-108，无权限）；若归 pathNotFound，AC-14 第一类永远不出现"
        )
        XCTAssertEqual(classified.diagnostic, .e108)
        XCTAssertEqual(classified.diagnostic.category, .noPermission)
    }

    /// **`ENOENT` → `E-101`（错误）。**
    func testClassifyENOENTAsNotFound() {
        let missing = "/tmp/residue-definitely-not-here-\(UUID().uuidString)"
        var caught: Error?
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: missing)
        } catch {
            caught = error
        }
        guard let error = caught else {
            return XCTFail("读取不存在的路径应失败")
        }
        let classified = ScanEngine.ScanError.classify(path: missing, error: error)
        XCTAssertEqual(classified, .pathNotFound(missing))
        XCTAssertEqual(classified.diagnostic, .e101)
        XCTAssertEqual(classified.diagnostic.category, .error)
    }

    /// **未知 `errno` 按「错误」处理，不报「无权限」。**
    ///
    /// 理由：我们只知道「读不到」，不知道成因。报无权限会引导用户去授权，
    /// 而授权可能解决不了（如 `ENOTDIR`）——**给错指引比不给更糟**。
    func testClassifyUnknownErrnoFallsBackToError() {
        let fake = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR))
        let classified = ScanEngine.ScanError.classify(path: "/tmp/x", error: fake)
        XCTAssertEqual(classified, .pathNotFound("/tmp/x"))
        XCTAssertEqual(
            classified.diagnostic.category, .error,
            "未知 errno 不得判为无权限（那会让用户去授权，而授权解决不了）"
        )
    }

    // MARK: - 五、错误类型的映射完整性

    /// **每个 `StateFileError` 都有码，且码属于 3xx 段。**
    func testStateFileErrorMapping() {
        let cases: [(StateFileError, DiagnosticCode)] = [
            (.schemaTooNew(found: 2, supported: 1), .e301),
            (.corruptNoBackup(detail: "x"), .e302),
            (.writeFailed(detail: "x"), .e303),
            (.segmentValidationFailed(detail: "x"), .e304),
            (.migrationSpaceInsufficient(requiredBytes: 1, availableBytes: 0), .e305),
            (.migrationRestoreFailed(detail: "x"), .e306),
            (.restoredFromBackup, .e308),
        ]
        for (err, expected) in cases {
            XCTAssertEqual(err.diagnostic, expected)
            XCTAssertTrue(
                err.diagnostic.rawValue.hasPrefix("E-3"),
                "状态载体错误应落在 3xx 段"
            )
        }
    }

    /// **`RestoreError` 的映射**：原路径被占 → `E-205`；源没了 → `E-201`。
    func testRestoreErrorMapping() {
        XCTAssertEqual(TrashExecutor.RestoreError.originalPathOccupied.diagnostic, .e205)
        XCTAssertEqual(TrashExecutor.RestoreError.noRestorePath.diagnostic, .e201)
        XCTAssertEqual(TrashExecutor.RestoreError.goneFromTrash.diagnostic, .e201)
        // E-205 必须归「错误」而不是「并发冲突」：它不是并发问题，
        // 是用户在原位置装了新东西，重试一百次也一样
        XCTAssertEqual(
            TrashExecutor.RestoreError.originalPathOccupied.diagnostic.category, .error,
            "原路径被占不是并发冲突——重试不会好，是用户要在两个东西里选一个"
        )
    }
}
