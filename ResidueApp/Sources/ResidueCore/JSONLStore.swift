import Foundation
import Darwin

/// JSONL 文件的落盘原语（**编码策略 / 原子替换 / 追加 + `fsync` 的唯一实现处**）。
///
/// ## 为什么单独抽出来
///
/// 同一份「执行记录」有两个落点：
///
/// | 落点 | 作用 |
/// |---|---|
/// | `records/execution.jsonl` | AC-18 举证链的数据源 |
/// | `state/pending-execution.jsonl` | 待补写队列（写盘失败时**恢复信息的保险箱**） |
///
/// 两者**必须是同一种格式**。格式一旦分叉，待补写队列里的记录补写回
/// `execution.jsonl` 时就解不开 ⇒ **恢复路径当场丢失，且没有任何报错**
/// （与 CLAUDE.md §七-6「编解码策略必须成对」同款）。
///
/// 故编码 / 解码策略只在这里写一次，两处共用。
public struct JSONLStore: Sendable {

    /// 目标文件。
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    // MARK: - 写入

    /// 追加一行（**`fsync` 真落盘**）。
    ///
    /// **未落盘即「无法证明」** —— 与举证链同一口径，故这里显式 `synchronize()`，
    /// 不接受「攒内存最后统一写」。
    public func append<T: Encodable>(_ value: T) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var line = try Self.encoder().encode(value)
        line.append(0x0A)   // '\n' —— jsonl 一行一条

        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        // 落盘（不是可选优化：未落盘 = 无法证明）
        try handle.synchronize()
    }

    /// 原子替换全部内容（临时文件 → `fsync` → `rename(2)`）。
    ///
    /// **不许「先删后写」** —— 中途崩溃会留下半个文件，
    /// 而这个文件里装的是**还没写进举证链的恢复路径**，丢了就再也回不来。
    ///
    /// - 临时文件落在**同目录**（`state/*.tmp` ⇒ 落在 N7 的清除范围内）。
    public func replaceAll<T: Encodable>(_ values: [T]) throws {
        var payload = Data()
        for value in values {
            var line = try Self.encoder().encode(value)
            line.append(0x0A)
            payload.append(line)
        }
        try replaceAllBytes(payload)
    }

    /// 原子替换全部内容（**原始字节** —— 解不开的行原样保留，不许悄悄丢掉）。
    public func replaceAllBytes(_ payload: Data) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let temporary = Self.temporaryURL(for: url)
        if !fm.fileExists(atPath: temporary.path) {
            fm.createFile(atPath: temporary.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: payload)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        // `rename(2)`：同卷内原子替换（先删后写会留半个文件）。
        guard rename(temporary.path, url.path) == 0 else {
            throw JSONLStoreError.replaceFailed(path: url.path, code: errno)
        }
    }

    /// 原子替换时的临时文件路径（**唯一实现处** —— N7 的清除范围要按它点名）。
    ///
    /// 落在**同目录**（`state/*.tmp` ⇒ 落在 N7 的清除范围内）。
    public static func temporaryURL(for url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".tmp")
    }

    // MARK: - 读取

    /// 读回全部行（逐行解码；**坏行跳过**，不抛 —— 一行坏不代表整份文件坏）。
    public func readAll<T: Decodable>(_ type: T.Type) throws -> [T] {
        let lines = try rawLines()
        var out: [T] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            guard let value = try? Self.decoder().decode(T.self, from: line) else { continue }
            out.append(value)
        }
        return out
    }

    /// 读回全部行的**原始字节**（一行一条，含解不开的行）。
    public func rawLines() throws -> [Data] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { $0.data(using: .utf8) }
    }

    // MARK: - 编解码

    /// 编码策略（**唯一实现处**）。
    ///
    /// - `dateEncodingStrategy = .iso8601`：**记录时刻只有一个来源 = 该行写入时刻**（M6 判据）。
    /// - `outputFormatting = [.sortedKeys`：同一份记录写出来的字节稳定，便于比对。
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// 解码策略（**必须与 `encoder()` 成对** —— 不对称则写进去读不出来，且没有任何报错）。
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// `JSONLStore` 的失败原因。
public enum JSONLStoreError: Error, Equatable, Sendable {
    /// 原子替换失败（`rename(2)` 返回非 0）。
    case replaceFailed(path: String, code: Int32)
}
