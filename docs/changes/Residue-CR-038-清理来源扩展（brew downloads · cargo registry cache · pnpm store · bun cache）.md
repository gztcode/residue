# CR-038 · 清理来源扩展（brew downloads / cargo registry cache / pnpm store / bun cache） · P0 · 判定域由 2 类扩为 4 类、域外只报告由 1 类扩为 3 类

> 状态：待实施
> 变更类型：契约基线变更（PRD v5.6 + R2 v1.10）+ 封闭枚举扩展 + 载体段表扩展
> 影响面：`ResidueCore`（`Source` / `SourceRule` / `ScanEngine` / `ResidueStateFile` / `ObservationWriteback` / `UpstreamCommand`）、`ResidueApp`（`AppModel` / `Pages` / `Components` / `PageRenderer` / `DesignSampleData` / `WiringSelfCheck`）、契约基线两份、设计稿 16 张
> 风险等级：P0 —— 触碰「删除只做 rename 到废纸篓」与「删之前先证明自己判得准」两条核心不变量；判定域成员变化 ⇒ 存量用户观察期必须重新起算

---

## 一、缺陷

### 1.1 现象

产品当前只清理两类 AI 工具链缓存：`uv` cache 与 `npm/_npx`。用户机器上另有四类同性质的缓存占着空间，本产品完全看不到：

| 来源 | 本机路径 | 本机体积 | 本机文件数 | 当前是否被扫 |
|---|---|---|---|---|
| Homebrew 瓶装归档 | `~/Library/Caches/Homebrew/downloads` | 2.7 G | 193 | ❌ |
| cargo 注册表缓存 | `~/.cargo/registry/cache` | 116 M | 868 | ❌ |
| pnpm 内容寻址存储 | `~/Library/pnpm/store` | 2.8 G | **117,457**〔v1.10 · CR-038 实测校正 2026-11-19：原值 60,438 只数了 `store/v11/files/`，漏了 `store/v11/links/` 的 57,017〕 | ❌ |
| bun 安装缓存 | `~/.bun/install/cache` | 119 M | 10,514 | ❌ |

四类合计 ≈ 129,032 个文件〔v1.10 · CR-038 实测校正 2026-11-19：193 + 868 + 117,457 + 10,514；原值 71,820 = 868 + 60,438 + 10,514，**漏加了 Homebrew 的 193** 且 pnpm 本身少了一半 —— 见 §10.4 第 10 条〕、≈ 5.7 G 占用（**体积未变**），其中占比最大的两类（Homebrew 2.7 G + pnpm 2.8 G）体积与已被管理的 `uv` cache（1.9 G）相当。

### 1.2 复现路径（代码级）

`ResidueApp/Sources/ResidueCore/Metrics.swift:45-67` —— 来源封闭枚举只有三个 case：

```swift
public enum Source: String, Codable, Sendable, CaseIterable {
    case uvCache = "uv_cache"
    case npmNpx = "npm_npx"
    case pipxRun = "pipx_run"
```

`ResidueApp/Sources/ResidueCore/ScanEngine.swift:296-343` —— 默认来源规则集只有三条路径片段：

```swift
public static let defaults: [SourceRule] = [
    SourceRule(source: .uvCache, pathFragments: ["/.cache/uv/"]),
    SourceRule(source: .npmNpx, pathFragments: ["/.npm/_npx/"]),
    SourceRule(source: .pipxRun, pathFragments: ["/.local/pipx/venv/"]),
]
```

`ResidueApp/Sources/ResidueApp/ScanInfrastructure.swift:127-156` —— 来源根解析只产出三条根：

```swift
out.append((Source.uvCache.rawValue, uvRoot))
out.append((Source.npmNpx.rawValue, npmBase + "/_npx"))
out.append((Source.pipxRun.rawValue, home + "/.local/pipx/venv"))
```

⇒ 即便用户把上述四类缓存删到零，本产品也观察不到、不会报告、更不会清理。

### 1.3 第二个后果：来源枚举是「封闭枚举」且写入载体段索引

`Source` 不是纯界面枚举 —— 它的**声明序**被烧进了载体文件的段索引：

`ResidueApp/Sources/ResidueCore/ResidueStateFile.swift:613-616`（写）：

```swift
for (sourceIndex, source) in Source.allCases.enumerated() {
    guard let p = payloads[source] else { continue }
    let index = UInt8(sourceIndex)
```

`ResidueApp/Sources/ResidueCore/ResidueStateFile.swift:892-900`（读）：

```swift
let sourceList = Source.allCases
for seg in segments {
    guard Int(seg.sourceIndex) < sourceList.count else {
        throw StateFileError.segmentValidationFailed(detail: "sourceIndex \(seg.sourceIndex) 越界")
    }
    let source = sourceList[Int(seg.sourceIndex)]
```

⇒ **在枚举中间插入 case 会让存量载体的旧来源段索引整体错位** —— 原来指向 `npm_npx` 的段会被读成新来源，误判数 `a` 归错来源，违反不变量④「删之前先证明自己判得准」。这是本单第一硬约束（见 3.1）。

### 1.4 第三个后果：判定域成员变化不会自动重启观察期

契约 PRD v5.6 `:1017`（AC-04 ② 原文）：

> ② **该来源在本轮观察期开始时已在判定域**：点亮后才入域、或观察期内才首次出现的来源，其候选**不进本轮自动删除候选集**、只进报告，直到**下一次全局观察期开始**（**计时器为全局单实例、不按来源分裂，故不存在「该来源自己的观察期」**；若期间未发生任何归零 / 版本切换，该来源**本期不参与自动删除**）

PRD v5.6 `:1203`（「计数第一键」行）：

> **〔CR-012 · 架构 A6 · 引用唯一分组键〕分组计数一律以「指标定义表 · 分组键」行为唯一依据**——`T` / `K` / `J` / `b` 按 (来源, 轮次)、**`a` 按 (来源, 应用版本) 跨轮次累计**；…**观察期计时器为全局单实例、不按来源分裂**（开关只有一个，不存在「各来源各自计时」）——这一条同时封住「用来源粒度把计时器拆成多份」的读法（CR-007 · R-5）

⇒ **契约明令禁止「按来源分裂计时器」** ⇒ 「给新来源单独开一份 14 天观察期」这一常见做法**违反契约**，本单不采用。

⇒ 唯一合法路径 = **全局观察期重启**，而契约认可的全局重启手段只有两个：**归零** 与 **版本切换**。PRD v5.6 `:1293`（S2）：

> 〔CR-012 · 架构 A2〕此处「版本」= 应用版本…**应用版本变更时 L0 / 样本 / 计时器全部随应用版本重置**，同应用版本内的**轮次切换保留** L0 计数

⇒ 「随新版本一起重置」与契约一致。但**版本号 bump 依赖人记得改**，漏改则新来源会在**旧的全局观察期**里直接取得删除资格 —— 用户裁决「加指纹自动比对」正是补这个洞。

### 1.5 与其它单的关系

- **CR-036 / CR-037**（① 页未达项三态、① 页扫描进度环）：本单把 `Source.allCases` 从 3 扩到 7 ⇒ **① 页来源卡从 3 张变 7 张**，CR-037 的圆环分母从 3 变 7、CR-034 的未达项披露条数随之变化。三单在同一分支上依次叠加，**本单改动面覆盖二者**。
- 本单不动 CR-034 的未达项逻辑、不动 CR-037 的圆环语义。

---

## 二、契约依据

### 2.1 PRD v5.6 `:915`（来源分流总裁决 · C2）

> 〔CR-006 · K-1 来源分流裁决〕按上游是否自清分流：上游不自清的来源（`uv` cache、`npm/_npx` **两类、封闭枚举；新增来源须另出变更单，不得以「等」留开放尾**）参与自动删除；上游 14 天机会式自清的 `pipx` run 临时 venv **只报告、不自动删**（仍进扫描 / 举证链）。因此 **N 只约束参与来源**

⇒ 本单是「新增来源」的唯一合法入口（正是它自己要求的）。「封闭枚举」「不得以『等』留开放尾」两条封尾约束**保留不变**，本单只是把枚举从 2 类扩到 4 类（判定域）+ 3 类（域外只报告），仍是封闭枚举。

### 2.2 PRD v5.6 `:1016`（AC-04 Given ①）

> **所属来源在判定域内**：来源属封闭枚举（`uv` cache / `npm/_npx` 两类，新增须另出变更单、不得以「等」留开放尾），且该来源**观察期开始快照总量 `T ≥ 1`**；`pipx` run 临时 venv 因上游 14 天机会式自清**不进判定域**（只进扫描 / 报告 / 举证链）

### 2.3 PRD v5.6 `:1026`（AC-04 判定）

> 〔CR-008 · K-7〕第 ② 页候选清单每行带标签且取值 ∈ {可参与自动删除 / 仅报告}，标签与「该来源是否在判定域」一致（域内 → 可参与；`pipx` run → 仅报告）

### 2.4 PRD v5.6 `:1076`（AC-08 组 B · L2 不构成门槛）

> `L2` 不构成门槛：`uv` cache / `npm/_npx` 均无稳定 L2 观测通道（无 lockfile、影子期不删条目，见 AC-09）→ 读数恒 0 而不具观测意义，列入门槛即空转（CR-008 · G-10；用户 2026-11-07 裁决）。

⚠️ **本条现有推理链对新来源不成立**：pnpm 与 bun **确有 lockfile**（PRD `:1084` 把 lockfile 列为 L2 判据之一）⇒ 必须逐源重新裁决，不能沿用「均无稳定 L2 观测通道」的旧句。

### 2.5 PRD v5.6 `:1087` / `:1090` / `:1092` / `:1093`（AC-09 判定 ②⑤⑦ 与域外行取值）

> ② `来源` ∈ 判定域枚举 ∪ {`pipx` run}
> ⑤ `L2 误判数` ∈ {数值} ∪ {「该来源不适用（无观测通道）」}——`uv` cache / `npm/_npx` 固定取后者，**不得显示 0**…〔CR-010 · 建议 G1〕该断言对本两类来源恒成立、无判别力，故**判定改为「⑤ 取值唯一且与该行来源一致」**（`uv` cache / `npm/_npx` 行取值 = 「该来源不适用（无观测通道）」、`pipx` run 行取值 = 「该来源不适用（无观测通道）」、其余来源行取值 = 数值）
> ⑦ `结论` ∈ {达标 / 未达标 / 仅报告} 且无空值；**`达标` ⟺ 该行属判定域 且 观察期已满且报告已生成 且 `K ≥ H` 且 `a = 0` 且 `b ≥ 1`**…**非判定域行（`pipx` run）恒为「仅报告」、不参与该式**
> ③ 取本窗扫描到的该来源条目数与失联，**并在该单元格内标注「扫描时点值 · 非结算值」**…；④ 填「不适用（不入判定域）」；⑤ 固定「该来源不适用（无观测通道）」；⑥ 填「不适用 · 未执行 L0 检查」；⑦ 恒「仅报告」。**该行不参与任何门槛判定。**

⇒ 「`pipx` run 行」的规则要**升格为「域外只报告行」的通用规则**，三个域外来源同规则。

### 2.6 PRD v5.6 `:1094`（AC-09 行集合公式）

> **行集合为条件式** = 判定域 ∪ {`pipx` run **且本机该来源候选总量 ≥ 1 时**占行}，总量为 0 的来源不占行；〔CR-011 · 架构 A11〕新入域来源（点亮后首次命中、本轮无快照）占行

### 2.7 PRD v5.6 `:1200`（判定域定义）

> **参与自动删除的来源 = 本机扫描命中、且该来源候选总量 ≥ 1 的上游不自清类来源**；当前版本**封闭枚举为 `uv` cache 与 `npm/_npx` 两类**，新增来源须另出变更单、不得以「等」留开放尾。…总量为 0 的来源**不进判定域**…判定域为空时，开关区按 §8「空」类**三项枚举**呈现（无可扫描来源 / 无清理候选〔判定域内无候选；**仅 `pipx` run 有候选时归此项**〕/ 观察期尚无数据本期无实例）

### 2.8 PRD v5.6 `:136`（M3 指标表「`pipx` run 行例外」行）

> 非判定域行**不取快照** → 该行 `J` 无非零来源、**不套用 `K + J = T` 恒等式**（否则该断言对该行恒真、无判别力）；该行 ③ 单元格须标注「扫描时点值 · 非结算值」，**不套用判定域行的 ③ 列呈现规则**

### 2.9 PRD v5.6 `:1045`（AC-07 候选清单物料分类）

> 候选清单条目全部属于缓存 / 临时 venv / 构建产物三类

### 2.10 PRD v5.6 `:1177` / `:1178` / `:1218`（只读定位命令白名单 · N6 探测预算）

> …上游命令逐条登记网络属性（T3）：CR-002 后集合仅含只读定位与举证命令（`uv cache dir` / `npm cache ls` / **`brew --cache`** 等），按概念卡 §0 F1 / F2 / F3 **全部纯本地、不产生外发、不附带网络动作**

> N6：包管理器以「CLI 存在性 + 能力探测」为准、不硬编码最低版本；单探测 ≤ 2 s、总探测 ≤ 10 s

⇒ ★ **`brew --cache` 已被 PRD 原文点名在白名单内** ⇒ Homebrew 的根解析**零契约改动**。

### 2.11 PRD v5.6 `:842`（T3 网络连通性）

> …上游命令是否附带网络动作（brew auto-update 类，且不由产品发起、不在 AC-19 集合内）。

⇒ `brew auto-update` 从「举例」升级为「实质风险」（本期新增 Homebrew 来源 ⇒ `brew --cache` 成为常规探测命令），须逐命令核实。

### 2.12 PRD v5.6 `:1213`（N1 扫描预算）

> N1：全量扫描（328 万文件量级）p95 ≤ 10 min，必须可中断/可取消/断点可续

### 2.13 PRD v5.6 `:186`（CR-010 A-2 已知边界放大）

判定域内**没有来源剔除路径**（除该来源候选总量归 0）→ 某一个来源的长期样本不足会持续把全部来源拖回第 1 轮。判定域从 2 类扩到 4 类 ⇒ 该风险面扩大。

### 2.14 R2 v1.10 相关条款

| 行 | 内容摘要 | 处置 |
|---|---|---|
| `:328` | 段序固定 = `Source.allCases` 声明序，读方按 `(sourceIndex, kind)` 索引 | 补 7 个来源名 + **尾部追加硬约束** |
| `:372` | 段表字段 `source` 取值域 `enum(uv.cache/npm.npx/pipx.run)` | 扩为 7 个 rawValue |
| `:302-308` | 载体 JSON 示例 | 按 7 来源展开 |
| `:320` | `previousRound.source` 示例取值池 | 随枚举序更新 |
| `:375` / `:659` | L2 观测通道登记 | 逐源登记 |
| `:713` | schema 迁移矩阵 | **新增「新增来源」一行**（易漏） |
| `:331` / `:332` | 段数算例 `segCount = 9` / `12` | 改 `segCount = 28`、段表 `24×28 = 672 B` |
| `:757` | `K + J = T` 恒等式适用说明 | 「含 3 个域外只报告来源」 |
| `:964` / `:1115` / `:1116` | 上游命令白名单条数、必拒清单、放行清单 | 重数 + 两侧各增 4 类来源 |
| `:1069` | 段序固定（重复表述） | **最适合加「尾部追加」约束** |
| `:1174` / `:1175` / `:1178` / `:1180` | 版面：三区块横排、七列三行 | 七区块 / 七行；**版面须复核**（一屏放不下 7 行） |

### 2.15 ★ 契约内部歧义登记（本单不解决，只登记）

1. **「域外行 ③/⑥」的实现与 PRD `:1093` 不一致**（既有偏差）：PRD 说域外行 ③ 取「扫描时点值 · 非结算值」、⑥ 填「不适用 · 未执行 L0 检查」；而 `PageModelBuilder.swift:565-637`（`reportRow`）里域外行 ③ 同样显示「本轮未结算」、⑥ 同样是 `a`/`b` 数值。**本单新增的域外来源沿用既有行为，不改实现**，登记为既有偏差。
2. **`Source` 枚举尾部追加的载体兼容性依赖「首启不写段」这一事实**：编码器对缺载荷的来源 `continue`（`ResidueStateFile.swift:615`），但 `ObservationWriteback.apply` 对**每个** `Source.allCases` 都写载荷（`ObservationWriteback.swift:216`）⇒ 存量载体在**第一次观测写回后**会新增 4 个来源 × 4 段 = 16 段，段数 12 → 28。载体格式自描述（段表在文件头）⇒ **不必升 schema 版本**。
3. **旧 App 读新载体必然报 `E-304`**：新载体的 `sourceIndex` 最大为 6，旧 App 的 `Source.allCases.count` 为 3 ⇒ 越界 ⇒ fail-closed。这是唯一安全处置（见 §九 #2）。
4. **「新入域来源行 ③/⑦」的口径本单不实现**（本单遗留）：PRD `:1094` 要求新入域来源（点亮后首次命中、本轮无快照）③ 填「本轮无快照 · 扫描时点值 · 非结算值」、⑦ 恒「仅报告」；而 `PageModelBuilder.swift`（`reportRow`）对「域内但 `K`/`T` 皆 nil」的行，③ 与 ⑦ 都取 `.unavailable(reason: UICopy.sourceNotSettled)`（= 「本来源未结算」）。**与第 1 条是两处不同**（第 1 条是域外行 ③/⑥，本条是新入域行 ③/⑦）。本单不实现该口径，登记为遗留偏差。
5. **⑤ 页缺 `L2 误判数` 列、多 `观察期` 列**（既有偏差 · 台账 M-5 已登记）：PRD `:1092` ⑤ 要求「`L2 误判数` ∈ {数值} ∪ {「该来源不适用（无观测通道）」}——**本期七个来源全部固定取后者，不得显示 0**」，DAC-84 已同步；实现侧 `ReportMatrix.columns`（`PageModel.swift:514-524`）的第 ⑤ 列是「**观察期**」，PRD 里没有对应项，且 `grep -rn "该来源不适用" ResidueApp/Sources/` **零命中** ⇒ **PRD 的 ⑤ 列在实现里根本不存在**（源码里「L2」只命中 `model.l2Inferred`（① 页 AC-02）、`evidenceFields`（⑦ 页）、`PageModelBuilder.swift:321` 注释）。台账 `docs/ledger/Residue-Phase3-闸门台账.md:236`（M-5）已登记该偏差并裁「**换列是产品决定**（`观察期` 列的数据在 PRD 里没有对应项）」⇒ 本单**只登记、不实现**。

---

## 三、改什么

### 3.1 `Source` 枚举扩展（末尾追加 + 两态 + 粒度 + 指纹）

**文件**：`ResidueApp/Sources/ResidueCore/Metrics.swift:45-67`

**★ 硬约束：新 case 一律追加在枚举末尾**（`pipxRun` 之后），理由见 1.3 —— 插中间会让存量载体段索引错位。

新增四个 case 与 rawValue：

| case | rawValue | 判定域 | 候选粒度 |
|---|---|---|---|
| `homebrewDownloads` | `brew_downloads` | ✅ 是 | 逐条 |
| `cargoRegistryCache` | `cargo_registry_cache` | ✅ 是 | 逐条 |
| `pnpmStore` | `pnpm_store` | ❌ 否 | **整块** |
| `bunCache` | `bun_cache` | ❌ 否 | **整块** |

枚举扩展后：

```swift
public enum Source: String, Codable, Sendable, CaseIterable {
    case uvCache = "uv_cache"
    case npmNpx = "npm_npx"
    case pipxRun = "pipx_run"
    // ⚠️ 追加区：新增来源只能追加在末尾 —— 载体段索引 = 声明序（`ResidueStateFile.swift:613`）
    case homebrewDownloads = "brew_downloads"
    case cargoRegistryCache = "cargo_registry_cache"
    case pnpmStore = "pnpm_store"
    case bunCache = "bun_cache"
```

`isInDecisionDomain` 两态扩展为：域内 = `uvCache` / `npmNpx` / `homebrewDownloads` / `cargoRegistryCache`；域外 = `pipxRun` / `pnpmStore` / `bunCache`。

`displayName` 扩展为：`"uv cache"` / `"npm/_npx"` / `"pipx run"` / `"brew downloads"` / `"cargo cache"` / `"pnpm store"` / `"bun cache"`。

> **显示名长度受版面硬约束**（视觉基线 v1.1 `:21`「数据行 32 pt 固定」）：⑤ 页来源列宽 100 pt，扣两侧 padding 只剩 84 pt ⇒ 超过约 13 字符即换行 ⇒ **撑破固定行高**。故 cargo 取短名 `"cargo cache"`（与既有 `"uv cache"` / `"bun cache"` 同风格），不取 `"cargo registry cache"`（20 字符，必换行）。
>
> 名称精度不丢：精确路径由 ② 页候选行（`cargo/registry/cache/…crate`）与 ⑦ 页举证链给出。
>
> **显示名不参与持久化**（落盘只用 `rawValue`）⇒ 改名对存量载体、观察期重置**零影响**。契约基线（PRD / R2 / DAC / B1 / 视觉基线）对 brew / cargo / pnpm / bun 的显示名**零约束** ⇒ 不需要改契约基线。

**新增：候选粒度属性**（新增来源的能力维度，须放在 `Source` 上而非 `SourceRule` 上 —— 粒度是来源的固有属性，不是路径映射规则的属性）：

```swift
/// 候选粒度：该来源的清理单元是「逐个条目」还是「整个来源根算一块」。
///
/// - `.perEntry`：每个命中叶子各成一条候选（`uv` / `npm` / `pipx` / `brew` / `cargo`）。
/// - `.wholeBlock`：整个来源根的命中叶子只累计字节，收敛成**一条**整块候选
///   （`pnpm` store / `bun` cache —— 内容寻址 + 硬链接布局，逐条列举会产出上万个碎片条目）。
public enum CandidateGranularity: String, Codable, Sendable {
    case perEntry
    case wholeBlock
}
```

`Source` 增加：

```swift
public var candidateGranularity: CandidateGranularity {
    switch self {
    case .uvCache, .npmNpx, .pipxRun, .homebrewDownloads, .cargoRegistryCache:
        return .perEntry
    case .pnpmStore, .bunCache:
        return .wholeBlock
    }
}
```

**新增：判定域成员指纹**（自动检测来源集合变化 ⇒ 触发全局观察期重启）：

```swift
/// 判定域成员指纹 —— 载体里存一份，加载时与当前代码算出的比对。
///
/// 覆盖**全部来源及其归属**（不只判定域）⇒ 任何来源集合变化都触发重置。
/// 纯域外新增来源也触发重置 —— 保守方向（宁严勿松），见 §九 #9。
public static var decisionDomainSignature: String {
    allCases.map { "\($0.rawValue)=\($0.isInDecisionDomain ? "1" : "0")" }
        .joined(separator: "|")
}
```

### 3.2 `SourceRule.defaults` 增补四条路径片段

**文件**：`ResidueApp/Sources/ResidueCore/ScanEngine.swift:296-343`

新增（★ 七条片段**必须互不重叠** —— `SourceRule.match` 返回**所有**命中规则的 rawValue 数组，重叠会产出逗号串，`Source(rawValue:)` 解析失败、字节聚合漏算）：

| 来源 | 路径片段 | 互斥依据 |
|---|---|---|
| `brew_downloads` | `"/Library/Caches/Homebrew/downloads/"` | 只命中 `downloads/` 子目录，不含 `brew` 的其它缓存 |
| `cargo_registry_cache` | `"/.cargo/registry/cache/"` | 与 `~/.cargo/registry/src/`（源码解压目录）天然区分 —— **`src` 路径不含 `/cache/`** ⇒ 只有 `cache` 可删 |
| `pnpm_store` | `"/Library/pnpm/store/"` | 版本子目录（`v10/` / `v11/`）在片段之后，自动匹配 |
| `bun_cache` | `"/.bun/install/cache/"` | 不含 `~/.bun/install/global/` 等其它物料 |

⚠️ 片段带尾斜杠 ⇒ **匹配的是根之下的路径，不是根本身**。这是既有三条片段的写法，新四条保持一致。

### 3.3 `resolveSourceRoots` 增补四条根解析

**文件**：`ResidueApp/Sources/ResidueApp/ScanInfrastructure.swift:127-156`

| 来源 | 解析方式 | 理由 |
|---|---|---|
| `brew_downloads` | `brew --cache` → 输出 + `"/downloads"` | `brew --cache` **已在只读白名单**（`UpstreamCommand.swift:97-98`）且 **PRD N6 原文点名** ⇒ 零契约改动；纯本地查询，**不触发 auto-update**（见 §九 #5） |
| `cargo_registry_cache` | 固定 `~/.cargo/registry/cache` | 无需探测 CLI；零进程开销、零网络 |
| `pnpm_store` | 固定 `~/Library/pnpm/store` | ★ **不调 `pnpm store path`** —— corepack shim 可能联网下载 pnpm，违反 N6「全部纯本地、不附带网络动作」（见 §九 #3） |
| `bun_cache` | 固定 `~/.bun/install/cache` | 同上 |

⚠️ `brew --cache` 的 stdout **可能带尾斜杠** ⇒ 直接拼 `"/downloads"` 会得到 `.../Homebrew//downloads` ⇒ 后续叶子路径不含 `/Library/Caches/Homebrew/downloads/` ⇒ **一条候选都匹配不到**。⇒ 拼接前须去掉 `brewBase` 的尾斜杠（`brewBase` 非根目录时）。

⚠️ 上游命令失败**回退标准路径**（与既有 `uv` / `npm` 同规则）⇒ 没装 brew 的用户只扫到 0 候选，不报错、不阻断。

### 3.4 `StateHeader` 增加指纹字段

**文件**：`ResidueApp/Sources/ResidueCore/ResidueStateFile.swift:230-279`

```swift
/// 判定域成员指纹（`Source.decisionDomainSignature`）。
///
/// `String?` + 合成 Codable ⇒ 走 `decodeIfPresent` ⇒ **存量载体天然兼容**（无该字段 ⇒ `nil`）。
/// `nil` ≠ 指纹 ⇒ 存量用户首次启动即触发一次全局观察期重置 —— 正是应有的语义。
public var decisionDomainSignature: String?
```

★ 该结构**无 `CodingKeys`、无自定义 `init(from:)`** ⇒ 合成 Codable ⇒ 新增可选属性不破坏旧载体解码。

### 3.5 指纹比对 ⇒ 全局观察期重启（★ 保留误判数 `a`）

**文件**：`ResidueApp/Sources/ResidueCore/ResidueStateFile.swift:307-335`（`resetObservationCredentials`）、`ResidueApp/Sources/ResidueCore/ObservationReset.swift`（`ObservationResetPolicy`）、`ResidueApp/Sources/ResidueApp/AppModel.swift`（`applyObservationResetIfNeeded`）

**★ 裁决：`resetObservationCredentials()` 加一个布尔参数，指纹路径传 `false` 保留 `a`。**

理由（不变量④ 的方向性）：

- `a` = L0 误判累计，`a = 0` 是点亮条件之一。
- **清 `a` 是宽松方向** —— 丢掉历史误判证据 ⇒ `a` 归零 ⇒ 更容易点亮 ⇒ 更容易误删。
- ⇒ 指纹路径（来源集合变了、但应用版本没变）**必须保留 `a`**：更保守，且符合 PRD `:1293` M4 字面「`a` 只在应用版本变更时清零」。

```swift
public mutating func resetObservationCredentials(clearingMissCount: Bool = true) {
    // …现有清零逻辑…
    if clearingMissCount { entry.a = 0 }
    // …
}
```

- **主路径（应用版本 bump）**：走既有 `clearCarrierForVersionChange` → `resetObservationCredentials()`（默认 `clearingMissCount: true`）⇒ **清 `a`** —— PRD `:1293` M4 明确许可「应用版本变更时 L0 / 样本 / 计时器全部随应用版本重置」。
- **兜底路径（指纹不一致、版本未变）**：`resetObservationCredentials(clearingMissCount: false)` ⇒ **保留 `a`**。

**比对时机**：与 `applyObservationResetIfNeeded()` 相邻 —— 加载载体后立即比对。判定顺序（**实现落点**：`ObservationResetPolicy.reason`，Core 层纯函数，可单测；`AppModel` 只做分派）：

```
stored.isEmpty（首启）      → 只记版本 + 指纹，不清零
appVersion != stored        → clearCarrierForObservationReset(preservingMissCount: false)（清 a）→ 写回新指纹
signature != stored.signature → clearCarrierForObservationReset(preservingMissCount: true)（保留 a）→ 写回新指纹
signature == nil（存量载体）→ 同上（nil ≠ 当前指纹 ⇒ 触发）
否则                        → 不动
```

★ **判定顺序是契约的一部分**：版本变更**优先于**指纹变更（版本路径更彻底，两者同时成立时一次重置就够，不必写两次载体）。

⚠️ **组合效应须登记**：若同时发生「版本 bump」与「指纹变化」，`a` 会被版本路径清掉（M4 许可）。这是有意的组合结果，不是缺陷。

**写回时机**：指纹在载体保存时统一写入当前 `Source.decisionDomainSignature` ⇒ 载体指纹 = 「当前代码状态下的指纹」。

### 3.6 `ScanEngine` 整块聚合

**文件**：`ResidueApp/Sources/ResidueCore/ScanEngine.swift:480-628`

**插入点**：`:577-592`（命中来源 → 收集为候选）那段。

逻辑改造：

```
命中来源片段的叶子：
  ├─ 取属性（birthtime / size / isDirectory）
  ├─ byteCount += size                      ← 两种粒度都算进扫描字节总数
  ├─ 若该来源是「整块粒度」：
  │     aggregatedBytes[source] += size     ← 只累计，不产生逐条候选
  └─ 否则：
        candidates.append(Candidate(...))   ← 逐条候选
```

**收敛点**（扫描正常结束时）：每个整块来源产出一条候选：

```
Candidate(path: <该来源的根>, birthtime: <根的 birthtime>, bytes: aggregatedBytes[source], isDirectory: true, source: rawValue)
```

- `path` = 扫描根路径（`scan(root:)` 的入参）—— 整块候选代表「整个来源根」。
- `birthtime` = 根目录的 birthtime；取不到时退回扫描起始时刻（域外来源不参与门槛判定 ⇒ 不影响任何结论）。

**★ 中止时不收敛**：中止时整块字节只是部分值 ⇒ 不产出整块候选（否则会把「扫了一半」说成「这个来源就这么多」—— 违反不变量③「不把未知判为安全」）。中止时只把累计值存进断点。

### 3.7 `Checkpoint` 增补 `aggregatedBytes`

**文件**：`ResidueApp/Sources/ResidueCore/ScanEngine.swift:233-292`

```swift
/// 整块粒度来源的累计字节（来源 rawValue → 字节数）。
///
/// ★ 整块候选**永不持久化** —— 它是 `aggregatedBytes` 的派生物。
///   持久化两份 ⇒ 断点续扫会重复累加（同一份字节算两遍）。
public var aggregatedBytes: [String: Int64]
```

**恢复规则**（断点续扫幂等的核心）：

```
aggregatedBytes = cp.aggregatedBytes          ← 累计值以断点为唯一真相
candidates.removeAll { 是整块来源的候选 }      ← 防御性：整块候选永不持久化，这里兜底
```

⇒ **断点续扫与一次性全量扫描的结果完全一致**（整块字节数不重不漏）。

### 3.8 ① 页来源卡改自适应网格

**文件**：`ResidueApp/Sources/ResidueApp/Pages.swift:83-88`

现状是 `HStack` 横排 7 张卡会挤爆。改为：

```swift
LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: Tokens.Spacing.m)], spacing: Tokens.Spacing.m) {
    ForEach(model.overviewBlocks) { OverviewBlockCard(block: $0) }
}
```

⚠️ `LazyVGrid` 只接受 `GridItem` 列 ⇒ 不能照抄 `HStack` 的写法。

⚠️ `OverviewBlockCard` 是否已是自撑高的（不写死高度）须在实施时确认；若写死了高度，7 张卡在 2 列网格里会截断。

### 3.9 ① 页合计文案去数字

**文件**：`ResidueApp/Sources/ResidueApp/Pages.swift:74`

`"三来源占用合计"` → `"来源占用合计"`（英文侧同步）。

⚠️ 该文案**只在 `Pages.swift:74` 一处，不在 `UICopy` 里** ⇒ `verify_a9.sh` 第四节不覆盖它 ⇒ 改文案不触发契约校验失败。

### 3.10 硬编码来源数同步

| 位置 | 现状 | 改为 |
|---|---|---|
| `ResidueApp/Sources/ResidueApp/WiringSelfCheck.swift:60` | `model.pageModel.overviewBlocks.count == 3` | `== Source.allCases.count`（不再写死数字） |
| `ResidueApp/Sources/ResidueApp/PageRenderer.swift:117` | `totalSources: 3` | `totalSources: Source.allCases.count` |

⚠️ `PageRenderer.swift` 属 `ResidueApp` 层、`Source` 属 `ResidueCore` ⇒ 可直接引用（依赖方向单向正确）。

⚠️ `WiringSelfCheck.swift:60` 的断言文案「① 页三区块由真实状态投影（Source.allCases 三个）」也要同步。

### 3.11 测试守卫同步（唯一三处硬编码）

**文件**：`ResidueApp/Tests/ResidueCoreTests/StateFileSchema2Tests.swift:280` / `:312` / `:363`

```swift
XCTAssertEqual(Source.allCases.count, 3, "来源数变了，夹具的位图长度恒等式不再成立")
```

⇒ 来源数变 7 后这三条**会主动失败**（设计上的守卫，不是 bug）⇒ 须同步改值，并同步改断言文案。

⚠️ 其余 11 处 `Source.allCases.count` 断言（`VersionResetTests.swift:140`、`StateFileTests.swift:127/232/613`、`StateFileMigrationTests.swift:144`、`ObservationWritebackTests.swift:67/643/694`、`StateFileSchema2Tests.swift:91/168`）**均为相对式，自动跟随，不动**。

### 3.12 注释与示例同步

⚠️ **本节原列 4 处已由 CR-037 部分完成**（「`overviewBlocks` 恒为三块」→「恒为「全部来源」块数」已改；「三张 `0 B` 卡」表述未改）。下表按**本单实际改动**重列，并注明哪些是 CR-037 已先行完成、哪些是本单补齐。

| 位置 | 现状 | 处置 |
|---|---|---|
| `ResidueApp/Sources/ResidueApp/Components.swift:439-441` | 注释说「`overviewBlocks` 恒为三块」 | **已由 CR-037 改为**「恒为「全部来源」块数（`Source.allCases.map`）」；本单把同段的「三张 `0 B` 卡片」同步为「**七张** `0 B` 卡片」 |
| `ResidueApp/Sources/ResidueApp/PageRenderer.swift:107-108` | 同上 | **已由 CR-037 改为**加载态横条（圆环 + 进度文案 + 取消按钮）；本单把分母注释同步为「来源总数（CR-038 起为 7）、分子 = 1 ⇒ 弧长 1/7」 |
| `ResidueApp/Sources/ResidueCore/SemanticSlot.swift:370` | 示例用三来源 | **已由 CR-037 改为**「已完成 1/7 个来源」（来源数 = `Source.allCases.count`）；本单不改 `SemanticSlot` 的封闭枚举 case 数 |
| `ResidueApp/Sources/ResidueApp/Pages.swift:57-58` | 「空态可达（原先 `overviewBlocks` 恒三块）」 | **已由 CR-037 改为**「空态可达（原先 `overviewBlocks` 恒为「全部来源」块数 → 这条分支永远进不来）」；本单把同段的「七张 0 B 卡片」表述与「来源卡横排（CR-038 §3.8）：来源数从 3 增到 7 ⇒ `HStack` 会挤爆」同步落盘 |

**本单新增 / 改写的注释（按文件）** —— 全部只改**来源清单与判定域归属**，不改判定逻辑：

| 文件 | 注释改动 |
|---|---|
| `ResidueCore/Metrics.swift` | `Source` 枚举文档注释：「封闭枚举（CR-038 后**七类**：判定域四类 = `uv` cache / `npm/_npx` / brew downloads / cargo cache；域外只报告三类 = `pipx` run / pnpm store / bun cache）」；`decisionDomainSignature` 的指纹语义注释（「编码**全部来源及其归属** ⇒ 任何来源集合或归属变化都会改变本值」） |
| `ResidueCore/ScanEngine.swift` | 「**封闭枚举**（AC-04 ①，CR-038 后七类）」 |
| `ResidueCore/PageModelBuilder.swift` | ①「而不是摆**七张** 0 B 的卡」；②「**判定域内的来源才可参与自动删除**（域外只报告三类 `pipx` run / pnpm store / bun cache 恒为仅报告）」；③ 未达项四态注释补「判定域空 / 判定域非空」的分界；④ ⑤ 页行集合注释补「判定域来源：本轮有快照（`T ≥ 1`）**或** 本窗扫到候选 ⇒ 占行」与「域外只报告来源：**只看本窗候选数** —— 它从不取快照，`T` 对它无意义，判定域语义不得外溢到它身上」 |
| `ResidueCore/PageModel.swift` | 空态注释「首启看到的是**七张** `0 B` 卡 + 一串 0」 |
| `ResidueCore/SemanticSlot.swift` | ①「判定域**非空**、报告已产出、观察期已满，但未达项集合为空」；②「`.noCleanupCandidate` → 「无清理候选」（页面有候选但判定域内无）」；③「形如「已完成 1/7 个来源」（来源数 = `Source.allCases.count`）」 |
| `ResidueCore/ObservationWriteback.swift` | 取快照判据注释补「判定域外的来源（`pipx` run / pnpm store / bun cache）**不取快照** —— 它们不参与自动删除」 |
| `ResidueCore/ResidueStateFile.swift` | 载体侧「**判定域成员指纹**（CR-038）」文档块（为什么写、为什么 `nil` 必须重置、为什么成员一变就重置） |
| `ResidueCore/StateFile.swift` | 重置策略表补「判定域指纹变更（`preservingMissCount: true`）| **保留** | **保留** |」一行 + 「判定域指纹写**当前值**」注释 + 「判定域指纹变更 ⇒ `a` 保留（PRD v5.6 M4）」 |
| `ResidueApp/AppModel.swift` | ①重置边界表补「版本没变但判定域指纹变了 \| 清零凭证，**保留 `a`**（M4）」；②「判定域指纹缺失 ⇒ 变更 ⇒ 反复重置 ⇒ 产品永远点不亮」；③「执行一次观察期重置（**版本变更清 `a` / 判定域变更保留 `a`**）」；④「**域外只报告三类恒为仅报告**（`pipx` run / pnpm store / bun cache）：不在判定域 → 永不参与自动删除（AC-04 ②）」 |
| `ResidueApp/DesignSampleData.swift` | 「① **七区块**（CR-038：来源从三类扩到七类）」+「⚠️ **合计必须与七张卡自洽**」+「样例不赋值的话，设计稿恒走**空态分支**，七张来源卡一张都不渲染」+「顺序 = 枚举声明序（域内域外**交错**，不是「域内 4 行在前」）」+「域外只报告来源（pnpm / bun）—— 判定域外两行」+「域外来源从不取快照 ⇒ K、T 皆 nil ⇒ 0 是**假值**（`nil ≠ 0`）」 |
| `ResidueApp/Pages.swift` | 见上表末行 + 「原先首启看到的是**七张** 0 B 卡片」 |

⚠️ `SemanticSlot` 的**封闭枚举 case 数 = 7 不得改**（不变量①）—— 本单只改示例文字，**不加 case、不改 case**。

### 3.13 `DesignSampleData` 来源名同步 + 重渲染 16 张设计稿

**文件**：`ResidueApp/Sources/ResidueApp/DesignSampleData.swift`

来源名从三来源改为七来源（示例数据用假字节数，不写真实扫描值），然后重渲染：

```bash
swift run --disable-sandbox ResidueApp --render-pages design-renders
```

### 3.14 PRD v5.6 逐行改动

★ **历史变更清单行（673 / 679 / 643 / 727 / 750 / 551 / 553 / 213 / 241 / 245 / 263 / 272 / 295 / 370 / 513 / 217）原文一字不动** —— 那是当时决策的留痕。新变更单须逐条重述其内容并挂本单号（见 §五）。

| 行 | 改动 |
|---|---|
| 136 | 「`pipx` run 行例外」→ 「域外只报告行例外」；主体「非判定域行」→「域外只报告行（`pipx` run / `pnpm` store / `bun` cache）」 |
| 186 | 已知边界「判定域内没有来源剔除路径」⇒ 判定域 2 → 4 类，风险面扩大 1 倍；严重度重述见 §九 #7 |
| 842 | `brew auto-update` 从举例升级为实质风险 ⇒ 须显式裁决 `brew --cache` 不触发 auto-update（T3 结论不变，理由升级） |
| 915 | 来源分流总裁决：判定域 2 类 → 4 类；域外只报告 1 类 → 3 类；**须补新增来源的自清属性裁决依据**（见 §三 3.15） |
| 1016 | AC-04 Given ①：「封闭枚举（`uv` cache / `npm/_npx` 两类）」→ 四类判定域 + 三类域外只报告；「`pipx` run 不进判定域」→ 三来源 |
| 1026 | 「域内 → 可参与；`pipx` run → 仅报告」→ 「域内四类 → 可参与；域外三类 → 仅报告」 |
| 1045 | AC-07 物料分类：四个新来源全部归「缓存」类；「三类」分类本身不改 |
| 1066 | 「判定域为 2 个来源时来源项应为 4 元素」→ 「判定域为 4 个来源时来源项应为 8 元素」 |
| 1076 | AC-08 组 B：L2 观测通道推理链**逐源重裁**，不能沿用「均无稳定 L2 观测通道」旧句 |
| 1087 | 「`来源` ∈ 判定域枚举 ∪ {`pipx` run}」→ 判定域四类 ∪ 域外三类 |
| 1090 | ⑤ 取值规则：本期**全部七个来源**均取「该来源不适用（无观测通道）」；「其余来源行取值 = 数值」一句删（本期无「其余来源」） |
| 1092 | ⑦「非判定域行（`pipx` run）」→「域外只报告行（`pipx` run / `pnpm` store / `bun` cache）」 |
| 1093 | 域外行取值规则**升格为「域外只报告行」通用规则** |
| 1094 | 行集合公式扩为 判定域(4) ∪ 域外(3，各须候选总量 ≥ 1) ⇒ **第 ⑤ 页最大行数 3 → 7** |
| 1177 / 1178 | 只读定位命令集合：登记新增来源的定位方式；★ `brew --cache` **已在集合内** ⇒ 白名单零扩张；cargo / pnpm / bun 用固定路径（不新增命令） |
| 1200 | 「封闭枚举为 `uv` cache 与 `npm/_npx` 两类」→ 四类；「仅 `pipx` run 有候选时归此项」→ 「仅域外只报告来源有候选时归此项」 |
| 1213 | N1「328 万文件量级」重估：新增 ≈ 129,032 文件 ⇒ 总量约 341 万（+3.9%）⇒ 数值不变但须登记重估依据〔v1.10 · CR-038 实测校正 2026-11-19：原值「71,820 / 约 335 万（+2.2%）」少算了 pnpm 的 `links/` 半边，见 §10.4 第 10 条〕 |
| 1218 | N6「单探测 ≤ 2 s、总探测 ≤ 10 s」：探测命令数 2 → 3（`uv cache dir` / `npm config get cache` / `brew --cache`），cargo / pnpm / bun **零探测** ⇒ 预算仍成立；须登记「pnpm 不走 `pnpm store path`」的理由 |
| 1247 | 第 ⑤ 页行集合 → 四类 + 三类 |
| 1274 / 1278 | 「因两类来源均无 L2 观测通道」「当前两类来源均无 L2 观测通道」→ 逐源表述；空域成因 ②「仅 `pipx` run 有候选时归此项」→「仅域外只报告来源有候选时归此项」 |
| 1293 | S2「`uv` cache / `npm/_npx` 无稳定观测通道」→ 逐源表述 |
| 1334 | 裁决段：`brew --cache` 已在集合内 ⇒ 无需改 |

### 3.15 新增来源的「上游是否自清」逐个裁决（PRD `:915` 要求补的）

| 来源 | 上游是否自清 | 依据 | 本期归属 |
|---|---|---|---|
| Homebrew `downloads/` | **否** | `brew cleanup` 需手动触发；Homebrew 不自动清下载缓存 | **判定域** |
| cargo `registry/cache` | **否** | cargo 本身不自动清注册表缓存；需 `cargo-cache` 等第三方手动工具 | **判定域** |
| pnpm store | **否** | `pnpm store prune` 需手动触发 | **域外只报告** |
| bun `install/cache` | **否** | `bun pm cache rm` 需手动触发 | **域外只报告** |

★ **PRD 必须显式写明**：pnpm store 与 bun `install/cache` **虽亦不自清**，但因二者为**内容寻址 + 硬链接**布局 —— 删除其中一个内容块会连带破坏其它包的引用（不可逆）⇒ 本期裁决为**只报告、不自动删**。

⚠️ 若不写这一条，「不自清 ⇒ 参与删除」的隐含推理链会与「pnpm / bun 只报告」直接冲突。

### 3.16 R2 v1.10 逐处改动

| 类 | 行 | 改动 |
|---|---|---|
| A | `:328` | 段序固定的来源清单补 7 个；**新增硬约束「新增来源只能尾部追加、不得插入中间」**（对应 `ResidueStateFile.swift:613-616` 写 / `:892-900` 读） |
| A | `:372` | 段表字段 `source` 取值域扩为 7 个 rawValue |
| A | `:302-306` | 载体 JSON 示例按 7 个来源展开，`state` 分 `inDomain` / 域外 |
| A | `:308` | `previousRound.source` 示例取值池随枚举序更新 |
| A | `:320` | 「判定域内按 `Source.allCases` 序首个 `K < H` 的来源」括号内举例更新 |
| A | `:667` | `RESIDUE_TEST_SOURCES`（封闭枚举子集）注入点扩到 7 个；`pipx` 行 → 「域外只报告行」 |
| A | `:1069` | 段序固定（重复表述）⇒ **最适合加「尾部追加」约束** |
| B | `:302` | `state` 每来源都要有一行 |
| B | `:757` | `K + J = T` 恒等式适用说明 → 「含 3 个域外只报告来源」 |
| B | `:1409` | 「`pipx.run` 不套该恒等式」⇒ 域外三来源同规则 |
| B | `:375` / `:659` | L2 观测通道逐源登记 |
| B | `:111` | 「候选所在目录其他用户可写 ⇒ 不进自动删除候选集」：**规则不改，但结论不可从 `~/.cache` 外推到 `~/.cargo/registry` / `~/Library/pnpm/store` / `~/.bun/install/cache`** ⇒ 须逐源实测 |
| B | `:791` / `:1262` / `:1266-1270` | 新增来源必须全部进入 `sourceRootReadable` 探测集合 |
| C | `:16` | 「每来源由三段改四段」⇒ 总段数 12 → 28 |
| C | `:331` | `segCount = 9` 算例 ⇒ `segCount = 28`、段表 `24×28 = 672 B` |
| C | `:332` | `segCount = 12` ⇒ `segCount = 28` |
| C | `:605-609` / `:789` | 载体体积 636 MB 量级：来源数 ×3 ⇒ 数值须重估 |
| C | `:713` | ★ **迁移矩阵须新增「新增来源」一行**（最易漏）：旧载体无新来源的段，而 `ensureSourceRows` 会补头部条目 ⇒ 「有头部条目无段」触发一致性校验失败（`E-304`） |
| C | `:1053` | 测试期望值同步改 |
| D | `:964` | 「封闭白名单（**6 条命令**…）」⇒ 重数；「归属来源」扩到 7 类 |
| D | `:1108` | 交付物规模随白名单条目数变化；测试条数 15 须重估 |
| D | `:1115` | 真删除命令必拒清单补 `pnpm store prune` / `bun pm cache rm` / `cargo cache --autoclean` 类；★ `brew cleanup` **已在列** |
| D | `:1116` | 放行的只读命令补新来源的定位方式；★ `brew --cache` **已就位** |
| D | `:1113` / `:73` / `:139` / `:538` / `:111` / `:1188` | 明确是举例 / 无关 ⇒ **不改** |
| E | `:117` | 「命中来源模式」⇒ 新增 4 类来源各需匹配模式；★ `~/.cargo/registry/cache` 与 `~/.cargo/registry/src` 要区分 —— **只有 `cache` 可删** |
| E | `:136` | 探测次数 1 → 4（`uv` / `npm` / `brew` 三条命令 + 固定路径零探测） |
| E | `:596` | ★ **增量扫描对新来源近乎失效**：「来源根 + 一级子目录」计数粗差对 pnpm store / cargo registry 的**深目录 + 内容寻址散列布局**几乎不变 ⇒ 增量扫描永远发现不了新候选 ⇒ 须为新来源单列增量策略 |
| E | `:598` | 总量 ×3 须重估 |
| E | `:611` | ★ `112 B = 路径均长 98 B`（实测样本只覆盖 uv）⇒ cargo registry / pnpm store 路径**显著更长**，每条 112 B 假设失效 |
| E | `:646` | cargo registry 内确有 symlink（`~/.cargo/bin` 是 shim）、pnpm store 有 `node_modules` 链接结构 ⇒ 允许根判定必须逐源精确 |
| E | `:583-589` | 328 万是 uv 单来源量级 ⇒ 须重估 |
| F | `:1174` | 「**三区块**横排」⇒ 七区块；连带 `WiringSelfCheck.swift:60` 硬断言 `count == 3` 失败、`PageModelBuilderTests.swift:739` 同样断言 3 |
| F | `:1175` | 「七列**三行**完整」⇒ 七列七行（上限）；★ **版面须复核**（一屏放不下 7 行） |
| F | `:1178` | 「**三行**三种徽标」⇒ 七行 |
| F | `:1175` / `:1180` | 分页「第 1 / 3 页」页数随候选量变化 |
| G | `:466-471` | 7 个来源须各自走第一道映射（规则不改） |

★ R2 中**明确不改**的项（同名不同义）：`:8`（单槽而非按来源留档）、`:12`（`uv.cache` vs `uv_cache` 不一致 —— ★ **新增来源必须照 rawValue 写**）、`:39`、`:289-293`（`sourceIndex u8` 仍在 u8 内 ⇒ 二进制兼容）、`:585-589`、`:605-609`（表结构不改、数值重估）、`:827`、`:1065`、`:1321`、`:442`、`:538`。

### 3.17 上游命令白名单：零扩张

**文件**：`ResidueApp/Sources/ResidueCore/UpstreamCommand.swift`

- ✅ `brew --cache` **已在 `entries`**（`:97-98`）⇒ 不加。
- ✅ `brew cleanup` **已在 `explicitlyForbidden`**（`:117`）⇒ 不加。
- ★ **只读命令白名单不扩张** —— 本期新增的探测只有 `brew --cache`（已在），cargo / pnpm / bun 走固定路径。
- ★ **必拒清单须新增**：`pnpm store prune` / `bun pm cache rm` / `cargo cache --autoclean`（真删除命令必拒）。⚠️ 这一条是**新增的封闭集元素**，属契约面扩张 ⇒ 须同步 R2 `:1115`。

### 3.18 空态与错误态

- **§8 空类「无清理候选」**：「仅 `pipx` run 有候选时归此项」→「仅域外只报告来源有候选时归此项」（PRD `:1200` / `:1278`）。
- **AC-14 权限受阻三类**：不变。
- ⚠️ 「多数用户不装 cargo / pnpm / bun」⇒ 每个缺失的 CLI 产生一条「错误」登记而非空态（R2 `:442` 已知缺口放大）—— 本期因走固定路径（零探测）⇒ **不产生探测失败登记**，风险自然消解。

### 3.19 载体段表：尾部追加约束

**文件**：`ResidueApp/Sources/ResidueCore/ResidueStateFile.swift:613-616`

- 新来源**只追加在 `Source.allCases` 末尾** ⇒ 存量载体的 `sourceIndex` 0 / 1 / 2 仍对得上 ⇒ 新 App 读旧载体 **OK**（新来源无段 ⇒ 跳过）。
- **旧 App 读新载体 ⇒ `E-304`**（`sourceIndex` 越界）⇒ fail-closed，接受降级（见 §九 #2）。
- **schema 版本不升**：`StateFileCodec.currentSchemaVersion = 2` 不变 —— 只加来源不改段种类。
- **存量载体首次写回后段数 12 → 28**（`ObservationWriteback.apply` 对每个 `Source.allCases` 都写载荷）⇒ 段表 288 B → 672 B。载体格式自描述 ⇒ 无兼容问题。

### 3.20 不动的地方（外科手术边界）

以下**明确不改**：

1. **PRD 的历史变更清单行**（673 / 679 / 643 / 727 / 750 / 551 / 553 / 213 / 241 / 245 / 263 / 272 / 295 / 370 / 513 / 217）—— 原文一字不动，只在本单重述。
2. **`SemanticSlot` 的封闭枚举** —— case 数 = 7 不变，只改示例文字。
3. **`GateEvaluator`（判定门槛 `K ≥ H` ∧ `a = 0` ∧ `b ≥ 1`）** —— 判据本身不改。
4. **`TrashExecutor`** —— 仍然只做 `moveItem` 到 `~/.Trash`，全文无 `rm` / `unlink`。
5. **CR-034 的未达项逻辑、CR-037 的圆环语义** —— 不动，只被本单的来源数变化波及。
6. **域外行 ③/⑥ 的既有实现偏差** —— 登记不改（2.15 #1）。
7. **观察期计时器仍是全局单实例** —— 不引入任何「按来源计时」的结构。
8. **`L0Probe` / `L0Judge`** —— 判定逻辑不变（pnpm / bun 的整块候选也照常走 L0，只是不参与门槛）。
9. **`ScanProgressAccumulator`** —— 圆环分母已按 `roots.count` 自动缩放，生产代码不改。
10. **`ObservationWriteback` 的快照 / 结算分流** —— 已按 `source.isInDecisionDomain` 分流，生产代码零改动。
11. **`PageModelBuilder.overviewBlocks`** —— 已是 `Source.allCases.map`，自动跟随（① 页七张卡恒在）。
12. **`PageModelBuilder.reportRows`** —— **不自动跟随**，且本单**改过**（§3.8 之外的裁决）：行集合是**条件式**（PRD `:1094`），判据为「判定域来源有快照（`T ≥ 1`）或本窗候选条目数 ≥ 1；域外来源须本窗候选条目数 ≥ 1」⇒ 总量为 0 的来源**不占行**，故 `reportRows.count` 不是恒等于来源数。
    ★ **本条曾表述为「自动跟随」，与 PRD `:1094` 冲突** —— 以 PRD `:1094` 为准，本单据此修正表述（§2.15 同类裁决）。

### 3.21 其他契约基线同步（DAC v2.0 · R2 安全合规检查表 v1.0 · B1 功能用例集 v1.0）

PRD v5.6 与 R2 v1.10 之外，三份契约基线同样含来源集表述，本单一并同步。

> ⚠️ **这三份基线零机器守卫** —— `grep -rn "DAC" tests/contract/*.py tests/contract/*.sh` **零命中**；扩到 `B1` 与安全合规表同样零命中（只命中 `verify10`–`verify18` 里无关的 `B10` / `B11` 字面量）；`tests/contract/verify_counts.py` 的 `WORKFLOWS`（`:35`）**只扫 `.github/workflows/*.yml`** ⇒ 这三份基线的字面量**不被任何校验脚本约束** ⇒ 下列改动**只能靠人工复核**，故逐条列出原文与改后，并登记「扩守卫须另出变更单」（§4.3.1 同类）。

#### 3.21.1 DAC v2.0（3 处）

| 行 | 原文 | 改后 |
|---|---|---|
| `:53`（AC-01 判定） | 「现只有**三张来源卡**，缺「可再生物料清单」「不可再生物料清单」两块」 | 「现只有**七张来源卡**，缺…两块」 |
| `:131`（DAC-40 修订） | 「**三张来源卡（uv cache / npm/_npx / pipx run）是①块内的三行数据，不构成三个区块**——把它当三区块即判不通过」 | 「**来源卡（uv cache / npm/_npx / pipx run / brew downloads / cargo cache / pnpm store / bun cache）是①块内的多行数据，不构成多个区块**——把它们当多个区块即判不通过」 |
| `:263`（DAC-84 判定方式） | 「本机**三类来源**应均为「该来源不适用（无观测通道）」」 | 「本机**七类来源**应均为…」 |

★ **DAC `:131` 的标题部分不改** —— 「含且仅含**三个区块**」「三块**各自非空**」「数区块容器数 = 3」「逐块核内容行数 ≥ 1」全部保持原文 ⇒ **区块数仍是 3**，来源卡只是 ① 块内的行数（辨析见 3.21.4）。

★ **DAC 裁定为历史留痕、不改**：`:23`（DAC-40 修订记录）、`:133`（「为什么改」记 v1.0 当时的事实）、`:391`（v1.0 → v2.0 逐条对照表）—— 记的是 v1.0 当时的事实，改写即伪造历史。
★ **DAC 与来源数无关、不改**：`:250`（DAC-76 四数齐）、`:297`（DAC-103 黑名单命令点名）、`:298`（DAC-104 副标题口径）、`:465`（§74 举例）。

#### 3.21.2 R2 安全合规检查表 v1.0（1 处）

| 行 | 原文 | 改后 |
|---|---|---|
| `:25`（S-01「删除范围越界」） | 「L1 生成候选只限 `uv cache` / `npm/_npx` / `pipx run` 三类来源的候选子树」 | 「L1 生成候选只限**七个来源**的候选子树（判定域四类：`uv cache` / `npm/_npx` / brew downloads / cargo cache；域外只报告三类：`pipx run` / pnpm store / bun cache）；**自动删除只限判定域四类来源的候选**（域外只报告三类恒为「仅报告」，永不进入删除路径）」 |

★ **`:38` 结论汇总未受影响** —— `已覆盖` 9 项 / `需验证` 2 项 / `不适用` 0 项 / 空白 0 项，S-01 结论仍是「**已覆盖**」，不因来源数变化而改。
★ **`:25` 位于 `## 四`（`:56`）之前** ⇒ 不触碰 `verify_r2.py` 的「检查表正文 `## 四` 之前无 `276`」断言（`:167-181`）。
★ **S-01 的判据列未动** —— 「查必究 → AC-07 判定项」与来源数无关。

#### 3.21.3 B1 功能用例集 v1.0（4 处）

| 行 | 原文 | 改后 |
|---|---|---|
| `:21`（FIX-C 夹具） | 「`~/.cache/uv` 保留 **8** 个条目 + `~/.npm/_npx` 保留 **12** 个条目」 | 补：「**并确保 `~/Library/Caches/Homebrew/downloads` 与 `~/.cargo/registry/cache` 下候选总量为 0**」（判定域两来源已入域，不清空则判定域不止 2 个来源）；再补：「**并确保 `~/Library/pnpm/store` 与 `~/.bun/install/cache` 下候选总量为 0**」（两个域外来源候选 ≥ 1 即占行 ⇒ 第 ⑤ 页多行，TC-048 / TC-056 的「三行」断言不成立） |
| `:23`（FIX-EMPTY 夹具） | 「删除 `~/.cache/uv` 与 `~/.npm/_npx` 两个目录（使只读定位成功但无缓存目录）」 | 补：「**并删除 `~/Library/Caches/Homebrew/downloads` 与 `~/.cargo/registry/cache` 两个目录**」——目录仍在即「定位成功且判定域内无候选」⇒ 落 §8 空类②「无清理候选」而非①；PRD `:1278` 空类① 的口径是「无缓存目录」，不是「无候选」 |
| `:104`（TC-0xx 前置） | 「`FIX-EMPTY`（**两个来源目录**均不存在，只读定位仍成功）」 | 「`FIX-EMPTY`（**判定域四个来源目录**均不存在，只读定位仍成功）」 |
| `:500`（TC-048 ② 断言） | 「② ∈ 判定域枚举 ∪ {`pipx run`} 且无空」 | 「② ∈ 判定域枚举 ∪ **域外只报告枚举**〔原写只列域外三类中的一类，与 PRD `:1087` 判定 ②「判定域枚举 ∪ 域外只报告枚举（三类：`pipx run` / pnpm store / bun cache）」不一致〕 且无空」 |

★ **B1「三行」不改（论证）** —— TC-048（`:500`）与 TC-056（`:564`）的「三行」指 `uv.cache` / `npm/_npx` / `pipx run`。行集合为条件式（PRD `:1094`）：域内来源须 `T ≥ 1`、域外来源须候选总量 ≥ 1 ⇒ FIX-C 把 brew / cargo / pnpm / bun 四个来源钉在 0 ⇒ 恰为 3 行 ⇒ 「三行」仍成立。TC-056 的 ⑤ 取值断言（「该来源不适用（无观测通道）」）亦逐字不变。

★ **B1 既有缺口登记（本单不引入、不修）**：`grep -rn "RESIDUE_TEST_SOURCES\|RESIDUE_TEST_COUNTED_DAYS\|RESIDUE_TEST_L2" ResidueApp/Sources/` **零命中** ⇒ B1 的四个注入点（`CLOCK-14` / `CLOCK-9` / `L2-INJ` / `SRC-SUB`）在当前实现里**完全不存在** ⇒ B1 是 Phase 4 走查用例集，注入点尚未实现 ⇒ **既有缺口**，非本单引入。
★ **B1 既有缺口登记（本单扩大，待裁决）**：`FIX-EMPTY` 只钉了判定域四来源，**域外三来源（`~/.local/pipx/venv` / `~/Library/pnpm/store` / `~/.bun/install/cache`）的候选未受约束** ⇒ 走查机上任一存在候选，§8 空类即由①「无可扫描来源」落②「无清理候选」（PRD `:1278` 空类② 明确「仅域外只报告来源有候选时归此项」）。`pipx` 这一项在 CR-038 之前就已存在（`pipx run` 早是域外来源），**本单把该缺口从 1 类扩到 3 类**。彻底修它要重写 FIX-EMPTY 的造数步骤并重估 SM-13 / SM-18 的走查工时（`B1:1286` / `B1:1478`）⇒ **属走查用例集的重新设计，超出本单范围**，登记为已知缺口 + 待裁决项（§九）。
★ **B1 与来源数无关、不改**：`FIX-D` 的 pipx 路径 `~/.local/share/pipx/venvs` 与实现 `SourceRule.defaults`（`ScanEngine.swift`）的 `~/.local/pipx/venv` 不一致 —— **本单未改动 pipx 路径**，属既有出入。
★ **B1 `L2-INJ` 键名** `uv.cache` 与实现 rawValue `uv_cache` 不一致 —— 已在 R2 `:12` 登记 ⇒ **新增来源一律照 rawValue 写**。

#### 3.21.4 三处「三 / 多」的含义辨析（本单最容易踩的坑）

| 出处 | 「三」指的是 | 本单后 |
|---|---|---|
| DAC `:131`「含且仅含**三个区块**」 | **区块** = 各来源占用量 / 可再生物料清单 / 不可再生物料清单 | **仍为 3 块**（不变） |
| DAC `:53`「现只有**三张来源卡**」 | ① 块内的**来源卡行数** | **3 → 7 张** |
| R2 `:1177`「**七区块横排**」 | **来源卡区块**（R2 `:1177` 已由「三区块横排」改来） | **3 → 7 块** |

★ 三个「三」指向三样不同的东西 ⇒ **改前必须逐个确认所指**，否则会把「区块数 = 3」误改成 7（那是改错了对象；DAC `:131` 的标题部分与判定方式「数区块容器数 = 3」必须保持原文）。

#### 3.21.5 与 §2.15 之后「不需要改契约基线」那句的辨析

§2.15 之后那句「契约基线（PRD / R2 / DAC / B1 / 视觉基线）对 brew / cargo / pnpm / bun 的**显示名**零约束 ⇒ 不需要改契约基线」**只针对显示名**（落盘只用 `rawValue`，显示名不参与持久化 ⇒ 改名对存量载体与观察期重置零影响）。
本节 §3.21 改的是**来源数量与来源集合的表述**，与显示名无关 ⇒ 两句**不冲突**：显示名不改，来源数要改。视觉基线（`Residue-视觉基线-v1.1.md`）不含来源枚举表述 ⇒ 本单不动。

---

## 四、影响面

### 4.1 代码引用点

| 文件 | 位置 | 改动 |
|---|---|---|
| `ResidueCore/Metrics.swift` | `:45-114` | `Source` 枚举 +4 case（**尾部追加**）、`isInDecisionDomain`、`displayName`、`candidateGranularity`、`decisionDomainSignature`；新增 `CandidateGranularity`（`:116`） |
| `ResidueCore/ScanEngine.swift` | `:258-280` | `Checkpoint.aggregatedBytes` |
| `ResidueCore/ScanEngine.swift` | `:341` | `SourceRule.defaults` +4 条 |
| `ResidueCore/ScanEngine.swift` | `:534` / `:619-621` / `:670` | 整块 owner 判定、字节累加、整块候选产出 |
| `ResidueCore/ResidueStateFile.swift` | `:241` / `:264-278` | `StateHeader.decisionDomainSignature` |
| `ResidueCore/ResidueStateFile.swift` | `:322` | `resetObservationCredentials(clearingMissCount:)` |
| `ResidueCore/StateFile.swift` | `:362` | 新增 `clearCarrierForObservationReset(...)` 统一入口（`:329` 的 `clearCarrierForVersionChange` 改为转调它） |
| `ResidueCore/ObservationReset.swift` | 新增文件（82 行） | `ObservationResetReason` + `ObservationResetPolicy.reason(...)` —— **「要不要重置」的纯判定下沉 Core**（不变量②） |
| `ResidueCore/SourceRoots.swift` | 新增文件（59 行） | `SourceRoots.resolve(...)` —— **来源根路径解析**（纯计算、零 IO、零进程）下沉 Core（否则放 App 层**测不到**：本仓库只有一个 test target，只依赖 `ResidueCore`） |
| `ResidueCore/UpstreamCommand.swift` | `explicitlyForbidden` | +3 条真删除命令（`pnpm store prune` / `bun pm cache rm` / `cargo cache --autoclean`） |
| `ResidueCore/PageModelBuilder.swift` | `:396-407` | ⑤ 页 `reportRows` 行集合改为**条件式**（PRD `:1094`） |
| `ResidueApp/ScanInfrastructure.swift` | `resolveSourceRoots` | +`brew --cache` 探测；路径计算转调 `SourceRoots.resolve`（App 层只做 IO 编排） |
| `ResidueApp/AppModel.swift` | `applyObservationResetIfNeeded` | 指纹比对分支（版本变更清 `a` / 指纹变更保留 `a`） |
| `ResidueApp/Pages.swift` | ① 页来源卡区 | 文案改「来源占用合计」+ `LazyVGrid(.adaptive)` 自适应网格 |
| `ResidueApp/Components.swift` | 扫描进度环 | 圆环推进（CR-037 同批落地） |
| `ResidueApp/PageRenderer.swift` | `totalSources` | 改用 `Source.allCases.count`（去硬编码） |
| `ResidueApp/WiringSelfCheck.swift` | `:60` | 断言去硬编码 |
| `ResidueApp/DesignSampleData.swift` | — | 示例来源名（7 卡 / 7 行候选 / 7 行报告） |

> ⚠️ 同批落地的 **CR-036 / CR-037** 相关改动（`ScanProgress.swift`、`UnmetSection.swift`、
> `SemanticSlot.swift` 的 `UICopy` 追加）**不属本单**，但同处一个工作区 ⇒
> §十 的统计数字**含这三单的合并效果**，已逐项标注。

### 4.2 测试引用点

| 文件 | 位置 | 改动 |
|---|---|---|
| `Tests/ResidueCoreTests/StateFileSchema2Tests.swift` | `:280` / `:312` / `:363` | `Source.allCases.count == 3` → `== 7` + 文案 |
| `Tests/ResidueCoreTests/PageModelBuilderTests.swift` | `:739` | 断言 3 → `Source.allCases.count` |
| `Tests/ResidueCoreTests/UpstreamAndRecordTests.swift` | — | 3 条真删除命令的拒绝断言 |
| 新增 `Tests/ResidueCoreTests/SourceExpansionTests.swift` | 31 个用例 | 见 §八 |
| 新增 `Tests/ResidueCoreTests/ObservationSignatureTests.swift` | 17 个用例 | 指纹重置路径（版本 / 指纹 / 首启 / `a` 保留） |
| 新增 `Tests/ResidueCoreTests/WholeBlockAggregationTests.swift` | 10 个用例 | 整块聚合、断点续扫、中止不产候选 |
| 新增 `Tests/ResidueCoreTests/ScanProgressTests.swift` | 13 个用例 | **CR-037**，非本单 |

⚠️ 其余 `Source.allCases.count` 断言均为相对式，自动跟随。

### 4.3 声明面数字同步

| 位置 | 现状 | 改为 |
|---|---|---|
| `README.md` | 来源三类 | 七类（判定域四 + 域外三） |
| `README.en.md` | 来源三类（`:13` / `:115` / `:170` 三处） | 七类（判定域四 + 域外三） |
| `ARCHITECTURE.md` | 来源三类 | **无可改内容（已核查）** —— 全文逐行检索无「来源三类 / 三个来源」类表述，原表此项**作废**，见 §10.6 |
| `CLAUDE.md` | 「新增来源 → 改 `Source` 封闭枚举 + `SourceRule.defaults`」 | 补充「**只能尾部追加**」 |
| 根目录 `CLAUDE.md` §七 踩坑 | 无 | 建议补一条「来源枚举插入中间 ⇒ 载体段索引错位」 |

⚠️ **本表原缺「结构性计数字段」一行** —— 实施时只同步了「来源数量」类表述，漏掉
「单测数 / 文档份数 / 变更单份数」。这些数字随本单改动而变，**漏了就是声明面与事实对不上**。补齐如下：

> 「现状」列取 **`git diff` 的 `-` 行**（= 当前 HEAD 的文档内容），不是本单实施中途的中间值。
> CR-036 / CR-037 / CR-038 三张单同处一个工作区、均未提交 ⇒ 文档侧数字从 **472 一步跳到 555**；
> 中间值 481 / 496 只落在 `.github/workflows/` 两个文件上（那两个文件本会话前段已改）。

| 位置 | 现状（HEAD） | 改为 |
|---|---|---|
| `README.md:194` | `472 个单测` | `555 个单测` |
| `ARCHITECTURE.md:34` | `472 个单测` | `555 个单测` |
| `ARCHITECTURE.md:122` | `# 编译 + 472 单测` | `# 编译 + 555 单测` |
| `ARCHITECTURE.md:136` | `472 个单测永远替代不了它` | `555 个单测永远替代不了它` |
| `CLAUDE.md:20` | `# 全部单测（当前 472 个）` | `# 全部单测（当前 555 个）` |
| `CLAUDE.md:11` | `docs/` 下 `140` 份 `.md` | `143` 份 |
| `CLAUDE.md:127` | `docs/` 下 `140` 份 `.md` 分四类 | `143` 份 |
| `ARCHITECTURE.md:87` | `61 份文件 / 23 个单号` | `64 份文件 / 26 个单号` |

> `ARCHITECTURE.md:81` 的「决策材料与交底单等 25 份」= `docs/reviews/` 实测 25 份 ⇒ **不动**。
> `ARCHITECTURE.md:87` 的 61 / 23 是**变更单**口径（`docs/changes/`），与 `:81` 的**评审单**口径不同，两者不可混。

### 4.3.1 声明面数字同步的守卫缺口

`tests/contract/verify_counts.py` 第 35 行 `WORKFLOWS = sorted(glob.glob(".github/workflows/*.yml"))`
⇒ **只扫 workflow**。文档侧声明面（`README.md` / `ARCHITECTURE.md` / `CLAUDE.md`）**无机器守卫**。

这就是本次 8 处数字能同时漂移而无人发现的直接原因。处置：

- 本单**手工补齐**这 8 处（见上表），并在 §10.4 登记该缺口。
- **不擅自扩 `verify_counts.py` 的覆盖面** —— 改校验脚本的覆盖范围属于契约层改动，
  须另出变更单（见 §10.6）。

### 4.4 声明面数字（变更单编号 / 文档份数）

- **实测口径**（`git ls-files docs/` 逐条计数，非记忆值）：
  - 已跟踪 `docs/changes/*.md` = **61 份** ⇒ 本单为**第 62 份**。
  - 已跟踪 `docs/**/*.md` = **140 份** ⇒ 本单计入后 **141 份**。
- ⚠️ 本会话同批另有 **CR-036 / CR-037 两份变更单**尚未提交 ⇒ 连同本单，工作区
  实际为 `docs/changes/` **64 份**、`docs/` **143 份** `.md`。
  上面的 61 / 140 是「**本单之前**」的基线，验收时按工作区实数（64 / 143）核对。

---

## 五、附带订正

本单须逐条重述以下 PRD 历史变更清单内容并挂本单号（**原文不动，仅在此重述**）：

| 原行 | 内容 | 本单重述 |
|---|---|---|
| 673 / 679 | CR-007 计时器不分裂 | 契约仍禁止按来源分裂计时器 ⇒ 新来源随全局观察期一起重置 |
| 643 | CR-006 来源分流 | 分流依据从「上游是否自清」扩为「上游是否自清 **+ 内容寻址/硬链接不可逆性**」 |
| 727 | CR-008 K-7 候选清单标签 | 标签取值域不变，取值映射扩为域内四 / 域外三 |
| 750 | CR-010 建议 G1 L2 无判别力 | 扩为「本期七个来源全部取『该来源不适用（无观测通道）』」 |
| 551 / 553 | CR-011 架构 A11 行集合条件式 | 域外来源占行条件从「`pipx` run」扩为「三个域外来源，各须候选 ≥ 1」 |
| 213 / 241 / 245 | CR-012 架构 A2 / A6 / 引用唯一分组键 | 版本切换 = 全局观察期重启手段；指纹比对 = 兜底检测手段 |
| 263 / 272 / 295 | CR-004 / CR-005 观察期口径 | 不变 |
| 370 | CR-003 影子期 | 新来源进影子期后 14 天方可点亮（AC-04 ②） |
| 513 | CR-001 载体格式 | 段种类不变、来源数变 ⇒ 段数 12 → 28 |
| 217 | CR-007 · R-5 | 同 673 / 679 |

---

## 六、不做的事

1. **不做「按来源分裂观察期」** —— 契约明令禁止（PRD `:1203`）。
2. **不把 pnpm / bun 放进判定域** —— 用户裁决 + 内容寻址不可逆性。
3. **不新增上游只读命令白名单条目** —— `brew --cache` 已在；cargo / pnpm / bun 走固定路径。
4. **不删 `~/.cargo/registry/src`** —— 只删 `cache/`（`src` 是解压后的源码，不是缓存）。
5. **不动 `SemanticSlot` 的 case 数** —— 不变量①。
6. **不改判定门槛判据**（`K ≥ H` ∧ `a = 0` ∧ `b ≥ 1`）。
7. **不改 `TrashExecutor`** —— 仍然只做 rename 到废纸篓。
8. **不升 schema 版本** —— 段种类未变。
9. **不修域外行 ③/⑥ 的既有实现偏差** —— 登记不改（2.15 #1）。
10. **不做第 ⑤ 页七行的一屏放下** —— 版面复核留给实施时；若一屏放不下，须在本单内登记并提后续单，**不在本单擅自改版式契约**。
11. **不处理「增量扫描对新来源近乎失效」**（R2 `:596`）—— 登记为已知缺口，本期以全量扫描为准；新增独立变更单处理。
12. **不 push、不建 PR** —— 除非用户另行要求。

---

## 七、验收判据

| # | 判据 | 验证方式 |
|---|---|---|
| A1 | `Source.allCases.count == 7`，前三个 rawValue 不变 | 单测 |
| A2 | 判定域四类 / 域外三类，两态正确 | 单测 |
| A3 | 七条路径片段互不重叠（任一路径最多命中一个来源） | 单测（对每条片段造样本路径） |
| A4 | 整块来源各产**一条**候选，字节 = 全量累计 | 单测（真 FS） |
| A5 | 断点续扫的整块字节数 == 一次性全量扫描（**幂等**） | 单测（真 FS，中断 → 续扫 → 比对） |
| A6 | 指纹不一致 ⇒ 观察期凭证清零 | 单测 |
| A7 | ★ 指纹路径**保留 `a`**（不清零误判数） | 单测 |
| A8 | 版本 bump 路径**清 `a`**（M4 许可） | 单测 |
| A9 | 存量载体（无指纹字段）解码成功且触发一次重置 | 单测 |
| A10 | 域外来源永不出现在自动删除候选集 | 单测 |
| A11 | 域外来源不取快照（`T` / `K` / `J` 恒 nil） | 单测 |
| A12 | ① 页 `overviewBlocks.count == 7` | 单测 + 接线自检 |
| A13 | ⑤ 页 `reportRows` 行集合**条件式**（PRD `:1094`）：七来源全部有候选或快照时 `count == 7`；任一来源候选总量为 0 且无快照时**不占行**，`count < 7` | 单测 |
| A14 | 界面文案「来源占用合计」不含数字 | grep + 单测 |
| A15 | 真实扫描：七类来源全部被扫到根 | 接线自检 |
| A16 | 契约基线四项校验全绿 | `check_all.sh` / `verify_r2.py` |
| A17 | `swift test` 全绿且用例数增加 | `swift test` |
| A18 | `verify_a9.sh` 全绿 | 脚本 |
| A19 | 16 张设计稿重渲染 | `--render-pages` |
| A20 | `brew --cache` 已在白名单、未新增只读命令 | 单测 + grep |
| A21 | `pnpm store prune` / `bun pm cache rm` / `cargo cache --autoclean` 在必拒清单 | 单测 |

---

## 八、TDD 步骤

> 每步：先写测试 → 跑 → **确认失败原因正确**（不是编译错误、不是断言写错）→ 再改实现 → 跑 → 确认通过。

### 步骤 1 · `Source` 枚举扩展（RED）

新建 `Tests/ResidueCoreTests/SourceExpansionTests.swift`：

- `test_sourceAllCasesCountIsSeven`
- `test_sourceRawValuesOfFirstThreeAreUnchanged`（尾部追加的回归守卫）
- `test_decisionDomainContainsFourSources`
- `test_reportOnlySourcesAreThree`
- `test_candidateGranularityIsWholeBlockOnlyForPnpmAndBun`
- `test_decisionDomainSignatureIsStableAcrossCalls`
- `test_decisionDomainSignatureChangesWhenMembershipChanges`

**验证**：`swift test --filter SourceExpansionTests` 失败，且失败信息是「来源数应为 7，实际 3」之类，**不是**编译错误。

### 步骤 2 · 路径片段（RED）

- `test_sourceRuleMatchesBrewDownloads`
- `test_sourceRuleMatchesCargoRegistryCacheButNotSrc`
- `test_sourceRuleMatchesPnpmStoreWithVersionSubdir`
- `test_sourceRuleMatchesBunCache`
- `test_noPathMatchesMoreThanOneSource`（**互不重叠守卫** —— 遍历七条片段的样本路径，逐个断言命中数 == 1）

**验证**：失败于「未命中」而非编译错误。

### 步骤 3 · 根解析（RED）

- `test_resolveSourceRootsProducesSevenRoots`
- `test_resolveSourceRootsUsesBrewCacheCommandAndAppendsDownloads`
- `test_resolveSourceRootsStripsTrailingSlashFromBrewCacheOutput`（★ 防 `//` 断裂匹配）
- `test_resolveSourceRootsFallsBackWhenBrewMissing`

**验证**：失败于「根数应为 7，实际 3」。

### 步骤 4 · 整块聚合（RED，真文件系统）

- `test_wholeBlockSourceProducesSingleCandidate`
- `test_wholeBlockCandidateBytesEqualSumOfLeaves`
- `test_perEntrySourceStillProducesPerLeafCandidates`
- `test_resumeFromCheckpointYieldsSameAggregatedBytes`（★ 幂等）
- `test_interruptedScanDoesNotEmitWholeBlockCandidate`（★ 不把「扫了一半」说成「就这么多」）

**验证**：失败于「候选数」/「字节数」不符。

### 步骤 5 · 指纹与重置（RED）

- `test_signatureMismatchResetsObservationCredentials`
- `test_signatureMismatchPreservesMissCount`（★ 保留 `a`）
- `test_versionChangeStillClearsMissCount`（★ 版本路径清 `a`）
- `test_legacyCarrierWithoutSignatureDecodesAndTriggersReset`
- `test_signatureMatchLeavesObservationIntact`

**验证**：失败于「计数日 / 误判数」不符。

### 步骤 6 · 页面投影（RED）

- `test_overviewBlocksCountEqualsSourceCount`
- `test_reportRowsCountEqualsSourceCount`
- `test_reportOnlySourcesHaveReportOnlyParticipation`
- `test_totalFootprintIsSumAcrossAllSources`（含整块来源）

**验证**：失败于「块数 / 行数」不符。

### 步骤 7 · 契约基线同步

改 PRD / R2 ⇒ 跑 `./tests/contract/check_all.sh` + `python3 tests/contract/verify_r2.py` ⇒ 两项退出码 0。

### 步骤 8 · 防假绿验证（破坏性变异）

**必做**。逐个引入下列变异，确认**至少有一个测试变红**；全部还原后重跑全绿：

| 变异 | 期望被谁抓住 |
|---|---|
| 把 `cargoRegistryCache` 插到 `uvCache` **之前**（违反尾部追加） | 步骤 1 的 `test_sourceRawValuesOfFirstThreeAreUnchanged` |
| 把 `pnpmStore` 的 `isInDecisionDomain` 改成 `true` | 步骤 1 / 步骤 6 |
| 指纹重置路径改成 `clearingMissCount: true` | 步骤 5 的 `test_signatureMismatchPreservesMissCount` |
| 断点恢复时 `aggregatedBytes` 不从断点取（重新从 0 累加） | 步骤 4 的 `test_resumeFromCheckpointYieldsSameAggregatedBytes` |
| 中止时也产出整块候选 | 步骤 4 的 `test_interruptedScanDoesNotEmitWholeBlockCandidate` |
| `brew --cache` 输出带尾斜杠时不处理 | 步骤 3 的 `test_resolveSourceRootsStripsTrailingSlashFromBrewCacheOutput` |

---

## 九、待裁决

以下九项已在本单内给出拟定结论，**实施前须确认**：

| # | 议题 | 拟定结论 | 依据 |
|---|---|---|---|
| 1 | **L2 观测通道逐源裁决** | 判定域四类 + 域外三类**全部**填「该来源不适用（无观测通道）」 | pnpm / bun 确有 lockfile（PRD `:1084`），但二者为域外来源 ⇒ L2 分母恒 0 ⇒ 仍填「不适用」；**须在 PRD 显式登记**「pnpm / bun 存在 lockfile 观测通道，本期因分母恒 0 不启用；若将来纳入判定域须重新评估」 |
| 2 | **旧 App 读新载体 ⇒ `E-304` 降级不兼容** | **接受降级** —— 旧 App 报 `E-304`，用户下载新版 | 这是唯一 fail-closed 安全行为，符合不变量④；用户主动回滚版本才会触发 |
| 3 | **`pnpm store path` 是否加入只读命令白名单** | **不入白名单** | corepack shim 可能联网下载 pnpm，违反 N6「全部纯本地、不附带网络动作」⇒ 用 `PNPM_HOME` / 默认路径兜底 |
| 4 | **N6 探测预算 / N1 扫描预算重估** | N6：探测命令 2 → 3 条，总预算 ≤ 10 s 仍成立（cargo / pnpm / bun 零探测）；N1：文件量 328 万 → 约 341 万（+3.9%），p95 ≤ 10 min 不变 | PRD `:1218` / `:1213`；本机实测新增 ≈ 129,032 文件〔v1.10 · CR-038 实测校正 2026-11-19：原值 71,820 少算了 pnpm 的 `links/` 半边，见 §10.4 第 10 条〕 |
| 5 | **Homebrew 定位命令选取** | 用 `brew --cache`（已在白名单、PRD N6 原文点名） | 纯本地查询，**不触发 auto-update**（Homebrew 的 auto-update 只在 `install` / `upgrade` / `tap` 等变更类子命令前触发）⇒ T3 结论不变，理由从「举例」升级为「逐命令核实」 |
| 6 | **AC-07 物料归属** | 四个新来源全部归「缓存」类 | Homebrew bottle 归档 / cargo `.crate` 归档 / pnpm store / bun cache 都是缓存物料；「缓存 / 临时 venv / 构建产物」三类分类本身不改 |
| 7 | **PRD `:186` 已知边界放大的严重度重述** | 风险面扩大 1 倍，但**概率未变** | 本机实测两个新判定域来源 `T` 均 ≥ 30（cargo 868 个 `.crate`、Homebrew 193 个 bottle）⇒ `H = min(30,T) = 30` 可达 ⇒ 不会因样本天然不足而拖住轮次；仍须登记「多一个来源 = 多一个慢性缺口拖住全局轮次的可能」 |
| 8 | **域外行 ③/⑥ 实现与 PRD `:1093` 的既有偏差** | **登记不改** | 新增来源沿用既有行为；修偏差须另出变更单 |
| 9 | **★ 指纹重置路径下 `a`（L0 误判累计）保留还是清零** | **保留**（指纹路径）/ **清零**（版本 bump 路径） | 清 `a` 是**宽松方向**（丢掉历史误判证据 ⇒ 更容易点亮 ⇒ 更容易误删）⇒ 指纹路径必须保留 `a`；版本 bump 路径清 `a` 由 PRD `:1293` M4 明确许可。实现形态 = `resetObservationCredentials(clearingMissCount:)` 加一个布尔参数（默认 `true` 保持版本路径行为不变），**不是第三条原语** |

---

## 十、实施记录

> 实施时逐节填写，未实施前留空。

### 10.1 代码改动

**已跟踪文件 19 个**（`git diff --stat -- ResidueApp/Sources ResidueApp/Tests` 实测）
⇒ **982 insertions / 229 deletions**：

| 类别 | 文件 | 改动量 |
|---|---|---|
| Core · 来源定义 | `Metrics.swift` | `Source` +4 case + 4 个派生属性 + `CandidateGranularity` |
| Core · 扫描 | `ScanEngine.swift` | `Checkpoint.aggregatedBytes` + `SourceRule.defaults` +4 + 整块聚合分支 |
| Core · 载体 | `ResidueStateFile.swift` | `decisionDomainSignature` 字段 + `resetObservationCredentials(clearingMissCount:)` |
| Core · 载体 | `StateFile.swift` | 新增 `clearCarrierForObservationReset(...)`（统一入口）；`clearCarrierForVersionChange` 改为转调它 |
| Core · 判定 | `PageModelBuilder.swift` | ⑤ 页 `reportRows` 条件式行集合 |
| Core · 模型 | `PageModel.swift` | 域外来源相关字段 |
| Core · 文案 | `SemanticSlot.swift` | `UICopy` 追加 4 个静态文案（**`SemanticSlot` 枚举 case 数仍为 7** —— 不变量①未破） |
| Core · 命令 | `UpstreamCommand.swift` | `explicitlyForbidden` +3 条真删除命令 |
| App · 编排 | `AppModel.swift` | `applyObservationResetIfNeeded` + `performObservationReset(preservingMissCount:)` |
| App · 编排 | `ScanInfrastructure.swift` | `brew --cache` 探测；`ScanProgress` 迁 Core 后删除本地副本 |
| App · 界面 | `Pages.swift` / `Components.swift` / `RootView.swift` | ① 页 7 卡自适应网格 + 文案改「来源占用合计」；扫描进度环 |
| App · 工具 | `PageRenderer.swift` / `WiringSelfCheck.swift` / `DesignSampleData.swift` | 去硬编码 + 示例数据扩容到 7 来源 |
| 测试（已跟踪） | `StateFileSchema2Tests.swift` / `PageModelBuilderTests.swift` / `UpstreamAndRecordTests.swift` | 断言去硬编码 + 3 条禁删命令断言 |

**契约基线（属本单）** —— 上表 19 个只统计 `ResidueApp/Sources` + `ResidueApp/Tests`，
**不含 `docs/contract/`**；PRD v5.6 的同步改动同样属本单，须单列（否则实施记录不完整）：

| 文件 | 改动量 | 归属 | 说明 |
|---|---|---|---|
| `docs/contract/Residue-PRD-v5.6.md` | 23 行（20 个改动块） | **本单** | 判定域四类 / 域外三类口径落到 AC-04（`:1016` / `:1026`）/ AC-07（`:1045`）/ AC-08（`:1066` / `:1076`）/ AC-09（`:1087` / `:1090` / `:1092` / `:1093` / `:1094`）/ AC-11（`:1177` / `:1200`）/ §N1·N6（`:1213` / `:1218`）/ §八状态（`:1274` / `:1278` / `:1293`）；另 `:136`（`pipx` 行例外 ⇒ 域外只报告行例外）、`:186`、`:842`、`:915` 四处连带订正 |

> **归属核对方法**（不是凭印象）：`git diff -- docs/contract/Residue-PRD-v5.6.md | grep -oE 'CR-0[0-9]{2}' | sort | uniq -c`
> ⇒ 新增行里出现的本批单号**只有 `CR-038`**（其余 `CR-001`…`CR-031` 是原文既有的历史引用），
> **CR-036 / CR-037 未改 PRD** ⇒ 这 46 行改动全部归本单。

**同工作区内、属其他单的已跟踪改动**（三张单同处一个工作区、均未提交 ⇒ 必须逐项标注归属，
否则「36 个已跟踪文件被修改」这个数字会让人误以为是本单一家干的）：

| 文件 | 改动量 | 归属 | 说明 |
|---|---|---|---|
| `ResidueApp/scripts/verify_a9.sh` | 17 行 | **CR-037** | 判据锚点由 `scanProgress.displayText` @ `RootView.swift` ⇒ 改为 `ScanProgressStrip(` @ `Pages.swift` + `progress.displayText` @ `Components.swift` + **新增第三条** `trim(from: 0, to:` @ `Components.swift`（确定弧的证据） |
| `ResidueApp/scripts/verify_a5.sh` | 8 行 | **CR-037** | 同上收窄（a5 判「README 承诺 → 引擎有回调**且**界面有显示」，**不判弧长** ⇒ 与 a9 故意不同） |
| `ResidueApp/design-renders/*.png`（8 张） | 二进制 | **CR-037** | ① 页来源卡改自适应网格 + 圆环 ⇒ 重渲染 |

> 这三项**本单不改**，登记在此只为让 §10.1 的文件清单与 `git diff --stat` 对得上。
> 两个脚本的**项数不变**（a9 仍 80 项 / a5 仍 42 项）—— 只改锚点串，不改 `ok()` / `bad()` 调用次数。

**新增文件 8 个**（未跟踪，§4.1 / §4.2 已列）：

| 文件 | 行数 | 归属 |
|---|---|---|
| `ResidueCore/ObservationReset.swift` | 82 | **本单**（§3.8 重置判定下沉 Core） |
| `ResidueCore/SourceRoots.swift` | 59 | **本单**（来源根解析下沉 Core） |
| `ResidueCore/ScanProgress.swift` | 184 | CR-037 |
| `ResidueCore/UnmetSection.swift` | 34 | CR-036 |
| `Tests/.../SourceExpansionTests.swift` | 31 用例 | **本单** |
| `Tests/.../ObservationSignatureTests.swift` | 17 用例 | **本单** |
| `Tests/.../WholeBlockAggregationTests.swift` | 10 用例 | **本单** |
| `Tests/.../ScanProgressTests.swift` | 13 用例 | CR-037 |

**声明面**（`git diff -U0` 实测改动块）：
- `README.md` **7 处** —— `:13` / `:118` / `:120` / `:130` / `:174` 来源七类表述 + `:194` 单测数
- `README.en.md` **4 处** —— `:13` / `:115` / `:117` / `:170` 来源七类表述
- `ARCHITECTURE.md` **4 处** —— `:34` / `:122` / `:136` 单测数 + `:87` 变更单份数 / 单号
  （§4.3 原表写「无可改内容」指的是**「来源三类」表述**，不是整份文件；结构性计数字段仍需改）
- `CLAUDE.md` **5 处** —— `:11` / `:20` / `:127` 结构性计数 + `:140` §五 尾部追加约束 + `:164` §七 第 9 条踩坑
- `.github/workflows/ci.yml:5` + `release.yml:211` —— 单测数 496 → 555

⇒ 合计 **22 个改动块**（文档侧 20 + workflow 侧 2），对应 22 行替换。

### 10.2 测试改动

| 文件 | 用例数 | 说明 |
|---|---|---|
| 新增 `SourceExpansionTests.swift` | 31 | 7 条 `SourceRule.defaults` 路径片段两两互不包含；`SourceRoots` 尾斜杠 / brew downloads / 探测失败回退 / 固定路径；域外来源不占行；`displayName` 长度上界（⑤ 页来源列宽约束） |
| 新增 `ObservationSignatureTests.swift` | 17 | 首启 / 同版本 / 版本变更 / 指纹变更四态；版本变更清 `a`、指纹变更**保留 `a`**；旧载体缺指纹键 ⇒ 判变更 |
| 新增 `WholeBlockAggregationTests.swift` | 10 | 整块聚合、断点续扫字节一致、断点不重复计数、中止**不产整块候选** |
| 新增 `ScanProgressTests.swift` | 13 | **CR-037**，非本单 |
| 改 `StateFileSchema2Tests.swift` | — | `Source.allCases.count` 3 → 7 |
| 改 `PageModelBuilderTests.swift` | — | 断言 3 → `Source.allCases.count` |
| 改 `UpstreamAndRecordTests.swift` | — | `pnpm store prune` / `bun pm cache rm` / `cargo cache --autoclean` 拒绝断言 |

**单测总数**：472（HEAD 基线）→ **555**（`swift test` 实测，0 failures）⇒ 已同步 `.github/workflows/ci.yml:5` 与
`release.yml:211`；**文档侧 8 处结构性计数**同步见 §4.3 补表 ⇒ `python3 tests/contract/verify_counts.py` 复跑 ⇒
**一致 9 项 / 不一致 0 项**。

### 10.3 校验实跑结果

| 校验 | 期望 | 实跑 |
|---|---|---|
| `./tests/contract/check_all.sh` | exit 0 | ✅ exit 0 —— 结构落点 191 + 声明归零 9 + 单一定义 + CR-022 47 |
| `python3 tests/contract/verify_r2.py` | exit 0 | ✅ exit 0 —— 结构 30 + 落地 65 + 归零 16 + 一致 10 + 自洽 2（**123 项**） |
| `python3 scripts/verify_codes.py` | exit 0 | ✅ exit 0 —— **11 项 / 0 失败** |
| `./scripts/verify_a9.sh` | exit 0 | ✅ exit 0 —— **80 项 / 0 失败** |
| `swift test` | 0 failures | ✅ **555 tests / 0 failures**（2026-11-20 提交前复跑 2.17 s） |
| `swift build -c release` | 成功 | ✅ `ok (build complete)` |
| `swift run --disable-sandbox ResidueApp --verify-wiring /tmp/wiring` | exit 0 | ✅ **111 项 / 0 失败** |
| `swift run --disable-sandbox ResidueApp --render-pages design-renders` | 16 张 | ✅ **共渲染 16 张**（2000×1280） |
| `./scripts/make_app.sh` + `./scripts/verify_a5.sh` | exit 0 | ✅ 打包成功（SHA-256 `e4aea274…653e6`〔v1.10 · 2026-11-20 提交前复跑重出；ad-hoc 签名每次重打 SHA 必变，产物结构与 a5 判定不受影响〕）+ **42 项 / 0 失败 / 3 项未覆盖** |
| `python3 tests/contract/verify_counts.py`（额外自查） | 一致 | ✅ **一致 9 / 不一致 0 / 未覆盖 4** |

> ⚠️ `verify_a5.sh` 的 3 项「未覆盖」**如实登记，不算通过**：本机无 Developer ID 身份 ⇒ 无法公证 / 钉票 /
> `spctl` 评估；完全磁盘访问权限需 GUI 人工确认。⇒ 属 A-10 发布准入项。

### 10.4 偏差登记

| # | 偏差 | 处置 |
|---|---|---|
| 1 | 域外行 ③/⑥ 实现与 PRD `:1093` 的既有偏差 | **登记不改**（§2.15 #1）—— 新来源沿用既有行为，修偏差须另出变更单 |
| 2 | 「新入域来源」行的 ③/⑦ 口径（PRD `:1094` 要求「本轮无快照 · 扫描时点值 · 非结算值」）**本单未实现** | **登记不改**（§2.15 #4）—— 本单新增来源随版本走，不触发「新入域」路径 |
| 3 | 增量扫描对新来源近乎失效（R2 `:596`） | **登记不改**（§10.6） |
| 4 | `ARCHITECTURE.md` §4.3 原列「来源三类 → 七类」 | **原表项作废** —— 已核查全文无「来源三类」表述，无可改内容（§10.6） |
| 5 | **声明面结构性计数漂移 8 处**（单测数 / 文档份数 / 变更单份数与单号）—— CR-038 §4.3 原表只列「来源数量」类表述，漏了结构性计数字段 | **已修** —— 按 §4.3 补表逐处改（`README.md:194` / `ARCHITECTURE.md:34`/`:87`/`:122`/`:136` / `CLAUDE.md:11`/`:20`/`:127`），逐条 `git diff` 核对 |
| 6 | **`verify_counts.py` 覆盖面盲区** —— 第 35 行 `WORKFLOWS = sorted(glob.glob(".github/workflows/*.yml"))` ⇒ 只扫 workflow，文档侧声明面（`README.md` / `ARCHITECTURE.md` / `CLAUDE.md`）**无机器守卫** | **登记不改** —— 这正是第 5 条能溜过去的原因，但扩校验脚本覆盖面属契约层改动，须另出变更单（见 §10.6） |
| 7 | **⑤ 页缺 `L2 误判数` 列、多 `观察期` 列**（PRD `:1092` ⑤ 要求「`L2 误判数` ∈ {数值} ∪ {「该来源不适用（无观测通道）」}」，实现侧 `ReportMatrix.columns` 的第 ⑤ 列是「观察期」） | **登记不改**（§2.15 #5 · 台账 M-5 已裁「**换列是产品决定**」）—— 本单只随来源扩容行集合，不动列结构；换列须另出变更单 |
| 8 | **R2 §7.2 合计行不自洽** —— 表内逐行相加 122.5 s，合计行却写 ≈ 118 s（偏差 ≈ 3.8%） | **已修** —— 合计改 ≈ **123 s**、p95 余量改 ≈ **4.9×**（600 ÷ 123）、§13 V8 改「约 342 万规模假设」；另补修 §14 `:816` 残留的「118 s」。★ 详见 §10.7 第 1 项（本单自身「E 类要求重估」与「明确不改清单」矛盾 → 裁决：**表格 E 行优先**） |
| 9 | **B1 夹具未约束域外三来源（`pipx` / pnpm / bun）的候选总量** ⇒ `FIX-EMPTY` 的预期结果 §8 空类①「无可扫描来源」在装了 pnpm / bun 的走查机上仍可能落②「无清理候选」 | **登记不改**（§3.21.3）—— pipx 这一项在 CR-038 之前就已存在，**本单把缺口从 1 类扩到 3 类**；彻底修要重写 FIX-EMPTY 造数步骤并重估 SM-13 / SM-18 走查工时 ⇒ 属走查用例集重新设计，超出本单范围 |
| 10 | **★ 本机实测 pnpm 文件数少算一半** —— 原 §1.1 表记 pnpm `60,438` 个文件、四类合计 `71,820`；2026-11-19 复测 `store/v11/files/` = 60,438、`store/v11/links/` = 57,017 ⇒ **真实 117,457**；且原「四类合计 71,820」= 868 + 60,438 + 10,514，**本身也漏加了 Homebrew 的 193** | **已修** —— §1.1 表 pnpm 文件数改 **117,457**、合计句改 **≈ 129,032**；PRD `:1213` 同步改「新增 ≈ 129,032 文件 ⇒ 全量约 **341 万**（+3.9%）」；§3.14 `:523` 与 §九 #4 同步。★ **体积未变**（2.8 G / 合计 ≈ 5.7 G 均复测一致）⇒ **N1「p95 ≤ 10 min」结论不变**；R2 §7.2 的 342 万是 `readdir` **条目**口径（含目录），与 PRD 的 341 万**文件**口径不冲突，已在 R2 `:585` 加口径说明 |

### 10.5 防假绿验证

**6 个破坏性变异，逐个实跑确认「至少一个测试变红」，每个变异的红因均已定位到具体断言，
且变异全部还原。还原后全量 `swift test` ⇒ 555 tests / 0 failures。**

| # | 变异 | 实测红因 | 状态 |
|---|---|---|---|
| ① | `Source` 枚举把 `cargoRegistryCache` 插到 `uvCache` **之前** | `test_sourceRawValuesOfFirstThreeAreUnchanged` 红（存量 `rawValue` 不得变）+ `test_reportOnlySourceNeverOccupiesRowBySnapshotAlone` 红 | ✅ 已还原 |
| ② | `pnpmStore` 的 `isInDecisionDomain` 改 `true` | 5 个测试红（含 `test_decisionDomainContainsFourSources`） | ✅ 已还原 |
| ③ | 指纹重置路径改成 `clearingMissCount: true` | 5 个测试红；红因是**载体一致性校验**：`StateFileError.segmentValidationFailed(detail: "来源 uv cache 的 F 段长 1 B ≠ ceil(slotCount 0/8) = 0 B")` —— 真红，非文件系统错误冒充 | ✅ 已还原 |
| ④ | 断点恢复时 `aggregatedBytes` **不从断点取**（`ScanEngine.swift:542`） | `WholeBlockAggregationTests` 3 个断言红：`Optional(350) != Optional(357)`（差 7 = 根下那个 7 字节叶子，正是断点里已累计未带上的部分）；另含 `testResumeFromCheckpointYieldsSameAggregatedBytes`、`testResumeDoesNotDoubleCountAggregatedBytes` | ✅ 已还原 |
| ⑤ | 扫描中止时也产出整块候选（`ScanEngine.swift:653`） | `testInterruptedScanDoesNotEmitWholeBlockCandidate` 红：`XCTAssertTrue failed - 中止时不得产出整块候选（会把「扫了一半」说成「就这么多」）`（10 tests / 1 failure） | ✅ 已还原 |
| ⑥ | `brew --cache` 输出带尾斜杠时**不处理**（`SourceRoots.swift:54-56`） | `test_sourceRootsStripsTrailingSlashFromBrewCacheDir` 红：`Optional("/Users/x/Library/Caches/Homebrew//downloads") != Optional("/Users/x/Library/Caches/Homebrew/downloads")`（31 tests / 1 failure） | ✅ 已还原 |

**还原确认**：`grep -c "变异" Sources/ResidueCore/{ScanEngine,SourceRoots}.swift` ⇒ **0**（无残留标记）；
临时排障文件 `TmpDebugTests.swift` 已删除（`git status` 不再出现）。

### 10.6 已知既有漂移

- 域外行 ③/⑥ 实现与 PRD `:1093` 不一致（§2.15 #1）—— 本单不改。
- 增量扫描对新来源近乎失效（R2 `:596`）—— 本单不改，已登记。
- 「多数用户不装 cargo / pnpm / bun」⇒ 固定路径探测下不产生错误登记，风险自然消解。
- **`ARCHITECTURE.md` 无「来源三类」表述** ⇒ §4.3 原表该项**无可改内容**（已逐行正则核查），
  该行改为如实登记，不硬凑改动。
  ⚠️ 但这**只针对「来源数量」类表述** —— 该文件仍有 4 处**结构性计数**需改（`:34` / `:87` / `:122` / `:136`），
  见 §4.3 补表。
- **`verify_counts.py` 只扫 `.github/workflows/*.yml`** ⇒ 文档侧声明面无机器守卫。
  本单**手工补齐** 8 处（§10.4 第 5 条），但缺口本身**登记不改**：
  扩校验脚本覆盖面会让 README / ARCHITECTURE / CLAUDE 的措辞成为 CI 失败条件，
  属契约层改动，须另出变更单（**不在本单顺手扩**）。
- **`verify_r2.py` 已复跑通过** —— R2 v1.10 的 27 处同步落盘后复跑 ⇒ ✅ exit 0（结构 30 + 落地 65 +
  归零 16 + 一致 10 + 自洽 2 = **123 项**），已回填 §10.3。★ 同步执行方回报的 **13 项冲突 / 歧义**
  逐条登记见 §10.7。
- **§10.1 / §10.2 的统计数字含同批 CR-036 / CR-037 的合并效果**（同处一个工作区、未提交）⇒
  已逐文件标注归属；`ObservationSignatureTests` / `SourceExpansionTests` / `WholeBlockAggregationTests`
  属本单，`ScanProgressTests` 属 CR-037。
- **`swift test` 输出里的 SourceKit 噪音**：`ScanEngine.swift:524` `Variable 'unknownCount' was never mutated;
  consider changing to 'let' constant` —— **既有噪音**，非本单引入，按外科手术式改动原则**不擅自改动**。

### 10.7 R2 同步执行方回报的 13 项冲突 / 歧义（逐条登记）

R2 v1.10 的 27 处同步由后台执行方落地。执行方**未自行发挥**，把遇到的 13 项冲突 / 歧义回报本单裁决。
本节逐条登记处置结果（★ = 需要人确认的项）。

| # | 执行方回报 | 本单处置 |
|---|---|---|
| 1 | ★ **CR 自相矛盾**：§3.16 的 E 类要求重估 `:583-589`，而 CR 尾「明确不改」清单里**也**含 `:585-589` ⇒ 执行方按「不改」优先，把 4 行回退到原文，于是**表内逐行相加 ≈ 122.5 s，合计行仍写 ≈ 118 s**（偏差 ≈ 3.8%） | **已裁决：表格 E 行优先** —— 合计改 ≈ **123 s**、p95 余量改 ≈ **4.9×**、§13 V8 改「约 342 万规模假设」，并补修 §14 `:816` 的「118 s」残留（§10.4 第 8 条）。★ 如实记录处置链：执行方回退 → 主 agent 依裁决重做 |
| 2 | §7.2 标题（原 `:579`）**不在表内**，原写 `V8 = 328 万`，与表内新值矛盾 ⇒ 执行方改为「`V8 ≈ 342 万`」并加标记，自认**属扩范围** | **采纳** —— 标题与表内数值同指一个量，不一致即自相矛盾；扩范围落在 §3.16 E 类授权内 |
| 3 | `:111` **双重身份**：B 类授权「补一句」，D 类又把它列入「明确不改」 | **采纳 B 类** —— D 类的「不改」指**规则本身**不改，追加说明不改规则 |
| 4 | `:605-609` **冲突**：既在 C 类（数值重估）又在不改清单（表结构不改） ⇒ 表结构未动，数值口径改到 `:789` 登记，`336 MB` / `112 B` / 「约 640 MB 量级」全部保留 | **采纳** —— 这三个字面量是 `verify_r2.py` 的**断言源**，动它们等于让校验跟着文档走 |
| 5 | `:331` / `:332` 与实机测试冲突：`StateFileTests.swift` 依赖 `1536 B` 存量算例 | **采纳** —— 存量算例是**存量兼容性的唯一证据**，新增算例另加，不删旧例 |
| 6 | `:136`「探测次数 1 → 4」**含糊** | **已落为「定位手段 1 → 4 类、探测命令 2 → 3」** —— 两者不是同一个量（手段分类 ≠ 命令条数） |
| 7 | `:598`「总量 ×3」**含糊** | **已落为「候选总量重估（30 万 → 约 30.1 万）」** —— 给出可核的绝对值，不写倍数 |
| 8 | `:596` 要求「单列增量策略」与 CR §六 #11「登记为已知缺口」**冲突** | **只登记，未写策略** —— 与 §10.4 第 3 条一致；策略属另开变更单 |
| 9 | ★ `:713` 与代码冲突：CR 说「有头部条目、无段」触发 `E-304`，但 `ResidueStateFile.swift:943` **跳过**缺失载荷、CR §3.19 又说新 App 读旧载体 OK ⇒ 执行方按后者写并标 ★ 待裁决 | **待裁决（本单未决）** —— ★ 本项与 §九 #2 **语义不同**：§九 #2 裁的是「旧 App 读新载体 ⇒ `E-304` 降级不兼容」（接受降级）；本项裁的是「**有头部条目、无段**是否一律 `E-304`」。本单不自行收紧（收紧 = 把 fail-closed 范围扩大），须另出变更单。★ 该 ★ 标记**已落在契约基线里** —— R2 迁移矩阵行（现 `:716`）已写明「**待裁决**：若将来把『有头部条目、无段』收紧为一律 `E-304`，则 ① 由『跳过』改为『拒绝加载』，本行须同步改写」⇒ 裁决不会漏 |
| 10 | `:12` 不改清单 vs「新增来源照 rawValue 写」 ⇒ JSON 首项保留 `uv.cache`，其余 6 项用 rawValue ⇒ **同一示例内两种写法** | **登记不改**（R2 `:12` 已自行登记为偏差）—— 统一写法要动示例语义，留给下一轮清理 |
| 11 | **缺实测样本**、**未编数字**：`:611`、`:789`、`:1053`、`:1175` / `:1180`、`:583-589` 的基线 328 万本身 | **登记不改** —— 宁可留空，**不填推测值**；唯一裁判是 AC-20 实测用例 |
| 12 | **行号漂移**（R2 +3 行）：CR-033 `:282`「R2 :692」/ `:313`「R2 :1394」；CR-038 `:574`「R2 `:1115`」/ `:580`「R2 `:442`」/ `:738`,`:985`,`:1010`「R2 `:596`」；CR-034 `:305`「R2 :458」 | **登记不改** —— 历史变更单是**当时决策的记录**，不随 R2 行号漂移改写（与 `docs/` 目录迁移同理） |
| 13 | `:791` **锚点含义**：R2 该处是「`sourceRootReadable`」上下文，执行方按此理解改写 | **已澄清** —— R2 `:791` → `:794` 落为「新增来源必须全部进入 `sourceRootReadable` 探测集合（`brew_downloads` / `cargo_registry_cache` / `pnpm_store` / `bun_cache` 逐个探测）：**未被探测 ≠ 不可读**」，与 §3.16 B 类意图一致 |

★ **本节不新增 §九 条目**：第 1 / 4 / 5 / 6 / 7 项已在本单内裁决并落盘；第 9 项**需要人裁决但不在本单裁决范围** ⇒
按仓库惯例登记在 §十 实施记录内（此处），**并在本单收尾时以「待裁决」名义提请复核**；第 2 / 3 / 8 / 10 / 11 / 12 / 13 项
不需裁决（采纳执行方处置或登记不改）。
