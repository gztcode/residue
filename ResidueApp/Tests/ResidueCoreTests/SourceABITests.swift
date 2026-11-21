import XCTest
import Foundation
@testable import ResidueCore

/// `Source` 枚举 ⇄ `state.residue` 段索引的 **隐式 ABI 守卫**。
///
/// ## 为什么需要它
///
/// `state.residue` 段表用 `sourceIndex u8` 索引来源，而这个字节的历史取值
/// 就是 `Source` 的**声明序**。也就是说「枚举的声明顺序」是**落盘格式的一部分**，
/// 但它长得像普通代码 —— 谁在中间插入一个 case，存量载体的段索引就整体错位：
/// 误判数 `a` 归到错误来源 ⇒ 不变量④「删之前先证明自己判得准」静默失效。
///
/// 本文件把这条契约钉成三条机器断言：
/// 1. **声明序冻结**：`(rawValue, stableIndex)` 与历史表逐项相等；
/// 2. **索引连续双射**：`stableIndex` = `0..<count`，且能反解回同一来源；
/// 3. **读写必须走 `stableIndex`**：`ResidueStateFile.swift` 不得用
///    `Source.allCases.enumerated()` 的下标当段索引。
///
/// ⚠️ 改动本文件的冻结表 **必须附变更单号** —— 它就是载体格式本身。
final class SourceABITests: XCTestCase {

    /// 历史 ABI 冻结表（**只可追加，不可插入、不可改值**）。
    ///
    /// 这是 `state.residue` 已发布格式的唯一清单：index = 落盘 `sourceIndex`。
    private static let frozenABI: [(rawValue: String, stableIndex: UInt8)] = [
        ("uv_cache", 0),
        ("npm_npx", 1),
        ("pipx_run", 2),
        ("brew_downloads", 3),
        ("cargo_registry_cache", 4),
        ("pnpm_store", 5),
        ("bun_cache", 6),
    ]

    // MARK: - ① 声明序冻结

    /// 枚举声明序（= `allCases` 顺序）必须与冻结表逐项一致。
    ///
    /// **中间插入**会让本断言在「新 case 之后的每一项」上失败；
    /// 追加到末尾会因「数量不等」失败 —— 两种情况都必须先出变更单、
    /// 再更新本表（而不是直接改代码让测试变绿）。
    func testSourceDeclarationOrderIsFrozenABI() {
        XCTAssertEqual(
            Source.allCases.count, Self.frozenABI.count,
            "来源数量变了 —— 新增来源只能追加到枚举末尾，且须出变更单并同步本冻结表"
        )
        for (offset, expected) in Self.frozenABI.enumerated() where offset < Source.allCases.count {
            let actual = Source.allCases[offset]
            XCTAssertEqual(
                actual.rawValue, expected.rawValue,
                "声明序第 \(offset) 位应是 \(expected.rawValue)，实际 \(actual.rawValue) —— "
                    + "在枚举中间插入/换序会让存量载体的 sourceIndex 整体错位（载体 ABI 破坏）"
            )
            XCTAssertEqual(
                actual.stableIndex, expected.stableIndex,
                "\(actual.rawValue) 的落盘索引应为 \(expected.stableIndex)，实际 \(actual.stableIndex) —— "
                    + "已发布的 stableIndex 不可改"
            )
        }
    }

    // MARK: - ② 索引连续双射

    /// `stableIndex` 必须是 `0..<allCases.count` 的连续双射，且反解回同一来源。
    func testStableIndexIsContiguousBijection() {
        let count = Source.allCases.count
        let expected = Array(0..<UInt8(count))
        XCTAssertEqual(
            Source.allCases.map(\.stableIndex), expected,
            "stableIndex 必须覆盖 0..<\(count) 且不重不漏"
        )
        for source in Source.allCases {
            XCTAssertEqual(
                Source(stableIndex: source.stableIndex), source,
                "\(source.rawValue) 的 stableIndex 反解必须回到自身"
            )
        }
        // 未知索引必须返回 nil（读方据此报 E-304，不猜、不部分加载）。
        XCTAssertNil(Source(stableIndex: UInt8(count)), "越界索引必须 nil")
        XCTAssertNil(Source(stableIndex: .max), "越界索引必须 nil")
    }

    // MARK: - ③ 读写走 stableIndex（绕过检查）

    /// `ResidueStateFile.swift` 的段索引**必须**走 `stableIndex`，不得用
    /// `allCases.enumerated()` 的序号或 `firstIndex` 的隐式下标。
    ///
    /// 这是「同一判定只有一个实现处」在载体 ABI 上的落地：`stableIndex` 是
    /// 唯一映射点，任何第二套映射都会在枚举改动时各自腐坏。
    func testStateFileIndexesGoThroughStableIndex() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ResidueCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ResidueApp
            .appendingPathComponent("Sources/ResidueCore/ResidueStateFile.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        // 去掉整行注释，避免注释里的字面量造成假红/假绿。
        let code = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertTrue(
            code.contains("source.stableIndex"),
            "写方必须用 source.stableIndex 落盘段索引"
        )
        XCTAssertTrue(
            code.contains("Source(stableIndex:"),
            "读方必须用 Source(stableIndex:) 反解段索引（唯一入口）"
        )
        XCTAssertFalse(
            code.contains(".allCases.enumerated"),
            "发现 Source.allCases.enumerated() —— 段索引不得依赖声明序下标这个隐式巧合"
        )
        XCTAssertFalse(
            code.contains("let sourceList = Source.allCases"),
            "发现按声明序下标取来源（sourceList[...]）—— 必须改走 Source(stableIndex:)"
        )
    }

    // MARK: - ④ 载体往返映射

    /// 每个来源的载荷编码再解码后，必须回到**同一个来源**。
    ///
    /// 断言的是 `(sourceIndex → source)` 这条映射本身，而不是「文件能读」：
    /// 索引错位时文件照样能读，只是 `a` 归错来源。
    func testSegmentIndexMapsBackToTheSameSource() throws {
        let slotCount = 8
        var payloads: [Source: SourcePayload] = [:]
        for source in Source.allCases {
            payloads[source] = SourcePayload(
                bitmap: Data([source.stableIndex]),
                countedDoneSlots: [],
                slots: [
                    0: CandidateID(
                        path: "/tmp/\(source.rawValue)",
                        birthtime: Date(timeIntervalSince1970: 1_700_000_000)
                    )
                ]
            )
        }
        let header = StateHeader(sources: Source.allCases.map {
            SourceHeaderEntry(source: $0, slotCount: slotCount)
        })

        let data = try StateFileCodec.encode(header: header, payloads: payloads)
        let contents = try StateFileCodec.decode(data)

        for source in Source.allCases {
            XCTAssertEqual(
                contents.payloads[source]?.slots[0]?.path, "/tmp/\(source.rawValue)",
                "\(source.rawValue) 的段索引必须映射回自身，不能串到别的来源"
            )
            XCTAssertEqual(
                contents.payloads[source]?.bitmap.first, source.stableIndex,
                "\(source.rawValue) 的位图段必须来自自身"
            )
        }
    }
}
