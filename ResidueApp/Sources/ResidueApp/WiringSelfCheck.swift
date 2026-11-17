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
            //
            // CR-031 后 `b` 是**累计判定次数**（M5），`slotCount` 是**去重后的位槽数**
            // ⇒ 恒有 `b ≥ slotCount`（每个被判定过的候选至少占一个位槽）。
            // 「被持有数」`pNowCount` 是第三个量，与 `b` 无关。
            check(
                (uvEntry?.b ?? -1) >= (uvEntry?.slotCount ?? -2),
                "b（累计判定次数）≥ slotCount（去重位槽数）；pNowCount 是另一个量，实为 \(model.lastScanDiagnostics.pNowCount)"
            )
        } else {
            check(false, "扫描后仍读不到载体内容")
        }

        print("\n--- 4a2. CR-031 结算写入链（K / J / producedAt 同一次原子写入）---")
        // **这是 CR-031 的核心闭环**：
        // `K` / `J` / `settlement.producedAt` 三个门槛量在运行路径上**从未被写过非空值**
        // → `GateEvaluator.isQualified` 恒 `false` → 自动删除永远点不亮。
        //
        // 走**真文件系统**的完整链路（不注入假判定）：
        //   ① 首轮 full 扫描 → 取快照（写 `T` / `H` / 快照成员集合 / `F` 位图）
        //   ② 删掉一条候选（模拟缓存被清理）
        //   ③ 把观察期计数日推到 14（真实路径要 14 天，这里直接推进载体）
        //   ④ 次轮 full 扫描 → 结算（写 `K` / `J` / `producedAt` / `reportId`）
        //
        // ⚠️ 独立目录 + 独立 `AppModel`：不污染 §1–§4a 的载体与断点。
        let cr031Root = dir.appendingPathComponent("cr031")
        // ⚠️ 路径**必须**含 `/.cache/uv/`：`ScanEngine.SourceRule.match` 按路径片段
        //    判来源（`/.cache/uv/` / `/.npm/_npx/` / `/.local/pipx/venv/`）——
        //    路径不命中 ⇒ 候选数为 0 ⇒ 自检测的其实是「空目录」，不是结算链。
        let cr031UV = cr031Root.appendingPathComponent("fakehome/.cache/uv")
        try? FileManager.default.createDirectory(at: cr031UV, withIntermediateDirectories: true)
        try? Data(repeating: 0x51, count: 4096).write(to: cr031UV.appendingPathComponent("blob-a"))
        try? Data(repeating: 0x52, count: 8192).write(to: cr031UV.appendingPathComponent("blob-b"))

        let cr031StateFile = StateFile(directory: cr031Root.appendingPathComponent("state"))
        let cr031Model = AppModel(
            stateFile: cr031StateFile,
            writer: RecordWriter(directory: cr031Root.appendingPathComponent("state/records"))
        )
        cr031Model.sourceRootsOverride = [
            (Source.uvCache.rawValue, cr031UV.path),
            (Source.npmNpx.rawValue, cr031Root.appendingPathComponent("nonexistent-npm").path),
        ]

        /// 跑一次 `full` 扫描并等它结束（RunLoop 泵，见 §2 的坑）。
        func runFullScan(_ target: AppModel) -> Bool {
            var done = false
            Task { @MainActor in
                await target.runScan(mode: .full)
                done = true
            }
            let limit = Date().addingTimeInterval(120)
            while !done && Date() < limit {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            return done
        }

        check(runFullScan(cr031Model), "CR-031：首轮 full 扫描完成")

        // ---- ① 首轮：只取快照，不结算 ----
        if let c = cr031StateFile.load().contents {
            let uv = c.header.sources.first { $0.source == .uvCache }
            check(uv?.T == 2, "首轮 full 扫描取到快照：T = 2（实为 \(uv?.T ?? -1)）")
            check(uv?.H == 2, "H = min(30, T) = 2（实为 \(uv?.H ?? -1)）")
            check(uv?.K == nil, "首轮**不结算**：K 仍为 null（取快照与结算互斥）")
            check(uv?.J == nil, "首轮**不结算**：J 仍为 null")
            check(c.header.settlement.producedAt == nil, "首轮无结算凭证：settlement.producedAt 仍为 null")
            check(c.header.settlement.reportId == nil, "首轮无结算凭证：reportId 仍为 null")
            check(c.payloads[.uvCache]?.snapshotMembers.count == 2,
                  "快照成员集合已落盘（2 条，实为 \(c.payloads[.uvCache]?.snapshotMembers.count ?? -1)）")
            check((c.payloads[.uvCache]?.bitmap.count ?? 0) > 0,
                  "F 位图已落盘（\(c.payloads[.uvCache]?.bitmap.count ?? 0) B）—— `a` 的写入路径真的走了")
            check(c.header.countedDays == 1, "计数日推进到 1（实为 \(c.header.countedDays)）")
        } else {
            check(false, "CR-031：首轮扫描后读不到载体内容")
        }

        // ---- ①.5 取证字段 `fSetBits` 必须来自载体的真实位图 ----
        //
        // `fSetBits` 曾被**写死为 `0`**：CR-031 之前 `F` 位图恒空，`0` 碰巧是对的；
        // CR-031 之后位图**首次真实承载数据** ⇒ `0` 从「碰巧对」变成「稳定的错」，
        // 而当时**没有任何测试守得住它**。
        //
        // ⚠️ `AppModel` 侧**没有单测**（单测只覆盖 `ResidueCore`）
        // ⇒ 接线自检是这条唯一能守住的地方。
        if let c = cr031StateFile.load().contents {
            // 载体里的真实置位数（**数的是那串字节本身**，不是重新推算）
            let carrierCount = c.payloads.values.reduce(0) { $0 + $1.fSetBitCount }
            // ⚠️ **不能只断言「两边相等」** —— 载体为 0 位时 `0 == 0` **假绿**
            //    （这正是缺陷本身的样子：诊断 0 / 载体 0）。
            //    所以必须钉住**绝对值**：首轮 2 条候选全判「无活引用」⇒ `F` 有 2 位。
            //
            //    「判不出」不会走到这里：本段已有的 `b == 3` 断言要求
            //    `!degraded`（降级时 `b` 不累计），且两条假候选是刚写的真实文件
            //    ⇒ `lstat` 必然成功 ⇒ 判定必然落到 `noLiveReference`。
            check(
                cr031Model.lastScanDiagnostics.fSetBits == carrierCount && carrierCount == 2,
                "取证字段 `fSetBits` 来自载体真实位图（诊断 \(cr031Model.lastScanDiagnostics.fSetBits) / 载体 \(carrierCount)）"
            )
        } else {
            check(false, "CR-031：首轮扫描后读不到载体内容（`fSetBits` 对账）")
        }

        // ---- ② 删掉一条候选 ----
        try? FileManager.default.removeItem(at: cr031UV.appendingPathComponent("blob-b"))

        // ---- ③ 把观察期计数日推到 14（真实路径要 14 天）----
        if var c = cr031StateFile.load().contents {
            c.header.countedDays = ObservationProgress.requiredDays
            try? cr031StateFile.save(header: c.header, payloads: c.payloads)
        }
        cr031Model.loadAndProject()

        check(runFullScan(cr031Model), "CR-031：次轮 full 扫描完成")

        // ---- ④ 次轮：结算 ----
        if let c = cr031StateFile.load().contents {
            let uv = c.header.sources.first { $0.source == .uvCache }
            check(uv?.T == 2, "结算不改动 T（快照冻结，实为 \(uv?.T ?? -1)）")
            check(uv?.K == 1, "K = 1（归因到 1 条，实为 \(uv?.K ?? -1)）")
            check(uv?.J == 1, "J = T − K = 1（实为 \(uv?.J ?? -1)）")
            check((uv?.K ?? 0) + (uv?.J ?? 0) == (uv?.T ?? -1), "K + J == T（恒等式）")
            check(c.header.settlement.producedAt != nil, "结算凭证已写入：settlement.producedAt 非 null")
            check(c.header.settlement.reportId != nil, "结算凭证已写入：reportId 非 null")
            check(uv?.settlementDate != nil, "结算时刻已落盘（settlementDate 非 null）")
            check(uv?.unattributableCount == 0,
                  "「有 N 条无法归因」如实落盘（实为 \(String(describing: uv?.unattributableCount))）")
            // `b`（M5）是**累计**判定次数：首轮 2 条 + 次轮 1 条 = 3。
            // 覆盖写（每轮都写本轮数）⇒ 恒为 1 ⇒ 门槛项 `b ≥ 1` 仍过，
            // 但「M5 累计」这条契约就没了 ⇒ 这里必须钉住 3。
            check(uv?.b == 3, "b 是**累计**（2 + 1 = 3），不是覆盖（实为 \(uv?.b ?? -1)）")
            check(uv?.a == 0, "a = 0（无人持有 ⇒ 无误判，实为 \(uv?.a ?? -1)）")
        } else {
            check(false, "CR-031：次轮扫描后读不到载体内容")
        }

        // ---- ⑤ 结算结果必须出现在**导出报告**里（CR-031 §五③ 裁决）----
        //
        // 数据层已落盘（`unattributableCount == 0`），但**呈现层零命中**时
        // 等于没披露：维护者看报告只看到 `J = 1`，看不到「其中 0 条无法归因」。
        //
        // ⚠️ 必须用 **`cr031Model`**（已结算）而不是主 `model`（未结算）：
        // 未结算时 `unattributableCount == nil` → 渲染为「—」，
        // 与「已结算但确实 0 条无法归因」的「0」**不可区分** ⇒ 用主 model 断言会假绿。
        //
        // ⚠️ 状态列文案**不得写死中文**：`L.applyEnvironment()` 在 App 启动时
        // 已把 `L.current` 改成系统语言（CI runner 可能是 en）⇒ 断言必须跟着语言走。
        do {
            let cr031Report = try Redactor.render(
                try cr031Model.buildReportForExport(),
                context: Redactor.Context.current()
            )
            // 整行断言（T=2 / K=1 / J=1 / 其中无法归因=0 / H=2 / a=0 / b=3）
            // ——顺带钉住列序，多插一列或少插一列都会红。
            //
            // 来源名取 `Source.uvCache.rawValue`（= `uv_cache`）而不是手写字符串：
            // 手写就多出第二处可能漂移的名字。
            let expectedRow = "| \(Source.uvCache.rawValue) | \(L.pick("在域", "In domain")) | 2 | 1 | 1 | 0 | 2 | 0 | 3 |"
            let actualRow = cr031Report
                .split(separator: "\n")
                .first { $0.hasPrefix("| \(Source.uvCache.rawValue) |") } ?? "（报告里没有 \(Source.uvCache.rawValue) 行）"
            check(cr031Report.contains(expectedRow),
                  "导出报告如实披露「其中无法归因」条数（CR-031 §五③）；实为：\(actualRow)")
        } catch {
            check(false, "CR-031 导出报告渲染失败：\(error)")
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
        //
        // ⚠️ 原来的断言只验了盒子本身（`cancel()` 后 `isCancelled == true`）
        // ——那是**恒真**的，与「扫描会不会停下来」毫无关系。
        // 而真实缺陷正是「盒子被取消了，引擎却不知道」：`runScan` 原先
        // **没把 `cancelBox` 接进 `abortCheck`**，取消只在**每条来源之间**
        // 生效一次 → 单来源 11 万条目要整条扫完才停（实测 ~6.7 s）。
        //
        // 这里验行为不验结构：扫一个大树，跑到一半下取消信号，
        // 断言**扫描提前停了**（扫过的条目远少于总量）+ 落了断点。
        let cancelRoot = dir.appendingPathComponent("cancelstate")
        for d in 0..<120 {
            let sub = cancelRoot.appendingPathComponent("d\(d)")
            try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            for f in 0..<8 {
                try? Data(repeating: 0x55, count: 32)
                    .write(to: sub.appendingPathComponent("f\(f)"))
            }
        }
        let totalEntries = 120 * 8        // 960 个叶子
        let cancelBox = CancelBox()
        let cancelEngine = ScanEngine()
        let cancelDone = DispatchSemaphore(value: 0)
        let cancelBoxOut = ResultBox()
        Task.detached(priority: .userInitiated) {
            let r = try? cancelEngine.scan(
                root: cancelRoot.path,
                mode: .full,
                // **与 `AppModel.runScan` 同源**：引擎内部逐目录读同一个盒子
                abortCheck: ScanEngine.AbortCheck {
                    cancelBox.isCancelled ? .userCancelled : nil
                },
                progress: { p in
                    // 扫到 48 条就下取消信号（远早于 960）
                    if p.filesScanned >= 48 { cancelBox.cancel() }
                },
                progressEvery: 8
            )
            cancelBoxOut.store(r)
            cancelDone.signal()
        }
        _ = cancelDone.wait(timeout: .now() + 30)
        let cancelResult = cancelBoxOut.load()

        check(cancelResult?.aborted == .userCancelled, "取消后引擎如实报「用户取消」（E-104）")
        check(
            (cancelResult?.filesScanned ?? totalEntries) < totalEntries / 2,
            "取消在**扫描途中**生效（实扫 \(cancelResult?.filesScanned ?? -1) / 共 \(totalEntries) 条）—— 只在外层循环查一次会让单来源整条扫完"
        )
        check(cancelResult?.checkpoint != nil, "取消落断点（AC-20：重启后可续扫）")

        print("\n--- 4c3. 断点落盘 → 重启 → 续扫（AC-20 · 进程重启后仍可续）---")
        // §4c2 只验了「引擎会返回断点」；这一节验另一半：**断点真的落盘了**。
        // 此前 `runScan` 把 `result.checkpoint` 直接丢弃、日志里
        // `breakpointSaved` 写死 `false` → 进程一重启断点就没了。
        //
        // 走**完整 `AppModel` 路径**（不是直接调引擎）—— 落盘发生在
        // `runScan` 收尾，那才是要验的接线点。
        let resumeRoot = dir.appendingPathComponent("resumestate")
        let resumeScan = resumeRoot.appendingPathComponent("scan")
        let store = CheckpointStore(directory: resumeRoot.appendingPathComponent("state"))
        // ⚠️ 树必须**大** —— 取消要在扫描途中打中，而主 actor 的轮询有开销。
        // 实测：8000 条只要 **257 ms**，取消打不中（`aborted` 恒为 nil）；
        // 200 × 300 = 60000 条约 2 s，留得出取消窗口。
        try? FileManager.default.createDirectory(at: resumeScan, withIntermediateDirectories: true)
        for d in 0..<200 {
            let sub = resumeScan.appendingPathComponent("d\(d)")
            try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            for f in 0..<300 {
                try? Data(repeating: 0x33, count: 16)
                    .write(to: sub.appendingPathComponent("f\(f)"))
            }
        }

        /// 在**主 actor** 上跑一次扫描；`cancel: true` 时在扫描启动后取消它。
        ///
        /// ⚠️ 两个不能踩的坑：
        /// 1. **不能用 `semaphore.wait()`** —— 那占住主线程，而 `runScan` 要在
        ///    主 actor 上继续跑 → 自己等自己（实测 exit 137）。用 RunLoop 泵。
        /// 2. **不能用 `scanProgress.filesScanned` 判「扫到多少了」** ——
        ///    进度经「后台 → `cancelBox` → 主 actor 的 100 ms 定时器」回流，
        ///    而本地树的扫描只要几十毫秒 → 定时器一次都没触发 → 进度永远不涨
        ///    （实测：等 `filesScanned >= 2000` 永远等不到，取消一次都没打中）。
        ///    `cancelScan()` 本身**不依赖进度**（直接写 `cancelBox`），
        ///    所以判据用「`isScanning` 已置位」+ 让扫描跑一小段。
        func runScanAndCancel(_ model: AppModel, cancel: Bool) {
            var finished = false
            Task { @MainActor in
                await model.runScan(mode: .full)
                finished = true
            }
            let deadline = Date().addingTimeInterval(120)
            var sawScanning = false
            var cancelled = false
            var scanElapsed: TimeInterval = 0
            while !finished, Date() < deadline {
                if model.isScanning { sawScanning = true }
                // 扫描启动后让它推进 50 ms（真扫到东西 → 断点里有内容），再取消。
                if cancel, sawScanning, !cancelled, scanElapsed >= 0.05 {
                    model.cancelScan()
                    cancelled = true
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                scanElapsed += 0.01
            }
        }

        // ---- ① 取消 → 断点必须落盘 ----
        let cancelModel = AppModel(
            stateFile: StateFile(directory: resumeRoot.appendingPathComponent("s1")),
            writer: writer, checkpoints: store
        )
        cancelModel.sourceRootsOverride = [(Source.uvCache.rawValue, resumeScan.path)]
        runScanAndCancel(cancelModel, cancel: true)

        if case .usable(let savedCPs) = store.load() {
            check(true, "取消后断点落在 state/checkpoints.json（此前从没落过盘）")
            check(savedCPs[Source.uvCache.rawValue] != nil, "断点按来源分开存（uv_cache 一份）")

            // ---- ② 「重启」：全新 AppModel + 同一 store → 正常扫完 ----
            //
            // 这次不取消。扫完后断点必须被**清除**（没有「未扫完的部分」了）。
            let resumeModel = AppModel(
                stateFile: StateFile(directory: resumeRoot.appendingPathComponent("s2")),
                writer: RecordWriter(directory: resumeRoot.appendingPathComponent("s2/records")),
                checkpoints: store
            )
            resumeModel.sourceRootsOverride = [(Source.uvCache.rawValue, resumeScan.path)]
            runScanAndCancel(resumeModel, cancel: false)   // 不取消：这次要跑完

            check(!resumeModel.isScanning, "续扫跑完了（未再被取消）")
            if case .none = store.load() {
                check(true, "正常扫完后断点被清除（没有未扫完的部分）")
            } else {
                check(false, "正常扫完后断点应被清除，否则下次会拿旧断点续扫")
            }
        } else {
            check(false, "取消后断点应落在 state/checkpoints.json（此前从没落过盘）")
            check(false, "断点按来源分开存（uv_cache 一份）")
        }

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

        print("\n--- 4b. 损坏载体不得被静默重建（不变量④）---")
        // 载体损坏时 `load()` 把它移成 `.corrupt` 并返回只读。若加载流程
        // 继续走「首启 → 写默认 header」，磁盘上会立刻出现一个空载体：
        // 现场被覆盖、`a` 被静默清零。这里用真文件复现那条路径。
        let corruptDir = dir.appendingPathComponent("corrupt")
        try? FileManager.default.createDirectory(at: corruptDir, withIntermediateDirectories: true)
        let corruptFile = corruptDir.appendingPathComponent("state.residue")
        // 造**段校验失败**（E-304）：魔数与 schema 都合法，只有 headerLen 越界。
        //
        // ⚠️ 样本必须避开 E-301。「合法魔数 + 乱码」看着像损坏，实际是
        // `u32(at:4)` 把 `"garb"` 读成 `schemaVersion = 1,734,438,498 > 1`
        // → 抛 `.schemaTooNew`。E-301 的契约行为是**保留文件、只读降级**
        // （用户可能装过更新版本，归档它等于毁掉新版本数据），
        // 与 E-304 的「留档 .corrupt」正好相反。用错样本会测出一个假失败。
        var badCarrier = Array("RSD1".utf8)
        badCarrier += [1, 0, 0, 0]                  // schemaVersion = 1（合法）
        badCarrier += [0xFF, 0xFF, 0xFF, 0xFF]      // headerLen 巨大 → 越界
        badCarrier += [UInt8](repeating: 0, count: 12)  // 补到 24 B ≥ 20 B 前置
        try? Data(badCarrier).write(to: corruptFile)

        let corruptStateFile = StateFile(directory: corruptDir)
        let corruptModel = AppModel(stateFile: corruptStateFile, writer: writer)
        corruptModel.loadAndProject()

        let mainFileExists = FileManager.default.fileExists(atPath: corruptFile.path)
        let corruptCopyExists = FileManager.default.fileExists(
            atPath: corruptDir.appendingPathComponent("state.residue.corrupt").path
        )
        // **两条都要成立**：现场被留档（.corrupt 存在）**且**主文件没被重建。
        // 只判前者会被「留档 + 立刻重建空壳」骗过 —— 那正是静默重建的形态。
        check(corruptCopyExists, "损坏载体现场已留档（.corrupt）")
        check(!mainFileExists, "损坏载体未被静默重建（主文件不应重新出现）")
        check(corruptModel.readOnly, "损坏载体进入只读态")

        // **反向边界**：`E-301`（schema 更高）必须**保留**主文件 —— 只读降级，
        // 不归档、不重置。那是用户装过更新版本写下的载体，归档等于毁数据。
        // 与 E-304 的「留档」相反，两者不可合并处理。
        let newerDir = dir.appendingPathComponent("newer")
        try? FileManager.default.createDirectory(at: newerDir, withIntermediateDirectories: true)
        let newerFile = newerDir.appendingPathComponent("state.residue")
        var newerCarrier = Array("RSD1".utf8)
        newerCarrier += [9, 0, 0, 0]                    // schemaVersion = 9 > 1
        newerCarrier += [UInt8](repeating: 0, count: 12)
        try? Data(newerCarrier).write(to: newerFile)
        let newerModel = AppModel(stateFile: StateFile(directory: newerDir), writer: writer)
        newerModel.loadAndProject()
        check(FileManager.default.fileExists(atPath: newerFile.path),
              "E-301（schema 更高）保留主文件，不归档")
        check(!FileManager.default.fileExists(
                atPath: newerDir.appendingPathComponent("state.residue.corrupt").path),
              "E-301 不得生成 .corrupt（那是 E-304 的处置）")
        check(newerModel.readOnly, "E-301 进入只读降级")

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
