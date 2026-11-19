import XCTest
@testable import ResidueCore

// ============================================================
// CR-038 · 判定域成员指纹与观察期重置
//
// ## 这条机制防的是什么
//
// 判定域（哪些来源参与自动删除）是**门槛判定的一部分**（PRD v5.6 AC-04 ①）：
// 新增一个来源进判定域 ⇒ 那个来源的 `T` / `K` / `J` / `b` 要**重新积累 14 天**
// ⇒ 观察期凭证**必须重置**，否则会拿「新来源零观察证据」放行自动删除。
//
// ## 为什么用**指纹**而不是「版本号」
//
// 版本号是**人为约定**的：改了判定域却忘了 bump 版本 ⇒ 凭证不会重置 ⇒
// 新来源带着零观察期证据进自动删除候选集。
// 指纹是**代码算出来的**（`Source.decisionDomainSignature`）：
// 判定域成员一变，指纹就变 ⇒ 凭证自动重置。**版本号 bump 变成可选项。**
//
// ## 为什么 `a`（误判累计）在两条路径上处置不同
//
// | 触发 | `a` | 依据 |
// |---|---|---|
// | 应用版本变更 | **清零** | PRD v5.6 M4「`a` 只在应用版本变更时清零」 |
// | 判定域指纹变更 | **保留** | 同上 —— 版本没变就不是「版本变更」 |
//
// 保留 `a` 意味着 **`F` 位图 / `C_done` / 位槽占用表必须一并保留**
// （它们是 `a` 的载体）—— 否则 `a` 与载体自相矛盾。
// ============================================================

final class ObservationSignatureTests: XCTestCase {

    private var dir: URL!
    private var stateFile: StateFile!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObservationSignatureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stateFile = StateFile(directory: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: - 夹具

    /// 造一个「有观察期凭证」的载体。
    ///
    /// - Parameters:
    ///   - decisionDomainSignature: 载体里记的指纹（`nil` = 旧载体，没有这个键）。
    ///   - missCount: 每个来源的 `a`（误判累计）。
    private func saveCarrier(
        appVersion: String,
        decisionDomainSignature: String?,
        round: Int = 2,
        missCount: Int = 0,
        configure: (inout StateHeader) -> Void = { _ in }
    ) throws {
        var header = StateHeader()
        header.appVersion = appVersion
        header.decisionDomainSignature = decisionDomainSignature
        header.round = round
        header.countedDays = 14
        header.roundStartAnchor = Date(timeIntervalSince1970: 1_700_000_000)
        header.settlement = SettlementHeader(
            producedAt: Date(timeIntervalSince1970: 1_700_000_500),
            reportId: "report-1"
        )
        // ⚠️ 载荷必须**自洽**，否则 `StateFile.save` 末尾的写后回读校验会抛
        //    `segmentValidationFailed`（F 段长必须 == `ceil(slotCount/8)`）。
        //    这里造的是「位槽域 1 槽 / 槽 0 已被判过阴性 / 槽 0 已计过误判」。
        header.sources = Source.allCases.map {
            SourceHeaderEntry(
                source: $0, snapshotTaken: true,
                T: 100, K: 90, J: 10, H: 30,
                a: missCount, b: 12, slotCount: 1, doneCount: 1,
                snapshotDate: Date(timeIntervalSince1970: 1_700_000_100),
                settlementDate: Date(timeIntervalSince1970: 1_700_000_400),
                unattributableCount: 3
            )
        }
        configure(&header)

        // 载荷：`a` 的三项载体（`F` 位图 / `C_done` / 位槽占用表）+ 本轮快照成员。
        var payloads: [Source: SourcePayload] = [:]
        let identity = CandidateID(
            path: "/tmp/x",
            birthtime: Date(timeIntervalSince1970: 1_700_000_000)
        )
        for source in Source.allCases {
            payloads[source] = SourcePayload(
                bitmap: Data([0x01]),
                countedDoneSlots: [0],
                slots: [0: identity],
                snapshotMembers: [identity]
            )
        }
        try stateFile.save(header: header, payloads: payloads)
    }

    private func loadHeader() throws -> StateHeader {
        let result = stateFile.load()
        guard let c = result.contents else {
            throw XCTSkip("载体未加载：\(String(describing: result.error))")
        }
        return c.header
    }

    private func loadPayloads() throws -> [Source: SourcePayload] {
        let result = stateFile.load()
        guard let c = result.contents else {
            throw XCTSkip("载体未加载：\(String(describing: result.error))")
        }
        return c.payloads
    }

    // MARK: - 策略层（纯函数）

    /// **首启不重置**：载体里没有版本号 ⇒ 没有「旧版本」可比 ⇒ 清不清都一样。
    func testPolicyReturnsNoneOnFirstLaunch() {
        let reason = ObservationResetPolicy.reason(
            storedAppVersion: "",
            currentAppVersion: "1.7.0",
            storedDecisionDomainSignature: nil,
            currentDecisionDomainSignature: Source.decisionDomainSignature
        )
        XCTAssertEqual(reason, .none, "首启不该触发重置")
    }

    /// **版本变了** ⇒ 按「应用版本变更」处置（`a` 一并清零）。
    func testPolicyReturnsAppVersionChangedWhenVersionDiffers() {
        let reason = ObservationResetPolicy.reason(
            storedAppVersion: "1.6.0",
            currentAppVersion: "1.7.0",
            storedDecisionDomainSignature: Source.decisionDomainSignature,
            currentDecisionDomainSignature: Source.decisionDomainSignature
        )
        XCTAssertEqual(reason, .appVersionChanged)
    }

    /// **版本没变但指纹变了** ⇒ 按「判定域变更」处置（保留 `a`）。
    func testPolicyReturnsDecisionDomainChangedWhenSignatureDiffers() {
        let reason = ObservationResetPolicy.reason(
            storedAppVersion: "1.7.0",
            currentAppVersion: "1.7.0",
            storedDecisionDomainSignature: "uv_cache=1|npm_npx=1",
            currentDecisionDomainSignature: Source.decisionDomainSignature
        )
        XCTAssertEqual(reason, .decisionDomainChanged)
    }

    /// **版本与指纹都一致** ⇒ 不重置（否则每次启动都把观察期打回起点 ⇒ 产品永远点不亮）。
    func testPolicyReturnsNoneWhenBothMatch() {
        let reason = ObservationResetPolicy.reason(
            storedAppVersion: "1.7.0",
            currentAppVersion: "1.7.0",
            storedDecisionDomainSignature: Source.decisionDomainSignature,
            currentDecisionDomainSignature: Source.decisionDomainSignature
        )
        XCTAssertEqual(reason, .none)
    }

    /// **版本变更优先于指纹变更** —— 前者更彻底（`a` 也清），且两者同时成立时
    /// 一次重置就够（不必写两次载体）。
    func testPolicyPrefersAppVersionChangeOverSignatureChange() {
        let reason = ObservationResetPolicy.reason(
            storedAppVersion: "1.6.0",
            currentAppVersion: "1.7.0",
            storedDecisionDomainSignature: "uv_cache=1|npm_npx=1",
            currentDecisionDomainSignature: Source.decisionDomainSignature
        )
        XCTAssertEqual(reason, .appVersionChanged)
    }

    /// **旧载体（没有指纹键）必须能被解码**，且**必须触发一次重置**。
    ///
    /// ## 为什么这条是关键的安全边界
    ///
    /// 旧版本写出的载体里**根本没有**「判定域成员指纹」这个键。
    /// 若解码失败 ⇒ 载体被判损坏（`E-304`）⇒ 进入只读 ⇒ 用户看��到任何读数。
    /// 若解码成功但**不触发重置** ⇒ 旧凭证（对应旧判定域）被新判定域继承 ⇒
    /// 新来源带着零观察证据进自动删除候选集 ⇒ **误删**。
    ///
    /// ⇒ 旧载体必须「能读 + 必重置」。
    func testLegacyCarrierWithoutSignatureDecodesAndTriggersReset() throws {
        try saveCarrier(appVersion: "1.6.0", decisionDomainSignature: nil)

        // ① 能解码
        let after = try loadHeader()
        XCTAssertNil(
            after.decisionDomainSignature,
            "旧载体没有指纹键 ⇒ 解码后应为 nil（不是解码失败）"
        )
        XCTAssertEqual(after.countedDays, 14, "前置：旧载体的观察期凭证在位")

        // ② 必触发重置
        let reason = ObservationResetPolicy.reason(
            storedAppVersion: after.appVersion,
            currentAppVersion: after.appVersion,
            storedDecisionDomainSignature: after.decisionDomainSignature,
            currentDecisionDomainSignature: Source.decisionDomainSignature
        )
        XCTAssertEqual(
            reason, .decisionDomainChanged,
            "旧载体无指纹 ⇒ 无法证明判定域未变 ⇒ 必须重置"
        )
    }

    /// **`nil` 指纹不写出 JSON 键** —— 这就是「旧载体字节等价」的根据。
    ///
    /// Swift 合成 `Codable` 对可选属性用 `encodeIfPresent` ⇒ `nil` 不写键。
    /// ⇒ 「没有这个键的旧载体」与「这个键为 nil 的新载体」**解码后完全不可区分**。
    func testHeaderWithoutSignatureOmitsTheKey() throws {
        var header = StateHeader()
        header.decisionDomainSignature = nil
        header.appVersion = "1.6.0"

        let data = try JSONEncoder().encode(header)
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNil(
            obj["decisionDomainSignature"],
            "nil 可选属性不该写出键（否则与旧载体的字节就不等价了）"
        )
        XCTAssertNotNil(obj["appVersion"], "其它键照常写出")
    }

    // MARK: - 载体层：指纹变更 ⇒ 观察期凭证重置

    /// **指纹不一致 ⇒ 观察期凭证重置**（计数日归零、`T`/`K`/`J`/`b` 清零）。
    func testSignatureMismatchResetsObservationCredentials() throws {
        try saveCarrier(appVersion: "1.7.0", decisionDomainSignature: "uv_cache=1|npm_npx=1")

        try stateFile.clearCarrierForObservationReset(
            newAppVersion: "1.7.0",
            newDecisionDomainSignature: Source.decisionDomainSignature,
            preservingMissCount: true,
            preservedRound: 2
        )

        let after = try loadHeader()
        XCTAssertEqual(after.countedDays, 0, "本轮计数日必须归零")
        XCTAssertNil(after.roundStartAnchor, "起算点必须重置")
        XCTAssertNil(after.settlement.producedAt, "结算凭证必须清零")
        XCTAssertEqual(
            after.decisionDomainSignature, Source.decisionDomainSignature,
            "指纹必须更新为当前值（否则下次启动又判一次变更）"
        )
        for entry in after.sources {
            XCTAssertNil(entry.T, "\(entry.source) 的 T 必须回到「未取快照」")
            XCTAssertNil(entry.K, "\(entry.source) 的 K 必须回到「未结算」")
            XCTAssertNil(entry.J, "\(entry.source) 的 J 必须回到「未结算」")
            XCTAssertEqual(entry.b, 0, "\(entry.source) 的 b 必须归零")
            XCTAssertFalse(entry.snapshotTaken, "\(entry.source) 的快照标志必须清零")
        }
    }

    /// **指纹变更 ⇒ `a` 保留**（PRD v5.6 M4：「`a` 只在应用版本变更时清零」）。
    ///
    /// 判错过一次的来源，判错这件事**不会因为判定域变了就变成没发生过**。
    func testSignatureMismatchPreservesMissCount() throws {
        try saveCarrier(appVersion: "1.7.0", decisionDomainSignature: "uv_cache=1|npm_npx=1", missCount: 2)

        try stateFile.clearCarrierForObservationReset(
            newAppVersion: "1.7.0",
            newDecisionDomainSignature: Source.decisionDomainSignature,
            preservingMissCount: true,
            preservedRound: 2
        )

        for entry in try loadHeader().sources {
            XCTAssertEqual(entry.a, 2, "\(entry.source) 的 a 必须保留（版本未变）")
        }
    }

    /// **保留 `a` ⇒ 必须保留 `a` 的三项载体**（`F` 位图 / `C_done` / 位槽占用表）。
    ///
    /// 否则 `a = 2` 而位图是空的 ⇒ 头与载荷自相矛盾 ⇒ 误判记录凭空消失。
    func testSignatureMismatchPreservesMissCountCarriers() throws {
        try saveCarrier(appVersion: "1.7.0", decisionDomainSignature: "uv_cache=1|npm_npx=1", missCount: 2)

        try stateFile.clearCarrierForObservationReset(
            newAppVersion: "1.7.0",
            newDecisionDomainSignature: Source.decisionDomainSignature,
            preservingMissCount: true,
            preservedRound: 2
        )

        let payloads = try loadPayloads()
        for source in Source.allCases {
            let payload = try XCTUnwrap(payloads[source], "\(source) 的载荷必须仍在")
            XCTAssertEqual(
                payload.bitmap, Data([0x01]),
                "\(source) 的 F 位图必须保留（它是 a 的载体）"
            )
            XCTAssertEqual(payload.countedDoneSlots, [0], "\(source) 的 C_done 必须保留")
            XCTAssertEqual(payload.slots.count, 1, "\(source) 的位槽占用表必须保留")
        }
    }

    /// **保留 `a` ⇒ 本轮快照成员集合要清**（`T` 重取 ⇒ 旧成员不再属于新快照）。
    func testSignatureMismatchClearsSnapshotMembers() throws {
        try saveCarrier(appVersion: "1.7.0", decisionDomainSignature: "uv_cache=1|npm_npx=1")

        try stateFile.clearCarrierForObservationReset(
            newAppVersion: "1.7.0",
            newDecisionDomainSignature: Source.decisionDomainSignature,
            preservingMissCount: true,
            preservedRound: 2
        )

        let payloads = try loadPayloads()
        for source in Source.allCases {
            let payload = try XCTUnwrap(payloads[source])
            XCTAssertTrue(
                payload.snapshotMembers.isEmpty,
                "\(source) 的本轮快照成员必须清空（T 待重取）"
            )
        }
    }

    /// **版本变更仍然清 `a`**（既有 M4 行为不得因新增指纹机制而松动）。
    func testVersionChangeStillClearsMissCount() throws {
        try saveCarrier(appVersion: "1.6.0", decisionDomainSignature: Source.decisionDomainSignature, missCount: 2)

        try stateFile.clearCarrierForObservationReset(
            newAppVersion: "1.7.0",
            newDecisionDomainSignature: Source.decisionDomainSignature,
            preservingMissCount: false,
            preservedRound: 2
        )

        let after = try loadHeader()
        for entry in after.sources {
            XCTAssertEqual(entry.a, 0, "\(entry.source) 的 a 必须清零（应用版本变更）")
            XCTAssertEqual(entry.slotCount, 0, "\(entry.source) 的位槽数必须清零")
            XCTAssertEqual(entry.doneCount, 0, "\(entry.source) 的已计误判数必须清零")
        }
        let payloads = try loadPayloads()
        for source in Source.allCases {
            // 版本变更 ⇒ **载荷段整体不存在**（既有契约 `StateFileTests.testClearCarrierForVersionChange`）：
            // 「无段」= 无数据可读 = 已清零。
            XCTAssertNil(
                payloads[source],
                "\(source) 的载荷必须整体清零（无段 = 无数据）"
            )
        }
    }

    /// **版本变更时轮次保留**（M1：重置当前轮次，不产生新轮次）。
    func testResetPreservesRound() throws {
        try saveCarrier(appVersion: "1.6.0", decisionDomainSignature: nil, round: 3)

        try stateFile.clearCarrierForObservationReset(
            newAppVersion: "1.7.0",
            newDecisionDomainSignature: Source.decisionDomainSignature,
            preservingMissCount: false,
            preservedRound: 3
        )

        XCTAssertEqual(try loadHeader().round, 3, "轮次必须保留（不产生新轮次）")
    }

    /// **用户设置类字段不随重置清零**（M1 写入时刻 ⑧）。
    func testResetPreservesUserSettings() throws {
        try saveCarrier(appVersion: "1.6.0", decisionDomainSignature: nil, configure: {
            $0.autoDeleteEnabled = true
            $0.countedDaysCap = 21
        })

        try stateFile.clearCarrierForObservationReset(
            newAppVersion: "1.7.0",
            newDecisionDomainSignature: Source.decisionDomainSignature,
            preservingMissCount: true,
            preservedRound: 2
        )

        let after = try loadHeader()
        XCTAssertTrue(after.autoDeleteEnabled, "自动删除总开关是用户设置，不得被重置改掉")
        XCTAssertEqual(after.countedDaysCap, 21, "观察期天数上限是用户设置，不得被重置改掉")
    }

    /// **指纹一致 ⇒ 观察期凭证原封不动**。
    func testSignatureMatchLeavesObservationIntact() throws {
        try saveCarrier(appVersion: "1.7.0", decisionDomainSignature: Source.decisionDomainSignature)

        let reason = ObservationResetPolicy.reason(
            storedAppVersion: "1.7.0",
            currentAppVersion: "1.7.0",
            storedDecisionDomainSignature: Source.decisionDomainSignature,
            currentDecisionDomainSignature: Source.decisionDomainSignature
        )
        XCTAssertEqual(reason, .none, "指纹一致 ⇒ 不该触发重置")

        let after = try loadHeader()
        XCTAssertEqual(after.countedDays, 14, "观察期凭证原封不动")
        XCTAssertEqual(after.sources.first?.K, 90, "结算值原封不动")
        XCTAssertEqual(after.sources.first?.b, 12, "L0 计数原封不动")
    }

    // MARK: - 头部原语

    /// **`resetObservationCredentials(clearingMissCount: false)` 保留 `a` 三项**。
    ///
    /// 这是「判定域变更保留 `a`」的头部侧落点 —— 与载荷侧保留三项配套。
    func testResetObservationCredentialsKeepsMissCountWhenNotClearing() {
        var header = StateHeader()
        header.countedDays = 9
        header.sources = [SourceHeaderEntry(source: .uvCache, snapshotTaken: true, T: 10, K: 8, J: 2, H: 3, a: 4, b: 5, slotCount: 7, doneCount: 2)]

        header.resetObservationCredentials(clearingMissCount: false)

        let entry = header.sources[0]
        XCTAssertEqual(entry.a, 4, "a 必须保留")
        XCTAssertEqual(entry.slotCount, 7, "位槽数必须保留")
        XCTAssertEqual(entry.doneCount, 2, "已计误判数必须保留")
        XCTAssertEqual(header.countedDays, 0, "计数日必须归零")
        XCTAssertNil(entry.T, "T 必须回到「未取快照」")
        XCTAssertEqual(entry.b, 0, "b 必须归零")
    }

    /// **`resetObservationCredentials()` 默认清 `a`**（既有行为不变）。
    func testResetObservationCredentialsClearsMissCountByDefault() {
        var header = StateHeader()
        header.sources = [SourceHeaderEntry(source: .uvCache, a: 4, slotCount: 7, doneCount: 2)]

        header.resetObservationCredentials()

        let entry = header.sources[0]
        XCTAssertEqual(entry.a, 0, "默认清 a")
        XCTAssertEqual(entry.slotCount, 0, "默认清位槽数")
        XCTAssertEqual(entry.doneCount, 0, "默认清已计误判数")
    }
}
