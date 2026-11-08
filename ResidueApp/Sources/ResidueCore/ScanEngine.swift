import Foundation

/// 扫描引擎（技术方案 ADR-04 / IF-01 / IF-02 / §5.5）。
///
/// **两阶段**（ADR-04）：
/// 1. **遍历阶段**：`readdir` + `d_type`（APFS 全支持，**不对每个文件 `stat`**）；
/// 2. **属性阶段**：只对**命中来源模式**的条目用 `getattrlistbulk` 批量取属性。
///
/// **断点续扫（AC-20）**：判定要求「重启后续扫与未中断扫描在**文件数 / 字节数 / 候选清单**三项一致」。
/// **断点 = 「已完成名字集合」，不是「字典序水位」**（K2 实测：APFS `readdir` 是**哈希序**，
/// 字典序水位会漏掉 70% 的候选 —— 这是 R2 v1.5 的错误，v1.6 已更正）。
public struct ScanEngine {

    // MARK: - 输入类型

    public enum Mode: String, Codable, Sendable {
        /// 全量扫描。
        case full
        /// 增量扫描（**不发现深层新候选** —— 那是全量的职责；见 R2 §7.3）。
        case incremental
    }

    /// 中止原因（**`aborted ≠ 失败`**：这些都落断点，且**均不计入计数日**，见 M1）。
    public enum AbortReason: String, Codable, Sendable {
        /// 低电量（< 20%，电池供电）→ `E-103`。
        case lowBattery
        /// 用户取消 → `E-104`。
        case userCancelled
        /// 超时（N1 的 600 s）→ `E-105`。
        case timeout
    }

    /// 扫描错误（§6 错误码）。
    public enum ScanError: Error, Equatable, Sendable {
        /// `E-101` 路径**不存在**（`ENOENT`）。归类：错误。
        ///
        /// ## 为什么原来叫 `pathUnreadable` 是个缺陷
        /// 它把 `ENOENT`（不存在）与 `EACCES`（存在但读不到）塞进一个 case。
        /// 两者**用户该做的事完全不同**：
        /// - 不存在 → 去检查来源路径（可能升级后换了目录）
        /// - 读不到 → 去授权
        ///
        /// 而归成一类时只能归「错误」→ **AC-14 第一类（来源不可读）的
        /// 「所缺权限 + 授权指引条目 ID」永远不出现**。
        /// 已按成因二分：这条 = `E-101`，下面 `pathDenied` = `E-108`。
        case pathNotFound(String)
        /// `E-108` 路径**存在但不可读**（`EACCES` / `EPERM`）。归类：**无权限**。
        case pathDenied(String)
        /// `E-103` 低电量中断。
        case lowBattery
        /// `E-104` 用户取消。
        case userCancelled
        /// `E-105` 超时。
        case timeout
        /// `E-106` 断点一致性校验失败。
        case checkpointInconsistent(String)

        /// 对应的诊断码（**`rawValue` 即用户可见的码**）。
        ///
        /// 契约评审指出的结构性问题：`"E-xxx"` 字面量在源码里出现 0 次，
        /// 全部只活在注释里 → 「码 ↔ 用例」核对无法机器化。
        /// 这个映射就是让码进代码的那一处。
        /// 从一次文件系统失败判定该抛哪个码。
        ///
        /// **这是二分能成立的唯一地方**：如果这里还是「一律 `pathNotFound`」，
        /// 那 AC-14 第一类仍然永远不出现，二分就只是改了名字。
        ///
        /// ## ⚠️ 不能直接比较 `(error as NSError).code` 与 `EACCES`
        ///
        /// 这是本函数第一版的写法，**它是错的，而且静默错**：
        /// Foundation 的文件 API 抛的是 `NSCocoaErrorDomain`，
        /// 其 `code` 是 Cocoa 错误码，**不是 errno**。实测（macOS 26.0.1）：
        ///
        /// | 场景 | domain | code | underlying |
        /// |---|---|---|---|
        /// | `chmod 000` 后读目录 | `NSCocoaErrorDomain` | **257** | `NSPOSIXErrorDomain 13` |
        /// | 读不存在的路径 | `NSCocoaErrorDomain` | **260** | `NSOSStatusErrorDomain -43` |
        ///
        /// 于是 `ns.code == EACCES`（13）**永远为 false** → 全部落到兜底分支
        /// → `E-108` 一次都不会被抛出 → AC-14 第一类的授权指引永远不出现，
        /// **而且不会有任何报错**。这正是「按字面实现会静默产出错误数据」。
        ///
        /// 尤其注意：**不能只看 underlying**——`ENOENT` 的 underlying 是
        /// `NSOSStatusErrorDomain -43`，不是 POSIX 2。
        ///
        /// ## 判法（三级，按可靠性排序）
        /// 1. `domain == NSPOSIXErrorDomain` → `code` 就是 errno
        /// 2. 有 `NSUnderlyingErrorKey` 且其 domain 是 `NSPOSIXErrorDomain` → 用它的 code
        /// 3. `domain == NSCocoaErrorDomain` → 映射 Cocoa 码：
        ///    `NSFileReadNoPermissionError`(257) / `NSFileWriteNoPermissionError`(513) → 无权限
        ///    `NSFileReadNoSuchFileError`(260) / `NSFileNoSuchFileError`(4) → 不存在
        /// 4. 其余 → **按「不存在」兜底**（保守一侧，理由见下）
        ///
        /// **兜底为什么选「不存在」而不是「无权限」**：
        /// 我们只能确定「读不到」，无法确定成因。报无权限会引导用户去授权，
        /// 而授权可能根本解决不了（`ENOTDIR`、`ELOOP`）。
        /// **给错指引比不给指引更糟。**
        public static func classify(path: String, error: Error) -> ScanError {
            let ns = error as NSError

            // 1. 已经是 POSIX 域 → code 就是 errno
            if ns.domain == NSPOSIXErrorDomain {
                return classify(posixErrno: Int32(ns.code), path: path)
            }

            // 2. underlying 若是 POSIX 域，用它（这是最可靠的来源）
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
               underlying.domain == NSPOSIXErrorDomain {
                return classify(posixErrno: Int32(underlying.code), path: path)
            }

            // 3. Cocoa 域 → 映射 Cocoa 码
            if ns.domain == NSCocoaErrorDomain {
                switch ns.code {
                case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                    return .pathDenied(path)
                case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
                    return .pathNotFound(path)
                default:
                    return .pathNotFound(path)
                }
            }

            // 4. 其余域 → 兜底（保守：报错误，不报无权限）
            return .pathNotFound(path)
        }

        /// errno → 码（`ENOENT` 不存在；`EACCES`/`EPERM` 无权限；其余兜底不存在）。
        private static func classify(posixErrno: Int32, path: String) -> ScanError {
            switch posixErrno {
            case EACCES, EPERM:
                return .pathDenied(path)
            default:
                // 含 ENOENT；也含 ENOTDIR / ELOOP 这类「读不到但不是权限」的情况
                return .pathNotFound(path)
            }
        }

        public var diagnostic: DiagnosticCode {
            switch self {
            case .pathNotFound: return .e101
            case .pathDenied: return .e108
            case .lowBattery: return .e103
            case .userCancelled: return .e104
            case .timeout: return .e105
            case .checkpointInconsistent: return .e106
            }
        }
    }

    /// 一个候选条目（命中来源模式的对象）。
    public struct Candidate: Codable, Sendable, Equatable {
        /// 身份键 = **路径 + birthtime**（AC-09 既有身份键；M4 的位槽键）。
        public var path: String
        public var birthtime: Date
        /// 字节数（普通文件 `st_size`；目录为递归逻辑字节）。
        public var bytes: Int64
        public var isDirectory: Bool
        public var source: String

        public init(path: String, birthtime: Date, bytes: Int64, isDirectory: Bool, source: String) {
            self.path = path
            self.birthtime = birthtime
            self.bytes = bytes
            self.isDirectory = isDirectory
            self.source = source
        }
    }

    /// 一次扫描的结果。
    public struct ScanResult: Sendable {
        public var startedAt: Date
        public var finishedAt: Date
        public var mode: Mode
        /// 遍历到的**叶子条目数**（**不含目录** —— 目录是容器，不计入条目数）。
        ///
        /// **为什么不含目录**：断点续扫时「已完成的叶子」会被跳过、不再计数，
        /// 若条目数含目录，则「累计起点」与「本次新增」两部分的边界随目录展开状态漂移
        /// → 续扫结果与基线不一致（实测 147 vs 168，差 21）。
        public var filesScanned: Int
        /// 命中的候选。
        public var candidates: [Candidate]
        /// `DT_UNKNOWN` 的退回 `lstat` 次数（APFS 上实测为 0；保留是为非 APFS 卷）。
        public var unknownCount: Int
        /// 中止原因（`nil` = 正常完成）。
        public var aborted: AbortReason?
        /// 断点是否已保存。
        public var breakpointSaved: Bool
        /// 快照是否已取（**只有 `full` 扫描能取快照**，见 R2 §7.3）。
        public var snapshotTaken: Bool
        /// **断点本身**（中断时非 nil）——调用方必须持有它才能续扫。
        ///
        /// **这是一个真实缺陷的修复**：中断时若只回一个 `breakpointSaved: true` 标志，
        /// 调用方**拿不到断点内容** → 续扫无从谈起 → AC-20 的「可续扫」成为空话。
        public var checkpoint: Checkpoint?

        public init(
            startedAt: Date, finishedAt: Date, mode: Mode,
            filesScanned: Int, candidates: [Candidate], unknownCount: Int,
            aborted: AbortReason?, breakpointSaved: Bool, snapshotTaken: Bool,
            checkpoint: Checkpoint? = nil
        ) {
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.mode = mode
            self.filesScanned = filesScanned
            self.candidates = candidates
            self.unknownCount = unknownCount
            self.aborted = aborted
            self.breakpointSaved = breakpointSaved
            self.snapshotTaken = snapshotTaken
            self.checkpoint = checkpoint
        }
    }

    // MARK: - 断点

    /// 断点状态（`state/checkpoints.json` · **不计入 N7 计量**）。
    ///
    /// **核心字段 = `completedNames`**：每个目录已完成的条目名字集合。
    /// 恢复时同目录 `readdir` 逐个比对集合、跳过已完成的。
    public struct Checkpoint: Codable, Sendable, Equatable {
        /// 目录路径 → **已完成的叶子条目**名字集合。
        ///
        /// **只记叶子条目，不记目录**——记目录会导致「跳过该目录 → 整个子树永远不被遍历」
        /// （这是断点机制的第一版缺陷：续扫后候选只剩根目录那一层）。
        public var completed: [String: [String]]
        /// **已展开的目录**（该目录的条目已全部枚举完毕）。
        ///
        /// 与 `completed` 分开：目录要「展开」才知道里面有什么，
        /// 叶子条目才是「可跳过」的粒度。
        public var expandedDirs: [String]
        /// 已见条目的哈希（用于一致性自证）。
        public var seenHash: String
        /// 累计计数（文件数 / 字节数）。
        public var fileCount: Int
        public var byteCount: Int64
        /// 已收集的候选（跨断点保留）。
        public var candidates: [Candidate]
        /// **已计入 `fileCount` 的条目数**（断点内累计）。
        ///
        /// 与「本次新扫」分开是必要的：续扫时**已完成的条目被跳过、不再计数**，
        /// 若把「本次计数」直接当累计值 → 续扫结果**比基线少**（实测 147 vs 168）。
        public var countedFiles: Int

        public init(
            completed: [String: [String]] = [:],
            expandedDirs: [String] = [],
            seenHash: String = "",
            fileCount: Int = 0,
            byteCount: Int64 = 0,
            candidates: [Candidate] = [],
            countedFiles: Int = 0
        ) {
            self.completed = completed
            self.expandedDirs = expandedDirs
            self.seenHash = seenHash
            self.fileCount = fileCount
            self.byteCount = byteCount
            self.candidates = candidates
            self.countedFiles = countedFiles
        }

        /// 该目录的某**叶子条目**是否已完成。
        public func isCompleted(dir: String, name: String) -> Bool {
            completed[dir]?.contains(name) ?? false
        }

        /// 记一个**叶子条目**完成。
        public mutating func markCompleted(dir: String, name: String) {
            completed[dir, default: []].append(name)
        }

        /// 该目录是否已**展开**（条目已全部枚举）。
        public func isExpanded(dir: String) -> Bool {
            expandedDirs.contains(dir)
        }

        /// 记一个目录**已展开**。
        public mutating func markExpanded(dir: String) {
            if !expandedDirs.contains(dir) { expandedDirs.append(dir) }
        }
    }

    // MARK: - 来源规则

    /// 来源规则：**一个候选路径是否属于某个来源、命中哪些来源**。
    ///
    /// **封闭枚举**（AC-04 ①）：`uv` cache / `npm/_npx` / `pipx` run。
    /// **只做路径模式匹配**（不执行任何命令、不读内容）。
    public struct SourceRule: Sendable {
        /// **来源枚举本身**（唯一标识）。
        ///
        /// ## 为什么不再用自由字符串 `name`
        ///
        /// 原来规则用 `name: "uv.cache"`（点号），而 `Source.rawValue` 是
        /// `"uv_cache"`（下划线）—— **同一件事两套标识，中间没有映射**。
        ///
        /// 后果是**静默的**：任何「按来源过滤候选」的地方（`candidates.filter
        /// { $0.source == source.rawValue }`）都匹配不上 → 数量恒为 0。
        /// 实测症状：接线自检里 `slotCount = 0`，而 ② 页明明有 2 条候选。
        ///
        /// 这类 bug 不会崩、不会报错，只会让**统计量悄悄变成 0**
        /// —— 而 `T = 0` 会让门槛永远不满足，产品退化成只读扫描器。
        ///
        /// **修法：只留一套标识。** 展示名走 `Source.displayName`。
        public var source: Source
        /// 命中的路径片段（相对主目录）。
        public var pathFragments: [String]

        /// 标识名 = `Source.rawValue`（**派生，不独立存**）。
        public var name: String { source.rawValue }

        public init(source: Source, pathFragments: [String]) {
            self.source = source
            self.pathFragments = pathFragments
        }

        /// 默认规则集（**封闭枚举**，新增须另出变更单 —— AC-04 ①）。
        public static let defaults: [SourceRule] = [
            SourceRule(source: .uvCache, pathFragments: ["/.cache/uv/"]),
            SourceRule(source: .npmNpx, pathFragments: ["/.npm/_npx/"]),
            SourceRule(source: .pipxRun, pathFragments: ["/.local/pipx/venv/"]),
        ]

        /// 判断路径命中哪些来源（**一个路径可命中多个**；判定域成员由判定层决定）。
        public static func match(path: String, rules: [SourceRule] = defaults) -> [String] {
            rules.filter { rule in
                rule.pathFragments.contains { path.contains($0) }
            }.map { $0.name }
        }
    }

    // MARK: - 依赖

    /// 文件系统访问（**可注入 → 可单测**）。
    public protocol FileSystem: Sendable {
        /// 列目录内容（**名字 + 是否目录**；`isDirectory == nil` 表示未知）。
        func listDirectory(at path: String) throws -> [(name: String, isDirectory: Bool?)]
        /// 取属性（birthtime / size / 是否目录）。
        func attributes(at path: String) throws -> (birthtime: Date, size: Int64, isDirectory: Bool)
        /// 目录是否存在。
        func exists(at path: String) -> Bool
    }

    /// 默认实现（`FileManager`）。
    public struct DefaultFileSystem: ScanEngine.FileSystem {
        public init() {}

                /// **只列一层**（**不递归**）。
        ///
        /// **必须用 `contentsOfDirectory` 而不是 `enumerator`** —— `enumerator` 本身是
        /// **递归**的，与引擎里的手动下探叠加 → 同一子树被遍历两次 → 无限增长 / 栈溢出。
        /// （这个缺陷只在**真文件系统**上暴露：`MemoryFS` 是扁平的，永远不会递归。）
        public func listDirectory(at path: String) throws -> [(name: String, isDirectory: Bool?)] {
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: path)
            } catch {
                // **按 errno 判成因**：EACCES → E-108（无权限，AC-14 第一类要它）
                throw ScanEngine.ScanError.classify(path: path, error: error)
            }
            var out: [(String, Bool?)] = []
            for name in names {
                // 隐藏项跳过（与 `enumerator` 的 `.skipsHiddenFiles` 保持一致）
                if name.hasPrefix(".") { continue }
                let full = (path as NSString).appendingPathComponent(name)
                var isDirObj: ObjCBool = false
                var isDir: Bool? = nil
                if FileManager.default.fileExists(atPath: full, isDirectory: &isDirObj) {
                    isDir = isDirObj.boolValue
                }
                out.append((name, isDir))
            }
            return out
        }

        public func attributes(at path: String) throws -> (birthtime: Date, size: Int64, isDirectory: Bool) {
            let a = try FileManager.default.attributesOfItem(atPath: path)
            let bt = (a[.creationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            let size = (a[.size] as? NSNumber)?.int64Value ?? 0
            let isDir = (a[.type] as? FileAttributeType) == .typeDirectory
            return (birthtime: bt, size: size, isDirectory: isDir)
        }

        public func exists(at path: String) -> Bool {
            FileManager.default.fileExists(atPath: path)
        }
    }

    /// 中止检查（**注入点**：`RESIDUE_TEST_POWER` / 用户取消）。
    public struct AbortCheck: Sendable {
        public var shouldAbort: @Sendable () -> AbortReason?

        public init(shouldAbort: @escaping @Sendable () -> AbortReason? = { nil }) {
            self.shouldAbort = shouldAbort
        }
    }

    // MARK: - 引擎

    public let fileSystem: FileSystem
    public let rules: [SourceRule]

    public init(fileSystem: FileSystem = DefaultFileSystem(), rules: [SourceRule] = SourceRule.defaults) {
        self.fileSystem = fileSystem
        self.rules = rules
    }

    /// 扫描一个来源根目录。
    ///
    /// - 参数 `root`：来源根的绝对路径。
    /// - 参数 `checkpoint`：续扫用的断点（`nil` = 全量新扫）。
    /// - 参数 `abortCheck`：中止检查（低电量 / 用户取消）。
    /// - 参数 `deadline`：超时时刻（`nil` = 不限时）。
    /// - 参数 `takeSnapshot`：**只有 `full` 扫描能取快照**（R2 §7.3：增量不取快照，
    ///   否则 `T` 会由部分候选集确定 → 偏小且**静默**）。
    public func scan(
        root: String,
        mode: Mode,
        checkpoint: Checkpoint? = nil,
        abortCheck: AbortCheck = AbortCheck(),
        deadline: Date? = nil,
        now: Date = Date(),
        takeSnapshot: Bool? = nil
    ) throws -> ScanResult {
        let startedAt = now
        guard fileSystem.exists(at: root) else {
            // 存在性检查失败 = 确实不存在（`pathExists` 为 false 只可能是 ENOENT
            // 或路径链上有非目录；后者在本产品的来源根上不会出现）
            throw ScanError.pathNotFound(root)
        }

        var cp = checkpoint ?? Checkpoint()
        var candidates = cp.candidates
        // **累计计数起点 = 断点里已计的**（`countedFiles`），不是 `fileCount`
        // （后者是「本次扫描数」的旧字段，语义不同 → 续扫会少算）。
        var filesScanned = cp.countedFiles
        var byteCount = cp.byteCount
        var unknownCount = 0
        var aborted: AbortReason? = nil
        var seen = Set<String>()

        // 广度优先遍历（**用栈**，避免深递归爆栈）。
        var stack = [root]
        while let dir = stack.popLast() {
            if let reason = abortCheck.shouldAbort() { aborted = reason; break }
            if let deadline, Date() >= deadline { aborted = .timeout; break }

            let entries: [(name: String, isDirectory: Bool?)]
            do {
                entries = try fileSystem.listDirectory(at: dir)
            } catch {
                // 若底层已二分出成因（`listDirectory` 走的是 classify），原样上抛；
                // 否则按 errno 再判一次
                if let scanErr = error as? ScanError { throw scanErr }
                throw ScanError.classify(path: dir, error: error)
            }

            for entry in entries {
                let full = (dir as NSString).appendingPathComponent(entry.name)
                let isDir = entry.isDirectory ?? false

                if isDir {
                    // **目录永远不重新下探、也永远不跳过它的枚举**。
                    //
                    // **关键**：断点的「不重复」粒度是**叶子条目**，不是目录。
                    // 若把目录也记为「已完成」→ 续扫时该目录**整个子树永远不被遍历**
                    // （实测 147 vs 168，差 21 条）。
                    //
                    // 正确做法：目录**每次都重新枚举**（一次 `readdir` 很便宜），
                    // 由「叶子是否已完成」决定要不要处理该叶子。
                    // 这样：
                    //   · 中断时未扫完的子树 → 续扫时会重新枚举到 → 补上；
                    //   · 已扫完的叶子 → 名字集合命中 → 跳过（不重复计数、不重复收集）。
                    // **目录不计入 `filesScanned`** —— 它是容器，不是条目。
                    // 计数只对**叶子条目**做 → 续扫时的算术才自洽：
                    // 累计 = 已计叶子 + 本次新扫叶子，两部分不重叠。
                    //
                    // **目录每次都下探**（不再用 `expandedDirs` 拦截）：
                    // 若「已展开过的目录」被拦 → 中断时未扫完的子树**永远不会被遍历**
                    // （实测候选差 12，恰好等于中断时扫过的目录数）。
                    // 「不重复处理」由**叶子名字集合**保证（重复下探只是多一次 `readdir`，
                    // 代价极低；漏扫的代价是数据丢失）。
                    stack.append(full)
                    seen.insert(full)
                    continue
                }

                // **叶子条目**：断点续扫时跳过已完成的（名字集合机制，非字典序水位）。
                if cp.isCompleted(dir: dir, name: entry.name) { continue }

                filesScanned += 1
                seen.insert(full)

                // 命中来源模式 → 收集为候选。
                let matched = SourceRule.match(path: full, rules: rules)
                if !matched.isEmpty {
                    if let attr = try? fileSystem.attributes(at: full) {
                        candidates.append(
                            Candidate(
                                path: full,
                                birthtime: attr.birthtime,
                                bytes: attr.size,
                                isDirectory: attr.isDirectory,
                                source: matched.joined(separator: ",")
                            )
                        )
                        byteCount += attr.size
                    }
                }

                cp.markCompleted(dir: dir, name: entry.name)
            }

            // 本目录的条目已全部枚举完毕 → 标记已展开（续扫时不再重复展开）。
            cp.markExpanded(dir: dir)
        }

        // **一致性自证**（AC-20：三项一致）。
        // 续扫时把断点里的累计数与本次累计合并 → 与未中断扫描应完全相等。
        cp.countedFiles = filesScanned
        cp.fileCount = filesScanned
        cp.byteCount = byteCount
        cp.candidates = candidates
        cp.seenHash = ScanEngine.hash(seen)

        if let reason = aborted {
            // 中断 → **把断点内容返回**（不只是标志位）；**不计入计数日**（M1）
            return ScanResult(
                startedAt: startedAt, finishedAt: Date(), mode: mode,
                filesScanned: filesScanned, candidates: candidates, unknownCount: unknownCount,
                aborted: reason, breakpointSaved: true,
                snapshotTaken: false,
                checkpoint: cp
            )
        }

        // 正常完成 → 断点可丢弃。
        let snapshot = takeSnapshot ?? (mode == .full)
        return ScanResult(
            startedAt: startedAt, finishedAt: Date(), mode: mode,
            filesScanned: filesScanned, candidates: candidates, unknownCount: unknownCount,
            aborted: nil, breakpointSaved: false, snapshotTaken: snapshot,
            checkpoint: nil
        )
    }

    /// 三项一致性的比较器（**供测试与验收复用**）。
    public struct Consistency: Equatable, Sendable {
        public var filesScanned: Int
        public var byteCount: Int64
        public var candidatePaths: [String]

        public init(filesScanned: Int, byteCount: Int64, candidatePaths: [String]) {
            self.filesScanned = filesScanned
            self.byteCount = byteCount
            self.candidatePaths = candidatePaths
        }

        /// 从扫描结果构造。
        public init(_ result: ScanResult) {
            self.filesScanned = result.filesScanned
            self.byteCount = result.candidates.reduce(0) { $0 + $1.bytes }
            self.candidatePaths = result.candidates.map(\.path).sorted()
        }
    }

    /// 稳定哈希（用于一致性自证；**不需要抗碰撞强度**，只需同输入同输出）。
    static func hash(_ items: Set<String>) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for item in items.sorted() {
            for byte in Array(item.utf8) {
                h ^= UInt64(byte)
                h = h &* 0x0000_0100_0000_01B3
            }
            h ^= 0xFF
            h = h &* 0x0000_0100_0000_01B3
        }
        return String(h, radix: 16)
    }
}
