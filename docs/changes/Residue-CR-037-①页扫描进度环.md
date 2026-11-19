# CR-037 · ① 页扫描进度环（按来源推进的确定环）· P1 · 扫描期间一直显示静态「正在扫描…」，且①页加载态缺「取消」按钮

> **缺陷**（编号是全文的**唯一引用口径**，`#N` 与 §1.2 的复现路径一一对应）：
> - **缺陷 #1 · ① 页加载态没有「取消」按钮** —— `ResidueApp/Sources/ResidueApp/Pages.swift:32` 的 `LoadingView(message: model.loadingMessage)` **不传 `onCancel`** ⇒ `ResidueApp/Sources/ResidueApp/Components.swift:306` 的 `if let onCancel` 恒不成立 ⇒ DAC-105「两要素（进度文案 + `取消` 按钮）」只满足 **1/2**。
> - **缺陷 #2 · 取消按钮落点错** —— 取消按钮在**页头**（`ResidueApp/Sources/ResidueApp/RootView.swift:151-154`），而 DAC-105 与视觉基线 §三要求它在**① 页内容区顶部**（`ResidueApp/Sources/ResidueApp/Components.swift:307` 的实现就写在加载态里，只是没被传进去）。
> - **缺陷 #3 · ① 页加载态的「进度文案」是静态串** —— `ResidueApp/Sources/ResidueCore/PageModel.swift:79` 写死 `L.pick("正在扫描…", "Scanning…")`；真正的实时进度文字（`ResidueApp/Sources/ResidueApp/RootView.swift:134`）**被放在页头** ⇒ 违视觉基线 §三「内容区顶部，进度文案 + 取消按钮」。
> - **缺陷 #4 · 扫描起手页头连「正在扫描」都不显示** —— `ResidueApp/Sources/ResidueApp/AppModel.swift:486` 起手写 `scanProgress = ScanProgress()` ⇒ `isRunning == false` ⇒ `ResidueApp/Sources/ResidueApp/ScanInfrastructure.swift:51` 的 `guard isRunning else { return "" }` 使 `displayText` 返回 `""` ⇒ `RootView.swift:133` 的 `!app.scanProgress.displayText.isEmpty` 不成立 ⇒ **页头空白**。用户看到的就是「一直显示正在扫描」——**正是本次要修的现象**。
> - **缺陷 #5 · 环形指示器是不定进度 spinner，不是「按来源推进的确定环」** —— `ResidueApp/Sources/ResidueApp/Components.swift:300` 的 `ProgressView()` + `.progressViewStyle(.circular)` 是系统不定 spinner ⇒ 弧长与实际进度无关。
> - **缺陷 #6 · ① 页加载态是整页替换** —— `ResidueApp/Sources/ResidueApp/Pages.swift:31-33` 的 `if model.loading { LoadingView } else { 正常内容 }` ⇒ 扫描时三区块 / 状态条 / 空态**全部消失** ⇒ 与视觉基线 §五「① 页 = 三区块 + 状态条 + **加载态**」骨架不符。
> - **缺陷 #7 · 跨来源条目计数倒退** —— `ResidueApp/Sources/ResidueCore/ScanEngine.swift:506` 的 `var filesScanned = cp.countedFiles` 让每个来源**从各自断点起算**，而 `ResidueApp/Sources/ResidueApp/AppModel.swift:586-594` 每次 `report` 是**整份替换** ⇒ 「已扫描 N 项」在来源边界**跳回小值**。`candidatesFound` 同款（`ScanEngine.swift:572`）。
> - **缺陷 #8 · 小来源永不触发进度回调** —— `ResidueApp/Sources/ResidueCore/ScanEngine.swift:493` 的 `progressEvery: Int = 2000` ⇒ 条目数 < 2000 的来源**一次回调都不触发** ⇒ 进度长时间停在 0/3 再突然跳到 1/3。
>
> **契约依据**：DAC-105（`docs/contract/Residue-DAC-v2.0.md:304`）· 视觉基线 §三加载行（`docs/contract/Residue-视觉基线-v1.1.md:86`）· 视觉基线 §二信号色优先级（`docs/contract/Residue-视觉基线-v1.1.md:28-90`）· 视觉基线 §五①页骨架（`docs/contract/Residue-视觉基线-v1.1.md:124`）· PRD C-17（`docs/contract/Residue-PRD-v5.6.md:1247`）· PRD AC-20（`docs/contract/Residue-PRD-v5.6.md:1182-1185`）· PRD N1（`docs/contract/Residue-PRD-v5.6.md:1213`）· PRD §8 加载行（`docs/contract/Residue-PRD-v5.6.md:1279`）· `E-103`/`E-104`（`docs/contract/Residue-R2-技术方案-v1.10.md` §6 错误码表，见 `ResidueApp/Sources/ResidueCore/DiagnosticCode.swift:46-49`）。
>
> **性质**：**功能缺失 + 实现错误 + 契约违例**（三类 —— ①「取消」按钮缺失与落点错（#1 / #2）是**功能缺失 + DAC-105 违例**；②静态文案、整页替换（#3 / #6）是**契约违例**；③跨来源计数倒退、小来源不回调（#7 / #8）是**实现错误**）。
>
> **状态**：**待实现**（变更单先行；代码落地须按 §八 TDD 步骤）
>
> **修订记录**：
> - **v1 · 2026-11-19**：初稿。取证完成（缺陷 9 条、契约依据 14 处、既有机器守卫 17 条）；§2.7 登记 5 条契约内部歧义并逐条裁决；§3 给出 17 项改动；§4 影响面含 21 个代码引用点 + 8 个测试引用点 + 13 处声明面数字；§九 5 条待裁决。
> - **v2 · 2026-11-19**：**证伪并删除 1 条缺陷**（原第 9 条「跨来源『已用时』归零」）—— `AppModel.swift:583` 传给引擎的 `now: started` 是**全局扫描起点**（`AppModel.swift:489`，位于来源循环**之外**）⇒ 引擎内的 `elapsed` **本来就是总耗时**，切来源**不归零**。缺陷清单由 9 条改为 **8 条**；头部缺陷**编号显式化**（`#N` 成为全文唯一引用口径）；§3.7 的 `engine.scan` 调用改写为 `AppModel.swift:566-596` 的**真实形态**；§3.7 的 elapsed 取值理由改写（原理由错误）。

---

## 一、缺陷

### 1.1 现象

用户按「扫描」后，① 页（只读存储总览）发生三件事：

1. **整页被替换成一张静态卡片**：一个系统 spinner + 一行永远不变的「正在扫描…」。三区块（占用 / 可回收 / 已用时）、状态条、空态全部消失。
2. **页头右侧出现一行实时文字**「已扫描 12,847 项 · 已用时 3.2 秒」，但它**不在内容区顶部**，且**扫描刚开始时是空的**（起手那一拍 `displayText == ""`）。
3. **① 页内容区里没有「取消」按钮** —— 取消按钮在页头，且**是唯一一处**。用户若把视线放在内容区（产品的重心在内容区，视觉基线 §三把加载态放在「内容区顶部」），找不到取消入口。

净效果就是用户报的那句话：**「一直显示正在扫描」** —— 既看不到一个能动的圆圈（spinner 是不定进度，与实际进度无关），也看不到真实进度在内容区里走，更看不到「还剩多少」。

### 1.2 复现路径（代码级）

**路径 A —— 扫描起手页头空白**

1. `ResidueApp/Sources/ResidueApp/RootView.swift:141` 点「扫描」⇒ `Task { await app.runScan() }`。
2. `ResidueApp/Sources/ResidueApp/AppModel.swift:485` `isScanning = true`；`:486` `scanProgress = ScanProgress()` ⇒ `isRunning == false`。
3. `ResidueApp/Sources/ResidueApp/ScanInfrastructure.swift:51` `guard isRunning else { return "" }` ⇒ `displayText == ""`。
4. `ResidueApp/Sources/ResidueApp/RootView.swift:133` `if app.isScanning, !app.scanProgress.displayText.isEmpty` ⇒ **条件不成立 ⇒ 页头不显示任何进度**。
5. 此时内容区 `ResidueApp/Sources/ResidueApp/Pages.swift:32` 的 `LoadingView(message: model.loadingMessage)` 显示 `ResidueApp/Sources/ResidueCore/PageModel.swift:79` 的静态串「正在扫描…」。
6. ⇒ **用户在这一拍看到的正是「一直显示正在扫描」**。

**路径 B —— ① 页无取消按钮（DAC-105 两要素只满足 1/2）**

1. `ResidueApp/Sources/ResidueApp/Pages.swift:31-32`：`if model.loading { LoadingView(message: model.loadingMessage) }` —— **只传 `message`，不传 `onCancel`**。
2. `ResidueApp/Sources/ResidueApp/Components.swift:296` `var onCancel: (() -> Void)?` ⇒ `nil`。
3. `ResidueApp/Sources/ResidueApp/Components.swift:306` `if let onCancel {` ⇒ **永不成立** ⇒ `:307` 的「取消」按钮**永远不渲染**。
4. ⇒ DAC-105 的「两要素 2/2」判据**只满足 1/2**。

**路径 C —— 取消按钮落点错（页头 ≠ 内容区顶部）**

1. 全仓唯一的取消按钮在 `ResidueApp/Sources/ResidueApp/RootView.swift:151-154`。
2. 它属于**页头**（`RootView.swift:113` `private var header`），不是 ① 页内容区。
3. DAC-105（`docs/contract/Residue-DAC-v2.0.md:304`）要求「① 页加载态含两要素」；视觉基线 §三加载行（`docs/contract/Residue-视觉基线-v1.1.md:86`）要求「**内容区顶部**，进度文案 + 取消按钮」。
4. ⇒ **落点违契约**。（注意：`Components.swift:307` 的取消按钮实现**就写在加载态里**——组件设计是对的，只是没人把 `onCancel` 传进去。）

**路径 D —— ① 页加载态是整页替换**

1. `ResidueApp/Sources/ResidueApp/Pages.swift:31` `if model.loading {` … `:33` `} else {` ⇒ **else 分支才是正常内容**。
2. ⇒ 扫描期间 `Pages.swift:36` 的 `StatusBar`、`:41` 的 `ExecutionNoticeCard`、`:49` 的 `FirstRunEmptyState`、三区块**全部不渲染**。
3. 视觉基线 §五（`docs/contract/Residue-视觉基线-v1.1.md:124`）：「① 只读存储总览 | **三区块 + 状态条 + 加载态**」⇒ 加载态是**与三区块并存的第四件**，不是整页替换。
4. ⇒ **骨架违契约**。

**路径 E —— 环形指示器是不定 spinner，不是确定环**

1. `ResidueApp/Sources/ResidueApp/Components.swift:299-303`：`ProgressView()` + `.progressViewStyle(.circular)` + `.tint(Tokens.Color.signal)`。
2. 系统 `.circular` 样式是**不定进度**——弧长由系统动画驱动，与「扫了多少」无关。
3. ⇒ 用户看到的圈**不表达任何进度**。（DAC-105 只要求「信号色着色区落在进度环上」，未区分确定/不定 ⇒ 现状**名义上满足** DAC-105 ⇒ 这是一条**契约空白**，见 §2.7 歧义 A。）

**路径 F —— 跨来源条目计数倒退**

1. `ResidueApp/Sources/ResidueCore/ScanEngine.swift:506`：`var filesScanned = cp.countedFiles` ⇒ 每个来源**从各自的续扫断点起算**（不是从 0，也不是从全局累计）。
2. `ResidueApp/Sources/ResidueCore/ScanEngine.swift:568-573`：回调报 `filesScanned: filesScanned`（**本来源内的数**）。
3. `ResidueApp/Sources/ResidueApp/AppModel.swift:586-594`：`cancelBox.report(ScanProgress(source: p.source, filesScanned: p.filesScanned, …))` ⇒ **整份替换**，`filesScanned` **没有跨来源累加**。
4. ⇒ 扫完 uv（11 万项）时显示「已扫描 115,875 项」；切到 npm 时**跳回** npm 自己的小值 ⇒ **数字倒退**。
5. `candidatesFound` 同款（`ScanEngine.swift:572` 报的是本来源内的候选数）。
6. ⚠️ `ResidueApp/Tests/ResidueCoreTests/ScanConcurrencyTests.swift:188-198` 的 `testProgressCountsAreMonotonic` **只覆盖单个来源内的一次 `engine.scan`** ⇒ **这条路径无任何测试覆盖**。

**路径 G —— 小来源永不触发进度回调**

1. `ResidueApp/Sources/ResidueCore/ScanEngine.swift:493`：`progressEvery: Int = 2000`。
2. `ResidueApp/Sources/ResidueCore/ScanEngine.swift:568`：`if filesScanned % max(1, progressEvery) == 0 { progress(…) }`。
3. ⇒ 条目数 < 2000 的来源**一次都不触发**。
4. ⇒ 若 pipx 目录只有 20 个文件，扫完它时进度**原地不动**；分子（完成来源数）也因为没有回调而不推进 ⇒ 用户看到 0/3 卡住很久，然后突然 1/3、2/3。

**已证伪的假设 —— 跨来源「已用时」归零（v2 删除）**

原稿曾把「切来源时『已用时』回到 0.0 秒」列为缺陷，v2 取证后**证伪**：

1. `ResidueApp/Sources/ResidueCore/ScanEngine.swift:490` 的签名是 `now: Date = Date()` —— **`Date` 值**，不是闭包。
2. `ResidueApp/Sources/ResidueApp/AppModel.swift:583` 传的是 `now: started`；`started` 是 `AppModel.swift:489` 的**全局扫描起点**，位于来源循环**之外**。
3. `ResidueApp/Sources/ResidueCore/ScanEngine.swift:495` 的 `let startedAt = now` ⇒ `startedAt == started`（**同一个起点**）。
4. `ResidueApp/Sources/ResidueCore/ScanEngine.swift:573` 的 `elapsed: Date().timeIntervalSince(startedAt)` ⇒ **本来就是总耗时**。
5. ⇒ **切来源不归零**。原稿的错因：看到「每次 `engine.scan` 都重新 `let startedAt = now`」就以为起点会重置，**没看调用方传的是什么**。

⇒ **纪律仍然成立**：`elapsed` 的起点必须由**调用方**通过 `now` **显式固定**。若将来有人在来源循环内写成 `now: Date()`，归零会真的发生 ⇒ §七 判据 10 与 §八 步骤 3 的 `testElapsedDoesNotResetAcrossSources` **作为回归防护保留**，但它们**不是**在修本次的缺陷。

### 1.3 第二个后果 —— 文件级进度在快机器上永远不涨

`ResidueApp/Sources/ResidueApp/WiringSelfCheck.swift:570` 的自检必须显式传 `progressEvery: 100` 才能让 `WiringSelfCheck.swift:578` 的 `reported.filesScanned > 0` 成立 ⇒ **在默认 `progressEvery = 2000` 下，条目数少于 2000 的来源，「已扫描 N 项」恒为 0**。

用户此时看到的是「已扫描 0 项 · 已用时 0.4 秒」——**一个恒定不动的数字，比没有数字更糟**：它宣称「我知道进度是 0」，而实际是「我还没开始数」。

⇒ 这与 `ResidueApp/Sources/ResidueApp/ScanInfrastructure.swift:46-49` 自己的注释一致：

> 「## 为什么写「已扫描 N 项」而不是「已完成 x%」
> 总条目数**事先不知道**（要先扫一遍才知道）→ 百分比是假的。
> 「已扫描 N 项 + 已用时」是**能如实说出口**的量。」

**⇒ 本次要显示的圆圈，分母必须是「来源数」** —— 它是**唯一事先已知、且不多不少**的量（`resolveSourceRoots` 返回固定的 3 个根，但实现上必须取运行时 `roots.count` 而不是写死 3）。

### 1.4 与其它单的关系

| 单号 | 范围 | 与本单的关系 |
|---|---|---|
| CR-034 | ③ 页未达项完整披露 | **无重叠**。CR-034 在 ③ 页，本单在 ① 页。 |
| CR-035 | ⑤ 页 ③ 列补失联 `J` | **无重叠**。CR-035 在 ⑤ 页，本单在 ① 页。 |
| CR-036 | ③ 页未达项区三态 | **无重叠**。CR-036 在 ③ 页，本单在 ① 页。**实施顺序：CR-036 先、CR-037 后**（CR-036 会动 `UICopy` 与 `SemanticSlot` 的周边，先做完可避免同文件双改）。 |
| 遗留 | ① 页首启空态文案「还没有扫描过」是 DAC-80 违例 | **本单不处理**，登记备查（见 §五）。 |

---

## 二、契约依据

### 2.1 DAC-105（`docs/contract/Residue-DAC-v2.0.md:304`，§4.9 ① 加载态 · AC-20）

> `| **DAC-105** | ① 页加载态含**两要素**：①进度文案（非空）②\`取消\` 按钮（可点击）。**信号色名额口径（本条最容易判错，写死）**：该屏信号色着色区 **= 1 处，且该名额按视觉基线 §三 归「进度环」**（基线 §三 加载行明写「中性 + 信号色（进度环）」）；**取消按钮取中性色**（\`textSecondary\` 或 \`textPrimary\`），**不得用信号色、不得用危险色**——它是该屏唯一可执行动作，但信号色名额已被进度环占用，这不是违规而是基线指定 | 两要素 2/2；信号色着色区 = 1 且落在进度环上；取消按钮像素核色相 | 视觉基线 §三 加载行「内容区顶部，进度文案 + **取消按钮**」「中性 + 信号色（进度环）」+ AC-20 Then「可随时取消」+ S-02 采纳 | AC-20 | 定位加载态两要素；数信号色着色区 = 1 并核其在进度环上；取取消按钮像素核色相 |`

**逐项对照现状**：

| DAC-105 判据 | 现状 | 判定 |
|---|---|---|
| 两要素 2/2 | 进度文案 ✓（静态串）+ 取消按钮 ✘（`Pages.swift:32` 不传） | **1/2 ⇒ 违例** |
| 信号色着色区 = 1 且落在进度环上 | `ProgressView(.circular).tint(signal)` 1 处 ✓ | **满足**（但见 §2.7 歧义 A） |
| 取消按钮色相 ∈ {中性}，0 容差 | 页头取消按钮用 `SecondaryButtonStyle` ⇒ `textPrimary` + `divider` 描边 ✓ | **满足**（但落点错 ⇒ 见 §2.2） |

⇒ **本单的第一使命是把 DAC-105 从 1/2 拉回 2/2，并把两个要素搬到契约指定的位置。**

### 2.2 视觉基线 §三 八态视觉映射（`docs/contract/Residue-视觉基线-v1.1.md:86`）

> `| **加载** | 环形进度 | 内容区顶部，进度文案 + 取消按钮 | 中性 + 信号色（进度环）|`

三个硬要素：**① 环形进度**、② **内容区顶部**（不是页头）、③ **进度文案 + 取消按钮**。

⇒ 现状：环形 ✓（但是不定 spinner）；内容区顶部 ✘（取消按钮在页头、进度文案在页头）；两要素 ✘（内容区里没有取消按钮，静态串不是真进度）。

### 2.3 视觉基线 §五 ① 页骨架（`docs/contract/Residue-视觉基线-v1.1.md:124`）

> `| ① 只读存储总览 | 三区块 + 状态条 + 加载态 | 三区块各一个 \`.metric\`；状态条承载「并发冲突」 |`

⇒ **加载态与三区块、状态条是并列的三件**，不是「加载态 = 整页」。现状的整页替换**违此骨架**。

### 2.4 视觉基线 §二 信号色规则（`docs/contract/Residue-视觉基线-v1.1.md:28-90`）

> `| **信号色（唯一强调）** | \`#5E6AD2\` | 主按钮、可点亮、焦点环、选中态 |`
> `| **中性提示** | 次文字色 | 空态、加载文案（**不加第三种色**） |`
> `**规则（v1.1 改写：从「数次数」改成「取优先级」）**`
> `### 信号色：优先级规则`
> `**唯一名额仍然只有一个**，但只回答「给谁」，不再需要「数次数」。每屏**只兑现优先级最高的一个**，其余全部退到中性表达：`
> `| 优先级 | 承载物 | 条件 |` / `| **1** | **主行动按钮** | 每屏最多一个可执行主按钮（提交 / 确认 / 清除） |` / `| **2** | **焦点环** | 键盘焦点，且**仅当该屏无主行动时** |` / `| **3** | **选中态** | 侧栏 / 分段控件当前项，且**仅当该屏无主行动、无焦点环时** |`
> `### 逐行属性标记：**永久不进入信号色**（不是例外，是不属于合法用途）`
> `**危险色**：只用于「这一步不可逆」的提示。**不引入绿/黄/蓝等额外语义色**——七态靠图标与文案区分，不靠颜色堆叠。`

⇒ 两条硬约束落到本单：

1. **扫描期 ① 页的信号色着色区必须恰好 1 处，且落在进度环上**（DAC-105 写死）。
2. **「其余全部退到中性表达」** ⇒ 扫描期若 ① 页上还有别的信号色承载物（空态的「开始扫描」主按钮、执行结果卡的 accent），**必须退到中性**——但**不能隐藏**（隐藏 = 改变信息量；退到中性 = 改变表达）。

### 2.5 PRD（`docs/contract/Residue-PRD-v5.6.md`）

**C-17 落点（`:1247`）**：

> 「定时任务配置 → 第 ③ 页「清理策略配置」（C-17）；**扫描进度 → 第 ① 页加载态（C-17）**；……」

⇒ 「扫描进度」在**契约里明文指定落在第 ① 页加载态**。

**AC-20（`:1182-1185`）**：

> - Given 目录规模达 328 万文件量级（V8 待确认）
> - When 定时扫描触发
> - Then 「默认走增量、**可随时取消**、断点可续，满足 N1/N2/N3 的时长与 CPU/电量预算，电池供电且电量低于 20% 时暂停」（`:1184`）
> - 判定（`:1185`）：「取消动作后 5 秒内无新增扫描 I/O…**重启后可续扫结果断言**…」

**N1（`:1213`）**：

> 「全量扫描（328 万文件量级）p95 ≤ 10 min，**必须可中断/可取消/断点可续**；增量扫描单次 CPU 平均 ≤ 5%、峰值 ≤ 15%、持续 ≤ 30 s。」

**§8 加载行（`:1279`）**：

> 「加载 | 百万级文件扫描中的进度、可取消、断点续扫（**进度承载第 ① 页，C-17**）；四档授权流程未完成时的中间态。**〔R1-10〕** 四档均授权 / 任一档未授权为两次执行的两组状态，不同 Given」

⇒ 「进度」与「可取消」都是 PRD 明文要求，且明确承载在第 ① 页。

### 2.6 错误码依据（`ResidueApp/Sources/ResidueCore/DiagnosticCode.swift:46-49`）

```
46:        case e103 = "E-103"
48:        /// 用户取消。归类：**加载**。
49:        case e104 = "E-104"
```

`:166` `case loading = "加载"`（错误分类）· `:193` `.e103: return .loading` · `:194` `.e104: return .loading` · `:231-237` 用户文案（`.e104` ⇒「已取消」）· `:278-283` 行动指引（`.e104: return nil` ⇒ **无行动指引**）。

⇒ **取消是契约已有的一等状态**（`E-104`，归类「加载」，无行动指引）⇒ 本单不新增错误码，`verify_codes.py` 的 11 项不受影响。

### 2.7 ★ 契约内部歧义登记（本单裁决依据）

| 出处 | 写法 | 性质 |
|---|---|---|
| DAC-105 | 「信号色着色区 = 1 且**落在进度环上**」 | 缺口：**未区分确定环 / 不定 spinner**。系统 `ProgressView(.circular)` 也是环形、着色区也恰好 1 处 ⇒ **现状字面上满足 DAC-105**，但它表达的进度是假的。 |
| 视觉基线 §三 | 「**环形进度**」 | 缺口：同上，未区分确定 / 不定。 |
| PRD / DAC / 视觉基线 / R2 | 对「**已完成 x/y 个来源**」**全部零命中** | 缺口：**来源计数文案没有契约判据**（可自行新立）。 |
| PRD / DAC / 视觉基线 / R2 | 对「**取消按钮**」「**扫描按钮**」「**页头**」**全部零命中** | 缺口：**取消按钮落点只由视觉基线 §三 + DAC-105 一处规定**（§2.1/§2.2）⇒ 落点裁决依据充分，但页头职责无契约背书。 |
| 视觉基线 §二 vs DAC-105 | 「每屏只兑现优先级最高的一个」+「唯一名额仍然只有一个」 | 冲突：加载态期间 ① 页若同时渲染空态主行动按钮（`Components.swift:400` 的 `PrimaryButtonStyle` ⇒ 信号色）与执行结果卡 accent（`Components.swift:351` ⇒ `signal`），**信号色着色区 = 3**，违 DAC-105。 |

**裁决 A —— 「确定进度环」在契约里有没有字面判据？**

**裁决**：本单**在变更单内新立口径**，**不改契约基线**。

「确定环」= **弧长随「已完成来源数 / 来源总数」变化**，来源总数在扫描开始后即为已知量。系统 `.circular` spinner（弧长由系统动画驱动、与实际进度无关）**不算**确定环。

理由：

1. DAC-105 的验收方法写的是「数信号色着色区 = 1 并核其在进度环上」——它**只管颜色，不管语义**。把语义判据补进 DAC-105 需要动契约基线文档 ⇒ 需另出变更单改 PRD/DAC 版本号，超出本单范围（§六）。
2. 用户诉求「显示一个圆圈的扫描进度而不是一直显示正在扫描」的**核心是语义**：圈要表达「还剩多少」。不定 spinner 表达不了这件事。
3. 本单不动契约基线 ⇒ **PRD 不升 v5.7**、**DAC 不升 v2.1** ⇒ `ARCHITECTURE.md:69` 与 `CLAUDE.md:131` 的版本号不动 ⇒ `tests/contract/` 下 7 个脚本**零改动**。

**★ 说明**：是否把「确定环」补进 DAC-105，列入 §九 待裁决 #1。

**裁决 B —— 「已完成 x/y 个来源」文案的字面判据？**

**裁决**：本单新立文案，**不改契约基线**。

文案 = **来源计数 + 既有「已扫描 N 项」+ 既有「已用时 t 秒」**，分母 = 运行时 `roots.count`（**不写死 3**——`resolveSourceRoots` 在自检注入 override 时可能返回别的数量）。

理由：PRD / DAC / 视觉基线 / R2 对该文案零命中 ⇒ 属于**实现自由区**；而 DAC-105 要求「进度文案（非空）」⇒ 必须有文案才谈得上「两要素 2/2」。

**裁决 C —— 分母口径：`roots.count` 还是「实际存在根数」？**

**裁决**：分母 = **`roots.count`**（本次任务的来源总数），**被跳过的来源也计入完成**（分子照常推进）。

理由：

1. **不把未知判为安全**（不变量③）：「实际存在的根数」要等到 `fileExists` 判定完才知道 ⇒ 那是**用未来信息倒推分母**——扫描一开始就得知道还没开始的事。
2. 分母 = **本次任务量**；一个来源被跳过（根不存在）是**这个来源已完成**（扫完了，结果是「没有」），不是「这个来源不存在」。
3. `ResidueApp/Sources/ResidueApp/AppModel.swift:564` 的 `guard FileManager.default.fileExists(atPath: root) else { continue }` 必须同时**推进分子**——否则环永远转不满，且用户看不到「为什么少了一个」。

**裁决 D —— 加载态与三区块并存后，信号色名额归谁？**

**裁决**：**扫描期 ① 页的信号色着色区 = 1，落在进度环上**；其余全部退到中性表达。

具体到两个具体的承载物：

| 承载物 | 扫描期处置 | 理由 |
|---|---|---|
| 空态的「开始扫描」主行动按钮（`Components.swift:398-400`，`PrimaryButtonStyle` ⇒ 信号色） | **不出现**（扫描期传 `onScan: nil` ⇒ `if let onScan` 自然不成立） | 它既是第二个信号色，又是**第二个可执行动作**。DAC-105 明写取消按钮「是该屏唯一可执行动作」⇒ 扫描期不能有第二个。 |
| 执行结果卡 `ExecutionNoticeCard` 的 accent（`Components.swift:348-352`，干净成功时 = `signal`） | **保留可见，但退到中性**（加一个「是否用信号色 accent」的开关，扫描期关掉） | 视觉基线 §二原话「其余全部退到中性表达」——**退到中性**不是**隐藏**。隐藏会改变信息量（用户看不到上次清理的结果）。 |

其余 ① 页承载物核实：`StatusBar`（`Components.swift:150-161`）用 `SemanticSlotView` ⇒ 中性；三区块走 `SemanticSlot` ⇒ 中性；`FirstRunEmptyState` 的说明文字 ⇒ 中性。**均不占信号色名额。**

**裁决 E —— 取消后分子停在中途可以吗？**

**裁决**：**可以**。

分母恒定 = 任务总量（恒定值）；分子 = 已完成量；取消时停在当前位置 ⇒ 「已完成 1/3 个来源」**仍然是真的**（它没说「扫完了 1/3」，它说的是「完成了 1 个来源」）。

取消的终态由 `E-104` 承载（「已取消」，归类「加载」，**无行动指引**）——契约已经把它定义成一等状态 ⇒ 不需要本单再发明一个「已中止」的界面态。

**★ 边界说明**：裁决 A/B 是**本单在变更单内新立的口径**，**不改契约基线**；若 §九 #1/#2 被裁决为「要进契约」，则需另出变更单升 PRD/DAC 版本号。

---

## 三、改什么

### 3.1 `ScanProgress` 迁入 Core（新建 `Sources/ResidueCore/ScanProgress.swift`）

**现状**：`ScanProgress` 定义在 `ResidueApp/Sources/ResidueApp/ScanInfrastructure.swift:32-65`（App 层）。

**改为**：整体迁到 Core，新文件 `Sources/ResidueCore/ScanProgress.swift`。`CancelBox` / `ResultBox` / `resolveSourceRoots` **留在 App 层**（它们是 IO 编排设施，不是数据模型）。

★ **同一个新文件里再放一个 `ScanProgressAccumulator`**（跨来源累加器，§3.7）——理由：累加规则必须**只有一处实现**（不变量②）且**可单测**（留在 App 层则 Core 的测试看不到它）。

**为什么必须迁**（不是「设计如此」，是不变量①逼出来的）：

- 进度**比例**必须在 Core 算（界面禁止算术）⇒ 比例要挂在 `ScanProgress` 上。
- `PageModel` 在 Core，要携带进度 ⇒ `PageModel` 引用的类型必须在 Core。
- ⇒ **`ScanProgress` 必须进 Core**。这直接否决了「把进度当视图参数传下去」的省事方案（那样比例就落到了 App 层，违反不变量①）。

**兼容性要求**：`ScanProgress` 现在的成员是「全部有默认值」的 memberwise init。Swift 的 memberwise init **只在所有属性都有默认值时**才隐式生成，且**不是 `public`**。Core 的类型被 App 层构造 ⇒ 必须**显式写 `public init`**（保留 memberwise 的参数形状与默认值，尾部追加本单新增的两个带默认值的属性）⇒ 现有调用点 `AppModel.swift:587` 与 `WiringSelfCheck.swift:559` **全部保持编译通过，一行不改**。

**新增两个属性**：

```swift
/// 已完成的来源数（分子）。
public var completedSources: Int = 0
/// 本次扫描的来源总数（分母）。0 = **分母未知**（不是「没有来源」）。
public var totalSources: Int = 0
```

### 3.2 `ScanProgress.fraction` —— Core 侧算好的进度比例

```swift
/// Core 侧算好 —— 界面只拿现成的数（守「界面禁止算术」）。
/// `nil` = 分母未知，**不是 0**（守「不把未知判为安全」）。
public var fraction: Double? {
    guard totalSources > 0 else { return nil }
    return min(1, max(0, Double(completedSources) / Double(totalSources)))
}
```

**三条设计约束**：

1. **返回 `Double?` 而不是 `Double`** ⇒ 分母未知时返回 `nil`，**不是 0**（不变量③：`nil ≠ 0`——0 会被读成「扫完了 0%」，那是假的）。
2. **夹到 `[0, 1]`** ⇒ 分子 > 分母（理论上不该发生，但夹住比画出一个 > 360° 的弧安全）。
3. **除法在 Core** ⇒ 界面拿到的就是现成的 `Double?`，**不碰算术**（a9 第二节 2.2 / 2.2b 不会触雷——`VIEW_FILES` 只含 App 层的 4 个视图文件）。

### 3.3 `displayText` 追加来源计数段；新文案进 `UICopy`

**现状**：`ScanInfrastructure.swift:50-64` 的 `displayText` 三段式（已扫描 N 项 / 发现 N 个可回收条目 / 已用时 t 秒）。

**改为**：**来源计数段插在最前**（它是最粗粒度的进度，也是圆环的对应量），其余三段**原样保留**（不搬、不改措辞——那是既有文案，与本单无关）。

- `totalSources > 0` 时首段 = 「已完成 1/3 个来源」。
- `totalSources == 0`（**分母未知**）时首段 = 「正在扫描…」（**沿用 `PageModel.loadingMessage` 的既有措辞**，不编造「0/0」）⇒ 此时 `displayText` 恒非空。

**新文案进 `UICopy`**（按 CLAUDE.md §五「新增/修改界面文案 → 改 `UICopy`」），形态照 `ResidueApp/Sources/ResidueCore/SemanticSlot.swift:292` 的 `unmetSampleNote()`（无参先例）：

```swift
public static func scanSourcesCompleted(done: Int, total: Int) -> String {
    L.pick("已完成 \(done)/\(total) 个来源", "\(done)/\(total) sources completed")
}

public static func scanningInProgress() -> String {
    L.pick("正在扫描…", "Scanning…")
}
```

- **写法说明**：「1/3」**不加空格**（避免 `1 / 3` 被误读成算式），且**不用中文顿号分隔**。
- `UICopy` 在 Core（`SemanticSlot.swift:206`）且 `L` / `L.pick` 都是 `public`（`ResidueApp/Sources/ResidueCore/Localization.swift:55`/`:71`）⇒ Core 里的 `ScanProgress` 可以直接用。

**⚠️ 既有文案不动**：现有三段的 `L.pick` 是**内联在 `displayText` 里**的，不在 `UICopy`。本单**不把它们整体搬进 `UICopy`**（那是与本单无关的改动）⇒ 登记为既有漂移（§10.6）。

### 3.4 `PageModel` 用 `scanProgress` 取代 `loading` + `loadingMessage`

| 位置 | 现值 | 改为 |
|---|---|---|
| `ResidueApp/Sources/ResidueCore/PageModel.swift:77` | `public var loading: Bool = false` | **删除** |
| `ResidueApp/Sources/ResidueCore/PageModel.swift:79` | `public var loadingMessage: String = L.pick("正在扫描…", "Scanning…")` | **删除** |
| `ResidueApp/Sources/ResidueCore/PageModel.swift`（新） | —— | `public var scanProgress: ScanProgress? = nil` |

**为什么用 `Optional` 而不是「`loading: Bool` + `scanProgress`」并列**：并列会产生**两个事实源**（一个说「在加载」，一个说「进度是多少」）⇒ 不变量②（同一判定只有一个实现处）要求单源。`scanProgress == nil` ⇒ 不在扫描；`!= nil` ⇒ 在扫描，**且进度就在手边**。

**⚠️ 绝不能误伤**：`ResidueApp/Sources/ResidueCore/DiagnosticCode.swift:166` / `:193` / `:194` 的 `.loading` 是**错误分类**（`DiagnosticCode.Category.loading`），与 `PageModel.loading` **同名不同义** ⇒ 本单**不碰这三处**。

### 3.5 `PageModelBuilder` 的 `Input` 同步

| 位置 | 现值 | 改为 |
|---|---|---|
| `ResidueApp/Sources/ResidueCore/PageModelBuilder.swift:33` | `public var loading: Bool` | `public var scanProgress: ScanProgress?` |
| `ResidueApp/Sources/ResidueCore/PageModelBuilder.swift:76` | `loading: Bool = false,` | `scanProgress: ScanProgress? = nil,` |
| `ResidueApp/Sources/ResidueCore/PageModelBuilder.swift:95` | `self.loading = loading` | `self.scanProgress = scanProgress` |
| `ResidueApp/Sources/ResidueCore/PageModelBuilder.swift:133` | `model.loading = input.loading` | `model.scanProgress = input.scanProgress` |

**已核实**：`ResidueApp/Tests/` 下**零处**引用 `loading` / `loadingMessage` ⇒ 替换**不打破任何既有断言**；`ResidueApp/Sources/ResidueApp/DesignSampleData.swift` 亦零引用 ⇒ 设计样例数据不受影响。

### 3.6 `AppModel.runScan`：来源计数 + 三处 report

**现状**（`ResidueApp/Sources/ResidueApp/AppModel.swift`）：

- `:551` `let roots = resolveSourceRoots(override:rootsOverride:probe:upstream:&job.upstream)` ⇒ `roots` 是 `[(String, String)]`，**顺序确定**（uv → npm → pipx，见 `ScanInfrastructure.swift:183/:190/:193`）。
- `:558` `for (sourceName, root) in roots {` ⇒ **无序号**。
- `:564` `guard FileManager.default.fileExists(atPath: root) else { continue }` ⇒ **跳过的来源不推进任何计数**。
- `:585-595` 进度回调 → `cancelBox.report(ScanProgress(…))` ⇒ **一次 report 点**。

**改为**（累加规则收进 Core 的 `ScanProgressAccumulator`，见 §3.7）：

```swift
// ---- 来源根（用上游只读命令定位；失败回退标准路径）----
let roots = resolveSourceRoots(
    override: rootsOverride,
    probe: probe,
    upstream: &job.upstream
)

// ★ 累加器：**分母先到**（进循环之前）⇒ 第一拍的圆环就画得出弧
var acc = ScanProgressAccumulator(totalSources: roots.count)
cancelBox.report(acc.starting(elapsed: Date().timeIntervalSince(started)))

// ---- 逐来源扫描 ----
for (sourceName, root) in roots {          // ★ 循环头**不变**
    job.roots[sourceName] = root
    if cancelBox.isCancelled { break }
    guard FileManager.default.fileExists(atPath: root) else {
        // **根不存在 = 这个来源已经扫完了**（结果是「没有」）⇒ 分子照样推进
        cancelBox.report(acc.completing(
            source: sourceName, files: 0, candidates: 0,
            elapsed: Date().timeIntervalSince(started)
        ))
        continue
    }
    …
}
```

> ✅ **循环头为什么不用 `enumerated()`**：分子由 `ScanProgressAccumulator` **自己推进**（`completing` 每次 +1）⇒ **不需要序号** ⇒ 循环头保持 `AppModel.swift:558` 的原样 `for (sourceName, root) in roots {` ⇒ **零编译期风险**。
>
> （本单写单时曾打算用 `index + 1` 算分子 ⇒ 那会逼出 `for (index, (sourceName, root)) in roots.enumerated()` ⇒ 实测 `error: pattern cannot match values of type '(offset: Int, element: (String, String))'` ⇒ **改为累加器自增后该硬伤消失**，见 §八 步骤 3。）

**三处 report 点**（`CancelBox.report` 是**整份替换**，`ScanInfrastructure.swift:113` ⇒ **每一次 report 都必须带全量**）：

| # | 触发时机 | 累加器方法 | `completedSources` | `totalSources` | 为什么要有 |
|---|---|---|---|---|---|
| (a) | `roots` 解析完、**进循环之前** | `starting(elapsed:)` | 0 | `roots.count` | **分母必须先于分子到达**。否则第一拍圆环是「分母未知」（`fraction == nil`），用户看到的是一条空轨道——而那一刻用户并不知道「总共 3 个来源」。 |
| (b) | 来源**内**的进度回调 | `progressing(source:deltaFiles:deltaCandidates:elapsed:)` | 当前来源**未完成**（= 已完成的前 N 个） | `roots.count` | 实时刷新条目数 / 候选数 / 耗时。 |
| (c) | 每个来源**处理完**（正常扫完 / 「根不存在」跳过 / 扫描失败 —— **三条出口各一次**） | `completing(source:files:candidates:elapsed:)` | 累加器自增后的值 | `roots.count` | **分子推进**（圆环走一格）+ 把该来源的最终 `filesScanned` / `candidatesFound` 落到文案里（修缺陷 #8：小来源永不触发回调 ⇒ 其数字只在 (c) 落地）。 |

**分母取运行时 `roots.count`，不写死 3**（`resolveSourceRoots` 在自检注入 override 时可能返回别的数量）。

**`totalSources` 的生命周期**：`roots` 在 `Task.detached` 块**内部**解析（`AppModel.swift:551`）⇒ 分母在 detached 块内可知 ⇒ (a) 点直接 report 即可。**`AppModel` 的 `scanProgress` 属性在 detached 块外拿不到 `roots`** ⇒ 分母**不通过 `rebuild()` 传递**，只通过 `CancelBox` 的 report 传递 ⇒ **单一写入点**（`AppModel.swift:539` 的轮询）不变。

### 3.7 跨来源累计：`ScanProgressAccumulator`（Core 侧原语）

**缺陷 #7（计数倒退）修法**：

`CancelBox.report` 是**整份替换**（`ScanInfrastructure.swift:113`）⇒ 每次 report 都必须是**累计到此刻的全量**，不能是「本来源的增量」。

⇒ **累加规则收进 Core 的一个新类型** `ScanProgressAccumulator`（与 `ScanProgress` 同文件，§3.1）。

**为什么必须是 Core 侧的独立原语**（三条理由，逐条对应本仓库的既有纪律）：

1. **只有一处实现**（不变量②）—— 累加规则若散在 `AppModel` 的循环里，就是「判定只有一处实现」的破例。
2. **可单测** —— 累加逻辑若留在 App 层，Core 的单测**看不到**它（`Tests/ResidueCoreTests/` 只覆盖 `ResidueCore`）⇒ §八 步骤 3 的三条跨来源用例**落不了地**。
3. **不复制生产逻辑**（CLAUDE.md：「不要在测试里复制生产解析逻辑……要造中间结果就把它提成生产的公开原语」）⇒ 先例就在仓库里：`L0Probe.vnodeFDList`。

```swift
// Sources/ResidueCore/ScanProgress.swift

/// 跨来源的**进度累加器**。
///
/// ## 为什么单独一个类型
///
/// 1. 「本来源的增量」≠「累计到此刻的全量」——`CancelBox.report` 是**整份替换**
///    ⇒ 报增量会让数字在切来源时**倒退**（缺陷 #7）。
/// 2. 累加规则必须**只有一处实现**（不变量②）。
/// 3. 累加逻辑留在 App 层则 Core 的单测看不到它 ⇒ 提成 Core 类型。
public struct ScanProgressAccumulator: Sendable {
    /// 本次任务的来源总数（分母）。0 = **分母未知**（不是「没有来源」）。
    public let totalSources: Int
    /// 已完成的来源数（分子）。
    public private(set) var completedSources: Int = 0
    /// **已完成来源**的条目数合计（**不含**正在扫的那个来源）。
    public private(set) var filesScanned: Int = 0
    /// **已完成来源**的候选数合计（**不含**正在扫的那个来源）。
    public private(set) var candidatesFound: Int = 0

    public init(totalSources: Int) {
        self.totalSources = totalSources
    }

    /// (a) 点：**分母先到** —— 只把「总共几个来源」告诉界面。
    public func starting(elapsed: TimeInterval) -> ScanProgress {
        ScanProgress(
            source: "", filesScanned: 0, candidatesFound: 0,
            elapsed: elapsed, isRunning: true,
            completedSources: completedSources, totalSources: totalSources
        )
    }

    /// (b) 点：来源**内**的一次进度 → 累计到此刻的全量。
    ///
    /// ## 为什么**不**把 `deltaFiles` 累加进 `filesScanned`
    ///
    /// 正在扫的来源的最终数**还没定**（后面 (c) 点会用 `result.filesScanned` 落定）⇒
    /// 这里若累加进来，(c) 点再落一次 ⇒ **同一个来源被数了两遍**。
    /// 这里只返回「已完成来源的合计 + 本来源的当前数」的**视图**，**不改变累加器**。
    public func progressing(
        source: String, deltaFiles: Int, deltaCandidates: Int, elapsed: TimeInterval
    ) -> ScanProgress {
        ScanProgress(
            source: source,
            filesScanned: filesScanned + deltaFiles,
            candidatesFound: candidatesFound + deltaCandidates,
            elapsed: elapsed, isRunning: true,
            completedSources: completedSources, totalSources: totalSources
        )
    }

    /// (c) 点：来源**处理完**（正常扫完 / 根不存在 / 扫描失败 —— 三条出口各一次）
    /// ⇒ 分子推进 + 该来源的最终数落进合计。
    public mutating func completing(
        source: String, files: Int, candidates: Int, elapsed: TimeInterval
    ) -> ScanProgress {
        completedSources += 1
        filesScanned += files
        candidatesFound += candidates
        return ScanProgress(
            source: source,
            filesScanned: filesScanned,
            candidatesFound: candidatesFound,
            elapsed: elapsed, isRunning: true,
            completedSources: completedSources, totalSources: totalSources
        )
    }
}
```

**`AppModel.runScan` 侧**（detached 块内）：

```swift
// ---- 来源根（用上游只读命令定位；失败回退标准路径）----
let roots = resolveSourceRoots(
    override: rootsOverride,
    probe: probe,
    upstream: &job.upstream
)

// ★ 累加器：**分母先到**（进循环之前）⇒ 第一拍的圆环就画得出弧
var acc = ScanProgressAccumulator(totalSources: roots.count)
cancelBox.report(acc.starting(elapsed: Date().timeIntervalSince(started)))

// ---- 逐来源扫描 ----
for (sourceName, root) in roots {
    job.roots[sourceName] = root
    if cancelBox.isCancelled { break }
    guard FileManager.default.fileExists(atPath: root) else {
        // **根不存在 = 这个来源已经扫完了**（结果是「没有」）⇒ 分子照样推进
        cancelBox.report(acc.completing(
            source: sourceName, files: 0, candidates: 0,
            elapsed: Date().timeIntervalSince(started)
        ))
        continue
    }
    do {
        // ★ 不可变快照：`@Sendable` 闭包只能捕获不可变绑定（见下）
        let base = acc

        let result = try engine.scan(
            root: root,
            mode: mode,
            // 续扫：该来源上次中断时的断点（没有则全量新扫）
            checkpoint: usableCheckpoints[sourceName],
            // ---- 中止检查（AC-20：取消 5 s 内停 I/O）----
            abortCheck: ScanEngine.AbortCheck {
                cancelBox.isCancelled ? .userCancelled : nil
            },
            // ---- 超时（N1：全量扫描 600 s → `E-105`）----
            deadline: started.addingTimeInterval(ScanEngine.fullScanTimeout),
            now: started,
            // **进度回流**：每 2000 条一次 → 11 万条约 56 次
            progress: { p in
                cancelBox.report(base.progressing(
                    source: p.source,
                    deltaFiles: p.filesScanned,       // ★ 本来源的当前数
                    deltaCandidates: p.candidatesFound,
                    elapsed: Date().timeIntervalSince(started)  // ★ 总耗时（三点同源同刻）
                ))
            }
        )
        job.results.append((sourceName, result))
        if let cp = result.checkpoint {
            job.abortedCheckpoints[sourceName] = cp
        }
        if let ab = result.aborted, job.abortReason == nil {
            job.abortReason = ab.rawValue
        }

        // ★ (c) 点：**分子推进**（圆环走一格）+ 该来源的最终数落进合计
        //   ⇒ 小来源（< progressEvery = 2000 条）也会推进（修缺陷 #8）
        cancelBox.report(acc.completing(
            source: sourceName,
            files: result.filesScanned,
            candidates: result.candidates.count,
            elapsed: Date().timeIntervalSince(started)
        ))
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

// ★ 合计回填 `ScanJob`（执行记录用，`AppModel.swift:779` 读它）
//   ⇒ **单一计数器**：累加只发生在 `acc` 里
job.filesScanned = acc.filesScanned
job.candidatesFound = acc.candidatesFound
```

**★ 单一计数器（不变量②）**：`AppModel.swift:598-599` 原有的 `job.filesScanned += result.filesScanned` / `job.candidatesFound += result.candidates.count` **被本单删除** ⇒ 累加**只发生在 `acc` 里** ⇒ 不存在「两套计数器各自腐坏」。

**★ 断点续扫不重复计数**：`p.filesScanned` 从 `cp.countedFiles` 起算（`ScanEngine.swift:506`），而 `base.filesScanned` 是**前序来源**的总量 ⇒ 两者**不同源** ⇒ 相加不重复。`result.filesScanned` 与 `p.filesScanned` 的末值同口径 ⇒ (c) 点落定后与 (b) 点末值一致。

**★ `@Sendable` 闭包捕获 —— 唯一一处编译期硬伤**（已实测）：

`ScanEngine.swift:391` 的 `public typealias ProgressHandler = @Sendable (Progress) -> Void`
⇒ 这个 `progress:` 闭包是 **`@Sendable`** ⇒ 闭包里**捕获 `var`** 会被 Swift 6 在**编译期**拦下：

```
error: reference to captured var 'completed' in concurrently-executing code [#SendableClosureCaptures]
```

（已用最小样例实测；**即使该 `var` 在捕获之后不再被修改，也照样报错** —— 编译器只看「捕获的是 `var`」。）

⇒ 唯一被 `@Sendable` 闭包捕获的 `var` 是 **`acc`** ⇒ **在 `engine.scan` 之前做一次不可变快照** `let base = acc`，闭包里只用 `base`（`progressing` 是**非 mutating** 方法 ⇒ 快照够用）。
`totalSources` 在累加器里是 `let`；`started` 本来就是 `let` ⇒ 都不用处理。

**为什么三点都用 `Date().timeIntervalSince(started)`，不用 `p.elapsed`**：

1. **(a) / (c) 点根本没有引擎回调可取** —— `p.elapsed` 只在 `engine.scan` 内部的 `progress:` 闭包里拿得到；而「分母先到」与「分子推进」这两个时刻都在 `engine.scan` **之外**。
2. **三点必须同源同刻**（不变量②「同一判定只有一个实现处」）—— 圆环、进度文案、耗时三处若分别取 `p.elapsed` 与 `Date().timeIntervalSince(started)`，两个量虽同起点但会差几十毫秒 ⇒ 用户看到「环走了、文案没走」。
3. **与引擎的 `p.elapsed` 等价** —— 引擎的起点是 `ScanEngine.swift:495` 的 `let startedAt = now`，而调用方传的是 `now: started`（`AppModel.swift:583`）⇒ `startedAt == started` ⇒ 同起点，差值 < 1 ms。

⇒ `started` 是 `AppModel.swift:489` 的**外层 `let`**（在来源循环**之外**），`Date` 是 `Sendable` ⇒ 可安全跨 actor 捕获。

> ⚠️ **纪律**：**不要把 `now: started` 改成 `now: Date()`** —— 一改，引擎内的 `startedAt` 就变成「每个来源各自起算」，`p.elapsed` 会真的跨来源归零。本单不依赖 `p.elapsed`，但那个量仍在 `ScanEngine.Progress` 里 ⇒ 未来若有人改用它，会踩坑（§1.2「已证伪的假设」段留了取证链）。

**与既有载体一致**：`AppModel.swift:598-599` 原本就在累加 `job.filesScanned` / `job.candidatesFound` ⇒ 本单把**累加搬家**到 `acc`，**数值口径完全不变**（`result.filesScanned` 与 `result.candidates.count` 原样搬过去）⇒ `AppModel.swift:779` 写进执行记录的数字**与今天一致**。

### 3.8 扫描起手不再空白

| 位置 | 现值 | 改为 |
|---|---|---|
| `ResidueApp/Sources/ResidueApp/AppModel.swift:486` | `scanProgress = ScanProgress()` | `scanProgress = ScanProgress(isRunning: true)` |

⇒ 起手那一拍 `isRunning == true` ⇒ `displayText` 恒非空 ⇒ **页头/横条立刻有反馈**（不再空白）。

此时 `totalSources == 0` ⇒ `fraction == nil` ⇒ 圆环**只画轨道、不画弧**（诚实的「分母未知」态）⇒ (a) 点 report 之后弧才出现。

### 3.9 轮询点必须同 tick 回填 `pageModel.scanProgress`

**问题**：`AppModel.swift:440` 的 `pageModel = PageModelBuilder.build(input)` 是**整体替换** ⇒ 若轮询点只写 `scanProgress = p`（`:539`），`pageModel` 里的进度**不会自动更新**（`rebuild()` 只在 `runScan` 起手 `:487` 与收尾 `:801` 各调一次）⇒ 中间 13 秒里 ① 页看到的进度**永远是起手那一帧**。

**改为**：轮询点（`AppModel.swift:535-543`）在**同一个 tick** 内写两处：

```swift
let p = cancelBox.takeProgress()
if p != scanProgress {
    scanProgress = p        // 权威活值
    pageModel.scanProgress = p   // ★ 同 tick 回填（rebuild 会整体替换 pageModel）
}
```

⇒ 两个值**同源同刻** ⇒ 不会漂移。

`rebuild()` 里的 `Input` 相应改为 `scanProgress: isScanning ? scanProgress : nil`（镜像今天 `AppModel.swift:421` 的 `loading: isScanning`）。

### 3.10 自绘圆环（不用系统 `ProgressView(.circular)`）

**新组件**放在 `ResidueApp/Sources/ResidueApp/Components.swift`（**不放 `Pages.swift`** —— a9 `:56` 的 `PAGE_VIEWS` 正则 `^struct (Overview|Environments|Policy|Privacy|Report|Confirm|Evidence)[A-Za-z_]*: View` 只认七个页面 struct，新组件名不匹配 ⇒ 放 `Pages.swift` 会被误计进「七页视图 struct」计数；放 `Components.swift` 则不受影响）。

**实现要点**：

| 要点 | 做法 | 理由 |
|---|---|---|
| 形状 | `Circle().trim(from: 0, to: fraction)` + `.stroke(...)` | 系统 `.circular` 是**不定** spinner（§2.7 裁决 A）；`trim` 才是确定弧。 |
| 起点 | `.rotationEffect(.degrees(-90))` | 让 0% 从 12 点方向开始（视觉常规）。 |
| 底圈 | `Tokens.Color.divider` | 中性（视觉基线 §二「中性提示」）。 |
| 弧 | `Tokens.Color.signal` | **信号色着色区 = 1，且落在进度环上**（DAC-105 写死）。 |
| 分母未知 | `fraction == nil` ⇒ **只画底圈，不画弧** | **不得用 `?? 0` 把未知画成 0**（不变量③：`nil ≠ 0`）。 |
| 尺寸 | 组件内 `private let diameter: CGFloat = 16` | `DesignTokens.swift` **没有圆环尺寸 token** ⇒ 本单不新增 token 类别（登记备查，§五）。 |

**⚠️ a9 第二节的约束（组件放 `Components.swift` ⇒ 受 `VIEW_FILES` 检查）**：

- **2.1**（`grep -nE '\$[A-Za-z_][A-Za-z0-9_]*\s*[-+*/]\s*\$?[A-Za-z_]'`，**要求 `$` 前缀**）⇒ `trim(from: 0, to: fraction)` **不匹配** ⇒ 不误报。
- **2.2**（拦 `slotCount|countedDays|missCount|pNowCount|fSetBits|totalBytes` 的运算）⇒ `completedSources` **不在名单** ⇒ 不触雷。
- **2.2b**（拦 `'total - '` / `' / total'` / `'/ 1024'`）⇒ 除法在 **Core**（`ScanProgress.fraction`），不在 `VIEW_FILES` ⇒ 不触雷。
- **2.5**（拦 `Text("…\(…)…")` 里含 `count|total|bytes|value|a|b|K|T` 的**字面插值**）⇒ ⚠️ **横条文案不得直接写 `Text("\(progress.completedSources) 项")` 这类插值** ⇒ 必须显示**已拼好的字符串** `Text(progress.displayText)`（**无字面插值**形式，整条正则根本不匹配，因为正则要求 `Text("` 后紧跟 `\(`）⇒ **安全**。

### 3.11 `ScanProgressStrip` 横条组件（① 页内容区顶部）

**新组件**（`Components.swift`）= **圆环 + 进度文案 + 取消按钮**，样式照 `StatusBar`（`Components.swift:150-161`）：

- `HStack(spacing: Tokens.Spacing.xs)`
- `.padding(.vertical, Tokens.Spacing.xs)` + `.padding(.horizontal, Tokens.Spacing.s)`
- `.background(Tokens.Color.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.control))`

**取消按钮**：`Button(L.pick("取消", "Cancel"), action: onCancel)` + `.buttonStyle(SecondaryButtonStyle(enabled: true))` ⇒ 色相 = `textPrimary` + `divider` 描边 = **中性** ⇒ 满足 DAC-105「取消按钮取中性色」。

**⚠️ 组件放 `Components.swift` ⇒ 不受 a9 第九节「空实现检测」保护**（该节只扫 `Pages.swift` 与 `RootView.swift`，见 `scripts/verify_a9.sh:378-400`）⇒ 取消按钮的**真实守卫是 `app.cancelScan()` 出现在 `RootView.swift`**（a9 `:687` / a5 `:447`）⇒ 按钮的 action 由 `RootView` 传入 `OverviewPage`，**`RootView.swift` 里仍然出现 `app.cancelScan()`** ⇒ 两条判据**继续成立**。

### 3.12 ① 页落点：横条 + 去掉整页替换

**现状**（`ResidueApp/Sources/ResidueApp/Pages.swift:30-50`）：

```swift
var body: some View {
    if model.loading {                                   // :31
        LoadingView(message: model.loadingMessage)      // :32
    } else {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            if let status = model.statusSlot { StatusBar(slot: status) }        // :35
            if let notice = model.lastExecutionNotice {
                ExecutionNoticeCard(notice: notice)                            // :41
            }
            if model.isFirstRunEmpty {
                FirstRunEmptyState(onScan: onScan)                             // :49
            } else { … 三区块 … }
            …
        }
    }
}
```

**改为**：

```swift
var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
        // **加载态是第四件，与三区块 / 状态条并存**（视觉基线 §五）
        if let sp = model.scanProgress {
            ScanProgressStrip(progress: sp, onCancel: onCancel)
        }
        if let status = model.statusSlot { StatusBar(slot: status) }
        …
    }
}
```

**连带**：`LoadingView` 随之失效（**全仓唯一调用点就是 `Pages.swift:32`** ⇒ 删除安全）⇒ `ResidueApp/Sources/ResidueApp/Components.swift:294-315` 的 `struct LoadingView` **整块删除**。

**`OverviewPage` 新增参数**：`var onCancel: (() -> Void)? = nil`（带默认值 ⇒ 既有调用点 `PageRenderer.swift:237` 的 `OverviewPage(model: model)` **不用改也能编译**）。

**⚠️ 不要与其它 `onCancel` 混淆**：`ResidueApp/Sources/ResidueApp/Pages.swift:743` 的 `var onCancel: () -> Void` 与 `:840` 的 `Button(L.pick("取消", "Cancel"), action: onCancel)` **属于 ⑤ 页确认抽屉**；`ResidueApp/Sources/ResidueApp/RootView.swift:76` 与 `:206` 的 `onCancel:` 也**属于抽屉**。本单新增的是 `OverviewPage` 的**可选** `onCancel`，语义是「取消扫描」。

### 3.13 扫描期的空态与执行结果卡（信号色名额收口）

**空态**：`FirstRunEmptyState`（`Components.swift:381-404`）在扫描期会与横条**并存** ⇒ 出现「还没有扫描过」与「已完成 1/3 个来源」**自相矛盾**（且「还没有扫描过」本身是 DAC-80 违例，见 §五，本单不修）。

**改法**：

- `FirstRunEmptyState` 增加 `var showsTitle: Bool = true`（标题是 `Components.swift:387` 的 `Text(L.pick("还没有扫描过", "No scan yet"))`）⇒ 扫描期传 `false` ⇒ **去掉自相矛盾的标题**，**保留**下方那句「首次扫描会建立观察期基线：只读取文件元数据…」（那是指引，仍然有用）。
- 扫描期 `onScan` 传 `nil` ⇒ `Components.swift:398` 的 `if let onScan` 不成立 ⇒ **「开始扫描」主行动按钮不出现** ⇒ 信号色着色区 −1（§2.7 裁决 D）。
- **零改动即可达成**：`if let onScan` 本来就在，不需要改组件逻辑。

**执行结果卡**：`ExecutionNoticeCard`（`Components.swift:345-360`）的 `accent`（`:348-352`）在「干净成功」时是 `Tokens.Color.signal` ⇒ 第二个信号色。

**改法**：给 `ExecutionNoticeCard` 加 `var usesSignalAccent: Bool = true`；扫描期传 `false` ⇒ accent 退到 `Tokens.Color.textSecondary` ⇒ **卡片保留可见，只是不再着色**（视觉基线 §二「其余全部退到中性表达」）。

**⚠️ 为什么不隐藏卡片**：隐藏 = 改变信息量；退到中性 = 改变表达。契约要求的是后者。

### 3.14 页头清理（`RootView.swift`）

| 位置 | 处置 |
|---|---|
| `RootView.swift:121-132` | **删除**「扫描进度（扫描期间必须有反馈）」的 12 行长注释（进度搬走了，注释的落点也变了） |
| `RootView.swift:133-138` | **删除**「`if app.isScanning, !app.scanProgress.displayText.isEmpty { Text(app.scanProgress.displayText) … }」 |
| `RootView.swift:141-145` | **保留**（扫描按钮；扫描中显示「扫描中…」且 `.disabled`） |
| `RootView.swift:147-150` | **删除**「取消（13 秒不能反悔）」的 4 行长注释 |
| `RootView.swift:151-154` | **删除**（取消按钮搬去 ① 页横条） |

⇒ 页头职责回归「**标题 + 扫描按钮**」。

### 3.15 `RootView` 的接线

`RootView.swift:175-178` 的 `OverviewPage(model:model, onScan:…)` 追加一个参数：

```swift
OverviewPage(
    model: model,
    onScan: model.readOnly ? nil : { Task { await app.runScan() } },
    onCancel: { app.cancelScan() }        // ★ 取消扫描（不是抽屉的 onCancel）
)
```

⇒ ★ **`app.cancelScan()` 仍然出现在 `RootView.swift`** ⇒ a9 `:687` 与 a5 `:447` 的取消判据**继续成立**，**不需要改**。

### 3.16 渲染稿复现（`PageRenderer.swift`）

| 位置 | 处置 |
|---|---|
| `ResidueApp/Sources/ResidueApp/PageRenderer.swift:107-109` | `loadingModel.loading = true` / `loadingModel.loadingMessage = L.pick("正在扫描 3 个来源 · 已扫描 12,847 条", …)` ⇒ 改为设 `loadingModel.scanProgress = ScanProgress(source: …, filesScanned: 12_847, candidatesFound: …, elapsed: 3.2, isRunning: true, completedSources: 1, totalSources: 3)` |
| `ResidueApp/Sources/ResidueApp/PageRenderer.swift:132` | `("13-存储总览-加载态", Page.overview, loadingModel)` ⇒ **保留**（文件名与渲染稿数量都不变 ⇒ 16 张不变） |
| `ResidueApp/Sources/ResidueApp/PageRenderer.swift:237` | `OverviewPage(model: model)` ⇒ 可传 `onCancel: {}`（渲染稿无交互）——**`PageRenderer.swift` 不在 a9 第九节的扫描范围内** ⇒ 空 action **不会**被判为空实现 |

⇒ `--render-pages` 重渲染后，「13-存储总览-加载态」应显示**横条 + 圆环（1/3 弧）+ 进度文案 + 取消按钮**，而**不是**整页被 spinner 替换。

### 3.17 校验锚点改法（**必须申报**：改的是锚点串与锚点路径，不是判据意图）

**背景**：进度文字从 `RootView.swift` 搬到 `Components.swift` ⇒ 下面两条锚点**必然报红**，必须一并改，否则 CI 恒红。

**`ResidueApp/scripts/verify_a9.sh:682`**（现：`if grep -qF 'scanProgress.displayText' "$UI_DIR/RootView.swift" 2>/dev/null; then`）改为：

```bash
if grep -qF 'ScanProgressStrip(' "$UI_DIR/Pages.swift" 2>/dev/null \
   && grep -qF 'progress.displayText' "$UI_DIR/Components.swift" 2>/dev/null \
   && grep -qF 'trim(from: 0, to:' "$UI_DIR/Components.swift" 2>/dev/null; then
```

**`ResidueApp/scripts/verify_a5.sh:437`**（现：`&& grep -qF 'scanProgress.displayText' "Sources/ResidueApp/RootView.swift" 2>/dev/null; then`）改为：

```bash
    if grep -qF 'progressEvery' "Sources/ResidueCore/ScanEngine.swift" 2>/dev/null \
       && grep -qF 'ScanProgressStrip(' "Sources/ResidueApp/Pages.swift" 2>/dev/null \
       && grep -qF 'progress.displayText' "Sources/ResidueApp/Components.swift" 2>/dev/null; then
```

> ★ **实施后补记（CR-037 §10.4 偏差 2 / 3）**：上面两段锚点**实施时又收紧了一轮** ——
>
> ① 裸串 `ScanProgressStrip` ⇒ **带调用括号**的 `ScanProgressStrip(`；
> ② a9 **新增第三条** `grep -qF 'trim(from: 0, to:'`（「**确定弧**」的证据 —— 系统的 `.circular` spinner 不含这个串）。
>
> **为什么收紧**：`grep -qF` 是**子串匹配** ⇒ 裸串会被 `ScanProgressStripMutated` 命中 ⇒ §八 步骤 6 的变异 ② **首次实跑假绿**（全过程见 §10.5.1）。收紧后同一变异正确报红，**项数不变**（a9 仍 **80**、a5 仍 **42**）。
>
> ⚠️ **a5 的三条里没有 `trim(from: 0, to:`** —— 这是**故意**的：a5 判的是「README 承诺 → 引擎有进度回调**且**界面有显示」，**不判弧长**；「弧长 = 确定环」由 a9 与单测负责。两条脚本**分工不同**，不是漏写。

**三条硬要求**：

1. **项数不变**：`verify_a9.sh:25` 的 `PASS=0; FAIL=0` 与 `:27`/`:28` 的 `ok()`/`bad()` ⇒ **项数 = ok+bad 调用次数**。改锚点**路径与串**不改变调用次数 ⇒ **a9 仍 80 项、a5 仍 42 项**。
2. **⚠️ 必须用 `progress.displayText`，不能用裸 `displayText`** —— `ResidueApp/Sources/ResidueApp/Components.swift:30` 已有 `Text(slot.displayText)`（`SemanticSlotView`）⇒ 裸串会**误匹配** ⇒ 判据形同虚设。
3. **不改判据意图**：a9 `:682` 的 ok 文案「界面显示扫描进度（用户看得到它在动）」与 a5 `:438` 的「README 承诺「实时显示已扫描 N 项」→ 引擎有进度回调且界面有显示」**含义不变**——改的只是「界面在哪」的锚点。

**不需改的两条**：a9 `:687`（`app.cancelScan()` @ `RootView.swift`）与 a5 `:447`（同）⇒ **§3.15 之后仍然成立**。

### 3.18 声明面：README 新文案（**两个守卫词组必须保留**）

`README.md:176`（已知限制第 6 条）现值逐字：

> 「| 6 | **全量扫描本身要十几秒** | 缓存大时（实测 22 万项 ≈ 12 秒）**扫描本身要十几秒**。但扫描在**后台线程**跑，界面全程可操作，并实时显示「已扫描 N 项」与耗时，**也可以随时取消**。（限制的是耗时，不是卡死 —— 界面不会冻住） |」

**改写要点**：圆环 + ① 页顶部横条。

**⚠️ 两个词组必须保留**：

| 词组 | 守卫 | 删掉的后果 |
|---|---|---|
| 「已扫描 N 项」 | `ResidueApp/scripts/verify_a5.sh:434` `if grep -q "已扫描" "$README2"` | **整条检查被跳过** ⇒ a5 项数掉 1 |
| 「随时取消」 | `ResidueApp/scripts/verify_a5.sh:444` `if grep -q "随时取消" "$README2"` | **整条检查被跳过** ⇒ a5 项数掉 1 |

⇒ 新文案**必须同时**含这两个词组（措辞可调整，但词要在）。

### 3.19 导航项数同步（声明面数字）

**实测（2026-11-19，本单落盘前）**：

```
docs/changes/  = 62 份文件
变更单文件名里的单号去重 = 24 个（CR-001~CR-010、CR-022~CR-034、CR-036）
docs/**/*.md    = 141 份
```

**本单落盘后**：**63 份文件 / 25 个单号 / 142 份 `.md`**。

> ★ **实施后复核（2026-11-19，CR-037 落盘后实测）**：`docs/changes/` = **63 份文件** / **25 个单号**，`docs/**/*.md` = **142 份** ⇒ 与本节「本单落盘后」的数值**一致**。
>
> ⚠️ **上表的「现值」列是 HEAD 基线（`dc7f813`）**，不是工作区现状 —— CR-036 的实施已把三处写成 **63 / 25 / 142**，本单的 `§4.3` 同步脚本再次核对了这三处，**确认已是 63 / 25 / 142** ⇒ **本单这三处无需再改**（登记为 §10.6 第 9 行）。

| 位置 | 现值 | 改为 |
|---|---|---|
| `ARCHITECTURE.md:87` | 「61 份文件 / 23 个单号。」 | 「63 份文件 / 25 个单号。」 ⇒ ★ **实施后复核已是 63 / 25**（CR-036 已落盘，**本单不再改**） |
| `CLAUDE.md:11` | 「`docs/` 下 140 份 `.md` 是**契约文档**」 | 「142 份」 ⇒ ★ **实施后复核已是 142** |
| `CLAUDE.md:127` | 「`docs/` 下 140 份 `.md` 分四类」 | 「142 份」 ⇒ ★ **实施后复核已是 142** |

**⚠️ 实施时的实测（2026-11-19，CR-037 落盘后）**：三处声明**已经**是 63 / 25 / 142 ⇒ 与实测**一致** ⇒ 本单**不再改**这三处（CR-036 的实施已顺带补平 ⇒ 登记为 §10.6 第 9 行）。

**⚠️ `CLAUDE.md:127` 这处在 CR-036 的 §3.10 里被漏列**（CR-036 只列了 `CLAUDE.md:11`）⇒ 本单一并补上（见 §五）。

**⚠️ 这三处是散文声明，不是机器守**：`tests/contract/verify_counts.py` 的 `scan_claims()` **只扫 `.github/workflows/*.yml`** ⇒ 这三处**不被机器守** ⇒ 仍要人工同步。

### 3.20 不动的地方（外科手术边界）

| 不动 | 理由 |
|---|---|
| `ScanEngine` 的回调机制与 `progressEvery = 2000` | 缺陷 #8 的修法是**在来源扫完后补一次 report**，不改引擎的回调粒度（改引擎会牵动 `ScanConcurrencyTests` 与自检）。 |
| `SemanticSlot` 的 7 个 case | 不变量①要求 case 数 = 7；本单不需要新的槽位形态（进度是**独立横条**，不是页内度量）。 |
| `DiagnosticCode` 的 `.loading` 分类 | 与 `PageModel.loading` 同名不同义（§3.4 已警示）。 |
| ②③④⑤⑥⑦ 页 | 本单只动 ① 页与页头。 |
| `StatusBar` | 它承载「并发冲突」，与加载态不是同一件东西（视觉基线 §五明确并列）。 |
| `CancelBox` / `ResultBox` / `resolveSourceRoots` | 留在 App 层（IO 编排设施）。 |
| `DesignTokens` | 本单不新增 token 类别（圆环直径写在组件内，§3.10）。 |
| 契约基线文档（PRD / DAC / 视觉基线 / R2） | §2.7 裁决 A/B ⇒ 本单**不改契约** ⇒ 版本号不动 ⇒ `tests/contract/` 零改动。 |

---

## 四、影响面

### 4.1 代码引用点

| 文件 | 行 | 现状 | 本单后 |
|---|---|---|---|
| `ResidueApp/Sources/ResidueApp/ScanInfrastructure.swift` | 32-65 | `struct ScanProgress` 定义在 App 层 | **整段迁到 Core**（`Sources/ResidueCore/ScanProgress.swift`）⇒ 本文件只剩 `CancelBox` / `ResultBox` / `resolveSourceRoots` |
| `ResidueApp/Sources/ResidueApp/ScanInfrastructure.swift` | 50-64 | `displayText` 三段式 | 迁到 Core；**追加来源计数段**为首段 |
| `ResidueApp/Sources/ResidueApp/AppModel.swift` | 128 | `var scanProgress = ScanProgress()` | 引用 Core 的 `ScanProgress` |
| `ResidueApp/Sources/ResidueApp/AppModel.swift` | 421 | `loading: isScanning` | `scanProgress: isScanning ? scanProgress : nil` |
| `ResidueApp/Sources/ResidueApp/AppModel.swift` | 486 | `scanProgress = ScanProgress()` | `ScanProgress(isRunning: true)` |
| `ResidueApp/Sources/ResidueApp/AppModel.swift` | 535-543 | 轮询写 `scanProgress = p` | **同 tick** 追加 `pageModel.scanProgress = p` |
| `ResidueApp/Sources/ResidueApp/AppModel.swift` | 551 | `let roots = resolveSourceRoots(…)` | 追加 (a) 点 report（分母先到） |
| `ResidueApp/Sources/ResidueApp/AppModel.swift` | 558 | `for (sourceName, root) in roots {` | **不变**（分子由 `ScanProgressAccumulator` 自增 ⇒ **不需要序号** ⇒ 也不用 `roots.enumerated()`） |
| `ResidueApp/Sources/ResidueApp/AppModel.swift` | 564 | `guard fileExists … else { continue }` | 跳过路径**推进分子 + (c) 点 report** |
| `ResidueApp/Sources/ResidueApp/AppModel.swift` | 566-596 | `engine.scan(…progress:)` 单一 report 点，报本来源内的数 | 闭包内改用 `base.progressing(…)` ⇒ 报**跨来源累计**的数 + `completedSources`/`totalSources` + 总耗时 |
| `ResidueApp/Sources/ResidueApp/AppModel.swift` | 607-610 | `catch` 块只有 `job.failures.append(…)` | **补 (c) 点 report**（失败也算这个来源处理完了 ⇒ 分子照样推进） |
| `ResidueApp/Sources/ResidueApp/AppModel.swift` | 598-599 | `job.filesScanned += …` / `job.candidatesFound += …` | **删除**（累加只发生在 `acc` 里 ⇒ 单一计数器）；改为**循环后** `job.filesScanned = acc.filesScanned` / `job.candidatesFound = acc.candidatesFound` |
| `ResidueApp/Sources/ResidueApp/AppModel.swift` | 798 | `scanProgress = ScanProgress()`（收尾复位） | 不变 |
| `ResidueApp/Sources/ResidueApp/RootView.swift` | 121-138 | 页头进度文字 + 12 行注释 | **删除** |
| `ResidueApp/Sources/ResidueApp/RootView.swift` | 147-154 | 页头取消按钮 + 4 行注释 | **删除** |
| `ResidueApp/Sources/ResidueApp/RootView.swift` | 175-178 | `OverviewPage(model:onScan:)` | 追加 `onCancel: { app.cancelScan() }` |
| `ResidueApp/Sources/ResidueApp/Pages.swift` | 25-49 | `OverviewPage`（整页替换 + 空态） | 去整页替换；加横条；空态 `onScan: nil` + `showsTitle: false` |
| `ResidueApp/Sources/ResidueApp/Components.swift` | 294-316 | `struct LoadingView` | **整块删除**（唯一调用点 `Pages.swift:32` 被删） |
| `ResidueApp/Sources/ResidueApp/Components.swift` | 345-367 | `ExecutionNoticeCard` | 加 `usesSignalAccent` 开关 |
| `ResidueApp/Sources/ResidueApp/Components.swift` | 381-405 | `FirstRunEmptyState` | 加 `showsTitle` 开关 |
| `ResidueApp/Sources/ResidueApp/Components.swift` | 新增 | —— | `ScanProgressStrip` + 圆环视图 |
| `ResidueApp/Sources/ResidueCore/ScanProgress.swift` | **新增** | —— | `ScanProgress`（从 `ScanInfrastructure.swift` 迁入，`public init` 显式写出）+ `ScanProgressAccumulator`（跨来源累加器，§3.7） |
| `ResidueApp/Sources/ResidueCore/PageModel.swift` | 77 / 79 | `loading` / `loadingMessage` | **删除**；新增 `scanProgress: ScanProgress?` |
| `ResidueApp/Sources/ResidueCore/PageModelBuilder.swift` | 33 / 76 / 95 / 133 | `Input.loading` 四处 | 换 `scanProgress` |
| `ResidueApp/Sources/ResidueCore/SemanticSlot.swift` | 新增 | —— | `UICopy.scanSourcesCompleted(done:total:)` / `UICopy.scanningInProgress()` |
| `ResidueApp/Sources/ResidueApp/PageRenderer.swift` | 107-109 / 132 / 237 | `loadingModel` 构造 | 改用 `scanProgress` 复现横条 |
| `ResidueApp/Sources/ResidueApp/WiringSelfCheck.swift` | 559 | `ScanProgress(…isRunning: true)` | **不改**（显式 `public init` ⇒ 编译通过） |

### 4.2 测试引用点

| 位置 | 现状 | 本单后 |
|---|---|---|
| `ResidueApp/Tests/ResidueCoreTests/`（全目录） | **`loading` / `loadingMessage` / `ScanProgress` 零引用** | ⇒ 字段替换**零既有断言被打破** |
| `ResidueApp/Tests/ResidueCoreTests/ScanConcurrencyTests.swift:175-200` | `testProgressCountsAreMonotonic` **只覆盖单来源内** | 断言**不变**；⚠️ 它**不覆盖**跨来源累计（缺陷 #7 无覆盖）⇒ 本单**补**跨来源累计用例（§八 步骤 3） |
| `ResidueApp/Tests/ResidueCoreTests/ScanProgressTests.swift` | —— | **新建**（§八 步骤 1/2/3）⇒ `fraction` 5 条 + `displayText` 3 条 + `ScanProgressAccumulator` 4 条 + **起手分母 1 条** = **13 条**（★ 实测 13 条；本单初稿的分项求和漏计了 §八 步骤 3 的「★ 另补一条」，见 §10.4 偏差 1） |
| `ResidueApp/Tests/ResidueCoreTests/PageModelBuilderTests.swift` | 已有文件（`Input.loading` 相关用例） | **追加 2 条**（§八 步骤 4：`testBuilderCarriesScanProgressIntoModel` / `testModelHasNoLoadingField`）⇒ 本单新增合计 **15 条**（13 + 2） |
| `ResidueApp/Sources/ResidueApp/WiringSelfCheck.swift:578` | `reported.filesScanned > 0` | 断言**不变**（`filesScanned` 语义仍是「已扫描条目数」） |
| `ResidueApp/Sources/ResidueApp/WiringSelfCheck.swift:582` | `!reported.displayText.isEmpty` | 断言**不变** ⇒ ⚠️ 必须保证 `isRunning == true` 时 `displayText` **恒非空**（`totalSources == 0` 时首段用「正在扫描…」⇒ 非空） |

### 4.3 声明面数字同步

| 位置 | 内容 | 本单后 |
|---|---|---|
| `README.md:176` | 已知限制第 6 条 | 改写为圆环 + ① 页顶部横条；**保留「已扫描 N 项」与「随时取消」两个守卫词组** |
| `README.md:194` | `swift test  # 472 个单测`（HEAD `dc7f813`） | **+ 本单新增用例数**（§八 步骤 1/2/3 共 **13** 条 + 步骤 4 共 2 条 = **15** 条 ⇒ **基线 481**（HEAD 的 472 + CR-036 的 9）+ 15 = **496**）⇒ 实测 **496**，已落盘 |
| `README.md:195` | `./scripts/verify_a9.sh  # …（80 项）` | **80 项不变**（只改锚点，不改项数） |
| `README.md:197` | `--verify-wiring /tmp/w  # 真 IO 往返（111 项）` | **111 项不变**（本单不新增自检项） |
| `README.md:198` | `./scripts/verify_a5.sh  # 产物结构（42 项）` | **42 项不变**（只改锚点，不改项数） |
| `ARCHITECTURE.md:34` | `├── Tests/ResidueCoreTests/    472 个单测` | **496**（实测） |
| `ARCHITECTURE.md:37` | `verify_a9.sh 80 项` | 不变 |
| `ARCHITECTURE.md:38` | `verify_a5.sh 42 项` | 不变 |
| `ARCHITECTURE.md:87` | 「61 份文件 / 23 个单号。」 | 「63 份文件 / 25 个单号。」 ⇒ ★ **实施后复核已是 63 / 25**（CR-036 已落盘，**本单不再改**） |
| `CLAUDE.md:11` | 「`docs/` 下 140 份 `.md`」 | 「142 份」 ⇒ ★ **实施后复核已是 142** |
| `CLAUDE.md:127` | 「`docs/` 下 140 份 `.md` 分四类」 | 「142 份」 ⇒ ★ **实施后复核已是 142** |
| `.github/workflows/ci.yml:5` | 「编译、472 个单测、…」 | **496**（**`verify_counts.py` 机器守**） |
| `.github/workflows/release.yml:211-212` | 「472 单测全绿、码表 11 项、页面结构 80 项、接线自检 111 项、产物结构 42 项…」 | 单测数 **496**；**80 / 111 / 42 不变** |

**⚠️ `verify_counts.py` 的命中范围**（`tests/contract/verify_counts.py` 的 `scan_claims()` **只扫 `.github/workflows/*.yml`**）：

| 声明 | 位置 | 机器守？ |
|---|---|---|
| 496 个单测 | `ci.yml:5` / `release.yml:211` | **是** |
| 码表 11 项 | `ci.yml:111` | **是** |
| 页面结构 80 项 | `ci.yml:116` | **是**（但 `release.yml:211` 的「页面结构 80 项」**不匹配**任何 CLAIMS 正则 ⇒ **不被机器守**） |
| 接线自检 111 项 | `ci.yml:121` | **是** |
| 产物结构 42 项 | `ci.yml:132` | **是** |
| PRD 238 项 | `ci.yml:141` | **是** |
| R2 123 项 | `ci.yml:145` | **是** |
| `ARCHITECTURE.md:87` / `CLAUDE.md:11` / `CLAUDE.md:127` | 散文声明 | **否**（`scan_claims()` 不扫这三个文件） |

⇒ ⚠️ `ci.yml:151` 的注释明写：「**报红时改注释，不要改实测值去迁就注释**」⇒ 实施时若 `verify_counts.py` 报红，**改注释里的数字**，不改脚本里的期望值。

---

## 五、附带订正

| # | 事项 | 位置 | 处置 |
|---|---|---|---|
| 1 | `ScanEngine.Progress.source` 的注释写「`Source.rawValue`」，**实传的是根路径** | `ResidueApp/Sources/ResidueCore/ScanEngine.swift:364` / `:570` | **登记不改**（本单不显示 `source`，改它会牵动 `ScanProgress.source` 的语义，超出范围） |
| 2 | `ScanEngine.Progress.filesScanned` 的注释写「累计」，**实为单来源内** | `ResidueApp/Sources/ResidueCore/ScanEngine.swift:366` | **登记不改**（本单在 `AppModel` 侧做跨来源累计，引擎语义不动） |
| 3 | `ScanProgress.source` 设置了但**界面不显示** | `ResidueApp/Sources/ResidueCore/ScanProgress.swift`（迁入后） | **登记不删**（自检与将来「正在扫哪个来源」会用到；删它等于删一个已被三处构造的字段） |
| 4 | `Source.rawValue` 带下划线（`uv_cache` / `npm_npx` / `pipx_run`） | `ResidueApp/Sources/ResidueCore/Metrics.swift:45-48` | **登记**（若将来把 `source` 显示上界面，需先做一次可读化映射；本单不显示，故不动） |
| 5 | `PageModel.loadingMessage` 的默认串随本单删除 | `ResidueApp/Sources/ResidueCore/PageModel.swift:79` | 本单**随字段一并删除**（不是死代码清理，是本单改动直接导致的失效） |
| 6 | 页头职责从「标题 + 扫描按钮 + 进度 + 取消」回到「标题 + 扫描按钮」 | `ResidueApp/Sources/ResidueApp/RootView.swift:113-166` | 本单**主动改**（§3.14） |
| 7 | ① 页首启空态文案「还没有扫描过」是 **DAC-80 违例** | `ResidueApp/Sources/ResidueApp/Components.swift:387` | **登记备查，不在本单范围**（本单只在扫描期隐藏标题 ⇒ 顺带少显示一次，但空态本身的文案问题仍在） |
| 8 | `DesignTokens` **没有圆环直径 token** | `ResidueApp/Sources/ResidueApp/DesignTokens.swift` | **处置**：直径写在组件内（`private let diameter: CGFloat = 16`）⇒ 不新增 token 类别；**登记备查** |
| 9 | `displayText` 的既有三段文案**内联在 App 层**，不在 `UICopy` | `ResidueApp/Sources/ResidueApp/ScanInfrastructure.swift:52-62` | **登记为既有漂移**（本单只把**新**文案放进 `UICopy`，不整体搬迁 ⇒ 外科手术边界） |
| 10 | `ARCHITECTURE.md:87` / `CLAUDE.md:11` / `CLAUDE.md:127` 的声明值**比实测少 1** | 见 §3.19 | 本单按实测值 +1 一并订正（63 / 25 / 142） |
| 11 | **CR-036 §3.10 漏列 `CLAUDE.md:127`** | `docs/changes/Residue-CR-036-③页未达项区三态.md` §3.10 | **本单一并订正**（§3.19 已列两处） |

---

## 六、不做的事

1. **不修 ① 页首启空态的 DAC-80 违例**（「还没有扫描过」文案问题）—— 范围外，登记备查（§五 #7）。
2. **不加 `SemanticSlot` case** —— 不变量①要求 case 数 = 7；进度是**独立横条**，不是页内度量形态。
3. **不改契约基线文档**（PRD / DAC / 视觉基线 / R2）—— §2.7 裁决 A/B ⇒ PRD 不升 v5.7、DAC 不升 v2.1 ⇒ `tests/contract/` 下 7 个脚本**零改动**、`ARCHITECTURE.md:69` 与 `CLAUDE.md:131` 的版本号不动。
4. **不改 `ScanEngine` 的回调机制与 `progressEvery = 2000`** —— 缺陷 #8 用「来源扫完后补一次 report」解决，不动引擎。
5. **不做断点续扫 UI** —— PRD AC-20 的「断点可续」是**行为**要求，已有断点机制；本单不做进度条上的断点可视化。
6. **不做剩余时间预估** —— ETA 需要历史耗时分布，Core 里没有这个量 ⇒ **不编造**（不变量③）。
7. **不引入第三方依赖** —— 圆环用 `Circle().trim` 自绘。
8. **不动 ②③④⑤⑥⑦ 页**。
9. **不把 `ScanProgress` 的既有内联文案整体搬进 `UICopy`** —— 见 §五 #9。
10. **不碰 `DiagnosticCode` 的 `.loading` 错误分类**（`DiagnosticCode.swift:166`/`:193`/`:194`）。
11. **不新增 `--verify-wiring` 自检项** ⇒ 该项数**仍 111**。
12. **不改 `SemanticSlot` 的 7 个 case、不加第二个封闭枚举** —— 比例挂在 `ScanProgress`（结构体，非封闭枚举）上，不进 `SemanticSlot`。
13. **不 push、不建 PR** —— 除非用户另行要求。

---

## 七、验收判据

| # | 判据 | 怎么验 |
|---|---|---|
| 1 | ① 页加载态**两要素 2/2**：进度文案非空 + 「取消」按钮可点击 | 扫��中看 ① 页内容区顶部：横条里有文案、有「取消」按钮 |
| 2 | 取消按钮**落在①页内容区顶部**，不在页头 | 页头只剩「标题 + 扫描按钮」；横条在内容区第一行 |
| 3 | ① 页加载态是**第四件**，三区块 / 状态条**不被整页替换** | 扫描中 ① 页仍能看到三区块与状态条 |
| 4 | 圆环是**确定环**：弧长 = 已完成来源数 / 来源总数 | 扫完 uv 后弧走到 1/3；扫完 npm 走到 2/3 |
| 5 | **分母未知时只画轨道、不画弧**（不把未知画成 0） | 扫描起手那一拍圆环是空轨道，不是 0% 的「一圈不亮」之外还显示「0/0」 |
| 6 | 信号色着色区在扫描期 **= 1**，且落在进度环上 | 扫描期 ① 页无其它信号色：空态无「开始扫描」主按钮；执行结果卡不着色 |
| 7 | 取消按钮色相 ∈ {中性}，0 容差 | 取消按钮不是 `#5E6AD2`，是 `textPrimary` + `divider` 描边 |
| 8 | 「已扫描 N 项」**跨来源不倒退** | uv 扫完显示 ≥ 11 万，切到 npm 后数字**不变小** |
| 9 | 小来源（< 2000 条）**扫完时分子推进** | pipx 目录条目很少 ⇒ 扫完它环走到 2/3 而不是原地不动 |
| 10 | 「已用时」**跨来源不归零**（★ **回归防护**，见 §1.2「已证伪的假设」——**不是**本次缺陷的修复对象） | 切来源时计时器不回 0 |
| 11 | 扫描起手**页头/横条不空白** | 按下扫描的瞬间就有反馈（不再只有静态串） |
| 12 | 「已完成 x/y 个来源」分母 = **运行时来源数**，不写死 3 | 自检注入 override 时分母随之变 |
| 13 | `fraction` 分母未知时返回 `nil`（**不是 0**） | 单测断言 |
| 14 | `fraction` 在 `completed > total` 时夹到 1 | 单测断言 |
| 15 | 取消后界面显示「已取消」终态（`E-104`），无行动指引 | 点取消 ⇒ 扫完后看错误/状态文案 |
| 16 | **a9 80 项、a5 42 项、接线自检 111 项、单测数 = 基线 481 + 本单 15 = 496** | 全量校验实跑 |
| 17 | 16 张设计稿数量不变，「13-存储总览-加载态」显示**横条 + 圆环** | `--render-pages design-renders` 后看图 |
| 18 | README 新文案**同时含「已扫描 N 项」与「随时取消」** | `grep -c "已扫描" README.md` / `grep -c "随时取消" README.md` 均 ≥ 1；a5 项数仍 42 |

---

## 八、TDD 步骤

> 每一步都是「先写会失败的测试 → 看它红 → 最小实现 → 看它绿」。
> **红必须是「因为功能缺失」而红，不是「因为写错」而红。**

### 步骤 1 —— `ScanProgress.fraction`（Core 层，先行）

在 `ResidueApp/Tests/ResidueCoreTests/` 新建 `ScanProgressTests.swift`：

1. `testFractionIsZeroWhenNoSourceCompleted`：分母 3、分子 0 ⇒ `fraction == 0.0`。
2. `testFractionIsOneThirdWhenOneSourceCompleted`：分母 3、分子 1 ⇒ `fraction == 1.0/3.0`（**用 `XCTAssertEqual(…, accuracy: 1e-9)`**）。
3. `testFractionIsOneWhenAllSourcesCompleted`：分母 3、分子 3 ⇒ `fraction == 1.0`。
4. `testFractionIsNilWhenDenominatorUnknown`：分母 0、分子 0 ⇒ `fraction == nil`（**这条守不变量③**）。
5. `testFractionIsClampedWhenCompletedExceedsTotal`：分母 3、分子 5 ⇒ `fraction == 1.0`。

**验证**：此时 `ScanProgress` 还在 App 层（Core 的测试**看不到** App 层）⇒ **必须先做 §3.1 的迁移**才能让测试编译。⇒ **步骤 1 的第一步就是迁移 + 写 `public init`**，迁移后这 5 条测试应当**全部红**（`fraction` 不存在 ⇒ 编译错误 ⇒ 属「功能缺失」的红）。

> ⚠️ **迁移本身的验证**：`public init` 加好后，`ResidueApp/Sources/ResidueApp/AppModel.swift:587` 与 `ResidueApp/Sources/ResidueApp/WiringSelfCheck.swift:559` 的两处构造**必须仍然编译**（它们没显式写 `completedSources`/`totalSources` ⇒ 靠默认值）。⇒ **迁移后先跑一次 `swift build`，确认 App 层没被迁移打断。**

### 步骤 2 —— `ScanProgress.displayText` 的来源计数段

在 `ScanProgressTests.swift` 追加：

6. `testDisplayTextShowsCompletedSourcesWhenDenominatorKnown`：`totalSources = 3, completedSources = 1, isRunning = true` ⇒ `displayText` 含「1/3」与「个来源」。
7. `testDisplayTextIsNonEmptyWhenDenominatorUnknown`：`totalSources = 0, isRunning = true` ⇒ `displayText` **非空**且**不含「/0」**（守不变量③：不编造 0/0）。
8. `testDisplayTextIsEmptyWhenNotRunning`：`isRunning = false` ⇒ `displayText == ""`（既有语义不变）。

### 步骤 3 —— 跨来源累计不倒退

9. `testCompletedSourcesAdvancesWhenSourceIsSkipped`：分母 3、跳过 1 个根不存在 ⇒ 分子推进到 1，`fraction == 1.0/3.0`。
10. `testFilesScannedAccumulatesAcrossSources`：两个来源分别报 100 与 50 ⇒ 第二次 report 的 `filesScanned == 150`（**不是 50**）。
11. `testElapsedDoesNotResetAcrossSources`：第二次 report 的 `elapsed >= 第一次`（不归零）—— ★ **回归防护**，不是本次缺陷的修复对象（§1.2「已证伪的假设」段已取证：`now: started` 是全局起点 ⇒ 引擎的 `p.elapsed` 本就跨来源累计）。

**★ 这三条的落点**：`ResidueApp/Tests/ResidueCoreTests/ScanProgressTests.swift`（**新建**），直接测 **`ScanProgressAccumulator`**（§3.7）—— 它是**生产侧的公开原语**，累加规则**只有这一处实现**（不变量②）。

**不能**在测试里复制一份生产聚合逻辑（CLAUDE.md：「不要在测试里复制生产解析逻辑……要造中间结果就把它提成生产的公开原语」）⇒ 累加规则**必须**收在 Core 的 `ScanProgressAccumulator` 里，由 `AppModel` 调用它。

⇒ 三条用例的**落点与命名**（`ScanProgressTests.swift`）：

| 用例 | 构造 | 断言 |
|---|---|---|
| `testCompletedSourcesAdvancesWhenSourceIsSkipped` | `ScanProgressAccumulator(totalSources: 3)` ⇒ `completing(source:files:0,candidates:0,elapsed:0)` | `completedSources == 1`、返回值的 `fraction == 1.0/3.0` |
| `testFilesScannedAccumulatesAcrossSources` | 分母 2 ⇒ 先 `completing(files: 100, candidates: 0)` ⇒ 再 `completing(files: 50, candidates: 0)` | 第二次的 `filesScanned == 150`（**不是 50**） |
| `testElapsedDoesNotResetAcrossSources` | 两次 `completing` 的 `elapsed` 分别为 1.0 与 2.5 | 第二次返回值的 `elapsed >= 第一次` |

> ★ 另补一条 `progressing` 的用例（**不累加 delta**，§3.7 的关键约束）：`testProgressingDoesNotDoubleCountTheRunningSource` ⇒ 分母 2、`completing(files: 100)` 后调 `progressing(deltaFiles: 30)` ⇒ 返回的 `filesScanned == 130`，而累加器自身的 `filesScanned` **仍 == 100** ⇒ 再 `completing(files: 30)` ⇒ 累加器 `filesScanned == 130`（**不是 160**）。

> ★ **实施时再补一条（本单初稿未列 ⇒ 登记为 §10.4 偏差 8）**：`testStartingReportsDenominatorBeforeAnySourceCompletes` —— `ScanProgressAccumulator(totalSources: 3).starting(elapsed: 0)` ⇒ `totalSources == 3` ∧ `completedSources == 0` ∧ `fraction == 0.0` ⇒ **起手就有分母**，第一拍就画得出弧（对应 §八 步骤 1「起手不空白」的硬约束：分母为 `nil` ⇒ 圆环画不出弧）。

**★ 步骤 3 之前先解决一处编译期硬伤**（本单写单时已用最小样例实测，不是推测）：

| 硬伤 | 现象 | 正确写法 |
|---|---|---|
| `@Sendable` 闭包捕获 `var` | `error: reference to captured var 'completed' in concurrently-executing code [#SendableClosureCaptures]`（**即使该 `var` 在捕获后不再被修改，也照样报错**） | 唯一被 `@Sendable` 闭包捕获的 `var` 是 **`acc`** ⇒ 在 `engine.scan` **之前**做一次不可变快照 `let base = acc`，闭包里只用 `base`（`progressing` 是**非 mutating** 方法 ⇒ 快照够用） |

⇒ **先写测试、再改这一行**，否则「红」会红在编译错误上，而不是红在断言上（那是**编译失败**，不是**功能缺失**的红 ⇒ 按 CLAUDE.md 的口径不算数）。

> ✅ **`roots.enumerated()` 的解构硬伤已消失**：分子改由 `ScanProgressAccumulator` **自增** ⇒ **不需要序号** ⇒ 循环头保持生产现状 `for (sourceName, root) in roots {`（`AppModel.swift:558`）⇒ **零编译期风险**。

### 步骤 4 —— `PageModelBuilder` 传 `scanProgress`

**落点**：`ResidueApp/Tests/ResidueCoreTests/PageModelBuilderTests.swift`（**已有文件** ⇒ 追加 2 条，不新建）。

14. `testBuilderCarriesScanProgressIntoModel`：`Input(scanProgress: 某进度)` ⇒ `model.scanProgress == 该进度`。
15. `testModelHasNoLoadingField`：断言 `PageModel` **不再有** `loading` / `loadingMessage`（防止有人再加回来）⇒ ★ **实施时改用 `Mirror` 反射**取 `PageModel()` 的子字段名 —— 本单初稿写的是「**编译期断言**用 `#if`」，但编译期断言在字段被删后是「**编译不过**」⇒ 那**测不出「字段还在」**（编译失败 ≠ 测试红）⇒ 反射能把它变成**可执行的红**（见 §10.4 偏差 9）。

### 步骤 5 —— 界面接线（脚本判据 + 渲染稿）

16. 改 `ResidueApp/scripts/verify_a9.sh:682` 与 `ResidueApp/scripts/verify_a5.sh:437` 的锚点（§3.17）⇒ **先临时把 `ScanProgressStrip` 改名** ⇒ 实跑 a9 ⇒ 应在「界面显示扫描进度」这项**报红** ⇒ 改回 ⇒ 再实跑 ⇒ 绿。
17. `--render-pages design-renders` ⇒ 「13-存储总览-加载态」应显示**横条 + 圆环（1/3 弧）+ 文案 + 取消按钮**，且**三区块仍在**。
18. 人工核对（`swift run ResidueApp`）：扫描中 ① 页**信号色只有圆环**；页头**没有**进度文字与取消按钮；取消按钮**在横条里**。

### 步骤 6 —— 防假绿验证（**破坏性变异**：逐条临时改坏实现 → 实跑 → 看红 → 还原）

| # | 变异 | 期望红输出 | 被哪条判据抓住 |
|---|---|---|---|
| 1 | 把 `fraction` 的 `guard totalSources > 0 else { return nil }` 改成 `return 0` | 步骤 1 的第 4 条用例失败 | 单测（不变量③） |
| 2 | 把 `ScanProgressStrip` **改名**为 `ScanProgressStripMutated`（★ **不是删掉** —— 删掉会让 `Pages.swift` 的调用点**编译失败**，变异就变成「编译红」而不是「判据红」，**测不到判据**） | a9「界面显示扫描进度（用户看得到它在动）」报红 | `verify_a9.sh:682` |
| 3 | 把 `progress.displayText` 改成 `slot.displayText` | a9 同项报红（锚点串不再匹配） | `verify_a9.sh:682` |
| 4 | 把 `ScanProgressStrip` 的取消按钮 action 换成空闭包 `{}` | a9「界面提供取消扫描（12 秒不能反悔）」报红 | `verify_a9.sh:687`（`app.cancelScan()` 仍须在 `RootView.swift`） |
| 5 | 把 `ScanProgressAccumulator.completing` 里的 `completedSources += 1` 改成 `completedSources += 0`（分子永不推进） | 步骤 3 的第 9 条用例失败 | 单测 |
| 6 | 把 `ScanProgressAccumulator.completing` 的 `filesScanned += files` 改成 `+= files * 2`（同一来源被数两遍）★ **原写「改 `progressing` 也累加 `deltaFiles`」不可行** —— `progressing` 是**非 mutating** 的，且唯一调用点在 `@Sendable` 闭包内（只能用不可变快照 `let base = acc`）⇒ 改成 mutating 会让 App 层**编译失败**，测不到单测 | 步骤 3 的 `testProgressingDoesNotDoubleCountTheRunningSource` 与 `testFilesScannedAccumulatesAcrossSources` 失败 | 单测 |

> **每条变异都必须「先改坏 → 实跑 → 看红 → 还原」**，并把红输出贴进 §10.5。

### 步骤 7 —— 全量校验

```bash
cd ResidueApp
swift build && swift build -c release
swift test                       # 期望：基线 481（HEAD 472 + CR-036 的 9）+ 本单 15 = 496 全绿（实测数字写进 §10.3）
python3 scripts/verify_codes.py  # 11 项
./scripts/verify_a9.sh           # 80 项
swift run --disable-sandbox ResidueApp --verify-wiring /tmp/wiring   # 111 项
./scripts/make_app.sh && ./scripts/verify_a5.sh                     # 42 项
cd .. && ./tests/contract/check_all.sh && python3 tests/contract/verify_r2.py  # 238 / 123
python3 tests/contract/verify_counts.py
```

---

## 九、待裁决

### #1 「确定环」要不要补进 DAC-105？

**建议**：**暂不补**（本单在变更单内新立口径，契约基线零改动）。（本单采用）

**理由**：改 DAC-105 需升 DAC 版本号 ⇒ 牵动 `ARCHITECTURE.md:69` / `CLAUDE.md:131` 与 `tests/contract/` 的版本发现逻辑 ⇒ 超出本单范围（§六）。

**若裁决为「要补」**：需另出变更单（改 DAC-105 的验收方法列，加入「弧长 = 已完成来源数 / 来源总数」），本单的实现不受影响。

### #2 来源计数文案要不要进契约？

**建议**：**暂不进**（PRD / DAC / 视觉基线 / R2 对该文案零命中，属实现自由区）。（本单采用）

**理由**：DAC-105 只要求「进度文案（非空）」⇒ 文案内容是自由的 ⇒ 无需契约化。

**若裁决为「要进」**：需另出变更单（如在 PRD §8 加载行或 DAC-105 追加「来源计数」要素）。

### #3 分母口径：`roots.count` 还是「实际存在的根数」？

**建议**：**`roots.count`**（被跳过的来源也计入完成）。（本单采用）

**理由**：见 §2.7 裁决 C —— 「实际存在的根数」是**用未来信息倒推分母**，违不变量③。

**若裁决为「实际存在的根数」**：分母会随扫描推进而**变化**（先 3 后 2）⇒ 圆环会**倒退**；且起手那一刻分母仍未知 ⇒ 首拍仍是空轨道。⇒ 需在 §九 #3 被推翻时重新评估「起手分母」的来源。

### #4 取消后分子停在中途是否可接受？

**建议**：**可接受**（分母恒定 = 任务总量，分子 = 已完成量；「已完成 1/3 个来源」仍然是真的）。（本单采用）

**理由**：见 §2.7 裁决 E；取消终态由 `E-104` 承载。

**若裁决为「不可接受」**：需要在取消时把分子**推到分母**（显示「已完成 3/3」但实际只扫了 1 个）⇒ **那是撒谎** ⇒ 若坚持，不可接受的其实是「用完成率表达取消」这件事 ⇒ 需改文案形态（如「已取消（完成 1/3 个来源）」），那会牵动 §3.3 的文案与 §2.7 裁决 B。

### #5 扫描期的执行结果卡是「退到中性」还是「隐藏」？

**建议**：**退到中性**（保留可见）。（本单采用）

**理由**：视觉基线 §二原话「其余全部退到中性表达」——**退到中性**是改变表达，**隐藏**是改变信息量；契约要求的是前者。

**若裁决为「隐藏」**：⇒ `Pages.swift` 的 `ExecutionNoticeCard` 分支在扫描期**整块不渲染** ⇒ 扫描期间用户看不到上次清理结果 ⇒ 需要评估是否可接受（扫描期用户注意力在进度上，代价可能不大）。

---

## 十、实施记录

> ★ **每项都写实跑结果与数字**，不写「已完成」。
>
> **实跑环境**：macOS（darwin arm64）· SwiftPM 包根 `ResidueApp/` · 仓库根 `自动化配置/` · 分支 `gztcode/gate-link` · 基线 HEAD `dc7f813` · 实跑日期 2026-11-19。

### 10.1 代码改动

**逐文件、逐行**。★ 工作区 diff 同时含 **CR-036** 的改动（`ResidueCore/UnmetSection.swift`、`PageModel.swift` 的 `unmetSection`、`PageModelBuilder.swift` 的四态分派、`SemanticSlot.swift` 的 `unmetNone` / `emptyDomainText`、`DesignSampleData.swift`、`Components.swift` 的 `FirstRunEmptyState` 文案）⇒ 那部分记在 **CR-036 的 §十**，本表只列 **CR-037** 的落点。

| # | 文件 | 改了什么 | 为什么 |
|---|---|---|---|
| 1 | `ResidueApp/Sources/ResidueCore/ScanProgress.swift` | **新建**（184 行）：`ScanProgress`（`Sendable` + `Equatable`，`:17`）、`init`（`:43`）、`fraction: Double?`（`:67`）、`displayText`（`:78`）、`ScanProgressAccumulator`（`:126`，含 `init(totalSources:)` `:136` / `starting(elapsed:)` `:143` / `progressing(source:deltaFiles:deltaCandidates:elapsed:)` `:155` / `completing(source:files:candidates:elapsed:)` `:170`） | 进度模型必须落 **Core**（不变量①：界面只拿已算好的值）⇒ 否则**界面对算术**且无法被单测覆盖 |
| 2 | `ResidueApp/Sources/ResidueApp/ScanInfrastructure.swift` | **删 46 行**：原 `ScanProgress` 定义整体迁出；顶部留 3 行注释说明「已迁入 Core」；`CancelBox` / `ResultBox` / `resolveSourceRoots` **保留不动** | 同一判定只有一个实现处（不变量②）⇒ Core 与 App 层不得各有一份 `ScanProgress` |
| 3 | `ResidueApp/Sources/ResidueCore/PageModel.swift` | **修改** `:76-85`：`loading: Bool` + `loadingMessage: String` ⇒ 删；新增 `scanProgress: ScanProgress? = nil`（带 8 行注释说明为何取代那两个字段） | 「加载中」与「加载到哪儿了」原是**并列的两个事实源** ⇒ 必然出现「`loading` 为真但 `loadingMessage` 是旧的」；现在只有一个载体 |
| 4 | `ResidueApp/Sources/ResidueCore/PageModelBuilder.swift` | **修改** `:33` / `:76` / `:95` / `:133`：`Input.loading: Bool` ⇒ `Input.scanProgress: ScanProgress?`；`init` 默认值 `nil`；`build` 里 `model.scanProgress = input.scanProgress` | 聚合层只搬运，不判定（§3.5） |
| 5 | `ResidueApp/Sources/ResidueCore/SemanticSlot.swift` | **修改** `:381` / `:389`：新增 `UICopy.scanSourcesCompleted(done:total:)`（「已完成 x/y 个来源」）与 `UICopy.scanningInProgress()`（「正在扫描…」，分母未知时的首段） | 界面文案唯一样式串（`UICopy`）⇒ 新文案**不得**内联在视图里 |
| 6 | `ResidueApp/Sources/ResidueApp/AppModel.swift` | **修改** 12 处：`:421-423`（`Input` 改传 `scanProgress: isScanning ? scanProgress : nil`）、`:488-490`（起手即 `ScanProgress(isRunning: true)`，**不再空白**）、`:543-546`（轮询点**同 tick** 写 `scanProgress` 与 `pageModel.scanProgress`）、`:564-565`（循环前建累加器 `ScanProgressAccumulator(totalSources: roots.count)` 并 `starting`）、`:575-582`（根不存在也 `completing` ⇒ 分子照样推进）、`:584`（`let base = acc` 不可变快照）、`:606-612`（进行中 `progressing`）、`:616-621`（来源扫完 `completing` ⇒ 分子推进）、`:634-639`（**失败也算处理完** ⇒ 分子照样推进）、`:643-647`（合计回填 `ScanJob.filesScanned` / `candidatesFound`） | 进度必须来自**真实扫描事件**（不变量②），不能是界面自演；`rebuild()` 会整体替换 `pageModel` ⇒ 只写活值不够，横条会停在上一拍 |
| 7 | `ResidueApp/Sources/ResidueApp/Components.swift` | **修改**：**删** `struct LoadingView` 整块；**新增** `ScanProgressRing`（`:311`，自绘确定弧：`trim(from: 0, to:)` + `rotationEffect(.degrees(-90))` + 底圈 `Tokens.Color.divider` + 弧 `Tokens.Color.signal`）与 `ScanProgressStrip`（`:349`，横条 = 环 + `Text(progress.displayText)` + `Spacer()` + 中性取消按钮 `SecondaryButtonStyle(enabled: true)`）；`ExecutionNoticeCard` 加 `usesSignalAccent: Bool = true`（`:409` / `:412`）；`FirstRunEmptyState` 加 `showsTitle: Bool = true`（`:452` / `:457`） | 系统 `ProgressView(.circular)` 是**不定**的（只表示「还在动」，不表示还剩多少）⇒ 用户要的是后者 ⇒ 必须自绘；a9 的「七页视图 struct」计数用正则 `^struct (Overview\|…)[A-Za-z_]*: View` ⇒ 组件名放 `Components.swift` 不放 `Pages.swift` |
| 8 | `ResidueApp/Sources/ResidueApp/Pages.swift` | **修改** `:29-33` / `:36-46` / `:53-54` / `:62-68`：删「扫描时整页替换成 `LoadingView`」；新增 `onCancel: (() -> Void)?`、私有 `isScanning`（= `model.scanProgress != nil`）；内容区**顶部**插 `ScanProgressStrip(progress:onCancel:)`；执行结果卡扫描期 `usesSignalAccent: !isScanning`；空态扫描期 `onScan: nil` + `showsTitle: false` | 横条落 **① 页内容区顶部**（Q2）；加载态是**第四件**，与三区块并存（不是替换）；信号色着色区只留给圆环 |
| 9 | `ResidueApp/Sources/ResidueApp/RootView.swift` | **修改** `:121-129` / `:134` / `:156-158`：页头删掉进度文字与取消按钮；扫描按钮在扫描期显示「扫描中…」并禁用；`:158` 新增 `onCancel: { app.cancelScan() }` | 取消按钮**只在横条一处**（`:158` 是全仓**唯一**一处 `app.cancelScan()`）；页头在②~⑦ 页也会出现，放页头会「在②页按扫描、进度显示在①页」 |
| 10 | `ResidueApp/Sources/ResidueApp/PageRenderer.swift` | **修改** `:107-118` / `:246-248`：`loadingModel.loading = true` + `loadingMessage` ⇒ 改设 `loadingModel.scanProgress = ScanProgress(source: "uv", filesScanned: 12_847, candidatesFound: 42, elapsed: 3.2, isRunning: true, completedSources: 1, totalSources: 3)`；`OverviewPage(model:)` ⇒ `OverviewPage(model: model, onCancel: {})` | 让 13 号渲染稿**复现真实横条**（1/3 弧）；`PageRenderer.swift` 不在 a9 扫描范围内 ⇒ 空 action 不会被判为空实现 |
| 11 | `ResidueApp/scripts/verify_a9.sh` | **修改** `:682-697`（净 +17 行）：判据锚点由 `scanProgress.displayText` @ `RootView.swift` ⇒ 改为 `ScanProgressStrip(` @ `Pages.swift` + `progress.displayText` @ `Components.swift` + **新增第三条** `trim(from: 0, to:` @ `Components.swift`；新增 12 行注释说明收紧依据 | 进度文字已搬到 `Components.swift`（旧锚点必然报红）；第三条是「**确定弧**」的证据 —— 系统 `.circular` spinner 不含这个串（§3.17） |
| 12 | `ResidueApp/scripts/verify_a5.sh` | **修改** `:436-444`（净 +8 行）：判据锚点改为 `progressEvery` + `ScanProgressStrip(` + `progress.displayText`；新增 5 行注释 | 同上；a5 判的是「README 承诺 → 引擎有进度回调**且**界面有显示」，**不判弧长** ⇒ 与 a9 分工不同，**故意**不同 |
| 13 | `README.md` | **修改** `:176`（已知限制第 6 条改写为「圆环 + ① 页顶部横条」）与 `:194`（单测数 481 → 496） | 对外声明必须与实现一致（§3.18）；两个守卫词组「已扫描」「随时取消」**保留** |
| 14 | `ARCHITECTURE.md` | **修改** `:34` / `:122` / `:136`（单测数 481 → 496） | 同上 |
| 15 | `CLAUDE.md` | **修改** `:20`（单测数 481 → 496） | 同上 |
| 16 | `.github/workflows/ci.yml` | **修改** `:5`（单测数 481 → 496） | `verify_counts.py` **机器守**（§4.3） |
| 17 | `.github/workflows/release.yml` | **修改** `:211`（单测数 481 → 496） | 同上 |
| 18 | `ResidueApp/design-renders/13-存储总览-加载态.png` | **重渲染**（108,622 → 159,783 字节）：由整页 spinner 改为**横条 + 1/3 弧圆环 + 进度文案 + 取消按钮**，三区块仍在 | 设计稿是**契约面** —— 改实现就得改稿 |

**★ 未触及**：`ScanEngine` 的回调机制与 `progressEvery = 2000`、`SemanticSlot` 的 7 个 case、`DiagnosticCode` 的 `.loading` 分类、`TrashExecutor`、`L0Probe`、`ResidueStateFile`、`GateEvaluator`、`Metrics.swift`（§3.20）。


### 10.2 测试改动

**本单新增合计 15 条**（`ScanProgressTests.swift` **13** 条 + `PageModelBuilderTests.swift` **2** 条）⇒ 基线 **481**（HEAD `dc7f813` 的 472 + CR-036 的 9）+ 15 = **496**。

### 10.2.1 `ResidueApp/Tests/ResidueCoreTests/ScanProgressTests.swift`（**新建**，168 行 / 13 条）

| # | 用例 | 断言要点 |
|---|---|---|
| 1 | `testFractionIsZeroWhenNoSourceCompleted` | `fraction == 0.0`（分母已知、分子为 0 ⇒ 画空弧，**不是** `nil`） |
| 2 | `testFractionIsOneThirdWhenOneSourceCompleted` | `fraction == 1.0/3.0`（accuracy `1e-9`） |
| 3 | `testFractionIsOneWhenAllSourcesCompleted` | `fraction == 1.0` |
| 4 | `testFractionIsNilWhenDenominatorUnknown` | `fraction == nil`（**不变量③**：`nil ≠ 0`） |
| 5 | `testFractionIsClampedWhenCompletedExceedsTotal` | `fraction == 1.0`（上界钳位） |
| 6 | `testDisplayTextShowsCompletedSourcesWhenDenominatorKnown` | 含「1/3」∧ 含「个来源」 |
| 7 | `testDisplayTextIsNonEmptyWhenDenominatorUnknown` | 非空 ∧ **不含**「/0」（不得写成「已完成 0/0 个来源」） |
| 8 | `testDisplayTextIsEmptyWhenNotRunning` | `displayText == ""`（终态不带进度文案） |
| 9 | `testCompletedSourcesAdvancesWhenSourceIsSkipped` | `completedSources == 1`（**跳过的来源也算完成**）∧ `totalSources == 3` |
| 10 | `testFilesScannedAccumulatesAcrossSources` | 第二个来源完成后 `filesScanned == 150`（**跨来源**累计） |
| 11 | `testElapsedDoesNotResetAcrossSources` | 第二个来源的 `elapsed` **不小于**第一个（耗时单调） |
| 12 | `testProgressingDoesNotDoubleCountTheRunningSource` | `mid.filesScanned == 130` ∧ `acc.filesScanned == 100` ∧ `done.filesScanned == 130`（**不是 160** ⇒ 进行中不双计） |
| 13 | `testStartingReportsDenominatorBeforeAnySourceCompletes` | `totalSources == 3` ∧ `completedSources == 0` ∧ `fraction == 0.0`（★ **起手就有分母** ⇒ 第一拍就画得出弧） |

### 10.2.2 `ResidueApp/Tests/ResidueCoreTests/PageModelBuilderTests.swift`（**追加 2 条**）

| # | 用例 | 断言要点 |
|---|---|---|
| 14 | `testBuilderCarriesScanProgressIntoModel` | `model.scanProgress == progress` ∧ `model.scanProgress?.fraction == 1.0/3.0`（聚合层**只搬运**，不重算） |
| 15 | `testModelHasNoLoadingField` | 用 `Mirror(reflecting: PageModel())` 取子字段名 ⇒ **不含** `loading` / `loadingMessage`，**含** `scanProgress` |

> ★ 第 15 条**故意用反射**而不是直接访问字段 —— 直接访问在字段被删后是**编译失败**，那就**测不出「字段还在」**（测试编译不过 ≠ 测试红）。反射能把这个契约变成**可执行的红**。


### 10.3 校验实跑结果

| 校验 | 实跑命令 | 实跑结果 |
|---|---|---|
| 编译 | `swift build` | ✅ 退出码 **0** |
| Release 编译 | `swift build -c release` | ✅ 退出码 **0**；**3 条既有 warning**：`ScanEngine.swift:508`（`unknownCount` never mutated）、`TrashExecutor.swift:160`（`bytesKind` never used）、`AppModel.swift:1140`（`deleted` never used）—— **本单未触及**（第三条的行号因本单改动从 CR-036 记的 `1105` 下移到 `1140`） |
| 单测 | `swift test` | ✅ **Executed 496 tests, with 0 failures**（退出码 0）⇒ 基线 481 + 本单 15 |
| 错误码表 | `python3 scripts/verify_codes.py` | ✅ 通过 **11** 项 / 失败 **0** 项 |
| 页面结构 | `./scripts/verify_a9.sh` | ✅ 通过 **80** 项 / 失败 **0** 项（★ **项数不变**，只改锚点） |
| 接线自检 | `swift run --disable-sandbox ResidueApp --verify-wiring /tmp/wiring` | ✅ 通过 **111** 项 / 失败 **0** 项（本单不新增自检项） |
| 产物结构 | `./scripts/make_app.sh && ./scripts/verify_a5.sh` | ✅ 打包退出码 **0**（产出 `build/Residue.app` + `build/Residue.app.dmg`，无证书 ⇒ **ad-hoc 签名**，DMG SHA-256 `db9caa14407a1504655f6e00b1d8f150b30613af083b145038908d62c9f7c2b9`）；a5 通过 **42** 项 / 失败 **0** 项 / 未覆盖 **3** 项（★ **项数不变**） |
| PRD 基线 | `./tests/contract/check_all.sh` | ✅ 退出码 **0** ⇒ `verify18.py` **191** 项 + `verify_cr022.py` **47** 项 = **238** 项（`verify_cr022.py` 末行「✅ 全部校验通过」） |
| R2 基线 | `python3 tests/contract/verify_r2.py` | ✅ **123** 项（结构 30 + 落地 65 + 归零 16 + 一致 10 + 自洽 2） |
| 声明数字 | `python3 tests/contract/verify_counts.py` | ✅ 一致 **9** 项 / 不一致 **0** 项 / 未覆盖 **4** 项 |
| 设计稿 | `swift run --disable-sandbox ResidueApp --render-pages design-renders` | ✅ **16** 张；**仅 `13-存储总览-加载态.png` 变化**（108,622 → 159,783 字节），其余 15 张逐字节不变 |

**声明面数字同步（§4.3）**：单测数 **481 → 496** 已落盘于 `README.md:194`、`ARCHITECTURE.md:34` / `:122` / `:136`、`CLAUDE.md:20`、`.github/workflows/ci.yml:5`、`.github/workflows/release.yml:211`。★ `ci.yml` 与 `release.yml` 两处**被 `verify_counts.py` 机器守** ⇒ 第一次实跑曾**报红 2 项**（声明 481、实测 496）⇒ 按脚本自身提示「**改注释，不要改实测值去迁就注释**」处理。

**★ 未纳入本单校验清单的项**（CI 绿 ≠ 可发布，见 `CLAUDE.md` §六）：公证、钉票、`spctl` 通过、干净机装机、GUI 交互 / 滚动 / 焦点可达性、回滚演练 —— 六项需外部资源，属 A-10 发布准入。

### 10.4 偏差登记

| # | 偏差 | 为什么 | 处置 |
|---|---|---|---|
| 1 | **§4.2 写「12 条」，实测 13 条** | §八 步骤 1~3 只列了 **12 条**（编号 1~11 + 「★ 另补一条」`testProgressingDoesNotDoubleCountTheRunningSource`），但 §4.2 的分项求和（5 + 3 + 4）**没把「另补」那条算进去**；实施时又补了第 13 条（见偏差 8）⇒ 实测 **13** 条 | §4.2 已订正为 **13 条**（5 + 3 + 4 + 1）；§10.2 按实测 13 条写；§4.3 总数同步改为 481 + 15 = **496** |
| 2 | **§3.17 正文写 a9 两条 grep，实际落地三条** | 实施时发现**裸串** `ScanProgressStrip` 会被 `ScanProgressStripMutated` 命中（`grep -qF` 是**子串匹配**）⇒ §八 步骤 6 变异 ② 首次实跑**假绿** | a9 收紧为 `ScanProgressStrip(` + `progress.displayText` + **新增第三条** `trim(from: 0, to:`；§3.17 已补记全过程；**项数不变**（80 / 42） |
| 3 | **§3.17 正文写裸串 `ScanProgressStrip`** | 同上 | 两条脚本的锚点都改为**带调用括号**的 `ScanProgressStrip(` |
| 4 | **§八 步骤 6 变异 ② 原写「把 `ScanProgressStrip` 从 `OverviewPage` 里删掉」** | 删掉会让 `Pages.swift` 的调用点**编译失败** ⇒ 变异变成「编译红」而不是「判据红」，**测不到判据** | 改为**改名**为 `ScanProgressStripMutated`（编译仍过、判据仍应红）⇒ 首次实跑假绿，收紧锚点后正确报红 |
| 5 | **§八 步骤 6 变异 ⑥ 原写「把 `progressing` 改成也累加 `deltaFiles`」** | `progressing` 是**非 mutating** 的，且唯一调用点在 `@Sendable` 闭包内（只能用不可变快照 `let base = acc`）⇒ 改成 mutating 会让 App 层**编译失败**（不是测试红） | 变异落到**等价落点** `completing` 的 `filesScanned += files` ⇒ `+= files * 2`（同一来源被数两遍）⇒ 两条用例报红（§10.5 第 6 行） |
| 6 | **§八 步骤 7 的期望值写「472 + N」** | 472 是 HEAD `dc7f813` 的基线；**同工作区**里 CR-036 已把单测数提到 **481** | 订正为「基线 481 + 本单 15 = **496**」 |
| 7 | **a5 的新增注释块一度重复两遍** | 脚本生成时按「块」拼接，锚点命中了两处 | 去重后为 **5 行**；已用 `count(dup) == 1` 断言过 |
| 8 | **第 13 条用例 `testStartingReportsDenominatorBeforeAnySourceCompletes` 是实施时新增，本单初稿未列** | 实施时发现：`fraction` 的分母来自 `totalSources`，若起手分母为 `nil` ⇒ **第一拍画不出弧** ⇒ 与 §八 步骤 1「起手不空白」的硬约束相抵 ⇒ 必须有一条用例把「起手就有分母」钉住 | §八 步骤 3 已补该条的说明；§4.2 / §10.2 / §4.3 的条数已同步（12 ⇒ 13） |
| 9 | **§八 步骤 4 第 13 条原写「**编译期断言**用 `#if`」，实际实现是 `Mirror` 反射** | 编译期断言在字段被删后是「**编译不过**」⇒ **测不出「字段还在」**（编译失败 ≠ 测试红）⇒ 那样这条用例只是「守着不让删」，**守不住「删了之后要红」** | 改为 `Mirror(reflecting: PageModel()).children.compactMap { $0.label }` ⇒ 断言字段名集合**不含** `loading` / `loadingMessage`、**含** `scanProgress`；§八 步骤 4 已订正 |
| 10 | **§3.19 表内「现值 61 / 23 / 140」是 HEAD 基线，工作区早已是 63 / 25 / 142** | CR-036 的实施已把 `ARCHITECTURE.md:87` / `CLAUDE.md:11` / `CLAUDE.md:127` 三处写成 63 / 25 / 142 | §3.19 已补 ★ 说明；**本单这三处不再改**（实测已对齐，登记为 §10.6 第 9 行） |

**★ 订正后 §3.17 / §3.19 / §4.2 / §4.3 / §八 步骤 3 / §八 步骤 4 / §八 步骤 5 / §八 步骤 6 / §八 步骤 7 的正文已同步改写** —— 变更单里**不留与实跑不一致的旧表述**。

### 10.5 防假绿验证

§八 步骤 6 的**六条变异逐条实跑**。★ 每条都是「**先改坏 → 实跑 → 看红 → 还原**」⇒ 全部还原后再次实跑 a9 与单测，均为绿（80 / 496）。

| # | 变异 | 实跑红输出 | 抓住它的判据 |
|---|---|---|---|
| 1 | `fraction` 的 `guard totalSources > 0 else { return nil }` ⇒ `return 0` | `ScanProgressTests.swift:40: XCTAssertNil failed: "0.0"`；`Executed 13 tests, with 1 failure` | 单测 `testFractionIsNilWhenDenominatorUnknown`（**不变量③**：`nil ≠ 0`） |
| 2 | 组件改名 `ScanProgressStrip` ⇒ `ScanProgressStripMutated` | ⚠️ **首次实跑 a9 仍绿（假绿）** —— 根因：`grep -qF` 是**子串匹配**；**收紧锚点后**（`ScanProgressStrip(` + 新增第三条 `trim(from: 0, to:`）⇒ `✗ 界面不显示扫描进度`；a9 **79 / 1** | a9「界面显示扫描进度（用户看得到它在动）」 |
| 3 | `Text(progress.displayText)` ⇒ `Text(slot.displayText)` | `✗ 界面不显示扫描进度`；a9 **79 / 1** | a9 同项（锚点串 `progress.displayText` 不再匹配） |
| 4 | `onCancel: { app.cancelScan() }` ⇒ `onCancel: {}` | `✗ 界面无取消入口 → 用户必须等完 12 秒`；a9 **79 / 1** | a9「界面提供取消扫描（12 秒不能反悔）」 |
| 5 | `completedSources += 1` ⇒ `completedSources += 0`（分子永不推进） | `ScanProgressTests.swift:113: ("0") is not equal to ("1") - 跳过的来源也算完成`；`Executed 13 tests, with 1 failure` | 单测 `testCompletedSourcesAdvancesWhenSourceIsSkipped` |
| 6 | `completing` 的 `filesScanned += files` ⇒ `+= files * 2`（同一来源被数两遍） | `testProgressingDoesNotDoubleCountTheRunningSource` 红（`:147` / `:150` / `:151` / `:154`）+ `testFilesScannedAccumulatesAcrossSources` 红（`:123` / `:125`）；`Executed 13 tests, with 6 failures` | 单测（跨来源累计 + 进行中不双计） |

### 10.5.1 变异 ② 的「首次假绿 → 判据收紧」全过程

| 步骤 | 做了什么 | 结果 |
|---|---|---|
| ① | 按本单原计划把组件改名 `ScanProgressStripMutated`（不删，删了编译不过 ⇒ 测不到判据） | a9 **仍绿** —— ❌ **假绿** |
| ② | 定位根因：a9 原判据是 `grep -qF 'ScanProgressStrip'` ⇒ **子串匹配** ⇒ `ScanProgressStripMutated` **命中** | — |
| ③ | 收紧锚点：a9 三条改为 `ScanProgressStrip(`（**带调用括号**）+ `progress.displayText` + **新增** `trim(from: 0, to:`（确定弧的证据）；a5 两条相应改为 `ScanProgressStrip(` | 判据**意图不变**，只是「更精确地指着同一件事」 |
| ④ | 复跑同一变异 | a9 **79 / 1** ⇒ `✗ 界面不显示扫描进度` ⇒ ✅ **抓住** |
| ⑤ | 还原变异，复跑 a9 / a5 / 单测 | a9 **80 / 0**、a5 **42 / 0**、单测 **496 / 0** ⇒ **项数不变** |

> ★ 这一条本身就是「**判据不是形式，是承诺**」的证据：锚点写不写调用括号，区别只在**能不能被改名骗过**。


### 10.6 已知既有漂移（本单不处理，登记备查）

| # | 漂移 | 位置 | 处置 |
|---|---|---|---|
| 1 | `ScanEngine.Progress.source` 注释写「`Source.rawValue`」，实传根路径 | `ResidueApp/Sources/ResidueCore/ScanEngine.swift:364` / `:570` | 登记，不改 |
| 2 | `ScanEngine.Progress.filesScanned` 注释写「累计」，实为单来源内 | `ResidueApp/Sources/ResidueCore/ScanEngine.swift:366` | 登记，不改 |
| 3 | `ScanProgress.source` 设置了但界面不显示 | `ResidueApp/Sources/ResidueCore/ScanProgress.swift` | 登记，不删 |
| 4 | `Source.rawValue` 带下划线，不宜直接上界面 | `ResidueApp/Sources/ResidueCore/Metrics.swift:45-48` | 登记（将来显示前需可读化映射） |
| 5 | `displayText` 的既有三段文案内联在 `displayText` 里，不在 `UICopy` | 本单迁入后位于 `ResidueApp/Sources/ResidueCore/ScanProgress.swift`（原 `ResidueApp/Sources/ResidueApp/ScanInfrastructure.swift:52-62`） | 登记，不整体搬迁 |
| 6 | ① 页首启空态文案「还没有扫描过」是 DAC-80 违例 | `ResidueApp/Sources/ResidueApp/Components.swift:387` | 登记，不在本单范围 |
| 7 | `DesignTokens` 无圆环直径 token | `ResidueApp/Sources/ResidueApp/DesignTokens.swift` | 登记（直径写在组件内） |
| 8 | `release.yml:211` 的「页面结构 80 项」不被 `verify_counts.py` 匹配 | `.github/workflows/release.yml:211-212` | 登记（该项数本单不变） |
| 9 | `docs/` 份数声明在**本单实施前就已对齐**（63 / 25 / 142） | `ARCHITECTURE.md:87` / `CLAUDE.md:11` / `CLAUDE.md:127` | 登记，**本单不改**（CR-036 的实施已写成对齐值；本单实测 `docs/changes/` = 63 份文件 / 25 个单号、`docs/**/*.md` = 142 份 ⇒ 三处**一致**） |
| 10 | `AppModel.swift` 的 release warning **行号下移**（CR-036 记的是 1105 ⇒ 现为 1140） | `ResidueApp/Sources/ResidueApp/AppModel.swift:1140`（`deleted` never used） | 登记（本单改动使行号下移；warning 本身是**既有漂移**，不在本单范围） |
