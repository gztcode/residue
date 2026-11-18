# CR-033 · 轮次自动推进（未达标自动开下一轮）· P0 · 观察期未达标后永远停在第 1 轮

> **缺陷**：M1 规定「轮次 = 观察期窗口序号（首轮 = 1），**唯一递增事件 = 「未达标自动开下一轮」**」，
> 但全仓库**没有任何一处会递增 `round`** —— `ObservationProgress.advanceCountedDay` 只改
> `startAnchor` 与 `countedDays`，唯一带 `round += 1` 的 `beginNextRound()` 只存在于
> **未投产**的 `StateStore.swift:84`
> ⇒ 观察期满、结算完成、**未达标**时，产品永远停在第 1 轮
> ⇒ 用户**没有任何出口**可以「再观察 14 天重新达标」
> ⇒ R6 要求的三处可见结果（③ 页括注 / ⑤ 页页级轮次 / ⑤ 页「上一轮」四要素行）全部缺失
> **契约依据**：PRD v5.6 :62〔CR-010 · R4〕/ :63 / :65 / :68〔CR-010 · R6 · G-3〕/ :69 / :70 / :71〔R7〕/
> :107 / :110 / :113；DAC v2.0 :176 DAC-50（修订）/ :61 AC-09；B1 v1.0 TC-045 / TC-046 / TC-054；
> 视觉基线 v1.1 §五 :126 / :128 / :133 / :134；R2 v1.9 §5.1 / :245 / :692 / §26.3 / §26.5
> **性质**：**功能缺失**（契约侧已写对，代码从未实现 —— 与 CR-032 的「实现错误」不同类）
> **状态**：**待实现**（变更单先行；代码落地须按 §八 TDD 步骤）
>
> **修订记录**：
> - **v1 · 2026-11-17**：初稿。逐条核实 PRD v5.6 / DAC v2.0 / B1 v1.0 / 视觉基线 v1.1 / R2 v1.9
>   的契约原文与代码落点行号；列出 §九 待裁决 6 条（**均给出建议方案**，不阻塞起草）。

---

## 一、缺陷

### 1.1 现象

用户装好 Residue，扫满 14 天观察期，报告产出，但**样本不足**（`K < H`，例如缓存被清理得太狠、
或者扫描窗口内候选数量本来就少）：

- ③ 页把该来源列为未达项「样本不足」；
- ⑤ 页结论列写「未达标」；
- 自动删除开关**保持 disabled**（不变量④：没证明自己判得准就不动手 —— 这部分**是对的**）；
- 然后**什么也不会再发生**：观察期天数停在 14/14，剩余天数显示 `—`，报告不再产出，
  轮次永远是第 1 轮。

用户诉求是「再给我 14 天，这次我多攒点缓存再说」—— **产品没有这个出口**。
PRD v5.6 :65 把这条明确写成待修项：**「② 未达标自动开下一轮（修 A7-4 的『无出口』）」**。

### 1.2 复现路径（代码级）

`ResidueCore/Metrics.swift` 的 `ObservationProgress`（:72–128）：

```swift
public var round: Int          // :75  —— 注释写明「唯一递增事件 = 未达标自动开下一轮」
...
public mutating func advanceCountedDay(on day: Date, calendar: Calendar = .current) {
    if let anchor = startAnchor {
        guard !calendar.isDate(anchor, inSameDayAs: day) else { return }
        countedDays = Swift.min(countedDays + 1, ObservationProgress.requiredDays)
        startAnchor = day
    } else {
        startAnchor = day
        countedDays = Swift.max(countedDays, 1)
    }
}                                // :116–126 —— **只改 anchor 与 countedDays，从不改 round**
```

全仓库唯一会 `round += 1` 的地方在 `ResidueCore/StateStore.swift:84`：

```swift
/// 轮次切换（未达标自动开下一轮）：**只清本轮派生量，`F` / `C_done` / `a` 保留**。
public mutating func beginNextRound() {
    progress.round += 1
    ...
}
```

但 `StateStore` 是**未投产的老载体实现** —— `Sources/` 下 0 处实例化，
`App/WiringSelfCheck.swift:11` 的注释明写生产路径走 `state.residue` 二进制载体。
⇒ **这段正确的轮次切换逻辑从来没有被接上生产路径。**

生产路径的唯一写回处是 `ResidueCore/ObservationWriteback.swift` 的 `apply(input:header:payloads:)`，
其写入顺序为：① 补齐来源行 → ② `a` 写入 + `b` 累计 → ③ 取快照 → ④ 结算 → ⑤ 计数日推进 → `lastScanAt`。
**其中没有任何一步触碰 `round`。**

### 1.3 第二个后果：R6 要求的三处可见结果全部缺失

PRD v5.6 :69〔CR-010 · R6〕要求自动开轮**必须留下三处可见结果**（不新增页面 / 状态类 / 用户动作，
全部落在既有语义位）。当前状态：

| R6 要求的位置 | 契约原文（:69） | 现状 |
|---|---|---|
| ① 第 ③ 页未达项全局项带轮次 | 文案形如「第 2 轮 · 观察期 0/14 天（上一轮样本 27/30 未达标，已自动重开）」 | **括注缺失**（`UICopy.observationInProgress` 只有 base 串，无 `previous` 后缀） |
| ② 第 ⑤ 页页级状态行带轮次 | 形如「第 2 轮 · 本轮可点亮：否」 | **已满足**（`UICopy.pageLevelVerdict` 已带轮次前缀；轮次恒为 1 故看不出问题） |
| ③ 第 ⑤ 页「上一轮」行（轮次 ≥ 2 时） | 「第 1 轮 · 样本 `<K>` / 总量 `<T>` · 未达标 · 冻结于 `<YYYY-MM-DD>`」 | **不满足**：`UICopy.previousRound(round:)` 只输出「第 1 轮 · 上一轮结算」——**只有标签、没有四要素**，DAC v2.0 :176 DAC-50（修订）判**不通过** |

### 1.4 与其它单的关系

- **CR-031**：把 `K` / `J` 结算写进载体，让「有没有报告」这个问题有答案。本单是它的**下游** ——
  有了结算值，才谈得上「结算了但没达标 ⇒ 开下一轮」。CR-031 §8.3-ii 已登记「轮次自动推进」为遗留项。
- **CR-032**：修的是「判定域口径」——本单**依赖** CR-032 的判定域结论（域内来源 = 本轮快照内命中的来源）。
  CR-032 已落地（提交 `de547f0` / `dde2720`），本单在其之上推进。
- **PRD v5.6 :68 〔R6 写入口唯一 + R7〕**：观察期状态、轮次、开关状态、`a` 计数由**同一状态写入口**维护，
  本期**唯一触发源 = 「未达标自动开下一轮」** ⇒ 本单的写入口就是 `ObservationWriteback.apply`，
  不新开状态写入口、不新增用户动作。

---

## 二、契约依据

以下原文均已逐字核对（行号为当前冻结版本的实际行号）。

### 2.1 PRD v5.6（`docs/contract/Residue-PRD-v5.6.md`）

| 行号 | 条款 | 原文（逐字） |
|---|---|---|
| :62 | 〔CR-010 · R4〕自动开下一轮后的起算点 | 新一轮的「本轮首次成功扫描」= **上一轮结束扫描完成后的下一次成功扫描**（若开轮当日已有一次成功扫描，则该次即为新一轮第 1 计数日）。**不存在「第 14 个自然日早已过去 → 第 2 轮 1 天即满」的情形** —— 第 2 轮同样须走满 14 个**计数日**。 |
| :63 | 未达项文案（唯一串） | 若第 14 个计数日之后的扫描连续失败 ⇒ 观察期停留未结束、天数显示 14/14、剩余天数显示 `—`；**未达项文案统一为「第 `<N>` 轮 · 观察期未满 · 待结算扫描（无需操作）」**（全文唯一样式串；**除本串外不出现其它写法** —— 旧样式串「观察期已满 · 待结算」「等待结算扫描成功」等**已归零**）；不设超时上限。 |
| :65 | 观察期规则表「未达标处理」 | **② 未达标自动开下一轮（修 A7-4 的『无出口』）**。 |
| :68 | 〔CR-010 · R6〕自动开下一轮 | **观察期结束扫描产出报告后，若该轮未达标（存在任一来源 `K < H`），自动开启下一轮**：重新取快照（`T` 重算，**取快照时刻 = 该轮首次成功扫描完成时刻**）、计时器归零（**本轮计数日归零**）、**保留 L0 误判计数 `a`**（S2「错 1 次永久」不因换轮而清）。下一轮同样走「14 **计数日** + 结束扫描」。**〔CR-010 · 质量 G-3〕触发条件只认「存在任一来源 `K < H`」（样本不足）**——`a ≠ 0` **不单独触发开轮**（`a` 的重置只随应用版本，见 M4）；若某轮仅因 `a ≠ 0` 未达标，则该轮**不开新轮、开关保持 disabled**、`a` 保留。 |
| :69 | 〔CR-010 · R6〕可观测性 | 自动开轮**必须留下三处可见结果**（不新增页面 / 状态类 / 用户动作，全部落在既有语义位）：① **第 ③ 页未达项全局项带轮次**，文案形如「第 2 轮 · 观察期 0/14 天（上一轮样本 27/30 未达标，已自动重开）」；② **第 ⑤ 页页级状态行带轮次**，形如「第 2 轮 · 本轮可点亮：否」；③ **第 ⑤ 页在存在上一轮时（轮次 ≥ 2）于页级状态行下方固定一行「第 1 轮 · 样本 `<K>` / 总量 `<T>` · 未达标 · 冻结于 `<YYYY-MM-DD>`」**（**首轮不显示该行**）；**该行永远只呈现上一轮（第 `<N−1>` 轮）的结算值**，**直到下一轮开轮时才由本轮结算值替换**（替换后标签为新的轮次号，不再出现「上一轮：」字样）。**轮次**是唯一新增的**显示字段**；`T` 重算 / 计时器归零 / `a` 保留三件断言的**读数源 = ① ② ③ 三处**。 |
| :70 | 〔R6〕设计约束 | **不新增状态、不新增页面、不新增用户动作**——它就是「观察期又一次开始」。 |
| :71 | 〔R6〕写入口唯一 + 〔R7〕 | 观察期状态、轮次、开关状态、`a` 计数由**同一状态写入口**维护；本期**唯一触发源 = 本条**；「应用版本更新重置」**优先级低于本条**——同刻发生时，**先结算本轮、后执行应用版本重置**，`a` 终值 = 重置后的 0。**〔R7〕`a` 的重置边界 = 应用版本**：轮次切换**不清零**。 |
| :107 | M1 判据行 | 轮次 = 观察期窗口序号（首轮 = 1），**唯一递增事件 = 「未达标自动开下一轮」**；**应用版本变更不产生新轮次**；本轮计数日起算点 = **本轮首次成功扫描完成所在日**；本轮计数日 = 自起算点起计的**有成功扫描的日历日数**；失败 / 跳过 / **扫描中止（用户取消 / 超时 / 低电量）**不计入。 |
| :110 | M1 写入时刻行 | 每次**成功扫描完成**时 +1；**开轮时归零（并轮次 +1）**。版本变更时**同时**发生八件事：① 计数日归零 + 起算点重置 ② `T` 待重取（快照成员集合随 `T` 一并待重取）③ `K`/`J` 清零（结算凭证随 `K`/`J` 一并清零）④ `b` 清零 ⑤ **轮次不变** ⑥ `a` 清零（F 位图 / C_done / 位槽占用表 一并清零）⑦ `H` 随新 `T` 重算 ⑧ **用户设置类字段不清零**。 |
| :113 | M1 未达项文案行 | 计数日未满 → 「第 `<N>` 轮 · 观察期 `<已观察>/14` 天」；计数日已满而报告未产出 → 「**第 `<N>` 轮 · 观察期未满 · 待结算扫描（无需操作）**」；〔CR-011 · 设计 B8〕两串均带轮次前缀；**全文只此两串**，不得出现「已满 · 待结算」「等待结算扫描成功」等其它写法。 |

### 2.2 DAC v2.0（`docs/contract/Residue-DAC-v2.0.md`）

| 行号 | 条款 | 要点 |
|---|---|---|
| :176 | **DAC-50（修订）** | ⑤ 页存在页级状态行；且在轮次 ≥ 2 时，「上一轮」行**含四要素**：①轮次 `第 <N−1> 轮` ②`样本 <K> / 总量 <T>` ③`未达标` ④`冻结于 <YYYY-MM-DD>`。**四要素缺一即不通过**；「上一轮结算」这类只有标签无四要素的写法**不通过**。 |
| :170 | DAC-47（修订） | ⑤ 矩阵七项逐项点名且与 AC-09 全等。 |
| :118 | §二 沿用条目表第 `57` 行 | 「上一轮」行**仅轮次 ≥ 2 显示**（首轮不显示，非 `—`、非灰行）。 |
| :119 | §二 沿用条目表第 `58` 行 | 只读态未知字段 = `—（由更高版本维护）` 逐字。 |
| :61 | AC-09 现状栏 | 「DAC 齐·现状缺（缺 `L2 误判数` 列、多 `观察期` 列；**上一轮行缺 3 要素**）」。 |

### 2.3 B1 v1.0（`docs/contract/Residue-B1-功能用例集-v1.0.md`）

| 行号 | 用例 | 要点 |
|---|---|---|
| :467–473 | **TC-045** | 预期 ① 第 ③ 页全局项形如「第 2 轮 · 观察期 0/14 天（上一轮样本 11/12 未达标，已自动重开）」② 第 ⑤ 页页级状态行形如「第 2 轮 · 本轮可点亮：否」③ 第 ⑤ 页出现固定一行「第 1 轮 · 样本 11 / 总量 12 · 未达标 · 冻结于 `<YYYY-MM-DD>`」④ `a` 读数**仍为 1** ⑤ 第 2 轮的 `T` 由**该轮首次成功扫描**重新取快照（**开轮时不取快照**）。 |
| :1170 | TC-045 断言降级 | 断言降为五个子串「第 2 轮」「0/14」「上一轮」「未达标」「已自动重开」。 |
| :475–481 | **TC-046** | `K = 12 ≥ H` 且 `a = 1` ⇒ 轮次**仍为 1**、开关 = disabled、`a` 读数 = 1。 |
| :543–549 | **TC-054** | 第 1 轮**不显示**该行；第 2 轮出现**逐字**形如「第 1 轮 · 样本 11 / 总量 12 · 未达标 · 冻结于 `<YYYY-MM-DD>`」；该行**只呈现第 1 轮（即 `<N−1>`）的结算值**，**不占七项**；第 2 轮结算后该行由第 2 轮结算值替换、标签变为新的轮次号、**不再出现「上一轮：」字样**。 |

### 2.4 视觉基线 v1.1 §五 跨页规则（:120–140）

| 行号 | 要点 |
|---|---|
| :126 | ③ 页开关区未达项文案（带轮次）。 |
| :128 | ⑤ 页 = 矩阵 + 页级状态行 + 「上一轮」行。 |
| :133 | **轮次表述统一为前置数字式**（`第 2 轮 · …`），三处同构。 |
| :134 | **「上一轮」行仅在轮次 ≥ 2 时显示**，首轮不显示。 |
| :135 | 只读态。 |

### 2.5 R2 v1.9（`docs/contract/Residue-R2-技术方案-v1.9.md`）

| 行号 | 要点 |
|---|---|
| :278–320 | §5.1 载体布局（`headerJSON` 示例见 :289–303 —— **未列 `previousRound`** ⇒ 新增字段需 R2 升版）。 |
| :245 | `clearForAppVersionChange()` 按 M1 写入时刻穷举对齐（**轮次不变**）。 |
| :692 | 低一档迁移表（schema 1 → 2：就地升级、观察期从头开始、用户设置类字段原样保留）。 |
| :1390 / :1394 | §26.3 `a` 写入路径与 `b` 累计：「**`b` 按来源累加**…**轮次切换时归零**」。 |
| :1403 / :1407 | §26.5 版本变更清零表（:1407 **轮次不变**、用户设置类字段不清零）。 |

---

## 三、改什么

### 3.1 `SampleSufficiency` —— `K < H` 的唯一实现处

**问题**：PRD :68 的开轮触发条件「存在任一来源 `K < H`」与门槛判定「`K ≥ H`」是**同一个判据**。
若在写回层再写一遍 `k < Threshold.h(forTotal: t)`，就有**第二套实现** —— 两套必然漂移（不变量②）。

**改法**：在 `ResidueCore/Metrics.swift` 的 `Threshold`（:133–141）之后新增一个判据原语：

```swift
// ---------- M3 · 样本充分性判据（`K` 与 `H` 的比较） ----------

/// 样本充分性判据（`K` 与 `H` 的比较）——**全文唯一的 `K` 与 `H` 比较处**。
///
/// ## 为什么要有这个原语
/// 「未达标自动开下一轮」的触发条件（PRD v5.6 :68 · G-3）与门槛判定
/// （`GateEvaluator.isQualified`）判的是**同一件事**：`K` 是否够 `H`。
/// 若在写回层再写一遍 `k < Threshold.h(forTotal: t)`，就出现了第二套实现，
/// 两套必然漂移（不变量②：同一判定只有一个实现处）。
public enum SampleSufficiency {
    /// 样本是否不足（`K < H`，其中 `H = min(30, T)`）。
    ///
    /// - Note: `K` 为 `nil`（该来源本轮尚未结算）**不等于**不足 ——
    ///   契约口径是「存在任一来源 `K < H`」，`nil` 不参与比较（不变量③：`nil ≠ 0`）。
    public static func isInsufficient(k: Int, t: Int) -> Bool {
        k < Threshold.h(forTotal: t)
    }
}
```

**三处内联判据改调它**（`K < H` 的全部出现处，改完后全文只剩本原语内部一处）：

| 位置 | 现状 | 改为 |
|---|---|---|
| `Metrics.swift:639`（`GateEvaluator.unmetItems`） | `if let k = input.attributable, let t = input.total, k < Threshold.h(forTotal: t) {` | `if let k = input.attributable, let t = input.total, SampleSufficiency.isInsufficient(k: k, t: t) {` |
| `Metrics.swift:678`（`GateEvaluator.isQualified`） | `if k < Threshold.h(forTotal: t) { return false }` | `if SampleSufficiency.isInsufficient(k: k, t: t) { return false }` |
| `PageModelBuilder.swift:544`（`reportRow` 结论列） | `let qualified = k >= Threshold.h(forTotal: t) && entry.a == 0 && entry.b >= 1` | `let qualified = !SampleSufficiency.isInsufficient(k: k, t: t) && entry.a == 0 && entry.b >= 1` |

> **注意**：这三处是**等价改写**（`k < H` ⇔ `!(k >= H)`），行为不变 —— 本单只借它们的**既有位置**消除重复实现，
> 不改变任何判定结果。

### 3.2 `ObservationProgress.beginNextRound()` —— 轮次递增的唯一实现处

**改法**：在 `ObservationProgress`（`Metrics.swift:72–128`）内新增：

```swift
/// 轮次切换（**M1 写入时刻「开轮时归零（并轮次 +1）」的唯一实现处**）。
///
/// 契约依据：PRD v5.6 :68（未达标自动开下一轮）/ :107（唯一递增事件）/ :110（开轮时归零并轮次 +1）。
///
/// ## 起算点为什么清空
/// 新一轮的起算点 = **该轮首次成功扫描完成时刻**（PRD :62 〔R4〕），
/// 本方法在开轮当下**不知道**新轮第一次成功扫描是哪一天 —— 所以清空起算点，
/// 交给下一次成功扫描重新锚定。
/// ⇒ 「开轮当天的结算扫描」不会被误算成新轮的第 1 计数日。
public mutating func beginNextRound() {
    round += 1
    countedDays = 0
    startAnchor = nil
}
```

### 3.3 载体新增 `previousRound`（单槽）

**问题**：开轮时本轮的 `T` / `K` 被清零（下一轮重新取快照、重新结算），
若不留存，⑤ 页的「上一轮」行与 ③ 页的括注就**没有可显示的结算值**。

**改法**：在 `ResidueCore/ResidueStateFile.swift` 中新增一个记录类型，并在 `StateHeader` 上加一个
**可选单槽字段**：

```swift
/// 上一轮的结算记录（**开轮时写入，覆盖式单槽**）。
///
/// ## 为什么必须落盘
/// 开轮时本轮的 `T` / `K` 被清零（下一轮重新取快照、重新结算），
/// 若不留存，⑤ 页的「上一轮」行就没有可显示的结算值（PRD v5.6 :69 ③）。
///
/// ## 为什么是单槽而不是按来源留档
/// 契约只要求**一行**（DAC-50（修订）四要素、TC-045 ③），
/// 且「直到下一轮开轮时才由本轮结算值替换」（PRD :69 ③）⇒ 单槽覆盖即可。
public struct PreviousRoundRecord: Codable, Sendable, Equatable {
    /// 被结算的那一轮的轮次号（显示为「第 `<N>` 轮」）。
    public var round: Int

    /// 触发开轮的来源（**只供审计，不显示**）。
    public var source: Source

    /// 样本量 `K`（该来源本轮的归因命中数）。
    public var sample: Int

    /// 快照总量 `T`（该来源本轮的快照成员数）。
    public var total: Int

    /// 冻结时刻 = 该来源完成结算的时刻。
    public var settledAt: Date

    public init(round: Int, source: Source, sample: Int, total: Int, settledAt: Date) {
        self.round = round
        self.source = source
        self.sample = sample
        self.total = total
        self.settledAt = settledAt
    }
}
```

`StateHeader`（`ResidueStateFile.swift:186–230`）新增：

```swift
/// 上一轮结算记录（**单槽**；无上一轮 = `nil` ⇒ 首轮不显示「上一轮」行）。
public var previousRound: PreviousRoundRecord?
```

**`schemaVersion` 不 bump** —— 理由：

1. `StateHeader` 是**合成 Codable**（`Codable` + `Equatable`，字段由编译器合成）⇒ Optional 字段走
   `decodeIfPresent` ⇒ **旧二进制载体（无该键）自然解出 `nil`**，无需迁移；
2. 反向也安全：旧版本 App 读新版本写的载体时**忽略未知键** ⇒ 不会崩（只是旧版本看不到「上一轮」行 ——
   而旧版本本来就看不到轮次，不构成降级）；
3. R2 §5.1 的**尺寸恒等式只约束「段」的总长**，header JSON 的长度不参与该恒等式 ⇒ 不 bump 不破坏任何校验；
4. `tests/contract/verify_r2.py` 只对 `schemaVersion` 有 3 处字面断言，**不校验 header 字段集合**。

> **代价（如实登记）**：载体格式新增了一个字段而 `schemaVersion` 不变 ⇒ 「`schemaVersion` == 载体结构版本」
> 这一约定被打破。**这是本单刻意选择的取舍**：可加字段靠合成 Codable 的 `decodeIfPresent` 兼容，
> 而 bump `schemaVersion` 会触发 R2 :692 的「低一档迁移」语义（观察期从头开始），代价远大于收益。
> 若后续评审要求严格一致，替代方案是 bump 到 3 并在 R2 补迁移条目 —— 本单不擅自决定，登记为 §九 待裁决⑥。

### 3.4 轮次切换的清零原语（**不复用** `resetObservationCredentials()`）

**问题**：载体上已有「清零」原语 `StateHeader.resetObservationCredentials()`（`ResidueStateFile.swift:258–286`），
但它是**应用版本变更**用的，**会清 `a`** —— 而 PRD :68 / :71〔R7〕明写轮次切换**不清 `a`**。
⇒ **两条路径不可互相复用**。

**改法**：在 `StateHeader` 上新增独立方法：

```swift
extension StateHeader {
    /// 轮次切换（**未达标自动开下一轮**）——清本轮派生量，**保留 `a`**。
    ///
    /// ## 与 `resetObservationCredentials()` 的区别（**不可复用**）
    /// 那条是「应用版本变更」用的，**会清 `a`**（M4：`a` 只在应用版本变更时清零）；
    /// 本条是「轮次切换」用的，**必须保留 `a`**（PRD v5.6 :68 / :71〔R7〕/ G-3）。
    ///
    /// ## 清 / 不清对照表
    ///
    /// | 字段 | 处理 | 依据 |
    /// |---|---|---|
    /// | `round` | **+1** | PRD :110「开轮时归零（并轮次 +1）」 |
    /// | `countedDays` | 归零 | PRD :68「计时器归零（本轮计数日归零）」 |
    /// | `roundStartAnchor` | 清空 | PRD :62〔R4〕起算点 = 新轮首次成功扫描完成时刻 |
    /// | `settlement`（结算凭证） | 清零 | PRD :110「结算凭证随 `K`/`J` 一并清零」 |
    /// | 每来源 `snapshotTaken` | 清 false | 新轮要重新取快照（PRD :68「重新取快照」） |
    /// | 每来源 `T` / `H` | 清 nil | `H` 随新 `T` 重算（PRD :68 / :110⑦） |
    /// | 每来源 `K` / `J` | 清 nil | 新轮要重新结算 |
    /// | 每来源 `snapshotDate` / `settlementDate` / `unattributableCount` | 清 nil | 上一轮的时刻与条数不适用于新轮 |
    /// | 每来源 `b` | 归零 | PRD :68「计时器归零」+ R2 :1394「`b` 按来源累加…轮次切换时归零」 |
    /// | 每来源 `a` / `slotCount` / `doneCount` | **保留** | PRD :68 / :71〔R7〕「保留 L0 误判计数 `a`」（S2「错 1 次永久」） |
    /// | 每来源 `lastJudgmentAt` | **保留** | 判定记录随 `a` 一并保留 ⇒ 其时刻仍然成立 |
    /// | `appVersion` / `autoDeleteEnabled` / `countedDaysCap` | **保留** | PRD :110⑧「用户设置类字段不清零」 |
    /// | `lastScanAt` | **保留** | 本次扫描确实发生过 |
    /// | `previousRound` | **写入新记录（覆盖）** | PRD :69 ③「直到下一轮开轮时才由本轮结算值替换」 |
    public mutating func beginNextRound(previous: PreviousRoundRecord) {
        var progress = ObservationProgress(
            round: round,
            startAnchor: roundStartAnchor,
            countedDays: countedDays
        )
        progress.beginNextRound()
        round = progress.round
        roundStartAnchor = progress.startAnchor
        countedDays = progress.countedDays

        settlement = SettlementHeader()
        self.previousRound = previous

        for index in sources.indices {
            sources[index].snapshotTaken = false
            sources[index].T = nil
            sources[index].H = nil
            sources[index].K = nil
            sources[index].J = nil
            sources[index].b = 0
            sources[index].snapshotDate = nil
            sources[index].settlementDate = nil
            sources[index].unattributableCount = nil
            // `a` / `slotCount` / `doneCount` / `lastJudgmentAt` —— 保留
        }
    }
}
```

> **载荷侧（`SourcePayload`）同步清**：`snapshotMembers` 必须清空（否则新轮结算会拿旧轮的成员集合当快照 ——
> `T` 已归零但成员集合还在，是**自相矛盾的载体态**）。而 `bitmap`（`F`）/`countedDoneSlots`（`C_done`）/
> `slots`（位槽占用表）**必须保留** —— 它们是 `a` 的载体，保留 `a` 就必须保留它们。
>
> ```swift
> extension SourcePayload {
>     /// 轮次切换时清本轮快照成员集合（**不动 `a` 的三项载体**）。
>     public mutating func clearSnapshotMembers() {
>         snapshotMembers = []
>     }
> }
> ```

### 3.5 写回层集成顺序（**顺序是铁律**）

**改法**：`ObservationWriteback.apply(input:header:payloads:)` 在「⑤ 计数日推进」之后、
`header.lastScanAt = input.now` 之前，插入「⑦ 未达标自动开下一轮」：

```swift
// ⑦ 未达标自动开下一轮（PRD v5.6 :68 · 〔CR-010 · R6〕）
//
// **顺序铁律**：必须放在「⑤ 计数日推进」**之后**。
// 反过来（先开轮再推进）会把起算点重新锚到**结算当天**，
// 于是「结算扫描」被误算成新轮的第 1 计数日 —— 违反 PRD :62〔R4〕
// （新一轮的第 1 计数日 = 上一轮结束扫描完成后的**下一次**成功扫描）。
//
// **开轮时不取快照**（B1 TC-045 ⑤）：新轮的快照由它自己的首次成功扫描取。
if !settledSources.isEmpty {
    // 判定域内按 `Source.allCases` 序**首个** `K < H` 的来源
    // （`header.sources` 的顺序由 `apply` 的 :219 重排保证 = `Source.allCases` 序）
    let failing = header.sources.first { entry in
        guard let k = entry.K, let t = entry.T else { return false }
        return SampleSufficiency.isInsufficient(k: k, t: t)
    }
    if let failing, let k = failing.K, let t = failing.T {
        let record = PreviousRoundRecord(
            round: header.round,          // **开轮前**的轮次 = 被结算的那一轮
            source: failing.source,
            sample: k,
            total: t,
            settledAt: failing.settlementDate ?? input.now
        )
        header.beginNextRound(previous: record)
        // 载荷侧：清本轮快照成员集合（`F` / `C_done` / 位槽占用表**保留** —— 它们是 `a` 的载体）
        for source in Source.allCases {
            guard var payload = payloads[source] else { continue }
            payload.clearSnapshotMembers()
            payloads[source] = payload
        }
    }
}
```

**开轮后的载体状态**（与 TC-045 逐条对齐）：

| TC-045 断言 | 开轮后载体状态 | ✓ |
|---|---|---|
| ④ `a` 读数**仍为 1** | `a` / `slotCount` / `doneCount` 保留，`F` / `C_done` / 位槽占用表保留 | ✓ |
| ⑤ 第 2 轮的 `T` 由**该轮首次成功扫描**重新取快照（**开轮时不取快照**） | 开轮时 `T = nil`、`snapshotTaken = false`、`snapshotMembers = []` ⇒ 本次扫描**不再取快照** | ✓ |
| ① 第 ③ 页「观察期 0/14 天」 | `countedDays = 0`、`startAnchor = nil` ⇒ 下一次成功扫描才锚定第 1 日 | ✓ |

### 3.6 触发判据

| 条件 | 契约依据 | 本单实现 |
|---|---|---|
| 本次**有来源完成结算** | PRD :68「观察期结束扫描**产出报告后**」 | `!settledSources.isEmpty` |
| **存在任一来源 `K < H`** | PRD :68 / G-3 | `header.sources.first { SampleSufficiency.isInsufficient(...) }` |
| `a ≠ 0` **不单独触发** | PRD :68 G-3 / TC-046 | 判据里**没有** `a` ⇒ `K ≥ H` 而 `a ≠ 0` ⇒ **不开轮**、轮次仍为 1、开关保持 disabled、`a` 保留 |

**边界（如实登记，不改）**：

- 某来源结算 `K ≥ H` 而另一来源本轮**未结算**（`K = nil`）⇒ 此刻**不存在** `K < H` ⇒ **不开轮**。
  这**不构成死锁**：后者在下一次成功 full 扫描时结算（`observationFull` 仍成立）⇒ 届时再判；
  若它本轮从未取过快照，则它不在判定域内（CR-032 已修），不构成阻塞。
- 判定域含多来源时，若某来源本轮未扫到则其 `K` 恒 `nil`、结算被跳过 —— 这是 CR-031
  「结算要求本轮扫过」规则的衍生边界，本单登记备查、**不改**。

### 3.7 文案（`UICopy`）

**改法 1 —— 第一串加条件性后缀**（`SemanticSlot.swift:212`）：

```swift
/// M1 第一串（计数日未满）：`第 <N> 轮 · 观察期 <已观察>/14 天`
/// **有上一轮结算记录时追加条件性括注**（PRD v5.6 :69 ①）。
public static func observationInProgress(
    round: Int,
    observed: Int,
    previous: PreviousRoundRecord? = nil
) -> String {
    let base = "第 \(round) 轮 · 观察期 \(observed)/14 天"
    guard let previous else { return base }
    return base + "（上一轮样本 \(previous.sample)/\(previous.total) 未达标，已自动重开）"
}
```

> **为什么只给第一串加后缀**：
> PRD :63 明写未达项文案「**全文唯一样式串；除本串外不出现其它写法**」，
> PRD :113 明写「**全文只此两串**」。
> 若第二串（待结算扫描）也加后缀，就会出现「第三串」⇒ 违反 :113。
> ⇒ **第二串 `awaitingSettlementScan` 逐字不动**。
> 调和结论：「两串」指两个**基串**；R6 ① 是给第一串加的**条件性后缀**（无上一轮记录时不出现），
> **不构成第三串**（登记为 §九 待裁决④）。
>
> **无上一轮记录时第一串逐字不变** ⇒ 现有逐字断言
> （`SemanticSlotTests.swift:139-142`、`MetricsTests.swift:54`）**零改动**。

**改法 2 —— 「上一轮」行改成四要素**（新增；**删除**旧的 `UICopy.previousRound(round:)`）：

```swift
/// ⑤ 页「上一轮」行 —— **四要素缺一即不通过**（DAC v2.0 :176 DAC-50（修订））。
///
/// 契约格式（PRD v5.6 :69 ③ / B1 TC-045 ③ / TC-054）：
/// `第 <N−1> 轮 · 样本 <K> / 总量 <T> · 未达标 · 冻结于 <YYYY-MM-DD>`
public static func previousRoundSettlement(_ record: PreviousRoundRecord) -> String {
    "第 \(record.round) 轮 · 样本 \(record.sample) / 总量 \(record.total) · 未达标 · 冻结于 \(dayText(record.settledAt))"
}
```

**格式陷阱（逐字核对过，写测试时必须用对）**：

| 位置 | 写法 | 斜杠两侧 |
|---|---|---|
| ③ 页括注 | `上一轮样本 11/12 未达标，已自动重开` | **无空格** |
| ⑤ 页「上一轮」行 | `样本 11 / 总量 12` | **两侧有空格** |

**改法 3 —— Core 侧日期格式化原语**（`SemanticSlot.swift` 内，`UICopy` 附近）：

```swift
/// 日期「yyyy-MM-dd」（**Core 侧唯一样式串**）。
///
/// ## 为什么不用 `DateFormatter`
/// 它不是 `Sendable` ⇒ Swift 6 下不能做 `static let`（共享可变状态）；
/// `Date.FormatStyle` 又随 locale 变化 ⇒ 日期格式会漂。
/// 这里用 `Calendar` 取分量 + 手工拼串：**确定性 + 无共享可变状态**。
static func dayText(_ date: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
}
```

> Core 内此前**没有任何 `DateFormatter`**（唯一的 Core 内日期格式化是 `Redactor.swift:373` 的
> `invokedAt.ISO8601Format()`）；`AppModel.swift:1423` 的 `DateFormatter("yyyyMMdd-HHmmss")`
> 是**文件名用途**、不可复用。故新增本原语。

**改法 4 —— 删除旧函数**：

`UICopy.previousRound(round:)`（`SemanticSlot.swift:311`）输出「第 N−1 轮 · 上一轮结算」，
**只有标签、没有四要素** ⇒ DAC-50（修订）判不通过。
本单改用四要素行 ⇒ **该函数因本次改动而失效**，按「只删除因本次改动而失效的函数」删除。
（`SemanticSlotTests.swift:158-165` 的 `testPreviousRoundCopyIsPrefixNumeric` 与
`:177-190` 的 `testThreeRoundCopiesAreIsomorphic` 随之改写。）

### 3.8 `PageModelBuilder` / `DesignSampleData`

**改法 1 —— ③ 页全局项把「上一轮」传下去**：

`PageModelBuilder.swift:237` 当前是 `model.unmetNotice = .text(unmetNoticeText(unmet, progress: progress))`，
改为 `unmetNoticeText(unmet, progress: progress, previous: header.previousRound)`。

`UnmetGlobalItem.text`（`Metrics.swift:536–551`）扩参数：

```swift
public static func text(
    round: Int,
    countedDays: Int,
    previous: PreviousRoundRecord? = nil
) -> String {
    if countedDays < ObservationProgress.requiredDays {
        return UICopy.observationInProgress(round: round, observed: countedDays, previous: previous)
    }
    return UICopy.awaitingSettlementScan(round: round)
}
```

**改法 2 —— `unmetNoticeText` 改调 `UnmetGlobalItem.text`（消除第二处两串选择）**：

当前 `unmetNoticeText`（`PageModelBuilder.swift:436–469`）自己判分支选串
（`:439` `isDayQuotaReached` → `awaitingSettlementScan`；`:443` → `observationInProgress`），
与 `UnmetGlobalItem.text` **各写一遍**同样的两选一 ⇒ 第二套实现（不变量②隐患）。
本单改为**只调 `UnmetGlobalItem.text`**（两处判据互补 ⇒ 等价：`countedDays < 14` ⇔ `!isDayQuotaReached`）。

**改法 3 —— ⑤ 页「上一轮」行的显示条件**：

```swift
// 「上一轮」行**仅在存在上一轮结算记录时显示**（首轮不显示，不是显示「—」）
model.previousRoundSlot = header.previousRound.map { record in
    .text(UICopy.previousRoundSettlement(record))
}
```

> 判据从「`header.round >= 2`」改为「`header.previousRound != nil`」——
> 生产语义上二者等价（轮次 ≥ 2 必然有上一轮记录），但**后者是「有记录才显示」的直接表达**，
> 且不依赖「轮次与记录必须同时存在」这个隐含前提。
> **迁移无影响**：旧载体的 `round` 恒为 1、`previousRound` 为 `nil` ⇒ 显示条件均为「不显示」。

**改法 4 —— `DesignSampleData.swift:141–142`** 同步新签名：

```swift
m.previousRoundSlot = .text(UICopy.previousRoundSettlement(
    PreviousRoundRecord(round: 1, source: .uvCache, sample: 11, total: 12,
                        settledAt: Date(timeIntervalSince1970: 1_700_000_000))
))
```

**改法 5 —— `PageModel.swift:261–262`** 的注释同步（「仅轮次 ≥ 2 时非 nil」→「存在上一轮结算记录时非 nil」）。

### 3.9 R2 升 v1.10（载体字段补文档）

**为什么必须升版**：R2 §5.1 的 `headerJSON` 示例（:289–303）是**载体布局的契约**，
新增 `previousRound` 字段而不写进 R2 ⇒ **代码与文档对不上就是缺陷**（CLAUDE.md §五）。

**改法**：复制 `Residue-R2-技术方案-v1.9.md` → `Residue-R2-技术方案-v1.10.md`，改：

1. 标题行版本号（**并订正现存的标题行错误**，见 §五）；
2. 版本说明行：「本文件即**最新版 v1.10**（CR-033 · 轮次自动推进）」；
3. 新增「**v1.10 修订说明（CR-033 · 轮次自动推进 · 2026-11-17）**」块，写明：
   - `headerJSON` 新增 `previousRound`（单槽，可为 `null`）；
   - **`schemaVersion` 不 bump** 的理由（合成 Codable + `decodeIfPresent`；尺寸恒等式只约束段长）；
   - 轮次切换的清 / 不清对照表（与 §3.4 的表一致）。
4. §5.1 的 `headerJSON` 示例补 `previousRound` 字段。

> `tests/contract/verify_r2.py` **自动发现最新版本号**（不写死）⇒ 无需改脚本。
> **PRD 不升版**：PRD v5.6 已是现行规格（:62/:63/:65/:68/:69/:70/:71/:107/:110/:113），
> 本单是**实现缺失**，不是契约变更 ⇒ PRD 侧一个字都不改。

### 3.10 设计稿重渲染

`swift run --disable-sandbox ResidueApp --render-pages design-renders` 重渲染 16 张设计稿
（⑤ 页「上一轮」行文案变了）。CI 会重渲染并上传、**不做 diff 比对** ⇒ 不会让 CI 变红，
但仓库内 16 张 PNG 会过时 ⇒ 本单一并重渲染。

### 3.11 不动的地方（外科手术边界）

| 不动 | 理由 |
|---|---|
| `GateEvaluator` / `PageModelBuilder` 的**判定语义** | 本单只把内联的 `K < H` 改调 `SampleSufficiency`，**行为等价** |
| `UICopy.awaitingSettlementScan` | PRD :63 / :113「全文只此两串」 |
| `GateEvaluator.isQualified` 的门槛条件 | 不变量④不变：没证明判得准就不动手 |
| `TrashExecutor` / 删除路径 | 本单**完全不动**删除逻辑 |
| `Pages.swift` | ⑤ 页「上一轮」行已在矩阵七项**之外**渲染（`Pages.swift:579–583`）⇒ 满足 TC-054「不占七项」，无需改 |
| `StateStore.swift:84` 的 `beginNextRound()` | **未投产的历史死代码**（见 §六） |
| `schemaVersion` | 见 §3.3 的取舍说明 + §九 待裁决⑥ |
| PRD v5.6 | 契约侧已写对，本单只补实现 |
| DAC v2.0 / B1 v1.0 / 视觉基线 v1.1 | 契约侧已写对（含 DAC-57 沿用条目，见 §五） |

---

## 四、影响面

| 文件 | 改动 | 性质 |
|---|---|---|
| `Sources/ResidueCore/Metrics.swift` | 新增 `SampleSufficiency`；`ObservationProgress.beginNextRound()`；`UnmetGlobalItem.text` 扩参数；`GateEvaluator` 两处改调 | 新增 + 等价改写 |
| `Sources/ResidueCore/SemanticSlot.swift` | `UICopy.observationInProgress` 扩参数；新增 `UICopy.previousRoundSettlement` + `dayText`；**删除** `UICopy.previousRound(round:)` | 新增 + 删除（因本次改动失效） |
| `Sources/ResidueCore/ResidueStateFile.swift` | 新增 `PreviousRoundRecord`；`StateHeader.previousRound` 字段；新增 `StateHeader.beginNextRound(previous:)`；新增 `SourcePayload.clearSnapshotMembers()` | 新增（不动既有字段语义） |
| `Sources/ResidueCore/ObservationWriteback.swift` | `apply` 末尾插入「⑦ 未达标自动开下一轮」 | 新增分支 |
| `Sources/ResidueCore/PageModelBuilder.swift` | `unmetNoticeText` 扩参数 + 改调 `UnmetGlobalItem.text`；`previousRoundSlot` 条件改为 `header.previousRound != nil`；`reportRow` 一处改调 `SampleSufficiency` | 改写（等价） |
| `Sources/ResidueCore/PageModel.swift` | 仅注释 | 注释 |
| `Sources/ResidueApp/DesignSampleData.swift` | 同步 `previousRoundSlot` 新签名 | 改写 |
| `Sources/ResidueApp/Pages.swift` | **不动** | — |
| `docs/contract/Residue-R2-技术方案-v1.10.md` | 新增（从 v1.9 复制修订） | 文档 |
| `design-renders/*.png` | 重渲染 16 张 | 产物 |

### 受影响测试（必须改写 / 新增）

| 测试文件 | 现状 | 处理 |
|---|---|---|
| `SemanticSlotTests.swift:139-142` | `observationInProgress(round: 2, observed: 5)` 逐字断言 | **零改动**（默认参数 `previous = nil` ⇒ 逐字不变） |
| `SemanticSlotTests.swift:146-151` | `awaitingSettlementScan` 逐字断言 | **零改动** |
| `SemanticSlotTests.swift:158-165` | `testPreviousRoundCopyIsPrefixNumeric` 断言旧的「上一轮结算」串 | **改写**为四要素断言 |
| `SemanticSlotTests.swift:177-190` | `testThreeRoundCopiesAreIsomorphic` 引用 `UICopy.previousRound(round: 2)` | **改写**为 `previousRoundSettlement` |
| `MetricsTests.swift:54` / `:58` | `UnmetGlobalItem.text(round:countedDays:)` | **零改动**（新增参数有默认值） |
| `PageModelBuilderTests.swift:12-36` | `makeHeader` 默认 `round: 2`、来源行 `T:100, K:90, J:10, H:30, a:0, b:12`、**无 `previousRound`** | **改写**：加 `previousRound` 参数；默认仍 `round: 2` |
| `PageModelBuilderTests.swift:85` | 只读态断言 `previousRoundSlot == nil` | **零改动**（只读态早返回） |
| `PageModelBuilderTests.swift:319-332` | `testPreviousRoundOnlyFromRoundTwo`：round=1 → nil；round=2 → 非 nil | **改写**：判据改为「有记录才显示」 |
| `ObservationWritebackTests.swift` | 现有 21 个用例 | **新增**开轮相关用例（§八） |

> ⚠️ **`PageModelBuilderTests.makeHeader` 的默认基线本身就是 `round: 2`** ——
> 现有测试基线**假装已经在第 2 轮**，而生产载体里轮次恒为 1。
> 新规则下（「有记录才显示」），默认基线**必须显式带上 `previousRound` 记录**，
> 否则 `testPreviousRoundOnlyFromRoundTwo` 会**假绿**（断言 `nil` 通过，但测的不是契约说的东西）。
> 这是本单最容易踩的坑，已写进 §八 的 RED 步骤。

---

## 五、附带订正

| # | 订正项 | 依据 |
|---|---|---|
| 1 | **DAC-57 不是文档缺口** —— DAC v2.0 §二 沿用条目表**第 `57` 行**已定义（「上一轮」行仅轮次 ≥ 2 显示，首轮不显示，非 `—`、非灰行）。CR-032 前期调研曾把它记为「缺口」，本单订正为**沿用条目**，DAC v2.0 **无需改动** | DAC v2.0 :118 |
| 2 | **R2 标题行版本号错误** —— `Residue-R2-技术方案-v1.9.md:1` 的标题仍是「# Residue · R2 技术方案 **v1.7**」，而 :5 明写「本文件即**最新版 v1.9**」。本单升 v1.10 时**一并订正标题行**为 v1.10（该行本就要改） | R2 v1.9 :1 vs :5 |
| 3 | **`ARCHITECTURE.md:69-70` 仍写 PRD v5.5 / R2 v1.8** —— 本单升 R2 v1.10 后该处**又落后一版**。本单**不连带改**（外科手术边界），但**登记**在此，等专门单统一同步 | CR-032 §9.5 已登记过一次 |
| 4 | **`StateStore.swift:84` 的 `beginNextRound()` 是未投产的第二处「轮次切换」实现** —— 逻辑与本单要写的**几乎一致**（`round += 1` / `countedDays = 0` / `startAnchor = nil` / 清 `checkCountThisRound`），但载体模型不同（老载体无 `T`/`K`/`J`）。**本单不动它、不删它**（不擅自删历史死代码），只在 §六 登记 | `StateStore.swift` 在 `Sources/` 下 0 处实例化 |

---

## 六、不做的事

| 不做 | 理由 |
|---|---|
| 不改 PRD / DAC / B1 / 视觉基线 | 契约侧已写对（缺口在实现） |
| 不 bump `schemaVersion` | 见 §3.3 取舍说明 + §九 待裁决⑥ |
| 不删 `StateStore.swift` 的 `beginNextRound()` | 未投产的历史死代码；发现无关死代码**指出但不擅自删除**（CLAUDE.md 三·外科手术式改动） |
| 不改 `Pages.swift` | 「上一轮」行已在矩阵七项之外渲染（TC-054 已满足） |
| 不改 `GateEvaluator` 的门槛条件 | 不变量④ |
| 不做「上一轮」行的**按来源留档** | 契约只要一行 ⇒ 单槽 |
| 不合成 `ΣK` / `ΣT` 之类的**合计值** | 界面只呈现**载体真实值**，不造数（不变量③） |
| 不新增页面 / 状态类 / 用户动作 | PRD :70 明写 |
| 不碰 §1.7-c / §1.7-d / §1.7-e（⑤ 页列集合、`evidence.jsonl` 字段） | 另开单 |
| 不改 `ARCHITECTURE.md` | 见 §五 第 3 条 |

---

## 七、验收判据

| # | 判据 | 验证方式 |
|---|---|---|
| 1 | 未达标（`K < H`）结算 ⇒ **轮次 +1**、计数日归零、起算点清空 | 单测（`ObservationWritebackTests` 新增） |
| 2 | 开轮时 `a` **保留**（连同 `slotCount` / `doneCount` / `F` / `C_done` / 位槽占用表） | 单测：断言 `a` 不变、载荷三项载体不变 |
| 3 | 开轮时 `T` / `K` / `J` / `H` / `b` / `snapshotMembers` / 结算凭证**全部清零** | 单测：逐字段断言 |
| 4 | 开轮时**不取快照**（`T` 仍为 `nil`、`snapshotTaken == false`） | 单测（TC-045 ⑤） |
| 5 | 开轮当天的**结算扫描不计入**新轮计数日（`countedDays == 0`、起算点为 `nil`） | 单测（PRD :62〔R4〕） |
| 6 | 仅因 `a ≠ 0` 未达标（`K ≥ H`）⇒ **不开轮**、轮次仍为 1、`a` 保留、开关 disabled | 单测（TC-046） |
| 7 | ③ 页全局项 = 「第 2 轮 · 观察期 0/14 天（上一轮样本 11/12 未达标，已自动重开）」 | 单测（`PageModelBuilderTests`，TC-045 ①） |
| 8 | ③ 页括注的 `K`/`T` 与 ⑤ 页「上一轮」行**同源**（同一来源的同一对值） | 单测：两处断言相等 |
| 9 | ⑤ 页页级状态行 = 「第 2 轮 · 本轮可点亮：否…」 | 单测（TC-045 ②；**本单不改编动**，只补断言） |
| 10 | ⑤ 页「上一轮」行 = 「第 1 轮 · 样本 11 / 总量 12 · 未达标 · 冻结于 YYYY-MM-DD」（**四要素齐**） | 单测（TC-045 ③ / DAC-50（修订）） |
| 11 | 首轮**不显示**「上一轮」行（`nil`，不是「—」、不是灰行） | 单测（TC-054 / DAC-57） |
| 12 | 上一轮行**不占七项**（矩阵仍是 3 行） | 单测：`reportRows.count == 3` + 审查 `Pages.swift:579–583` 渲染位置 |
| 13 | 第 2 轮结算后「上一轮」行由**第 2 轮结算值替换**、标签变为「第 2 轮」、**不出现「上一轮：」字样** | 单测（TC-054） |
| 14 | 无上一轮记录时，③ 页两串**逐字不变** | 单测（沿用现有断言，零改动） |
| 15 | `K < H` 的比较在 Core 内**只剩一处**实现 | 审查：`grep -n "Threshold.h(forTotal" Sources/` ⇒ 命中仅 `Threshold.h` 自身与 `SampleSufficiency` |
| 16 | 载体往返：新增字段能编码/解码；**旧载体（无该键）可解码为 `nil`** | 单测（`StateFileTests` / `StateFileSchema2Tests`） |
| 17 | 全部单测通过 | `swift test` |
| 18 | 页面结构 / 界面禁算术 / 数据层接线 / 空实现 未破 | `./scripts/verify_a9.sh` |
| 19 | 错误码表 ↔ 文档一致 | `python3 scripts/verify_codes.py` |
| 20 | 真 IO 往返自检通过 | `swift run --disable-sandbox ResidueApp --verify-wiring /tmp/wiring` |
| 21 | 文档基线未破（PRD + R2） | `./tests/contract/check_all.sh` + `python3 tests/contract/verify_r2.py` |
| 22 | Release 编译通过（`#if DEBUG` 自检入口在 Release 下会被裁掉） | `swift build -c release` |

---

## 八、TDD 步骤

> 铁律：**先写失败测试，看它以「功能缺失」的原因失败，再写实现**。
> 每步的「验证」列写明**怎么确认它真的红/真的绿**。

| # | 步骤 | 类型 | 验证 |
|---|---|---|---|
| 1 | `ObservationWritebackTests` 新增「未达标结算 ⇒ 开轮」：`countedDays = 14`、快照已取、本轮结算 `K < H` ⇒ 断言 `round == 2`、`countedDays == 0`、`roundStartAnchor == nil`、`T == nil`、`snapshotTaken == false`、`snapshotMembers.isEmpty`、`a` 不变 | **RED** | 跑该用例 ⇒ 应因 `round == 1` 失败（**不是**因编译错误） |
| 2 | 新增「仅 `a ≠ 0`（`K ≥ H`）⇒ 不开轮」 | **RED** | 应因 `round` 仍为 1 而**通过**（本步是防回归护栏，先写先绿亦可，但要**在实现前写**） |
| 3 | 新增「开轮当天的结算扫描不计入新轮计数日」 | **RED** | 应因 `countedDays == 1` 失败 |
| 4 | 实现 `SampleSufficiency` + 三处内联判据改调 | **GREEN** | `swift test --filter SampleSufficiency`；`grep` 确认 `K < H` 只剩一处 |
| 5 | 实现 `ObservationProgress.beginNextRound()` | **GREEN** | 步骤 1–3 的用例转绿 |
| 6 | 实现 `PreviousRoundRecord` + `StateHeader.previousRound` + `StateHeader.beginNextRound(previous:)` + `SourcePayload.clearSnapshotMembers()` | **GREEN** | 步骤 1–3 转绿 |
| 7 | 实现写回层「⑦ 未达标自动开下一轮」 | **GREEN** | 步骤 1–3 转绿；**且步骤 2 仍绿** |
| 8 | 新增 `UICopy.previousRoundSettlement` + `dayText` + `observationInProgress(previous:)` 的**逐字**断言；**删除**旧 `UICopy.previousRound(round:)` 及其用例 | **RED → GREEN** | 先写逐字断言 ⇒ 编译失败（函数不存在）⇒ 实现后转绿 |
| 9 | 新增 `PageModelBuilder` 的 ③ 页括注断言（TC-045 ①）与 ⑤ 页四要素行断言（TC-045 ③）、首轮不显示断言（TC-054） | **RED → GREEN** | 先写断言 ⇒ 转绿 |
| 10 | 改写 `PageModelBuilderTests.makeHeader`（加 `previousRound` 参数）**与** `testPreviousRoundOnlyFromRoundTwo` | **REFACTOR** | 全绿；**确认默认基线不再假绿**（§四 的 ⚠️） |
| 11 | 新增载体往返测试：旧载体（无 `previousRound` 键）解码为 `nil`、新载体往返保真 | **RED → GREEN** | 全绿 |
| 12 | R2 升 v1.10 + 改变更单 §十 实施记录 | 文档 | `python3 tests/contract/verify_r2.py` 通过 |
| 13 | 重渲染 16 张设计稿 | 产物 | `swift run --disable-sandbox ResidueApp --render-pages design-renders` 成功；16 张 PNG 已更新 |
| 14 | 回跑全部校验 | 验收 | §七 的 17–22 项逐条通过，**并把实跑数字写进 §十** |

> **不在测试里复制生产解析逻辑**（CLAUDE.md §八）：本单的测试一律**调用生产原语**
> （`ObservationWriteback.apply` / `SampleSufficiency` / `UICopy.*`），
> 不在测试里重写一份「`K < H`」或「四要素拼串」的逻辑。

---

## 九、待裁决

> 以下 6 条**均给出建议方案**，不阻塞起草与实现；如评审给出不同裁决，按裁决调整。

| # | 待裁决 | 建议 | 理由 |
|---|---|---|---|
| ① | **多来源时「上一轮」行显示哪一对 `K` / `T`？** | 取**判定域内按 `Source.allCases` 序首个 `K < H` 的来源**（`uvCache` → `npmNpx`） | 契约只给一行、只给一对数；每个数字都是**载体真实值**，不造 `ΣK` / `ΣT` 合成值（不变量③）；`header.sources` 的顺序由 `apply` 的重排保证 = `Source.allCases` 序 ⇒ 确定性可单测 |
| ② | **「冻结于」取哪个时刻？** | 取**结算时刻**（`settledAt` = 该来源 `K`/`J` 写下的时刻） | 该行的「未达标」是**结算判定**，结算时刻才使结论成立；快照日只是「取样那天」，与「未达标」无因果关系。契约只给 `<YYYY-MM-DD>` 占位，未指定来源 |
| ③ | **应用版本变更时「上一轮」记录保留还是清掉？** | **保留** | PRD :107「应用版本变更**不产生新轮次**」⇒ 上一轮的冻结结论仍然成立；`resetObservationCredentials()` 不碰它 ⇒ **无需改代码** |
| ④ | **PRD :113「全文只此两串」与 R6 :69 ① 的括注是否冲突？** | 判定为**不冲突**：两串指两个**基串**；R6 ① 是给第一串加的**条件性后缀**（无上一轮记录时不出现），不构成第三串。实现上**只给第一串加后缀，第二串逐字不动** | PRD :63 明写「除本串外不出现其它写法」指的是**第二串（待结算）**；:113 的「两串」指未达项的两种形态；R6 是**观察期规则**层的追加约束。两条都满足的唯一实现 = 后缀只挂第一串 |
| ⑤ | **`lastJudgmentAt` 在轮次切换时清还是留？** | **保留** | `a` 保留 ⇒ 判定记录（F 位图 / `C_done` / 位槽占用表）保留 ⇒ 最后一次判定的时刻**仍然成立**；版本变更路径清它是因为版本变更**连 `a` 一起清** |
| ⑥ | **新增载体字段但不 bump `schemaVersion` 是否可接受？** | **可接受**（本单按此实现），但**显式登记** | 合成 Codable + Optional `decodeIfPresent` ⇒ 双向兼容；R2 §5.1 尺寸恒等式只约束段长；`verify_r2.py` 不校验 header 字段集合。**代价**：「`schemaVersion` == 载体结构版本」的约定被打破。若评审要求严格一致 ⇒ 改为 bump 到 3 并在 R2 补迁移条目（触发 PRD :110⑧「用户设置类字段不清零」的迁移语义） |

---

## 十、实施记录

> **每项都写实跑结果与数字**，不写「已完成」。

### 10.1 代码改动

| 文件 | 改动 | 状态 |
|---|---|---|
| `Sources/ResidueCore/Metrics.swift` | `SampleSufficiency` / `ObservationProgress.beginNextRound()` / `UnmetGlobalItem.text` 扩参 / `GateEvaluator` 两处改调 | ✅ |
| `Sources/ResidueCore/SemanticSlot.swift` | `observationInProgress` 扩参（条件性后缀） / `previousRoundSettlement`（四要素） / `dayText` / 删 `previousRound(round:)` | ✅ |
| `Sources/ResidueCore/ResidueStateFile.swift` | `PreviousRoundRecord` / `StateHeader.previousRound` / `beginNextRound(previous:)` / `clearSnapshotMembers()` | ✅ |
| `Sources/ResidueCore/ObservationWriteback.swift` | ⑦ 未达标自动开下一轮 | ✅ |
| `Sources/ResidueCore/PageModelBuilder.swift` | `unmetNoticeText` 改调 / `previousRoundSlot` 条件 / `reportRow` 改调 | ✅ |
| `Sources/ResidueCore/PageModel.swift` | 注释（1 行：「仅轮次 ≥ 2 时非 nil」→「存在上一轮结算记录时非 nil」） | ✅ |
| `Sources/ResidueApp/DesignSampleData.swift` | 同步新签名 | ✅ |

> 旧 `UICopy.previousRound(round:)` 全仓已无残留（`grep -rn "previousRound(round:" Sources/ Tests/` ⇒ 0 命中）。

### 10.2 测试改动

| 文件 | 用例 | 状态 |
|---|---|---|
| `Tests/ResidueCoreTests/ObservationWritebackTests.swift` | 新增：开轮 / `a` 保留 / 不取快照 / 结算扫描不计入新轮 / 仅 `a ≠ 0` 不开轮 | ✅ |
| `Tests/ResidueCoreTests/SemanticSlotTests.swift` | 改写 `testPreviousRoundCopyIsPrefixNumeric` / `testThreeRoundCopiesAreIsomorphic`；新增四要素逐字断言 | ✅ |
| `Tests/ResidueCoreTests/PageModelBuilderTests.swift` | 改写 `makeHeader` / `testPreviousRoundOnlyFromRoundTwo`；新增 TC-045 ① ③、TC-054 断言 | ✅ |
| `Tests/ResidueCoreTests/StateFileTests.swift` | 新增：旧载体解码为 `nil` / 新载体往返保真 | ✅ |
| `Sources/ResidueApp/WiringSelfCheck.swift` | 新增「4a3 · CR-033 未达标自动开下一轮」段（**真 IO 往返**，28 条断言） | ✅ |

> ⚠️ **接线自检 §4a2 段（CR-031 结算链）因本单新语义而改造** ——
> 详见 §10.4 偏差 ⑦。App 层**无单测**（`Tests/` 只覆盖 `ResidueCore`），
> 接线自检是这一层**唯一**的防线 ⇒ 改造方式是**换场景**（候选 2 → 31），
> **不是弱化断言**。

### 10.3 校验实跑结果

| 校验 | 命令 | 结果 |
|---|---|---|
| 单测 | `swift test` | ✅ 459 个用例，0 失败（退出码 0） |
| 页面结构 / 界面禁算术 | `./scripts/verify_a9.sh` | ✅ 通过 80 项 / 失败 0 项 |
| 错误码表 | `python3 scripts/verify_codes.py` | ✅ 通过 11 项 / 失败 0 项 |
| 接线自检 | `swift run --disable-sandbox ResidueApp --verify-wiring /tmp/wiring` | ✅ 通过 111 项 / 失败 0 项（退出码 0） |
| PRD 基线 | `./tests/contract/check_all.sh` | ✅ 全部通过（末段「通过 47 项」，退出码 0） |
| R2 基线 | `python3 tests/contract/verify_r2.py` | ✅ 全部通过（结构 30 + 落地 65 + 归零 16 + 一致 10 + 自洽 2，退出码 0） |
| Release 编译 | `swift build -c release` | ✅ 退出码 0（`Build complete!`） |
| 设计稿重渲染 | `swift run --disable-sandbox ResidueApp --render-pages design-renders` | ✅ 共渲染 16 张；10 张内容变更（`01 / 03 / 05 / 06 / 07 / 08 / 09 / 10 / 12 / 15`），其余 6 张不变 |

### 10.4 偏差登记（7 条）

> 均为实现过程中与本单原稿的偏离，**逐条写实**，供评审裁决。

| # | 偏差 | 原因 |
|---|---|---|
| ① | 旧 `UICopy.previousRound(round:)` 的删除**从步骤 8 推迟到步骤 9** | 步骤 8 要先写新串的逐字断言（RED），但新串依赖 `PageModelBuilder` 的调用点改造（步骤 9）⇒ 顺序对调 |
| ② | `PageModelBuilderTests.makeHeader` 的 `previousRound` 参数化**从步骤 10 提前到步骤 9** | 步骤 9 的 ⑤ 页四要素行断言需要能造出「有上一轮记录」的基线 ⇒ 参数必须先就位 |
| ③ | `DesignSampleData` 的 `settledAt` 用**本地日历日**（2023-11-14）而非 §3.8 字面的 `Date(timeIntervalSince1970: 1_700_000_000)` | 后者在 UTC+8 渲染成 **2023-11-15**，与设计稿预期的日期不符 ⇒ 改用本地日历日构造（2023-11-14 00:00 本地时区） |
| ④ | `makeHeader` 的 `previousRound` 默认保持 `nil` | 默认给非 `nil` 会让**所有**用 `makeHeader` 的用例都进入「有上一轮记录」分支 ⇒ 基线被污染；`nil` 才是「首轮」的自然默认 |
| ⑤ | 步骤 11（载体往返测试）**首次即绿** | 该行为是合成 `Codable` + `decodeIfPresent` 的**既有能力**（新增字段走同一条路径）⇒ 测试是**回归锁定**而非新功能。**已用破坏性变异证明该用例可被抓到**（把 `previousRound` 从编码里去掉 ⇒ 往返保真用例红） |
| ⑥ | R2 新版**首行标题写 `v1.10`**，而 v1.1–v1.9 的文件首行标题**未随版本更新**（v1.7–v1.9 都写 v1.7） | 沿用历史惯例会与「文档基线校验的自动版本发现」冲突；本单选择**新文件写自己的版本号**，**不回改历史文件**（历史文件是当时决策的记录） |
| ⑦ | **接线自检 §4a2 段（CR-031 结算链）因本单新语义而改造**：候选数 2 → 31，期望值随之改写；并**新增 §4a3 段**（28 条断言）守本单的开轮语义 | **本单引入「结算未达标 ⇒ 自动开轮」⇒ 同一次扫描里结算值被清零** ⇒ 原 §4a2 场景（`K = 1 < H = 2` ⇒ 未达标 ⇒ 开轮 ⇒ 结算值当场被清）读到的是**全 `nil`** ⇒ 9 条结算断言 + 1 条报告行断言全红。**根因不是结算写入路径坏了，是自检场景与新语义冲突**。<br>⚠️ **关键约束**：`H = min(30, T)`、`K ≤ T` ⇒ 达标必有 `K = T` ⇒ `J = 0`；而 `J > 0` ⇒ `K < T` ⇒（`T ≤ 30` 时）`K < H` ⇒ 未达标 ⇒ 必开轮 ⇒ 结算值必被清。⇒ **「失联 `J > 0` 覆盖」与「结算值留在载体上」不可兼得**。<br>**破局**：取 `T = 31` ⇒ `H = 30`（阈值封顶）⇒ `K = 30 ≥ H = 30` ⇒ **达标 ⇒ 不开轮** ⇒ 结算值留在载体；同时 `J = 31 − 30 = 1 > 0` ⇒ 失联覆盖也保住。**31 是最小可行候选数**。<br>**不得弱化断言**：App 层无单测，接线自检是唯一防线 ⇒ 改造方式是**换场景**（`T = 31`）**+ 新增独立场景**（§4a3）**+ 补「达标 ⇒ 不开轮」三条断言**（否则「读到 `nil`」既可能是「结算没写」也可能是「写完又被开轮清掉」⇒ 无法区分 = 假绿）。 |

### 10.5 防假绿验证（破坏性变异）

> 新断言必须**可被抓到**，否则与恒真断言无异。逐条做了临时变异，验证后**已全部撤除**
> （`grep -rn "MUTATION" Sources/` ⇒ 0 命中）。

| # | 临时变异 | 期望抓到 | 实跑 |
|---|---|---|---|
| 1 | `StateHeader.beginNextRound(previous:)` 里加 `sources[index].a = 0` | 「开轮**不清零** `a`（实为 7）」红 | ✅ 红（通过 110 / 失败 1） |
| 2 | `SourcePayload.clearSnapshotMembers()` 里连 `bitmap` / `slots` / `countedDoneSlots` 一起清 | 载体解码失败 ⇒ 读不到载体 | ✅ 红（通过 88 / 失败 1） |
| 3 | 写回层 ⑦ 开轮处同时清载荷 `bitmap` / `slots` 与文件头 `slotCount`（使解码仍可通过） | 「`slotCount` = 2」与「`F` 位图置位数 = 2」两条**精确**红 | ✅ 红（通过 109 / 失败 2，实为 0 / 0） |

> 变异 2 的失败位置偏「早」（解码阶段就挂），变异 3 才是对**两条载体保留断言**的精确验证 —— 两者都做，缺一不可。

