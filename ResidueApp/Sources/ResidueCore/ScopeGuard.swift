import Foundation

// ============================================================
// Residue · 执行范围守卫（AC-19 · R2:218 / :225）
//
// ## 契约原文（R2 技术方案 v1.8 · 删除前置断言）
//
// > 前置断言：目标存在、**非符号链接**（`lstat` 判 `S_ISLNK`）、
// > **真实路径在该来源允许根内**、**同卷**、**普通文件或目录**。
//
// > 失败：`E-201` 源不存在 / `E-202` 废纸篓不可写 / `E-203` 跨卷 /
// > `E-204` 符号链接或越界路径 / `E-205` 同名冲突无法消解 / `E-207` 体积不可得。
//
// ## 为什么这是「误删」级的防线
//
// 扫描端曾经用 `fileExists(atPath:isDirectory:)` 判目录 —— 而该 API
// **跟随符号链接**（已用真文件系统实测确认）：来源根里一个指向
// `~/Documents` 的 symlink 会被判成「目录」→ 被压栈枚举 →
// **`~/Documents` 下的每个文件都成为候选**。执行端再按路径 `moveItem`，
// 就把来源根之外的文件移进了废纸篓。
//
// 所以执行前必须自己再判一次（**不信扫描结果**）：
// 判「这条路径本身现在是什么」，而不是「它指向什么」。
//
// ## 为什么放 Core 而不是 TrashExecutor 里内联
//
// 判定要能单测（真文件系统造 symlink / 跨卷）。`TrashExecutor` 只做
// 文件操作，判定归 Core —— 与本仓库「执行器不做判定」的既有分工一致。
// ============================================================

/// 执行范围守卫：删除前的越界 / 符号链接 / 跨卷判定。
public enum ScopeGuard {

    /// 拒绝原因（**值与诊断码一一对应**，不复用、不含糊）。
    public enum Rejection: Equatable, Sendable {
        /// 目标不存在 → `E-201`（源不存在）。
        case notFound
        /// 目标是符号链接 → `E-204`（不跟随、不删链接目标）。
        case symlink
        /// 真实路径落在允许根之外 → `E-204`（越界）。
        case outOfRoot
        /// 与来源根不在同一卷 → `E-203`（跨卷，源仍在原位）。
        case crossVolume

        /// 对应的诊断码。
        public var diagnostic: DiagnosticCode {
            switch self {
            case .notFound: return .e201
            case .symlink, .outOfRoot: return .e204
            case .crossVolume: return .e203
            }
        }
    }

    /// 判一条候选路径**现在**是否允许被删除。
    ///
    /// 四道判定按契约顺序，任一不过即返回该原因（**先命中先返回**）：
    /// 1. `lstat` 成功（存在）
    /// 2. 不是符号链接（`S_ISLNK` 不在 `st_mode` 里）
    /// 3. 真实路径（`realpath`）在允许根之内
    /// 4. 与允许根同卷（`st_dev` 相等）
    ///
    /// - Parameters:
    ///   - path: 候选路径（扫描期记录的那条）。
    ///   - allowedRoot: 该来源的允许根（`uv` cache dir / `npm/_npx` 等）。
    ///   - fileManager: 可注入（单测）。
    /// - Returns: `nil` = 通过；否则为拒绝原因。
    public static func check(
        path: String,
        allowedRoot: String,
        fileManager: FileManager = .default
    ) -> Rejection? {
        // ---- ① 存在性 + ② 非符号链接（同一次 `lstat` 取两样）----
        var st = stat()
        guard lstat(path, &st) == 0 else {
            return .notFound
        }
        guard (st.st_mode & S_IFMT) != S_IFLNK else {
            return .symlink
        }

        // ---- ③ 真实路径在允许根内 ----
        //
        // 用 `realpath` 而不是字符串前缀：路径里可能有 `..`、`.` 或
        // 中间某级是 symlink。字符串前缀会被 `/a/b/../../etc` 这类路径骗过。
        guard let real = realpathString(path) else {
            // `realpath` 失败（通常 = 中间某级不存在）→ 按不存在处理
            return .notFound
        }
        guard let realRoot = realpathString(allowedRoot) else {
            // 根都解析不了 → 无法证明在范围内 → 拒绝（**不把未知判为安全**）
            return .outOfRoot
        }
        // 根特殊处理（与白名单同一条边界纪律）：`/` 之下一切都算在内
        let inRoot: Bool = realRoot == "/"
            ? real.hasPrefix("/")
            : (real == realRoot || real.hasPrefix(realRoot + "/"))
        guard inRoot else {
            return .outOfRoot
        }

        // ---- ④ 同卷 ----
        //
        // `moveItem` 跨卷会退化成「复制 + 删除」，中途失败会留下半个文件；
        // 且契约要求跨卷判 `E-203`（源仍在原位）。故执行前先判 `st_dev`。
        var rootSt = stat()
        guard stat(allowedRoot, &rootSt) == 0 else {
            return .outOfRoot
        }
        guard st.st_dev == rootSt.st_dev else {
            return .crossVolume
        }

        return nil
    }

    /// `realpath(3)` 的 Swift 封装（失败返回 `nil`）。
    ///
    /// 用系统 `realpath` 而不是自己拼字符串：它会把 `..`、`.`、中间 symlink
    /// 全部解析成规范的绝对路径 —— 这正是「真实路径」的语义。
    private static func realpathString(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
