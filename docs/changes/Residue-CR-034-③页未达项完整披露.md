# CR-034 · ③ 页未达项完整披露（来源标识 / 类名 / 四数齐 / 追加句 / 多行承载）· P0 · 未达项集合在类型上无法多行且不披露基数

> **缺陷**：PRD v5.6 AC-08 组 A 要求 ③ 页「未达项」按**两级分行**呈现 ——
> 全局项不带来源、只列一次；来源项**带来源标识**、**按判定域顺序分组逐行**（一项一行），
> `样本不足` 行的基数形态为**四数齐**（`样本 K / 总量 T（门槛 H，其中失联 J）`）
> 并在其后**追加**逐字句「失联不补足，下一轮以新快照重算」，
> `L0 误判` 逐字为「`<来源>` · L0 误判 N 次（检查 M 次）」，
> 未判定态逐字为「`<来源>` · L0 未判定（无法枚举本用户进程）」；
> 但实现侧：
> - `PageModel.unmetNotice` 是**单数槽位**（`SemanticSlot?`）⇒ **多行在类型上无法表达**；
> - `PageModelBuilder.unmetNoticeText` **只取 `.first`** ⇒ 多来源多未达项**只呈现第一条**；
> - `样本不足` 行走的是 `UICopy.unmetSampleInsufficient(round:sample:threshold:)`
>   →「第 N 轮 · 样本不足（K / H）」—— **无来源标识、无类名、缺 `T` / `J`、缺追加句**，
>   且实现里用 `sample: 0, threshold: 0` + `replacingOccurrences(of: "0 / 0", …)`
>   的**占位 hack** 才凑得出字形 ⇒ 产出畸形文本「第 N 轮 · 样本不足（来源名 / 0）」；
> - `L0 误判` 行的两串**内联在 `PageModelBuilder` 里**（不在 `UICopy`）且**不带次数**；
> - `Metrics.UnmetSourceItem.text` 是**死代码**（无调用点）且带**旧口径**「未取得 Full Disk Access」
>   —— 与〔CR-022 · 偏差 6〕/ R2 v1.10 :458 的「无法枚举本用户进程」冲突；
> - `PageModelBuilder` 装配段的 `undetermined` 靠**启发式**推断
>   （`entry.a == 0 && entry.b == 0 && entry.T != nil && entry.K == nil`）
>   ⇒ 把「本轮未结算」**误标**成「无法枚举本用户进程」——
>   **正常机器上会显示一句产品根本不知道的事**（违不变量③「不把未知判为安全」）
> **契约依据**：PRD v5.6 :1066 / :1067〔AC-08 组 A Given + 判定 ①①′①″②②′②″②‴③〕/
> :1247〔§6 承载页指定 · 未达项文案段〕/ :157〔M5 · `b = 0` 本期不可达〕；
> DAC v2.0 :245–256〔DAC-74 ~ DAC-79〕；B1 v1.0 TC-027 / TC-028 / TC-029 / TC-031 / TC-032 /
> TC-033 / TC-034 / TC-035 / TC-036 / TC-037 / TC-038；R2 v1.10 :40 / :458 / §25.1 裁定一；
> 视觉基线 v1.1 :126 / :133
> **性质**：**功能缺失 + 实现错误**（双类 —— 多行承载与基数披露是「从未实现」，
> `undetermined` 启发式与「未取得 Full Disk Access」旧口径是「实现错了」）
> **状态**：**待实现**（变更单先行；代码落地须按 §八 TDD 步骤）
>
> **修订记录**：
> - **v1 · 2026-11-18**：初稿。逐条核实 PRD v5.6 / DAC v2.0 / B1 v1.0 / 视觉基线 v1.1 / R2 v1.10
>   的契约原文与代码落点行号；列出 §九 待裁决 5 条（**均给出建议方案**，不阻塞起草）。
>   取证期间发现并登记两处**契约内部歧义**（§二.7）：来源名逐字（`npm/_npx` vs `npm.npx`）
>   与「单行文本」（PRD :1247）vs「分行」（DAC-74 / AC-08 组 A Then）。

---

## 一、缺陷

### 1.1 现象

用户在第 ③ 页「清理策略配置」页看到的未达项，只有**一行**，且**信息量远低于契约**。

观察期满、报告产出、`npm/_npx` 样本不足（`K = 11 < H = 12`）时：

| | 契约要求 | 现状呈现 |
|---|---|---|
| 来源项行数 | 样本不足 **+** L0 误判 = **2 行** | **1 行**（`unmetNoticeText` 只取 `.first`） |
| 来源标识 | 「`<来源>` · …」 | **无** |
| 类名 | 「… · 样本不足 · …」 | **无**（只有「样本不足」四字嵌在括注里） |
| 基数形态 | 「样本 11 / 总量 12（门槛 12，其中失联 1）」 | 「样本不足（11 / 12）」—— **缺 `T`、缺 `J`、门槛与总量混为一谈** |
| 追加句 | 「失联不补足，下一轮以新快照重算」 | **无** |
| `L0 误判` 行 | 「`<来源>` · L0 误判 1 次（检查 128 次）」 | 「`<来源>` · L0 误判」—— **无次数、无检查次数** |
| 未判定行 | 「`<来源>` · L0 未判定（无法枚举本用户进程）」 | 「`<来源>` · L0 未判定（无法枚举本用户进程）」✓（**唯一达标的一处**） |

且现状的「样本不足」行是**占位 hack** 拼出来的：

```swift
// PageModelBuilder.swift:455-457（现状）
return UICopy.unmetSampleInsufficient(round: progress.round, sample: 0, threshold: 0)
    .replacingOccurrences(of: "0 / 0", with: entry.source.displayName)
```

⇒ 产出「第 N 轮 · 样本不足（npm/_npx / 0）」—— **数字是 0，来源名挤在括号里，轮次挂在来源项上**。
契约里**来源项不带轮次**（轮次只属于全局项），且这个 0 是**假数字**（不变量③）。

### 1.2 复现路径（代码级）

| # | 落点 | 现状 | 违了什么 |
|---|---|---|---|
| ① | `ResidueCore/PageModel.swift:182` | `public var unmetNotice: SemanticSlot?` | 单数槽位 ⇒ DAC-74「两级分行」「一项一行」**在类型上无法表达** |
| ② | `ResidueCore/PageModelBuilder.swift:441-478` | `if let first = unmet.bySource.first { … }` | 多来源多未达项**只呈现第一条** ⇒ DAC-74 / DAC-78 / PRD ①′ / ②‴ / B1 TC-028 / TC-033 / TC-037 |
| ③ | `ResidueCore/PageModelBuilder.swift:455-457` | `sample: 0, threshold: 0` + `replacingOccurrences(of: "0 / 0", …)` | 占位 hack：产出假数字 0 + 畸形字形；DAC-76「四数齐」不成立 |
| ④ | `ResidueCore/SemanticSlot.swift:267` | `unmetSampleInsufficient(round:sample:threshold:)` →「第 N 轮 · 样本不足（K / H）」 | 无来源标识、无类名、`H` 与 `T` 混用、缺 `J`、缺追加句；**来源项不该带轮次** |
| ⑤ | `ResidueCore/PageModelBuilder.swift:464-468` | `L0 误判` / `L0 未判定` 两串**内联**在 builder 里 | 契约文案不在 `UICopy`（唯一文案出口）；`L0 误判` **不带次数** |
| ⑥ | `ResidueCore/Metrics.swift:547-566` | `UnmetSourceItem.text` —— **无任何调用点**（死代码） | 死代码 + 第二套文案实现 + **旧口径**「L0 未判定（未取得 Full Disk Access）」违〔CR-022 · 偏差 6〕/ R2 v1.10 :458 |
| ⑦ | `ResidueCore/PageModelBuilder.swift:203` | `undetermined: entry.a == 0 && entry.b == 0 && entry.T != nil && entry.K == nil` | **启发式误标**：本轮未结算（`K == nil`）的来源被标成「无法枚举本用户进程」⇒ 正常机器上显示一句产品不知道的事（不变量③） |
| ⑧ | `ResidueCore/PageModelBuilder.swift:140` | 只读态写 `model.unmetNotice = .unavailable(…)` | 单数槽位承载「不可用」态（改数组后须同步） |

### 1.3 第二个后果：降级未判定被误报，正常机器显示一句假话

`PageModelBuilder.swift:203` 的启发式把「**本轮尚未结算**」（`T` 有、`K` 无）当成
「**L0 无法判定**」。触发路径极常见：

1. 观察期已满，**报告尚未产出**（结算扫描还没跑）→ `header.settlement.producedAt == nil`
   ⇒ `settlementProduced == false` ⇒ `unmetItems` **提前 return**（`Metrics.swift:664-666`）
   ⇒ 启发式**不会**被读到 —— 这一路安全；
2. **报告已产出**，但某个来源**本轮未结算**（例如它刚入域、或它本轮没被扫到）
   ⇒ `settlementProduced == true` ⇒ 走到来源项判定 ⇒ 该来源 `a = 0`、`b = 0`、`T` 有、`K` 无
   ⇒ **命中启发式** ⇒ 界面显示「`<来源>` · L0 未判定（无法枚举本用户进程）」。

⇒ 用户看到的是一句**产品并不知道的事**：进程枚举其实成功过，只是这个来源没结算。
这正是 CLAUDE.md §七「一句听起来对的话，可以掩护一个没做的事」的同型问题，
也是 CR-026 记录过的教训。

**正确信号在别处**：`PageModelBuilder.Input.degraded`（`:35` 定义、`:77` init 默认 `false`）
已经承载了 L0 探测的**全局降级单值**，AppModel 侧从 `snapshot.degraded`（`AppModel.swift:688`）
与 `lastScanDiagnostics.degraded`（`AppModel.swift:422`）喂进来；
R2 v1.10 §25.1 裁定一确认 `degraded` 是**全局单值**（`L0Probe.snapshot()` 一次产出一个 `Bool`，
没有 `sourceIndex`）⇒ 契约层口径就是它。

### 1.4 与其它单的关系

| 单 | 关系 |
|---|---|
| **CR-031** | 已把 `K` / `J` / `H` 写进载体 `SourceHeaderEntry` ⇒ **本单载体侧零改动**，只读 `entry.J` |
| **CR-032** | 判定域 = 本轮快照内命中 ⇒ 本单的来源项集合口径依赖它，不改 |
| **CR-033** | 轮次自动推进 ⇒ 全局项的「第 N 轮」由 `ObservationProgress.round` 提供，不改 |
| **CR-035（待开）** | ⑤ 页 ③ 列补失联 `J`（PRD M3 划归另开单）⇒ **本单只做 ③ 页** |
| **CR-008 §3.1 / §3.2** | 未达项三级分类的原始出处 |

---

## 二、契约依据

### 2.1 PRD v5.6 · AC-08 组 A（`docs/contract/Residue-PRD-v5.6.md` :1060–1090）

**Given（逐字要点）**：

- 「**判定域可空**；**判定域非空时**，对判定域内每个来源分别判定……**未达项分两级：**」
- **全局项**（不带来源；全机器至多一项）——`观察期未满`。
  **其定义 = 观察期结束扫描尚未成功完成**（含两种成因：本轮计数日 < 14；或第 14 个计数日后的
  扫描尚未成功完成、报告未产出）——**两种成因合为同一个未达项，不另设状态**
- **来源项**（带来源标识；按判定域顺序分组）——
  - `样本不足`（`K < H`）
  - `L0 误判`（`a ≠ 0` **或** `b = 0` **或该来源 `a` / `b` 未判定（无法枚举本用户进程）**）
    - 〔CR-011〕**`b = 0` 并入既有「L0 误判」项、不新增未达项类**
    - 〔CR-012〕**同 uid 进程枚举失败态亦并入既有「L0 误判」项**，
      文案 = 「`<来源>` · L0 未判定（**无法枚举本用户进程**）」——**三态共用一个未达项类**
    - 〔CR-022 · 偏差 6〕**可观测代理 = 同 uid 进程枚举失败（`E-501`）**
    - **来源项只在报告产出后判定**

**Then（逐字要点）**：

- 全局项**不带来源、只列一次**（形如「第 1 轮 · 观察期 9/14 天」；
  计数日已满而报告未产出时**统一为**「第 `<N>` 轮 · 观察期未满 · 待结算扫描（无需操作）」）
- 来源项**带来源标识、按判定域顺序分组逐行**
  （形如「uv cache · 样本 27 / 总量 30（门槛 30，其中失联 3）」
  ——**三个基数是 `K`/`T`/`J`，门槛 `H` 另标，不得把 `J` 挂在 `H` 下**）；
  〔CR-019 · D33〕**`样本不足` 行在其基数形态之后追加一句
  「失联不补足，下一轮以新快照重算」**（不加判定项、不加数字，承载页 = **第 ③ 页开关区**，不是第 ⑤ 页矩阵）；
  **一项一行、逐行独立**
- **固定顺序 = 全局项在前、来源项在后**；**不展示剩余条数**
- `样本不足` 与 `L0 误判` 同时成立时**两项分行列出**，归因文字
  「因存在 L0 误判，本版本不再提示可点亮进度」作为**附加说明**附在 `样本不足` 行之后
  ——**不合并成一项**
- **`L0 误判` 项文案格式**：`uv cache · L0 误判 1 次（检查 128 次）`；
  **`b = 0` 时**：`uv cache · L0 未检查（检查 0 次）`——**仍属既有三类未达项之一**；
  触发条件 = `a ≠ 0` **或** `b = 0`（文案按两态分别给出）
- **`L2` 与熔断回退均不列为未达项**

**判定用例（逐字要点）**：

| 用例 | 逐字 |
|---|---|
| ① | 集合须与 {`观察期未满`} **一元素全等**（来源项数 = 0） |
| ①′ | 集合须与 {`<来源>` · 样本不足, `<来源>` · L0 误判} **两元素全等、两项分行**（无全局项） |
| ①″ | 被持有候选**就是**被手删的那 1 条 ⇒ 按 M4 唯一例外**不计误判** ⇒ 集合只含 {`<来源>` · 样本不足} |
| ② | `T ≤ 30`、不失联 ⇒ 达标 ⟺ `K ≥ H` |
| ②′ | 集合**只含 {`<来源>` · L0 误判} 一项** |
| ②″ | 集合**只含 {`<来源>` · L0 未判定（无法枚举本用户进程）} 一项**、⑥ 填「无法判定（无法枚举本用户进程）」、页级取「否（因 `<来源>` 未判定）」 |
| ②‴ | 集合 = **{`<来源>` · 样本不足, `<来源>` · L0 未判定（无法枚举本用户进程）} 两项、两行** |
| ③ | 判定域为空 ⇒ **不列出任何未达项**；剩余天数 = `14 − 计数日`（下界 0），**计数日已满而报告未产出时该格显示 `—`（不显示 `0 天`）** |

### 2.2 PRD v5.6 · M5（:157）

> 〔CR-018 · 自查 2 · **本期不可达**〕本期内 `b = 0` 对判定域内来源不可达：
> 判定域 = 本轮观察期开始快照内命中的来源，而该快照正是由**首次扫描**取的
> ⇒ 该来源的候选在入域当轮即被执行 L0 判定 ⇒ **`b ≥ 1` 恒成立**；
> 故 AC-08 组 A 的来源项第三态「`L0 未检查（检查 0 次)`」在本期**无触发场景**，
> **不需为其单独立用例**（该文案保留为**防御性表述**——若实现方出现 `b = 0`，
> 说明扫描未按 M4 前置执行，属实现缺陷）

⇒ **本单仍然实现该文案**（否则 `b = 0` 会落到错误分支），但**不单独立验收用例**。

### 2.3 DAC v2.0（`docs/contract/Residue-DAC-v2.0.md` :245–256）

| 条 | 逐字要点 | 容差 |
|---|---|---|
| **DAC-74** | 未达项**两级分行**：全局项不带来源、只列一次；来源项带来源标识、按判定域顺序分组、一项一行。全局项最前、来源项在后 | 结构完全一致（**0 容差**）｜判定：数行数；读首行有无来源名；核对顺序 |
| **DAC-75** | 来源项取值**逐串点名封闭为三串**：`样本不足` / `L0 误判` / `L0 未判定（无法枚举本用户进程）`。**出现第四种未达项类即不通过** | 三串逐字完全一致｜判定：**造三态各一行，逐行读串比对** |
| **DAC-76** | `样本不足` 行的基数形态为**四数齐**：`样本 <K> / 总量 <T>（门槛 <H>，其中失联 <J>）`；且**在其后追加逐字句**「失联不补足，下一轮以新快照重算」 | 四数 4/4；追加句逐字 0｜判定：读该行拆四数；检索追加句 |
| **DAC-77** | ③ 页开关区有**独立「剩余天数」格**（形如 `剩余 N 天`；计数日已满而报告未产出时为 `—`），与未达项**同址相邻但不同格**，**不得合并进未达项那一句** | 独立元素 0 容差（**现状已合规**） |
| **DAC-78** | `样本不足` 与 `L0 误判` **同时成立时分行两项**（两行），**不合并成一项**；「因存在 L0 误判，本版本不再提示可点亮进度」作为**附加说明**附在 `样本不足` 行后，不单独成未达项 | **2 行（0 容差）**｜判定：造该组合态，**数行数 = 2** |
| **DAC-79** | 判定域为空时呈现 §8 空类成因之一 ∈ {`无可扫描来源`, `无清理候选`}；且**不列出任何未达项** | 未达项行数 = 0 |

> ⚠️ **DAC / 视觉基线不在机器校验范围内**（`grep -rln "DAC" tests/contract/` 无输出）
> ⇒ 改动 DAC-75 措辞**不会被任何脚本挡住**，属**人工评审事项**（§九 待裁决①）。

### 2.4 B1 v1.0（`docs/contract/Residue-B1-功能用例集-v1.0.md`）

| 用例 | 逐字要点 |
|---|---|
| **TC-027** | 组 A ①：集合 = {`观察期未满`} 一项全等（来源项数 = 0） |
| **TC-028** | 组 A ①′：集合 = **{`npm.npx` · 样本不足, `npm.npx` · L0 误判}**，**两项分行、不合并成一项** |
| **TC-029** | 组 A ①″：被持有候选即被手删那条 ⇒ 不计误判 ⇒ 集合只含 {`npm.npx` · 样本不足} |
| **TC-030** | 组 A ②：`T ≤ 30`、不失联 ⇒ 达标 ⟺ `K ≥ H` |
| **TC-031** | 组 A ②′：集合**只含 {`npm.npx` · L0 误判} 一项** |
| **TC-032** | 组 A ②″：集合**只含 {`npm.npx` · L0 未判定（无法枚举本用户进程）} 一项**；⑥ 列**逐字**为「无法判定（无法枚举本用户进程）」 |
| **TC-033** | 组 A ②‴：集合 = **{`npm.npx` · 样本不足, `npm.npx` · L0 未判定（无法枚举本用户进程）}**，**两项分行** |
| **TC-034** | 组 A ③：空判定域 ⇒ **未达项列表条目数 = 0** |
| **TC-035** | 全局项文案：逐字为「第 1 轮 · 观察期 9/14 天」；检索「观察期已满 · 待结算」「等待结算扫描成功」出现次数 = **0** |
| **TC-036** | 计数日已满而报告未产出：全局项逐字为「第 1 轮 · 观察期未满 · 待结算扫描（无需操作）」；「剩余天数」格显示 **`—`**（**不得显示「0 天」**）；计数日封顶 14/14 |
| **TC-037** | 固定顺序：第 1 行 = 全局项（不带来源名）；第 2 行起 = 来源项（带来源名）；「还差 X 条」出现次数 = **0** |
| **TC-038** | `样本不足` 行追加：「该行在其基数形态（「样本 11 / 总量 12（门槛 12，其中失联 1）」）之后**追加**一句，逐字为「失联不补足，下一轮以新快照重算」；该句**不携带任何数字**（**行内数字只有 11 / 12 / 12 / 1 四个**） |

**前置定义**：`CLOCK-9` = `RESIDUE_TEST_COUNTED_DAYS = 9`（观察期未满 9/14，报告未产出）；
`CLOCK-14` = `RESIDUE_TEST_COUNTED_DAYS = 14`（观察期满且报告产出）；
`FIX-C` = `~/.cache/uv` 8 条 + `~/.npm/_npx` 12 条（判定域 = 2 来源）。

### 2.5 R2 v1.10

- **§25.1 裁定一**：`degraded = true` 在无 root、无 entitlement 的产品进程里是**可构造态**；
  `L0Snapshot(degraded: true)` 是**公开可构造的值**；`degraded` 是**全局单值**
  （`L0Probe.snapshot()` 一次产出、一个 `Bool`，**没有 `sourceIndex`**）。
  契约层新口径：`degraded = true` 时该来源 `a` / `b` **均不判定**、
  第 ⑤ 页 ⑥ 列 = 「无法判定（无法枚举本用户进程）」（不填 `0/0`、不填空）、
  未达项集合含「L0 未判定（无法枚举本用户进程）」、页级状态行取「否（…未判定）」。
- **:40 / :458**：未判定口径为「**无法枚举本用户进程**」，**不判定 FDA 是否授予**
  （macOS 无公开 API，见 AC-14）⇒ 现有死代码里的「未取得 Full Disk Access」是**旧口径**。

### 2.6 视觉基线 v1.1

- **:126**：「③ 清理策略配置 | 表单 + **两个不重叠的语义位**（清理策略参数 / 规则版本） |
  开关区未达项文案（带轮次）；剩余天数 `.duration`」
- **:133**：「**轮次表述统一为前置数字式**（`第 2 轮 · …`），三处（③ 页未达项、⑤ 页页级、
  ⑤ 页上一轮行）**同构**」

### 2.7 ★ 契约内部歧义登记（本单裁决依据）

**歧义 A —— 来源名逐字：`npm/_npx` vs `npm.npx`**

| 出处 | 写法 | 性质 |
|---|---|---|
| PRD :673 / :1200 / :1293 | `uv` cache / **`npm/_npx`** | **展示名** |
| DAC :40 / :131 | uv cache / **`npm/_npx`** / pipx run | **展示名** |
| 代码 `Source.displayName`（`Metrics.swift:60-66`） | uv cache / **`npm/_npx`** / pipx run | **展示名** ✓ 一致 |
| B1 :38 / :328 / :336 / :352 / :360 / :368 | **`npm.npx`** | **来源标识**（`RESIDUE_TEST_SOURCES` 注入点子集名） |

⇒ **裁决**：二者是**不同概念的不同字符串** —— `npm.npx` 是来源**标识**（注入点 / 集合的语义标识），
`npm/_npx` 是**展示名**。本单的行首用 **`source.displayName`**，
理由是 PRD 组 A Then 的**唯一逐字举例**（「uv cache · 样本 27 / 总量 30（门槛 30，其中失联 3）」）
用的是**展示名**；且 `displayName` 是生产原语（不变量②：不在测试或文案层另立一套来源命名）。
⇒ **代码侧无偏差**，**B1 的 `npm.npx` 无需订正**。

**歧义 B —— 「单行文本」vs「分行」**

- PRD :1247（§6 承载页指定）逐字：「……**单行文本、不复制表格**」
- PRD AC-08 组 A Then：来源项「**一项一行、逐行独立**」「**两项分行列出**」
- DAC-74 / DAC-78：**0 容差**（数行数 = 2）
- B1 TC-028 / TC-033 / TC-034 / TC-037：全部要求**分行 / 条目数 = 0 / 固定顺序**

⇒ **裁决**：PRD :1247 的「单行文本」指「**不复制表格**（不用表格呈现）」，
不是「只能一行」—— 依据有三：① 同一句里用「`样本不足` **行**」称呼该元素；
② PRD :1247 自述「该句的**唯一定义处 = AC-08 组 A Then**」；
③ 四份文档中三份明确要求分行，且 DAC 是 R3.8 走查的**唯一依据**且容差为 0。
⇒ **本单按分行实现**；PRD :1247 的措辞建议在评审时补一句澄清（§九 待裁决②）。

---

## 三、改什么

> **改动面清单（外科手术式）**：判定留在 `GateEvaluator`（唯一实现处），
> 算术与文案收口在 Core，界面只渲染已算好的字符串（不变量①②③）。

### 3.1 `SourceGateInput` 加 `lost: Int?`（`Metrics.swift:615-649`）

```swift
public struct SourceGateInput: Equatable, Sendable {
    public var source: Source
    public var attributable: Int?   // K
    public var total: Int?           // T
    public var lost: Int?             // J  ← 新增（失联数）
    public var missCount: Int?       // a
    public var checkCount: Int?      // b
    public var undetermined: Bool
}
```

- `J` 的**判定**不需要它（判「样本不足」只看 `K` 与 `H`）⇒ 它是**载荷**，不是判据。
- **`H` 不加字段** ⇒ `H = Threshold.h(forTotal: T)` 由判定处填入
  （`Threshold.h` 是 `H` 的**全文唯一式子** ⇒ 不违反不变量②）。

### 3.2 `UnmetSourceItem` 扩载荷 + **删 `text`**（`Metrics.swift:541-566`）

```swift
public enum UnmetSourceItem: Equatable, Sendable {
    /// 样本不足（`K < H`）—— 载荷 = 四数齐（DAC-76）。
    case insufficientSample(sample: Int, total: Int, threshold: Int, lost: Int?)
    /// L0 误判（`a ≠ 0`）· 或 `b = 0`（本期不可达）· 或未判定（同 uid 进程枚举失败）。
    /// **三态共用一个未达项类**（〔CR-011〕/〔CR-012〕）。
    case l0Misjudged(missCount: Int?, checkCount: Int?, undetermined: Bool)
}
```

**为什么保持 2 个 case 而不是拆 3 个**：PRD 〔CR-011〕/〔CR-012〕明写
「`b = 0` **并入既有「L0 误判」项**」「三态**共用一个未达项类**」
⇒ **用户可见的来源项类 = 2 个**（`样本不足` / `L0 误判`），
三态是 `L0 误判` 类的**三种呈现态**。

**删除 `UnmetSourceItem.text`**：① 无任何调用点（死代码）；
② 是第二套文案实现（违不变量②）；③ 含**旧口径**「未取得 Full Disk Access」
（违〔CR-022 · 偏差 6〕/ R2 :458）。

**`lost` 为何可空**：`J` 与 `K` 在结算时**同写**（`ObservationWriteback.swift:206-207`）
⇒ 构造路径上 `K` 非 nil ⟹ `J` 非 nil。保留可空是为了**不把未知判成 0**
（`J == nil` 时显示「—」而非谎称「失联 0」）—— 防御分支，正常链路不可达（§九 待裁决④）。

### 3.3 `GateEvaluator.unmetItems` 载荷填充（`Metrics.swift:651-701`）

```swift
if let k = input.attributable, let t = input.total,
   SampleSufficiency.isInsufficient(k: k, t: t) {
    items.append(UnmetSourceEntry(
        source: input.source,
        item: .insufficientSample(
            sample: k,
            total: t,
            threshold: Threshold.h(forTotal: t),   // H 的唯一式子
            lost: input.lost
        )
    ))
}
```

**判定逻辑本身不变**（仍是 `K < H` / `a ≠ 0` / `b = 0` / `undetermined`）⇒ 不变量④ 不动。

### 3.4 ★ `undetermined` 改由 `input.degraded` 驱动 —— 删除启发式（`PageModelBuilder.swift:203`）

```swift
// 现状（错）：启发式 —— 把「本轮未结算」当成「L0 无法判定」
undetermined: entry.a == 0 && entry.b == 0 && entry.T != nil && entry.K == nil

// 改为：L0 探测的全局降级单值（R2 v1.10 §25.1 裁定一）
undetermined: input.degraded
```

- `input.degraded` 由 AppModel 从 `snapshot.degraded` / `lastScanDiagnostics.degraded` 喂入
  ⇒ **已经是真实信号**，不需要推断。
- `degraded` 是**全局单值** ⇒ 降级时**所有**判定域内来源的 `a` / `b` 均不判定
  ⇒ 全部呈现「L0 未判定（无法枚举本用户进程）」—— 这**就是**真实情况
  （产品枚举不出本用户进程 ⇒ 所有来源的 L0 都不可判），符合不变量③。

### 3.5 `UICopy` 新串 / 删旧串（`SemanticSlot.swift:200+`）

**删**：`unmetSampleInsufficient(round:sample:threshold:)`（:267）。

**增**（全部逐字落地，英文为 `L.pick` 的第二支）：

| 函数 | 逐字（中文） |
|---|---|
| `unmetSampleInsufficient(source:sample:total:threshold:lost:)` | 「`<来源>` · 样本不足 · 样本 `<K>` / 总量 `<T>`（门槛 `<H>`，其中失联 `<J>`）」 |
| `unmetSampleNote()` | 「失联不补足，下一轮以新快照重算」 |
| `unmetL0Misjudged(source:missCount:checkCount:)` | 「`<来源>` · L0 误判 `<a>` 次（检查 `<b>` 次）」 |
| `unmetL0NeverChecked(source:)` | 「`<来源>` · L0 未检查（检查 0 次）」 |
| `unmetL0Undetermined(source:)` | 「`<来源>` · L0 未判定（无法枚举本用户进程）」 |
| `unmetL0AttributionNote()` | 「因存在 L0 误判，本版本不再提示可点亮进度」 |

- **`lost` 为 nil 时**：「其中失联 `—`」（不变量③：不谎称 0）。
- 追加句与归因说明**都不带数字** ⇒ 满足 TC-038「行内数字只有 11 / 12 / 12 / 1 四个」。

### 3.6 `PageModel.unmetNotice` → `unmetNotices: [SemanticSlot]`（`PageModel.swift:182`）

```swift
/// 未达项（③ 页开关区）—— **多行**：全局项在前、来源项在后（每项一行）。
public var unmetNotices: [SemanticSlot] = []
```

⚠️ **不改 `SemanticSlot` 枚举** ⇒ `verify_a9.sh:47-52`（Page 枚举 case 数 = 7）**不受影响**。

### 3.7 `PageModelBuilder` 装配 + 格式化（`PageModelBuilder.swift:140 / 195-245 / 441-478`）

- `:140` 只读态 ⇒ `model.unmetNotices = [.unavailable(reason: UICopy.readOnlyNoSettlement)]`
- `:195-245` 装配段 ⇒ `gateInputs` 加 `lost: entry.J`、`undetermined: input.degraded`；
  `model.unmetNotices = unmetNoticeSlots(unmet, progress: progress, previous: header.previousRound)`
- `:441-478` ⇒ `unmetNoticeText` 改为 **`unmetNoticeSlots(_:) -> [SemanticSlot]`**：

```
1. 全局项非 nil ⇒ 追加一行（UnmetGlobalItem.text(round:countedDays:previous:)）
2. 按来源分组（bySource 天然按来源连续 —— unmetItems 的循环按来源 append）
3. 每组内：
   样本不足行 ⇒ <来源> · 样本不足 · 四数形态 · 追加句
                      （+ 归因说明，仅当该来源存在 a ≠ 0 的 L0 项）
   L0 行     ⇒ a ≠ 0 → 「L0 误判 N 次（检查 M 次）」
                b = 0 → 「L0 未检查（检查 0 次）」
                未判定 → 「L0 未判定（无法枚举本用户进程）」
```

**归因说明的触发条件**：同来源存在 `.l0Misjudged(missCount: a, undetermined: false)` 且 `a > 0`
⇒ **仅真误判时追加**（未判定态下说「因存在 L0 误判」是**错的**）。

### 3.8 `Pages.swift` 渲染改多行（`Pages.swift:294-307`）

```swift
HStack(alignment: .firstTextBaseline) {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
        if model.unmetNotices.isEmpty {
            SemanticSlotView(slot: .text(L.pick("未达项读取中", "Loading unmet items")), muted: true)
        } else {
            ForEach(model.unmetNotices.indices, id: \.self) { index in
                SemanticSlotView(slot: model.unmetNotices[index])
            }
        }
    }
    Spacer(minLength: Tokens.Spacing.s)
    // 「剩余天数」**仍是独立格**（DAC-77：同址相邻但不同格，不得合并进未达项那一句）
    SemanticSlotView(slot: model.remainingDays, muted: true)
}
```

### 3.9 `DesignSampleData.swift:63`（设计稿样本同步新签名）

```swift
m.unmetNotices = [
    .text(UICopy.unmetSampleInsufficient(
        source: Source.uvCache.displayName, sample: 11, total: 12,
        threshold: 12, lost: 1
    ) + " · " + UICopy.unmetSampleNote())
]
```

### 3.10 测试改动

| 文件 | 改动 |
|---|---|
| `Tests/ResidueCoreTests/MetricsTests.swift` | ① helper `input(_:k:t:…)` 加 `lost:`；② `.insufficientSample` 断言改为带载荷比较；③ **用例改名**：`testUnmetFDAUndetermined` → `testUnmetL0Undetermined`、`testUnmetSampleAndFDAUndeterminedTwoRows` → `testUnmetSampleAndL0UndeterminedTwoRows`（语义已从「未取得 FDA」改为「同 uid 进程枚举失败」，旧名带**已废止口径**）；④ **新增** 8 条用例（见 §八） |
| `Tests/ResidueCoreTests/PageModelBuilderTests.swift` | 三处断言改写（`:209` / `:270` / `:377`）：`unmetNotice?` → `unmetNotices` 数组；**新增**多行 / 逐字 / 顺序 / 降级态断言 |
| `Sources/ResidueApp/DesignSampleData.swift` | `:63` 同步新签名（§3.9） |

### 3.11 导航项数同步

`CLAUDE.md` 两处「`docs/` 下 **139** 份 `.md`」⇒ **140**（本单新增 1 份变更单）。
（`ARCHITECTURE.md:87` 的「59 份文件 / 21 个单号」**已过时**（实际 60 份 / 22 个单号）——
**既有漂移，不在本单范围**，登记于 §十 偏差。）

### 3.12 不动的地方（外科手术边界）

- `GateEvaluator.isQualified`（`:708-732`）—— 门槛条件一字不改（不变量④）
- `UnmetSourceEntry` / `UnmetItems` 结构 —— 不动
- `UnmetGlobalItem` / `UnmetGlobalItem.text` —— 不动（CR-033 已定稿）
- `ObservationProgress.remainingDays` —— **已合规**（`countedDays ≥ 14` ⇒ 返回 `nil` ⇒ `.duration(days: nil)` ⇒ 渲染「—」，
  满足 TC-036「不得显示 0 天」）
- `unmetReason(_:)`（`:480-497`，用于 **⑤ 页页级状态行**）—— **不动取值**
  （AC-09 五级优先级与 ③④ 的旧口径属 CR-035 / 另开单）；仅因 `UnmetSourceItem` 载荷变化
  而**同步其 switch 分支的解构写法**（编译必需）
- ⑤ 页矩阵、⑤ 页 ③ 列、⑤ 页页级状态行取值优先级 —— **不动**
- `L0Probe` / `ObservationWriteback` / 载体 —— **不动**

---

## 四、影响面

| 层 | 文件 | 改动性质 |
|---|---|---|
| Core | `Metrics.swift` | `SourceGateInput` 加字段；`UnmetSourceItem` 扩载荷 + 删 `text`；`GateEvaluator.unmetItems` 填载荷 |
| Core | `SemanticSlot.swift` | `UICopy` 删 1 串 / 增 6 串 |
| Core | `PageModel.swift` | `unmetNotice` → `unmetNotices: [SemanticSlot]` |
| Core | `PageModelBuilder.swift` | `gateInputs` 两处改；`unmetNoticeText` → `unmetNoticeSlots`；只读态同步 |
| App | `Pages.swift` | ③ 页开关区改 `VStack` 多行渲染 |
| App | `DesignSampleData.swift` | 样本数据同步 |
| 文档 | `CLAUDE.md` | 项数 139 → 140 |
| 测试 | `MetricsTests.swift` / `PageModelBuilderTests.swift` | 见 §3.10 |

**受影响测试（必须改写 / 新增）**

| 现有用例 | 处理 |
|---|---|
| `MetricsTests.testUnmetTextUnifiedStyles`（:51） | **不动**（测 `UnmetGlobalItem.text`，本单不改全局项） |
| `MetricsTests.testUnmetDuringObservationIsGlobalOnly`（:216） | **不动**（用例①） |
| `MetricsTests.testUnmetSampleInsufficient`（:228） | **改写**（`.insufficientSample` 载荷变了） |
| `MetricsTests.testUnmetL0Misjudged`（:241） | **不动**（`.l0Misjudged` 载荷未变） |
| `MetricsTests.testUnmetFDAUndetermined`（:257） | **改名 + 注释对齐新口径** |
| `MetricsTests.testUnmetSampleAndL0TwoRows`（:273） | **不动**（`bySource.count == 2` 仍成立） |
| `MetricsTests.testUnmetSampleAndFDAUndeterminedTwoRows`（:294） | **改名 + 注释对齐新口径** |
| `MetricsTests.testDomainSourceWithoutSnapshotProducesNoUnmetItem`（:416） | **不动** |
| `PageModelBuilderTests`（:209 / :270 / :377） | **改写**（单数槽位 → 数组） |

---

## 五、附带订正

| # | 订正 | 理由 |
|---|---|---|
| 1 | `Metrics.UnmetSourceItem.text` **删除** | 死代码 + 第二套文案实现 + 旧口径「未取得 Full Disk Access」 |
| 2 | `PageModelBuilder` 的 `undetermined` **启发式删除**，改 `input.degraded` | 修掉「本轮未结算」被误报成「无法枚举本用户进程」的真实缺陷 |
| 3 | `MetricsTests` 两个用例名里的「FDA」改为「L0 未判定」 | FDA 口径已被〔CR-022 · 偏差 6〕废止 |
| 4 | `CLAUDE.md` 项数 139 → 140 | 本单新增 1 份 `.md` |

---

## 六、不做的事

| 不做 | 理由 |
|---|---|
| 不改 ⑤ 页 ③ 列（补失联 `J`） | PRD M3 划归另开单 ⇒ **CR-035** |
| 不加「其中无法归因」列 | PRD M3 已落导出报告；DAC-47 禁第 8 项 |
| 不动 ⑤ 页 `观察期` 列 | M-5 / A-04 |
| 不动 `L2 误判数` 列 | M-5 |
| 不落 PRD 〔D31〕的单元格内两行 + 冻结于日期 | 与视觉基线 v1.1 B1/A3 + DAC-48 冲突 ⇒ 待裁决；另受 32 pt 行高约束 |
| 不把失联 `J` 移进表头副标 | DAC v2.0 :473 |
| 不动 ⑤ 页页级状态行取值优先级 | 〔CR-013 · B18〕的 ③④ 仍写「FDA」旧口径 ⇒ 属 CR-035 / 另开单 |
| **不改 `Source.displayName`** | PRD / DAC / 代码三方一致（`npm/_npx`）；B1 的 `npm.npx` 是**来源标识**不是展示名（§二.7 歧义 A） |
| 不改 `ObservationProgress.remainingDays` | **已合规**（TC-036 满足） |
| 不动 `GateEvaluator.isQualified` | 不变量④ |
| 不 bump `schemaVersion` | 载体侧**零改动** |
| 不新增页面 / 状态类 / 用户动作 | PRD :70 |
| 不删 `ARCHITECTURE.md:87` 的既有漂移 | 既有漂移，不在本单范围（登记于 §十） |

---

## 七、验收判据

| # | 判据 | 验证方式 |
|---|---|---|
| 1 | 来源项行**带来源标识 + 类名 + 四数齐**：`<来源> · 样本不足 · 样本 11 / 总量 12（门槛 12，其中失联 1）` | 单测：**逐字**断言 |
| 2 | `样本不足` 行在基数形态**之后**追加逐字句「失联不补足，下一轮以新快照重算」 | 单测：逐字断言 + **位置断言**（追加句在四数之后） |
| 3 | 追加句**不携带任何数字**；该行**数字恰为 4 个** | 单测：正则抽取行内数字 ⇒ 断言个数 = 4（TC-038） |
| 4 | `L0 误判` 行逐字 = `<来源> · L0 误判 1 次（检查 128 次）」 | 单测：逐字断言 |
| 5 | `b = 0` 时行 = `<来源> · L0 未检查（检查 0 次）」 | 单测：逐字断言（**防御分支**，PRD M5 说不需单独立验收用例，但代码必须落到这一支） |
| 6 | 未判定态行 = `<来源> · L0 未判定（无法枚举本用户进程）」 | 单测：逐字断言（TC-032） |
| 7 | 样本不足 + L0 误判 ⇒ **2 行**、不合并；**归因说明**附在 `样本不足` 行后、**不单独成行** | 单测：断言数组长度 = 2 + 归因句在第 1 行内（DAC-78，0 容差） |
| 8 | 归因说明**仅在真误判（`a ≠ 0`）时**出现 | 单测：`a = 0` 的组合态 ⇒ 行内**不含**该句 |
| 9 | **固定顺序**：全局项在最前、来源项在后；同来源的行**连续** | 单测：断言首行含「轮次」且不含来源名、次行含来源名（DAC-74） |
| 10 | 空判定域 ⇒ 未达项**行数 = 0** | 单测（TC-034 / DAC-79） |
| 11 | 观察期内 ⇒ 只有全局项，**来源项数 = 0** | 单测（TC-027，用例①） |
| 12 | 计数日已满而报告未产出 ⇒ 全局项逐字「第 N 轮 · 观察期未满 · 待结算扫描（无需操作）」；**「剩余天数」格 = `—`** | 单测（TC-036） |
| 13 | 「剩余天数」是**独立格**、不并入未达项那一句 | 审查 `Pages.swift` 渲染结构（DAC-77）+ 单测断言两槽位分离 |
| 14 | 降级态（`degraded == true`）⇒ 判定域内来源呈现「L0 未判定（无法枚举本用户进程）」 | 单测 |
| 15 | ★ **本轮未结算的来源（`K == nil`）不得被误标为「L0 未判定」** | 单测（**回归护栏**：删掉启发式的证明） |
| 16 | 未达项串**全部来自 `UICopy`**，`Metrics` / `PageModelBuilder` 内无内联契约串 | 审查：`grep -n "L0 未判定\|样本不足" Sources/` ⇒ 命中仅 `UICopy` |
| 17 | `UnmetSourceItem.text` 已删除，全仓无残留 | `grep -rn "UnmetSourceItem" Sources/ Tests/` |
| 18 | 界面层无域内算术 | `./scripts/verify_a9.sh` |
| 19 | `SemanticSlot` 枚举 case 数仍 = 7 | `./scripts/verify_a9.sh`（:47-52 守栏） |
| 20 | 全部单测通过 | `swift test` |
| 21 | 页面结构 / 空实现 / 数据层接线未破 | `./scripts/verify_a9.sh` |
| 22 | 错误码表 ↔ 文档一致 | `python3 scripts/verify_codes.py` |
| 23 | 真 IO 往返自检通过 | `swift run --disable-sandbox ResidueApp --verify-wiring /tmp/wiring` |
| 24 | 文档基线未破（PRD + R2） | `./tests/contract/check_all.sh` + `python3 tests/verify_r2.py` |
| 25 | Release 编译通过 | `swift build -c release` |
| 26 | 设计稿重渲染（③ 页开关区行数变化） | `swift run --disable-sandbox ResidueApp --render-pages design-renders` |

---

## 八、TDD 步骤

> 铁律：**先写失败测试，看它以「功能缺失」的原因失败，再写实现**。

| # | 步骤 | 类型 | 验证（怎么确认它真的红 / 真的绿） |
|---|---|---|---|
| 1 | `MetricsTests` 新增「`样本不足` 载荷含四数」：断言 `items.bySource[0].item == .insufficientSample(sample: 11, total: 12, threshold: 12, lost: 1)` | **RED** | 编译失败（case 无带参构造）⇒ 属**预期红** |
| 2 | 实现 `SourceGateInput.lost` + `UnmetSourceItem.insufficientSample` 带参 + `GateEvaluator` 填载荷 | **GREEN** | 步骤 1 转绿 |
| 3 | 新增 `UICopy` 逐字断言：`unmetSampleInsufficient` 全串、`unmetSampleNote`、`unmetL0Misjudged`、`unmetL0NeverChecked`、`unmetL0Undetermined`、`unmetL0AttributionNote` | **RED** | 编译失败（函数不存在） |
| 4 | 实现 6 个 `UICopy` 串 + **删** `unmetSampleInsufficient(round:sample:threshold:)` + **删** `UnmetSourceItem.text` | **GREEN** | 步骤 3 转绿；`grep` 确认旧串已无残留 |
| 5 | 改 `PageModel.unmetNotice` → `unmetNotices: [SemanticSlot]`；改写 `PageModelBuilderTests` 三处断言为**数组**语义 | **RED** | 编译失败 ⇒ 预期红 |
| 6 | 实现 `PageModelBuilder.unmetNoticeSlots(_:) -> [SemanticSlot]`（全局项在前 + 按来源分组逐行 + 归因说明并入 `样本不足` 行）+ 只读态同步 | **GREEN** | 步骤 5 转绿 |
| 7 | 新增「两行不合并 + 归因说明在第 1 行内 + 行数 = 2」 | **RED → GREEN** | 先红后绿 |
| 8 | 新增「归因说明仅 `a ≠ 0` 时出现」 | **RED → GREEN** | 先红后绿 |
| 9 | 新增「固定顺序：全局项在前、来源项在后、同来源连续」 | **RED → GREEN** | 先红后绿 |
| 10 | 新增「空判定域 ⇒ 行数 = 0」 | **RED → GREEN** | 先红后绿 |
| 11 | 新增「`degraded == true` ⇒ 呈现 L0 未判定」 | **RED** | 应因现值非「L0 未判定」而失败 |
| 12 | **改** `undetermined` 源为 `input.degraded`、**删**启发式 | **GREEN** | 步骤 11 转绿 |
| 13 | ★ 新增**回归护栏**：「本轮未结算（`K == nil`）的来源**不得**被误标为「L0 未判定」」 | **RED → GREEN** | 先红（现状会误标）⇒ 改源后转绿 |
| 14 | 新增「`b = 0` ⇒ 「L0 未检查（检查 0 次）」」 | **RED → GREEN** | 先红后绿（防御分支） |
| 15 | 新增「追加句位置在四数之后」+「行内数字恰 4 个」 | **RED → GREEN** | 先红后绿（TC-038） |
| 16 | 新增「计数日已满而报告未产出 ⇒ 剩余天数格 = `—`」 | **RED → GREEN** | 先红后绿（现状已合规 ⇒ 允许**先写先绿**，但必须在改实现前写） |
| 17 | 改 `Pages.swift` ③ 页渲染为 `VStack` 多行（「剩余天数」仍独立格） | **GREEN** | 编译通过；`verify_a9.sh` 通过；设计稿渲染检查行数 |
| 18 | 改 `DesignSampleData.swift:63` | **GREEN** | 编译通过 + 设计稿重渲染 |
| 19 | 改 `MetricsTests` 两个用例名与注释（FDA → L0 未判定） | **REFACTOR** | 全绿 |
| 20 | `CLAUDE.md` 项数 139 → 140 | 文档 | `find docs -name "*.md" \| wc -l` = 140 |
| 21 | 回跑全部校验 + 改变更单 §十 实施记录 | 验收 | §七 的 20–26 项逐条通过，**并把实跑数字写进 §十** |

> **不在测试里复制生产解析逻辑**（CLAUDE.md §八）：本单测试一律**调用生产原语**
> （`GateEvaluator.unmetItems` / `UICopy.*` / `Source.displayName`），
> 不在测试里重写一份「四数齐」或「行首两段」的拼串逻辑。
> 唯一允许硬编码的是**契约给死的逐字串**（TC-038 的「样本 11 / 总量 12（门槛 12，其中失联 1）」）。

---

## 九、待裁决

> 以下 6 条**均给出建议方案**，不阻塞起草与实现；如评审给出不同裁决，按裁决调整。

| # | 待裁决 | 建议 | 理由 |
|---|---|---|---|
| ① | **DAC-75「封闭为三串」vs PRD 的 4 种呈现态** —— DAC-75 点名三串（`样本不足` / `L0 误判` / `L0 未判定（无法枚举本用户进程）`），但 PRD 组 A Then 另给了「`L0 未检查（检查 0 次)`」 | **在 CR-034 内订正 DAC-75 措辞**：把「封闭为三串」改为「封闭为**三类**（`样本不足` / `L0 误判` / `L0 未判定`）；其中 `L0 误判` 类的**呈现态**为三种逐字串：`L0 误判 N 次（检查 M 次）` / `L0 未检查（检查 0 次）` / `L0 未判定（无法枚举本用户进程）`。**出现第四种未达项类即不通过**」 | PRD 自己说「`b = 0` **仍属既有三类未达项之一，不新增未达项类**」⇒ 「类」与「串」是两个层级，DAC-75 把两者写混了；订正是让两份文档说同一件事。**DAC 无机器校验**（§二.3）⇒ 不构成脚本阻塞，但属**人工评审事项**，须评审签字 |
| ② | **PRD :1247「单行文本」vs AC-08 组 A Then / DAC-74「分行」** | **按分行实现**（本单已按此实现） | §二.7 歧义 B 的三条理由；且「单行文本」与同句的「不复制表格」并列 ⇒ 指的是**不用表格**。建议评审时在 PRD :1247 补一句澄清「（单行文本指不复制表格；行数按 AC-08 组 A Then）」——**本单不改 PRD**（改契约需独立变更单） |
| ③ | **类名在行内的位置** | **行 = `<来源> · <类名> · <载荷>`**（本单已按此实现） | ① DAC-75 的判定方法是「**造三态各一行，逐行读串比对**」⇒ 行内必须出现类名串；② PRD 用例 ①′ 的集合元素写法 `{<来源> · 样本不足, <来源> · L0 误判}` **恰是行首两段**；③ PRD :1247 的「uv cache · 样本 27 / 总量 30（门槛 30，其中失联 3）」是**只举基数形态段的简写**（它没给类名、没给追加句，而后者是 AC-08 组 A Then 的强制项 ⇒ 该句不可能是完整行） |
| ④ | **`J` 缺失时「其中失联」显示什么** | **显示 `—`**（本单已按此实现） | 不变量③：不知道就说不知道，不显示 0（0 会被读成「一条都没失联」）。**构造路径上不可达**（`J` 与 `K` 同写，`ObservationWriteback.swift:206-207`）⇒ DAC-76 的「四数 4/4」在验收路径上恒成立，`—` 只是防御分支 |
| ⑤ | **归因说明的承载形态** | **并入 `样本不足` 同一行文本**（本单已按此实现），且**仅 `a ≠ 0`（真误判）时**追加 | DAC-78 明写「**2 行（0 容差）**」+「作为附加说明附在 `样本不足` 行后，**不单独成未达项**」⇒ 独立成行会破 0 容差；「未判定」态下说「因存在 L0 误判」是**错的**（那不是误判，是没判）⇒ 触发条件收窄到真误判 |
| ⑥ | **PRD v5.6 内部自相矛盾** —— `:269`（v4.3 定点修单表「质量 Q8」行）仍写逐字串「`<来源>` · L0 未判定（**未取得 Full Disk Access**）」，而同版 `:1055`（AC-08 组 A Given，现行条文）已是「L0 未判定（**无法枚举本用户进程**）」 | **本单不改 PRD**（改契约需独立变更单 + 评审签字）⇒ 登记备查；建议另开变更单把 `:269` 的「文案 = 」改为**引用现行口径**（不写逐字串），避免下游照抄已废止串 | 〔CR-022 · 偏差 6〕+ R2 v1.10 §25.1 裁定一已定「无法枚举本用户进程」；本单 §3.2 删掉的正是这个旧串。**同一版本内两处说法不同 ⇒ 属契约缺陷**（不是「文档过时」）；`:269` 虽属修单表（历史记录），但它**明写「文案 = 」并落点在现行条款** ⇒ 会被当现行口径抄 |

---

## 十、实施记录

> **每项都写实跑结果与数字**，不写「已完成」。

> **实跑环境**：macOS（darwin arm64）· SwiftPM 包根 `ResidueApp/` · 仓库根 `自动化配置/` ·
> 分支 `gztcode/gate-link` · 基线 HEAD `4eaff64` · 实跑日期 2026-11-18。
> 判据编号沿用 §七（1–26），步骤编号沿用 §八（1–21）。

### 10.1 代码改动

| 文件 | 改动 | 状态 |
|---|---|---|
| `Sources/ResidueCore/Metrics.swift` | §3.1 `SourceGateInput` 加 `lost: Int?`（构造参数同步加 `lost: Int? = nil`）；§3.2 `UnmetSourceItem` 扩为 2 个**带参** case（`insufficientSample(sample:total:threshold:lost:)` / `l0Misjudged(missCount:checkCount:undetermined:)`）并**删 `text`**（连带删掉其中「未取得 Full Disk Access」旧口径串）；§3.3 `GateEvaluator.unmetItems` 填载荷（`threshold: Threshold.h(forTotal: t)` —— `H` 的唯一式子） | ✅ |
| `Sources/ResidueCore/SemanticSlot.swift` | §3.5 删 `unmetSampleInsufficient(round:sample:threshold:)`；增 6 个**逐字**文案函数：`unmetSampleInsufficient(source:sample:total:threshold:lost:)` / `unmetSampleNote()` / `unmetL0Misjudged(source:missCount:checkCount:)` / `unmetL0NeverChecked(source:)` / `unmetL0Undetermined(source:)` / `unmetL0AttributionNote()`；`lost == nil` ⇒ 「其中失联 `—`」（不变量③，不谎称 0） | ✅ |
| `Sources/ResidueCore/PageModel.swift` | §3.6 `unmetNotice: SemanticSlot` → `unmetNotices: [SemanticSlot]`。**未改 `SemanticSlot` 枚举** ⇒ 判据 19（枚举 case 数 = 7）未破 | ✅ |
| `Sources/ResidueCore/PageModelBuilder.swift` | §3.4 `undetermined` 由启发式（`a == 0 && b == 0 && T != nil && K == nil`）改为 `input.degraded`；§3.7 `unmetNoticeText` → **`unmetNoticeSlots(_:) -> [SemanticSlot]`**（全局项在前 → 按来源分组逐行 → 归因说明并入 `样本不足` 行）；另删兜底串「已达达标条件」—— 见 10.4 偏差① | ✅ |
| `Sources/ResidueApp/Pages.swift` | §3.8 ③ 页未达项改 `VStack` **多行**渲染（一项一行）；「剩余天数」仍为**独立格**（判据 13 / DAC-77） | ✅ |
| `Sources/ResidueApp/DesignSampleData.swift` | §3.9 同步新签名；样例由 1 条扩为 **2 条**（第 2 条 = `npm/_npx · L0 误判 1 次（检查 128 次）`）—— 见 10.4 偏差④ | ✅ |
| `CLAUDE.md` | §3.11 两处「`docs/` 下 **139** 份 `.md`」→ **140**。实测 `find docs -name "*.md" \| wc -l` = **140**。另：§二 `swift test` 的「当前 **459** 个」→ **472**（本单新增 13 条单测）—— 见 10.4 偏差⑥ | ✅ |
| `ARCHITECTURE.md` | §3.11 同源项数同步：`:34`「**459** 个单测」→ **472**、`:122`「编译 + **459** 单测」→ **472**、`:136`「**459** 个单测永远替代不了它」→ **472**；另 `:87`「59 份文件 / 21 个单号」→ **61 份文件 / 23 个单号**（实测 `find docs/changes -name "*.md" \| wc -l` = **61**，单号 = CR-001~CR-010 + CR-022~CR-034 共 **23** 个）—— 见 10.4 偏差⑦ / 10.6 | ✅ |
| `README.md` | §3.11 同源项数同步：`:194`「**459** 个单测」→ **472**（见 10.4 偏差⑦） | ✅ |
| `.github/workflows/ci.yml` | §3.11 同源项数同步（**本单开始前 CI 即为红**）：`:5`「440 个单测」→ **472**、`:121` 接线自检「79 项」→ **111**、`:141`「PRD **v5.5**」→ **v5.6**、`:145`「R2 **v1.8**」→ **v1.10** —— 见 10.4 偏差⑧ | ✅ |
| `.github/workflows/release.yml` | §3.11 同源项数同步：`:211`「**440** 单测全绿」→ **472**、「接线自检 **79** 项」→ **111** —— 见 10.4 偏差⑧。该 heredoc 会贴到**公开 Release 页** ⇒ 属对外文案 | ✅ |

**步骤 19 之外的额外改动**：`Metrics.swift` 另订正 **5 处注释口径**（6 行注释，「FDA」→ 「未判定（无法枚举本用户进程）」），依据与处置见 10.4 偏差③。

### 10.2 测试改动

| 文件 | 用例 | 状态 |
|---|---|---|
| `Tests/ResidueCoreTests/MetricsTests.swift` | helper `input(_:k:t:…)` 加 `lost:`；**新增 4 条**：`testUnmetSampleInsufficientCarriesFourNumbers`（判据 1）、`testUnmetSampleInsufficientKeepsMissingLostAsNil`（§3.2 可空语义）、`testUnmetCopyVerbatimStrings`（判据 2 / 4 / 5 / 6 逐字）、`testUnmetSampleCopyShowsDashWhenLostUnknown`（§九 ④「其中失联 `—`」）；**改名 2 条**：`testUnmetFDAUndetermined` → `testUnmetL0Undetermined`、`testUnmetSampleAndFDAUndeterminedTwoRows` → `testUnmetSampleAndL0UndeterminedTwoRows`（旧名带已废止口径）。用例数 **35 → 39** | ✅ |
| `Tests/ResidueCoreTests/PageModelBuilderTests.swift` | 新增 helper `digits(in:)`（**限定 ASCII** 抽取行内数字，见 10.5 陷阱）；3 处断言改写（`unmetNotice?` → `unmetNotices` 数组语义）；**新增 9 条**：`testSampleInsufficientAndL0MisjudgedStayTwoRows`（判据 7）、`testNoAttributionNoteWithoutRealL0Miss`（判据 8）、`testUnmetNoticesOrderGlobalFirstThenSources`（判据 9）、`testEmptyDecisionDomainProducesNoUnmetRow`（判据 10）、`testDegradedProducesL0UndeterminedRow`（判据 14）、`testUnsettledSourceIsNotLabeledL0Undetermined`（判据 15 回归护栏）、`testZeroCheckCountShowsL0NeverChecked`（判据 5）、`testSampleNoteFollowsBaseFormAndAddsNoDigits`（判据 2 位置 / 判据 3 计数）、`testDayQuotaReachedWithoutReportShowsDashForRemainingDays`（判据 12）。用例数 **35 → 44** | ✅ |

> 全仓单测 **472** 个（`swift test` 实跑），较基线新增 **13** 条。全部用例**只调用生产原语**
> （`GateEvaluator.unmetItems` / `UICopy.*` / `Source.displayName`），未在测试里复制拼串逻辑。

### 10.3 校验实跑结果

| 命令 | 结果 | 状态 |
|---|---|---|
| `swift build` | `Build complete!`（debug 编译通过） | ✅ |
| `swift build -c release` | `Build complete! (7.74秒)` —— Release 会裁掉 `#if DEBUG` 的自检入口，本项单独验过 | ✅ |
| `swift test` | `Executed 472 tests, with 0 failures (0 unexpected) in 2.068 秒` / `All tests passed` | ✅ |
| `./scripts/verify_a9.sh` | 通过 **80** 项 / 失败 **0** 项（含判据 18 界面无域内算术、判据 19 枚举 case 数 = 7、判据 21 页面结构与空实现） | ✅ |
| `python3 scripts/verify_codes.py` | 通过 **11** 项 / 失败 **0** 项（判据 22） | ✅ |
| `swift run --disable-sandbox ResidueApp --verify-wiring /tmp/wiring` | 通过 **111** 项 / 失败 **0** 项（判据 23，真 IO 往返） | ✅ |
| `./tests/contract/check_all.sh` | ✅ 全部校验通过 —— 结构落点 **191** + CR-022 **47** + 声明归零（9 条已实删命中数均为 0）+ 单一定义（未发现数量冲突）（判据 24 前半） | ✅ |
| `python3 tests/contract/verify_r2.py` | ✅ 全部通过 —— 结构 **30** + 落地 **65** + 归零 **16** + 一致 **10** + 自洽 **2**（判据 24 后半） | ✅ |
| `swift run --disable-sandbox ResidueApp --render-pages design-renders` | 共渲染 **16** 张 → `design-renders/`（判据 26；③ 页可见 2 行未达项 ⇒ 行数由 1 变 2） | ✅ |
| `./scripts/make_app.sh` | `build/Residue.app` + `build/Residue.app.dmg`（SHA256 `6a8c4b7427354f678fed7840173a2dc03d6fc133b42e6e8c8ba2718f938d1606`；无证书时 ad-hoc 签名） | ✅ |
| `./scripts/verify_a5.sh` | 通过 **42** 项 / 失败 **0** 项 / **未覆盖 3 项**（未覆盖项如实登记、不算通过：① 本机无 Developer ID 身份 ⇒ 无法公证 / staple；② 已实现 11 处但 ad-hoc 下必抛 `kSMErrorInvalidSignature` ⇒ 需真身份；③ 需 GUI 会话人工确认「完全磁盘访问权限」⇒ 属 A-10） | ✅ |
| `python3 tests/contract/verify_counts.py` | 一致 **9** 项 / 不一致 **0** 项 / 未覆盖 **4** 项（wiring 111 ×2、a5 42 ×2 —— 本脚本**不实测**这两项，需编译 / 打包）⇒ **EXIT=0**。**改前为「一致 7 / 不一致 2」⇒ EXIT=1（红）** —— 见 10.4 偏差⑧ | ✅ |

**判据 16 / 17（审查项）**：`grep -rn "L0 未判定\|样本不足" Sources/` ⇒ 契约串字面量**仅**命中 `SemanticSlot.swift`（`UICopy`）；`grep -rn "UnmetSourceItem" Sources/ Tests/` ⇒ 仅剩 enum 定义 + 属性类型 + init 参数，**无 `.text` 残留** ✅

### 10.4 偏差登记

| # | 偏差 | 处置 |
|---|---|---|
| ① | **兜底串「已达达标条件」被删除** —— 原 `PageModelBuilder` 在「无未达项」时返回 `L.pick("已达达标条件", "Gate conditions met")`。**§三 未列此改动** | **删**。同 §3.2「删第二套文案实现」同源处置：该串**不是未达项**（PRD 组 A 的未达项只有 2 类来源项 + 至多 1 类全局项）⇒ 留在集合里会变成**第四种未达项类**，破 DAC-75（§九 ①）。副作用见偏差② |
| ② | 删兜底串后，**无未达项时 ③ 页显示「未达项读取中」** —— 语义不准（那是「读取中」，不是「无未达项」） | **本单不处理**，登记备查（10.6）。补法需在 `PageModel` 增「未达项已加载」状态位或新增槽位 ⇒ 属**新增界面状态**，超出 §三 范围且会动 `SemanticSlot` 面 ⇒ **待另开变更单** |
| ③ | `Metrics.swift` **5 处注释口径订正**（6 行注释，「FDA」→「未判定（无法枚举本用户进程）」），超出 §八 步骤 19 的范围 | **保留**。依据：R2 v1.10 §25.1 裁定一 `:40` / `:458` 已裁定未判定口径 = 「**无法枚举本用户进程**」、**不判定 FDA 是否授予** ⇒ 原注释描述的正是本单 §3.4 改过的 `undetermined` 语义，且与代码新行为**矛盾** ⇒ 属「因本次改动而失效的注释」，随改动一并订正 |
| ④ | `DesignSampleData` 样例由 1 条扩为 **2 条**（§3.9 只给 1 条） | **保留**。理由：判据 26 要求「③ 页开关区**行数变化**」可核对 ⇒ 只给 1 条，渲染出来仍是 1 行，看不出「一项一行、逐行独立、来源项各带来源标识」（DAC-74）。第 2 条取**另一个来源**（`npm/_npx`）⇒ **不触发**归因说明（归因只附在**同一来源**的 `样本不足` 行后），保持样例自洽 |
| ⑤ | §3.10 写「`MetricsTests` 新增 **8** 条用例」，实跑为**新增 4 条 + 改名 2 条**（全仓新增合计 **13** 条：`MetricsTests` +4 / `PageModelBuilderTests` +9） | **以实跑为准**；§三 正文**不改**（冻结后的条款）。差异成因：§八 步骤 3（`UICopy` 逐字断言）实际拆成 **2** 条用例（逐字串 + `lost == nil` ⇒ 「其中失联 `—`」），另加 1 条 `lost == nil` 载荷护栏（`testUnmetSampleInsufficientKeepsMissingLostAsNil`），该条对应 §3.2「`lost` 为何可空」而非 §八 某一步 |
| ⑥ | `CLAUDE.md` §二 的「全部单测（当前 **459** 个）」**因本单新增 13 条单测而失准** —— §三 3.11 只列了「文档份数 139 → 140」，未列单测数 | **一并改为 472**（实测 `swift test` = `Executed 472 tests, with 0 failures`）。同属「项数同步」，与 §八 步骤 20 同一原则；不改 §三 / §八 正文。该声明**无机器校验**（`tests/contract/` 下无脚本读 `CLAUDE.md`）⇒ 靠纪律 |
| ⑦ | **导航文件声明面失准** —— `ARCHITECTURE.md` 三处 + `README.md` 一处的「**459** 个单测」因本单新增 13 条而失准；另 `ARCHITECTURE.md:87`「59 份文件 / 21 个单号」实测为 **61 份 / 23 个单号**（CR-033、CR-034 各增 1 单号） | **一并改为 472 / 61 份 / 23 个单号**（实测 `find docs/changes -name "*.md" \| wc -l` = 61，单号 = CR-001~CR-010 + CR-022~CR-034）。与偏差⑥ 同源（项数同步），§三 3.11 只点名了 `CLAUDE.md` ⇒ 记此偏差。同样**无机器校验** ⇒ 靠纪律 |
| ⑧ | **CI 门禁 `tests/contract/verify_counts.py` 在本单开始前已红** —— 该脚本比对 `.github/workflows/*.yml` 注释里声明的项数与脚本实测值。实测起点「一致 7 / 不一致 **2**」⇒ `ci.yml:5` 与 `release.yml:211` 的「440 个单测」≠ 实测 472。**分段归因**：`440 → 459` 段由 CR-032 / CR-033 的 19 条新单测造成（`4eaff64` 只同步了 `ARCHITECTURE.md` / `README.md`，**漏了 workflow**），`459 → 472` 段由本单 13 条造成。另四处属**纯既有漂移**：`ci.yml:121` + `release.yml:211` 接线自检 79 → 111、`ci.yml:141` PRD v5.5 → v5.6、`ci.yml:145` R2 v1.8 → v1.10 | **按脚本要求「改注释，不改实测值去迁就注释」**，把两处 workflow 的声明拉齐到当前实测值（472 / 111 / PRD v5.6 / R2 v1.10）⇒ 复跑 **EXIT=0**（一致 9 / 不一致 0 / 未覆盖 4）。**如实归因**：440 / 79 / v5.5 / v1.8 这几处漂移**不是本单造成的**，但**不修则 CI 一直红** ⇒ 本单顺手同步。`release.yml` 的同一段 heredoc 会贴到**公开 Release 页** ⇒ 属对外文案，必须准 |

### 10.5 防假绿验证（破坏性变异）

> 目的：证明新写的测试**真的能抓住回归**，而不是恒绿。
> 每条变异都是**临时改坏实现 → 实跑 → 看红 → 还原**（全部已还原，当前树为变异前状态）。

| # | 变异 | 实跑红输出 | 被哪条判据抓住 |
|---|---|---|---|
| A | `GateEvaluator`：`a ≠ 0` 时**不产** L0 行 | `Executed 39 tests, with 5 failures`：`testSampleInsufficientAndL0MisjudgedStayTwoRows`（行数 **1** ≠ **2**，且数组缺第 2 行） | 判据 7 / 4 |
| B | 归因说明触发条件由 `a > 0` 放宽为 `a >= 0` | `Executed 39 tests, with 1 failure`：`testNoAttributionNoteWithoutRealL0Miss`（`a = 0` 的组合态仍出现归因说明） | 判据 8 |
| C | 全局项**挪到**来源项之后 | 同 A 轮次：`testUnmetNoticesOrderGlobalFirstThenSources`（全局项错位 + 报「全局项不带来源标识」） | 判据 9 |
| D | 空判定域时**补一行** | 同 A 轮次：`testEmptyDecisionDomainProducesNoUnmetRow`（**1** ≠ **0**） | 判据 10 |
| E | 删 `Metrics.swift` 里 `b == 0` 分支 | `testZeroCheckCountShowsL0NeverChecked`：`("[]")` ≠ `("["uv cache · L0 未检查（检查 0 次）"]")` | 判据 5 |
| F | 追加句**前置**到四数之前 | `testSampleNoteFollowsBaseFormAndAddsNoDigits`：`(["失联不补足… · npm/_npx · 样本不足…"])` ≠ 期望 | 判据 2（位置） |
| G | 追加句携带 `" 5"` | 同上用例 **2** 处失败：`("[11, 12, 12, 1, 5]")` ≠ `("[11, 12, 12, 1]")` | 判据 3 |
| H | `ObservationProgress.remainingDays` 的 `guard countedDays < requiredDays else { return nil }` 改为 `return 0` | `testDayQuotaReachedWithoutReportShowsDashForRemainingDays`：`("0 天")` ≠ `("—")` | 判据 12 |

> A / C / D 是**同一轮同时注入**（合计 5 failures）；B 是**第二轮单独注入**（1 failure）。

**真红（首写即红）记录** —— 不是事后补的「变异」，而是 TDD 循环里**先写的测试当场就红**：

| 步骤 | 红的原因（逐字） |
|---|---|
| 步骤 1 | 编译失败 —— `case` 无带参构造 |
| 步骤 3 | 编译失败 —— 6 个 `UICopy` 函数不存在 |
| 步骤 5 | 编译失败 —— `unmetNotice` → `unmetNotices` 未改 |
| 步骤 11 | `testDegradedProducesL0UndeterminedRow` RED（现值非「L0 未判定」） |
| 步骤 13 | `testUnsettledSourceIsNotLabeledL0Undetermined` RED —— `XCTAssertFalse failed - 未结算（`K == nil`）≠ 枚举失败 ⇒ 不得标「L0 未判定」（实为「["uv cache · L0 未判定（无法枚举本用户进程）"]"）」；改源后转绿 |

**实现陷阱（判据 3 的前提）**：Swift 的 `Character.isNumber` 对**中文数字字形**（「一」= U+4E00）返回 `true`，而 `Int("一")` 为 `nil` ⇒ 抽取行内数字的 helper `digits(in:)` **必须限定 ASCII**（`ch.isASCII && ch.isNumber`），否则会把「一」当成数字，判据 3 的「恰 4 个」变成假绿。

### 10.6 已知既有漂移（**本单不处理**，登记备查）

- ~~`ARCHITECTURE.md:87`：「59 份文件 / 21 个单号」~~ —— **本单已处理**（改为 61 份 / 23 个单号，见 10.1 / 10.4 偏差⑦）。
- `ARCHITECTURE.md:150`：「`K` / `J` / `doneCount` / `fSetBits` 等……尚未接线」—— CR-031 已接线，表述过时。
- `TrashExecutor.swift:160` `bytesKind` / `AppModel.swift:1105` `let deleted` —— 历史死代码（指出但不擅自删除）。
- `StateStore.swift:84` 的 `beginNextRound()` —— 未投产历史死代码。
- R2 §5.1 示例 `uv.cache` vs 代码 rawValue `uv_cache`。
- **无未达项时 ③ 页显示「未达项读取中」** —— 删兜底串「已达达标条件」后的副作用（10.4 偏差②）：语义不准，需另开变更单补「未达项已加载」状态。
- **保留未动的 4 处 FDA 措辞** —— `L0Probe.swift:46`（跨 uid 恒 `EPERM` 的事实陈述）、`DiagnosticCode.swift:151`（规范约束「**不得**写『未取得 Full Disk Access』」）、`Metrics.swift:372`（单条候选层）、`L0SnapshotAssemblyTests.swift:106`（测试注释）。四者均属**另一层语义**，不是本单 §3.4 的来源级 `undetermined` 语义 ⇒ 本单不动。
- **§七 判据 24 的脚本路径过时** —— 条文写 `python3 tests/verify_r2.py`，实际脚本在 `tests/contract/verify_r2.py`（仓库根 `tests/` 下只有 `contract/` 一个目录）。本单按**实际路径**实跑，**未改判据正文**。
- **PRD v5.6 内部自相矛盾** —— `:269`（v4.3 定点修单表「质量 Q8」行）仍写「`<来源>` · L0 未判定（**未取得 Full Disk Access**）」，而同版 `:1055`（AC-08 组 A Given 现行条文）已是「L0 未判定（**无法枚举本用户进程**）」。**本单不改契约** ⇒ 登记备查，待裁决（§九 ⑥），建议另开变更单订正。
- **设计稿顶部裁切** —— `PageRenderer.size` 固定 1000×640，③ 页内容超高 ⇒ `design-renders/03-清理策略.png` 顶部被裁切（**既有渲染限制**，非本单引入）。核对方式：可见 **2 行**未达项（第 1 行下半截 + 第 2 行完整「npm/_npx · L0 误判 1 次（检查 128 次）」）⇒ 行数由 1 变 2，判据 26 达成。
