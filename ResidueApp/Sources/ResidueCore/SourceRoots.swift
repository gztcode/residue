import Foundation

/// 来源根路径解析（CR-038）——**纯函数、零 IO、零进程**。
///
/// ## 为什么放在 Core 而不是 App 层
///
/// 路径计算是**判定的一部分**（不变量②「同一判定只有一个实现处」）⇒ 必须可单测。
/// 而本仓库**只有一个 test target（`ResidueCoreTests`，只依赖 `ResidueCore`）**
/// ⇒ 放在 `Sources/ResidueApp/` 下的路径计算**测不到**。
///
/// 所以：`ResidueApp` 层只负责**调上游命令取输出**（IO 编排），
/// 路径计算全部落在本文件（纯计算）—— 依赖方向仍是单向（`ResidueApp` → `ResidueCore`）。
public enum SourceRoots {

    /// 解析全部来源的扫描根。
    ///
    /// - Parameters:
    ///   - home: 用户主目录（`NSHomeDirectory()`）。
    ///   - uvCacheDir: `uv cache dir` 的输出；`nil` 表示探测失败 ⇒ 回退标准路径。
    ///   - npmCacheDir: `npm config get cache` 的输出；`nil` 表示探测失败 ⇒ 回退标准路径。
    ///   - brewCacheDir: `brew --cache` 的输出；`nil` 表示探测失败 ⇒ 回退标准路径。
    /// - Returns: `(来源 rawValue, 扫描根路径)` 数组，**顺序与 `Source.allCases` 一致**。
    public static func resolve(
        home: String,
        uvCacheDir: String? = nil,
        npmCacheDir: String? = nil,
        brewCacheDir: String? = nil
    ) -> [(String, String)] {
        let uv = normalized(uvCacheDir) ?? (home + "/.cache/uv")
        let npmBase = normalized(npmCacheDir) ?? (home + "/.npm")
        let brew = normalized(brewCacheDir) ?? (home + "/Library/Caches/Homebrew")

        return [
            (Source.uvCache.rawValue, uv),
            (Source.npmNpx.rawValue, npmBase + "/_npx"),
            (Source.pipxRun.rawValue, home + "/.local/pipx/venv"),
            // `brew --cache` 指向缓存根，`downloads` 子目录才是可删的下载缓存。
            (Source.homebrewDownloads.rawValue, brew + "/downloads"),
            // cargo / pnpm / bun 走**固定路径、零探测**（零进程开销、零网络）。
            (Source.cargoRegistryCache.rawValue, home + "/.cargo/registry/cache"),
            (Source.pnpmStore.rawValue, home + "/Library/pnpm/store"),
            (Source.bunCache.rawValue, home + "/.bun/install/cache"),
        ]
    }

    /// 去尾部斜杠并去空白；空串视作「探测失败」（⇒ 调用方回退标准路径）。
    ///
    /// ★ 尾斜杠必须去：`brew --cache` 的输出可能带尾 `/` ⇒ 直接拼 `/downloads`
    /// 会得到 `.../Homebrew//downloads` ⇒ 后续叶子路径不含来源片段 ⇒ **一条候选都匹配不到**
    /// （不报错、不崩溃，只是静默为 0 —— 最难查的一类）。
    private static func normalized(_ path: String?) -> String? {
        guard var path else { return nil }
        path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path.isEmpty ? nil : path
    }
}
