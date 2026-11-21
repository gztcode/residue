# CR-041 · 增量扫描真做「只复核已登记候选」· 取消延迟 · 执行线程 · README 口径 · P1

> 状态：待实施
> 变更类型：实现口径修复（**不改 `T` 公式、不改门槛判定、不改 `Source` 枚举**）
> 影响面：`ResidueCore`（`ScanEngine` / `TrashExecutor`）、`ResidueApp`（`AppModel`）、`README.md` / `README.en.md`、单测 7 个
> 风险等级：P1 —— 不触碰「删除只做 rename 到废纸篓」与「删之前先证明自己判得准」两条核心不变量；风险集中在「增量日的覆盖率」与「执行并发」

---

## 一、缺陷

### 1.1 「增量」名不副实：与全量做同样的工作

`ResidueApp/Sources/ResidueCore/ScanEngine.swift` 的 `scan(root:mode:...)` 此前**没有任何按 `mode` 的分支**：`mode` 只影响取不取快照（`takeSnapshot ?? (mode == .full)`），遍历行为与全量完全相同。

而排程是**每日 1 次、每 7 天里 6 天跑增量**（`SchedulePlanner`，N3）：

```swift
// ResidueApp/Sources/ResidueCore/SchedulePlanner.swift
/// 全量扫描间隔（默认 7 天；其余为增量）。
```

⇒ 6/7 的日子里，产品花 ~12–13 s 把整棵子树重走一遍（含 pnpm store 的 11.7 万条），**判定上没有任何收益**：R2 §7.3 ① 要求的是「对已登记候选批量重取属性」，不是「重新发现候选」。

### 1.2 取消延迟 ~6.8 s，超过 AC-20 的 5 s

`abortCheck.shouldAbort()` 此前只在**进入每个目录前**检查一次。单个来源根下可能有数万条目的单目录（实测 pnpm store），目录内部的 `readdir` + 逐条处理期间取消**不生效** ⇒ 实测取消延迟 ~6.8 s，超过 AC-20 的 5 s。

### 1.3 删除执行跑在主 actor 上

`AppModel.executeBatch()` 是 `@MainActor` 函数，`executor.execute(...)`（真实 `moveItem`，十万级候选）在**主 actor 上同步执行** ⇒ 违反 CLAUDE.md §七-8（重 I/O 必须离开主 actor），清理期间界面卡死。

### 1.4 README 口径与实现不符

`README.md:173` 写「新装的包要到下一次全量扫描（默认每日 1 次）才进清单」，但 `SchedulePolicy.fullScanInterval = 7 * 24 * 3600`（每 7 天 1 次）。**文档与代码对不上就是缺陷**，且这句话会让用户对「新包多久进清单」产生 7 倍误差的预期。

---

## 二、修法

### 2.1 增量**只复核已登记候选**（R2 §7.3 ①）

`ScanEngine.scan` 新增可选参数 `registered: [Candidate] = []`；当 `mode == .incremental && !registered.isEmpty` 时走 `rescanRegistered(...)`，**不遍历子树**：

| 情形 | 处理 | 理由 |
|---|---|---|
| 路径不再存在 | 剔除 | 候选已被删除，保留会虚报可回收字节 |
| `attributes` 失败（权限 / 竞态） | 剔除 | 看不见 ⇒ 不猜（不变量③） |
| `birthtime` 变化（同名重建） | 剔除 | 新文件不是「被观察了 14 天」的那个文件；执行侧 `SecondCheck.checkIdentity` 也会拦 |
| `birthtime` 不变 | 保留，**重取 `bytes`** | 同一个文件长大了，字节要更新 |
| 整块粒度来源（`pnpmStore` / `bunCache`） | **存在即原样保留** | 候选 `bytes` 是聚合值，不是目录自身 `st_size`；重取会把「3 GB」读成「96 B」 |
| 进程重启后 `registered` 为空 | 回落全量遍历，`mode` 仍为 `incremental` | `AppModel.candidates` 只在内存（`state.residue` 不得含文件名清单）；回落避免静默产出空清单 |
| 复核中途取消 / 超时 | **未复核的候选原样保留** | 取消不是「候选消失」的证据；丢弃会让清单静默缩水，下一次清理漏掉它们（要等下一轮全量才回来） |

候选**按路径归属**分给来源根（`path == root || path.hasPrefix(root + "/")`，与遍历同一判据），**不按 `candidate.source` 分组**：一个路径可命中多个来源（`source` 为逗号连接），按来源分会让它落不进任何一次扫描、在增量日静默消失（见 §四-3）。

**不取快照**（`snapshotTaken = false`）、**不结算**（`ObservationWriteback` 只对 `full` 结算）—— `T` 公式与门槛判定**一行未动**。

### 2.2 取消检查移到**条目级**

在条目循环内，与进度回调共用同一间隔：

```swift
if filesScanned % every == 0 {
    if let reason = abortCheck.shouldAbort() { aborted = reason; break }
    if let deadline, Date() >= deadline { aborted = .timeout; break }
    if let progress { progress(...) }
}
```

取消延迟上界 = **`progressEvery`（默认 2000）个条目的处理时间（~0.1 s）**，远在 5 s 之内。

同时修复一个续扫正确性问题：条目循环因中止退出后，**本目录没有枚举完**，不得 `cp.markExpanded(dir:)`——否则续扫会把该目录当成「已展开」而跳过剩余条目：

```swift
// 条目循环因中止退出 ⇒ 本目录**没有枚举完**，不得记「已展开」。
if aborted != nil { break scanLoop }
cp.markExpanded(dir: dir)
```

### 2.3 删除执行搬离主 actor

- `TrashExecutor` 声明 `: Sendable`（全部存储属性为 `let`，`fileManager` 已是 `nonisolated(unsafe)`）；
- `AppModel.executeBatch()` 中取局部 `let executor`，把 `executor.execute(...)` 放进 `Task.detached(priority: .userInitiated)`，只把结果带回主 actor 记计数器 / 落 `execution.jsonl`；
- 新增 `isExecuting` 重入守卫：执行出现 `await` 挂起点后主 actor 的天然串行不再防重入，两个批次并发跑会对同一候选各发一次 `moveItem`（一次成功、一次失败，`execution.jsonl` 留下互相矛盾的记录）。`executeBatch` 与 `runScan` 双向互斥。

### 2.4 README / README.en 口径修正

「下一次全量扫描（默认每日 1 次）」→「下一次全量扫描（默认每 7 天 1 次）」，并写明增量**只复核已登记候选**、不遍历子树。

---

## 三、为什么不只改口径（选 (b) 而不是 (a)）

选项 (a) 是「让非全量日不跑无用的全遍历」（改口径 / 跳过扫描）。不选它，理由三条：

1. **R2 §7.3 ① 本就规定增量 = 对已登记候选批量重取属性。** 改口径会让代码与契约基线正面冲突，需要改 R2 正文与 `verify_r2.py` 的落地断言——那是比本单大得多的语义变更。
2. **N3 的「每日 1 次」会失去意义。** 增量不结算（`ObservationWriteback` 只对 `full` 结算），若其余 6 天干脆不扫，14 天观察期就需要 14 次全量 ⇒ 按 7 天全量间隔计算约 **98 天**，把「14 天影子观察期」这个产品承诺拉长 7 倍。
3. **增量日确实需要复核。** 「登记的候选是否还在 / 是否长大了」是每日都该更新的信息（① 页字节数与 ③ 页未达项都依赖它）；跳过扫描会让界面数字连续 6 天停在陈旧值。

本单**不改 `T` 公式**：增量不取快照、不结算，`T` 仍只由 `full` 的快照确定。

---

## 四、已知缺口（如实登记）

1. **R2 §7.3 ② 未实现**：契约写的第二件事是「对来源根 + 一级子目录做 `readdir` 计数粗差（与上次比对，不用 mtime）」。本期只实现 ①；② 没有消费者（增量不负责发现新候选，新候选由全量发现），且需要把「上次的一级目录项数」持久化到 `state.residue`。**登记为缺口，不假装已实现**；若后续要让增量发现新候选，另开变更单。
2. **进程重启后的第一次增量**：`registered` 为空 ⇒ 回落全量遍历（见 §2.1 末行）。模式仍是 `incremental`，**不取快照**——避免用子集确定 `T`（R2 §7.3 快照条款）。
3. **多命中来源的候选**（`source` 形如 `"uvCache,pipxRun"`）：增量输入**按路径归属**分给来源根，不按 `candidate.source` 分组 —— 按来源分组会让这类候选落不进任何一次扫描，在增量日静默从清单消失。执行侧仍按 `source == rawValue` 严格相等过滤，这类候选不会被清理（既有行为，本单不改）。

---

## 五、落点穷举表

| 文件 | 落点 | 改什么 |
|---|---|---|
| `Sources/ResidueCore/ScanEngine.swift` | `scan(...)` 签名（L503） | 新增 `registered: [Candidate] = []` |
| 同上 | L530–537 | 增量短路：`mode == .incremental && !registered.isEmpty` → `rescanRegistered` |
| 同上 | L637–650 | 条目级 abort / deadline / progress 共用 `progressEvery` 间隔 |
| 同上 | L676–677 | 中止后 `break scanLoop`，不记 `markExpanded` |
| 同上 | L752–826 | 新增私有 `rescanRegistered(...)`（① 的完整实现 + 中文理由） |
| `Sources/ResidueCore/TrashExecutor.swift` | `struct TrashExecutor` | 加 `: Sendable`，注释说明为何可送进 `Task.detached` |
| `Sources/ResidueApp/AppModel.swift` | L40 | 新增 `isExecuting`（重入守卫 + 理由） |
| 同上 | L527–528 | `runScan` 与执行互斥 |
| 同上 | L545–555 | 增量输入：已登记候选（非全量才非空） |
| 同上 | L577–578、L642–650 | 断点注释改口径；按**路径归属**筛出本根的候选并 `registered:` 传入引擎 |
| 同上 | L993–995 | `executeBatch` 重入守卫 + `defer` |
| 同上 | L1185–1200 | `executor.execute` 搬进 `Task.detached`，局部 `executor` / `itemCap` / `capacityCapBytes` |
| `README.md` | L173 | 增量口径 + 全量间隔 7 天 |
| `README.en.md` | L169 | 同上（英文） |
| `Tests/ResidueCoreTests/ScanEngineTests.swift` | L410–577 | 新增 7 个单测（见 §六） |

---

## 六、单测

`ResidueApp/Tests/ResidueCoreTests/ScanEngineTests.swift` 新增 7 个（复用既有 `MemoryFS` / `Counter` / `makeEngine`）：

| 用例 | 断言 |
|---|---|
| `testIncrementalRescanDropsVanishedCandidate` | 路径不存在 ⇒ 候选剔除 |
| `testIncrementalRescanDropsRebuiltCandidate` | `birthtime` 变 ⇒ 剔除（同名重建不是同一个文件） |
| `testIncrementalRescanUpdatesBytesWithoutSnapshot` | `birthtime` 不变 ⇒ 保留且 `bytes` 重取；`filesScanned == 1`；不取快照 |
| `testIncrementalRescanKeepsWholeBlockCandidateAsIs` | `pnpmStore` 候选（聚合字节）存在即原样保留，不被目录 `st_size` 覆盖 |
| `testIncrementalWithoutRegisteredFallsBackToFullWalk` | 基线为空 ⇒ 回落全量遍历，仍不取快照 |
| `testIncrementalAbortKeepsUnrescannedCandidates` | 复核中途取消 ⇒ 已复核的更新字节、**未复核的原样保留**（取消不是候选消失的证据） |
| `testAbortIsCheckedPerEntryNotPerDirectory` | 单目录 5000 条、`progressEvery: 100`、第 2 次询问即取消 ⇒ `filesScanned == 100`、`aborted == .userCancelled`，且该目录**不在** `expandedDirs` |

**单测总数**：555（HEAD 基线）→ **562**（`swift test` 实测，0 failures）⇒ 已同步 `.github/workflows/ci.yml:5`、`.github/workflows/release.yml:211`、`README.md:194`、`ARCHITECTURE.md:34 / 122 / 136`、`CLAUDE.md:20`。

---

## 七、验收

| 命令 | 预期 | 实测 |
|---|---|---|
| `swift build` | 成功 | ✅ Build complete |
| `swift test` | 0 failures | ✅ **562 tests / 0 failures** |
| `python3 scripts/verify_codes.py` | 11 / 0 | ✅ |
| `./scripts/verify_a9.sh` | 80 / 0 | ✅ |
| `swift run --disable-sandbox ResidueApp --verify-wiring /tmp/wiring` | 111 / 0 | ✅ |
| `./tests/contract/check_all.sh` | 191 + 47 | ✅ |
| `python3 tests/contract/verify_r2.py` | 123 | ✅ |
| `python3 tests/contract/verify_counts.py` | 全部一致 | ✅ |

---

## 八、导航项数同步

新增本单 ⇒ `docs/` 下 `.md` 由 143 份变 144 份；`docs/changes/` 由 64 份 / 26 个单号变 65 份 / 27 个单号。

| 文件 | 旧 | 新 |
|---|---|---|
| `CLAUDE.md:11` | 143 份 | 144 份 |
| `CLAUDE.md:127` | 143 份 | 144 份 |
| `ARCHITECTURE.md:87` | 64 份文件 / 26 个单号 | 65 份文件 / 27 个单号 |
