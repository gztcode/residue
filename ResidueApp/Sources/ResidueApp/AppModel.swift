import AppKit
import Foundation
import Observation
import ResidueCore

// ============================================================
// Residue · 应用模型（**真实 IO 编排层**）
//
// ## 它补的是什么
// 之前 App 层只引用 `SemanticSlot` / `StateLabel` / `UICopy` 三个纯展示类型，
// `ScanEngine` / `L0Probe` / `TrashExecutor` / `StateFile` / `Retention` / `Redactor`
// **零处实例化** —— 业务逻辑一行都没进运行路径，七页渲染的是硬编码假数据。
// 本文件把它们接起来。
//
// ## 它只做编排，不做判定、不做算术
//   - 判定 → `GateEvaluator`
//   - 聚合 / 格式化 → `PageModelBuilder`（Core）
//   - 本文件只负责「按什么顺序调谁、失败怎么处理」
//
// ## 落盘是硬要求
// 首启必须真正写出 `~/Library/Application Support/Residue/state.residue`——
// 否则 A-10 第 9 步（卸载 → 重装 → 判据为初始态）永远不可达（常在线在发布把关里点出过）。
// ============================================================

@MainActor
@Observable
final class AppModel {

    /// 当前页面模型（视图只读它）。
    var pageModel = PageModel()

    /// 是否正在扫描。
    var isScanning = false

    /// 最近一次扫描的中止原因（`nil` = 正常完成）。
    var lastAbort: String?

    /// 错误提示（`nil` = 无错误）。
    var errorMessage: String?

    /// 只读态（数据由更高版本创建）。
    var readOnly = false

    /// 登录项四态（ADR-02）。**非 enabled 时定时任务不执行**。
    var loginItemState: LoginItemState = .notRegistered

    /// 运行期偏好（`state/preferences.json`）：目前只有「是否曾启用过自动删除」。
    ///
    /// AC-10 需要它区分「从未启用」与「曾启用后关闭」——
    /// 前者四档显示「未采集」，后者显示「已停止」。
    private(set) var preferences = Preferences()
    private let preferencesStore: PreferencesStore

    /// 位置告警（Translocation / 不在「应用程序」）。
    var locationWarning: String?

    // ---- IO 组件 ----
    private let loginItem = LoginItemManager()
    private var scheduler: ScheduledRunner?
    /// 废纸篓执行器（AC-04 / AC-15 的执行机构）。
    private let executor = TrashExecutor()

    /// 上次扫描的模式（`T` 快照只能由 `full` 取，见 M3）。
    private(set) var lastScanMode: ScanEngine.Mode = .full

    /// 上次扫描的 L0 是否降级（无法枚举同 uid 进程）。
    private(set) var lastScanDegraded = false

    /// AC-15 的顺延条目数（本次因上限而未执行的条数）。
    private(set) var deferredCount: Int = 0
    /// 上次实际执行时刻（「首次 / 稳定后」的阶段分界依据之一）。
    private(set) var lastExecutionAt: Date?
    private let stateFile: StateFile
    private let writer: RecordWriter
    private let engine = ScanEngine()
    private let probe = UpstreamRunner()

    /// **测试 / 自检专用**：覆盖来源根（`nil` = 走真实定位）。
    ///
    /// 为什么需要：自检若扫真实 `~/.cache/uv`，耗时不稳且随机器变化，
    /// 「通过」与否取决于用户机器上有多少缓存——那不是自检，是碰运气。
    var sourceRootsOverride: [(String, String)]?

    // ---- 运行期数据 ----
    private var contents = StateFileContents()
    private var candidates: [ScanEngine.Candidate] = []
    private var executions: [ExecutionRecord] = []
    private(set) var lastScanDiagnostics = ScanLogRecord.Diagnostics()
    /// 本次扫描的上游命令调用记录（AC-19 的界面落点数据源）。
    private var lastUpstreamCommands: [UpstreamCommand] = []

    init(
        stateFile: StateFile = StateFile(),
        writer: RecordWriter = RecordWriter(),
        preferencesStore: PreferencesStore? = nil
    ) {
        self.stateFile = stateFile
        self.writer = writer
        self.preferencesStore = preferencesStore
            ?? PreferencesStore(directory: stateFile.directory)
        loadAndProject()

        // **首启必须落盘**：若载体还不存在，立刻写出初始态。
        // 否则「卸载 → 重装 → 判据为初始态」无法与「从来没有写过」区分
        // —— A-10 第 9 条的首演判据就永远不可达（常在线在发布把关里点出过）。
        if !FileManager.default.fileExists(atPath: stateFile.fileURL.path) {
            persist()
        }

        // 运行期偏好（丢了不影响正确性，所以 load 不抛错）
        preferences = self.preferencesStore.load()

        // 登录项四态**如实读**（不缓存、不推断）
        loginItemState = loginItem.currentState()
        // 位置校验（ADR-02 代价 ②）：从 .dmg 直接运行会让登录项指向失效路径
        locationWarning = LoginItemManager.locationWarning()

        startScheduler()
    }

    /// 启动定时任务。**登录项非 `.enabled` 直接不排**（ADR-02）。
    private func startScheduler() {
        if scheduler == nil {
            scheduler = ScheduledRunner { [weak self] mode in
                await self?.runScan(mode: mode)
            }
        }
        restartScheduler()
    }

    /// 按当前状态重排定时任务（登录项态或自动删除态变化后调用）。
    private func restartScheduler() {
        let allowsCollection = collectionAllowed
        scheduler?.start(
            loginItemAllows: loginItemState.allowsScheduling,
            allowsCollection: allowsCollection
        )
    }

    /// **采集是否被允许**（AC-10 的核心判定，**唯一实现处**）。
    ///
    /// | 状态 | 采集 | 为什么 |
    /// |---|---|---|
    /// | 从未启用过（观察期中） | **允许** | 否则永远攒不够样本、永远点不亮 → 产品锁死 |
    /// | 已启用 | 允许 | 正常 |
    /// | 曾启用、现已关闭 | **不允** | AC-10 的 Then：关闭后定时任务不跑采集 |
    var collectionAllowed: Bool {
        // **调用 Core 的唯一实现，本层不自己推**（同一判定两处实现必然分叉）
        CollectionPolicy.isCollectionAllowed(
            autoDeleteEnabled: contents.header.autoDeleteEnabled,
            everEnabledAutoDelete: preferences.everEnabledAutoDelete
        )
    }

    /// 重新读取登录项状态并据此启停排程（用户可能刚在系统设置里允许）。
    func refreshLoginItem() {
        loginItemState = loginItem.currentState()
        locationWarning = LoginItemManager.locationWarning()
        if scheduler == nil {
            scheduler = ScheduledRunner { [weak self] mode in
                await self?.runScan(mode: mode)
            }
        }
        restartScheduler()
        rebuild()
    }

    /// 注册登录项（用户首次启用自动删除时调用）。
    func registerLoginItem() {
        if case .failure(let e) = loginItem.register() {
            errorMessage = "登录项注册失败：\(e.localizedDescription)"
        }
        refreshLoginItem()
    }

    /// 打开系统设置让用户手动允许（只在 `.requiresApproval` 时该给这个动作）。
    func openLoginItemSettings() {
        loginItem.openSystemSettings()
    }

    // MARK: - 加载与投影

    /// 从载体加载 → 投影成页面模型。
    func loadAndProject() {
        let result = stateFile.load()
        readOnly = result.readOnly

        if let err = result.error {
            errorMessage = describe(err)
        } else {
            errorMessage = nil
        }

        if let c = result.contents {
            contents = c
        }
        rebuild()
    }

    private func rebuild() {
        let input = PageModelBuilder.Input(
            contents: contents,
            candidates: candidates,
            executions: executions,
            readOnly: readOnly,
            loading: isScanning,
            degraded: lastScanDiagnostics.degraded,
            coverage: L0Coverage(
                sameUIDTotal: lastScanDiagnostics.coverage.sameUIDTotal,
                sameUIDRead: lastScanDiagnostics.coverage.sameUIDRead,
                statOtherUID: lastScanDiagnostics.coverage.statOtherUID
            ),
            contentReads: lastScanDiagnostics.contentReads,
            loginItem: loginItemState,
            locationWarning: locationWarning,
            upstreamCommands: lastUpstreamCommands,
            autoDeleteEnabled: contents.header.autoDeleteEnabled,
            autoDeleteEverEnabled: preferences.everEnabledAutoDelete,
            deferredCount: deferredCount,
            executionMode: preferences.executionMode,
            capacityCapBytes: preferences.capacityCapBytes,
            itemCap: preferences.itemCap,
            whitelist: preferences.whitelist
        )
        pageModel = PageModelBuilder.build(input)
    }

    // MARK: - 扫描

    /// 执行一次扫描（`full` 才取快照）。
    ///
    /// 流程：定位来源根 → 逐来源扫描 → L0 探测 → 聚合诊断 → 落盘 → 投影。
    func runScan(mode: ScanEngine.Mode = .full) async {
        guard !readOnly else {
            errorMessage = UICopy.readOnlyNoSettlement
            return
        }
        isScanning = true
        rebuild()

        let started = Date()
        var allCandidates: [ScanEngine.Candidate] = []
        var filesScanned = 0
        var bytesScanned: Int64 = 0
        var unknownCount = 0
        var abortReason: String?
        var upstreamRecords: [UpstreamCommand] = []

        // ---- 来源根（用上游只读命令定位；失败回退标准路径） ----
        let roots = resolveSourceRoots(&upstreamRecords)

        // ---- 逐来源扫描 ----
        for (sourceName, root) in roots {
            guard FileManager.default.fileExists(atPath: root) else { continue }
            do {
                let result = try engine.scan(root: root, mode: mode, now: started)
                filesScanned += result.filesScanned
                bytesScanned += result.candidates.reduce(Int64(0)) { $0 + $1.bytes }
                unknownCount += result.unknownCount
                if let ab = result.aborted { abortReason = ab.rawValue }
                // 引擎按路径片段匹配来源；这里以「扫描根所属来源」为准做一次校正，
                // 避免路径里恰好含别的来源片段时被误判。
                for var c in result.candidates {
                    if c.source.isEmpty { c.source = sourceName }
                    allCandidates.append(c)
                }
            } catch {
                // 单个来源不可读不阻断整体（AC-14 第一类：来源不可读 → 降级只读该来源）
                errorMessage = "\(sourceName)：\(describeScanError(error))"
            }
        }
        candidates = allCandidates
        lastUpstreamCommands = upstreamRecords
        lastScanMode = mode

        // ---- L0 探测（排除自身，防自污染） ----
        let snapshot = L0Probe.snapshot(excludePIDs: [getpid()])
        lastScanDegraded = snapshot.degraded

        // **`pNowCount` 与 `b` 是两个不同的量，曾经被混成一个变量**
        //
        // - `pNowCount` = 当前**被持有**的候选数（观测面）
        // - `b` = 本轮 **L0 检查次数**（**门槛项**，AC-08 组 B 要求 `b ≥ 1`）
        //
        // 原实现写成 `let a = countHeld(...)` 然后 `pNowCount: a, b: a` ——
        // 于是 `b` 变成了「被持有数」。后果：
        //
        // **「缓存满满但没有任何进程在用」是最理想的可清理场景，
        // 而它恰好 `countHeld = 0` → `b = 0` → 门槛永远不满足 → 永远点不亮。**
        //
        // 正确口径（M5）：「计数对象 = 对某候选执行 L0 判定的一次」。
        // 每条候选都会被判一次，所以 `b` = 参与判定的候选数。
        let pNowCount = countHeld(in: snapshot)
        let checkedCount = countL0Checks()

        // ---- 更新诊断 ----
        lastScanDiagnostics = ScanLogRecord.Diagnostics(
            degraded: snapshot.degraded,
            coverage: .init(
                sameUIDTotal: snapshot.coverage.sameUIDTotal,
                sameUIDRead: snapshot.coverage.sameUIDRead,
                statOtherUID: snapshot.coverage.statOtherUID
            ),
            pNowCount: pNowCount,
            fSetBits: 0,
            doneCount: 0,
            // `a`（累计误判数）**本轮尚无判定结果**，如实取载体里的累计值。
            // 不写死 0：`a` 只增不减（CR-022 偏差 3），清采集物也不清它。
            a: accumulatedMisjudgment(for: nil),
            b: checkedCount,
            round: contents.header.round,
            countedDays: contents.header.countedDays,
            // **内容读取次数恒为 0**：扫描只读元数据、不读内容（AC-07 载体）
            contentReads: 0
        )

        // ---- 观测进度推进（成功扫描 +1 计数日） ----
        advanceCountedDayIfNeeded(now: started)

        // ---- 落盘（**必须真写**，否则 A-10 第 9 步不可达） ----
        persist()

        // ---- 扫描日志（AC-19 唯一可判载体） ----
        let record = ScanLogRecord(
            at: started,
            mode: mode.rawValue,
            sources: roots.map(\.0),
            filesScanned: filesScanned,
            bytesScanned: bytesScanned,
            durationMs: Int(Date().timeIntervalSince(started) * 1000),
            aborted: abortReason,
            breakpointSaved: false,
            unknownCount: unknownCount,
            upstreamCommands: upstreamRecords,
            diagnostics: lastScanDiagnostics
        )
        do {
            try writer.appendScan(record)
        } catch {
            // **未落盘即「无法证明」，验收按不通过**（§5.4）——
            // 所以这里把失败如实暴露给用户，不静默。
            errorMessage = "扫描日志写入失败：\(error.localizedDescription)"
        }

        lastAbort = abortReason
        isScanning = false
        rebuild()
    }

    // MARK: - 开关

    /// 点亮 / 关闭自动删除。
    ///
    /// **未达线不得点亮**（AC-08 组 B）——由 `GateEvaluator.isQualified` 决定，
    /// 界面只读 `pageModel.canLightUp`，此处再兜一次底。
    func setAutoDelete(_ on: Bool) {
        guard !readOnly else { return }
        if on && !pageModel.canLightUp {
            errorMessage = "未达达标条件，不能点亮自动删除"
            return
        }
        contents.header.autoDeleteEnabled = on
        if on && !preferences.everEnabledAutoDelete {
            // **第一次点亮** → 记下「曾启用过」。这一位只增不减：
            // 它记的是历史（用户曾经让产品动手过），不是当前意图。
            preferences.everEnabledAutoDelete = true
            preferencesStore.save(preferences)
        }
        persist()
        // 采集是否被停止（AC-10）：曾启用过 + 现在关着
        restartScheduler()
        rebuild()
    }

    // MARK: - 执行清理（AC-04 / AC-15）

    /// **单次执行的条目数上限**（每来源）。
    ///
    /// ## 这个数从哪来（V2 是「建议值 · 待确认」，没有定值）
    ///
    /// PRD 的 V2 明写「另设条目数上限（**数值待定**）」，且 AC-11 的判定
    /// 特意声明「该数值**不作为默认值唯一性的判定基准**」—— 也就是契约
    /// 有意没把它钉死，留给实现定。
    ///
    /// 取 **200**，依据是**一致性而非拍脑袋**：
    /// - ② 页候选清单的分页就是 200 行/页（ADR-01）
    /// - 于是「用户看到的一页」与「一次能删的上限」是同一个数
    ///   → 用户对「这次会删多少」有直观预期，不会出现「我只看了一页，
    ///   结果删了三千条」
    ///
    /// 已登记进 CR-025，若产品后续给出定值，改这一个常量即可。
    static let itemCapPerSource = 200

    /// 单次容量上限（首次）：`min(5 GB, 来源总量 × 10%)`（AC-15）。
    static let firstRunAbsoluteCapBytes: Int64 = 5_000_000_000

    /// **执行一次清理批次**（`AC-04` 的定时执行点，也是 ⑥ 页「立即执行」的实现）。
    ///
    /// ## 为什么这不是「手动删除入口」
    ///
    /// CR-023 已裁定：本产品**没有「用户手动删文件」这条路径**（AC-04 只写
    /// 「到达定时执行点」）。⑥ 页那个按钮做的是「**把本次定时批次提前执行**」，
    /// 因此它受 AC-04 全部门槛约束 —— 也就**不存在「手动清理绕过观察期」**。
    ///
    /// 所以这里第一件事就是检查 `canLightUp`：未达线时直接返回，不做任何事。
    func executeBatch() async {
        guard !readOnly else {
            errorMessage = UICopy.readOnlyNoSettlement
            return
        }
        // **同门槛**：未达线不得执行（AC-04 ③ 逐来源复核 + AC-08 组 B）
        guard pageModel.canLightUp else {
            errorMessage = "未达达标条件，本次不执行（逐来源复核未通过）"
            return
        }
        guard !isScanning else { return }

        let now = Date()
        // 「首次」= 本机**首次产生实际删除动作**（AC-15 的阶段分界）
        let isFirstRun = executions.isEmpty
        var newRecords: [ExecutionRecord] = []
        var totalSkipped = 0

        for source in Source.allCases {
            // **pipx 恒为仅报告**：不在判定域 → 永不参与自动删除（AC-04 ②）
            guard source.isInDecisionDomain else { continue }

            let ids: [CandidateID] = candidates
                .filter { $0.source == source.rawValue }
                .map { CandidateID(path: $0.path, birthtime: $0.birthtime) }
            guard !ids.isEmpty else { continue }

            // 容量上限：首次取 min(5 GB, T×10%)；稳定后取 T×20%（AC-15）
            let total = sourceTotalBytes(for: source)
            let cap: Int64
            if isFirstRun {
                // 取「用户配置的上限」与「AC-15 的 10% 档」中更小者
                cap = Swift.min(
                    preferences.capacityCapBytes,
                    Int64(Double(total) * 0.10)
                )
            } else {
                cap = Int64(Double(total) * 0.20)
            }

            let outcome = executor.execute(
                candidates: ids,
                source: source,
                capacityCap: cap,
                countCap: preferences.itemCap,
                now: now
            )
            newRecords.append(contentsOf: outcome.records)
            totalSkipped += outcome.skippedByCap
        }

        // 写 `execution.jsonl`（AC-18 举证链的数据源）
        for rec in newRecords {
            try? writer.append(rec, kind: .execution, now: now)
        }
        executions.append(contentsOf: newRecords)

        // AC-15：顺延条目数 = 候选总数 − 实际删除条目数
        let deleted = newRecords.filter { $0.action == .renameToTrash }.count
        deferredCount = Swift.max(0, totalSkipped)
        _ = deleted

        lastExecutionAt = now
        persist()
        rebuild()
    }

    /// 从废纸篓恢复一条记录（AC-13 / U2）。
    ///
    /// 三条失败路径都挂真实码（`RestoreError.diagnostic`）：
    /// - 记录无恢复位置 → `E-201`
    /// - 废纸篓里已不存在 → `E-201`（用户在 Finder 里清空了）
    /// - **原路径已被占用 → `E-205`，且不覆盖**
    ///   （覆盖等于用旧文件打掉用户新装的东西，属不可逆数据损坏）
    func restore(_ record: ExecutionRecord) {
        guard !readOnly else {
            errorMessage = UICopy.readOnlyNoSettlement
            return
        }
        do {
            let restored = try executor.restore(record)
            // **回写 `restored_by_user`**（K2 建议 S1）：不回写则「恢复过几次」
            // 不可追，也就无法判断「同一误删反复恢复」。
            try? writer.append(restored, kind: .execution, now: Date())
            if let idx = executions.firstIndex(where: { $0.id == record.id }) {
                executions[idx] = restored
            } else {
                executions.append(restored)
            }
            rebuild()
        } catch let e as TrashExecutor.RestoreError {
            errorMessage = describe(e.diagnostic)
        } catch {
            errorMessage = describe(.e201, detail: error.localizedDescription)
        }
    }

    /// 某来源的**总量**（`T`；未取快照时退回候选合计）。
    private func sourceTotalBytes(for source: Source) -> Int64 {
        if let entry = contents.header.sources.first(where: { $0.source == source }),
           let t = entry.T, t > 0 {
            return Int64(t)
        }
        return candidates
            .filter { $0.source == source.rawValue }
            .reduce(Int64(0)) { $0 + $1.bytes }
    }

    // MARK: - 清理策略配置（AC-03 四项 + 白名单）

    /// 改执行方式（AC-03）。**默认「仅报告」**。
    func setExecutionMode(_ mode: ExecutionMode) {
        guard !readOnly else { return }
        preferences.executionMode = mode
        preferencesStore.save(preferences)
        rebuild()
    }

    /// 改单次容量上限（AC-03：可见可编辑）。单位字节。
    func setCapacityCap(bytes: Int64) {
        guard !readOnly, bytes > 0 else { return }
        preferences.capacityCapBytes = bytes
        preferencesStore.save(preferences)
        rebuild()
    }

    /// 改条目数上限（AC-03：可见可编辑）。
    func setItemCap(_ n: Int) {
        guard !readOnly, n > 0 else { return }
        preferences.itemCap = n
        preferencesStore.save(preferences)
        rebuild()
    }

    /// 加入白名单（AC-03：**用户唯一的主动保护动作**）。
    ///
    /// 加入后该路径（及其子路径）**不再出现在新候选清单中** ——
    /// 过滤在 `PageModelBuilder` 里做，不在渲染层隐藏。
    func addToWhitelist(_ path: String) {
        guard !readOnly, !path.isEmpty else { return }
        guard !preferences.whitelist.contains(path) else { return }
        preferences.whitelist.append(path)
        preferencesStore.save(preferences)
        rebuild()
    }

    /// 移出白名单（用户改主意时要能撤回——只增不减的白名单会变成新的陷阱）。
    func removeFromWhitelist(_ path: String) {
        guard !readOnly else { return }
        preferences.whitelist.removeAll { $0 == path }
        preferencesStore.save(preferences)
        rebuild()
    }

    /// 一键清除采集物与日志。
    ///
    /// **不含 `a` 的载体**（`state.residue`）——CR-022 偏差 3。
    /// 所以这里只删 `records/` 与 `state/` 下的运行期态，**不碰 state.residue**。
    func clearLogs() {
        guard !readOnly else { return }
        let fm = FileManager.default
        let recordsDir = writer.directory
        if fm.fileExists(atPath: recordsDir.path) {
            try? fm.removeItem(at: recordsDir)
        }
        // **不删 state.residue**：清了就等于「一键洗掉 L0 误判记录」（S2 可被绕过）
        executions = []
        rebuild()
    }

    // MARK: - 私有

    /// 定位各来源根。优先用上游只读命令（AC-19 白名单内），失败回退标准路径。
    private func resolveSourceRoots(_ upstream: inout [UpstreamCommand]) -> [(String, String)] {
        // 自检注入优先（不产生 upstreamCommands —— 因为压根没调上游命令）
        if let override = sourceRootsOverride { return override }

        let home = NSHomeDirectory()
        var out: [(String, String)] = []

        // uv：`uv cache dir`（白名单内，纯本地）
        let uv = probe.run(executable: "uv", args: ["cache", "dir"])
        upstream.append(uv.record)
        let uvRoot = (uv.stdout?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? home + "/.cache/uv"
        out.append((Source.uvCache.rawValue, uvRoot))

        // npm：`npm config get cache`（白名单内）
        let npm = probe.run(executable: "npm", args: ["config", "get", "cache"])
        upstream.append(npm.record)
        let npmBase = (npm.stdout?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? home + "/.npm"
        out.append((Source.npmNpx.rawValue, npmBase + "/_npx"))

        // pipx：规则目录固定（`.local/pipx/venv`，与 SourceRule 一致）
        out.append((Source.pipxRun.rawValue, home + "/.local/pipx/venv"))

        return out
    }

    /// 本轮 **L0 检查次数** `b`（M5：门槛项）。
    ///
    /// 计数对象 = 「对某候选执行 L0 判定的一次」。本实现对**每条候选都判一次**
    /// （`countHeld` 会遍历全部），所以 `b` = 参与判定的候选数。
    ///
    /// **不由 `countHeld` 的结果充当** —— 那是「被判为被持有的条数」，
    /// 是 `pNowCount` 的定义。两者混用会让「缓存满满但无人使用」
    /// 这个最理想的可清理场景永远点不亮（`b` 会是 0）。
    private func countL0Checks() -> Int {
        // 若 L0 降级（无法枚举），本轮**没有真正执行检查** → 如实记 0，
        // 让门槛自然不满足（不假装检查过）
        guard !lastScanDegraded else { return 0 }
        return candidates.count
    }

    /// 累计误判数 `a`（M4：**只增不减**，清采集物也不清它）。
    ///
    /// 从载体读；`source` 为 `nil` 时返回全部来源之和（⑤ 页的矩阵行会各自取）。
    private func accumulatedMisjudgment(for source: Source?) -> Int {
        if let source {
            return contents.header.sources
                .first(where: { $0.source == source })?.a ?? 0
        }
        return contents.header.sources.reduce(0) { $0 + $1.a }
    }

    /// 数「被持有」的候选数（`P_now` 规模，仅用于诊断）。
    private func countHeld(in snapshot: L0Snapshot) -> Int {
        var n = 0
        for c in candidates {
            var st = stat()
            guard stat(c.path, &st) == 0 else { continue }
            let id = FileIdentity(dev: UInt32(truncatingIfNeeded: st.st_dev), ino: UInt64(st.st_ino))
            if L0Probe.isHeld(identity: id, isDirectory: c.isDirectory, path: c.path, by: snapshot) {
                n += 1
            }
        }
        return n
    }

    /// 计数日推进 —— **调 Core 的 M1 唯一实现，本层不自行加一**。
    ///
    /// 原先这里写了 `countedDays + 1`，那是把 M1 的判定口径复制到编排层，
    /// 正是「同一判定两处实现必然分叉」的起点（`verify_a9` 的域内算术检查抓到的）。
    private func advanceCountedDayIfNeeded(now: Date) {
        var progress = ObservationProgress(
            round: contents.header.round,
            countedDays: contents.header.countedDays
        )
        progress.startAnchor = contents.header.roundStartAnchor
        progress.advanceCountedDay(on: now)
        contents.header.countedDays = progress.countedDays
        contents.header.roundStartAnchor = progress.startAnchor
        contents.header.lastScanAt = now
    }

    private func persist() {
        // ---- 保证每个来源都有一行（**字段值必须真实，不能留 nil 冒充「还没算」**）----
        //
        // ## 这里曾经有个会锁死产品的缺口
        //
        // 原实现给每个来源写 `T: nil, K: nil, J: nil, H: nil` 且 `slotCount: 0`，
        // 然后**再也不更新**（`if idx < count { continue }`）。
        //
        // 后果是整条门槛链断在起点：
        // - `T` 恒 null → `H = min(30, T)` 永远取不到值
        // - 门槛永远不满足 → **自动删除永远点不亮**
        // - 产品退化成一个只读扫描器
        //
        // 这正是复必现 M-02 怀疑的形态（他当时只从两页矛盾推断，
        // 没有看到代码；现在确认它在实现层是**结构性**的）。
        //
        // 修法：按 M3 的规则真取快照 ——
        // **`T` 的唯一来源 = 本轮首次成功 `full` 扫描**，取到后**冻结不再覆盖**。
        let now = Date()
        for source in Source.allCases {
            // 该来源本轮扫描到的候选数（`slotCount` 的载体）
            let slotCount = candidates.filter { $0.source == source.rawValue }.count
            // 该来源本轮参与 L0 判定的次数（`b` 是门槛项）
            let bCount = lastScanDegraded ? 0 : slotCount

            if let idx = contents.header.sources.firstIndex(where: { $0.source == source }) {
                var entry = contents.header.sources[idx]
                // **只增不减、只冻结不覆盖**：
                // 已取过快照的来源，`T` / `H` 一律不动（M3：冻结时刻唯一）
                if !entry.snapshotTaken, lastScanMode == .full, slotCount > 0 {
                    entry.snapshotTaken = true
                    entry.T = slotCount
                    // `H = min(30, T)`（AC-08 组 A 的门槛式）
                    entry.H = Swift.min(30, slotCount)
                }
                // 每次成功扫描都更新观测面（`b` / `slotCount` / 判定时刻）
                entry.b = bCount
                entry.slotCount = slotCount
                entry.lastJudgmentAt = now
                // `a` 不动：只增不减，且只在真实判定出错时由 GateEvaluator 写
                contents.header.sources[idx] = entry
            } else {
                contents.header.sources.append(
                    SourceHeaderEntry(
                        source: source,
                        // **快照只在 full 扫描且有候选时取**（M3）
                        snapshotTaken: (lastScanMode == .full && slotCount > 0),
                        T: (lastScanMode == .full && slotCount > 0) ? slotCount : nil,
                        K: nil, J: nil,
                        H: (lastScanMode == .full && slotCount > 0)
                            ? Swift.min(30, slotCount) : nil,
                        a: 0,
                        b: bCount,
                        slotCount: slotCount,
                        doneCount: 0,
                        lastJudgmentAt: now
                    )
                )
            }
        }
        do {
            _ = try stateFile.save(header: contents.header, payloads: contents.payloads)
        } catch {
            errorMessage = describeWriteError(error)
        }
    }

    // MARK: - 导出脱敏报告（AC-13 G-5）

    /// 导出脱敏报告到指定路径（**纯函数式，无 UI 依赖**）。
    ///
    /// 为什么拆出这一层：交互层要弹 `NSSavePanel`，那是 GUI 才能做的事；
    /// 而「导出内容对不对」必须能在自检里验证。**两者分开，自检才能跑**。
    ///
    /// - Returns: 实际写入的 URL。
    /// - Throws: `Redactor.RedactionError`（脱敏自检失败或报告缺段 → `E-401`）。
    @discardableResult
    func exportReport(to destination: URL) throws -> URL {
        let report = try buildReport()
        return try Redactor.export(
            report,
            context: Redactor.Context.current(),
            to: destination
        )
    }

    /// 交互式导出（弹保存面板）。
    func exportReportInteractive() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Residue-报告-\(Self.timestampForFileName()).md"
        panel.canCreateDirectories = true
        panel.title = "导出脱敏报告"
        panel.message = "报告已脱敏：用户名、主目录、主机名替换为占位符；不包含文件内容。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exportReport(to: url)
        } catch {
            // **`E-401`：导出失败**（不产出文件）
            if let re = error as? Redactor.RedactionError {
                errorMessage = describe(.e401, detail: re.description)
            } else {
                errorMessage = describe(.e401, detail: error.localizedDescription)
            }
        }
    }

    /// 组装五段报告（IF-12）。
    ///
    /// **五段缺任一段即视为报告不可用** —— 由 `Redactor.render` 自检，
    /// 这里只负责把数据凑齐。
    /// **供自检使用**：组装报告但不写文件（证伪通道需要单独渲染）。
    func buildReportForExport() throws -> Redactor.Report { try buildReport() }

    private func buildReport() throws -> Redactor.Report {
        // ---- 每来源指标（量段）----
        let sources = contents.header.sources.map { entry in
            Redactor.SourceMetrics(
                source: entry.source.rawValue,
                state: entry.snapshotTaken ? "在域" : "仅报告",
                // **`nil` 必须原样保留为 `nil`，不得写成 0**
                // （0 会被读成「本轮样本量为零」，而事实是「本轮还没结算」）
                t: entry.T,
                k: entry.K,
                j: entry.J,
                h: entry.H,
                a: entry.a,
                b: entry.b
            )
        }

        // ---- 取证段（来自 scan.jsonl.diagnostics）----
        let d = lastScanDiagnostics
        let diagnostics = Redactor.Diagnostics(
            degraded: d.degraded,
            sameUIDTotal: d.coverage.sameUIDTotal,
            sameUIDRead: d.coverage.sameUIDRead,
            statOtherUID: d.coverage.statOtherUID,
            pNowCount: d.pNowCount,
            fSetBits: d.fSetBits,
            doneCount: d.doneCount,
            contentReads: d.contentReads,
            round: d.round,
            countedDays: d.countedDays,
            a: d.a,
            b: d.b
        )

        // ---- 证据段 / 上游段 ----
        let evidenceLines = try jsonLines(kind: .evidence)
        let executionLines = try jsonLines(kind: .execution)
        let ctx = Redactor.Context.current()
        let upstream = lastUpstreamCommands.map { rec in
            Redactor.UpstreamCommand(
                cmd: rec.cmd,
                // **参数按 `<project>` 脱敏**（P5：路径里含项目名/用户名）
                args: Redactor.redactArguments(rec.args, context: ctx),
                exitCode: rec.exitCode ?? -1,
                durationMs: rec.durationMs,
                invokedAt: rec.invokedAt
            )
        }

        return Redactor.Report(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
            schemaVersion: contents.header.schemaVersion,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            arch: Self.archName(),
            sources: sources,
            diagnostics: diagnostics,
            evidenceLines: evidenceLines,
            executionLines: executionLines,
            upstreamCommands: upstream
        )
    }

    /// 把某类 JSONL 读成「一行一条 JSON 字符串」。
    ///
    /// `RecordWriter.readLines` 返回的是解析后的字典（丢了原始行文本），
    /// 而报告要求保留原始行（逐行脱敏），所以这里重新序列化回去。
    private func jsonLines(kind: RecordWriter.Kind) throws -> [String] {
        let dicts = try writer.readLines(kind: kind)
        return dicts.compactMap { dict -> String? in
            guard let data = try? JSONSerialization.data(
                withJSONObject: dict,
                options: [.sortedKeys]
            ) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    /// 当前 CPU 架构名（环境段要求，**不含主机名**）。
    private static func archName() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func timestampForFileName(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: now)
    }

    // MARK: - 错误文案（**必须给可执行动作**，视觉基线 §三）

    /// 统一格式：`E-xxx · 一句话结果` + 可选细节 + 可选动作。
    ///
    /// **码、一句话结果、建议动作三者全部来自 `DiagnosticCode`**，
    /// 界面层只补「本上下文独有的细节」（如具体磁盘 MB 数、错误的技术细节）。
    ///
    /// 为什么必须这样：原先 `AppModel` 自己拼了 `"来源目录不可读（E-101）"`
    /// 这类字符串，等于把 §6 的码表复制了一份到界面层——**同一事实两处写，
    /// 必然分叉**（契约评审在 R3 契约维度指出过这个问题）。
    private func describe(
        _ code: DiagnosticCode,
        detail: String? = nil,
        action: String? = nil
    ) -> String {
        var parts = ["\(code.rawValue) · \(code.summary)"]
        if let detail, !detail.isEmpty { parts.append(detail) }
        if let action, !action.isEmpty { parts.append(action) }
        return parts.joined(separator: "。")
    }

    private func describe(_ e: StateFileError) -> String {
        let code = e.diagnostic
        switch e {
        case .schemaTooNew:
            // 现有数据由更高版本写入 —— 这条必须说清「装回更高版本」
            return describe(code)
        case .corruptNoBackup(let d):
            return describe(code, detail: d)
        case .segmentValidationFailed(let d):
            return describe(code, detail: d)
        case .writeFailed(let d):
            return describe(code, detail: d)
        case .migrationSpaceInsufficient(let need, let avail):
            // **不给数字的提示等于没有提示**（§6 原话）
            return describe(
                code,
                detail: "需要 \(need / 1_000_000) MB，当前可用 \(avail / 1_000_000) MB"
            )
        case .migrationRestoreFailed:
            return describe(code)
        case .restoredFromBackup:
            return describe(code)
        }
    }

    private func describeWriteError(_ e: Error) -> String {
        if let se = e as? StateFileError { return describe(se) }
        return describe(.e303, detail: e.localizedDescription)
    }

    private func describeScanError(_ e: Error) -> String {
        guard let se = e as? ScanEngine.ScanError else {
            return e.localizedDescription
        }
        let code = se.diagnostic
        switch se {
        case .pathNotFound(let p):
            return describe(code, detail: p)
        case .pathDenied(let p):
            // **AC-14 第一类**：来源不可读 → 必须给授权指引
            return describe(code, detail: p)
        case .lowBattery, .userCancelled, .timeout:
            return describe(code)
        case .checkpointInconsistent(let d):
            return describe(code, detail: d)
        }
    }
}
