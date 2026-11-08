import XCTest
@testable import ResidueCore

// ============================================================
// AC-10 的采集开关 + 偏好持久化
//
// ## 为什么这条判据值得单独一组测试
//
// 它看起来只是一行布尔表达式，但**三个状态各自对应契约里不同的要求**，
// 而写错的后果分成两类，都很严重：
//
// | 写错的形态 | 后果 |
// |---|---|
// | 观察期就停采集 | **产品锁死**：永远攒不够样本 → 永远点不亮自动删除 |
// | 关闭后还采集 | 违反 AC-10 的 Then（关闭自动删除后所有采集停止） |
// | 「未采集」与「已停止」不分 | 对新用户**说谎**（他从未启用过，界面却说「你把它停了」） |
// ============================================================

final class CollectionPolicyTests: XCTestCase {

    // MARK: - 一、采集是否允许

    /// **从未启用过 → 必须允许采集**（否则产品锁死）。
    func testObservationPeriodCollects() {
        XCTAssertTrue(
            CollectionPolicy.isCollectionAllowed(
                autoDeleteEnabled: false,
                everEnabledAutoDelete: false
            ),
            "观察期必须采集——否则永远攒不够样本、永远点不亮，产品锁死"
        )
    }

    /// **已启用 → 采集**。
    func testEnabledCollects() {
        XCTAssertTrue(
            CollectionPolicy.isCollectionAllowed(
                autoDeleteEnabled: true,
                everEnabledAutoDelete: true
            )
        )
    }

    /// **曾启用、现已关闭 → 不采集**（AC-10 的 Then）。
    func testStoppedAfterBeingEnabled() {
        XCTAssertFalse(
            CollectionPolicy.isCollectionAllowed(
                autoDeleteEnabled: false,
                everEnabledAutoDelete: true
            ),
            "AC-10：关闭自动删除后定时任务不跑采集、仅按 N3 保留配置"
        )
    }

    /// **「已启用但 never 标记为 false」这个不可能态要能自我兜底。**
    ///
    /// 它不该出现（启用时一定会置位），但如果偏好文件被删了而
    /// `state.residue` 还在，就会落到这个组合。此时**必须采集**
    /// （宁可变回观察期，也不能让产品静默停摆）。
    func testEnabledButNoHistoryStillCollects() {
        XCTAssertTrue(
            CollectionPolicy.isCollectionAllowed(
                autoDeleteEnabled: true,
                everEnabledAutoDelete: false
            ),
            "偏好丢失时宁可退回观察期行为，不可静默停采集"
        )
    }

    // MARK: - 二、「未采集」与「已停止」必须分开

    /// **从未启用 → 不是「已停止」**。
    ///
    /// 这条防的是「界面说谎」：新用户从未启用过自动删除，
    /// 四档显示「已停止」会让他以为「我关了什么」。
    func testNeverEnabledIsNotStopped() {
        XCTAssertFalse(
            CollectionPolicy.shouldShowStopped(
                autoDeleteEnabled: false,
                everEnabledAutoDelete: false
            ),
            "从未启用不该显示「已停止」——那是说一件没发生的事"
        )
    }

    /// **曾启用后关闭 → 是「已停止」**（AC-10 的四档状态位）。
    func testStoppedOnlyAfterEverEnabled() {
        XCTAssertTrue(
            CollectionPolicy.shouldShowStopped(
                autoDeleteEnabled: false,
                everEnabledAutoDelete: true
            )
        )
        XCTAssertFalse(
            CollectionPolicy.shouldShowStopped(
                autoDeleteEnabled: true,
                everEnabledAutoDelete: true
            ),
            "开着的时候不是「已停止」"
        )
    }

    /// **两个函数在当前值域内数值等价 —— 这一点必须如实写清。**
    ///
    /// ## 一条自我纠正
    /// 我原本写的断言是「两者不等价」，并用「从未启用」这个状态举例。
    /// **那条断言是错的**：在所有四个组合（含不可能的 `(true, false)`）里，
    /// `shouldShowStopped` 恰好都等于 `!isCollectionAllowed`。
    ///
    /// 所以「保留两个函数」**不是因为它们在数值上不同**，而是因为：
    /// 1. **语义不同**：一个回答「要不要采集」，一个回答「状态标签显示什么」；
    ///    调用处读起来不会把两件事混在一起
    /// 2. **将来加第三个状态时会分叉**：若加入「暂停」，
    ///    「暂停」应当 `allowed == false` 而 `stopped == false`
    ///    —— 那时若两处共用 `!allowed` 就会静默显示错的标签
    ///
    /// 本用例钉住的是**当前的等价关系**（这样一旦有人改了一个忘了另一个，
    /// 测试会立刻失败），而不是假装它们不同。
    func testStoppedEqualsNotAllowedInCurrentDomain() {
        let combos: [(Bool, Bool)] = [(false, false), (true, true), (false, true), (true, false)]
        for (enabled, ever) in combos {
            let allowed = CollectionPolicy.isCollectionAllowed(
                autoDeleteEnabled: enabled, everEnabledAutoDelete: ever
            )
            let stopped = CollectionPolicy.shouldShowStopped(
                autoDeleteEnabled: enabled, everEnabledAutoDelete: ever
            )
            XCTAssertEqual(
                stopped, !allowed,
                "当前值域内两者应互为反面（enabled=\(enabled), ever=\(ever)）；"
                + "若这条失败，说明有人只改了一个函数——两处必须同步"
            )
        }
        // 但语义上的关键区别仍要单独钉住：
        XCTrueNeverEnabledIsNotStopped()
    }

    /// 辅助：从未启用时必须「允许采集」且「不显示已停止」。
    private func XCTrueNeverEnabledIsNotStopped() {
        XCTAssertTrue(
            CollectionPolicy.isCollectionAllowed(
                autoDeleteEnabled: false, everEnabledAutoDelete: false
            )
        )
        XCTAssertFalse(
            CollectionPolicy.shouldShowStopped(
                autoDeleteEnabled: false, everEnabledAutoDelete: false
            ),
            "从未启用显示「已停止」会对新用户说谎"
        )
    }

    // MARK: - 三、四档状态位（AC-10 判定：四档逐一「已停止」）

    private func makeHeader(autoDeleteEnabled: Bool = false) -> StateHeader {
        StateHeader(
            schemaVersion: 1,
            appVersion: "0.1.0",
            round: 1,
            roundStartAnchor: nil,
            countedDays: 0,
            countedDaysCap: 14,
            autoDeleteEnabled: autoDeleteEnabled,
            lastScanAt: nil,
            sources: Source.allCases.map { src in
                SourceHeaderEntry(source: src)
            },
            settlement: SettlementHeader(),
            bytes: ByteCounts()
        )
    }

    /// **关闭自动删除后，四档全部「已停止」**——含原本默认关的后两档。
    ///
    /// AC-10 判定原文：「四档状态位均为「已停止」」。
    /// 后两档不是「未采集」，因为它们此刻的状态是**被停止**，不是**从未开始**。
    func testAllFourTiersShowStopped() {
        let m = PageModelBuilder.build(
            PageModelBuilder.Input(
                contents: StateFileContents(header: makeHeader(), segments: [], payloads: [:], fileLength: 0),
                autoDeleteEnabled: false,
                autoDeleteEverEnabled: true
            )
        )
        XCTAssertEqual(m.collectionTiers.count, 4)
        for tier in m.collectionTiers {
            XCTAssertEqual(
                tier.state.displayText, "已停止",
                "四档「\(tier.name)」应显示「已停止」（AC-10 判定：四档状态逐一）"
            )
        }
    }

    /// **从未启用过时，四档是「未采集 / 运行中」，不是「已停止」。**
    func testNeverEnabledTiersAreNotStopped() {
        let m = PageModelBuilder.build(
            PageModelBuilder.Input(
                contents: StateFileContents(header: makeHeader(), segments: [], payloads: [:], fileLength: 0),
                autoDeleteEnabled: false,
                autoDeleteEverEnabled: false
            )
        )
        XCTAssertEqual(m.collectionTiers[0].state.displayText, "运行中", "前两档默认开")
        XCTAssertEqual(m.collectionTiers[1].state.displayText, "运行中")
        XCTAssertEqual(m.collectionTiers[2].state.displayText, "未采集", "后两档默认关")
        XCTAssertEqual(m.collectionTiers[3].state.displayText, "未采集")
        for tier in m.collectionTiers {
            XCTAssertNotEqual(tier.state.displayText, "已停止", "从未启用不该出现「已停止」")
        }
    }

    // MARK: - 四、偏好持久化

    /// **偏好存取往返**，且「只增不减」的语义由调用方保证（这里只验 IO）。
    func testPreferencesRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("residue-prefs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let store = PreferencesStore(directory: dir)
        // 首次读取：默认值
        XCTAssertFalse(store.load().everEnabledAutoDelete)
        // 写入
        XCTAssertTrue(store.save(Preferences(everEnabledAutoDelete: true)))
        // 再读：已生效
        XCTAssertTrue(store.load().everEnabledAutoDelete)
        // fileURL 必须落在 state 目录下（不是别处）
        XCTAssertEqual(store.fileURL.lastPathComponent, "preferences.json")
        XCTAssertEqual(store.fileURL.deletingLastPathComponent().path, dir.path)
    }

    /// **偏好文件损坏时返回默认值，不抛错。**
    ///
    /// 理由：偏好丢失只影响「已停止 / 未采集」的显示精度，
    /// 而抛出去会让整个 App 起不来。**为了一个显示精度让产品打不开，不值得。**
    func testCorruptPreferencesFallsBackToDefault() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("residue-prefs-bad-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let store = PreferencesStore(directory: dir)
        try Data("not json at all {{{".utf8).write(to: store.fileURL)
        XCTAssertFalse(
            store.load().everEnabledAutoDelete,
            "损坏的偏好文件应退回默认值，而不是让 App 起不来"
        )
    }
}
