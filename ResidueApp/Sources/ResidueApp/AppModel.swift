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

    // MARK: - 扫描作业（**必须离开主 actor**，否则界面冻结）

    /// 一次扫描的**可搬运单元**（`Sendable`）。
    ///
    /// ## 为什么需要它
    ///
    /// `AppModel` 是 `@MainActor` 隔离的。而 **`@MainActor` 类上的 `async` 函数
    /// 并不会自动离开主线程** —— `async` 只是让函数「可以被挂起」，
    /// 函数体里的**同步代码仍然在主 actor 上执行**。
    ///
    /// 实测（本机 · 2026-11-09）：
    /// | 来源 | 项数 | 耗时 |
    /// |---|---|---|
    /// | `~/.cache/uv` | 115,875 | **6.44 s** |
    /// | `~/.npm/_npx` | 106,983 | **6.79 s** |
    ///
    /// 合计约 **13 秒**的全同步阻塞跑在主线程上 → 界面**彻底冻结**
    /// （不能拖动、不能滚动、点按钮无反应）。
    ///
    /// 所以扫描必须整体搬到主 actor 之外。本类型承载那部分工作，
    /// 它只含 `Sendable` 数据，可以安全地跨 actor 边界传递。
    struct ScanJob: Sendable {
        /// 已扫描的来源与结果（`source` → 该来源的扫描结果）。
        var results: [(source: String, result: ScanEngine.ScanResult)] = []
        /// 各来源的错误（**单个来源失败不阻断整体**）。
        var failures: [(source: String, message: String)] = []
        /// 上游命令记录（定位来源根用的只读命令）。
        var upstream: [UpstreamCommand] = []
        /// L0 快照。
        var snapshot: L0Snapshot?
        /// 本轮各来源的候选（键 = `source.rawValue`）。
        var candidatesBySource: [String: [ScanEngine.Candidate]] = [:]
        /// 本轮各来源的 L0 判定结果（键 = `source.rawValue`）。
        ///
        /// **判定在主 actor 之外做完**（每条候选一次 `lstat`，是重 I/O），
        /// 这里只把**结果**带回来 —— 写回层只吃结果、不做探测。
        var judgmentsBySource: [String: [CandidateID: L0Verdict]] = [:]
        /// 本轮实际扫描的模式。
        var mode: ScanEngine.Mode = .full
        /// 累计扫描条目数。
        var filesScanned: Int = 0
        /// 累计候选数。
        var candidatesFound: Int = 0
        /// 首个中止原因。
        var abortReason: String?
        /// 本轮使用的来源根（`source.rawValue` → 根路径）。
        /// 执行期越界判定（AC-19）必须用**扫描时这一份**。
        var roots: [String: String] = [:]
        /// **被中断来源的断点**（`source.rawValue` → 断点）。
        ///
        /// 只有**中断**的来源才有断点 —— 正常扫完的来源引擎返回 `nil`
        /// （没有「未扫完的部分」，续扫无从谈起，也不该续）。
        /// 收尾时整份落 `state/checkpoints.json`，供下次启动续扫。
        var abortedCheckpoints: [String: ScanEngine.Checkpoint] = [:]
    }

    /// **当前扫描的进度**（供界面显示「在动」）。
    ///
    /// ## 为什么必须有它
    ///
    /// 只把扫描搬到后台线程而**不汇报进度**，用户看到的是「按了没反应」——
    /// **那和卡死没有区别**，甚至更糟（用户会去重复点击）。
    var scanProgress = ScanProgress()

    /// **当前扫描的取消令牌**（主 actor 写、后台任务读）。
    private var scanCancelBox: CancelBox?

    /// AC-15 的顺延条目数（本次因上限而未执行的条数）。
    private(set) var deferredCount: Int = 0
    /// 上次实际执行时刻（「首次 / 稳定后」的阶段分界依据之一）。
    private(set) var lastExecutionAt: Date?
    /// 最近一次清理的结果摘要（供首屏显示「删了什么」）。
    private var lastExecutionNotice: PageModel.ExecutionNotice?
    private let stateFile: StateFile
    private let writer: RecordWriter
    /// 扫描断点（`state/checkpoints.json` · AC-20 断点续扫）。
    private let checkpoints: CheckpointStore
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

    /// **本轮扫描用的来源根**（`source.rawValue` → 根路径）。
    ///
    /// AC-19 / R2:218 的执行期「真实路径在该来源允许根内」判定需要它。
    /// 不许在执行时重新 `resolveSourceRoots` —— 那要跑上游命令（`uv cache dir`），
    /// 而且可能返回与扫描时不同的根（用户改了配置）→ 判定用的根与实际扫描的根不一致。
    /// **判依据必须与扫描时同一份**（同一判定只有一个来源）。
    private var lastSourceRoots: [String: String] = [:]

    init(
        stateFile: StateFile = StateFile(),
        writer: RecordWriter = RecordWriter(),
        preferencesStore: PreferencesStore? = nil,
        checkpoints: CheckpointStore? = nil
    ) {
        self.stateFile = stateFile
        self.writer = writer
        // 断点落 `state/` 子目录（**不计入 N7 计量**，但计入 N7 清除范围），
        // 与 `state/schedule.json` 同级 —— 见 R2 §5.5 / §10.3。
        self.checkpoints = checkpoints ?? CheckpointStore(
            directory: stateFile.directory.appendingPathComponent("state", isDirectory: true)
        )
        self.preferencesStore = preferencesStore
            ?? PreferencesStore(directory: stateFile.directory)
        loadAndProject()

        // **首启必须落盘**：若载体还不存在，立刻写出初始态。
        // 否则「卸载 → 重装 → 判据为初始态」无法与「从来没有写过」区分
        // —— A-10 第 9 条的首演判据就永远不可达（常在线在发布把关里点出过）。
        //
        // ⚠️ **只读态例外**：载体损坏时 `load()` 已把主文件移成 `.corrupt`，
        // 此时「主文件不存在」≠「首启」。若照样写默认载体，就是**静默重建**：
        // 现场被一个空文件覆盖，`a` 被清零，`.corrupt` 之外再无痕迹。
        // 只读态的恢复出口是用户显式动作，不是自动重置（不变量④）。
        if !readOnly, !FileManager.default.fileExists(atPath: stateFile.fileURL.path) {
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
                await self?.scheduledWork(mode: mode)
            }
        }
        restartScheduler()
    }

    /// **定时执行点**（AC-04）：扫描 → 若已点亮自动删除，则执行清理批次。
    ///
    /// ## 为什么这是「到达定时执行点」的唯一落点
    ///
    /// 原先 `work` 闭包只调 `runScan` —— 定时任务**扫完就停**，
    /// 从不执行删除。AC-04 写的是「到达定时执行点执行删除」，于是这条
    /// AC 在代码里没有任何落点：排程在跑、扫描在跑，但**删除永远不会被触发**。
    ///
    /// ## 三道闸（与手动「立即执行」同源，不另立第二套）
    ///
    /// 1. **`autoDeleteEnabled`** —— 用户没点亮自动删除，定时点就**只扫描不删**
    ///    （这是「观察期」的意义：影子期内只观测，绝不动手）
    /// 2. **`executeBatch` 内部兜底 `canLightUp`** —— 即使开关开着，未达线也不执行
    /// 3. **`executeBatch` 内部兜底 `isScanning`** —— 防重复
    ///
    /// 闸 2/3 在 `executeBatch` 里，此处只加闸 1，避免定时点绕过「用户主动点亮」。
    private func scheduledWork(mode: ScanEngine.Mode) async {
        await runScan(mode: mode)
        guard contents.header.autoDeleteEnabled else { return }
        await executeBatch()
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
                await self?.scheduledWork(mode: mode)
            }
        }
        restartScheduler()
        rebuild()
    }

    /// 注册登录项（用户首次启用自动删除时调用）。
    func registerLoginItem() {
        if case .failure(let e) = loginItem.register() {
            errorMessage = L.pick("登录项注册失败：\(e.localizedDescription)", "Failed to register login item: \(e.localizedDescription)")
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
        applyObservationResetIfNeeded()
        loadExecutions()
        rebuild()
    }

    /// 当前应用版本（`CFBundleShortVersionString`）。
    private static var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// **应用版本变更 → 载体清零**（M4「重置边界」）。
    ///
    /// ## 为什么这必须在每次启动时判（原先这段是死代码）
    ///
    /// `a`（L0 误判累计）是「本应用版本内判错过几次」。**跨版本没有可比性**：
    /// 新版本改了判定规则，旧版本的「零误判」证明不了新版本判得准。
    ///
    /// 不重置 = **旧版本攒下的安全凭证被新版本继承** → 用户升级完立刻就能点亮
    /// 自动删除，而新规则一次都没被观察过。这是不变量④（删之前先证明判得准）
    /// 在版本边界上的失效。
    ///
    /// ## 四条边界（与 `VersionResetTests` / `ObservationSignatureTests` 一一对应）
    ///
    /// | 情形 | 行为 |
    /// |---|---|
    /// | `appVersion` 为空（首启） | 只记下版本与指纹，**不清零** |
    /// | 版本与指纹都没变 | 不动（否则每次启动重置 → 永远点不亮） |
    /// | 版本变了 | 清零凭证（`a` 一并清零），**保留轮次** |
    /// | 版本没变但判定域指纹变了 | 清零凭证，**保留 `a`**（M4） |
    ///
    /// ## 为什么判定住在 Core
    ///
    /// 「要不要重置」是**判定**，不变量②要求它只有一个实现处。
    /// `AppModel` 在 App 层 ⇒ **不可单测**（本仓库只有一个 test target，
    /// 只依赖 `ResidueCore`）⇒ 判定必须下沉到 Core 的
    /// `ObservationResetPolicy.reason`，这里只做分派。
    private func applyObservationResetIfNeeded() {
        // ⚠️ **只读 / 损坏态绝不写盘**。
        //
        // 载体损坏时 `load()` 把主文件移成 `.corrupt` 并返回只读。
        // 若此时继续走「首启 → 写默认 header」这条路：
        //   · 磁盘上立刻出现一个**空的 state.residue**（现场被覆盖）
        //   · `a` 被静默清零 → 旧版本攒的误判证据消失
        //   · 下一次启动已经看不到 `.corrupt` 之外的任何痕迹
        //
        // 那是「静默重建」，直接违反不变量④：**不知道就不能当成知道**。
        // 只读态的恢复出口是用户显式动作（重装 / 修载体），不是自动重置。
        guard !readOnly else { return }

        let current = Self.currentAppVersion
        let reason = ObservationResetPolicy.reason(
            storedAppVersion: contents.header.appVersion,
            currentAppVersion: current,
            storedDecisionDomainSignature: contents.header.decisionDomainSignature,
            currentDecisionDomainSignature: Source.decisionDomainSignature
        )

        switch reason {
        case .none:
            // 首启：载体里没有版本 → 只记下版本与指纹，不清零（没有旧凭证可清）。
            //
            // ⚠️ 指纹**必须在这里写下** —— 否则每次启动都会判成
            // 「判定域指纹缺失 ⇒ 变更」⇒ 反复重置 ⇒ 产品永远点不亮。
            guard contents.header.appVersion.isEmpty else { return }
            contents.header.appVersion = current
            contents.header.decisionDomainSignature = Source.decisionDomainSignature
            persist()
        case .appVersionChanged:
            performObservationReset(preservingMissCount: false)
        case .decisionDomainChanged:
            performObservationReset(preservingMissCount: true)
        }
    }

    /// 执行一次观察期重置（**版本变更清 `a` / 判定域变更保留 `a`**）。
    private func performObservationReset(preservingMissCount: Bool) {
        do {
            try stateFile.clearCarrierForObservationReset(
                newAppVersion: Self.currentAppVersion,
                newDecisionDomainSignature: Source.decisionDomainSignature,
                preservingMissCount: preservingMissCount,
                preservedRound: contents.header.round
            )
            // 内存态同步成重置后的载体，避免界面继续显示旧凭证。
            //
            // ⚠️ 回读失败时**不覆盖内存态** —— 覆盖等于「清空成什么都没有」，
            // 那会把 `a` 在界面上显示成 0（= 放行），违反不变量④。
            let reloaded = stateFile.load()
            if let error = reloaded.error {
                errorMessage = describeWriteError(error)
                return
            }
            contents = reloaded.contents ?? StateFileContents()
            if contents.header.appVersion.isEmpty {
                contents.header.appVersion = Self.currentAppVersion
            }
        } catch {
            errorMessage = describeWriteError(error)
        }
    }

    /// **回读 `execution.jsonl`**（AC-18 / AC-13）。
    ///
    /// ## 为什么必须回读（原先只写不读）
    ///
    /// `execution.jsonl` 是执行记录的**唯一持久载体**。原实现只 append、从不读 → 后果：
    ///
    /// | 症状 | 根因 |
    /// |---|---|
    /// | 重启后 ⑦ 页「举证链与日志」清空 | `executions` 每次启动都是 `[]` |
    /// | 所有「可恢复」按钮消失（恢复无从发起） | 同上 —— 内存里没有记录 |
    /// | `isFirstRun` 永远为真 | 它判 `executions.isEmpty` |
    ///
    /// 第三条最阴：AC-15 的「首次档」与「稳定后档」因此**永远停在首次档**，
    /// 容量上限（5 GB / 10%）用了一次又一次，从不进入稳定档（20%）。
    ///
    /// ## 解码方式
    ///
    /// `readLines` 返回 `[String: Any]`（已解析的字典，丢了原始行文本）。
    /// 这里重新序列化成 JSON 再交给 `iso8601` 解码器 —— 与 `RecordWriter.append`
    /// 的编码策略必须**成对**（`dateEncodingStrategy = .iso8601`），
    /// 否则解码静默失败、记录全丢（本仓库 Preferences 踩过同一个坑）。
    private func loadExecutions() {
        guard let dicts = try? writer.readLines(kind: .execution), !dicts.isEmpty else {
            executions = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: [ExecutionRecord] = []
        loaded.reserveCapacity(dicts.count)
        for dict in dicts {
            guard let data = try? JSONSerialization.data(withJSONObject: dict),
                  let rec = try? decoder.decode(ExecutionRecord.self, from: data)
            else { continue }
            loaded.append(rec)
        }
        // **按执行时刻排序**：文件顺序是 append 顺序，但恢复动作会再追加一条
        // 同一 candidate 的 `restored_by_user`。排序后界面按时间线读才对。
        executions = loaded.sorted { $0.executedAt < $1.executedAt }
    }

    private func rebuild() {
        let input = PageModelBuilder.Input(
            contents: contents,
            candidates: candidates,
            executions: executions,
            readOnly: readOnly,
            // ★ 加载态只有一个事实源：`scanProgress`（§3.4/§3.9）。
            //   `nil` = 不在扫描 ⇒ 界面不画进度横条。
            scanProgress: isScanning ? scanProgress : nil,
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
        // **运行期反馈必须跨 rebuild 存活**（它不是载体投影，但用户在等这个答复）
        pageModel.lastExecutionNotice = lastExecutionNotice
    }

    // MARK: - 扫描

    /// 执行一次扫描（`full` 才取快照）。
    ///
    /// 流程：定位来源根 → 逐来源扫描 → L0 探测 → 聚合诊断 → 落盘 → 投影。
    /// 执行一次扫描。
    ///
    /// ## ⚠️ 为什么这段要分成「主 actor 内外两段」
    ///
    /// `AppModel` 是 `@MainActor` 隔离的。**`@MainActor` 类上的 `async` 函数
    /// 并不会自动离开主线程** —— `async` 只让函数「可以被挂起」，
    /// 而函数体里的**同步代码仍然在主 actor 上执行**。
    ///
    /// 于是原先整个扫描（13 秒的全同步 `stat`）都跑在主线程上，
    /// 界面**彻底冻结**：不能拖动、不能滚动、点按钮无反应。
    ///
    /// 实测（本机 · 2026-11-09）：
    /// | 来源 | 项数 | 耗时 |
    /// |---|---|---|
    /// | `~/.cache/uv` | 115,875 | **6.44 s** |
    /// | `~/.npm/_npx` | 106,983 | **6.79 s** |
    ///
    /// ## 三件事，缺一件都还会「像卡住」
    ///
    /// 1. **搬走**：重活进 `Task.detached`（`ScanJob` 全 `Sendable`）
    /// 2. **汇报**：进度持续回流到界面 → 用户看到它在动
    /// 3. **可取消**：13 秒不能反悔
    ///
    /// ## 为什么**不是**多线程
    ///
    /// 扫描是 11 万次 `stat` —— **元数据查询**，在内核态串行完成，
    /// 并行化**不缩短总时长**，只会加剧磁盘竞争。
    /// 这里的瓶颈是「在主线程上做 I/O」，不是「单线程不够快」。
    /// **该用的是「离开主线程」，不是「加线程」。**
    func runScan(mode: ScanEngine.Mode = .full) async {
        guard !readOnly else {
            errorMessage = UICopy.readOnlyNoSettlement
            return
        }
        guard !isScanning else { return }   // **防重复点击**（后台化后更容易被点到）
        isScanning = true
        // ★ 起手就标「在跑」⇒ 页头按钮进「扫描中…」态、界面不空白（§3.8）。
        //   此时分母未知（`totalSources == 0`）⇒ 圆环只画轨道不画弧。
        scanProgress = ScanProgress(isRunning: true)
        rebuild()

        let started = Date()
        let engine = self.engine          // `ScanEngine` 是 `Sendable` 值
        let probe = self.probe            // `UpstreamRunner` 是 `Sendable` 值
        let rootsOverride = self.sourceRootsOverride
        let excludePIDs: Set<pid_t> = [getpid()]

        // ---- 取消令牌（**主 actor 持有**，后台任务读它）----
        let cancelBox = CancelBox()
        scanCancelBox = cancelBox

        // ---- 断点续扫（AC-20 / R2 §5.5）----
        //
        // ⚠️ **断点此前从未落过盘**：引擎一直能生产它，但 `runScan` 把
        // `result.checkpoint` 直接丢弃、日志里 `breakpointSaved` 写死 `false`。
        // 于是进程一重启断点就没了 —— 用户取消/超时中断一次，13 秒要从头再来。
        //
        // `E-106`（断点不可信）→ **全量重扫**，不拿坏断点续。
        let resumeCheckpoints: [String: ScanEngine.Checkpoint]
        switch checkpoints.load() {
        case .none:
            resumeCheckpoints = [:]
        case .usable(let cps):
            resumeCheckpoints = cps
        case .corrupt(let reason):
            // 坏断点必须**如实告诉用户**并丢弃：拿它续扫会静默少算候选
            // → `T` 偏小 → 门槛判据建立在错数上。
            checkpoints.clear()
            errorMessage = describe(.e106, detail: reason)
            resumeCheckpoints = [:]
        }
        // 断点只在 `full` 模式下有意义：增量扫描本就只查已知候选，
        // 拿全量断点去续会让「增量」静默变成「不扫」。
        let usableCheckpoints = (mode == .full) ? resumeCheckpoints : [:]
        // **非全量扫描不得沿用旧断点** —— 那份断点描述的是上次被中断的全量扫描，
        // 与本次模式不符，续上去就是错。
        if mode != .full { checkpoints.clear() }

        // ---- 进度轮询（**主 actor 上的定时器**）----
        //
        // 后台任务把进度写进 `cancelBox`，这里每 100 ms 取一次写进 `scanProgress`
        // → 界面上的文字会持续变化 → 用户看到它在动。
        //
        // **为什么用轮询而不是后台直接写 `@Observable` 属性**：
        // 后台任务写主 actor 的属性需要 `await MainActor.run`，
        // 那会让「进度」与「取消」分裂成两套机制；
        // 而轮询只有一个写入点（主 actor），**不存在竞态**。
        let progressTask = Task { @MainActor in
            while !Task.isCancelled {
                let p = cancelBox.takeProgress()
                if p != scanProgress {
                    scanProgress = p        // 权威活值
                    // ★ 同 tick 回填页面模型：`rebuild()` 会整体替换 `pageModel`，
                    //   只写 `scanProgress` 的话，横条会停在上一拍（§3.9）。
                    pageModel.scanProgress = p
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        // ================= 重活在主 actor 之外 =================
        let job = await Task.detached(priority: .userInitiated) { () -> ScanJob in
            var job = ScanJob()
            job.mode = mode

            // ---- 来源根（用上游只读命令定位；失败回退标准路径）----
            let roots = resolveSourceRoots(
                override: rootsOverride,
                probe: probe,
                upstream: &job.upstream
            )

            // ★ 累加器：**分母先到**（进循环之前）⇒ 第一拍的圆环就画得出弧（§3.6 (a)）
            var acc = ScanProgressAccumulator(totalSources: roots.count)
            cancelBox.report(acc.starting(elapsed: Date().timeIntervalSince(started)))

            // ---- 逐来源扫描 ----
            for (sourceName, root) in roots {
                // **留存来源根**：执行期越界判定（AC-19）用它，
                // 不用执行时重新解析的那份（可能已变）。
                job.roots[sourceName] = root
                // **取消检查**：每条来源一次（来源只有 3 个，开销可忽略）
                if cancelBox.isCancelled { break }
                guard FileManager.default.fileExists(atPath: root) else {
                    // ★ 根不存在 = 这个来源已经扫完了（结果是「没有」）⇒ 分子照样推进（§3.6 (c)）
                    cancelBox.report(acc.completing(
                        source: sourceName, files: 0, candidates: 0,
                        elapsed: Date().timeIntervalSince(started)
                    ))
                    continue
                }
                do {
                    // ★ 不可变快照：`progress:` 闭包是 `@Sendable`，捕获 `var` 编译期报错（§3.7）
                    let base = acc
                    let result = try engine.scan(
                        root: root,
                        mode: mode,
                        // 续扫：该来源上次中断时的断点（没有则全量新扫）
                        checkpoint: usableCheckpoints[sourceName],
                        // ---- 中止检查（AC-20：取消 5 s 内停 I/O）----
                        //
                        // ⚠️ **必须在引擎内部逐目录检查**，不能只在外层
                        // `for (sourceName, root)` 循环里查一次：一个来源 11 万条目
                        // 的遍历中途不回头，取消要等它**整条扫完**才生效
                        // （实测单来源 ~6.7 s）→ 用户点了取消，界面还在扫。
                        // 契约要的是「取消动作后 5 秒内无新增扫描 I/O」。
                        abortCheck: ScanEngine.AbortCheck {
                            cancelBox.isCancelled ? .userCancelled : nil
                        },
                        // ---- 超时（N1：全量扫描 600 s → `E-105`）----
                        deadline: started.addingTimeInterval(ScanEngine.fullScanTimeout),
                        now: started,
                        // **进度回流**：每 2000 条一次 → 11 万条约 56 次
                        progress: { p in
                            // ★ (b) 点：本来源进行中（分子不动，条目数临时叠加显示）
                            cancelBox.report(base.progressing(
                                source: p.source,
                                deltaFiles: p.filesScanned,
                                deltaCandidates: p.candidatesFound,
                                elapsed: Date().timeIntervalSince(started)
                            ))
                        }
                    )
                    job.results.append((sourceName, result))
                    // ★ (c) 点：**分子推进**（圆环走一格）+ 该来源的最终数落进合计
                    //   ⇒ 小来源（< progressEvery = 2000 条）也会推进（修缺陷 #8）
                    cancelBox.report(acc.completing(
                        source: sourceName,
                        files: result.filesScanned,
                        candidates: result.candidates.count,
                        elapsed: Date().timeIntervalSince(started)
                    ))
                    // 中断的来源 → 带走它的断点，收尾时落盘（AC-20 可续扫）
                    if let cp = result.checkpoint {
                        job.abortedCheckpoints[sourceName] = cp
                    }
                    if let ab = result.aborted, job.abortReason == nil {
                        job.abortReason = ab.rawValue
                    }
                } catch {
                    // 单个来源不可读不阻断整体（AC-14 第一类：来源不可读 → 降级只读该来源）
                    job.failures.append((sourceName, error.localizedDescription))
                    // ★ 失败**也算这个来源处理完了** ⇒ 分子照样推进
                    //   （否则圆环会卡在失败来源那一格，直到整轮结束才跳走）
                    cancelBox.report(acc.completing(
                        source: sourceName, files: 0, candidates: 0,
                        elapsed: Date().timeIntervalSince(started)
                    ))
                }
            }

            // ★ 合计回填 `ScanJob`（执行记录用）⇒ **单一计数器**：
            //   累加只发生在 `acc` 里（不变量②）。
            job.filesScanned = acc.filesScanned
            job.candidatesFound = acc.candidatesFound

            // ---- L0 探测（排除自身，防自污染）----
            // **也在主 actor 之外**：它要枚举同 uid 进程的 fd，同样是重 I/O。
            job.snapshot = L0Probe.snapshot(excludePIDs: excludePIDs)

            // ---- 逐候选 L0 判定（**也在主 actor 之外**）----
            //
            // 每条候选一次 `lstat`（十万级）⇒ 同样是重 I/O，
            // 放主 actor 会让界面卡住（§七坑 8）。
            //
            // 判定结果**按来源分组**带回主 actor：探测在 `L0Judge`、
            // 归因在 `ObservationWriteback`，两层分开，写回层可纯函数单测。
            let judgeSnapshot = job.snapshot ?? L0Snapshot()
            for (sourceName, result) in job.results {
                job.candidatesBySource[sourceName] = result.candidates
                job.judgmentsBySource[sourceName] = L0Judge.judge(
                    candidates: result.candidates,
                    snapshot: judgeSnapshot
                )
            }
            return job
        }.value

        // ================= 回到主 actor：落盘与刷新界面 =================
        var allCandidates: [ScanEngine.Candidate] = []
        var bytesScanned: Int64 = 0
        var unknownCount = 0
        for (sourceName, result) in job.results {
            bytesScanned += result.candidates.reduce(Int64(0)) { $0 + $1.bytes }
            unknownCount += result.unknownCount
            // 引擎按路径片段匹配来源；这里以「扫描根所属来源」为准做一次校正，
            // 避免路径里恰好含别的来源片段时被误判。
            for var c in result.candidates {
                if c.source.isEmpty { c.source = sourceName }
                allCandidates.append(c)
            }
        }

        candidates = allCandidates
        lastUpstreamCommands = job.upstream
        lastScanMode = job.mode
        // **执行期越界判定的依据**（AC-19）：与本次扫描同一份根
        lastSourceRoots = job.roots

        // **来源级错误**（此时已在主 actor，可用 `describeScanError` 取码表文案）
        if let first = job.failures.first {
            errorMessage = "\(first.source)：\(describeScanErrorMessage(first.message))"
        }

        let snapshot = job.snapshot ?? L0Snapshot()

        // ---- 写回层（Core · 「一次扫描 → 载体」的**唯一**转换处）----
        //
        // 取快照 / 结算 / `a` 写入 / `b` 累计 / 计数日推进 **全在这里发生**。
        // 编排层只负责把扫描结果**收集齐**再交给它 ——
        // 编排层一旦自己算这些量，就出现了第二套实现，两处必然分叉
        // （这正是 CR-031 要修的断链：`K` / `J` / `producedAt` 从未被写过非空值）。
        var scannedSources: Set<Source> = []
        var writebackCandidates: [Source: [CandidateID]] = [:]
        var writebackJudgments: [Source: [CandidateID: L0Verdict]] = [:]
        for (sourceName, _) in job.results {
            guard let source = Source(rawValue: sourceName) else { continue }
            scannedSources.insert(source)
            writebackCandidates[source] = (job.candidatesBySource[sourceName] ?? []).map {
                CandidateID(path: $0.path, birthtime: $0.birthtime)
            }
            writebackJudgments[source] = job.judgmentsBySource[sourceName] ?? [:]
        }

        let outcome = ObservationWriteback.apply(
            input: ObservationWriteback.Input(
                now: started,
                // **中止 ≠ 失败，但中止的那次扫描不算「完成」**：
                // 中止不取快照、不结算、不推进计数日（仍累计 `a` / `b`）。
                succeeded: job.abortReason == nil,
                mode: job.mode,
                degraded: snapshot.degraded,
                scannedSources: scannedSources,
                candidates: writebackCandidates,
                judgments: writebackJudgments
            ),
            header: contents.header,
            payloads: contents.payloads
        )
        contents.header = outcome.header
        contents.payloads = outcome.payloads

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
        // 现在两者都从**判定结果**导出（判定是唯一来源）：
        // `pNowCount` = 判为「有活引用」的条数；`b` = 本轮真正执行了判定的条数。
        let pNowCount = writebackJudgments.values.reduce(0) { total, verdicts in
            total + verdicts.values.filter { $0 == .hasLiveReference }.count
        }
        // 降级（无法枚举同 uid 进程）⇒ 本轮**没有真正执行检查** ⇒ 如实记 0，
        // 让门槛自然不满足（不假装检查过）。
        let checkedCount = snapshot.degraded ? 0 : writebackJudgments.values.reduce(0) { $0 + $1.count }

        // ---- 更新诊断 ----
        lastScanDiagnostics = ScanLogRecord.Diagnostics(
            degraded: snapshot.degraded,
            coverage: .init(
                sameUIDTotal: snapshot.coverage.sameUIDTotal,
                sameUIDRead: snapshot.coverage.sameUIDRead,
                statOtherUID: snapshot.coverage.statOtherUID
            ),
            pNowCount: pNowCount,
            // `fSetBits` = `F` 位图的**置位数** —— 从**载体**读（写回层刚更新过），
            // 不另算一份（与 `doneCount` 同一口径；不变量②：同一判定只有一个实现处）。
            //
            // ⚠️ 曾被**写死为 `0`**：CR-031 之前 `F` 位图恒空，`0` 碰巧是对的；
            // CR-031 之后位图首次真实承载数据 ⇒ `0` 从「碰巧对」变成「稳定的错」。
            fSetBits: contents.payloads.values.reduce(0) { $0 + $1.fSetBitCount },
            // `doneCount` = 已计误判的候选数（`C_done` 规模）——
            // 从**载体**读（写回层刚更新过），不另算一份。
            doneCount: contents.header.sources.reduce(0) { $0 + $1.doneCount },
            // `a`（累计误判数）**只增不减**（CR-022 偏差 3），清采集物也不清它。
            a: accumulatedMisjudgment(for: nil),
            b: checkedCount,
            round: contents.header.round,
            countedDays: contents.header.countedDays,
            // **内容读取次数恒为 0**：扫描只读元数据、不读内容（AC-07 载体）
            contentReads: 0
        )

        // ---- 落盘（**必须真写**，否则 A-10 第 9 步不可达）----
        persist()

        // ---- 断点落盘 / 清除（AC-20 可续扫）----
        //
        // 两条路互斥，且都**必须真落盘**：
        //   · 有来源被中断 → 写 `state/checkpoints.json`（下次启动续扫）
        //   · 全部正常完成 → 清除断点（没有「未扫完的部分」了）
        //
        // ⚠️ 此前这里恒为 `false`（断点被直接丢弃），所以「用户取消一次 →
        // 重启后从头再来」：13 秒的扫描白跑。
        var breakpointSaved = false
        do {
            if job.abortedCheckpoints.isEmpty {
                checkpoints.clear()
            } else {
                try checkpoints.save(job.abortedCheckpoints)
                breakpointSaved = true
            }
        } catch {
            // 断点写不进去**不影响本次扫描结果**（候选已拿到），
            // 但要让用户知道「这次中断的进度没保住」—— 不静默。
            errorMessage = L.pick(
                "断点未能保存，下次扫描将从全量开始：\(error.localizedDescription)",
                "Couldn't save the checkpoint; the next scan will start from a full scan: \(error.localizedDescription)"
            )
        }

        // ---- 扫描日志（AC-19 唯一可判载体）----
        let record = ScanLogRecord(
            at: started,
            mode: job.mode.rawValue,
            sources: job.results.map { $0.source },
            filesScanned: job.filesScanned,
            bytesScanned: bytesScanned,
            durationMs: Int(Date().timeIntervalSince(started) * 1000),
            aborted: job.abortReason,
            breakpointSaved: breakpointSaved,
            unknownCount: unknownCount,
            upstreamCommands: job.upstream,
            diagnostics: lastScanDiagnostics
        )
        do {
            try writer.appendScan(record)
        } catch {
            // **未落盘即「无法证明」，验收按不通过**（§5.4）——
            // 所以这里把失败如实暴露给用户，不静默。
            errorMessage = L.pick("扫描日志写入失败：\(error.localizedDescription)", "Failed to write scan log: \(error.localizedDescription)")
        }

        lastAbort = job.abortReason
        isScanning = false
        scanProgress = ScanProgress()
        scanCancelBox = nil
        progressTask.cancel()
        rebuild()
    }

    /// **取消当前扫描**（用户反悔）。
    ///
    /// 契约：`E-104`「用户取消」—— **取消不是失败**，它落断点、且**不计入计数日**。
    func cancelScan() {
        guard isScanning else { return }
        scanCancelBox?.cancel()
        // **不立刻置 `isScanning = false`** —— 后台任务还在收尾，
        // 提前置 false 会让用户能再点一次扫描 → 两个扫描并发 → 状态错乱。
        // 真正的复位在 `runScan` 收尾处。
    }

    /// 把一个错误消息还原成带码的文案（后台拿不到 `describeScanError` 的结构化错误）。
    private func describeScanErrorMessage(_ raw: String) -> String {
        // 后台任务里只能拿到 `localizedDescription`。
        // 这里做**尽力而为**的还原：若消息里含已知码字面量则直接引用，否则原样展示。
        if let code = DiagnosticCode.allCases.first(where: { raw.contains($0.rawValue) }) {
            return "\(code.rawValue) · \(code.summary)"
        }
        return raw
    }


    // MARK: - 开关

    /// 点亮 / 关闭自动删除。
    ///
    /// **未达线不得点亮**（AC-08 组 B）——由 `GateEvaluator.isQualified` 决定，
    /// 界面只读 `pageModel.canLightUp`，此处再兜一次底。
    func setAutoDelete(_ on: Bool) {
        guard !readOnly else { return }
        if on && !pageModel.canLightUp {
            errorMessage = L.pick("未达达标条件，不能点亮自动删除", "Gate not met; auto-delete can't be enabled")
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
            errorMessage = L.pick("未达达标条件，本次不执行（逐来源复核未通过）", "Gate not met; nothing executed this time (per-source re-check failed)")
            return
        }
        // **执行方式闸（AC-03）**：默认「仅报告」= 永不删。
        // 原先这里不读 executionMode → 用户在 ③ 页选「仅报告」形同虚设。
        guard preferences.executionMode == .autoDelete else {
            return
        }
        guard !isScanning else { return }

        let now = Date()
        // 「首次」= 本机**首次产生实际删除动作**（AC-15 的阶段分界）
        let isFirstRun = executions.isEmpty
        var newRecords: [ExecutionRecord] = []
        var totalSkipped = 0
        var totalFailures = 0

        // ---- **执行时刻的 L0 快照**（AC-17 二次检查的输入）----
        //
        // ## 为什么必须现取、不能用扫描期那份
        //
        // 扫描可能发生在几分钟前、甚至（定时点）昨天。那份快照记录的是
        // 「扫描那一刻谁持有文件」。而 AC-17 判的是「**删除前这一刻**还有没有
        // 活引用」—— 用过期快照等于拿旧证据判当下，TOCTOU（time-of-check-to-time-of-use）
        // 窗口内的活引用会漏掉 → 误删正在被使用的文件。
        //
        // `L0Probe.snapshot` 要枚举全部同 uid 进程的 fd，是重 I/O（同扫描），
        // 故同样**离开主 actor**（不变量：重 I/O 不在 `@MainActor`）。
        // 排除自身 pid（IF-03 自污染防护，与扫描期同一纪律）。
        let excludePIDs: Set<pid_t> = [getpid()]
        let secondCheckSnapshot = await Task.detached(priority: .userInitiated) {
            L0Probe.snapshot(excludePIDs: excludePIDs, now: now)
        }.value

        for source in Source.allCases {
            // **域外只报告三类恒为仅报告**（`pipx` run / pnpm store / bun cache）：不在判定域 → 永不参与自动删除（AC-04 ②）
            guard source.isInDecisionDomain else { continue }

            // **白名单闸（AC-03）**：被保护的条目在执行路径上**真的被排除**。
            //
            // 原先 `candidates` 全量直接进 `executeBatch` → 白名单只过滤了显示，
            // 执行照样删被保护目录下的文件。那是「用户以为保护生效了，
            // 而它在执行路径上不存在」——本产品最不能犯的谎之一。
            //
            // 走 `WhitelistGuard`（Core 唯一原语），与展示层同一份匹配逻辑。
            let sourceCandidates = WhitelistGuard.filter(
                candidates: candidates.filter { $0.source == source.rawValue },
                whitelist: preferences.whitelist,
                path: { $0.path }
            )

            // ---- **AC-17 删除前二次检查**（身份复核 + L0 复核）----
            //
            // 候选是「扫描时刻」的快照，删除发生在「之后的执行点」。这中间文件系统
            // 可能已经变了：路径被同名重建、文件被删、文件被活引用持有。
            // **不复核就删 = 误删**（你以为删的是观察期证明没用的那个缓存，
            // 实际删的是用户刚重新装好的同名目录）。
            //
            // 两道复核（判定都在 Core，本层只编排）：
            //   ① 身份复核（`SecondCheck.checkIdentity`）：重读 birthtime，
            //      不一致 = 同名重建 = **不是当初判定的那个文件** → 放弃。
            //   ② L0 复核（`SecondCheck.isLiveHeld`）：用**执行时刻**的新快照
            //      再探一次活引用 → 被持有 → 放弃。
            //
            // 被阻断的条目**仍写 `execution.jsonl`**（`.blockedSecondCheck`）——
            // 举证链不缺这一行，AC-18 的完整率才真实。
            var ids: [CandidateID] = []
            for cand in sourceCandidates {
                let id = CandidateID(path: cand.path, birthtime: cand.birthtime)

                // ⓪ **执行范围守卫（AC-19 / R2:218）** —— 最高优先，先于其它复核。
                //
                // 扫描端用 `fileExists(atPath:isDirectory:)` 判目录，而该 API
                // **跟随符号链接**（真文件系统实测确认）：来源根里一个指向
                // `~/Documents` 的 symlink 会被当目录下探 → 根外文件成为候选。
                // 执行端若不复核，就把根外的文件移进废纸篓了。
                //
                // 四道判定（存在 / 非 symlink / 真实路径在根内 / 同卷）全在
                // `ScopeGuard`（Core，可单测）。这里只编排与留痕。
                //
                // 拿不到来源根时 → **拒绝执行**（不把未知判为安全）。
                if let root = lastSourceRoots[source.rawValue] {
                    if let rejection = ScopeGuard.check(path: cand.path, allowedRoot: root) {
                        newRecords.append(
                            ExecutionRecord(
                                id: id, source: source, action: .blockedOutOfScope,
                                originalPath: cand.path, restorePath: nil, executedAt: now,
                                bytes: cand.bytes, bytesKind: cand.isDirectory ? .dirRecursive : .file,
                                blockedReason: rejection.diagnostic.summary,
                                bytesPreview: cand.bytes, bytesMeasuredAt: now
                            )
                        )
                        continue
                    }
                } else {
                    // 没有该来源的根 → 无法证明在范围内 → 不删（不把未知判为安全）
                    newRecords.append(
                        ExecutionRecord(
                            id: id, source: source, action: .blockedOutOfScope,
                            originalPath: cand.path, restorePath: nil, executedAt: now,
                            bytes: cand.bytes, bytesKind: cand.isDirectory ? .dirRecursive : .file,
                            blockedReason: L.pick("无法确认该来源的允许根，已跳过", "Allowed root for this source unknown; skipped"),
                            bytesPreview: cand.bytes, bytesMeasuredAt: now
                        )
                    )
                    continue
                }

                // ① 身份复核
                switch SecondCheck.checkIdentity(path: cand.path, recordedBirthtime: cand.birthtime) {
                case .vanished:
                    // 文件已不存在 → 没东西可删，记一行如实留痕（不是失败）
                    newRecords.append(
                        ExecutionRecord(
                            id: id, source: source, action: .blockedSecondCheck,
                            originalPath: cand.path, restorePath: nil, executedAt: now,
                            bytes: cand.bytes, bytesKind: cand.isDirectory ? .dirRecursive : .file,
                            blockedReason: "二次检查：文件已不存在（已自行删除）",
                            bytesPreview: cand.bytes, bytesMeasuredAt: now
                        )
                    )
                    continue
                case .rebuilt:
                    // **同名重建** → 现在那个文件不是当初判定的那个 → 放弃（误删防线）
                    newRecords.append(
                        ExecutionRecord(
                            id: id, source: source, action: .blockedSecondCheck,
                            originalPath: cand.path, restorePath: nil, executedAt: now,
                            bytes: cand.bytes, bytesKind: cand.isDirectory ? .dirRecursive : .file,
                            blockedReason: "二次检查：路径已被同名重建（birthtime 不一致），不是当初判定的文件",
                            bytesPreview: cand.bytes, bytesMeasuredAt: now
                        )
                    )
                    continue
                case .unchanged:
                    break
                }

                // ② L0 复核（用执行时刻新取的快照）
                if let identity = L0Probe.identity(atPath: cand.path),
                   SecondCheck.isLiveHeld(
                       identity: identity, isDirectory: cand.isDirectory,
                       path: cand.path, by: secondCheckSnapshot
                   ) {
                    newRecords.append(
                        ExecutionRecord(
                            id: id, source: source, action: .blockedSecondCheck,
                            originalPath: cand.path, restorePath: nil, executedAt: now,
                            bytes: cand.bytes, bytesKind: cand.isDirectory ? .dirRecursive : .file,
                            blockedReason: "二次检查：删除前发现活引用（进程正在使用）",
                            bytesPreview: cand.bytes, bytesMeasuredAt: now
                        )
                    )
                    continue
                }

                ids.append(id)
            }
            guard !ids.isEmpty else { continue }

            // ---- **`t1` 预检值**：取扫描时算好的逻辑字节（IF-08 的唯一来源）----
            //
            // 契约原文：「「删除前预估」用的字节数 = IF-07 的 `t1` 递归字节
            //（**首检时刻**算出的值，**随候选一起缓存到执行点**），
            // **不是执行时刻的实时递归值**。」
            //
            // `Candidate.bytes` 正是扫描期算出的那份（目录为递归逻辑字节）。
            //
            // **为什么必须用缓存值而不是现算**：契约要的是
            // 「预检通过 → `rename` 发生 → `t2` 实测超限 → 移回原位」这条路径**可达**。
            // 若预检用执行时刻的实时值，那么预检值 == `t2` 实测值 → 永不超限
            // → 那条路径不可达 → 判据失去判别力（恒真）。
            let preflight: [CandidateID: Int64] = Dictionary(
                sourceCandidates.map {
                    (CandidateID(path: $0.path, birthtime: $0.birthtime), $0.bytes)
                },
                uniquingKeysWith: { first, _ in first }
            )

            // 容量上限（AC-15）—— **判定在 Core 的唯一实现处**，本层不自己算。
            //
            // 三条上界取最小：用户配置 / 首次档绝对上限 5 GB / 来源总量按比例。
            //
            // ⚠️ 稳定后那一档**同样**受用户配置约束：
            // 原实现这一支只写 `T×20%`，把用户设置的上限丢了 ——
            // 于是「把上限调小」这个动作在第二次执行时**静默失效**。
            let cap = TrashExecutor.capacityCap(
                userCapBytes: preferences.capacityCapBytes,
                absoluteCapBytes: Self.firstRunAbsoluteCapBytes,
                sourceTotalBytes: sourceTotalBytes(for: source),
                tier: isFirstRun ? .firstRun : .steady
            )

            let outcome = executor.execute(
                candidates: ids,
                source: source,
                capacityCap: cap,
                countCap: preferences.itemCap,
                // **`t1` 预检值随候选缓存到执行点**（IF-08）
                preflightBytes: preflight,
                now: now
            )
            newRecords.append(contentsOf: outcome.records)
            totalSkipped += outcome.skippedByCap
            // **失败不再丢弃**：原先 `outcome.failures` 被直接扔掉，
            // 执行期错误因此不留任何痕迹（用户和日志都看不到）。
            totalFailures += outcome.failures.count
        }

        // 写 `execution.jsonl`（AC-18 举证链的数据源）
        for rec in newRecords {
            try? writer.append(rec, kind: .execution, now: now)
        }
        executions.append(contentsOf: newRecords)

        // AC-15：顺延条目数 = 候选总数 − 实际删除条目数
        let deleted = newRecords.filter { $0.action == .renameToTrash }.count
        deferredCount = Swift.max(0, totalSkipped)

        // ---- **结果反馈**：用户点了「执行」，必须得到答复 ----
        //
        // 原先执行完只写 `lastExecutionAt` 然后 rebuild —— 界面上什么都不变。
        // 用户不知道删了几条、有没有失败、要不要处理。`outcome.failures`
        // 更是**完全丢弃**（连日志都没有），失败没有任何痕迹。
        let deletedRecords = newRecords.filter { $0.action == .renameToTrash }
        lastExecutionNotice = PageModel.ExecutionNotice(
            deletedCount: deletedRecords.count,
            deletedBytes: deletedRecords.reduce(Int64(0)) { $0 + $1.bytes },
            deferredCount: deferredCount,
            failedCount: newRecords.filter { $0.action == .failed }.count + totalFailures,
            blockedCount: newRecords.filter { $0.action == .blockedSecondCheck }.count
                + newRecords.filter { $0.action == .blockedOutOfScope }.count
        )

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

    /// 某来源的**逻辑字节总量**（AC-15 容量上限的分母）。
    ///
    /// ## 这里曾经把「候选条数」当字节用 —— 一个静默的灾难
    ///
    /// 原实现：`if let t = entry.T { return Int64(t) }`。
    /// 而 `entry.T` 是 **M3 的候选条目数**（`slotCount`），**不是字节**。
    ///
    /// 后果（本机实测）：uv cache 有 115,875 条候选 →
    /// 首次档上限 = `min(5 GB, 115875 × 10%)` = **11,587 字节 ≈ 11.6 KB**。
    /// 于是**几乎每一次执行的所有候选都因「预检超限」被顺延** ——
    /// 用户点了清理，实际删掉的永远是个位数（甚至 0），而且**不报错**。
    ///
    /// ## 正确口径（AC-15 / CR-022 偏差 2）
    ///
    /// 分母 = 该来源候选的**逻辑字节**合计（目录 = 递归普通文件 `st_size` 之和）。
    /// `Candidate.bytes` 正是扫描期按该定义算好的那份 —— 直接求和即得，
    /// 且与执行期 `t1` 预检、`t2` 实测**同一口径**（不变量②：同一判定只有一处实现）。
    ///
    /// **不再看 `entry.T`**：它是条目数，与字节无关。这也是为什么原实现
    /// 在「候选数很少但体积很大」和「候选数很多但体积很小」两种情形下
    /// 都会给出荒谬的上限。
    private func sourceTotalBytes(for source: Source) -> Int64 {
        candidates
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
    /// **不含 `a` 的载体**（`state.residue`）——PRD v5.6 偏差 3 / R2 v1.10 §10.3（S-10）。
    /// 清除范围由 `N7ClearScope` 定义（唯一实现处）：`records/` + 运行期态 + 备份。
    func clearLogs() {
        guard !readOnly else { return }
        // **不删 state.residue**：清了就等于「一键洗掉 L0 误判记录」（S2 可被绕过）
        N7ClearScope.clear(
            stateFile: stateFile,
            checkpoints: checkpoints,
            recordsDirectory: writer.directory
        )
        executions = []
        rebuild()
    }

    // MARK: - 私有

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

    /// 落盘（**只落盘，不算数**）。
    ///
    /// `T` / `H` / `K` / `J` / `a` / `b` / 计数日 **全部由写回层**
    /// （`ObservationWriteback`）算好并写进 `contents`。
    /// 编排层在这里**只做一件事：把载体存下去** ——
    /// 一旦在这里自己算这些量，就会出现第二套实现，两处必然分叉
    /// （CR-031 修的正是这种断链：`T` 恒 nil → 门槛链断在起点）。
    private func persist() {
        // **纵深防御**：只读态一律不落盘。
        //
        // 调用方比对「主文件是否存在」更可靠 —— 损坏态下主文件已被移走，
        // 任何基于「文件不存在 = 首启」的判断都会误判。只读是一条硬闸：
        // 载体读不出来的时候，我们**没有资格**用内存里的空壳去覆盖它。
        guard !readOnly else { return }
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
        panel.nameFieldStringValue = L.pick(
            "Residue-报告-\(Self.timestampForFileName()).md",
            "Residue-Report-\(Self.timestampForFileName()).md"
        )
        panel.canCreateDirectories = true
        panel.title = L.pick("导出脱敏报告", "Export redacted report")
        panel.message = L.pick("报告已脱敏：用户名、主目录、主机名替换为占位符；不包含文件内容。", "The report is redacted: usernames, home directory, and hostname are replaced with placeholders; file contents are not included.")
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
                state: entry.snapshotTaken ? L.pick("在域", "In domain") : L.pick("仅报告", "Report only"),
                // **`nil` 必须原样保留为 `nil`，不得写成 0**
                // （0 会被读成「本轮样本量为零」，而事实是「本轮还没结算」）
                t: entry.T,
                k: entry.K,
                j: entry.J,
                // **失联条目中「无法归因」的条数**（PRD v5.6 M3 · CR-031 §五③）：
                // 单列披露，**不并入已归因、也不静默丢弃**。
                // `nil`（尚未结算）原样保留 ⇒ 渲染为「—」，不得写成 0。
                unattributable: entry.unattributableCount,
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
                detail: L.pick(
                    "需要 \(need / 1_000_000) MB，当前可用 \(avail / 1_000_000) MB",
                    "Needs \(need / 1_000_000) MB; \(avail / 1_000_000) MB available"
                )
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
