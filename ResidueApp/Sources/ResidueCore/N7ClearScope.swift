import Foundation

// ============================================================
// Residue · N7「一键清除采集物与日志」的作用域
//
// 契约落点：PRD v5.6 N7 行 + 偏差 3 · R2 v1.10 §10.3 · S-10。
//
// ## 范围（契约逐项落点）
//   `records/*.jsonl`
//   + `state/journal.jsonl`
//   + `state/checkpoints.json`
//   + `state/migrating.json`
//   + `state/pending-execution.jsonl`（待补写队列 · CR-045）
//   + `*.bak` / `*.corrupt` / `*.tmp`（载体的备份 / 损坏留档 / 写中临时文件）
//
// ## **不含** `state.residue` 本体（不变量④ · S2）
//   载体存着 `a`（L0 误判记录）。清掉它 = 给用户开一条
//   「一键洗掉误判记录」的旁路 ⇒ 门槛 `a = 0` 会被绕过。
//   **用户的清除动作不构成 `a` 的重置路径**（PRD 偏差 3）。
//   「一键清除」≠「卸载」——首演判据只挂「卸载」（R2 §10.3）。
//
// ## `.corrupt` 的条件
//   `.corrupt` 是 `a` 的**唯一幸存副本**（主载体被移走后的现场留档）：
//   · 主载体**还在** → `.corrupt` 只是损坏现场留档 ⇒ 纳入清除范围；
//   · 主载体**没了** → `.corrupt` 就是 `a` 的唯一副本 ⇒ **保留**。
//
// ## 为什么范围定义在 Core
//   Core 无 UI 依赖 ⇒ 这条范围能被**单测**逐项断言（App 层没有测试目标）。
// ============================================================

/// N7「一键清除采集物与日志」的作用域（**唯一实现处**）。
public enum N7ClearScope {

    /// 契约点名的清除范围（**不含** `state.residue` 本体）。
    ///
    /// - Parameters:
    ///   - stateFile: 载体读写器（提供 `.bak` / `.tmp` / `.corrupt` / `journal.jsonl` / `migrating.json` 的路径）。
    ///   - checkpoints: 断点存储（提供 `checkpoints.json` 的路径）。
    ///   - recordsDirectory: `.jsonl` 记录目录（整个目录都在范围内）。
    /// - Returns: 应当被清除的路径（存在的才清；不存在的跳过）。
    public static func paths(
        stateFile: StateFile,
        checkpoints: CheckpointStore,
        recordsDirectory: URL
    ) -> [URL] {
        var urls: [URL] = [
            recordsDirectory,              // `records/*.jsonl`
            stateFile.journalURL,           // `state/journal.jsonl`
            checkpoints.fileURL,            // `state/checkpoints.json`
            stateFile.migrationProgressURL, // `state/migrating.json`
            // `state/pending-execution.jsonl`（CR-045）：待补写队列里装的是
            // **还没写进举证链的执行记录**（含 `restorePath`）⇒ 含用户路径副本，
            // 漏清即等于「清除后仍留用户路径副本」（质量 B-07）。
            stateFile.pendingExecutionURL,
            // 它原子替换时的临时文件（崩在替换中间就会留下，内容同样是用户路径）。
            JSONLStore.temporaryURL(for: stateFile.pendingExecutionURL),
            stateFile.backupURL,            // `*.bak`
            stateFile.tempURL               // `*.tmp`
        ]
        // `.corrupt` 的条件：主载体还在 ⇒ 它只是损坏现场留档，可清。
        // 主载体没了 ⇒ 它是 `a` 的唯一幸存副本 ⇒ 保留（见文件头）。
        if FileManager.default.fileExists(atPath: stateFile.fileURL.path) {
            urls.append(stateFile.corruptURL) // `*.corrupt`
        }
        return urls
    }

    /// 执行清除。
    ///
    /// **不删 `state.residue` 本体**（见文件头）。
    ///
    /// - Returns: 实际被删掉的路径。**删不掉的不会出现在结果里**（文件仍在原处）——
    ///   本层没有错误上报通道，界面侧无法呈现「有一项没清掉」。
    @discardableResult
    public static func clear(
        stateFile: StateFile,
        checkpoints: CheckpointStore,
        recordsDirectory: URL
    ) -> [URL] {
        let fm = FileManager.default
        var removed: [URL] = []
        for url in paths(stateFile: stateFile, checkpoints: checkpoints, recordsDirectory: recordsDirectory) {
            guard fm.fileExists(atPath: url.path) else { continue }
            // 删不掉就留着 —— 不阻断其余项的清除。
            try? fm.removeItem(at: url)
            if !fm.fileExists(atPath: url.path) { removed.append(url) }
        }
        return removed
    }
}
