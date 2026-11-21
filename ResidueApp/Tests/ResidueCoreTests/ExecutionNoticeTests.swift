import XCTest
@testable import ResidueCore

// ============================================================
// ExecutionNotice · 清理结果反馈（"点了必须有反应"）
//
// ## 为什么这组测试值得存在
//
// 原先执行完只更新 `lastExecutionAt`，界面上什么都不变。用户点了确认、
// 回到原样，不知道删了几条、有没有失败。`outcome.failures` 更是直接丢弃。
//
// 这条反馈是**用户唯一能得知「刚刚发生了什么」的通道**，而它的文案
// 在 Core 拼接（界面不做算术）。文案错了 = 用户在读一个假的结果。
//
// ## 最容易写错的两处
//
// 1. **`didNothing` 的两种成因**：「被拦下」与「上限顺延」是完全不同的事
//    （前者文件变了/被占用，后者只是这批没轮到）。混为一谈会让用户
//    以为自己的文件「不存在了」。
// 2. **字节格式化**必须走 `MetricUnit.formatBytes`（与全站同一口径），
//    不能自己拼 GB/MB。
// ============================================================

final class ExecutionNoticeTests: XCTestCase {

    override func tearDown() {
        L.current = .zhHans
        super.tearDown()
    }

    private func make(
        deleted: Int = 0, bytes: Int64 = 0,
        deferred: Int = 0, failed: Int = 0, blocked: Int = 0
    ) -> PageModel.ExecutionNotice {
        PageModel.ExecutionNotice(
            deletedCount: deleted, deletedBytes: bytes,
            deferredCount: deferred, failedCount: failed, blockedCount: blocked
        )
    }

    // MARK: - didNothing

    func testDidNothingWhenNoDeletion() {
        XCTAssertTrue(make().didNothing)
        XCTAssertTrue(make(deferred: 5).didNothing, "只有顺延 = 什么都没删")
        XCTAssertTrue(make(blocked: 3).didNothing, "只有拦下 = 什么都没删")
    }

    func testDidSomethingWhenDeleted() {
        XCTAssertFalse(make(deleted: 1).didNothing)
    }

    // MARK: - 文案：什么都没删

    /// **被拦下**的文案要说清「文件已变化或正在被使用」——
    /// 这与「没轮到」是两件事，不能共用一句。
    func testBlockedOnlyExplainsReason() {
        let text = make(blocked: 3).summary
        XCTAssertTrue(text.contains("3"), "必须给出被拦下的条数：\(text)")
        XCTAssertTrue(
            text.contains("拦下") || text.contains("变化") || text.contains("使用"),
            "必须说明是执行前检查拦下的：\(text)"
        )
    }

    /// 纯顺延的文案不得声称「文件被拦下」（那是另一回事）。
    func testDeferredOnlyDoesNotClaimBlocked() {
        let text = make(deferred: 7).summary
        XCTAssertFalse(text.contains("拦下"), "纯顺延不该说被拦下：\(text)")
    }

    // MARK: - 文案：删了东西

    func testDeletedSummaryIncludesCountAndBytes() {
        let text = make(deleted: 5, bytes: 1_500_000).summary
        XCTAssertTrue(text.contains("5"), "必须给出条数：\(text)")
        XCTAssertTrue(
            text.contains(MetricUnit.formatBytes(1_500_000)),
            "字节必须走全站同一格式化：\(text)"
        )
    }

    /// CR-042：删了东西 ≠ 磁盘腾出来了 —— 摘要必须说明条目还在废纸篓里。
    ///
    /// 本产品只做 rename，用户看到「已移入废纸篓」很容易读成「已释放」。
    func testDeletedSummarySaysSpaceNotFreedYet() {
        let text = make(deleted: 5, bytes: 1_500_000).summary
        XCTAssertTrue(text.contains("回收站"), "必须点明条目仍在回收站：\(text)")
        XCTAssertTrue(text.contains("未") || text.contains("尚未"), "必须说明尚未释放：\(text)")

        L.current = .en
        let en = make(deleted: 5, bytes: 1_500_000).summary
        XCTAssertTrue(en.contains("Trash"), "英文也要点明仍在回收站：\(en)")
        XCTAssertTrue(en.contains("not freed"), "英文也要说明尚未释放：\(en)")
    }

    /// 有顺延 / 拦下 / 失败时，各自都要出现在摘要里（不吞信息）。
    func testAllCountsAppearInSummary() {
        let text = make(deleted: 2, bytes: 1000, deferred: 3, failed: 1, blocked: 4).summary
        XCTAssertTrue(text.contains("2"))
        XCTAssertTrue(text.contains("3"))
        XCTAssertTrue(text.contains("1"))
        XCTAssertTrue(text.contains("4"))
    }

    /// 英文环境下同样不吞信息，且不残留中文标点拼接。
    func testEnglishSummaryHasAllCounts() {
        L.current = .en
        let text = make(deleted: 2, bytes: 1000, deferred: 3, failed: 1, blocked: 4).summary
        XCTAssertTrue(text.contains("2"))
        XCTAssertTrue(text.contains("3"))
        XCTAssertTrue(text.contains("1"))
        XCTAssertTrue(text.contains("4"))
        XCTAssertFalse(text.contains("顺延"), "英文环境不得残留中文：\(text)")
    }
}
