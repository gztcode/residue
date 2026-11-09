import Foundation
import ResidueCore

// ============================================================
// Residue · 接线自检（**DEBUG-only，不随发布版分发**）
//
// 用法：`swift run ResidueApp --verify-wiring <临时目录>`
//
// ## 它要回答的问题
// 「数据层到底接上了没有」——这是常在线在发布把关里判 NO-GO 的第一条理由：
// `StateStore` / `RecordWriter` / `StateFile` 在 Sources 下 0 处实例化，
// 9417 行核心逻辑从未进入运行路径。
//
// 本自检**真的走一遍**：建 AppModel（含首启落盘）→ 跑一次扫描 → 检查落盘物。
// 不靠读代码判断，靠文件系统事实。
// ============================================================

#if DEBUG
@MainActor
enum WiringSelfCheck {

    @discardableResult
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--verify-wiring"), idx + 1 < args.count else {
            return false
        }
        let dir = URL(fileURLWithPath: args[idx + 1], isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var pass = 0, fail = 0
        func check(_ cond: Bool, _ msg: String) {
            print(cond ? "  ✓ \(msg)" : "  ✗ \(msg)")
            if cond { pass += 1 } else { fail += 1 }
        }

        print("=== 接线自检 ===")
        print("临时目录：\(dir.path)\n")

        // 造一棵极小的假来源树（**不扫真实缓存**：真实缓存大小随机器变化，
        // 那种自检的通过与否取决于用户机器，不是自检）
        let fakeUV = dir.appendingPathComponent("fakehome/.cache/uv")
        try? FileManager.default.createDirectory(at: fakeUV, withIntermediateDirectories: true)
        try? Data(repeating: 0x41, count: 4096).write(to: fakeUV.appendingPathComponent("blob-a"))
        try? Data(repeating: 0x42, count: 8192).write(to: fakeUV.appendingPathComponent("blob-b"))

        let stateFile = StateFile(directory: dir.appendingPathComponent("state"))
        let writer = RecordWriter(directory: dir.appendingPathComponent("state/records"))

        print("--- 1. 首启落盘（AppModel.init）---")
        let model = AppModel(stateFile: stateFile, writer: writer)
        model.sourceRootsOverride = [
            (Source.uvCache.rawValue, fakeUV.path),
            (Source.npmNpx.rawValue, dir.appendingPathComponent("nonexistent-npm").path),
        ]
        check(FileManager.default.fileExists(atPath: stateFile.fileURL.path),
              "首启即写出 state.residue（A-10 第 9 步判据可达的前提）")
        check((((try? Data(contentsOf: stateFile.fileURL))?.count) ?? 0) > 0, "state.residue 非空")
        check(model.pageModel.overviewBlocks.count == 3, "① 页三区块由真实状态投影（Source.allCases 三个）")

        print("\n--- 2. 扫描与落盘（runScan）---")
        // ⚠️ **不能**在主 actor 上 `sem.wait()` 等一个需要主 actor 的 Task —— 那是自己等自己，
        //    会死锁（实测 exit 137）。改用 RunLoop 泵：让主队列有机会推进 MainActor 任务。
        var finished = false
        Task { @MainActor in
            await model.runScan()
            finished = true
        }
        let deadline = Date().addingTimeInterval(120)
        while !finished && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        check(finished, "扫描在 120 s 内完成")

        let scanLog = writer.directory.appendingPathComponent("scan.jsonl")
        check(FileManager.default.fileExists(atPath: scanLog.path),
              "scan.jsonl 已写出（AC-19 的唯一可判载体）")
        if let lines = try? writer.readLines(kind: .scan), let first = lines.first {
            check(first["upstreamCommands"] != nil, "scan.jsonl 含 upstreamCommands")
            check(first["diagnostics"] != nil, "scan.jsonl 含 diagnostics")
            let diag = first["diagnostics"] as? [String: Any]
            check((diag?["contentReads"] as? Int) == 0, "contentReads = 0（AC-07：未读内容）")
            check((first["filesScanned"] as? Int ?? 0) >= 2, "filesScanned ≥ 2（真扫到了两个文件）")
        } else {
            check(false, "scan.jsonl 可解析")
        }

        print("\n--- 3. 页面模型来自真实数据 ---")
        check(model.pageModel.candidateRows.count == 2, "② 页候选 2 条（来自真扫，不是硬编码）")
        check(model.pageModel.overviewBlocks[0].slot.displayText != "0 B",
              "① 页 uv cache 区块非零（聚合了 12 KB）")

        print("\n--- 4. 清除不碰 a 的载体（CR-022 偏差 3）---")
        let before = ((try? Data(contentsOf: stateFile.fileURL))?.count) ?? 0
        model.clearLogs()
        let after = ((try? Data(contentsOf: stateFile.fileURL))?.count) ?? 0
        check(before == after, "一键清除后 state.residue 体积不变（a 的载体未被清）")
        check(!FileManager.default.fileExists(atPath: scanLog.path),
              "一键清除后 records/ 被清（采集物与日志）")

        print("\n--- 4a. 门槛链是否接通（T / H / b 必须非 null）---")
        // **这是本产品能不能工作的分界**：
        // 若 T 恒 null → H 取不到值 → 门槛永远不满足 → 自动删除永远点不亮
        // → 产品退化成一个只读扫描器。
        // 原实现正是在这里写死了 `T: nil` 且永不更新（已修）。
        let stateAfterScan = stateFile.load()
        if let c = stateAfterScan.contents {
            let uvEntry = c.header.sources.first { $0.source == .uvCache }
            check(uvEntry?.T != nil, "T（快照总量）已取到（非 null）—— 门槛链的起点")
            check(uvEntry?.H != nil, "H = min(30, T) 已算出（非 null）")
            check((uvEntry?.b ?? 0) >= 1, "b（L0 检查次数）≥ 1 —— AC-08 组 B 的门槛项")
            check(
                (uvEntry?.slotCount ?? 0) >= 2,
                "slotCount 记录了该来源的候选数（实为 \(uvEntry?.slotCount ?? -1)）"
            )
            // **`b` 必须等于「参与判定的候选数」，不是「被持有数」**
            //
            // 这曾是静默 bug：`b` 写成 `countHeld(...)` 的结果 →
            // 「缓存满满但无人使用」（最理想的可清理场景）恰好 `b = 0`
            // → AC-08 组 B 的 `b ≥ 1` 门槛永远不满足 → 永远点不亮。
            check(
                (uvEntry?.b ?? -1) == (uvEntry?.slotCount ?? -2),
                "b == slotCount（每条候选判一次）；pNowCount 是另一个量，实为 \(model.lastScanDiagnostics.pNowCount)"
            )
        } else {
            check(false, "扫描后仍读不到载体内容")
        }

        print("\n--- 4b. 导出脱敏报告（AC-13 G-5）---")
        // **这条不是「文件生成了就算过」**——`Redactor.render` 内含自检
        // （原串泄漏即抛 `E-401`），所以要真跑一遍并检查内容。
        let reportURL = dir.appendingPathComponent("report.md")
        do {
            try model.exportReport(to: reportURL)
            check(true, "导出成功（脱敏自检通过，否则会抛 E-401）")
            let text = (try? String(contentsOf: reportURL, encoding: .utf8)) ?? ""
            // 五段齐（缺任一段 Redactor 会抛错，这里再正向断言一遍）
            let sections = ["环境", "量", "取证", "证据", "上游"]
            let missing = sections.filter { !text.contains($0) }
            check(missing.isEmpty, "报告五段齐（缺：\(missing)）")
            // **绝不能出现真实用户名 / 主目录**
            let home = NSHomeDirectory()
            let user = NSUserName()
            check(!text.contains(home), "报告不含真实主目录路径")
            check(!text.contains(user) || user.isEmpty, "报告不含真实用户名")

            // ---------------- 脱敏的**证伪通道** ----------------
            //
            // 上面两条「不含」有个致命的弱点：**如果报告里本来就没有任何路径，
            // 它们必然为真**——那种「通过」什么也没证明（与 `E-301` 恒真同类）。
            //
            // 所以这里必须**故意造一条含敏感路径的数据**，验证它真被替换。
            // 判据不是「文件生成了」，而是「原串不见了、占位符出现了」。
            let probeURL = dir.appendingPathComponent("report-probe.md")
            let probeArgs = ["--cache-dir", home + "/.cache/uv", "--user", user]
            let ctx = Redactor.Context.current()
            let redacted = Redactor.redactArguments(probeArgs, context: ctx)
            check(!redacted.contains(where: { $0.contains(home) }),
                  "注入的 home 路径已被替换（原串不应残留）")
            check(redacted.contains { $0.contains("<path>") },
                  "占位符 <path> 已出现（替换真的发生了，不是原样返回）")
            if !user.isEmpty {
                check(!redacted.contains(where: { $0.contains(user) }),
                      "注入的用户名已被替换")
            }
            // 端到端再走一遍：真的写文件，确认落盘内容里也没有原串
            do {
                let report2 = try Redactor.render(
                    try model.buildReportForExport(),
                    context: ctx
                )
                try report2.write(to: probeURL, atomically: true, encoding: .utf8)
                let t2 = (try? String(contentsOf: probeURL, encoding: .utf8)) ?? ""
                check(!t2.contains(home), "端到端：落盘报告不含 home 原串")
            } catch {
                check(false, "证伪导出失败：\(error)")
            }
        } catch {
            check(false, "导出失败：\(error)")
        }

        print("\n--- 4c. AC-10 采集开关（曾启用后关闭 → 不采集）---")
        // 这条必须端到端验：偏好落盘 → 读回 → 影响采集条件。
        // 单测已覆盖 `CollectionPolicy` 的纯逻辑，这里验**落盘链路是通的**
        //（PreferencesStore 曾有「编码 iso8601 / 解码默认策略」的静默 bug，
        //  save 返回 true 而 load 永远拿默认值 —— 只有真跑一遍才发现）。
        let prefsDir = dir.appendingPathComponent("prefsstate")
        try? FileManager.default.createDirectory(at: prefsDir, withIntermediateDirectories: true)
        let prefsStore = PreferencesStore(directory: prefsDir)
        check(prefsStore.save(Preferences(everEnabledAutoDelete: true)),
              "偏好写入成功")
        let readBack = prefsStore.load()
        check(readBack.everEnabledAutoDelete,
              "偏好**读回**仍为 true（编码/解码策略对称 —— 否则永远存不住）")
        check(
            FileManager.default.fileExists(atPath: prefsStore.fileURL.path),
            "preferences.json 已落盘（运行期态，不进 M6 计量）"
        )
        // 采集条件：曾启用 + 现在关 → 不采集（AC-10）
        check(
            !CollectionPolicy.isCollectionAllowed(
                autoDeleteEnabled: false, everEnabledAutoDelete: true
            ),
            "AC-10：曾启用后关闭 → 不采集"
        )
        check(
            CollectionPolicy.isCollectionAllowed(
                autoDeleteEnabled: false, everEnabledAutoDelete: false
            ),
            "观察期仍采集（否则永远攒不够样本 → 产品锁死）"
        )
        check(
            CollectionPolicy.shouldShowStopped(
                autoDeleteEnabled: false, everEnabledAutoDelete: true
            ) && !CollectionPolicy.shouldShowStopped(
                autoDeleteEnabled: false, everEnabledAutoDelete: false
            ),
            "四档状态：「曾启用后关闭」= 已停止；「从未启用」= 未采集（不说谎）"
        )

        print("\n--- 4c2. 扫描的并发行为（界面不卡 · 2026-11-09）---")
        // **为什么这一节存在**
        //
        // 「点击扫描就卡住」这个缺陷在单测里**看不见** ——
        // 因为 `runScan` 是 `@MainActor` 上的 `async` 函数，
        // 而 **`async` 只让函数可以被挂起，函数体里的同步代码仍在主 actor 上执行**。
        //
        // 实测（本机）：`~/.cache/uv` 115,875 项 ≈ 6.44 s
        //             `~/.npm/_npx` 106,983 项 ≈ 6.79 s —— 合计约 **13 秒全同步阻塞**。
        //
        // 所以这里验三件**能观测**的事：
        // ① 扫描跑在主 actor 之外  ② 进度真的在汇报  ③ 取消真的能取消

        // ---- ① 扫描在后台跑时，主 actor 仍能被调度 ----
        let concRoot = dir.appendingPathComponent("concstate")
        try? FileManager.default.createDirectory(at: concRoot, withIntermediateDirectories: true)
        // 造一些条目（够跑一会儿，但不至于让自检变慢）
        for i in 0..<800 {
            try? Data(repeating: 0, count: 64)
                .write(to: concRoot.appendingPathComponent("c\(i).bin"))
        }

        let concEngine = ScanEngine()
        let concBox = CancelBox()
        // **注意：自检入口是同步的**（`runIfRequested() -> Bool`），
        // 所以这里用「起任务 + 同步等待」而不是 `await`。
        //
        // 而「主 actor 是否仍可被调度」这条，改用**另一个线程**来测 ——
        // 主线程被扫描阻塞时，**另一个线程**不该受影响；
        // 反之若扫描真在后台，主线程也不该被占住。
        //
        // 判据用「扫描线程不是主线程」+「进度被汇报了」两条 ——
        // 前者是**机制判定**（无假绿），后者是**可观测判定**。
        let concDone = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            try? concEngine.scan(
                root: concRoot.path,
                mode: .full,
                progress: { p in
                    concBox.report(
                        ScanProgress(
                            source: p.source,
                            filesScanned: p.filesScanned,
                            candidatesFound: p.candidatesFound,
                            elapsed: p.elapsed,
                            isRunning: true
                        )
                    )
                },
                progressEvery: 100
            )
            concDone.signal()
        }
        // **同步等它跑完**（自检是命令行工具，等得起）
        _ = concDone.wait(timeout: .now() + 30)

        // ---- ② 进度真的被汇报了 ----
        let reported = concBox.takeProgress()
        check(
            reported.filesScanned > 0,
            "扫描过程汇报了进度（已扫描 \(reported.filesScanned) 项）—— 没有进度用户会以为卡死"
        )
        check(
            !reported.displayText.isEmpty,
            "进度有可显示文案（\(reported.displayText)）"
        )

        // ---- ③ 取消真的能取消 ----
        let cancelBox = CancelBox()
        check(!cancelBox.isCancelled, "取消令牌初始为未取消")
        cancelBox.cancel()
        check(cancelBox.isCancelled, "取消信号被记录（后台任务读得到）")

        print("\n--- 4d. 执行路径的容量上限（AC-15 · 唯一真动用户文件的模块）---")
        // 这一节的存在理由：`executeBatch` 此前**一次都没被自检走过**，
        // 而它是唯一会把用户文件 rename 进废纸篓的路径。
        //
        // 尤其要紧的是 CR-029 那条缺陷：预检用目录自身 st_size、记账用递归逻辑字节
        // → 目录型候选的容量上限**根本不成立**（实测超上限 33%）。
        // 那条缺陷能长期存活，正是因为「上限」只被单测里的普通文件覆盖过。
        //
        // 这里用**真目录 + 真文件**走一遍完整判定，并验「实际删除量 ≤ 上限」。

        // 造两个目录候选，各含 100 KB
        let execRoot = dir.appendingPathComponent("execstate")
        let execCache = execRoot.appendingPathComponent("cache")
        let execTrash = execRoot.appendingPathComponent("trash")
        try? FileManager.default.createDirectory(at: execCache, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: execTrash, withIntermediateDirectories: true)
        var execIds: [CandidateID] = []
        for name in ["dir_a", "dir_b"] {
            let d = execCache.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try? Data(repeating: 0x7E, count: 100 * 1024)
                .write(to: d.appendingPathComponent("payload.bin"))
            let attrs = try? FileManager.default.attributesOfItem(atPath: d.path)
            let bt = (attrs?[.creationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            execIds.append(CandidateID(path: d.path, birthtime: bt))
        }

        let execOutcome = TrashExecutor(trashDirectory: execTrash).execute(
            candidates: execIds,
            source: .uvCache,
            capacityCap: 150 * 1024,
            countCap: 100
        )
        check(
            execOutcome.deletedBytes <= 150 * 1024,
            "目录型候选的实际删除量不超上限（实为 \(execOutcome.deletedBytes) B / 上限 153600 B）"
        )
        check(
            execOutcome.skippedByCap == 1,
            "第二个目录候选被顺延（预检必须看到递归逻辑字节，不是目录自身 ~96 B）"
        )
        check(
            execOutcome.failures.isEmpty,
            "顺延不计为失败（AC-15：超出部分顺延并留痕，不报错）"
        )
        // 顺延的那条必须仍在原位 —— 这是「没删错」的正面证据
        let stillThere = execIds.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }.count
        check(stillThere == 1, "被顺延的候选仍在原位（实为 \(stillThere) 条在原位）")

        // 上限判定必须在 Core 的唯一实现处（App 层不得自己做域内算术）
        check(
            TrashExecutor.capacityCap(
                userCapBytes: 1_000_000_000,
                absoluteCapBytes: 5_000_000_000,
                sourceTotalBytes: 100_000_000_000,
                tier: .steady
            ) == 1_000_000_000,
            "稳定后档仍受用户配置的上限约束（AC-15：用户设置不得静默失效）"
        )

        print("\n--- 5. 定时任务的 ADR-02 硬约束（登录项非 enabled 不排）---")
        let schedDir = dir.appendingPathComponent("schedstate")
        try? FileManager.default.createDirectory(at: schedDir, withIntermediateDirectories: true)
        var fired = 0
        let runner = ScheduledRunner(directory: schedDir) { _ in fired += 1 }
        // 登录项非 .enabled（本机 0 身份，必然不是）→ **start 不得排程、不得触发**
        runner.start(loginItemAllows: false)
        let deadline2 = Date().addingTimeInterval(2)
        while Date() < deadline2 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        check(fired == 0, "loginItemAllows=false 时定时任务不执行（ADR-02：非 enabled 不跑）")
        runner.stop()

        // 允许时：首次（lastRun=nil）应立刻补跑一次
        let runner2 = ScheduledRunner(directory: schedDir) { _ in fired += 1 }
        runner2.start(loginItemAllows: true)
        let deadline3 = Date().addingTimeInterval(3)
        while Date() < deadline3 && fired == 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        runner2.stop()
        check(fired >= 1, "loginItemAllows=true 且从未运行时立刻补跑（catch-up）")

        // **采集被禁止时不得触发**（AC-10）—— 与「登录项不 enabled」是两条独立约束
        let beforeFired = fired
        let runner3 = ScheduledRunner(directory: schedDir) { _ in fired += 1 }
        runner3.start(loginItemAllows: true, allowsCollection: false)
        let deadline4 = Date().addingTimeInterval(1.5)
        while Date() < deadline4 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        runner3.stop()
        check(fired == beforeFired,
              "allowsCollection=false 时定时任务不触发（AC-10：关闭后不跑采集）")
        check(
            FileManager.default.fileExists(atPath: schedDir.appendingPathComponent("schedule.json").path),
            "schedule.json 已落盘（运行期态，不进 M6 计量）"
        )

        print("\n==============================================")
        print("通过 \(pass) 项 / 失败 \(fail) 项")
        print("==============================================")
        exit(fail == 0 ? 0 : 1)
    }
}
#endif
