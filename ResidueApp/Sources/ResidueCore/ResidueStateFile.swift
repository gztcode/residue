import Foundation

// ============================================================
// Residue · 状态载体 `state.residue`（二进制格式）
//
// 契约落点：技术方案 §5.1 / IF-09 / §10.3；PRD v5.4 · M4「写入时刻」/ M6。
//
// ## 载体性质（契约 M4）
//   - 落**应用状态目录**下的本机状态文件
//   - **不属 N7 的 `.jsonl` 记录目录、不计入 N7 计量与容量回收**
//   - **N7「一键清除全部采集物与日志」不作用于它**
//     ⇒ 用户的清除动作**不构成 `a` 的重置路径**
//   - **应用版本变更时，载体字段（F / C_done / 位槽占用表 / a）一并清零**
//   - **轮次切换时不清零**（跨轮次累计，天然实现「错 1 次永久」）
//
// ## 文件格式（§5.1）
//   [ Magic "RSD1" 4B ][ schemaVersion u32 ][ headerLen u32 ][ headerJSON ]
//   [ segCount u32 ]
//   [ seg i: offset u64 | length u64 | kind u8 | sourceIndex u8 |
//            reserved u16 | reserved u32 ] × segCount      // 固定 24 B
//   [ payload ... ]
//   [ CRC32 of (header + segTable + payload) u32 ]
//
// ## 四条硬约束（照抄 §5.1，改动前先读 §5.1）
//   1. **段序固定**：`sources` 是数组，顺序 = `Source.allCases` 的**声明序**，
//      **不用 `Dictionary`**（Swift 每进程随机哈希种子 → 段序漂移 → 读方串段）。
//      读方按 `(sourceIndex, kind)` 索引，**不按位置猜**。
//   2. **段长恒由 `slotCount` 决定，与置位情况无关**：`F` 段长 `= ceil(slotCount/8)`。
//      加载期断言 `bitmapBytes == (slotCount + 7) / 8`，不等即 `E-304`。
//   3. **加载期校验三连**：尺寸恒等式 / 越界与重叠 / CRC32 一致。任一失败 → `E-304`，
//      **不猜、不部分加载**。
//   4. **原子写**：写临时文件 → fsync → rename。**短写 / ENOSPC 时不得 rename**
//      （否则半份文件覆盖好数据 → `a` 直接错）。
//
// 本文件不引用任何 UI；纯 IO + 序列化，便于单测。
// ============================================================

/// 状态载体的段种类（§5.1 payload 三段）。
public enum SegmentKind: UInt8, Sendable, CaseIterable {
    /// `0x01 F` · 每来源：位图。
    case fBitmap = 0x01
    /// `0x02 C_done` · 每来源：已计过误判的槽号。
    case countedDone = 0x02
    /// `0x03 Slots` · 每来源：位槽占用表。
    case slots = 0x03
}

/// 状态载体的错误码（§6 错误码表）。
public enum StateFileError: Error, Sendable, Equatable {
    /// `E-301` · schema 更高 → **只读降级**（不拒绝）。
    case schemaTooNew(found: Int, supported: Int)
    /// `E-302` · 状态文件损坏（CRC / 结构失败，且无可用 `.bak`）。
    case corruptNoBackup(detail: String)
    /// `E-303` · 写短写 / `ENOSPC` / `EDQUOT`。
    case writeFailed(detail: String)
    /// `E-304` · 段校验失败（越界 / 重叠 / CRC / 位图长度不符）。
    case segmentValidationFailed(detail: String)
    /// `E-305` · 迁移空间预检不足。
    case migrationSpaceInsufficient(requiredBytes: Int, availableBytes: Int)
    /// `E-306` · 迁移恢复失败（从 `.bak` 恢复也失败）。
    case migrationRestoreFailed(detail: String)
    /// `E-308` · **已从 `.bak` 恢复成功**（提示级）。
    case restoredFromBackup

    /// 对应的诊断码。
    ///
    /// 契约评审（R3 契约维度）指出：`"E-xxx"` 字面量在源码出现 0 次，
    /// 23 个码全部只活在注释里 → 「码 ↔ 用例」逐条核对无法机器化。
    /// 这个映射与 `ScanError.diagnostic` 一起，让码进了代码。
    public var diagnostic: DiagnosticCode {
        switch self {
        case .schemaTooNew: return .e301
        case .corruptNoBackup: return .e302
        case .writeFailed: return .e303
        case .segmentValidationFailed: return .e304
        case .migrationSpaceInsufficient: return .e305
        case .migrationRestoreFailed: return .e306
        case .restoredFromBackup: return .e308
        }
    }
}

/// 段表项（**固定 24 B**，字段序与 §5.1 校验① 完全一致）。
///
/// ⚠️ 字段序不可改：读写各按一处时**必然字段错位、且 CRC 查不出**
/// （错位读到的是合法字节）。
public struct SegmentDescriptor: Sendable, Equatable {
    /// payload 在文件中的绝对偏移。
    public var offset: UInt64
    /// payload 字节数。
    public var length: UInt64
    /// 段种类。
    public var kind: SegmentKind
    /// 来源序号（`Source.allCases` 的声明序下标）。
    public var sourceIndex: UInt8
    /// 保留（写 0）。
    public var reservedU16: UInt16
    /// 保留（写 0）。
    public var reservedU32: UInt32

    public init(offset: UInt64, length: UInt64, kind: SegmentKind, sourceIndex: UInt8) {
        self.offset = offset
        self.length = length
        self.kind = kind
        self.sourceIndex = sourceIndex
        self.reservedU16 = 0
        self.reservedU32 = 0
    }

    /// **固定 24 B**。
    public static let byteCount = 24
}

/// 一个来源在载体中的三段内容。
public struct SourcePayload: Sendable, Equatable {
    /// `F` 位图（长度 = `ceil(slotCount/8)`，与置位数无关）。
    public var bitmap: Data
    /// `C_done` 已计过误判的**槽号**集合（升序）。
    public var countedDoneSlots: [UInt32]
    /// 位槽占用表：槽号 → 身份键。
    public var slots: [UInt32: CandidateID]

    public init(bitmap: Data = Data(), countedDoneSlots: [UInt32] = [], slots: [UInt32: CandidateID] = [:]) {
        self.bitmap = bitmap
        self.countedDoneSlots = countedDoneSlots
        self.slots = slots
    }
}

/// 载体文件头（可读 JSON，供审计）。
public struct StateHeader: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var appVersion: String
    public var round: Int
    public var roundStartAnchor: Date?
    public var countedDays: Int
    public var countedDaysCap: Int
    public var autoDeleteEnabled: Bool
    public var lastScanAt: Date?

    /// 各来源的可读状态（**顺序 = `Source.allCases` 声明序**）。
    public var sources: [SourceHeaderEntry]

    /// 结算状态。
    public var settlement: SettlementHeader

    /// 各段的字节数（供审计；不参与加载校验）。
    public var bytes: ByteCounts

    public init(
        schemaVersion: Int = StateFileCodec.currentSchemaVersion,
        appVersion: String = "",
        round: Int = 1,
        roundStartAnchor: Date? = nil,
        countedDays: Int = 0,
        countedDaysCap: Int = 14,
        autoDeleteEnabled: Bool = false,
        lastScanAt: Date? = nil,
        sources: [SourceHeaderEntry] = [],
        settlement: SettlementHeader = SettlementHeader(),
        bytes: ByteCounts = ByteCounts()
    ) {
        self.schemaVersion = schemaVersion
        self.appVersion = appVersion
        self.round = round
        self.roundStartAnchor = roundStartAnchor
        self.countedDays = countedDays
        self.countedDaysCap = countedDaysCap
        self.autoDeleteEnabled = autoDeleteEnabled
        self.lastScanAt = lastScanAt
        self.sources = sources
        self.settlement = settlement
        self.bytes = bytes
    }
}

/// 单来源的可读状态。
public struct SourceHeaderEntry: Codable, Sendable, Equatable {
    public var source: Source
    /// 快照是否已取（本轮）。
    public var snapshotTaken: Bool
    /// `T` 快照总量（**null = 本轮尚未取快照**）。
    public var T: Int?
    /// `K` 样本量（**null = 本轮报告尚未产出**）。
    public var K: Int?
    /// `J` 失联量（**null = 本轮报告尚未产出**）。
    public var J: Int?
    /// `H` 门槛（`null` 随 `T` 为 null）。
    public var H: Int?
    /// 累计误判数 `a`。
    public var a: Int
    /// 本轮 L0 检查次数 `b`。
    public var b: Int
    /// 位槽数（`slotCount`）。
    public var slotCount: Int
    /// 已计过误判的候选数（`doneCount`）。
    public var doneCount: Int
    /// 上次判定时刻。
    public var lastJudgmentAt: Date?

    public init(
        source: Source,
        snapshotTaken: Bool = false,
        T: Int? = nil,
        K: Int? = nil,
        J: Int? = nil,
        H: Int? = nil,
        a: Int = 0,
        b: Int = 0,
        slotCount: Int = 0,
        doneCount: Int = 0,
        lastJudgmentAt: Date? = nil
    ) {
        self.source = source
        self.snapshotTaken = snapshotTaken
        self.T = T
        self.K = K
        self.J = J
        self.H = H
        self.a = a
        self.b = b
        self.slotCount = slotCount
        self.doneCount = doneCount
        self.lastJudgmentAt = lastJudgmentAt
    }
}

/// 结算状态。
public struct SettlementHeader: Codable, Sendable, Equatable {
    public var producedAt: Date?
    public var reportId: String?

    public init(producedAt: Date? = nil, reportId: String? = nil) {
        self.producedAt = producedAt
        self.reportId = reportId
    }
}

/// 字节数（供审计）。
public struct ByteCounts: Codable, Sendable, Equatable {
    public var header: Int
    public var segTable: Int
    public var payload: Int

    public init(header: Int = 0, segTable: Int = 0, payload: Int = 0) {
        self.header = header
        self.segTable = segTable
        self.payload = payload
    }
}

/// 载体文件（解析后的完整内容）。
public struct StateFileContents: Sendable, Equatable {
    public var header: StateHeader
    /// 段表（**顺序 = 文件内顺序**）。
    public var segments: [SegmentDescriptor]
    /// 各来源的三段内容（按 `Source` 索引）。
    public var payloads: [Source: SourcePayload]
    /// 文件总字节数。
    public var fileLength: Int

    public init(
        header: StateHeader = StateHeader(),
        segments: [SegmentDescriptor] = [],
        payloads: [Source: SourcePayload] = [:],
        fileLength: Int = 0
    ) {
        self.header = header
        self.segments = segments
        self.payloads = payloads
        self.fileLength = fileLength
    }
}

// ============================================================
// 序列化 / 反序列化
// ============================================================

/// `state.residue` 的编解码器（纯函数，无 IO）。
public enum StateFileCodec {

    /// Magic 4 B。
    public static let magic: [UInt8] = Array("RSD1".utf8)
    /// 当前支持的 schema 版本。
    public static let currentSchemaVersion = 1

    /// 当前 schema 版本（供 `StateFile` 引用）。
    public static var schemaVersion: Int { currentSchemaVersion }

    // MARK: - 写入

    /// 把载体内容编码成文件字节。
    ///
    /// - Parameter payloads: 各来源的三段内容。
    /// - Returns: 完整文件字节。
    public static func encode(header: StateHeader, payloads: [Source: SourcePayload]) throws -> Data {
        // 段序固定：按 `Source.allCases` 声明序遍历，**每来源三段、顺序 F → C_done → Slots**
        var segments: [SegmentDescriptor] = []
        var payloadBytes = Data()

        for (sourceIndex, source) in Source.allCases.enumerated() {
            guard let p = payloads[source] else { continue }
            let index = UInt8(sourceIndex)

            // ① F 位图
            let fLen = UInt64(p.bitmap.count)
            segments.append(SegmentDescriptor(offset: 0, length: fLen, kind: .fBitmap, sourceIndex: index))
            payloadBytes.append(p.bitmap)

            // ② C_done（count u32 + count × u32 slot，升序）
            let done = p.countedDoneSlots.sorted()
            var doneBytes = Data()
            var doneCount = UInt32(done.count).littleEndian
            withUnsafeBytes(of: &doneCount) { doneBytes.append(contentsOf: $0) }
            for slot in done {
                var s = slot.littleEndian
                withUnsafeBytes(of: &s) { doneBytes.append(contentsOf: $0) }
            }
            segments.append(SegmentDescriptor(offset: 0, length: UInt64(doneBytes.count), kind: .countedDone, sourceIndex: index))
            payloadBytes.append(doneBytes)

            // ③ Slots（count u32 + count × { slot u32, birthtime f64, pathLen u16, path UTF8 }）
            var slotsBytes = Data()
            var slotCount = UInt32(p.slots.count).littleEndian
            withUnsafeBytes(of: &slotCount) { slotsBytes.append(contentsOf: $0) }
            // 按槽号升序写（确定性）
            for slot in p.slots.keys.sorted() {
                guard let id = p.slots[slot] else { continue }
                var s = slot.littleEndian
                withUnsafeBytes(of: &s) { slotsBytes.append(contentsOf: $0) }
                var bt = id.birthtime.timeIntervalSince1970.bitPattern
                withUnsafeBytes(of: &bt) { slotsBytes.append(contentsOf: $0) }
                let pathBytes = Array(id.path.utf8)
                var pathLen = UInt16(min(pathBytes.count, Int(UInt16.max))).littleEndian
                withUnsafeBytes(of: &pathLen) { slotsBytes.append(contentsOf: $0) }
                slotsBytes.append(contentsOf: pathBytes.prefix(Int(pathLen)))
            }
            segments.append(SegmentDescriptor(offset: 0, length: UInt64(slotsBytes.count), kind: .slots, sourceIndex: index))
            payloadBytes.append(slotsBytes)
        }

        // 段表偏移：payload 起点 = 头部 + 段表之后（**此刻段数已知**）
        let headerData = try encodeHeader(header, segmentCount: segments.count)
        let headerLen = headerData.count
        let segTableLen = segments.count * SegmentDescriptor.byteCount
        let payloadStart = 4 + 4 + 4 + headerLen + 4 + segTableLen

        // 回填段偏移
        var running = UInt64(payloadStart)
        var finalSegments: [SegmentDescriptor] = []
        var segIndex = 0
        for seg in segments {
            var s = seg
            s.offset = running
            running += seg.length
            finalSegments.append(s)
            segIndex += 1
        }
        _ = segIndex

        // 段表字节
        var segTable = Data()
        for seg in finalSegments {
            var off = seg.offset.littleEndian
            withUnsafeBytes(of: &off) { segTable.append(contentsOf: $0) }
            var len = seg.length.littleEndian
            withUnsafeBytes(of: &len) { segTable.append(contentsOf: $0) }
            segTable.append(seg.kind.rawValue)
            segTable.append(seg.sourceIndex)
            var r16 = seg.reservedU16.littleEndian
            withUnsafeBytes(of: &r16) { segTable.append(contentsOf: $0) }
            var r32 = seg.reservedU32.littleEndian
            withUnsafeBytes(of: &r32) { segTable.append(contentsOf: $0) }
        }

        // CRC 覆盖 header + segTable + payload（**不含 magic / 长度字段 / CRC 自身**）
        var crcInput = Data()
        crcInput.append(headerData)
        crcInput.append(segTable)
        crcInput.append(payloadBytes)
        let crc = CRC32.checksum(crcInput)

        var out = Data()
        out.append(contentsOf: magic)
        var ver = UInt32(currentSchemaVersion).littleEndian
        withUnsafeBytes(of: &ver) { out.append(contentsOf: $0) }
        var hlen = UInt32(headerLen).littleEndian
        withUnsafeBytes(of: &hlen) { out.append(contentsOf: $0) }
        out.append(headerData)
        var sc = UInt32(finalSegments.count).littleEndian
        withUnsafeBytes(of: &sc) { out.append(contentsOf: $0) }
        out.append(segTable)
        out.append(payloadBytes)
        var crcLE = crc.littleEndian
        withUnsafeBytes(of: &crcLE) { out.append(contentsOf: $0) }

        return out
    }

    /// 编码头部 JSON（**不含 bytes** —— 那是写完才知道的）。
    private static func encodeHeader(_ header: StateHeader, segmentCount: Int) throws -> Data {
        var h = header
        h.bytes = ByteCounts()   // 写时未知；读时校验不依赖它
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(h)
    }

    // MARK: - 读取

    /// 解析文件字节 → 载体内容。**任一校验失败即抛 `E-304`，不猜、不部分加载**。
    public static func decode(_ data: Data) throws -> StateFileContents {
        let fileLen = data.count

        // 前置：最小长度 = magic(4) + ver(4) + hlen(4) + segCount(4) + CRC(4) = 20
        guard fileLen >= 20 else {
            throw StateFileError.segmentValidationFailed(detail: "文件过短：\(fileLen) B < 20 B")
        }
        let bytes = [UInt8](data)

        // magic
        guard Array(bytes[0..<4]) == magic else {
            throw StateFileError.segmentValidationFailed(detail: "magic 不匹配")
        }

        func u32(at off: Int) -> UInt32 {
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(bytes[off + i]) << (8 * UInt32(i)) }
            return v
        }
        func u64(at off: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(bytes[off + i]) << (8 * UInt64(i)) }
            return v
        }

        let schemaVersion = Int(u32(at: 4))
        let headerLen = Int(u32(at: 8))

        // schema 更高 → 只读降级（E-301，**不拒绝**）
        if schemaVersion > currentSchemaVersion {
            throw StateFileError.schemaTooNew(found: schemaVersion, supported: currentSchemaVersion)
        }

        let headerEnd = 12 + headerLen
        guard headerEnd + 4 <= fileLen else {
            throw StateFileError.segmentValidationFailed(detail: "headerLen 越界")
        }
        let headerData = Data(bytes[12..<headerEnd])

        let segCountOffset = headerEnd
        let segCount = Int(u32(at: segCountOffset))
        let segTableStart = segCountOffset + 4
        let segTableEnd = segTableStart + segCount * SegmentDescriptor.byteCount
        guard segTableEnd <= fileLen else {
            throw StateFileError.segmentValidationFailed(detail: "段表越界")
        }

        // 校验① 尺寸恒等式：
        // fileLen == 4 + 4 + 4 + headerLen + 4 + 24×segCount + Σpayload + 4
        // 解析段表，拿 Σpayload
        var segments: [SegmentDescriptor] = []
        var sumPayload: UInt64 = 0
        for i in 0..<segCount {
            let base = segTableStart + i * SegmentDescriptor.byteCount
            let off = u64(at: base)
            let len = u64(at: base + 8)
            let kindRaw = bytes[base + 16]
            guard let kind = SegmentKind(rawValue: kindRaw) else {
                throw StateFileError.segmentValidationFailed(detail: "未知段种类 \(kindRaw)")
            }
            let sourceIndex = bytes[base + 17]
            let r16 = UInt16(bytes[base + 18]) | (UInt16(bytes[base + 19]) << 8)
            let r32 = u32(at: base + 20)
            segments.append(SegmentDescriptor(
                offset: off, length: len, kind: kind, sourceIndex: sourceIndex
            ))
            segments[segments.count - 1].reservedU16 = r16
            segments[segments.count - 1].reservedU32 = r32
            sumPayload += len
        }

        let expected = 4 + 4 + 4 + headerLen + 4
            + segCount * SegmentDescriptor.byteCount
            + Int(sumPayload) + 4
        guard expected == fileLen else {
            throw StateFileError.segmentValidationFailed(
                detail: "尺寸恒等式不成立：期望 \(expected) B，实为 \(fileLen) B"
            )
        }

        // 校验② 越界 / 重叠 / offset ≥ 段表末尾
        let payloadRegionStart = segTableEnd
        var intervals: [(UInt64, UInt64)] = []
        for seg in segments {
            guard seg.offset >= UInt64(payloadRegionStart) else {
                throw StateFileError.segmentValidationFailed(
                    detail: "段 offset \(seg.offset) 早于段表末尾 \(payloadRegionStart)"
                )
            }
            guard seg.offset + seg.length <= UInt64(fileLen - 4) else {
                throw StateFileError.segmentValidationFailed(detail: "段越界")
            }
            intervals.append((seg.offset, seg.offset + seg.length))
        }
        let sortedIntervals = intervals.sorted { $0.0 < $1.0 }
        for i in 1..<max(sortedIntervals.count, 1) where !sortedIntervals.isEmpty {
            if sortedIntervals[i].0 < sortedIntervals[i - 1].1 {
                throw StateFileError.segmentValidationFailed(detail: "段间重叠")
            }
        }

        // 校验③ CRC32 一致（覆盖 header + segTable + payload）
        let crcStored = u32(at: fileLen - 4)
        var crcInput = Data()
        crcInput.append(headerData)
        crcInput.append(Data(bytes[segTableStart..<segTableEnd]))
        crcInput.append(Data(bytes[payloadRegionStart..<(fileLen - 4)]))
        let crcComputed = CRC32.checksum(crcInput)
        guard crcStored == crcComputed else {
            throw StateFileError.segmentValidationFailed(
                detail: "CRC 不一致：存 \(crcStored) vs 算 \(crcComputed)"
            )
        }

        // 解析头部 JSON
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var header = try? decoder.decode(StateHeader.self, from: headerData) else {
            throw StateFileError.segmentValidationFailed(detail: "header JSON 解析失败")
        }
        header.bytes = ByteCounts(
            header: headerLen,
            segTable: segCount * SegmentDescriptor.byteCount,
            payload: Int(sumPayload)
        )

        // 解析各段内容（**按 (sourceIndex, kind) 索引，不按位置猜**）
        var payloads: [Source: SourcePayload] = [:]
        let sourceList = Source.allCases
        for seg in segments {
            guard Int(seg.sourceIndex) < sourceList.count else {
                throw StateFileError.segmentValidationFailed(
                    detail: "sourceIndex \(seg.sourceIndex) 越界"
                )
            }
            let source = sourceList[Int(seg.sourceIndex)]
            var payload = payloads[source] ?? SourcePayload()
            let start = Int(seg.offset)
            let end = start + Int(seg.length)
            let segBytes = Data(bytes[start..<end])

            switch seg.kind {
            case .fBitmap:
                payload.bitmap = segBytes
            case .countedDone:
                payload.countedDoneSlots = try decodeCountedDone(segBytes)
            case .slots:
                payload.slots = try decodeSlots(segBytes)
            }
            payloads[source] = payload
        }

        // 段长恒等式：F 段长 == ceil(slotCount/8)（**与置位数无关**）
        for entry in header.sources {
            guard let payload = payloads[entry.source] else { continue }
            let expectedBitmapBytes = (entry.slotCount + 7) / 8
            guard payload.bitmap.count == expectedBitmapBytes else {
                throw StateFileError.segmentValidationFailed(
                    detail: "来源 \(entry.source.displayName) 的 F 段长 \(payload.bitmap.count) B "
                          + "≠ ceil(slotCount \(entry.slotCount)/8) = \(expectedBitmapBytes) B"
                )
            }
        }

        return StateFileContents(
            header: header,
            segments: segments,
            payloads: payloads,
            fileLength: fileLen
        )
    }

    private static func decodeCountedDone(_ data: Data) throws -> [UInt32] {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return [] }
        var count: UInt32 = 0
        for i in 0..<4 { count |= UInt32(bytes[i]) << (8 * UInt32(i)) }
        let expected = 4 + Int(count) * 4
        guard bytes.count == expected else {
            throw StateFileError.segmentValidationFailed(
                detail: "C_done 段长不符：\(bytes.count) B ≠ \(expected) B"
            )
        }
        var out: [UInt32] = []
        out.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            let base = 4 + i * 4
            var v: UInt32 = 0
            for j in 0..<4 { v |= UInt32(bytes[base + j]) << (8 * UInt32(j)) }
            out.append(v)
        }
        return out
    }

    private static func decodeSlots(_ data: Data) throws -> [UInt32: CandidateID] {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return [:] }
        var count: UInt32 = 0
        for i in 0..<4 { count |= UInt32(bytes[i]) << (8 * UInt32(i)) }
        var out: [UInt32: CandidateID] = [:]
        var off = 4
        for _ in 0..<Int(count) {
            guard off + 14 <= bytes.count else {
                throw StateFileError.segmentValidationFailed(detail: "Slots 段被截断")
            }
            var slot: UInt32 = 0
            for j in 0..<4 { slot |= UInt32(bytes[off + j]) << (8 * UInt32(j)) }
            var btBits: UInt64 = 0
            for j in 0..<8 { btBits |= UInt64(bytes[off + 4 + j]) << (8 * UInt64(j)) }
            var pathLen: UInt16 = 0
            pathLen |= UInt16(bytes[off + 12])
            pathLen |= UInt16(bytes[off + 13]) << 8
            off += 14
            let pl = Int(pathLen)
            guard off + pl <= bytes.count else {
                throw StateFileError.segmentValidationFailed(detail: "Slots 段路径被截断")
            }
            let pathBytes = Array(bytes[off..<(off + pl)])
            off += pl
            let path = String(decoding: pathBytes, as: UTF8.self)
            let birthtime = Date(timeIntervalSince1970: Double(bitPattern: btBits))
            out[slot] = CandidateID(path: path, birthtime: birthtime)
        }
        guard off == bytes.count else {
            throw StateFileError.segmentValidationFailed(
                detail: "Slots 段有尾随字节：解析到 \(off)，全长 \(bytes.count)"
            )
        }
        return out
    }
}

/// CRC32（IEEE 多项式，与 zlib 一致）。
public enum CRC32 {
    /// 查表（延迟初始化，线程安全由 Swift 的全局 `let` 保证）。
    private static let table: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            t[i] = c
        }
        return t
    }()

    /// 计算 CRC32。
    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let idx = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ table[idx]
        }
        return crc ^ 0xFFFF_FFFF
    }
}
