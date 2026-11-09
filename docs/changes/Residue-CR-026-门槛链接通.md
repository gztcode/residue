# CR-026 · 门槛链接通（三处串联缺陷让产品退化成只读扫描器）

> **性质**：实现层 P0 缺陷修复
> **提出**：程必达（交付总监）
> **依据**：M3 / M4 / M5 / AC-08 / AC-09
> **发现路径**：接 `Preferences` 与 `executeBatch` 时顺手核 `persist()`，发现 `T: nil` 写死；顺着查又发现两处
> **PRD 影响**：**无**。不新增 AC、不改判定口径、不改字段定义。

---

## 一、三条缺陷串起来会锁死产品

单独看每条都像「小问题」，串起来是一条完整的失效链：

```
① SourceRule.name = "uv.cache"，Source.rawValue = "uv_cache"
        ↓ 两套标识、无映射
② candidates.filter { $0.source == source.rawValue }  → 恒为空
        ↓
③ slotCount = 0 → T = 0 / nil → H = min(30, T) 取不到
        ↓
④ AC-08 组 B 的 b ≥ 1 也不满足（b 又写错成了 pNowCount）
        ↓
   门槛永远不满足 → 自动删除永远点不亮
        ↓
   **产品退化成一个只读扫描器**
```

复必现 M-02 当时从「③ 页观察期 5/14 天」与「⑤ 页报告已产出」两页矛盾推断出「可能被实现成两次动作」。**他的推断方向对了一半**：真正的断点不在那两页，而在**门槛链的起点 `T` 上**。但结论（产品会退化成只读扫描器）完全正确。

---

## 二、逐条

### D-1 · `SourceRule.name` 与 `Source.rawValue` 是两套标识

| 位置 | 值 |
|---|---|
| `SourceRule(name: "uv.cache", …)` | `"uv.cache"`（点号） |
| `Source.uvCache.rawValue` | `"uv_cache"`（下划线） |

**中间没有任何映射**，于是 `Candidate.source`（由 `SourceRule.match` 产出）与 `Source.rawValue` **永远不相等**。

**症状是静默的**：不崩、不报错，只让「按来源过滤候选」的数量恒为 0。
实测：接线自检里 `slotCount = 0`，而 ② 页明明有 2 条候选。

**修法：只留一套标识。** `SourceRule` 改为携带 `Source` 枚举：

```swift
public struct SourceRule {
    public var source: Source          // 唯一标识
    public var pathFragments: [String]
    public var name: String { source.rawValue }   // 派生，不独立存
}
```

展示名走 `Source.displayName`（已有）。

> **为什么不保留两套 + 加映射**：那正是这个 bug 的成因。加一层映射等于留一个「以后还会忘同步」的后门。

### D-2 · `T` 恒为 `nil` 且永不更新（**最严重**）

原 `persist()`：

```swift
for (idx, source) in Source.allCases.enumerated() {
    if idx < contents.header.sources.count { continue }   // ← 写一次就再也不碰
    contents.header.sources.append(SourceHeaderEntry(
        source: source, snapshotTaken: true,
        T: nil, K: nil, J: nil, H: nil,                    // ← 恒 nil
        a: 0, b: lastScanDiagnostics.b, slotCount: 0, …
    ))
}
```

后果：**门槛链断在起点**。`H = min(30, T)` 永远取不到值。

**修法**：按 M3 真取快照——

| 规则（M3） | 实现 |
|---|---|
| `T` 的唯一来源 = 本轮首次成功 `full` 扫描 | `if !entry.snapshotTaken, lastScanMode == .full, slotCount > 0` |
| 取到后**冻结不再覆盖** | `if !entry.snapshotTaken` 才写；已取过一律不动 |
| `H = min(30, T)` | `entry.H = Swift.min(30, slotCount)` |
| 观测面每次更新（`b` / `slotCount` / 判定时刻） | 每次成功扫描都写 |
| `a` 不动（只增不减） | 不从扫描写 `a` |

### D-3 · `b`（L0 检查次数）被写成了 `pNowCount`（被持有数）

```swift
let a = countHeld(in: snapshot)   // 实际上这是 P_now
…
pNowCount: a,   // ✓ 位置对
a: 0,           // △ 恒 0（a 应取载体累计值）
b: a,           // ✗✗ b 变成了「被持有数」
```

`b` 是**门槛项**（AC-08 组 B 要求 `b ≥ 1`），口径是 M5：「计数对象 = 对某候选执行 L0 判定的一次」。

**后果比 D-2 更反直觉**：**「缓存满满但没有任何进程在用」是最理想的可清理场景，而它恰好 `countHeld = 0` → `b = 0` → 门槛永远不满足。**

也就是说：**缓存越干净（没人用），越点不亮。**

**修法**：

```swift
let pNowCount = countHeld(in: snapshot)     // 观测面
let checkedCount = countL0Checks()          // 门槛项：每条候选判一次
…
pNowCount: pNowCount,
a: accumulatedMisjudgment(for: nil),        // 从载体读，不写死 0
b: checkedCount,
```

`countL0Checks()` 在 L0 降级时**如实返回 0**（不假装检查过）。

---

## 三、机器证据（`--verify-wiring` 新增 5 项）

```
--- 4a. 门槛链是否接通（T / H / b 必须非 null）---
  ✓ T（快照总量）已取到（非 null）—— 门槛链的起点
  ✓ H = min(30, T) 已算出（非 null）
  ✓ b（L0 检查次数）≥ 1 —— AC-08 组 B 的门槛项
  ✓ slotCount 记录了该来源的候选数（实为 2）
  ✓ b == slotCount（每条候选判一次）；pNowCount 是另一个量，实为 0
```

**修前全部失败**（`T` 不存在、`slotCount = 0`）。这条断言的价值：**它验的是「门槛链通不通」，不是「代码跑不跑得起来」** —— 后者一直是通的。

---

## 四、为什么这三条能长期存在而没被发现

| 原因 | 说明 |
|---|---|
| **243 个单测全绿** | 测的是 `ScanEngine` / `Metrics` / `StateFile` 各自的契约，**没人测「AppModel 把它们的输出接对了没有」** |
| **七页渲染全绿** | 渲染的是 `PageModel.skeleton()` 样例数据（当时），与真实链路无关 |
| **不崩不报错** | 全部是「值悄悄变成 nil / 0 / 空集」，属静默缺陷 |
| **`T: nil` 有注释辩护** | 原注释写「其它保持 null 的语义 —— null ≠ 0」，读起来像**刻意设计**，而不像**未实现** |

> 最后一条最值得记：**一句听起来对的话，可以掩护一个没做的事。**
> `null ≠ 0` 这个原则本身是对的（M3 确实用它区分「未取快照」与「总量为零」），
> 但把它用在「本该取值却还没接线」的地方，就变成了「用一个正确的原则掩盖一个缺失的实现」。

---

## 五、影响面

| 对象 | 影响 |
|---|---|
| **PRD** | 无 |
| **R2** | `§5.4` 字段语义不变（`T` / `H` / `b` 的定义本来就写对了，错的是实现） |
| **`ScanEngine.SourceRule`** | 构造参数从 `name:` 改为 `source:`（**破坏性 API 变更**，但只在项目内使用，4 处调用点全改） |
| **测试** | `ScanEngineTests` 4 处期望值从 `"uv.cache"` 改为 `"uv_cache"`；新增断言「候选 source == Source.rawValue」 |
| **`verify_a9`** | 无新增（`T` 的断言在 `--verify-wiring`，因为需要真扫描） |
| **工时** | 0.25 人日（查 0.1 / 改 0.1 / 验证与留痕 0.05） |

## 六、遗留

| # | 遗留 | 说明 |
|---|---|---|
| 1 | `K` / `J`（样本量 / 失联量）仍为 `nil` | 它们只在**观察期结束扫描**时产出（M3），当前没有「结束扫描」的触发点 → 属 AC-09 的未实现部分，不是本单范围 |
| 2 | `doneCount` 仍硬编码 0 | 它需要位槽表（`slotTable`）的接线，属 M4 的载体写入，未实现 |
| 3 | `fSetBits` 仍硬编码 0 | 同 2 |

**这三项与 D-2 是同一类问题**（字段有定义、实现未接线），但它们的关闭依赖**观察期结束扫描**与**位槽表**两件更大的工作，不塞进本单。

---

**结论**：已落地。`swift test` 243 全绿，`verify_a9` 51/51，`verify_a5` 36/0/3，`verify_codes` 11/11，`--verify-wiring` **36/36**。
