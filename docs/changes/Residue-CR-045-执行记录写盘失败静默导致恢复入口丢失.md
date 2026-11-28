# CR-045 · 执行记录写盘失败静默导致恢复入口丢失 · P0 · 举证链可靠性

> 状态：已实施
> 变更类型：**修产品代码**（Core 落盘原语 + App 接线）+ **加契约条文**（N7 清除范围、执行日志落盘口径）+ 导航项数同步
> 影响面：`ResidueCore/ExecutionRecordStore.swift`（新增）、`ResidueCore/JSONLStore.swift`（新增）、`ResidueCore/RecordWriter.swift`、`ResidueCore/StateFile.swift`、`ResidueCore/N7ClearScope.swift`、`ResidueCore/PageModel.swift`、`ResidueApp/AppModel.swift`、`ResidueApp/RootView.swift`、`ResidueApp/Components.swift`
> 风险等级：**P0** —— 触及 AC-13「14 日内可一键恢复」这条对外承诺的**唯一依据**。原实现在写盘失败时**静默丢弃恢复位置**，用户被告知「已清理 N 条」而那几条**永远恢复不了**

---

## 一、缺陷

`ResidueApp/Sources/ResidueApp/AppModel.swift`（基线 `0e2e096` 第 1262–1265 行）：

```swift
// 写 `execution.jsonl`（AC-18 举证链的数据源）
for rec in newRecords {
    try? writer.append(rec, kind: .execution, now: now)
}
executions.append(contentsOf: newRecords)
```

`try?` 把写盘失败整个吞掉 —— 没有 `errorMessage`、没有日志、没有任何痕迹。

## 二、根因（缺陷组 P-018 + P-031 同一根因）

1. **删除动作已经发生**：`TrashExecutor.moveToTrash` 在**返回前**就 `moveItem`（`ResidueCore/TrashExecutor.swift:172`）—— 文件**真的**进了废纸篓。
2. **恢复路径只有这一条记录能提供**：`restorePath` 由 `TrashExecutor` 在 rename 时算出（`TrashExecutor.swift:189`），而恢复入口是 `guard let restorePath else throw RestoreError.noRestorePath`（`TrashExecutor.swift:320`）。
3. ⇒ **执行记录写不下去 = 恢复入口永久消失**，而界面在 `AppModel.swift:1277-1289` 仍按**内存里**的 `newRecords` 报「已清理 N 条」—— **用户被告知一切正常，恢复入口却没了**。
4. **同一个类里两条写盘路径口径不一致**：`scan.jsonl` 写失败是**显式处理**的（`AppModel.swift:856-862` 设 `errorMessage`），`execution.jsonl` 写失败却是 `try?`。

⇒ 这不是「日志少一行」的小事：**AC-13 对外承诺「14 日内可一键恢复」，而这条承诺对写盘失败的那几条当场落空，且用户毫无感知**（LC-22 记为链路级安全检查项）。

## 三、修法

### 3.1 落盘责任方下沉到 Core（可测原语）

新增 `ResidueCore/ExecutionRecordStore.swift` —— **App 层不再有 testTarget**（`Package.swift` 只有 `ResidueCoreTests`），判定与落盘逻辑必须落在 Core 才测得到（仓库惯例：「同一判定只有一个实现处」）。

落盘结果**分三档**，逐档可区分：

| 档 | 含义 | 恢复入口 |
|---|---|---|
| `persisted` | 已写进 `records/execution.jsonl` | 可用 |
| `queued` | 写不进 `execution.jsonl`，但写进了 `state/pending-execution.jsonl` 待补写队列 | **信息还在**，下次启动补写 |
| `lost` | 连队列都写不进去 | **没了** —— 必须如实登记并单独提示 |

`AppModel` 只做接线：执行完调 `executionStore.persist(newRecords)`，把三档分别喂给 `PageModel.ExecutionNotice` 与 `errorMessage`。

### 3.2 界面口径（不许撒谎）

- **「已清理 N 条」只统计 `persisted`** —— 记录没落盘的条目，**恢复入口还不存在**，混进去等于告诉用户「一切正常」。
- `queued` / `lost` **各自单独成句**（Core 拼文案，界面不做算术）。
- `didNothing` 改为 `deletedCount + unloggedCount + lostCount == 0` —— **文件已经进了废纸篓**，说「本次没有删除任何条目」就是撒谎。

### 3.3 待补写队列（保住恢复信息）

- 落 `state/pending-execution.jsonl`，**下次启动补写**进 `execution.jsonl`。
- **补写幂等**：按「候选 + 动作 + 动作时刻」三元组比对 `execution.jsonl` 现有记录，已补过的不重复补。
- `execution.jsonl` **读不出来**时**不补写**（无从判断是否已补过）⇒ 宁可留在队列里，也不重复补污染 M6 计量；此时**如实报错**并保留队列。

### 3.4 错误可诊断

`errorMessage` + **`E-303`**（码表里**唯一**的写盘失败码）。**不新增错误码** —— 加码要连带改 R2 §6 码表 + `verify_codes.py` + 契约文档，收益不抵成本；`E-303` 的 summary 是「磁盘空间不足」，所以 detail 里**必须带上真实成因**（权限 / IO / 空间），不许让用户照着错误方向排查。

## 四、设计取舍

### 4.1 待补写队列落 `state/` 而不是 `records/`

| 落点 | `records/` | `state/` ✅ |
|---|---|---|
| M6「可回收字节」 | **计入** —— 把**还没写出去的恢复信息**算成垃圾是错的 | 不计入 ✅ |
| N7「一键清除」 | 在范围内（含路径副本） | 也在范围内（**必须加进去**）✅ |
| 语义 | 举证链的一部分 | 运行期态（与 `journal.jsonl` / `checkpoints.json` 同级）✅ |

⇒ 落 `state/`；**同时**把 `state/pending-execution.jsonl` 与它的 `.tmp` 补进 N7 清除范围（`N7ClearScope.paths`）—— 它含候选路径与恢复位置，**漏清即等于「清除后仍留用户路径副本」**（质量 B-07）。

### 4.2 为什么抽出 `JSONLStore`

`execution.jsonl` 与待补写队列**必须同格式** —— 否则补写时解不开 ⇒ 恢复信息等于丢了，而且**无报错**。抽 `JSONLStore` 统一编解码与落盘机制（`append` / `replaceAll` / `readAll`），`RecordWriter.append` 改为委托它。**队列行的编解码只有一处实现**。

### 4.3 为什么补写走「临时文件 → `rename(2)`」

重写队列文件（补写成功后清空剩余项）不能原地截断 —— 断电会留下半个队列文件，**恢复信息再次丢失**。故用同目录临时文件 + `fsync` + `rename(2)` 原子替换（与 `CheckpointStore` 的原子写惯例一致）。

### 4.4 为什么不直接重试写 `execution.jsonl`

同一个故障（磁盘满 / 目录只读）下**重试必然再失败**，而重试会拖住执行批次。所以「重试」放在**下一次启动**（故障多半已消失），而不是在同一次执行里空转。

## 五、测试证据

新增 `Tests/ResidueCoreTests/ExecutionRecordStoreTests.swift`（11 例）+ `ExecutionNoticeTests` 扩展（4 例）+ `N7ClearScopeTests` 扩展（1 例）。

**RED 验证**（把 `persist` 临时退回旧的 `try?` 行为后跑）：

```
Executed 11 tests, with 19 failures (0 unexpected) in 0.162 seconds
```

失败的正是**故障路径**：写盘失败未被发现、队列里没有 `restorePath`、丢失档没登记、补写不回、日志读不出来时队列被清空。**成功路径用例在旧实现下依然通过** ⇒ 行为未变。

**GREEN**：

```
swift test  →  Executed 615 tests, with 0 failures (0 unexpected) in 4.268 seconds
./scripts/verify_a9.sh  →  通过 80 项 / 失败 0 项
```

覆盖的断言（摘）：

- 写盘失败 ⇒ `persistedCount = 0` / `queuedCount = 1`，队列里那条**带 `restorePath`**（「恢复路径不能丢」）；
- 队列也写不进去 ⇒ `lostCount = 1`，**如实登记**；
- 补写后 `execution.jsonl` 里那条**带回 `restorePath`**，队列清空；
- 补写**幂等**（第二次 `recoveredCount = 0`，日志仍 1 行）；
- `execution.jsonl` 读不出来 ⇒ `failure = .logUnreadable`、**队列不丢**；
- 待补写队列落 `state/` ⇒ **不计入** `writer.totalJSONLBytes()`（M6 计量不受影响）；
- N7 清除范围含 `state/pending-execution.jsonl` 与其 `.tmp`。

## 六、契约同步

| 文件 | 改动 |
|---|---|
| `docs/contract/Residue-PRD-v5.6.md` | N7：清除范围增 `pending-execution.jsonl`；增执行日志写盘失败的三档口径 |
| `docs/contract/Residue-R2-技术方案-v1.10.md` | §5.3 增「写入失败分三档」；§10.3 清除范围增 `state/pending-execution.jsonl` |
| `docs/contract/Residue-R2-安全合规检查表-v1.0.md` | S-10 清除范围增该文件 |
| `docs/contract/Residue-安全验证移交清单-v1.0.md` | S-21 逐项检查清单增该文件 |
| `docs/contract/Residue-链路用例-v1.0.md` | 新增 **LC-22**（执行记录写盘失败 · 恢复入口不许消失）；用例数 21 → 22 |

## 七、影响面与风险

| 项 | 评估 |
|---|---|
| 删除动作本身 | **未改** —— `TrashExecutor` 一行未动（仍是纯 `moveItem`，全文无 `rm` / `unlink`） |
| 判定 / 门槛 / `T` / `K` / `J` / `Source` 枚举 | **未改** —— 本变更不碰任何判定 |
| 成功路径 | 行为**不变**（RED 验证里成功路径用例在旧实现下同样通过） |
| 新增落盘文件 | `state/pending-execution.jsonl` —— **只在写盘失败时**才出现；正常路径不产生 |
| M6 计量 | **不受影响**（队列落 `state/`，不计入 `records/*.jsonl` 字节） |
| N7 清除范围 | **扩大一项**（+ 该文件与其 `.tmp`）—— 含用户路径副本，本就该清 |
| 新增错误码 | **无**（沿用 `E-303`）⇒ R2 §6 码表、`verify_codes.py` 不动 |
| 界面 | 新增两档文案与一条补写提示横幅；`ExecutionNoticeCard` 的配色条件扩展（记录没落盘时用次级色，不谎报成功） |

## 八、未解决 / 后续

1. **补写只在启动时发生**（下一次启动）。同一次运行内若磁盘仍满，补写不成功 ⇒ **如实报错并保留队列**（用户看得见「下次启动会再试」）。
2. **彻底丢失档无法补救** —— 只能提示用户自行到废纸篓取回。本产品**不保留**用户路径以外的副本，故无二次恢复手段。
3. `execution.jsonl` 读不出来时**不补写**（保守取舍，见 §3.3），代价是这批记录要等到日志能读了才补上。
