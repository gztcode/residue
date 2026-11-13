# CR-031 · K/J 结算写入（P0 · 产品永远点不亮的最后一环）

> **缺陷**：`K`（样本量）在运行路径上**从未被赋过非 nil 值** → 门槛 `K ≥ H` 恒不成立
> → 自动删除**永远点不亮**，产品退化为只读扫描器
> **契约依据**：PRD v5.5 · 指标定义表 M3 / AC-09 / AC-08 组 B；R2 v1.8 §5.5
> **性质**：**功能缺失**（不是接线遗漏，也不是实现错误）
> **状态**：**待受理**（本文档为变更单，实现须在本单受理后开始）

---

## 一、缺陷事实（全部经代码与契约双向核对）

### 1.1 门槛链断在 `K`

`GateEvaluator.isQualified` 的三项门槛（PRD AC-08 组 B）：

```swift
guard let k = input.attributable, let t = input.total else { return false }
if k < Threshold.h(forTotal: t) { return false }
guard let a = input.missCount, a == 0 else { return false }
guard let b = input.checkCount, b >= 1 else { return false }
```

`input.attributable` 来自 `header.sources[i].K`（`PageModelBuilder.swift:218`）。
而 `K` 在整个 `Sources/` 下**只有一个赋值点**：

```swift
// AppModel.swift · persist()
SourceHeaderEntry(
    source: source,
    snapshotTaken: ...,
    T: ...,
    K: nil, J: nil,          // ← 恒为 nil
    ...
)
```

**结论**：`guard let k = input.attributable` 恒失败 → `isQualified` 恒 `false`
→ `a`、`b`、`T`、`H` 全都算对了也没有意义。

### 1.1b 附带发现：两处 `nil` 被当 `0`（违反不变量③）

`PageModelBuilder.swift:493` 与 `:524`：

```swift
.ratio(entry.K ?? 0, entry.T ?? 0)          // ③ 列
let k = entry.K ?? 0, t = entry.T ?? 0      // ⑦ 结论
```

两处都在 `produced == true` 分支内。若报告已产出而 `K` 仍为 `nil`
（旧载体、或结算写入中途失败），界面会显示「样本 0 / 总量 T」并把结论
判成「未达标」。

契约要求 `nil` 呈现为 `—`（`nil ≠ 0`：0 会被读成「一条都没归因成功」，
那是**另一件事**）。本单修 `K` 写入时**一并**把这两处改成 `.unavailable`。

### 1.2 结算报告从未产出

`settlement.producedAt` 被 `PageModelBuilder.swift:166` 读取（`settlementProduced`），
但 `SettlementHeader.producedAt` 在 `Sources/` 下**从未被写入过**。

`GateEvaluator` 两处都先判 `guard settlementProduced`，于是：

| 量 | 现状 | 后果 |
|---|---|---|
| `T` | 已正确赋值（首次 full 扫描） | 正常 |
| `H` | `min(30, T)`，已赋值 | 正常 |
| `a` | 有赋值路径 | 正常 |
| `b` | 有赋值路径 | 正常 |
| **`K`** | **恒 nil** | **门槛永不成立** |
| **`J`** | **恒 nil** | ⑤ 页 ③ 列三数不齐（`K + J = T` 不可验） |
| **`producedAt`** | **恒 nil** | 观察期永不「已满」 |

### 1.3 快照候选清单没有持久化（**这是本单的核心难点**）

契约 M3 对 `K` 的定义是**逐条归因的结果**：

> `K` = 该快照内**仍可归因**（未被排除）的条目数
> **`K` 只能由「快照条目逐条归因结果」直接得出，`J` 由 `T − K` 派生**

要逐条归因，必须先有「快照里到底有哪几条」。而载体里的 `SourcePayload` 是：

```swift
public struct SourcePayload {
    public var bitmap: Data              // F 位图（按位槽）
    public var countedDoneSlots: [UInt32] // C_done（槽号）
    public var slots: [UInt32: CandidateID] // 位槽占用表：槽号 → 身份键
}
```

`slots` **看起来**像快照清单，但两者语义不同：

| | `slots`（位槽占用表） | 契约要求的「快照清单」 |
|---|---|---|
| 增长时机 | **每次** L0 判定阴性时分配 | **本轮首次成功扫描**时一次性确定 |
| 是否回收 | 永不回收（含已手删的） | 固定为快照那一刻的集合 |
| 跨版本 | 随 `a` 清零 | 随 `K` 清零 |
| 用途 | `F` 位图的下标 | `K` 的分母 |

**不能拿 `slots` 冒充快照清单**：它含历史上出现过、但快照时刻并不存在的候选
（用户早先删掉的、上一轮遗留的），会**系统性放大 `T`** → `H = min(30, T)` 偏大
→ 门槛偏严；同时让「失联」把从未进过快照的条目也算进去 → `J` 虚高。

---

## 二、契约对归因的规定（逐条摘录，作为实现验收依据）

### 2.1 `K` 的算法（M3 · 唯一式）

- **`K + J = T`** 是恒等式；`J = T − K` 是**派生量**
- **禁止**任何第二套算法：不得 `K = T − J` 与独立算 `K` 并存
- **禁止** `K = T − J − 重建数`
- **不得由 `J` 反推 `K`**（否则恒等式循环恒真、不可证伪）

### 2.2 失联四类（M3 · 只作标签，不参与计数）

| 类别 | 判定 | 是否改变 `J` |
|---|---|---|
| 改名 | 同 inode / birthtime 出现在新路径 | 否（只打标签） |
| 用户手删 | 路径不存在且无同名重建 | 否 |
| 目录拆分合并 | 父目录结构变化导致路径失效 | 否 |
| 无法归因 | 以上都不匹配 | 否（兜底） |

**关键**：「四类只作归因标签、不参与计数、不改变 `J`」——
`J` 只由 `T − K` 派生，标签只用于报告说明。

### 2.3 身份键 = `path + birthtime`

- 路径相同 + birthtime 变化 = **同名重建**：旧条目留在本轮（计入 `J`），
  新条目**转入下一轮快照**，不计入本轮样本
- 「用户手删」的条目已不存在，**下一轮不会进入新快照**——不得声称「失联条目下一轮重新计入」

### 2.4 结算时刻（M1 / M3）

- **`T`**：本轮首次成功 `full` 扫描完成时刻（已有实现，正确）
- **`K`**：观察期结束扫描时写入（冻结值）
- **观察期已满** ⟺ 第 14 个计数日结束后的**第一次成功扫描**已完成
  **且该次扫描同时产出了 AC-09 报告**
- **计数日封顶 14**（`15/14` 永不出现）

### 2.5 `pipx` 行例外

`pipx` run 属**非判定域**，**不取快照** → 该行 `J` 无非零来源
→ **不套用 `K + J = T`**（否则该断言对该行恒真、无判别力）。

---

## 三、拟改范围

### 3.1 新增：快照清单（Core）

在 `SourcePayload` 增加**第 4 项**（与 `bitmap` / `countedDoneSlots` / `slots` 并列）：

```swift
/// 本轮快照的候选清单（`T` 的成员，逐条归因的对象）。
///
/// **只在「本轮首次成功 full 扫描」时写入一次**，此后冻结。
/// 与 `slots` 的区别见 CR-031 §1.3 —— 不能互相顶替。
public var snapshotMembers: [CandidateID]
```

- 载体 schema 版本 **1 → 2**（新增字段，旧载体走既有 `E-301` 只读降级路径
  还是就地升级，需在受理时裁决 —— 见 §五 待决项）
- 规模：300 万候选 × ~100 B ≈ 300 MB 量级。**这与契约「载体约 1 MB 量级」
  （M4 · 载体规模口径）冲突** —— 见 §五 待决项 ①

### 3.2 新增：归因判定（Core，纯函数，可单测）

```swift
public enum Settlement {
    public struct Attribution: Sendable {
        public var candidate: CandidateID
        public var status: Status       // .attributable / .lost(Label)
    }
    public enum Label: String, Sendable {
        case renamed, userDeleted, directoryRestructured, unattributable
    }

    /// 逐条归因。`K` 由结果直接得出，`J = T − K` 派生。
    public static func attribute(
        snapshot: [CandidateID],
        current: [CandidateID],
        fileSystem: ...
    ) -> [Attribution]
}
```

**判据（必须按契约，不得自创）**：

| 情形 | 归因结果 |
|---|---|
| 身份键（path + birthtime）在 `current` 中 | `.attributable` |
| 路径不存在、同目录无同名重建 | `.lost(.userDeleted)` |
| 同 inode/birthtime 出现在新路径 | `.lost(.renamed)` |
| 父目录结构变化 | `.lost(.directoryRestructured)` |
| 其它 | `.lost(.unattributable)` |

### 3.3 新增：结算写入（AppModel）

在「观察期结束扫描」这一时刻：

1. 逐条归因 → `K`
2. `J = T − K`（派生，不独立算）
3. 写 `entry.K` / `entry.J`
4. 写 `settlement.producedAt` / `reportId`
5. 落盘

**触发条件**（M1）：`countedDays == 14` 且本次扫描成功 → 这次就是结算扫描。

### 3.4 接线自检 + 单测

- 单测：归因四类各一例、`K + J = T` 恒等、同名重建不计入本轮、
  `pipx` 行不套恒等式
- 接线自检：真文件系统造快照 → 删几条 → 结算 → 断言 `K`/`J` 与预期一致

---

## 四、不做的事（明确边界）

| 项 | 为什么不做 |
|---|---|
| L2 误判分子/分母（AC-09 的「又被重新用到」） | 那是**披露项**，不构成门槛。本单只解决门槛链 |
| `a` 的判据修正 | `a` 已有实现，本单不动 |
| 结算报告的 UI 呈现 | 已有（第 ⑤ 页矩阵），本单只补数据 |
| 快照的增量更新 | 契约要求「冻结」，不做增量 |

---

## 五、待决项（**受理时必须裁决，否则不许开工**）

### ① 快照清单的存储规模与契约冲突

契约 M4 说载体规模「**约 1 MB 量级**」（`F` 位图 375 KB + `C_done` + 位槽表）。
但完整快照清单 300 万候选 × 约 100 B ≈ **300 MB** —— 是契约规模的 300 倍。

三个选项：

| 选项 | 做法 | 代价 |
|---|---|---|
| **A** | 快照清单独立落 `state/snapshot-<round>.json`（不进载体） | 新增一个落盘物，需登记 N7 清除范围 |
| **B** | 复用位槽表 + 一个「快照轮次戳」，只记快照那一刻已分配的槽号 | 需证明位槽单调性足以还原快照集合（**可能不成立**：槽号不回收，无法区分「快照时已存在」与「快照后才分配」） |
| **C** | 接受载体变大，修订 M4 的规模口径 | 需要改契约（M4 的「约 1 MB」是评审过的口径） |

**我的建议：A**。理由：契约的「约 1 MB」是在**没有快照清单**的前提下算的；
新增快照清单是**新增需求**，理应新增落盘物，而不是把原有口径撑破。
但 A 需要出第二张变更单改 N7 清除范围（`state/snapshot-*.json` 含候选路径）。

### ② 旧载体的迁移

schema 1 → 2。旧载体没有 `snapshotMembers`：

- 若走 `E-301` 只读降级 → 老用户升级后**整个观察期作废**（`T` 也没了）
- 若就地升级 → 首次扫描重新取快照（`T` 重置），观察期从头开始

两者都让老用户重来。**需要裁决**：是否接受「升级即重置观察期」。
（注：这与「应用版本变更重置观察期」的既有规则一致，可能是可接受的。）

### ③ 归因需要读文件系统，与「不把未知判为安全」

归因要 `lstat` 每个快照候选。若 `lstat` 失败（权限、跨 uid）：

- 判 `.attributable` → **把未知判为安全**（违反不变量③）
- 判 `.lost` → `K` 偏小 → 门槛偏严（保守，但可能让用户永远点不亮）

**我的建议：判 `.lost(.unattributable)` 并在报告里如实标注**。
保守方向正确（宁可点不亮，不可误判可删），但要在 UI 上说清「有 N 条无法归因」。

---

## 六、验收判据（本单完成的定义）

| # | 判据 | 验证方式 |
|---|---|---|
| 1 | `K` 在结算扫描后非 nil | 单测 + 接线自检 |
| 2 | `K + J = T` 恒成立 | 单测（含边界：全失联 / 零失联） |
| 3 | 同名重建（path 同、birthtime 变）计入 `J` 不计入 `K` | 单测（真文件系统） |
| 4 | 用户手删不计入 `a`，计入 `J` | 单测 |
| 5 | `pipx` 行不套 `K + J = T` | 单测 |
| 6 | 结算后 `settlement.producedAt` 非 nil | 接线自检 |
| 7 | 结算后门槛可成立（构造 `K ≥ H` ∧ `a = 0` ∧ `b ≥ 1`） | 单测 |
| 8 | 旧载体升级不崩溃、不静默丢数据 | 单测 |

---

## 七、为什么这张单必须先受理

不改契约就实现，会撞上 §五 的三个待决项，其中 ①（300 MB vs 1 MB）
是**契约内部的直接冲突**。按本仓库的规矩（CLAUDE.md §五）：

> 代码与文档对不上就是缺陷，不是「文档过时了」。
> 改契约需要变更单。

实现这一项必然要动 M4 的载体规模口径或新增落盘物 —— 两者都在契约层面，
**不能在实现层私了**。
