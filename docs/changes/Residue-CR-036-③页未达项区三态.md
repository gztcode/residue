# CR-036 · ③ 页未达项区三态（有未达项 / 无未达项 / 空判定域）· P0 · 无未达项被显示成「未达项读取中」，且空判定域时仍列全局项

> **缺陷**：
> - ③ 页开关区的未达项区在「未达项集合为空」时渲染兜底串 **「未达项读取中」**（`ResidueApp/Sources/ResidueApp/Pages.swift:299-300`）。未达项是**同步算出来的**（`GateEvaluator.unmetItems` 是纯函数，无异步加载、无 IO）⇒「读取中」是一个**不存在的状态**；界面在陈述一件没发生的事。
> - **现实路径**下判定域为空时，③ 页仍列出 **1 行全局项**（第 N 轮 · 观察期 x/14 天）⇒ 违 DAC-79「判定域为空时…**不列出任何未达项**」与 PRD AC-08 组 A 判定③「**不列出任何未达项**」。
> - 兜底串「未达项读取中」**落不进任何一处封闭枚举**：不是 AC-08 组 A 的全局项（唯一一种）、不是 DAC-75 封闭的三类来源项、不是 DAC-79 封闭的两串空类成因 ⇒ 属自造文案。
> - 现有单测 `PageModelBuilderTests.testEmptyDecisionDomainProducesNoUnmetRow`（`ResidueApp/Tests/ResidueCoreTests/PageModelBuilderTests.swift:317`）用 `produced: true` 构造输入 ⇒ 现实路径（空判定域 ⇒ 报告**不可能**产出）**从未被覆盖** ⇒ **测试把 bug 当成了规格**（CLAUDE.md §七坑 5 同类问题）。
> **契约依据**：PRD v5.6 :1278〔CR-010 · 建议 G7 · 空域成因三项〕/ :1274〔§8 前言〕/ :1200〔判定域为空时开关区按 §8「空」类三项枚举呈现〕/ :1053〔AC-08 组 A Given · 符号前言 · 判定用例③〕；DAC v2.0 :248 ~ :254〔DAC-74 ~ DAC-80〕/ :338 / :347 / :377 / :450 ~ :490〔异议栏 #74 ~ #80〕；B1 v1.0 TC-027 / TC-028 / TC-038；R2 v1.10 §25.1 裁定一。
> **性质**：**功能缺失 + 实现错误**（双类 —— ①「无未达项」这个态**根本没实现**，界面用自造串顶替；② 空判定域时**多列了一行**，与契约相反）
> **状态**：**待实现**（变更单先行；代码落地须按 §八 TDD 步骤）
> **修订记录**：
> - **v1 · 2026-11-18**：初稿。逐条核实 DAC-74 ~ DAC-80、PRD AC-08 组 A 与 §8 的契约原文及代码落点行号；列出 §九 待裁决 3 条（**均给出建议方案**，不阻塞起草）。取证期间发现并登记两处**契约内部歧义**（§2.7）。

---

## 一、缺陷

### 1.1 现象

③ 页（清理策略配置）开关区里，「未达项」那一格有三种可能的显示，现状只有一种实现，且那一种实现**两种情况下都是错的**：

| 实际语义 | 现状显示 | 是否正确 |
|---|---|---|
| 判定域非空、确有未达项 | 逐行列出未达项 | ✅ |
| 判定域非空、无未达项 | **「未达项读取中」** | ❌ 语义不存在 |
| 判定域为空（扫过但判定域内无候选） | **1 行全局项**（第 N 轮 · 观察期 x/14 天） | ❌ 违 DAC-79 |

### 1.2 复现路径（代码级）

**路径 A —— 兜底串「未达项读取中」**

`ResidueApp/Sources/ResidueApp/Pages.swift:299-300`：

```swift
if model.unmetNotices.isEmpty {
    SemanticSlotView(slot: .text(L.pick("未达项读取中", "Loading unmet items")), muted: true)
} else {
    ForEach(model.unmetNotices.indices, id: \.self) { index in
        SemanticSlotView(slot: model.unmetNotices[index])
    }
}
```

这串文案还**不是** `UICopy` 的一部分 —— 它是**直接写死在视图里的 `L.pick`**（CLAUDE.md §五「新增/修改界面文案 → 改 `UICopy`」的纪律在此处已被绕过）。

而 `unmetNotices` 的来源是 `ResidueApp/Sources/ResidueCore/PageModelBuilder.swift:238-241`：

```swift
model.unmetNotices = unmetNoticeSlots(unmet, progress: progress, previous: header.previousRound)
```

`unmetNoticeSlots`（`PageModelBuilder.swift:449-498`）是**纯格式化函数**，输入 `UnmetItems` 是 `GateEvaluator.unmetItems`（`Metrics.swift:647`）的返回值 —— 一次同步调用，**没有 IO、没有 await、没有加载态**。

⇒ **「未达项读取中」描述的状态在实现里根本不存在。** 它是一句自造的兜底文案，出现在界面上等于告诉用户「数据马上就来」，而数据其实**已经在屏幕上了**（只是集合为空）。

**路径 B —— 空判定域时多列一行**

判定域的唯一来源是 `PageModelBuilder.swift:229-233`：

```swift
let decisionDomain = DecisionDomain.members(
    snapshotSources: Set(header.sources.filter { $0.snapshotTaken }.map { $0.source }))
```

判定域 = **本轮观察期开始快照内命中的来源**。而快照的取得条件在 `ResidueApp/Sources/ResidueCore/ObservationWriteback.swift:169-173`：

```swift
let wantsSnapshot = input.succeeded
    && input.mode == .full
    && source.isInDecisionDomain
    && !entry.snapshotTaken
    && !current.isEmpty          // ★ 本轮候选为空 ⇒ 永远拿不到快照
```

⇒ **判定域内的来源若本轮一个候选都没有，就永远拿不到快照 ⇒ 判定域必为空。**

再看报告凭证（`ObservationWriteback.swift:225-228`）：

```swift
if !settledSources.isEmpty {
    header.settlement.producedAt = input.now
    header.settlement.reportId = reportID(round: header.round, now: input.now)
}
```

结算（`ObservationWriteback.swift:190-197`）要求 `entry.snapshotTaken` ⇒ 判定域为空 ⇒ **没有任何来源能完成结算** ⇒ `producedAt` 永不写 ⇒ `settlementProduced == false`。

而 `GateEvaluator.unmetItems`（`Metrics.swift:647`）在 `settlementProduced == false` 时：

```swift
if !settlementProduced || !progress.isDayQuotaReached {
    global = .observationUnfinished
}
var items: [UnmetSourceEntry] = []
guard settlementProduced else {
    return UnmetItems(global: global, bySource: items)   // ★ 只剩全局项
}
```

⇒ **现实路径的空判定域 ⇒ `unmetNotices` 恰好 1 行（全局项）** ⇒ DAC-79 要求的是 **0 行 + 一串空类成因**。

**为什么现有测试没抓住** —— `PageModelBuilderTests.swift:317` 的 `testEmptyDecisionDomainProducesNoUnmetRow`：

```
makeHeader(round:countedDays:produced:autoDelete:entries:previousRound:)  // 默认 produced: true
```

默认 `produced: true` ⇒ `settlementProduced == true` ⇒ `global == nil` ⇒ 未达项集合为空 ⇒ 测试断言 `count == 0` 通过。**但现实路径的 `produced` 恒为 `false`**（上面已证）⇒ **测试造了一个现实里不存在的输入**，于是 bug 完好无损地留在代码里。

> 这正是 CLAUDE.md §七坑 5 说的那一类：**原测试按错误方向写断言 ⇒ 测试把 bug 当成了规格。**

### 1.3 第二个后果 —— 空域时「为什么不能点亮」不可读

用户点不开自动删除开关时，③ 页必须告诉他**还差什么**（AC-08 组 A 的存在意义）。判定域为空时，真相是「**根本没有可回收的东西**」（不是「样本还不够」）—— 但现状显示「第 1 轮 · 观察期 0/14 天」，用户会去等 14 天，而实际上**等 14 天也不会有候选**。

这是一个**误导性引导**：把「无物可回收」显示成「需要再观察 13 天」。

### 1.4 与其它单的关系

| 单号 | 关系 |
|---|---|
| CR-034 | CR-034 §10.4 偏差②「删除『已达达标条件』文案」时**明确登记**「无未达项态需另开变更单」⇒ **本单承接该项**。CR-034 已落地「来源标识 / 类名 / 四数齐 / 追加句 / 多行承载」，但**没有**覆盖「一行都没有」与「判定域为空」两种情形。 |
| CR-035 | ⑤ 页 ③ 列补失联 `J`（CR-034 预留）⇒ 与本单**无耦合**，`J` 的补齐不改变判定域口径。 |
| DAC-80 违例 | ① 页首启空态文案「还没有扫描过」—— **不在本单范围**（§六.1 登记）。它与本单**共用**「无可扫描来源 / 无清理候选」两串，但**语义位不同**（① 页首启空态 vs ③ 页未达项区），且① 页空态的判据是 `isFirstRunEmpty`（`PageModelBuilder.swift:189`），与判定域空**不是同一个概念**。 |

---

## 二、契约依据

### 2.1 DAC-74 ~ DAC-80（`docs/contract/Residue-DAC-v2.0.md:248-254`，逐字）

| 编号 | 判据（逐字） | 容差 | 判定方式 |
|---|---|---|---|
| **DAC-74**（`:248`） | 未达项**两级分行**（全局项不带来源只列一次；来源项带来源标识、按判定域顺序分组、一项一行）；全局项最前、来源项在后 | 结构完全一致（0 容差） | 数行数；读首行有无来源名；核对顺序 |
| **DAC-75**（`:249`） | 来源项取值**逐串点名封闭为三串**：`样本不足` / `L0 误判` / `L0 未判定（无法枚举本用户进程）`。**出现第四种未达项类即不通过** | 三串逐字完全一致 | 读行 |
| **DAC-76**（`:250`） | `样本不足` 行的基数形态为**四数齐**：`样本 <K> / 总量 <T>（门槛 <H>，其中失联 <J>）`；且**在其后追加逐字句**「失联不补足，下一轮以新快照重算」 | 四数 4/4；追加句逐字 0 | 数四数；读追加句 |
| **DAC-77**（`:251`） | ③ 页开关区有**独立「剩余天数」格**（形如 `剩余 N 天`；计数日已满而报告未产出时为 `—`），与未达项**同址相邻但不同格**，**不得合并进未达项那一句** | 独立元素 0 容差；`—` vs `0 天` 逐字 | 数格 |
| **DAC-78**（`:252`） | `样本不足` 与 `L0 误判` **同时成立时分行两项**（两行），**不合并成一项**；「因存在 L0 误判，本版本不再提示可点亮进度」作为**附加说明**附在 `样本不足` 行后，不单独成未达项 | 2 行（0 容差） | 数行 |
| **DAC-79**（`:253`） | 判定域为空时 ③ 页开关区呈现 §8 空类**成因之一**，取值逐串点名 ∈ {`无可扫描来源`, `无清理候选`}；且**不列出任何未达项** | **二串之一（逐字）；未达项行数 = 0** | 造空域，读成因串；数未达项行 = 0 |
| **DAC-80**（`:254`） | **① 页空态文案**取值逐串点名 ∈ {`无可扫描来源`, `无清理候选`, `观察期尚无数据`} **三串之一**。**出现第四成因即不通过**（例：「还没有扫描过」是自造第四成因，§8 空类无此项） | 三串之一（逐字） | 读串 |

**DAC-79 的依据列逐字**：「AC-08 组 A 判定③『按空域实际成因呈现 §8「空」类对应义项…不列出任何未达项』+ §8 空（三成因封闭）」。

> ★ **DAC-79 是本单的第一号依据**：它同时规定了**要显示什么**（二串之一，逐字）与**不要显示什么**（未达项行数 = 0）。现状两条**都不满足**。

### 2.2 PRD AC-08 组 A（`docs/contract/Residue-PRD-v5.6.md:1053` 起，逐字）

**符号前言**：

> `K` / `T` / `J` 只在 AC-09 报告产出后存在——观察期内不展示、不判定这三个量（**观察期内第 ③ 页只展示观察期天数**）。

**Given**：

> **组 A（未达线 · 反向）** — Given **判定域可空**；**判定域非空时**，对判定域内每个来源分别判定，存在任一项未达。

**未达项分两级**：

> **其定义 = 观察期结束扫描尚未成功完成**（含两种成因：本轮计数日 < 14；或第 14 个计数日后的扫描尚未成功完成、报告未产出）——**两种成因合为同一个未达项，不另设状态**

**Then（要点逐字）**：

> **固定顺序 = 全局项在前、来源项在后** / **不展示剩余条数** / **全局项不带来源、只列一次**（形如「第 1 轮 · 观察期 9/14 天」）/ **一项一行、逐行独立** / `样本不足` 与 `L0 误判` 同时成立时，**两项分行列出**，归因文字作为**附加说明**附在 `样本不足` 行之后……**不合并成一项**

**判定（用例③逐字）**：

> **③ 空判定域**：判定域为空 → **本组不适用**，开关 disabled、**按空域实际成因呈现 §8「空」类对应义项**（无可扫描来源 → 「无可扫描来源」；有来源但无候选 → 「无清理候选」）、**不列出任何未达项**；本用例对本条「两件信息均可见且文本非空」作**显式豁免**

### 2.3 PRD §8 空类（`:1278`，逐字）

> **〔CR-009 · 空域成因分界〕`无可扫描来源` 仅当枚举来源的只读定位成功且无缓存目录；CLI 缺失或探测失败一律归「错误」、空态不出现。** **〔CR-010 · 建议 G7〕空域成因三项**（枚举封闭，逐字取一）：①「无可扫描来源」= 枚举来源的只读定位**成功**且无缓存目录；②「无清理候选」= 定位成功但**判定域内**（`uv` cache / `npm/_npx`）无候选（**仅 `pipx` run 有候选时归此项**——判定域为空但页面有候选，不归①）；③「观察期尚无数据」本期无实例。**CLI 缺失或探测失败一律归「错误」、空态不出现**。**无可扫描来源 / 无清理候选 / 无执行日志 / 观察期尚无数据**（〔CR-008 · K-8〕本期无实例——当前两类来源均无 L2 观测通道，该义项为定义保留，供未来具备通道的来源使用；不得据此认为本期存在该空态）。**〔R1-18〕** 与 AC-01 适用不同 Given：空态为未约束扫描范围内存在物料时的另一路径，显式标注，不与「三区块非空」相反。

**§8 前言（`:1274`，逐字）**：

> 「『本期无实例』的状态义项只作定义保留、**不进本期设计交付与验收**（当前唯一一处：`空` 类的「观察期尚无数据」，因两类来源均无 L2 观测通道；CR-008 · D5-5）」

⇒ **本单只用三串中的前两串**（「观察期尚无数据」本期无实例，不落）。

### 2.4 PRD 观察期判定与归零规则小节（`:1200`，逐字）

> 「判定域为空时，开关区按 §8「空」类**三项枚举**呈现（无可扫描来源 / 无清理候选〔判定域内无候选；仅 `pipx` run 有候选时归此项〕/ 观察期尚无数据本期无实例），且开关保持 disabled——**AC-08 组 A / 组 B 在空域上均不适用、不判为达标**（组 B 的全称量词在空集上恒真，不显式排除会被读成「可点亮」，CR-008 · G-2）；不新增未达项、不改「三类未达项」」

### 2.5 PRD AC-09 两条约束（与空态文案相邻，同源）

> ⑦ `结论` ∈ {达标 / 未达标 / 仅报告} 且无空值；〔CR-019 · B18〕取值优先级「② 空判定域 → 「否（判定域内无来源）」」
> 〔CR-010 · R1 · B4〕「空判定域时本行取「否（判定域内无来源）」、不填来源名」

⇒ 空判定域在**报告行**上已有明确口径（「否（判定域内无来源）」），**开关区**的对应口径就是 DAC-79 的两串。

### 2.6 DAC 其它相关行（逐字）

| 位置 | 内容 | 与本单的关系 |
|---|---|---|
| `:60` | AC-08 汇总行：「DAC 齐·现状缺」——两级分行 ✓、剩余天数格 ✓、三串取值 ✓；但 `样本不足` 四数齐 + 追加句缺、① 空态文案为自造第四成因 | 现状缺口的官方登记 |
| `:72` | AC-20 汇总行：「DAC 齐·现状缺（加载态**无渲染**）」 | 属 CR-037，不在本单 |
| `:244` | §4.3 标题「③ 未达项与空态 · AC-08（DAC-74 ~ DAC-80）」 | 本单的判据段 |
| `:338` | 「**加载态**由 DAC-105 覆盖结构要素；**空态**由 DAC-80 覆盖成因枚举」 | 空态归属 DAC-80（① 页），本单管的是 ③ 页未达项区（DAC-79） |
| `:347` | 逐字验例外清单，含 DAC-75/76/80，**不含**「无未达项」 | ⇒ 「无未达项」**不在**逐字验例外清单内 ⇒ 本单新增它时**不受**该例外保护，须自带逐字判据 |
| `:377` | 新增项清单，列 DAC-74~106 | DAC-79 已在册 |

**DAC 异议栏 `:450-490`（逐字，与本单直接相关）**：

> `| 79 | 若空域还出现第三种成因（如「观察期尚未开始」），两串封闭过窄 |`
> `| 80 | 若「还没有扫描过」被产品追认为第四成因并写进 §8，我判它不通过就错了——**判据本身要求 §8 先改** |`

> `| 74 | …全局项不带来源… |` / `| 75 | …三串封闭… |` / `| 76 | …追加句… |` / `| 77 | …剩余天数另设一格… |` / `| 78 | …不合并… |`

⇒ 异议 #74 ~ #78 **全部支持**本单方向（分级分行 / 封闭取值 / 独立格）；异议 #79 说明**空类成因只允许两串**（若要第三串，判据本身要改）⇒ 本单**不得**在 ③ 页引入第三串。

### 2.7 ★ 契约内部歧义登记（本单的裁决依据）

**歧义 A —— DAC-79 的「判定域为空」包含「从未扫描过」这一支吗？**

| 出处 | 写法 | 性质 |
|---|---|---|
| DAC-79（`:253`） | 「判定域为空时 ③ 页开关区呈现 §8 空类**成因之一**……且**不列出任何未达项**」 | 无「已扫描过」的前置条件 |
| PRD §8（`:1278`） | ①「无可扫描来源」= 枚举来源的只读定位**成功**且无缓存目录 | 成因①的**前提是定位跑过** |
| PRD AC-08 组 A 判定③（`:1053`） | 「无可扫描来源 → 「无可扫描来源」；有来源但无候选 → 「无清理候选」」 | 同样隐含「定位跑过、有来源」 |
| 实现 | 判定域 = `header.sources.filter { $0.snapshotTaken }` | **从未扫描 ⇒ 无快照 ⇒ 判定域机械为空** |

**裁决**：**判据的前提（定位跑过）必须来自实现侧的事实**（`header.lastScanAt != nil`），不能由「判定域为空」反推。理由：

- 「判定域为空」有两种截然不同的成因：**① 已确定为空**（扫过、定位成功、域内确实没候选）；**② 尚未知**（从没扫过 ⇒ 连快照都不存在）。判据写的是前者，实现撞上的是后者。
- 把 ② 说成「无可扫描来源」= **把未知说成已知**，违 CLAUDE.md 不变量③（`nil ≠ 0`）。
- 因此本单**四态**（§三 3.3），态④（从未扫描）**保留全局项**，不进 DAC-79 的 Given。

> ★ 这一条与 DAC 异议 #79 是一致的：DAC 允许的是**两串**封闭的成因，不允许自造「尚未知」第三串。

**歧义 B —— §8 ①「无缓存目录」的判据用什么载体表达？**

| 出处 | 写法 | 性质 |
|---|---|---|
| PRD §8（`:1278`） | ①「无可扫描来源」= 定位成功**且无缓存目录**；②「无清理候选」= 定位成功但**判定域内**无候选 | ①判**目录存在性**，②判**候选集合** |
| PRD AC-08 组 A 判定③ | 「无可扫描来源 → 「无可扫描来源」；**有来源但无候选** → 「无清理候选」」 | 措辞偏向**候选集合** |
| 实现 | `PageModelBuilder.Input` **无「来源根存在性」字段**；`input.candidates.isEmpty` 把「目录不存在」与「目录存在但为空」**塌缩成同一个信号** | 载体缺失 |

**裁决**：本单采用**候选集合近似**（`input.candidates.isEmpty` → ①；否则 → ②），理由：

1. 候选集合是 `Input` 里**已存在**的字段，判定可直接完成，不动 App 层 IO 编排（外科手术边界，§三 3.11）。
2. **载体来源已定位**：`ResidueApp/Sources/ResidueApp/AppModel.swift:564` 的 `guard FileManager.default.fileExists(atPath: root) else { continue }` 知道每个来源根是否存在，但 `resolveSourceRoots`（`ResidueApp/Sources/ResidueApp/ScanInfrastructure.swift:167+`）**只回路径、不回存在性** ⇒ 要逐字贴合 §8 ①，需要新增一个载体并回传 ⇒ 属另一件事（§九 待裁决 #2 建议另开变更单）。
3. 近似口径在**两种现实情形下都给出正确成因**：机器上三个缓存目录都没 ⇒ 「无可扫描来源」；只有 `pipx` 有 ⇒ 「无清理候选」。

**待补判据（DAC-79 从没验过）**：DAC-79 的判定方式是「造空域，读成因串；数未达项行 = 0」—— **本单必须补上「读成因串」的逐字断言**（现有测试只数行数，从不读串）。见 §八 步骤 6。

---

## 三、改什么

### 3.1 新增载体（Core · 封闭枚举）

新建 `ResidueApp/Sources/ResidueCore/UnmetSection.swift`：

```swift
/// ③ 页未达项区的**唯一事实源**（封闭枚举）。
///
/// 守不变量①（界面禁止算术）：界面拿到的是**已算好的**槽位或**已定好的**成因，
/// 界面上不出现任何分支判定。
public enum UnmetSection: Sendable, Equatable {
    /// 有未达项：全局项在前、来源项在后，**一项一行**（AC-08 组 A / DAC-74）。
    case rows([SemanticSlot])
    /// 无未达项：判定域非空，但未达项集合为空（**契约空白 · 本单新立**）。
    case none
    /// 判定域为空：呈现 §8 空类成因之一，**不列出任何未达项**（DAC-79）。
    case emptyDomain(EmptyDomainCause)
}

/// §8 空类成因（本期只落两串 · DAC-79 封闭 / 异议 #79）。
public enum EmptyDomainCause: Sendable, Equatable {
    /// 「无可扫描来源」—— 定位成功但**页面上一个候选都没有**（近似口径见 §2.7 歧义 B）。
    case noScannableSource
    /// 「无清理候选」—— 页面有候选，但**判定域内**没有（仅 `pipx` run 有候选时归此项）。
    case noCleanupCandidate
}
```

> ★ **不新增 `SemanticSlot` case** —— `SemanticSlot` 恒为 7 个 case（`text` / `metric` / `ratio` / `duration` / `stateLabel` / `unavailable` / `permissionBlocked`），守不变量①（§六.2）。

### 3.2 `PageModel` 改动：`unmetSection` 为唯一事实源，`unmetNotices` 改派生

`ResidueApp/Sources/ResidueCore/PageModel.swift:184`：

```swift
/// 未达项区（**唯一事实源** = `unmetSection`）。
public var unmetSection: UnmetSection = .rows([])

/// 未达项**行**（派生自 `unmetSection`）。
///
/// 只有 `.rows` 有行；`.none` 与 `.emptyDomain` 一律为空数组 —— 于是
/// 「未达项行数」有一个**单一可数口径**（DAC-79 的「未达项行数 = 0」就是它）。
public var unmetNotices: [SemanticSlot] {
    if case .rows(let slots) = unmetSection { return slots }
    return []
}
```

> `PageModel` 是 `Sendable`（`:73`），不实现 `Equatable`/`Codable` ⇒ 派生属性不引入协议一致性负担。

### 3.3 四态判据链（落在 `PageModelBuilder` 的呈现分派层）

**不动 `GateEvaluator` 的判定逻辑** —— 判定域、全局项、来源项的**判定**本身全部正确（`GateEvaluator.unmetItems` 在空域时返回 1 行全局项是**符合它自己的职责**的：它只回答「有没有未达项」，不回答「这一屏该显示什么」）。**丢弃全局项是呈现层的态分派** ⇒ 不变量②（同一判定只有一个实现处）仍成立。

`ResidueApp/Sources/ResidueCore/PageModelBuilder.swift:234-241` 改为：

```swift
let unmet = GateEvaluator.unmetItems(progress: progress, settlementProduced: settlementProduced,
                                     decisionDomain: decisionDomain, sources: gateInputs)

if decisionDomain.isEmpty {
    if header.lastScanAt == nil {
        // 态④：从未扫描过 —— 判定域是「尚未知」而不是「已确定为空」
        //       （§2.7 歧义 A）⇒ 保留全局项，不显示空类成因。
        model.unmetSection = .rows(unmetNoticeSlots(unmet, progress: progress, previous: header.previousRound))
    } else {
        // 态③：扫过、判定域为空 ⇒ §8 空类成因，**不列出任何未达项**（DAC-79）。
        //       成因判据 = 页面上有无候选（§2.7 歧义 B 的近似口径）。
        model.unmetSection = .emptyDomain(
            input.candidates.isEmpty ? .noScannableSource : .noCleanupCandidate)
    }
} else if unmet.isEmpty {
    // 态②：判定域非空、报告已产出、观察期已满，但无任何未达项行。
    model.unmetSection = .none
} else {
    // 态①：有未达项（全局项在前、来源项在后）。
    model.unmetSection = .rows(unmetNoticeSlots(unmet, progress: progress, previous: header.previousRound))
}
```

**四态判据表**（本单的规范表述）：

| 态 | 条件 | `unmetSection` | 界面呈现 | 未达项行数 |
|---|---|---|---|---|
| ① 有未达项 | 判定域非空 ∧（报告未产出 ∨ 观察期未满 ∨ 存在来源项） | `.rows([...])` | 逐行列出（全局项在前、来源项在后） | ≥ 1 |
| ② 无未达项 | 判定域非空 ∧ 报告已产出 ∧ 观察期已满 ∧ 无来源项 | `.none` | 「无未达项」（静态一行） | **0** |
| ③ 空判定域 | 判定域空 ∧ `lastScanAt != nil`（扫过） | `.emptyDomain(cause)` | 「无可扫描来源」/「无清理候选」 | **0** |
| ④ 从未扫描 | 判定域空 ∧ `lastScanAt == nil` | `.rows([全局项])` | 第 N 轮 · 观察期 0/14 天（现状不变） | 1 |

### 3.4 空域成因判据的口径（须逐条记死）

- 判据落点是 **`input.candidates`**（**全部候选**，含判定域外的 `pipx`），**不是** `visibleCandidates`（白名单过滤后的集合）—— 因为**判定域**是由快照算出来的，而快照用的是**未过滤**的候选集合（`ObservationWriteback` 的 `current`）；若用过滤后的集合，两处口径会不一致。
- `input.candidates.isEmpty` ⇒ `.noScannableSource`（「无可扫描来源」）。
- `input.candidates` 非空 ∧ 判定域为空 ⇒ `.noCleanupCandidate`（「无清理候选」）—— 这正是 PRD §8 ②「**仅 `pipx` run 有候选时归此项**」。
- ★ **不使用** `model.isFirstRunEmpty`（`PageModelBuilder.swift:189`）—— 那是**① 页首启空态**的判据（`candidates.isEmpty && lastScanAt == nil`），与「空判定域」是两个概念（§一 1.4）。

### 3.5 `UICopy` 新增三串（`ResidueApp/Sources/ResidueCore/SemanticSlot.swift`）

按 CLAUDE.md §五「新增/修改界面文案 → 改 `UICopy`」，并沿用 `unmetSampleInsufficient` 的 doc 注释风格：

```swift
/// ③ 页「无未达项」静态文案。
///
/// - 场景：判定域**非空**、报告已产出、观察期已满，但未达项集合为空。
/// - ⚠️ **不得**改成「已达达标条件」：未达项为空**不等于**可点亮
///   （`a` 未判定时既无来源项、又过不了达标门槛 —— 见 §三 3.9）。
public static var unmetNone: String {
    L.pick("无未达项", "No unmet items")
}

/// §8 空类成因文案（封闭两串 · DAC-79）。
///
/// - `.noScannableSource` → 「无可扫描来源」（定位成功且页面上无候选）
/// - `.noCleanupCandidate` → 「无清理候选」（页面有候选但判定域内无）
///
/// - ⚠️ **不得**新增第三串（DAC-79 容差「二串之一」+ 异议 #79）。
public static func emptyDomainText(_ cause: EmptyDomainCause) -> String {
    switch cause {
    case .noScannableSource:
        return L.pick("无可扫描来源", "No scannable source")
    case .noCleanupCandidate:
        return L.pick("无清理候选", "No cleanup candidate")
    }
}
```

> 英文串是配套译文。DAC 的「逐串点名」以简体中文为准（README §多语言已声明「契约文档与发布说明仍以简体中文为准」）。

### 3.6 界面渲染（`ResidueApp/Sources/ResidueApp/Pages.swift:299-305`）

```swift
// 未达项区：**四项态**由 `unmetSection` 决定（CR-036）。
// - `.rows` → 逐行（全局项在前、来源项在后，一项一行 · DAC-74）
// - `.none` → 「无未达项」（静态一行，不是未达项）
// - `.emptyDomain` → §8 空类成因（**不是**未达项 · DAC-79）
VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
    switch model.unmetSection {
    case .rows(let slots):
        ForEach(slots.indices, id: \.self) { index in
            SemanticSlotView(slot: slots[index])
        }
    case .none:
        SemanticSlotView(slot: .text(UICopy.unmetNone), muted: true)
    case .emptyDomain(let cause):
        SemanticSlotView(slot: .text(UICopy.emptyDomainText(cause)), muted: true)
    }
}
```

> ★ 旧的兜底串「未达项读取中」**在本单移除**（它是缺陷本身）。界面里不再有任何「读取中」文案 —— 因为没有异步加载。

### 3.7 只读态复用 `.rows`（不新增第四个 case）

`ResidueApp/Sources/ResidueCore/PageModelBuilder.swift:140`：

```swift
// 只读态：不显示任何未达项行，只显示一行说明（复用 `.rows` 承载单行说明）。
model.unmetSection = .rows([.unavailable(reason: UICopy.readOnlyNoSettlement)])
```

⇒ 只读态仍是「1 行说明」，语义与判据口径不变；`unmetNotices.count == 1` 依旧成立。

### 3.8 「无未达项」**不等于**「已达达标条件」（文案不得越界）

`GateEvaluator.unmetItems` 的来源项判定是：

```swift
if let a = input.missCount, a != 0 { … }        // ★ a == nil 时不产生来源项
else if let b = input.checkCount, b == 0 { … }
```

而 `GateEvaluator.isQualified` 要求：

```swift
guard let a = input.missCount, a == 0 else { return false }
guard let b = input.checkCount, b >= 1 else { return false }
```

⇒ **`a` 未判定（`nil`）时**：未达项集合为空（态②），但 `isQualified == false`（不可点亮）。

⇒ ★ 因此态② 的文案**只能是**「无未达项」，**不得**写成任何暗示「已达标 / 可点亮」的措辞。开关的 disabled 状态仍由 `model.canLightUp` 单独承载（`Pages.swift` 的 `TokenSwitch(enabled: model.canLightUp && !model.readOnly)`，**本单不动**）。

### 3.9 `DesignSampleData` 的连带改动（必要）

`ResidueApp/Sources/ResidueApp/DesignSampleData.swift:63`：

```swift
m.unmetNotices = [ … ]     // ❌ 存储属性已改为派生，不可赋值
```

⇒ 改为：

```swift
m.unmetSection = .rows([ … ])
```

（设计走查样张要能复现 16 张设计稿里的「③ 页 · 未达项多行」形态。）

### 3.10 导航项数同步

| 位置 | 现值 | 改为 |
|---|---|---|
| `ARCHITECTURE.md:87` | `61 份文件 / 23 个单号` | `63 份文件 / 25 个单号`（CR-036 + CR-037 两张一起加） |
| `CLAUDE.md:11` | 「`docs/` 下 140 份 `.md`」 | 「142 份」 |

### 3.11 不动的地方（外科手术边界）

| 不动 | 理由 |
|---|---|
| `GateEvaluator`（`Metrics.swift`）的**判定逻辑** | 判定是对的；本单只改**呈现分派**（§三 3.3） |
| `ObservationWriteback` | 快照 / 结算 / 计数日的写入规则不动 |
| `SemanticSlot` 的 7 个 case | 守不变量① |
| `remainingDays` 格（DAC-77） | 独立格不动；本单只改它**左边**那一格的内容 |
| `model.canLightUp` 与开关的 enabled 逻辑 | 空域下 `isQualified` 已返回 false（域空 ⇒ `guard !domain.isEmpty else { return false }`） |
| ① 页首启空态文案 | §六.1 登记为遗留 |
| PRD / R2 / 视觉基线 / DAC | **全部不改** ⇒ 不升版本号 ⇒ 契约校验脚本零改动 |

---

## 四、影响面

### 4.1 代码引用点（grep 实测）

| 文件 | 行 | 现状 | 本单后 |
|---|---|---|---|
| `ResidueApp/Sources/ResidueCore/PageModel.swift` | `184` | `public var unmetNotices: [SemanticSlot] = []`（存储） | 改为派生 + 新增 `unmetSection` 存储属性 |
| `ResidueApp/Sources/ResidueCore/PageModelBuilder.swift` | `140` | `model.unmetNotices = [.unavailable(…)]`（只读分支） | `model.unmetSection = .rows([.unavailable(…)])` |
| `ResidueApp/Sources/ResidueCore/PageModelBuilder.swift` | `238-241` | `model.unmetNotices = unmetNoticeSlots(…)` | 四态判据链分派（§三 3.3） |
| `ResidueApp/Sources/ResidueApp/Pages.swift` | `299` / `302` / `303` | 空则「未达项读取中」，否则 `ForEach` | 改为 `switch model.unmetSection` |
| `ResidueApp/Sources/ResidueApp/DesignSampleData.swift` | `63` | `m.unmetNotices = [ … ]` | `m.unmetSection = .rows([ … ])` |
| `ResidueApp/Sources/ResidueCore/SemanticSlot.swift` | — | — | 新增 `UICopy.unmetNone` / `UICopy.emptyDomainText(_:)` |
| `ResidueApp/Sources/ResidueCore/UnmetSection.swift` | — | — | **新建**：`UnmetSection` + `EmptyDomainCause` |

### 4.2 测试引用点

`ResidueApp/Tests/ResidueCoreTests/PageModelBuilderTests.swift` 共 **22 处** `unmetNotices` 断言（`:233` / `:252` / `:255` / `:278` / `:281` / `:282` / `:300` / `:309` / `:321` / `:322` / `:342` / `:344` / `:364` / `:365` / `:384` / `:386` / `:405` / `:407` / `:410` / `:432` / `:494` / `:495` / `:601`）。

⇒ **因 `unmetNotices` 保持为派生属性，这 22 处断言一行不动**（§九 待裁决 #3）。

### 4.3 声明面（数字同步）

| 位置 | 内容 | 本单后 |
|---|---|---|
| `README.md:194` | `swift test  # 472 个单测` | 按 §八 实测值改 |
| `ARCHITECTURE.md:34` / `:122` / `:136` | 472 单测 | 同上 |
| `.github/workflows/ci.yml:5` | 「472 个单测」 | 同上 |
| `.github/workflows/release.yml:211` | 「472 单测全绿」（**会贴到公开 Release 页**） | 同上 |
| `ARCHITECTURE.md:87` | 61 份 / 23 个单号 | 63 份 / 25 个单号 |
| `CLAUDE.md:11` | 140 份 `.md` | 142 份 |

> ★ `release.yml:211` 的那串数字会出现在**公开 Release 页面**上 —— 声明必须与实跑一致。`tests/contract/verify_counts.py` 会核对 CI 注释里的项数，**报红时改注释，不改实测值**。

---

## 五、附带订正

### 5.1 空域时「第 N 轮 · 观察期 x/14 天」不再出现

态③ 按 DAC-79 丢掉了全局项 ⇒ 空域下**轮次与观察期天数**在未达项区**不可见**。

- 契约要求如此（DAC-79「未达项行数 = 0」）。
- 同址相邻的 **`remainingDays` 格（DAC-77）仍然存在**，承担「还要等几天」这一层信息。
- ★ **信息损失登记**：轮次（第 N 轮）在空域下**全页不可见**。本单**不补偿**（补偿 = 在空类成因行里追加轮次 ⇒ 违反 DAC-79 的「二串之一，逐字」容差）。若将来要显示轮次，应另开载体（不在未达项区）。

### 5.2 「未达项读取中」是唯一一处绕过 `UICopy` 的界面文案

`Pages.swift:300` 直接写 `L.pick("未达项读取中", …)` ⇒ 本单移除后，`③` 页未达项区**全部文案**归 `UICopy` 管（CLAUDE.md §五的纪律回到位）。

---

## 六、不做的事

1. **① 页首启空态文案「还没有扫描过」（DAC-80 违例）—— 本单不处理。**
   - 代码位置：`ResidueApp/Sources/ResidueApp/Components.swift:387`。
   - 证据：DAC v2.0 `:254`〔DAC-80：「出现第四成因即不通过（例：「还没有扫描过」是自造第四成因）」〕、DAC `:471`〔异议 #80 实证〕、`docs/reviews/Residue-R1.5-第1轮-AC覆盖评审.md:87`〔B-12(e)：「① 页空态文案要改成 §8 的三选一，不得自造第四成因」〕、`docs/contract/Residue-旅程清单-v1.0.md:135`、`docs/contract/Residue-链路用例-v1.0.md:417` / `:452`。
   - **理由**：① 页空态与 ③ 页未达项区是**两个不同的语义位**，判据也不同（`isFirstRunEmpty` vs 判定域）；一起改会扩大影响面、且 DAC-80 的三串里含「观察期尚无数据」（本期无实例）需要单独裁决。
   - **处置**：**另开变更单**（本单在 §九 之外登记为已知遗留缺陷）。

2. **不新增 `SemanticSlot` case**（恒 7 个）—— 守不变量①。
3. **不改任何契约基线文档** —— PRD v5.6 / R2 v1.10 / 视觉基线 v1.1 / DAC v2.0 **一字不动** ⇒ 不升版本号 ⇒ 契约校验脚本零改动。
4. **不改 `GateEvaluator` 的判定逻辑** —— 空域丢全局项是呈现分派，不是判定（§三 3.3）。
5. **不补「来源根存在性」载体** —— §九 待裁决 #2 未决 ⇒ 先用近似判据（§2.7 歧义 B）。
6. **不改 ① 页首启空态、不改 ⑤ 页、不改 ⑦ 页。**

---

## 七、验收判据

逐条对应 DAC 判据（**容差 0**）：

| # | 判据 | 怎么验 |
|---|---|---|
| 1 | **DAC-79 · ①**：判定域为空且扫过 ⇒ 呈现「无可扫描来源」或「无清理候选」**之一，逐字** | 单测：造空域 + `lastScanAt != nil` ⇒ 断言字符串逐字相等 |
| 2 | **DAC-79 · ②**：判定域为空 ⇒ **未达项行数 = 0** | 单测：断言 `m.unmetNotices.isEmpty`（派生口径） |
| 3 | **DAC-79 · ③**：空域时**不列**全局项 | 单测：断言 `m.unmetSection` 是 `.emptyDomain`（**不是** `.rows`） |
| 4 | **DAC-75**：来源项取值仍**只有三串** | 现有 22 处断言不动 + 本单不新增来源项类 |
| 5 | **DAC-74**：有未达项时仍是**两级分行**、一项一行、全局项在前 | 现有断言不动（CR-034 已落地） |
| 6 | **DAC-76**：`样本不足` 行四数齐 + 追加句 | 现有断言不动（CR-034 已落地） |
| 7 | **DAC-77**：`remainingDays` 仍是**独立格**、未被合并进未达项 | 现有断言不动；本单只改未达项区左格内容 |
| 8 | **DAC-78**：`样本不足` 与 `L0 误判` 仍**分行两项** | 现有断言不动（CR-034 已落地） |
| 9 | **无未达项态**：判定域非空 ∧ 无未达项 ⇒ 呈现「无未达项」，且**不得**暗示「可点亮」 | 单测：断言 `m.unmetSection == .none` + 文案逐字 + `m.canLightUp == false`（`a` 未判定时） |
| 10 | **兜底串消失**：代码里不存在「未达项读取中」 | `grep -rn "未达项读取中" Sources/` 无命中 |
| 11 | **文案归口**：③ 页未达项区全部文案在 `UICopy` | `grep -n "L.pick" Sources/ResidueApp/Pages.swift` 的未达项区无命中 |
| 12 | **不变量①**：界面层无域内算术 | `./scripts/verify_a9.sh` 第二节 80 项全绿 |
| 13 | **不变量②**：判定仍只有一处实现处 | `GateEvaluator` 未被复制到视图层 |
| 14 | **不变量③**：未知不当成已知 | 态④ 保留全局项（不显示「无可扫描来源」）；`fraction`/`nil` 类语义不在本单 |
| 15 | **全量校验** | `swift test` / `verify_a9.sh` / `verify_codes.py` / `--verify-wiring` / `verify_a5.sh` / `check_all.sh` / `verify_r2.py` / `verify_counts.py` 全绿 |

---

## 八、TDD 步骤

> 铁律：**先写会失败的测试，看它以「功能缺失」的理由红，再写实现**（CLAUDE.md §三「目标驱动执行」+ §八「先写能复现的测试」）。
> 每步附验证方式。

### 步骤 1 —— 红：`unmetSection` 的三态分派（新增载体）

**测试**（`PageModelBuilderTests.swift`）：

1. `testUnmetSectionIsNoneWhenDecisionDomainNonEmptyAndNoUnmetItem`
   - 造：`produced: true`、`countedDays: 14`、判定域非空（`entries` 含 `snapshotTaken: true`）、域内来源 `K ≥ H` / `a = 0` / `b ≥ 1`。
   - 断言：`m.unmetSection == .none`。
2. `testUnmetSectionIsEmptyDomainWhenDecisionDomainEmptyAfterScan`
   - 造：`produced: false`（**现实路径**）、判定域空（`entries` 全 `snapshotTaken: false`）、`lastScanAt != nil`、`candidates` 空。
   - 断言：`m.unmetSection == .emptyDomain(.noScannableSource)`。
3. `testUnmetSectionIsEmptyDomainNoCandidateWhenOnlyOutOfDomainCandidates`
   - 造：同上，但 `candidates` 非空且**只有判定域外的 `pipx`**。
   - 断言：`m.unmetSection == .emptyDomain(.noCleanupCandidate)`。
4. `testUnmetSectionKeepsGlobalItemWhenNeverScanned`
   - 造：`produced: false`、判定域空、`lastScanAt == nil`。
   - 断言：`m.unmetSection` 是 `.rows` 且**含全局项**（断言行数 ≥ 1 且首行含「观察期」）。

**验证**：`swift test --filter "PageModelBuilderTests"` ⇒ **四条全红**，红因是「`unmetSection` 不存在 / 编译不过」⇒ 证明测试确实在测新东西。

### 步骤 2 —— 红：DAC-79 的**字符串断言**（从没验过的部分）

5. `testEmptyDomainCauseStringsAreExact`
   - 断言中文串逐字等于 `无可扫描来源` / `无清理候选`（两串，不多不少）。
6. `testEmptyDomainHasNoUnmetRows`
   - 断言 `m.unmetNotices.isEmpty == true`（DAC-79「未达项行数 = 0」）。

**验证**：同上 ⇒ 红。

### 步骤 3 —— 红：「无未达项」文案 + 不得暗示可点亮

7. `testUnmetNoneTextIsExact` —— 断言逐字 `无未达项`。
8. `testNoUnmetItemsDoesNotMeanQualified`
   - 造：判定域非空、`a` 未判定（`missCount: nil`）、`b ≥ 1`、`K ≥ H`。
   - 断言：`m.unmetSection == .none` **且** `m.canLightUp == false`。

**验证**：同上 ⇒ 红。

### 步骤 4 —— 绿：实现载体与判据链

- 新建 `ResidueApp/Sources/ResidueCore/UnmetSection.swift`（`UnmetSection` + `EmptyDomainCause`）。
- `PageModel`：加 `unmetSection`，`unmetNotices` 改派生。
- `PageModelBuilder`：四态判据链（§三 3.3）+ 只读分支改 `.rows`。
- `UICopy`：`unmetNone` + `emptyDomainText(_:)`。

**验证**：`swift test --filter "PageModelBuilderTests"` ⇒ 步骤 1~3 的八条**全绿**，且**现有 22 处断言全绿**（一行未改）。

### 步骤 5 —— 绿：界面与样张

- `Pages.swift`：改 `switch model.unmetSection`；移除「未达项读取中」。
- `DesignSampleData.swift:63`：改 `m.unmetSection = .rows([ … ])`。

**验证**：
- `grep -rn "未达项读取中" Sources/` ⇒ 无命中。
- `swift run --disable-sandbox ResidueApp --render-pages design-renders` ⇒ 16 张渲染产物重新生成，「③ 页 · 未达项多行」那张形态不变。

### 步骤 6 —— 防假绿验证（破坏性变异）

逐条「**临时改坏实现 → 实跑 → 看红 → 还原**」：

| # | 变异 | 期望红输出 | 被哪条判据抓住 |
|---|---|---|---|
| 1 | 空域时把全局项加回 `.rows` | 步骤 1.2 / 2.6 红 | DAC-79 ②③ |
| 2 | 空域成因判据写成 `visibleCandidates.isEmpty` | 步骤 1.3 红（白名单过滤后为空） | §3.4 口径 |
| 3 | 态④（从未扫描）也走 `.emptyDomain` | 步骤 1.4 红 | §2.7 歧义 A |
| 4 | `unmetNone` 写成「已达达标条件」 | 步骤 3.7 红 | §3.8 |
| 5 | `canLightUp` 在态② 被改成 true | 步骤 3.8 红 | 不变量③ / §3.8 |

**验证**：每条变异跑完**必须还原**（`git diff` 复核只剩预期改动）。

### 步骤 7 —— 全量校验

```bash
cd ResidueApp
swift build && swift build -c release
swift test                       # 期望：472 + 本单新增用例数 全绿（数字写进 §10.3）
python3 scripts/verify_codes.py  # 11 项
./scripts/verify_a9.sh           # 80 项
swift run --disable-sandbox ResidueApp --verify-wiring /tmp/wiring   # 111 项
./scripts/make_app.sh && ./scripts/verify_a5.sh                     # 42 项
cd .. && ./tests/contract/check_all.sh && python3 tests/contract/verify_r2.py  # 238 / 123
python3 tests/contract/verify_counts.py
```

**验证**：全部退出码 0；实跑数字填进 §10.3；**声明面数字同步**（§4.3）。

---

## 九、待裁决

> 三条**均已给出建议方案**，不阻塞起草；**实施前需裁决**。

### 待裁决 #1 —— 态④（从未扫描 ⇒ 判定域机械为空）该显示哪一串？

- **建议**：**保留全局项**（第 N 轮 · 观察期 0/14 天），**不**显示「无可扫描来源」。
- **理由**：判定域为空的唯一来源是 `snapshotTaken` 全 false；**从未扫描时连快照都不存在** ⇒ 那是「**尚未知**」（缺证据），不是「**已确定为空**」（有证据）。显示「无可扫描来源」= 把未知说成已知 ⇒ 违不变量③（`nil ≠ 0`）。PRD §8 ① 的前提「定位**成功**」在从未扫描时不成立。
- **若裁决为显示空类成因**：§三 3.3 的判据链第一分支删掉，态③④ 合并 ⇒ ③ 页在首启就显示「无可扫描来源」 ⇒ 与 DAC-80（① 页空态同名串）语义重叠，**建议否**。

### 待裁决 #2 —— §8 ①「无缓存目录」要不要补「来源根存在性」载体？

- **建议**：**本单不补**，用 `input.candidates.isEmpty` 近似（§2.7 歧义 B），**另开变更单**补载体。
- **理由**：补载体要动 `PageModelBuilder.Input`（+1 字段）与 App 层 IO 编排（`AppModel.swift:564` 的 `fileExists` 已知存在性，但 `resolveSourceRoots`（`ScanInfrastructure.swift:167+`）只回路径）⇒ 会把「呈现态分派」与「IO 编排」两件事捆在一起，超出本单的外科手术边界。
- **若裁决为补**：载体落点已定位（`AppModel.swift:564`），判据改为「所有来源根都不存在 ⇒ 无可扫描来源；存在但域内无候选 ⇒ 无清理候选」，并新增对应单测。

### 待裁决 #3 —— `unmetNotices` 是否保留为派生属性？

- **建议**：**保留**（本单采用）。
- **理由**：DAC-79 的「未达项行数 = 0」需要一个**单一可数口径**；派生属性让 22 处现有断言**一行不动**；视图改用 `unmetSection` 的 `switch` 分派后，派生属性在生产代码里只服务于「行数口径」这一件事（不是死代码）。
- **若裁决为删**：22 处测试断言需改写为对 `unmetSection` 的 `switch` ⇒ 改动面变大，收益不增。

---

## 十、实施记录

> ★ **每项都写实跑结果与数字**，不写「已完成」。
>
> **实跑环境**：macOS（darwin arm64）· SwiftPM 包根 `ResidueApp/` · 仓库根 `自动化配置/` · 分支 `gztcode/gate-link` · 基线 HEAD `dc7f813` · 实跑日期 2026-11-18。

### 10.1 代码改动

| 文件 | 改了什么 | 为什么 |
|---|---|---|
| `ResidueApp/Sources/ResidueCore/UnmetSection.swift`（**新建**，35 行） | `UnmetSection`（`.rows` / `.none` / `.emptyDomain`）+ `EmptyDomainCause`（`.noScannableSource` / `.noCleanupCandidate`）两个封闭枚举 | 空数组无法区分「没有未达项」/「没有可判定的东西」/「还没判定过」三件对用户完全不同的事（§一 1.1）；**不新增 `SemanticSlot` 的 case**（守不变量①） |
| `ResidueApp/Sources/ResidueCore/PageModel.swift` | 存储属性 `unmetNotices: [SemanticSlot] = []` → 存储属性 `unmetSection: UnmetSection = .rows([])` + **派生属性** `unmetNotices`（`.rows` 取行，其余返回 `[]`） | 真值只留一处（不变量②）；派生属性 ⇒ 既有 25 处断言与调用点**一行不动**（§九 待裁决 #3） |
| `ResidueApp/Sources/ResidueCore/PageModelBuilder.swift` | `:140` 只读分支改写为 `model.unmetSection = .rows([.unavailable(…)])`；`:243-274` 新增**四态判据链**（先判 `decisionDomain.isEmpty` → 内部分 `lastScanAt == nil` → 再判 `unmet.isEmpty` → 否则态①） | §3.3 判据表；成因判据取 `input.candidates`（**全部候选**）而不是 `visibleCandidates`（白名单过滤后）—— §3.4 |
| `ResidueApp/Sources/ResidueCore/SemanticSlot.swift` | `UICopy` 新增两串：`unmetNone`（`:349`）、「`emptyDomainText(_:)`」（`:359`，封闭两串） | §3.5；③ 页未达项区全部文案归口到 `UICopy`（§七 判据 11） |
| `ResidueApp/Sources/ResidueApp/Pages.swift` | `:302-313` 未达项区改为 `switch model.unmetSection` 三路分派（`.rows` 逐行 / `.none`「无未达项」/ `.emptyDomain` 成因串），两处非 `.rows` 分支均 `muted: true` | §3.6；**四态都是「已确定」状态** ⇒ 不得再显示「读取中」（违不变量③） |
| `ResidueApp/Sources/ResidueApp/DesignSampleData.swift` | `:63` `m.unmetNotices = [ … ]` → `m.unmetSection = .rows([ … ])` | 样张跟着真载体走（16 张设计稿重渲染后无 diff） |

### 10.2 测试改动

`PageModelBuilderTests.swift` 由 **44 条增至 53 条**（本单新增 9 条）。

| # | 新增用例 | 断言 | §七 判据 |
|---|---|---|---|
| 1 | `testUnmetSectionIsNoneWhenDecisionDomainNonEmptyAndNoUnmetItem` | `m.unmetSection == .none` | 9 |
| 2 | `testUnmetSectionIsEmptyDomainWhenDecisionDomainEmptyAfterScan` | `m.unmetSection == .emptyDomain(.noScannableSource)` | 1 / 3 |
| 3 | `testUnmetSectionIsEmptyDomainNoCandidateWhenOnlyOutOfDomainCandidates` | `m.unmetSection == .emptyDomain(.noCleanupCandidate)` | 1 / 3 |
| 4 | `testEmptyDomainCauseUsesUnfilteredCandidates` | 白名单挡掉候选后成因仍是 `.noCleanupCandidate` | §3.4 口径 |
| 5 | `testUnmetSectionKeepsGlobalItemWhenNeverScanned` | `m.unmetSection == .rows([.text("第 2 轮 · 观察期 0/14 天")])` | 14 |
| 6 | `testEmptyDomainCauseStringsAreExact` | 「无可扫描来源」/「无清理候选」**逐字** | 1 |
| 7 | `testEmptyDomainHasNoUnmetRows` | `m.unmetSection == .emptyDomain(…)` ∧ `m.unmetNotices.count == 0` | 2 / 3 |
| 8 | `testUnmetNoneTextIsExact` | `UICopy.unmetNone == "无未达项"` **逐字** | 9 |
| 9 | `testNoUnmetItemsDoesNotMeanQualified` | `m.unmetSection == .none` ∧ `m.canLightUp == false` | 9 / 不变量③ |

### 10.3 校验实跑结果

| 校验 | 实跑命令 | 实跑结果 |
|---|---|---|
| 编译（debug / release） | `swift build` / `swift build -c release` | ✅ 两者退出码 0；release 有 **3 条既有 warning**（`AppModel.swift:1105` / `ScanEngine.swift:508` / `TrashExecutor.swift:160`）—— 均为**本单未触及**的既有漂移，见 §10.6 第 3 条 |
| 单测 | `swift test` | ✅ **481 条 / 0 失败**（基线 472 + 本单新增 9） |
| 错误码表 | `python3 scripts/verify_codes.py` | ✅ 通过 **11** 项 / 失败 0 |
| 页面结构 + 界面禁算术 + 接线 | `./scripts/verify_a9.sh` | ✅ 通过 **80** 项 / 失败 0 |
| 接线自检（真 IO） | `swift run --disable-sandbox ResidueApp --verify-wiring /tmp/wiring` | ✅ 通过 **111** 项 / 失败 0 |
| 产物结构 | `./scripts/make_app.sh && ./scripts/verify_a5.sh` | ✅ `make_app.sh` 退出码 0，产出 `build/Residue.app` + `build/Residue.app.dmg`；`verify_a5.sh` 通过 **42** 项 / 失败 0 / **未覆盖 3**（未覆盖项为 A-10 发布准入：公证、ad-hoc 签名验证、FDA 人工确认 —— 非本单范围） |
| PRD 基线 | `./tests/contract/check_all.sh` | ✅ 全部通过（结构落点 191 + CR-022 47 + 声明归零 + 单一定义，合计 **238** 项） |
| R2 基线 | `python3 tests/contract/verify_r2.py` | ✅ 全部通过（结构 30 + 落地 65 + 归零 16 + 一致 10 + 自洽 2 = **123** 项） |
| 声明数字一致 | `python3 tests/contract/verify_counts.py` | ✅ 一致 **9** 项 / 不一致 0 / 未覆盖 4（未覆盖需编译/打包，本脚本不实测） |
| 设计稿重渲染 | `swift run --disable-sandbox ResidueApp --render-pages design-renders` | ✅ 共渲染 **16 张**；`git status` 显示 `design-renders/` **无 diff** ⇒ 样张形态未变 |
| 判据 10（兜底串消失） | `grep -rn "未达项读取中" Sources/` | ✅ 无命中 |
| 判据 11（文案归口） | 未达项区（`Pages.swift:296-318`）内 `grep -n "L.pick"` | ✅ 无命中 |

**声明面数字同步（§4.3）**：`README.md:194`、`ARCHITECTURE.md:34/:122/:136`、`CLAUDE.md:20`、`.github/workflows/ci.yml:5`、`.github/workflows/release.yml:211` 全部由 **472 → 481**；`ARCHITECTURE.md:87` 由「61 份文件 / 23 个单号」→ **「63 份文件 / 25 个单号」**（`docs/changes/` 实测 63 份、唯一单号 25 个）；`CLAUDE.md:11` 与 `CLAUDE.md:127` 由 **140 份 → 142 份**（`docs/` 下实测 142 份 `.md`）。

> ★ `release.yml:211` 的「481 单测全绿」会出现在**公开 Release 页面**上 —— 声明与实跑一致。

### 10.4 偏差登记

| # | 偏差 | 为什么 | 处置 |
|---|---|---|---|
| 1 | §3.8 的前提写成「`a` 未判定时」 | **造不出 `a == nil`** —— `SourceHeaderEntry.a` / `.b` 是**非可选 `Int`**。「未达项为空但不可点亮」的真实成因是**未结算（`K == nil`）** | 判据 9 与 `testNoUnmetItemsDoesNotMeanQualified` 已按 `K == nil` 写；**变更单 §3.8 的表述留作历史记录** |
| 2 | 判据链落点行号 `PageModelBuilder.swift:234-241` | 实际落在 `:243-274`（前面加了 9 行判据链注释） | 代码为准，行号漂移登记备查 |
| 3 | 界面落点行号 `Pages.swift:299-305` | 实际落在 `:302-313` | 同上 |
| 4 | `UnmetSection.swift` 首版头注释写了「一句『未达项读取中』」 | 判据 10 的 `grep -rn "未达项读取中" Sources/` 会**命中注释** ⇒ 自伤 | 注释改为「一句『读取中』」，`grep` 现无命中 |
| 5 | 变异 2 首跑**全绿**（假绿） | 步骤 1.3 的样本白名单为空 ⇒ `input.candidates` 与 `visibleCandidates` **完全一致** ⇒ §3.4 的口径差异**无测试区分力** | 补 `testEmptyDomainCauseUsesUnfilteredCandidates`（候选 `/uv/cache/abc` + 白名单 `["/uv/cache"]`）⇒ 重跑变异 2 现红在 `:994` |
| 6 | 变更单 §八 步骤 6 变异 2 写「期望步骤 1.3 红」 | 原样本下**不成立**（见偏差 5） | 实际由**新增**用例抓住；本单**未**改动既有步骤 1.3 的样本 |
| 7 | 变异 2 的写法 `input.visibleCandidates.isEmpty` **编译不过** | `visibleCandidates` 是 `PageModelBuilder.build` 内的**局部变量**（`:125`），不是 `Input` 的成员 | 变异写法改为 `visibleCandidates.isEmpty`（不带 `input.`） |
| 8 | `UnmetSection.none` 在 `switch` 里与 `Optional.none` 冲突 | Swift 报 "Cannot infer contextual base in reference to member 'none'" | 派生属性改用 `if case .rows(let slots) = unmetSection { return slots }` / `return []` |
| 9 | 还原变异备份时**误将 `PageModelBuilder` 备份覆盖 `SemanticSlot.swift`** | 备份文件名与目标文件名不一致，凭复制命令里的路径直觉下手 | 已 `git checkout --` 还原 `SemanticSlot.swift`，再按 §3.5 **逐字重贴**两串 `UICopy`；复跑 53 条全绿。教训：`/tmp/*.bak.swift` 备份必须按目标文件名校验 |
| 10 | 源码多处出现「no member 'unmetSection'」「Cannot infer contextual base」诊断 | SourceKit **索引未刷新**所致 | `swift build` / `swift test` 均通过 ⇒ 一律忽略，不改代码 |

### 10.5 防假绿验证

§八 步骤 6 的五条破坏性变异**逐条实跑**（临时改坏 → 实跑看红 → 还原）。全部**被抓住**。

| # | 变异 | 实跑红输出 | 抓住它的判据 |
|---|---|---|---|
| 1 | 空域时把全局项加回 `.rows` | **5 条红**：`PageModelBuilderTests.swift:951` / `:970` / `:994` / `:1035` / `:1037`；`:1037` 处 `("1") is not equal to ("0") - 空判定域不得列任何未达项行（DAC-79 …）` | DAC-79 ②③ |
| 2 | 空域成因判据写成 `visibleCandidates.isEmpty` | `:994` 红：`("emptyDomain(...noScannableSource)") is not equal to ("emptyDomain(...noCleanupCandidate)")` | §3.4 口径 |
| 3 | 态④（从未扫描）也走 `.emptyDomain` | `:1008` 红：`("emptyDomain(...noScannableSource)") is not equal to ("rows([...「第 2 轮 · 观察期 0/14 天」])")` | §2.7 歧义 A |
| 4 | `unmetNone` 写成「已达达标条件」 | `:1043` 红：`("已达达标条件") is not equal to ("无未达项")` | §3.8 |
| 5 | `canLightUp` 在态② 被改成 true | `:1065` 红：`XCTAssertFalse failed - 未达项为空 ≠ 可点亮：`K == nil`（未结算）时不得判为可点亮` | 不变量③ / §3.8 |

★ **变异 2 的两轮**（本单实测到的**第二处假绿**）：补 `testEmptyDomainCauseUsesUnfilteredCandidates` **之前**是 **52/52 全绿**（假绿）；补**之后**红在 `:994`。⇒ 「口径差异」若无区分力样本，变异测试会给**假通过**。

★ 每条变异跑完均已还原；还原后 `md5` 复核 `PageModelBuilder.swift` 与备份一致（`d675764968fe5c8d501abf324ce3c596`），复跑 53 条全绿。

### 10.6 已知既有漂移（本单不处理，登记备查）

| # | 漂移 | 位置 | 处置 |
|---|---|---|---|
| 1 | ① 页首启空态文案「还没有扫描过」违 DAC-80 | `Components.swift:387` | 另开变更单（§六.1） |
| 2 | `unmetNotices` 在生产代码里只作为「行数口径」存在 | `PageModel.swift` | 保留（§九 #3） |
| 3 | release 编译有 3 条 warning（`deleted` 未用 / `unknownCount` 未变 / `bytesKind` 未用） | `AppModel.swift:1105` / `ScanEngine.swift:508` / `TrashExecutor.swift:160` | 均为**本单未触及**的既有漂移；另开变更单或后续清理 |
