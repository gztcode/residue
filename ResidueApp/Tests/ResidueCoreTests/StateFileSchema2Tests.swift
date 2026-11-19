import XCTest
@testable import ResidueCore

/// CR-031 §3.1 / §3.8 · 载体 `state.residue` 的 schema 1 → 2。
///
/// 契约落点：
///   - R2 v1.9 §5.1 —— 段表新增 `0x04 Snapshot`（每来源第 4 段），段序 `F → C_done → Slots → Snapshot`
///   - R2 v1.9 §10.3 —— schema 1 → 2 **就地升级**，旧载体无 `Snapshot` 段 → 快照成员集合为空
///   - PRD v5.6 M3 —— 「取快照时刻唯一」需要把快照成员集合落到载体里
///
/// **为什么另起一个文件**：`StateFileTests` 守的是 §5.1 的既有不变量
/// （尺寸恒等式 / 段长恒等式 / 原子写 / 迁移回退），本文件守的是**版本升级**。
final class StateFileSchema2Tests: XCTestCase {

    // MARK: - 夹具

    /// 每来源的快照成员（两条；`T` 的成员，逐条归因的对象）。
    private static let snapshotMembers: [CandidateID] = [
        CandidateID(path: "/cache/a", birthtime: Date(timeIntervalSince1970: 1_700_000_000)),
        CandidateID(path: "/cache/b", birthtime: Date(timeIntervalSince1970: 1_700_000_100))
    ]

    private func makePayloads(
        snapshot: [CandidateID] = StateFileSchema2Tests.snapshotMembers
    ) -> [Source: SourcePayload] {
        var payloads: [Source: SourcePayload] = [:]
        for source in Source.allCases {
            // 位图长度必须 = ceil(slotCount/8) = ceil(16/8) = 2
            var bitmap = Data(count: 2)
            bitmap[0] = 0b1010_1010
            payloads[source] = SourcePayload(
                bitmap: bitmap,
                countedDoneSlots: [0, 2],
                slots: [
                    0: CandidateID(
                        path: "/tmp/cand-0-\(source.rawValue)",
                        birthtime: Date(timeIntervalSince1970: 1_700_000_000)
                    )
                ],
                snapshotMembers: snapshot
            )
        }
        return payloads
    }

    private func makeHeader(schemaVersion: Int = StateFileCodec.currentSchemaVersion) -> StateHeader {
        StateHeader(
            schemaVersion: schemaVersion,
            appVersion: "1.0.0 (1)",
            round: 2,
            countedDays: 3,
            countedDaysCap: 14,
            sources: Source.allCases.map {
                SourceHeaderEntry(
                    source: $0,
                    snapshotTaken: true,
                    T: 100, K: 90, J: 10, H: 30,
                    a: 2, b: 5,
                    slotCount: 16,
                    doneCount: 2,
                    lastJudgmentAt: Date(timeIntervalSince1970: 1_700_000_100)
                )
            }
        )
    }

    // MARK: - 版本与段种类

    /// **载体 schema 版本升到 2**（新增 `Snapshot` 段）。
    func testCurrentSchemaVersionIsTwo() {
        XCTAssertEqual(StateFileCodec.currentSchemaVersion, 2)
    }

    /// **`Snapshot` 段的 kind = `0x04`**（§5.1 段表）。
    func testSnapshotSegmentKindIsFour() {
        XCTAssertEqual(SegmentKind.snapshot.rawValue, 0x04)
    }

    /// **写不出版本不支持的载体** —— 写出来的文件读方必然拒绝，那是在制造坏文件。
    func testEncodeRejectsUnsupportedSchemaVersion() {
        let header = makeHeader(schemaVersion: 3)
        XCTAssertThrowsError(try StateFileCodec.encode(header: header, payloads: makePayloads()))
    }

    // MARK: - 段集与段序

    /// **schema 2 → 每来源四段**。
    func testSchemaTwoHasFourSegmentsPerSource() throws {
        let data = try StateFileCodec.encode(header: makeHeader(), payloads: makePayloads())
        let contents = try StateFileCodec.decode(data)
        XCTAssertEqual(contents.segments.count, Source.allCases.count * 4)
    }

    /// **段序固定**：`F` → `C_done` → `Slots` → `Snapshot`。
    ///
    /// 段按 `(sourceIndex, kind)` 索引、不按位置猜；顺序固定只为可读性
    /// （R2 v1.9 §5.1）。
    func testSegmentOrderIsFixedFCountedDoneSlotsSnapshot() throws {
        let data = try StateFileCodec.encode(header: makeHeader(), payloads: makePayloads())
        let contents = try StateFileCodec.decode(data)

        for (index, _) in Source.allCases.enumerated() {
            let kinds = contents.segments
                .filter { Int($0.sourceIndex) == index }
                .map { $0.kind }
            XCTAssertEqual(kinds, [.fBitmap, .countedDone, .slots, .snapshot])
        }
    }

    // MARK: - 快照成员集合往返

    /// **快照成员集合必须落盘**（否则结算无对象可归因，`K` 无从算起）。
    func testSnapshotMembersRoundTrip() throws {
        let data = try StateFileCodec.encode(header: makeHeader(), payloads: makePayloads())
        let contents = try StateFileCodec.decode(data)

        for source in Source.allCases {
            XCTAssertEqual(
                contents.payloads[source]?.snapshotMembers,
                StateFileSchema2Tests.snapshotMembers,
                "\(source.displayName) 的快照成员集合必须往返一致"
            )
        }
    }

    /// **空快照成员集合也能往返**（本轮尚未取快照的来源）。
    func testEmptySnapshotMembersRoundTrip() throws {
        let data = try StateFileCodec.encode(
            header: makeHeader(),
            payloads: makePayloads(snapshot: [])
        )
        let contents = try StateFileCodec.decode(data)

        for source in Source.allCases {
            XCTAssertEqual(contents.payloads[source]?.snapshotMembers, [])
        }
    }

    // MARK: - schema 1 旧载体仍可读

    /// **schema 1 旧载体必须仍能读**（不拒绝、不丢数据）。
    ///
    /// 旧载体每来源三段、无 `Snapshot` 段 → **快照成员集合为空**（R2 v1.9 §10.3 ①）。
    func testSchemaOneCarrierIsReadableWithEmptySnapshotMembers() throws {
        let data = try StateFileCodec.encode(
            header: makeHeader(schemaVersion: 1),
            payloads: makePayloads()
        )
        let contents = try StateFileCodec.decode(data)

        XCTAssertEqual(contents.header.schemaVersion, 1, "读出的版本必须是文件里的版本")
        for source in Source.allCases {
            XCTAssertEqual(
                contents.payloads[source]?.snapshotMembers,
                [],
                "schema 1 无 Snapshot 段 → 快照成员集合为空"
            )
        }
    }

    /// **schema 1 旧载体每来源仍是三段**。
    func testSchemaOneCarrierHasThreeSegmentsPerSource() throws {
        let data = try StateFileCodec.encode(
            header: makeHeader(schemaVersion: 1),
            payloads: makePayloads()
        )
        let contents = try StateFileCodec.decode(data)
        XCTAssertEqual(contents.segments.count, Source.allCases.count * 3)
    }

    /// **schema 1 读方遇到 `0x04` 段必须判 `E-304`** —— 不猜、不部分加载。
    ///
    /// 场景：文件头谎称 schema 1，段表里却有 schema 2 才有的 `Snapshot` 段。
    func testSchemaTwoSnapshotSegmentIsRejectedWhenFileClaimsSchemaOne() throws {
        let data = try StateFileCodec.encode(header: makeHeader(), payloads: makePayloads())
        var bytes = [UInt8](data)
        bytes[4] = 1; bytes[5] = 0; bytes[6] = 0; bytes[7] = 0   // 谎称 schema 1

        XCTAssertThrowsError(try StateFileCodec.decode(Data(bytes))) { error in
            guard case StateFileError.segmentValidationFailed = error else {
                XCTFail("schema 1 读到 0x04 段应判 E-304，实为 \(error)")
                return
            }
        }
    }

    // MARK: - §3.8 头部字段

    /// **取快照时刻 / 结算时刻必须落盘**（M3「取快照时刻唯一」要能事后核对）。
    func testHeaderCarriesSnapshotAndSettlementDates() throws {
        let snapshotDate = Date(timeIntervalSince1970: 1_700_000_000)
        let settlementDate = Date(timeIntervalSince1970: 1_700_100_000)
        var header = makeHeader()
        header.sources[0].snapshotDate = snapshotDate
        header.sources[0].settlementDate = settlementDate

        let data = try StateFileCodec.encode(header: header, payloads: makePayloads())
        let contents = try StateFileCodec.decode(data)

        XCTAssertEqual(contents.header.sources[0].snapshotDate, snapshotDate)
        XCTAssertEqual(contents.header.sources[0].settlementDate, settlementDate)
    }

    /// **「有 N 条无法归因」必须落盘**（裁决 ③：不变量③ —— 看不见的东西要如实显示）。
    func testHeaderCarriesUnattributableCount() throws {
        var header = makeHeader()
        header.sources[0].unattributableCount = 3

        let data = try StateFileCodec.encode(header: header, payloads: makePayloads())
        let contents = try StateFileCodec.decode(data)

        XCTAssertEqual(contents.header.sources[0].unattributableCount, 3)
    }

    /// **`nil`（未结算，无从归因）≠ `0`（已结算但无无法归因条目）**。
    ///
    /// 不变量③：`nil ≠ 0` —— `0` 会被读成「已结算、无失联」，`nil` 才是「尚未结算」。
    func testUnattributableCountNilIsDistinctFromZero() throws {
        var header = makeHeader()
        header.sources[0].unattributableCount = nil     // 未结算
        header.sources[1].unattributableCount = 0        // 已结算、无无法归因条目

        let data = try StateFileCodec.encode(header: header, payloads: makePayloads())
        let contents = try StateFileCodec.decode(data)

        XCTAssertNil(contents.header.sources[0].unattributableCount)
        XCTAssertEqual(contents.header.sources[1].unattributableCount, 0)
    }

    // MARK: - 身份键逐位无损（载体往返）

    /// `2^-23` 秒 —— `Date` 内部表示在当前量级下的一个 ULP（最小刻度）。
    private static let oneULP = 1.1920928955078125e-07

    /// 一个**必然**在「Unix 基准 ↔ 内部基准」转换中丢 1 ULP 的出生时间。
    ///
    /// ## 怎么推出来的
    ///
    /// `Date` 内部表示 = 「相对 2001-01-01 的秒」，`timeIntervalSince1970` 与它之间
    /// 隔着 978307200 秒 ⇒ 两者落在**不同的 f64 网格**上：
    /// - 内部值（~7.2e8）的刻度 = 2^-23 秒
    /// - Unix 值（~1.7e9）的刻度 = 2^-22 秒
    ///
    /// 取内部值 = `721_692_800 + 2^-23`（2^-23 的**奇数**倍）⇒ 换算到 Unix 域后
    /// 恰落在两个 2^-22 网格点的**正中** ⇒ 按就近取偶舍入 ⇒ **必然**丢 1 单位。
    ///
    /// ## 为什么不用随机真文件时间戳
    ///
    /// 丢不丢位取决于数值落在哪个网格 —— 随机样本是**间歇现象**，不能当规格。
    /// 这个夹具是**确定性**的：每次跑都必然触发。
    private static let lossyBirthtime = Date(
        timeIntervalSinceReferenceDate: 721_692_800 + 1.1920928955078125e-07
    )

    /// **载体往返后，身份键（路径 + birthtime）必须逐位无损**。
    ///
    /// ## 为什么有这条断言
    ///
    /// 二进制段的 birthtime 曾用 `timeIntervalSince1970` 的 f64 位模式编码、
    /// 用 `Date(timeIntervalSince1970:)` 解码 ⇒ 两端基准不同 ⇒ 往返**必然**丢 1 位。
    ///
    /// 后果有两条，都直接打穿 CR-031 想闭合的那条链：
    /// 1. 归因判据「路径 + birthtime 命中」不命中 ⇒ 同路径但 birthtime 不同 ⇒
    ///    判「同名重建」⇒ **`K = 0`、`J = T`**（一份全是假失联的报告）。
    /// 2. 位槽占用表的身份键同样被破坏 ⇒ **每轮扫描都分配新位槽** ⇒
    ///    `F` 位永不命中 ⇒ **`a` 恒为 0**（门槛里的 `a = 0` 恰好成立，但原因是错的）。
    func testIdentityKeySurvivesCarrierRoundTripBitExact() throws {
        let birthtime = StateFileSchema2Tests.lossyBirthtime
        let member = CandidateID(path: "/cache/bit-exact", birthtime: birthtime)
        let slotted = CandidateID(path: "/tmp/slot-bit-exact", birthtime: birthtime)

        var payloads = makePayloads(snapshot: [member])
        for source in Source.allCases {
            payloads[source]?.slots[0] = slotted
        }

        let data = try StateFileCodec.encode(header: makeHeader(), payloads: payloads)
        let contents = try StateFileCodec.decode(data)

        XCTAssertEqual(Source.allCases.count, 7, "来源数变了，夹具的位图长度恒等式不再成立")
        for source in Source.allCases {
            XCTAssertEqual(
                contents.payloads[source]?.snapshotMembers,
                [member],
                "\(source.displayName) 的快照成员身份键必须逐位无损"
            )
            XCTAssertEqual(
                contents.payloads[source]?.slots[0],
                slotted,
                "\(source.displayName) 的位槽身份键必须逐位无损"
            )
        }
    }

    /// **载体往返后，同一候选必须仍落在原位槽**（否则每轮重分配 ⇒ 位槽域无限膨胀）。
    ///
    /// 这是上一条断言的**下游后果**，单独钉住：位槽一旦重分配，`F` 位图就永远
    /// 命中不到 → `a` 无法再累计 → 门槛里的 `a = 0` 恒成立（但那是巧合，不是判定）。
    func testSlotAssignmentSurvivesCarrierRoundTrip() throws {
        let candidate = CandidateID(
            path: "/tmp/cand-slot-roundtrip",
            birthtime: StateFileSchema2Tests.lossyBirthtime
        )
        var payloads = makePayloads(snapshot: [])
        for source in Source.allCases {
            payloads[source]?.slots[0] = candidate
        }

        let data = try StateFileCodec.encode(header: makeHeader(), payloads: payloads)
        let contents = try StateFileCodec.decode(data)

        XCTAssertEqual(Source.allCases.count, 7, "来源数变了，夹具的位图长度恒等式不再成立")
        for source in Source.allCases {
            guard let payload = contents.payloads[source] else {
                XCTFail("\(source.displayName) 的载荷丢了")
                continue
            }
            var state = payload.l0State(missCount: 0)
            XCTAssertEqual(
                state.slotTable.slotIfAssigned(for: candidate),
                0,
                "\(source.displayName) 的同一候选往返后必须仍在原位槽 0"
            )
            XCTAssertEqual(
                state.slotTable.slot(for: candidate),
                0,
                "\(source.displayName) 的位槽分配必须幂等"
            )
            XCTAssertEqual(
                state.slotTable.slotDomainSize,
                1,
                "\(source.displayName) 的位槽域不得膨胀"
            )
        }
    }

    /// **schema 1 存量载体的位槽仍按 Unix 基准解读**（存量文件语义不得被改动）。
    ///
    /// ## 为什么要有这条
    ///
    /// schema 2 改用「相对 2001-01-01」的基准（往返逐位无损），
    /// 但**已在用户磁盘上的 schema 1 文件**用的是 Unix 基准。
    /// 若读方不分版本一律按新基准解读 ⇒ 存量文件的 birthtime **整体偏移 978307200 秒**
    /// （≈31 年）⇒ 恢复路径（`E-308`）交给上层的位槽身份键全是垃圾。
    ///
    /// 本用例是**守卫**（不是缺陷复现）：它在改动前后都应通过，
    /// 用来挡住「把基准一刀切」这种改法。
    func testSchemaOneCarrierKeepsUnixBirthtimeBase() throws {
        let birthtime = Date(timeIntervalSince1970: 1_700_000_000)
        let slotted = CandidateID(path: "/tmp/cand-schema1", birthtime: birthtime)

        var payloads = makePayloads(snapshot: [])
        for source in Source.allCases {
            payloads[source]?.slots[0] = slotted
        }

        let data = try StateFileCodec.encode(
            header: makeHeader(schemaVersion: 1),
            payloads: payloads
        )
        let contents = try StateFileCodec.decode(data)

        XCTAssertEqual(Source.allCases.count, 7, "来源数变了，夹具的位图长度恒等式不再成立")
        for source in Source.allCases {
            XCTAssertEqual(
                contents.payloads[source]?.slots[0]?.birthtime.timeIntervalSince1970,
                birthtime.timeIntervalSince1970,
                "\(source.displayName) 的 schema 1 位槽 birthtime 必须仍按 Unix 基准解读"
            )
        }
    }
}
