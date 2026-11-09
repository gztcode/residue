# CR-029 · 容量上限对目录型候选不成立（P0）

> **影响面**：AC-15「实际删除量不超过上限」——**用户最主要的安全保证**
> **触发条件**：候选里有**目录**（生产环境的常态）
> **后果**：一次执行可删掉上限 **1.3 倍以上**的体积，且**不报错、不留痕异常**
> **性质**：**按字面实现会静默产出错误数据**（本项目已第 4 次出现此类）
> **状态**：已修 + 三层防线已证伪

---

## 一、缺陷

### D-6 · 预检与记账用了两个不同的字节口径（P0）

`TrashExecutor.execute()` 判「这条删不删」时用的是：

```swift
let size = (try? fileManager.attributesOfItem(atPath: id.path))
    .flatMap { ($0[.size] as? NSNumber)?.int64Value } ?? 0
```

而 `moveToTrash()` **记进执行日志**的是：

```swift
(isDir ? (try recursiveLogicalBytes(atPath: id.path), .dirRecursive)
       : ((attrs[.size] as? NSNumber)?.int64Value ?? 0, .file))
```

**预检看的是目录自身 `st_size`（APFS 约 96 B），记账看的是子树内全部普通文件之和。**

### 实测复现（2026-11-09）

两个各含 100 KB 的目录候选，容量上限 150 KB：

```
dir1: 预检值 = 96 B, 递归逻辑字节 = 102400 B   （差 102304 B）
dir2: 预检值 = 96 B, 递归逻辑字节 = 102400 B   （差 102304 B）

模拟 execute(capacityCap: 150 KB):
  dir1: 删除，记录 bytes = 102400 B，累计 = 102400 B
  dir2: 删除，记录 bytes = 102400 B，累计 = 204800 B

结果: 删除 2 个, 顺延 0 个, deletedBytes = 204800 B
上限 = 153600 B
→ ❌ 实际删除量超过上限（超 33%）
```

**预检每次都看到 96 B，于是两个候选都「不超限」，全被删掉。**

### 为什么这直接违反契约

AC-15（PRD v5.5）原文：

> Then **实际删除量不超过**「首次 5 GB 与来源 10% 取小」、稳定后不超过来源 20%、条目数不超过条目数上限，超出部分顺延并留痕

并且 CR-022 偏差 2 已经把「字节」的定义与时点都定死了：

> - **目录** = 该目录下全部普通文件（递归）的 `st_size` 之和；**目录自身的 `st_size` 不计入**（APFS 目录 inode 本身仅 ~96 B，若直接计入将使上限判定**恒真**、本 AC 形同虚设）；
> - **预检取值与实测取值的时点**：「实际删除量」的**预检值** = 删除动作前对候选集按上述定义计算的逻辑字节（随候选缓存到执行点），**不是执行时刻的实时重算值**——否则「预检通过 → 删除发生 → 实测超限」的路径不可达，本 AC 判据失去判别力。

**契约早就把「目录自身 `st_size` 不计入」写清楚了**——而且明说那样做会让上限判定「恒真」。实现恰好在预检这一步用了那个被明文禁止的口径。

### 为什么「目录自身 `st_size` 不计入」这条已经出现在代码里，却仍然有洞

因为**它只出现在记账那一条路径上**（`moveToTrash` → `recursiveLogicalBytes`）。预检那一条路径绕开了它，直接读 `attributesOfItem[.size]`。

**同一个概念的两个口径分别写在两个地方 → 必然分叉。** 这与本项目此前反复出现的根因完全一致（`SourceRule.name` vs `Source.rawValue`、`T` 恒 nil、`b` 与 `pNowCount` 混用）。

---

### D-7 · 稳定后那一档漏掉了「用户自己配置的上限」

`AppModel.executeBatch()` 原实现：

```swift
if isFirstRun {
    cap = Swift.min(preferences.capacityCapBytes,
                     Int64(Double(total) * 0.10))
} else {
    cap = Int64(Double(total) * 0.20)      // ← 用户配置的上限被丢了
}
```

后果：用户把上限调到 1 GB 之后，**第一次执行按 1 GB 走（对），第二次执行跳回 20%（错）**。用户的设置**静默失效**。

AC-15 的措辞是「**不超过**来源 20%」——「不超过」是**上界**，不是目标值。用户自己设的上限同样是一个上界，两条上界取小才是对的。

> **顺带修**：原「首次」那一支也没有把 AC-15 明写的 **5 GB 绝对上限**算进去（只有用户上限与 10% 比例档）。现已补上。

---

## 二、修法

### 1. 预检与记账共用一个函数（口径统一）

`TrashExecutor.logicalBytes(of:)` 成为**唯一**的字节口径入口：

- 普通文件 / 符号链接 → 自身 `st_size`
- 目录 → `recursiveLogicalBytesResult`（子树内普通文件之和，目录自身不计）

`execute()` 的预检与 `moveToTrash()` 的记账**都走它**，不再各写各的。

### 2. 支持「预检值随候选缓存到执行点」

契约要求预检值是**随候选缓存**的，不是执行时刻实时重算的（理由见上：否则「预检通过 → 实测超限」路径不可达，判据失去判别力）。

故 `execute()` 新增 `preflightBytes: [CandidateID: Int64]?` 参数：

- 传了就用（调用方在扫描时算好）
- 没传则现算一次（**仍然同口径**）

**两条路径都被测试覆盖**（见下）。

### 3. 上限判定抽到 Core 的唯一实现处

新增 `TrashExecutor.capacityCap(userCapBytes:absoluteCapBytes:sourceTotalBytes:tier:)`：

| 档 | 上界 |
|---|---|
| 首次 | `min(用户上限, 5 GB, T×10%)` |
| 稳定后 | `min(用户上限, T×20%)` |

`AppModel` 改为**调用它**，不再自己做域内算术。

> 抽到 Core 的原因：这个判定原先在 `AppModel`（App target）里，**无法被单测约束**——而它决定「这次最多删多少字节」。

---

## 三、防再犯（三层防线，均已证伪）

### 第 1 层 · 单测（`TrashExecutorTests`，+10 条）

| 用例 | 守住什么 |
|---|---|
| `testCapacityCapHoldsForDirectoryCandidates` | 目录型候选的实际删除量 ≤ 上限，**且**有一个被顺延 |
| `testRecomputedPreflightUsesLogicalBytesNotDirectoryStatSize` | **不传预检值**的路径也必须同口径（生产路径就是这条） |
| `testPreflightBytesAreUsedForCapDecision` | 传入的预检值被真正使用 |
| `testPreflightValueDecidesNotRecomputedValue` | 预检值超上限时不得删除（契约：预检值决定，不得实时重算） |
| `testCapacityCapBoundaryIsInclusive` | 上限恰好等于累计值时**放行**（含等于，不是小于） |
| `testCountCapAppliesIndependentlyOfCapacityCap` | 条目数上限与容量上限是两条独立约束 |
| `testSteadyTierStillHonorsUserConfiguredCap` | **D-7 直接对应的守护** |
| `testFirstRunTierTakesMinOfThreeBounds` | 首次档三条上界取最小（每个分支各造样本） |
| `testCapacityCapIsNeverNegative` | 上限不为负 |
| `testSteadyRatioIsWiderThanFirstRun` | 两档比例不能反（10% vs 20%） |

### 第 2 层 · 接线自检（`WiringSelfCheck` 新增 §4d）

**`executeBatch` 此前一次都没被自检走过** —— 而它是唯一会把用户文件 rename 进废纸篓的路径。

新增 §4d 用**真目录 + 真文件**走一遍完整判定，验：
- 实际删除量 ≤ 上限
- 第二个候选被顺延
- 被顺延的仍在原位
- 稳定后档仍受用户上限约束

### 第 3 层 · 静态断言（`verify_a9` 新增第十二节，5 项）

- App 层**不得**出现容量比例算术（域内算术只允许在 Core）
- 上限判定的唯一实现处必须在 Core
- 预检与记账**必须**共用 `logicalBytes(of:)`
- `execute` **必须**接受预检值
- 接线自检**必须**走过执行路径

### 证伪记录（注入缺陷 → 三层各自报红）

| 注入的缺陷 | 单测 | 接线自检 | 静态断言 |
|---|---|---|---|
| 预检改回目录自身 `st_size` | ✅ 红 2 条 | ✅ 红 3 条 | — |
| App 层自己做比例算术 | — | — | ✅ 红 1 条 |
| 自检不覆盖执行路径 | — | ✅ 红 | ✅ 红 |

**三层都能独立抓到同一缺陷**，不是靠单点。

---

## 四、暴露出的方法论问题（比缺陷本身更值得记）

### 「用替身写用例会系统性屏蔽真实行为」——又一次

`TrashExecutorTests` 原有 10 条用例里，**造候选全用 `makeFile`（普通文件）**，目录型候选**一次都没走过**。

于是「口径不一致」这个缺陷完全隐身：普通文件的 `st_size` 与逻辑字节**恰好相等**，两个口径没有差别。

> 这与 `recursiveLogicalBytes` 那次（`enumerator(at:)` 的元素是 `URL` 不是 `String` → 目录字节恒 0）**是同一个病**：
> **测试样本没覆盖真实形态 → 真实形态上的缺陷看不见。**
>
> 那次补的用例里已经写了这句话，本轮它应验。

### 判据设计上的一个细节

`testCapacityCapHoldsForDirectoryCandidates` 我**没有**只写「断言 `deletedBytes ≤ cap`」——因为那样在「一个都不删」时也会通过（假绿）。

所以加了**反向锚**：`skippedByCap == 1` + 「被顺延的仍在原位」。两条合起来才能证明「限额真的在起作用」而不是「恰好没删多少」。

这与 CR-027 的 fd 那条、CR-028 的 cwd 那条是同一个判据：

> **把实现改错，这条断言会红吗？**
> 不会红的断言不构成防线。

### 顺带修的两处「我自己的错误」

- `testFirstRunTierTakesMinOfThreeBounds` 初版期望写错（我以为 10 GB < 5 GB）——**是我的算术错，不是代码错**。已改为每个分支各造一个样本，让每个分支都真正被走到。
- 证伪过程中注入的代码破坏了 `WiringSelfCheck.swift` 的编译（注释掉一行导致 `consecutive statements` 语法错）→ 第一次证伪「单测没报红」其实是**构建失败**，不是断言没抓到。**这正是「静默失败」的一种形态：看起来没报红，其实是没跑。**

---

## 五、影响与发布

| 项 | 处置 |
|---|---|
| 已发布版本 | **v0.1.0 / v0.1.1 均含 D-6 与 D-7** |
| 处置 | 发 **v0.1.2** |
| v0.1.1 的处置 | **保留不删**（不隐藏历史），但**必须加风险警告**（同 v0.1.0 的处置） |
| 触发条件说明 | 需要**候选里有目录**。`uv` / `npm-npx` 的缓存通常以**目录**为单位（`~/.cache/uv/archive-v0/<hash>/`）→ **生产环境的常态**，不是边缘场景 |

---

## 六、遗留（诚实登记）

1. **`preflightBytes` 尚未接线到生产路径**。`AppModel.executeBatch` 目前**不传**预检值，走「现算」分支——**已修且同口径**，但契约要求的「随候选缓存到执行点」尚未实现。接线后需把扫描期算好的值传进来。**已登记为上线前必做项**（不是可选优化）。
2. **预检值与执行时点之间的 TOCTOU**：契约刻意要求这个窗口存在（「预检通过 → 删除发生 → 实测超限」路径可达），因此**删掉的体积可能略大于预检时的估算**——但**不超过上限**这条依然成立（预检值就是判定依据）。这是契约的有意设计，不是缺陷。
3. **回收站容量**：`recursiveLogicalBytes` 会把**已存在于回收站**的候选也算进 `T`。这会让 `T` 偏大、比例档偏松。**已登记，未修**（需要 `TrashExecutor` 与 `ScanEngine` 之间的缓存协作，属架构层）。
