# CR-042 · 回收站占用独立指标（已度量，判据未改）· P1

> 状态：待实施
> 变更类型：**只加度量与呈现，不改 `T` 公式、不改门槛判定、不改 `Source` 枚举**
> 影响面：`ResidueCore`（新增 `TrashUsage` / `TrashUsageRecorder`；`TrashExecutor` / `StateHeader` / `ScanEngine` / `PageModel` / `PageModelBuilder` / `UICopy`）、`ResidueApp`（`AppModel` / `Pages`）、单测 15 个
> 风险等级：P1 —— 不触碰「删除只做 rename 到废纸篓」与「删之前先证明自己判得准」；风险集中在「新字段进二进制载体」与「未知 vs 0」的呈现口径

---

## 一、缺陷

R2 v1.10 §6.3.5 第 2 条（`docs/contract/Residue-R2-技术方案-v1.10.md:524`）已登记：

> **回收站容量**：`recursiveLogicalBytes` 会把**已存在于回收站**的候选也算进 `T` → `T` 偏大、比例档偏松。**已登记，未修**。

`T` 的语义是「候选总量」，而本产品只做 `moveItem` 到 `~/.Trash`：条目进了废纸篓**仍然占着磁盘**，却已从候选域里消失。于是：

1. **用户看不到回收站里还压着多少。** 执行摘要只说「已移入废纸篓 N 条、共 X」，很容易被读成「腾出了 X」——磁盘可用空间一点没变。
2. **`T` 的偏差无据可查。** 「偏大多少」取决于用户清没清空废纸篓，产品里没有任何数字能让人判断这个偏差的量级。

---

## 二、修法

### 2.1 账本：`TrashUsage` + `TrashUsageRecorder`（`Core/TrashUsage.swift`，新增）

```swift
public struct TrashUsage: Codable, Sendable, Equatable {
    public let bytes: Int64   // 累计字节
    public let items: Int       // 累计条数
    public let updatedAt: Date  // 最近一次变动时刻
}
```

`TrashUsageRecorder` 是 Core 侧的记账器（`NSLock` + `@unchecked Sendable`，可被扫描线程读取）：

| 时机 | 动作 | 落点 |
|---|---|---|
| `moveToTrash` 成功（`rename` 已完成） | `recordMoved(bytes:measuredBytes)`：`bytes += max(0, n)`、`items += 1` | `TrashExecutor.moveToTrash` |
| `restore` 成功 | `recordRestored(bytes: record.bytes)`：双向递减，**下界 0** | `TrashExecutor.restore` |
| `t2` 实测超限 → 回滚成功 | `recordRestored(bytes: rec.bytes)` | `TrashExecutor.execute` |
| 预检拦下 / 体积不可得 / rename 失败 | **不记** | —— |

`nil` 表示**没有记录**（首启 / 旧载体 / 从未执行过清理），不是 0。

**口径边界（如实登记）**：只统计「本产品移入、且未恢复」的条目，是系统废纸篓占用的**下界**。用户自己清空废纸篓、或在 Finder 里删了别的东西，产品都感知不到 ⇒ 用户清空后这个数会偏大。这是刻意选择：宁可如实标一个「本产品账」，也不去遍历 `~/.Trash` 猜总量（那需要全盘 stat，且与「只读统计自己看得清的来源」这条产品边界冲突）。

### 2.2 持久化：复用现有载体，不新开存储

`StateHeader` 新增可选字段 `trashUsage: TrashUsage?`。合成 `Decodable` 走 `decodeIfPresent` ⇒ **旧载体没有这个键时解码为 `nil`（未知），不判损坏**。

写入点在 `AppModel`（只编排，不做算术）：

| 时机 | 动作 |
|---|---|
| `loadAndProject()` 里、`applyObservationResetIfNeeded()` 之后、`rebuild()` **之前** | `trashUsageRecorder.seed(contents.header.trashUsage)` |
| 扫描收尾 / `executeBatch` / `restore` 之后 | `contents.header.trashUsage = trashUsageRecorder.usage`，随既有 `persist()` 一次落盘 |

`restore` 原先不落盘，本单补上一次 `persist()` —— 否则「恢复后账变小」要等下一次清理才生效。

**启动顺序（本轮修复）**：seed 原先在 `AppModel.init` 里、`loadAndProject()` **之后**调用，而 `loadAndProject()` 内部的 `rebuild()` 已经投影过一次 —— 首帧取的是空记账器，① 页恒显示「未知（尚无记录）」，且 seed 后不再重投影 ⇒ 一直挂到用户手动扫描 / 清理 / 恢复。这个指标就是「打开 App 想看一眼」用的，首帧错等于功能大半废掉。修法：把 seed 移进 `loadAndProject()`，放在 `applyObservationResetIfNeeded()` 之后（版本变更会清账，先 seed 等于把旧账播回来）、`rebuild()` 之前。

**版本变更清账（本轮修复）**：`clearCarrierForObservationReset(preservingMissCount: false)`（应用版本变更分支）新增 `header.trashUsage = nil` —— 旧版本移入的条目新版本无法核对，账不跨版本带出。判定域指纹变更分支**不清**（条目仍在废纸篓）；也不放进 `resetObservationCredentials`（该函数被 `StateFileMigration` 的 schema 升级复用，迁移不该清用户的账）。

### 2.3 扫描快照带上该字段

`ScanEngine.scan(...)` 新增可选参数 `trashUsage: TrashUsage? = nil`，原样带进 `ScanResult.trashUsage`（三个返回点：中止 / 正常完成 / 增量复核）。**只带快照，不参与任何判定。**

### 2.4 呈现：未知不写 0，文案区分「移入」与「释放」

- `PageModel` 新增 `trashUsageBytes` / `trashUsageItems`，缺省 `.unavailable(reason: UICopy.trashUsageUnknown)`；
- `PageModelBuilder.build` 仅在 `input.trashUsage != nil` 时覆盖为 `.metric(...)`，否则保留 `.unavailable` —— 「没记录过」与「回收站是空的」是两件事（不变量③）；
- ① 页新增「回收站占用」卡片：字节 + 条数 + footnote「本产品移入废纸篓、尚未恢复的条目。它们仍占用磁盘，清空废纸篓后才真正释放。」
- `ExecutionNotice.summary` 成功分支改为「已移入废纸篓 N 条，共 X（**回收站仍占用，尚未释放磁盘空间**）」，中英文同步；
- 所有文案进 `UICopy`，界面零算术（`SemanticSlot` 拿到的都是已算好的值）。

---

## 三、为什么不把回收站占用并入 `T`（判据未改）

`T` 是**删除门槛的输入**（`GateEvaluator.isQualified` 的比例档、`capacityCap` 的分母），改它等于改安全边界：同样一批候选，`T` 变大 ⇒ 比例档变松 ⇒ 更容易点亮「可清理」。这需要 owner 拍板，不属于实现侧的修复范围。

本单因此只做**度量与呈现**，并守住三条：

1. **`T` 的算式一行未动**（`Metrics.swift` 无改动），门槛判定无变化；
2. **新字段不参与任何判定**，只进快照与界面；
3. **未知不冒充 0**：旧载体 / 首启显示「未知（尚无记录）」，不显示 0。

台账记「已度量，判据未改」，不记「已解决」。

---

## 四、已知缺口（如实登记）

1. **口径是下界**：见 §2.1 末段。用户清空废纸篓后数字偏大，产品无法感知。
2. **`T` 仍含已进废纸篓的候选**：R2 §6.3.5 第 2 条保持「已登记，未修」。
3. **崩溃窗口**：`moveItem` 成功与 `persist()` 之间若进程被杀，这一次的增量不会落盘（账偏小）。不做 WAL —— 与本产品「宁可少算，不猜」的方向一致。

---

## 五、落点穷举表

| 文件 | 落点 | 改什么 |
|---|---|---|
| `Sources/ResidueCore/TrashUsage.swift` | 新文件 | `TrashUsage` + `TrashUsageRecorder`（`recordMoved` / `recordRestored` / `seed`） |
| `Sources/ResidueCore/TrashExecutor.swift` | L135–140 | 新增 `usageRecorder` 参数 |
| 同上 | `moveToTrash` | `rename` 成功后 `recordMoved` |
| 同上 | `restore` | 成功后 `recordRestored` |
| 同上 | `execute` 的 `t2` 回滚 | 回滚成功后 `recordRestored`（回滚失败不减） |
| `Sources/ResidueCore/ResidueStateFile.swift` | L267 / L283 / L298 | `StateHeader.trashUsage`（可选，向后兼容） |
| `Sources/ResidueCore/ScanEngine.swift` | L212–231 | `ScanResult.trashUsage` |
| 同上 | L522 / L544 / L709 / L742 / L773 / L840 | `scan` / `rescanRegistered` 传参 + 三个返回点回填 |
| `Sources/ResidueCore/SemanticSlot.swift` | L436–450 | `UICopy.trashUsageUnknown` / `Title` / `Footnote` |
| `Sources/ResidueCore/PageModel.swift` | L99–101 | 两个槽位（缺省 `.unavailable`）+ 执行摘要文案 |
| `Sources/ResidueCore/PageModelBuilder.swift` | L58 / L97 / L118 / L204–207 | `Input.trashUsage` + 投影 |
| `Sources/ResidueApp/AppModel.swift` | L68 / L203–207 / L316–338 / L508 / L569 / L713 / L840 / L1289 / L1317 | 记账器接线 + 启动顺序 seed + 落盘 |
| `Sources/ResidueCore/StateFile.swift` | `clearCarrierForObservationReset` 版本变更分支 | 版本变更时 `header.trashUsage = nil` |
| `Sources/ResidueApp/Pages.swift` | `OverviewPage` | 「回收站占用」卡片 |
| `Tests/ResidueCoreTests/TrashUsageTests.swift` | 新文件 | 14 个单测（含 3 条启动路径 / 版本清账） |
| `Tests/ResidueCoreTests/ExecutionNoticeTests.swift` | `testDeletedSummarySaysSpaceNotFreedYet` | 文案守「尚未释放」 |

---

## 六、单测（15 个）

| 用例 | 断言 |
|---|---|
| `testMoveToTrashIncreasesUsage` | 2048 B → `bytes 2048 / items 1`；再来 1024 B → `3072 / 2` |
| `testBlockedMoveDoesNotIncreaseUsage` | 被拦下 ⇒ 账仍为 `nil` |
| `testRestoreDecreasesUsage` | 恢复后 `0 / 0` |
| `testCapRollbackDecreasesUsage` | `t2` 超限回滚后 `0 / 0` |
| `testRestoreWithoutKnownUsageStaysUnknown` | 未知保持未知，不凭空造 0 |
| `testMissingCacheIsUnknownNotZero` | `trashUsage: nil` ⇒ 两个槽位均 `.unavailable` |
| `testKnownUsageIsProjectedToSlots` | 已知值原样投影，界面不做算术 |
| `testScanResultCarriesTrashUsage` | 快照带上；不给缓存 ⇒ `nil` |
| `testStateHeaderRoundTripPreservesTrashUsage` | codec 往返不丢 |
| `testOldHeaderWithoutTrashUsageDecodesAsNil` | 旧载体无该键 ⇒ `nil`，不判损坏 |
| `testUsagePersistsThroughStateFile` | 经现有 `state.residue` 落盘可读回 |
| `testStartupFirstProjectionUsesPersistedTrashUsage` | 载体带账 ⇒ 启动后**第一次**投影就是该值（复刻 `loadAndProject` 的 load → seed → rebuild 顺序） |
| `testStartupFirstProjectionWithOldCarrierIsUnknownNotZero` | 旧载体无该键 ⇒ 首次投影是「未知」，不是 0 |
| `testAppVersionResetClearsTrashUsageButDomainChangeKeepsIt` | 版本变更清账；判定域指纹变更保留账 |
| `testDeletedSummarySaysSpaceNotFreedYet` | 中英文摘要都点明「仍在回收站 / 尚未释放」 |

**单测总数**：合并 `origin/main`（`b5a1ac3`）后 **596**，本轮修启动路径再补 3 条 ⇒ **599**（`func test` 口径实测，`swift test` 0 failures；其中本单共新增 15 个）⇒ 已同步 `.github/workflows/ci.yml:5`、`.github/workflows/release.yml:211`、`README.md:196`、`README.en.md:192`、`ARCHITECTURE.md:34 / 122 / 136`、`CLAUDE.md:20`、`tests/contract/fixtures/doc_claims.json` 的 5 处 `declared`。

---

## 七、验收

| 命令 | 预期 | 实测 |
|---|---|---|
| `swift build` | 成功 | ✅ Build complete |
| `swift test` | 0 failures | ✅ **599 tests / 0 failures** |
| `python3 scripts/verify_codes.py` | 11 / 0 | ✅ |
| `./scripts/verify_a9.sh` | 80 / 0 | ✅ |
| `swift run --disable-sandbox ResidueApp --verify-wiring /tmp/wiring` | 117 / 0 | ✅ |
| `./tests/contract/check_all.sh` | 191 + 47 | ✅ |
| `python3 tests/contract/verify_r2.py` | 123 | ✅ |
| `python3 tests/contract/verify_counts.py` | 全部一致 | ✅ |
| `python3 tests/contract/verify_doc_claims.py` | 全部一致 | ✅ |

---

## 八、导航项数同步

基线 `docs/` 148 份；新增本单 ⇒ **149 份**。

| 文件 | 旧 | 新 |
|---|---|---|
| `CLAUDE.md:11` | 148 份 | 149 份 |
| `CLAUDE.md` §五 | 148 份 | 149 份 |
