import Foundation

// ============================================================
// Residue · 逐来源扫描统计（CR-043 / 台账 P2-1）
//
// ## 为什么需要它
//
// `~/.npm/_npx` **只增不减**（`npx` 每跑一次临时工具就留一个目录），
// 实测 2026-11-09 本机 106,983 项 / 6.79 s，占全量扫描 12.21 s 的一半以上。
// 产品**不代删**它（那是 npm 自己的缓存），但必须让用户**看得见**
// 「扫描慢主要慢在这里、而且它在长」。
//
// ## 为什么不是新增一个 `Source` case
//
// `_npx` 已经是 `Source.npmNpx` 的扫描根（见 `SourceRoots.resolve`），
// 逐来源统计天然就是「`_npx` 单独一条」。给 `Source` 加 case 会改动
// 声明序 = `state.residue` 段表 `sourceIndex u8` 的隐式 ABI
// （中间插入会让误判数 `a` 归到错误的来源上）。本文件**只做度量**，
// 不碰 `Source` 枚举、不碰任何判定。
//
// ## 为什么耗时在调用点测，不从 `ScanResult` 推
//
// `ScanResult.startedAt` 由调用方以 `now:` 传入（`runScan` 传的是**整轮**
// 起始时刻），`finishedAt` 才是该来源扫完的时刻 ⇒ 两者相减是「累计偏移」，
// 不是该来源的耗时。所以逐来源耗时只能在 `engine.scan(...)` 前后各取一次
// 时刻（见 `AppModel.runScan`），本文件只负责**换算与排序**。
// ============================================================

/// 一个来源的扫描统计（**纯度量，不参与任何判定**）。
public struct SourceScanStat: Codable, Sendable, Equatable {
    /// 来源（`Source.rawValue`）。
    public var source: String
    /// 该来源扫到的**叶子条目数**（不含目录；与 `ScanResult.filesScanned` 同义）。
    public var items: Int
    /// 该来源的扫描耗时（毫秒）。
    public var durationMs: Int

    public init(source: String, items: Int, durationMs: Int) {
        self.source = source
        self.items = items
        self.durationMs = durationMs
    }
}

/// 逐来源扫描统计的**唯一**聚合处。
public enum SourceScanStats {

    /// 两个时刻之间的毫秒数（**四舍五入**，负数钳到 0）。
    ///
    /// 取整用 `rounded()` 而不是截断：`6.789 s` 截断成 `6788 ms`
    /// 会让界面显示 `6.78 秒`，与实测差一位 —— 度量值不该有系统性偏差。
    public static func milliseconds(from start: Date, to end: Date) -> Int {
        let ms = ((end.timeIntervalSince(start)) * 1000).rounded()
        return ms < 0 ? 0 : Int(ms)
    }

    /// 把调用点测到的原始值整理成**按耗时从长到短**的统计行。
    ///
    /// 顺序：耗时降序；耗时相同 → 按 `Source` 声明序（**确定性**，
    /// 不依赖输入顺序，否则同一份数据两次渲染可能换位置）。
    /// 不认识的来源排在最后、按 `rawValue` 排 —— 不丢、不猜。
    public static func make(
        _ measured: [(source: String, items: Int, durationMs: Int)]
    ) -> [SourceScanStat] {
        let declOrder = Source.allCases.enumerated().reduce(into: [String: Int]()) {
            $0[$1.element.rawValue] = $1.offset
        }
        return measured
            .map { SourceScanStat(source: $0.source, items: $0.items, durationMs: $0.durationMs) }
            .sorted { lhs, rhs in
                if lhs.durationMs != rhs.durationMs { return lhs.durationMs > rhs.durationMs }
                let l = declOrder[lhs.source] ?? Int.max
                let r = declOrder[rhs.source] ?? Int.max
                if l != r { return l < r }
                return lhs.source < rhs.source
            }
    }
}
