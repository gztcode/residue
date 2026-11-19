import Foundation

// MARK: - 进度

/// 一次扫描的**进度快照**（`Sendable`，可跨 actor 边界传递）。
///
/// ## 为什么需要它
///
/// 若只是把扫描搬到后台线程而**不汇报进度**，用户看到的是「按了没反应」——
/// **那和卡死没有区别**，甚至更糟（用户会去重复点击）。
///
/// ## 为什么在 Core（CR-037 §3.1）
///
/// ① `fraction`（进度环弧长）要**在 Core 算好**再传给界面 ——
/// 界面禁止算术（不变量①），除法不得出现在视图层；
/// ② 跨来源的累计（分子 / 分母 / 条目数）要**可单测** —— Core 层才能被单测覆盖。
public struct ScanProgress: Sendable, Equatable {
    /// 当前正在扫的来源（`Source.rawValue`）。
    public var source: String = ""
    /// 已扫描的条目数。
    public var filesScanned: Int = 0
    /// 已发现的候选数。
    public var candidatesFound: Int = 0
    /// 已耗时（秒）。
    public var elapsed: TimeInterval = 0
    /// 是否仍在运行。
    public var isRunning: Bool = false
    /// 已完成的来源数（**分子**）。
    ///
    /// 语义：**已经扫完（或已跳过、已失败）的来源个数**。
    /// 「跳过」也算完成 —— 否则一个不存在的来源根会让进度环永远停在中途。
    public var completedSources: Int = 0
    /// 本次扫描的来源总数（**分母**）。
    ///
    /// ⚠️ **0 = 分母未知**，**不是**「没有来源」。
    /// 界面据此画「只有轨道、没有弧」的环（守不变量③：不把未知画成 0）。
    public var totalSources: Int = 0

    /// 显式初始化。
    ///
    /// ⚠️ **必须显式写**：Swift 的 memberwise init 只在**全部属性都有默认值**时
    /// 隐式生成，且**不是 `public`** —— 迁到 Core 后 App 层就构造不出来了。
    public init(
        source: String = "",
        filesScanned: Int = 0,
        candidatesFound: Int = 0,
        elapsed: TimeInterval = 0,
        isRunning: Bool = false,
        completedSources: Int = 0,
        totalSources: Int = 0
    ) {
        self.source = source
        self.filesScanned = filesScanned
        self.candidatesFound = candidatesFound
        self.elapsed = elapsed
        self.isRunning = isRunning
        self.completedSources = completedSources
        self.totalSources = totalSources
    }

    /// **进度环弧长**（Core 侧算好 —— 界面禁止算术，不变量①）。
    ///
    /// ⚠️ **分母未知 ⇒ 返回 `nil`**，不得用 `?? 0` 糊过去：
    /// 「分母未知」与「进度为 0」在界面上是两件事（守不变量③）。
    ///
    /// ⚠️ **夹到 `[0, 1]`** —— 分子超过分母时不得画出大于整圆的弧。
    public var fraction: Double? {
        guard totalSources > 0 else { return nil }
        return min(1, max(0, Double(completedSources) / Double(totalSources)))
    }

    /// **给用户看的进度文案**。
    ///
    /// ## 为什么写「已扫描 N 项」而不是「已完成 x%」
    ///
    /// 总条目数**事先不知道**（要先扫一遍才知道）→ 百分比是假的。
    /// 「已扫描 N 项 + 已用时」是**能如实说出口**的量。
    public var displayText: String {
        guard isRunning else { return "" }
        var parts: [String] = []
        // 首段：来源计数（CR-037 §3.3）。
        // ⚠️ 分母未知时只说「正在扫描…」—— **不得**编造「0/0」。
        if totalSources > 0 {
            parts.append(UICopy.scanSourcesCompleted(done: completedSources, total: totalSources))
        } else {
            parts.append(UICopy.scanningInProgress())
        }
        parts.append(L.pick("已扫描 \(filesScanned.formatted()) 项", "\(filesScanned.formatted()) items scanned"))
        if candidatesFound > 0 {
            parts.append(L.pick(
                "发现 \(candidatesFound.formatted()) 个可回收条目",
                "\(candidatesFound.formatted()) reclaimable items found"
            ))
        }
        parts.append(L.pick(
            String(format: "已用时 %.1f 秒", elapsed),
            String(format: "%.1f s elapsed", elapsed)
        ))
        return parts.joined(separator: " · ")
    }
}

// MARK: - 累计器

/// **跨来源的进度累计器**（CR-037 §3.7）。
///
/// ## 为什么要有它
///
/// ① **只有一处实现**：分子 / 分母 / 条目数的累计若散落在 `AppModel` 的
///    多个回调里，跨来源的加法就会散成几份（不变量②）；
/// ② **可单测**：累计规则必须能被独立验证，
///    否则「条目数在来源边界上倒退」这种缺陷只能靠人眼发现；
/// ③ **不复制生产逻辑**：测试直接测这个**生产侧公开原语**
///    （先例：`L0Probe.vnodeFDList`），不在测试里重写一份聚合。
///
/// ## 三个报告点
///
/// | 点 | 时机 | 方法 | 分子 | 分母 |
/// |---|---|---|---|---|
/// | (a) | 来源列表解析完、**进循环之前** | `starting(elapsed:)` | 0 | `totalSources` |
/// | (b) | 来源**内**的进度回调 | `progressing(...)` | 当前来源**未完成** | `totalSources` |
/// | (c) | 每个来源**处理完** | `completing(...)` | 自增后 | `totalSources` |
///
/// ⚠️ **(b) 点非 mutating** —— 它只把当前来源的增量**临时叠加**到显示值上，
/// 累加器自身不变；该来源真正完成时由 (c) 点一次性计入。否则同源会被数两遍。
public struct ScanProgressAccumulator: Sendable {
    /// 本次扫描的来源总数（**分母**）。
    public let totalSources: Int
    /// 已完成的来源数（**分子**）。
    public private(set) var completedSources: Int = 0
    /// **已完成来源**的条目数合计（不含正在扫的那个来源）。
    public private(set) var filesScanned: Int = 0
    /// **已完成来源**的候选数合计（不含正在扫的那个来源）。
    public private(set) var candidatesFound: Int = 0

    public init(totalSources: Int) {
        self.totalSources = totalSources
    }

    /// **(a) 点：分母先到。**
    ///
    /// 扫描一开始就报出「共几个来源」⇒ 进度环立刻能画出弧（哪怕弧长为 0）。
    public func starting(elapsed: TimeInterval) -> ScanProgress {
        ScanProgress(
            source: "", filesScanned: 0, candidatesFound: 0,
            elapsed: elapsed, isRunning: true,
            completedSources: completedSources, totalSources: totalSources
        )
    }

    /// **(b) 点：来源进行中。**
    ///
    /// ⚠️ **非 mutating** —— 不把 `deltaFiles` 累进 `filesScanned`：
    /// 那样该来源在 (c) 点完成时会被**数两遍**。
    public func progressing(
        source: String, deltaFiles: Int, deltaCandidates: Int, elapsed: TimeInterval
    ) -> ScanProgress {
        ScanProgress(
            source: source,
            filesScanned: filesScanned + deltaFiles,
            candidatesFound: candidatesFound + deltaCandidates,
            elapsed: elapsed, isRunning: true,
            completedSources: completedSources, totalSources: totalSources
        )
    }

    /// **(c) 点：某个来源处理完**（正常扫完 / 根不存在 / 扫描失败 —— 三条出口共用）。
    ///
    /// 分子 +1，该来源的最终条目数一次性计入合计。
    public mutating func completing(
        source: String, files: Int, candidates: Int, elapsed: TimeInterval
    ) -> ScanProgress {
        completedSources += 1
        filesScanned += files
        candidatesFound += candidates
        return ScanProgress(
            source: source,
            filesScanned: filesScanned,
            candidatesFound: candidatesFound,
            elapsed: elapsed, isRunning: true,
            completedSources: completedSources, totalSources: totalSources
        )
    }
}
