# CR-032 · Homebrew 与 pip 来源接入（评估 → 实施）

> **性质**：**评估单 + 实施记录**。§一–§十一 是评估与裁决（2026-11-14 上午）；§十二–§十四 是用户裁决后的实施记录（同日）。
> **状态**：**已实施**（D1–D5 经用户裁决：D1 Homebrew 入域 / D2 pip 仅报告 / D3 仅 bottle / D4 三种 pip 定位形态 / D5 ① 页 3 + 2、浮层 444 pt）。**未提交、未推送**——等待明确指令。
> **实测日期**：2026-11-14。**实测机器**：当前开发机（arm64，macOS 14+）。
> **基线**：PRD v5.5 / R2 v1.8 / 视觉基线 v1.1 + CR-031 / DAC v2.0 / B1 v1.0；实施后：**PRD v5.6 / R2 v1.9 / DAC v2.1**，视觉增补见本单 §十三（**不另立视觉基线文档版本**，沿用 CR-031 的做法）。
> **单号说明**：CR-031 已被视觉基线 v2 占用，本单为 CR-032。

---

## 一、一句话结论

**可以做，但不要「直接往 `Source` 枚举里加两个 case」就完事。**

Homebrew 与 pip 都能满足本产品的核心前提（**只读扫描 → 只清可再生物料 → 原子 rename 到废纸篓**），但当前代码里有 **3 个前置缺陷**会在来源数从 3 变成 5 时被放大，其中两个会直接导致「门槛永远点不亮」或「新来源继承旧观察期」。**这 3 个缺陷必须先修，且必须单独有测试**，否则新增来源只是把问题藏得更深。

推荐落地方式：

| 来源 | 是否进判定域（可自动删除） | 扫描范围 | 理由 |
|---|---|---|---|
| **Homebrew** | **是** | `<brew --cache>/downloads/` 下的 **bottle 文件** | 体量最大（本机 7.25 GiB）、删除单位清楚、瓶子由 Homebrew 自己的 CDN 托管、可重下 |
| **pip** | **先否（仅报告）** | `<pip cache dir>/` 的 `http-v2` / `http` / `wheels` 三个已知子目录 | 体量小、布局是 pip 内部实现、淘汰相对频繁；先观察一轮再单独裁决是否升域 |

**另一个必须先说清的事实**：当前代码里 **`K` 与「结算报告产出」没有写入点**（见 §六·P0-4）。也就是说，即使今天加上这两个来源，产品也**不会因此获得删除能力** —— 门槛本来就点不亮。CR-032 落地后的短期效果是「**看得见、统得准、能举证**」，不是「多删两个来源」。这不是本单引入的问题，但会影响优先级判断。

---

## 二、本机实测（2026-11-14）

### 2.1 定位命令与真实路径

```text
$ brew --cache
/Users/apple/Library/Caches/Homebrew

$ pip cache dir
/Users/apple/Library/Caches/pip

$ HOMEBREW_CACHE=/tmp/xxx brew --cache
/tmp/xxx                      # 尊重环境变量，且不创建目录（已实测）

$ PIP_CACHE_DIR=/tmp/xxx pip cache dir
/private/tmp/xxx              # 尊重环境变量，且不创建目录（已实测）
```

**两条都被实测证明**：

1. `brew --cache` / `pip cache dir` **会尊重环境变量覆盖**；
2. 两者都**不创建目录**，可以进上游只读白名单（AC-19 要求「不产生任何写 / 删动作」）；
3. 因此 **硬编码 `~/Library/Caches/Homebrew` / `~/Library/Caches/pip` 是错的**，必须用命令定位 + 回退。

### 2.2 体量与文件数

| 根 | 子项 | 文件数 | 体量 | 说明 |
|---|---|---:|---:|---|
| `~/Library/Caches/Homebrew` | `downloads/` | **261** | **7.25 GiB** | 瓶子、瓶子清单、cask 包、源包 |
| | `bootsnap/` | 3,386 | 39.9 MiB | Homebrew 自带 Ruby 的启动缓存，**不是下载缓存** |
| | `api/` | 17 | 30.5 MiB | formula API 元数据，删了 brew 要联网重取 |
| | `tool-selection/` | 2 | 8 KiB | brew 内部状态 |
| | `Cask/` | 0 | 0 | 本机为空 |
| `~/Library/Caches/pip` | `http-v2/` | 32 | 4.9 MiB | 16 组「元数据 + `.body`」 |
| | `http/` | 2 | 2.0 MiB | 旧版 HTTP 缓存 |
| | `selfcheck/` | 1 | 4 KiB | pip 自检时间戳，**不是缓存** |
| | `wheels/` | 0 | 0 | 本机无预构建 wheel |

`downloads/` 的文件名分布（本机实测）：

| 文件名形态 | 数量 | 例子 |
|---|---:|---|
| `*.bottle.tar.gz` / `*.bottle.N.tar.gz` | **113** | `0b6f…--highway-1.4.0.arm64_sequoia.bottle.tar.gz` |
| `*.bottle_manifest.json` | 113 | `0a12…--highway-1.4.0.bottle_manifest.json` |
| 其他（cask / 源包） | 35 | `…--Meslo.tar.xz` |

### 2.3 扫描成本

| 命令 | 耗时 | 结论 |
|---|---:|---|
| `brew --cache` | 0.01 s | 可忽略 |
| `pip cache dir` | 0.68 s | 可接受（asdf shim + Python 启动） |

按推荐范围扫描，新增叶子数约 **113（brew）+ 34（pip）**，相对现有 22 万级扫描量可忽略。**但上游命令从 2 条变成 4 条**，见 §六·P1-2 的总预算问题。

### 2.4 白名单现状

`brew --cache` **已经在白名单里**（`UpstreamCommand.swift:97`），但当前未被调用。
`pip cache dir` **不在白名单**（`UpstreamCommand.swift:90-103`），接入 pip 必须新开白名单条目 —— 这是 AC-19 封闭集合的契约变更，不能当实现细节处理。

---

## 三、为什么这两个来源符合产品前提

### 3.1 删除单位是「下载文件」，不是「软件包」

- Homebrew：删除 `downloads/` 里的一个瓶子文件，**不会卸载任何已安装的 formula**；下次 `brew install` / `reinstall` / 降级需要时重新下载。
- pip：删除 `http-v2` 里的一组缓存文件，**不会卸载任何已安装的 Python 包**；下次安装时重新下载或重建 wheel。

这与 `uv` / `npm/_npx` 的语义一致：**清理的是「下载缓存」，不是「环境」**。

### 3.2 两者都能「再生成」

- bottle 由 Homebrew 自己的 GHCR CDN 托管，已发布版本可重下；
- pip 的 HTTP 缓存和 wheel 缓存都是「命中则省流量、未命中则重算」，删除只会变慢，不会让环境失效。

### 3.3 但两者各有一个「不能照搬」的地方

| 来源 | 不能照搬的地方 | 处置 |
|---|---|---|
| Homebrew | `brew --cache` 根目录**不等于下载缓存**：`bootsnap/`、`api/`、`tool-selection/` 都不是下载物 | **只扫 `downloads/`，且只把 bottle 当候选** |
| pip | 缓存布局是 pip 内部实现（`http` → `http-v2`，未来可能 `http-v3`） | **只扫已知子目录；布局不认识时不显示 0，按「无法判定」呈现** |

---

## 四、来源建模（建议值）

### 4.1 枚举与展示

| 项 | Homebrew | pip |
|---|---|---|
| `Source` case | `brewCache` | `pipCache` |
| `rawValue` | `"brew_cache"` | `"pip_cache"` |
| 展示名 | `Homebrew`（**实施时由 `Homebrew cache` 缩短**：① 页来源列约 83 pt、浮层列宽 72 pt，11 pt 下 `Homebrew cache` 必截成 `Homebrew…`） | `pip cache` |
| 规范路径（展示用） | `~/Library/Caches/Homebrew/downloads` | `~/Library/Caches/pip` |
| 定位命令 | `brew --cache`（已在白名单） | `pip cache dir`（**需新增白名单**） |
| 回退路径 | `~/Library/Caches/Homebrew/downloads` | `~/Library/Caches/pip` |
| 判定域 | **是** | **否（先仅报告）** |
| 候选单位 | 单个 `*.bottle*.tar.gz` | 单个缓存叶子（元数据 + `.body`） |
| 识别色（建议） | `0xB37A4E`（暖棕） | `0x5FB3C9`（青） |

> **枚举顺序必须追加在末尾**：`uvCache, npmNpx, pipxRun, brewCache, pipCache`。原因见 §六·P1-1（状态文件段序与 `sourceIndex`）。

### 4.2 扫描范围：为什么不是整个 `brew --cache`

整根扫描会把 `bootsnap/`（3,386 个文件）和 `api/`（30.5 MiB 元数据）算成「可清理候选」。后果不是崩溃，而是**产品叙事失真**：

- `bootsnap/` 删了会让每次 `brew` 命令变慢直到重建 —— 它是**加速缓存**，不是**下载缓存**；
- `api/` 删了会让 `brew` 下次必须联网取元数据，离线场景直接不可用；
- 两者都**不该出现在「可回收字节」里**，否则用户会问「为什么清完 brew 变慢了」。

因此推荐：

```text
brew 扫描根 = <brew --cache>/downloads
brew 候选文件 = 文件名包含 ".bottle" 且以 ".tar.gz" 结尾
```

113 个瓶子，H = min(30, 113) = 30，样本门槛充裕。

**cask 包（`.dmg` / `.pkg` / `.tar.xz`）本单不纳入**：它们的下载 URL 由第三方厂商托管，版本被下架后**无法重下**，与「可再生物料」的前提不完全一致。是否纳入，见 D3。

### 4.3 pip 的扫描范围与「布局不认识」处置

推荐扫描根拆成多个：

```text
<pip cache dir>/http-v2     （存在才扫）
<pip cache dir>/http        （存在才扫）
<pip cache dir>/wheels      （存在才扫）
```

这样不需要文件名过滤，也不会误收 `selfcheck/`。

**风险**：若未来 pip 改用 `http-v3`，三个已知子目录可能都不存在 → 产品显示 `0 B`。这违反「不把未知判为安全」（看不见的东西不能显示 0）。处置建议：`pip cache dir` 成功但三个子目录一个都不存在时，该来源显示 `.unavailable(reason: "缓存布局未识别（pip 版本可能已变更）")`，而不是 `0 B`。这需要新增一条 `UICopy` 文案，`verify_a9.sh` 第四节的文案核对要同步。

### 4.4 状态载体

- 每个来源仍是一份独立的 `F / C_done / 位槽占用表 / a`（现有 `SourcePayload` 按来源分三段，自动扩展）；
- `StateHeader.sources` 数组追加两项，顺序 = 声明序；
- **`schemaVersion` 从 1 升到 2**。目的不是格式不兼容，而是让**旧版本读新文件时走 `E-301` 只读降级**（`ResidueStateFile.swift:442`），而不是 JSON 解码失败后把 `state.residue` 改名成 `.corrupt`（那会丢状态）。新版本读旧文件仍可正常解码（1 < 2）。
- **实现注意**：`ResidueStateFile.swift:385` 写二进制头时用的是 `currentSchemaVersion` 常量，而不是 `header.schemaVersion`。升级后从旧文件加载再保存，会出现「二进制头 = 2、头部 JSON 里的 schemaVersion 仍 = 1」的不一致。保存前应把 `header.schemaVersion` 归一化为当前版本。

---

## 五、判定域：Homebrew 进、pip 先不进

契约原文（PRD v5.5）：

- 判定域 = **本轮观察期开始快照内命中的来源**，且 `T ≥ 1`（`Residue-PRD-v5.5.md:1173`）；
- `T = 0` 的来源不进判定域、**第 ⑤ 页不占行**（同上）；
- 新增来源须另出变更单，封闭枚举不得留「等」（`Residue-PRD-v5.5.md:989`）。

判定域成员要同时满足 `K ≥ H`、`a = 0`、`b ≥ 1`。这决定了「候选会不会被外部清掉」很重要：

| 来源 | 本机 T | H | 「外部清掉多少会卡住本轮」 |
|---|---:|---:|---|
| Homebrew bottle | 113 | 30 | 超过 83 个瓶子消失（`brew cleanup -s` 会） |
| pip 缓存文件 | 32 | 30 | **消失 3 个就卡住** |
| uv（对照） | 11.5 万 | 30 | 几乎不可能 |
| npm（对照） | 10.7 万 | 30 | 几乎不可能 |

pip 的 `H = 30` 与 `T = 32` 只差 2，一次 `pip cache purge`、一次 pip 升级清理、一次手工清理，都会让 `K < H` → **本轮判定域里任何一个来源都不能点亮**。而 pip 的清理收益（本机 6.9 MiB）远小于这个风险。

所以推荐：

- **Homebrew 进判定域**：体量大、瓶子来源稳定、T 大所以抗流失；
- **pip 先仅报告**：只进扫描 / ② 候选清单（标「仅报告」）/ ⑤ 报告行 / 举证链，不参与门槛、不参与自动删除。观察一轮后，如果实际流失率低，再单独出变更单升域。

> 这不是「不做 pip」，而是**先把它接进来、看清它，再决定要不要让它参与删除** —— 与产品「14 天影子观察」的哲学一致。

---

## 六、必须先修的前置缺陷

以下 4 项都不是 CR-032 发明的，但来源数从 3 变 5 会让它们从「潜在」变成「必现」。**建议作为 CR-032 的第一阶段（P0），先修、先测，再动来源枚举。**

### P0-1 · 判定域没有接线，来源一多就永久点不亮

**代码事实**：

| 位置 | 现状 | 问题 |
|---|---|---|
| `PageModelBuilder.swift:299` | `gateInputs = header.sources.map` | 把**没有快照的、`T = nil` 的**来源也塞进门槛输入 |
| `Metrics.swift:589` | 只按 `isInDecisionDomain` 过滤 | 静态成员判断，**不看 `snapshotTaken` / `T`** |
| `Metrics.swift:676-689` | 取最差 `b` | 缺席来源 `b = 0` → **`checkPassed = false`** |
| `Metrics.swift:617-643` | 任一来源 `K/T` 缺失 → `sampleUnknown` | 缺席来源让样本行变成 `nil` |
| `Metrics.swift:728` | `unmetItems` 遍历**全部** `sources` | 缺席来源产出 `l0Misjudged(0, 0)`，界面显示「L0 误判」 |
| `PageModelBuilder.swift:329` | `sampleProgress = header.sources.map` | `T = 0` 的来源**占了第 ⑤ 页的行** |
| `PageModelBuilder.swift:467` | `reportRows = header.sources.map` | 同上，第 ⑤ 页矩阵多出空行 |
| `Metrics.swift:432` | `DecisionDomain.members(...)` | **只有测试在用**，生产投影没接 |

**后果（加入 brew/pip 后）**：

1. 用户机器上没装 brew 或 pip → 这两个来源 `T = nil`、`b = 0` → 门槛清单永远有红项 → **`isQualified` 恒 false**；
2. 未达项会显示「Homebrew cache · L0 误判」，而事实是**它根本没被扫到**；
3. 第 ⑤ 页会多出两行「总量 0」的来源，与契约「总量为 0 不占行」冲突。

**修法（单一定义处）**：

- 在 `DecisionDomain` 里提供**唯一**的判定函数，输入 `[SourceHeaderEntry]`，输出 `Set<Source>`：
  成员 = 来源声明在判定域 ∧ `snapshotTaken == true` ∧ `(T ?? 0) >= 1`；
- `gateInputs` / `sampleProgress` / `reportRows` 全部由这个函数派生；
- `unmetItems` 只接收已过滤的 `gateInputs`（或在函数内部按同一函数过滤，二选一，不能两处各写一套）；
- 新增测试：缺席来源、`T = 0`、`pipx` 有候选/无候选、新来源中途入域无快照。

**这条是 CR-032 的硬前置**：不修就加来源，等于把一个「3 个来源时偶尔出现」的缺陷变成「5 个来源时必现」。

### P0-2 · 来源归因靠静态路径片段，动态根会静默归零

**代码事实**：

```swift
// ScanEngine.swift:338-342
rules.filter { $0.pathFragments.contains { path.contains($0) } }

// ScanEngine.swift:572-586
let matched = SourceRule.match(path: full, rules: rules)
if !matched.isEmpty { candidates.append(...) }   // 不命中 = 连候选都不收
```

`SourceRule.defaults` 里的片段是 `"/.cache/uv/"`、`"/.npm/_npx/"`、`"/.local/pipx/venv/"`（`ScanEngine.swift:331-335`）。

**问题**：`AppModel.swift:435-440` 有一段「以扫描根所属来源为准做校正」，但**它永远触发不了** —— 因为 `matched.isEmpty` 的叶子在 `ScanEngine` 里根本没被 append，`c.source` 不可能是空串。

**实测证据**：`HOMEBREW_CACHE=/tmp/xxx brew --cache` 与 `PIP_CACHE_DIR=/tmp/xxx pip cache dir` 都会返回自定义路径。如果新增来源仍用 `"/Library/Caches/Homebrew/"` 之类的静态片段，那么：

- 扫描根被正确解析到自定义路径；
- 根下每个叶子的绝对路径**不含**静态片段；
- → 候选数 **0**；
- → 界面显示 `0 B`（而不是「无法判定」）→ **未知被显示成 0**。

这正是本仓库反复强调的那类「静默为 0」缺陷（`ScanEngine.swift:300-317` 的注释已经踩过一次 `uv.cache` / `uv_cache` 两套标识）。

**修法**：

- `ScanEngine.scan` 增加显式参数 `source: Source?`；传了就**按根归因**，不再依赖路径片段；
- `AppModel` 的逐来源扫描全部传 `source`；
- `SourceRule` 保留给「跨来源路径分类」的既有测试，但生产路径不再用它决定归因；
- 新增测试：用临时目录模拟 `HOMEBREW_CACHE` 覆盖，断言候选非 0 且 `candidate.source == "brew_cache"`。

### P0-3 · 版本变更重置没接线，新来源会继承旧观察期

**代码事实**：

- `StateStore.resetIfVersionChanged(...)` 定义在 `StateStore.swift:147`，**生产代码零调用**（只有测试可能调用）；
- `StateFile.clearCarrierForVersionChange(...)` 定义在 `StateFile.swift:238`，同样未被调用；
- `AppModel` 里没有把 `header.appVersion` 写成当前版本。

**后果**：CR-032 会随一个新版本发布。若版本重置没接线：

- 观察期计数日沿用上一个版本（可能已经满 14 天）；
- 新加的 Homebrew / pip **一进来就落在「观察期已满」的轮次里**；
- 虽然当前 `K`/结算未实现导致门槛点不亮，但一旦结算链接通，就会出现「新来源零观察期直接参与判定」——**这是安全边界问题，不是显示问题**。

**修法**：按 PRD M3「写入时刻」（`Residue-PRD-v5.5.md:109`）在启动时执行版本比对；版本变更时：计数日归零、`T` 待重取、`K/J` 清零、`b` 清零、`a` 清零、轮次不变。测试：写一个旧版本 state → 以新版本加载 → 断言七个量。

**这条必须在 CR-032 发布前修**，否则新来源的观察期起点是假的。

### P0-4（范围边界）· `K` 与结算报告没有写入点

代码事实：`SourceHeaderEntry.K` 只在构造时写 `nil`（`AppModel.swift:923`），全仓没有赋值；`SettlementHeader.producedAt` 也只有定义与读取，没有写入。结果是：

- `settlementProduced` 恒 false；
- 门槛清单的「结算」项恒「未产出」；
- 样本项恒「本轮未结算」。

**这不是 CR-032 要修的**，但它决定了本单的**真实收益边界**：

> CR-032 落地后，Homebrew / pip 会出现在扫描、① 页、② 页、⑤ 页、⑦ 页与报告里，但**不会**带来任何删除能力 —— 门槛本来就点不亮。

建议：把「结算链（K/T/J + 报告产出）」单独立项，不要与来源扩展混在一张单里。否则一张单同时改「来源枚举 + 门槛判定 + 结算链」，无法判断失败来自哪一层。

### P1-1 · 状态文件段序必须追加，不能插队

`StateFileCodec` 的段表用 `(sourceIndex, kind)` 索引，`sourceIndex` = `Source.allCases` 的枚举序号（`ResidueStateFile.swift:301`；R2 v1.8:297）。新增 case **必须追加在 `pipxRun` 之后**，否则：

- 老文件里 `sourceIndex = 2` 的 pipx 段会被新版本读成 `brewCache`；
- 后果是 `F` 位图 / `a` / 槽位表错位 —— **不崩，读数全错**。

配套测试：构造 v1（3 来源）文件 → v2 构建加载 → 断言三个老来源的载荷逐字节不变、两个新来源为空。

### P1-2 · 上游总预算没有累计

`UpstreamRunner` 的 `consumed` 是 `let`，构造后**永不增加**（`UpstreamCommand.swift:164-169`），所以总预算判定 `consumed + 2 > 10` 永远为假。当前 2 条命令不会超；变成 4 条后最坏 8 s，仍在 10 s 内，但**预算机制本身是失效的**。建议在 CR-032 一并修（加 `consuming(elapsed:)` 返回新 runner，或改成引用类型累计），并加测试。

---

## 七、契约与文档改动清单

CR-032 一旦进入实施，至少牵动以下文档。**没有变更单的改动判无效**（本仓库规则）。

| 文档 | 位置 | 改什么 | 版本 |
|---|---|---|---|
| PRD | AC-04 ①（`v5.5:989`） | 封闭枚举从 2 类变 4 类；明确 Homebrew 进域、pip 仅报告 | v5.6 |
| PRD | §六 判定域（`v5.5:1173`） | 同上；重申 `T = 0` 不占行 | v5.6 |
| PRD | AC-19 | 白名单新增 `pip cache dir`（以及 D4 选定的可执行形态） | v5.6 |
| PRD | §六 第 ⑤ 页行集合（`v5.5:1067`） | 行集合改为「判定域 ∪ pipx（有候选）∪ pip（仅报告，有候选）」 | v5.6 |
| R2 | 来源枚举与段序（`v1.8:297`、`v1.8:319`） | 5 个来源、声明序、`sourceIndex` 追加规则 | v1.9 |
| R2 | 上游白名单（`v1.8:908`、`v1.8:1060`） | 命令数从 6 变 7+；明确 `pip cache dir` 只读定位 | v1.9 |
| R2 | 状态载体 | `schemaVersion = 2`；旧版本读新文件 → `E-301` | v1.9 |
| 视觉基线 | ① 页来源构成、⑤ 页矩阵、菜单栏浮层 | 5 个来源的布局与 2 个识别色 | **不另立文档版本**；增补写在本单 §十三（同 CR-031 做法：v1.1 的色板 / 字号 / 圆角已被 CR-031 取代，再复制一份会各自腐坏） |
| DAC | ① 页来源构成、② brew 过滤、pip 仅报告、布局未识别 | DAC-08 / DAC-40 修订 + DAC-107~110 新增 | **v2.1** |
| B1 | 来源枚举、页面结构 | 新增来源的用例（brew 只计瓶子 / pip 恒仅报告 / 未装来源不阻断门槛 / 布局未识别显示「—」） | **v1.2**（§16 · TC-110 ~ TC-116，7 条；既有编号一条未改。文件名跟随内部版本标签：v1.0 首稿 → v1.1（2026-11-08，未改名）→ v1.2（本次）） |
| 台账 | Phase 3 闸门台账 | 登记 CR-032 与 P0 前置 | 当次 |

**不需要改的**：错误码表（`E-107` 已覆盖上游定位失败、`E-108` 覆盖来源不可读，无需新码）；N5 删除语义；§8 七类状态；14 天观察期。

---

## 八、代码落点与实施步骤

> 估算按「一个人、熟悉仓库」计，含测试与文档，不含评审往返。

### 阶段 0 · 前置修复（约 1.5–2 人日）

1. `DecisionDomain` 增加「从 `[SourceHeaderEntry]` 求成员」的唯一实现；`PageModelBuilder` 的 `gateInputs` / `sampleProgress` / `reportRows` 改用它；`unmetItems` 只吃过滤后的输入。
2. `ScanEngine.scan` 增加 `source:` 参数；`AppModel` 逐来源传入；补自定义根测试。
3. 接线版本变更重置；`AppModel` 保存时写 `appVersion`。
4. `UpstreamRunner` 总预算累计（P1-2）。
5. 测试：`MetricsTests` / `PageModelBuilderTests` / `ResidueStateFileTests` / `ScanEngineTests` 各补用例。

### 阶段 1 · Homebrew（约 1 人日）

1. `Source` 追加 `brewCache = "brew_cache"`；补 `isInDecisionDomain`、`displayName`、`canonicalCachePath`。
2. `resolveSourceRoots` 调 `brew --cache`，根 = `<cache>/downloads`；失败回退 `~/Library/Caches/Homebrew/downloads`。
3. `ScanEngine` 增加文件名过滤（`contains(".bottle") && hasSuffix(".tar.gz")`），只收瓶子。
4. `DesignTokens.source(for:)` 加 `"brew_cache"`；`verify_a9.sh:213` 色表加 `0xB37A4E`。
5. `WiringSelfCheck` 的 `overviewBlocks.count == 3` 改为 `== Source.allCases.count`；新增「brew 根被覆盖时仍有候选」断言。
6. 状态 schema 升 2；迁移测试。

### 阶段 2 · pip（约 0.5–1 人日）

1. `Source` 追加 `pipCache = "pip_cache"`；`isInDecisionDomain` 返回 `false`。
2. 白名单加 `pip cache dir`（以及 D4 选定的 `pip3` / `python3 -m pip`）。
3. `resolveSourceRoots` 拆三个子根：`http-v2`、`http`、`wheels`（只加存在的）。
4. 「布局不认识」→ `.unavailable`，新增 `UICopy` 文案并同步 `verify_a9.sh`。
5. 颜色 `0x5FB3C9`。

### 阶段 3 · 界面与设计（约 0.5–1 人日）

- ① 页来源构成目前是 **3 列等宽**（`Pages.swift:129-151`，注释写明「每列约 83 pt」）。5 个来源会挤到约 60 pt，`Homebrew cache` 必截断 → 改为「3 列 + 2 列」两行，或去掉该条的逐项字节（下方 `sourceTable` 已有完整数据）。
- ⑤ 页矩阵从 3 行变 5 行；菜单栏浮层固定 `height: 404`（`MenuBarPopover.swift:39`），5 行会多 40 pt → 需加高或折叠（折叠必须由 `PageModelBuilder` 算，不能在视图里做第二套聚合）。
- 16 张设计稿重渲染；`DesignSampleData` 补两个来源。

### 阶段 4 · 文档与校验（约 1 人日）

- 五份契约文档升版；CR-032 从「评估」转「实施」；台账登记。
- `check_all.sh` / `verify_r2.py` 全绿；`verify_a9.sh`（色表、文案、页面结构）；`--verify-wiring`（区块数、根覆盖）。
- **不要**用 `| tail` 截断 `swift test` 输出（本仓库踩过的坑）。

**合计约 4.5–5.5 人日**（不含评审往返）。不确定性主要在 ① 页布局和 pip 布局兼容。

---

## 九、测试与证伪计划

| 层 | 用例 | 改错了会红吗 |
|---|---|---|
| 单测 | 缺席来源不进 `gateInputs`；`T = 0` 不进 ⑤ 行；pipx 有候选才占行 | 会（注入旧实现 → 红） |
| 单测 | 自定义根下候选归因正确（`HOMEBREW_CACHE` / `PIP_CACHE_DIR` 模拟） | 会（用静态片段 → 0 候选 → 红） |
| 单测 | v1 state 文件在 v2 构建下三来源载荷不变 | 会（插队新增 case → 错位 → 红） |
| 单测 | 版本变更后七量归零、轮次不变 | 会（不接线 → 红） |
| 单测 | `UpstreamRunner` 连续 6 次 2 s 探测后拒绝第 7 次 | 会（`consumed` 不累计 → 红） |
| 接线自检 | `overviewBlocks.count == Source.allCases.count`；brew 覆盖根有候选；pip 缺席时页面不出现空行 | 会 |
| 静态校验 | `verify_a9.sh` 色表含两个新色；来源色映射有 `brew_cache` / `pip_cache`；无第二套算术 | 会 |
| 真文件系统 | 临时目录造 `downloads/*.bottle.tar.gz`、`http-v2/*.body`；**不要用 `MemoryFS`**（它是扁平的，不递归） | 会 |
| 迁移 | 新版本读旧文件成功；旧版本读新文件 → `E-301`（用 `schemaVersion = 3` 模拟） | 会 |

**证伪要求**：每条新断言至少注入一次对应缺陷，确认它变红；再把正确实现跑绿。本仓库已有多次「判据自己说谎」的记录（CR-030 §五），不能只写断言不证伪。

---

## 十、风险表

| # | 风险 | 级别 | 处置 |
|---|---|---|---|
| R1 | 删除 bottle 后离线无法重装 | 中 | 文案说明「删的是下载缓存，重装需联网」；不把 brew 缓存算进「已安装软件」 |
| R2 | `brew cleanup -s` 外部清空 → 本轮 `K < H` 卡住 | 中 | Homebrew 进域接受此风险；pip 因 `H ≈ T` 先不进域 |
| R3 | cask 包版本被厂商下架，无法重下 | 中 | 本单不纳入 cask（D3） |
| R4 | pip 布局变更（`http-v3`）→ 静默 0 | 中 | 「布局不认识」→ `.unavailable`，不显示 0 |
| R5 | 首次执行把 5 GB 移进废纸篓，用户以为「没释放空间」 | 中 | 现有 `TrashExecutor` 语义如此；确认文案已说明「移入废纸篓」 |
| R6 | 状态文件升级后旧版本读不了 | 低 | schema 升 2 → `E-301` 只读，不重置、不改名 |
| R7 | 上游命令从 2 变 4，冷启动变慢 | 低 | 实测 brew 0.01 s / pip 0.68 s；总预算 10 s 内 |
| R8 | brew 缓存文件被其他进程持有（正在安装） | 低 | L0 已按 `(dev, ino)` 判活引用；执行前二次检查 |
| R9 | `Candidate.source` 逗号拼接导致执行层过滤不到 | 低 | P0-2 改为单值归因后消失；加测试 |
| R10 | 5 个来源的 ① 页/浮层截断 | 中 | 阶段 3 设计走查；先用 `--render-pages` 看 16 张稿 |

---

## 十一、需要用户裁决的 5 个问题

| 编号 | 问题 | 我的建议 | 备选 |
|---|---|---|---|
| **D1** | Homebrew 是否进判定域（参与自动删除）？ | **是** | 先仅报告一轮再升域 |
| **D2** | pip 是否进判定域？ | **否，先仅报告** | 与 brew 一起进域（风险：`H = 30`、`T = 32`，流失 3 个就卡住） |
| **D3** | brew 候选是否只收 bottle？ | **只收 `*.bottle*.tar.gz`（113 个）** | 收整个 `downloads/`（261 个，含 cask，R3 风险） |
| **D4** | pip 定位命令的白名单形态？ | `pip cache dir` + `pip3 cache dir` + `python3 -m pip cache dir` 三条 | 只加 `pip`（本机是 asdf shim；部分机器没有 `pip` 只有 `pip3`） |
| **D5** | ① 页 5 个来源的布局 | 3 + 2 两行；浮层加高到约 444 pt | 只显示前 3 + 「其他 2」聚合（需在 Core 算） |

> D1/D2 是产品语义，不能由实现方代拍；D3/D4 是安全边界；D5 是设计走查项。

---

## 十二、本单明确不做

1. **不读聊天内容 / 不读绘画内容 / 不推断用户用了什么工具**（上一轮已与用户确认）；
2. **不接 pnpm / Yarn / Cargo / Go / conda / Docker / Ollama / HuggingFace / Nix**；这些需要单独评估（尤其是 pnpm 的硬链接与索引完整性、Go 的 asdf 路径）；
3. **不实现结算链（K/T/J、报告产出）**；单独立项；
4. **不实现删除动作的任何新路径**：一旦来源进入判定域，仍复用现有 `TrashExecutor` 的原子 rename，不新增 `rm` / `unlink`；
5. **不修改 UI 文案中的既有语义**（只新增来源名与「布局未识别」一条）；
6. **不在本单提交实现代码**；等 D1–D5 裁决后再开实施分支。

---

## 附：证据坐标（代码）

| 事实 | 位置 |
|---|---|
| 判定域静态成员定义 | `ResidueApp/Sources/ResidueCore/Metrics.swift:52` |
| 判定域成员函数（仅测试用） | `Metrics.swift:432` |
| 清单只按静态成员过滤 | `Metrics.swift:589` |
| 未达项遍历全部来源 | `Metrics.swift:728` |
| 门槛同源于清单 | `Metrics.swift:755` |
| `gateInputs` / `sampleProgress` / `reportRows` | `PageModelBuilder.swift:299 / 329 / 467` |
| 路径片段匹配 | `ScanEngine.swift:338-342` |
| 未命中片段即不收集 | `ScanEngine.swift:572-586` |
| 默认规则 | `ScanEngine.swift:331-335` |
| 归因校正（永不触发） | `AppModel.swift:435-440` |
| 持久化逐来源 | `AppModel.swift:875-940` |
| 版本重置函数（未接线） | `StateStore.swift:147` |
| 载体清零函数（未接线） | `StateFile.swift:238` |
| schema 版本与降级 | `ResidueStateFile.swift:285 / 442` |
| 白名单（brew 已在、pip 不在） | `UpstreamCommand.swift:90-103` |
| 总预算未累计 | `UpstreamCommand.swift:164-169 / 214` |
| 接线自检写死 3 区块 | `WiringSelfCheck.swift:60` |
| a9 色表 | `ResidueApp/scripts/verify_a9.sh:213` |
| 来源色映射 | `ResidueApp/Sources/ResidueApp/DesignTokens.swift:54-70` |
| ① 页 3 列布局 | `ResidueApp/Sources/ResidueApp/Pages.swift:129-151` |
| 浮层固定高度 | `ResidueApp/Sources/ResidueApp/MenuBarPopover.swift:39` |

---

## 十三、视觉基线增补（CR-032 落地，2026-11-14）

> **为什么不立 `视觉基线 v1.2`**：`CR-031` 已明写「v1.1 的色板 / 字号 / 圆角三节由本单取代」。若再从 v1.1 复制一份 v1.2，会把已被取代的旧色板复活成两份定义。**视觉增补一律走变更单**（与 CR-031 同法），契约侧只保留 `v1.1 + CR-031 + CR-032` 三段有效。

| # | 项 | 值 | 依据 |
|---|---|---|---|
| **V1** | ① 页「来源构成」栅格 | **3 个等宽弹性列**（`LazyVGrid`），列间距 12 pt、行间距 6 pt；5 个来源按 `Source.allCases` 声明序排成 **3 + 2**（次排左对齐） | D5 裁决 |
| **V2** | ① 页来源单元 | 识别点（`SourceDot`）+ 名称（单行截断）/ 字节（`numberSmall`）/ 占比（`nil` 时不占行） | `Pages.swift` `composition` |
| **V3** | 菜单栏浮层 | 来源构成 = **竖排 5 行**（识别点 + 名称 72 pt + 占比条 + 字节 62 pt，行高 20 pt）；浮层 **360 × 444 pt**（v1.1 为 404，+40 pt） | D5 裁决 |
| **V4** | 来源识别色 | `brew` = `#B37A4E`、`pip` = `#5FB3C9`；连同 CR-031 的 uv `#7C8CF8` / npm `#E8A84C` / pipx `#56C596` 共 5 个。**识别色不是状态色**：只用于 ≥ 6 pt 圆点 / 图标底，不占信号色名额，不得用于文字 / 边框 / 按钮 / 背景块 | CR-031 §2 同族规则 |
| **V5** | 未装来源 | 区块与浮层行**恒为 5**；根目录探测为不存在 → `0 B`（已探测、确为 0，是已知不是未知）。**「—」只留给「无法判定」**（布局未识别 / 本轮未扫描） | 「不把未知判为安全」 |
| **V6** | 布局未识别 | ① 该来源字节与占比、② 该行条目数与字节 → `.unavailable(reason: 「缓存布局未识别（工具版本可能已变更）」)`，**不得显示 `0`** | `UICopy.cacheLayoutUnrecognized` |

**与 AC-01 的关系**：视觉基线 §五 ① 的「来源构成」是**一张汇总卡内的一栏**，**不是** AC-01 的三个内容区块（各来源占用量 / 可再生 / 不可再生）。两者层级不同，DAC-40 已写明「来源卡不构成三区块」——本单的 3 + 2 只是把这一栏从 3 项排到 5 项，**不改变 AC-01 的判定**。

---

## 十四、实施记录与验证证据（2026-11-14）

### 14.1 落地清单（按层）

| 层 | 落点 | 内容 |
|---|---|---|
| Core · 来源 | `Metrics.swift` | `Source` 追加 `brewCache` / `pipCache`（**追加在尾部**，段序不变）；`isInDecisionDomain` 对 brew 为 `true`、pip 为 `false` |
| Core · 判定域 | `Metrics.swift` `DecisionDomain.members(from:)` | **唯一实现**：`isInDecisionDomain ∧ snapshotTaken ∧ T ≥ 1`；删除了按 `snapshotSources` 求成员的第二套实现 |
| Core · 扫描 | `ScanEngine.swift` | `FileNameFilter`（必含子串 / 必含后缀）与 `scan(..., source:fileFilter:)`；候选按**显式来源**归因（不靠路径片段猜） |
| Core · 状态 | `ResidueStateFile.swift` / `StateFile.swift` | schema **1 → 2**；v1 文件仍可读；新文件被旧版本读到 → `E-301` 只读（不是 `E-304` 损坏）；版本变更清零**保留轮次** |
| Core · 上游 | `UpstreamCommand.swift` | 白名单加 `pip cache dir` / `pip3 cache dir` / `python3 -m pip cache dir`；`pip cache purge` 拒绝；`UpstreamRunner` 改为累计已用时（**总预算 10 s 真正生效**） |
| Core · 投影 | `PageModelBuilder.swift` | 门槛输入 / ⑤ 行集合 / 未达项统一走 `DecisionDomain.members`；新入域无快照来源不阻断；布局未识别 → `.unavailable`；重启后逐来源显示「—」 |
| App · 根解析 | `ScanInfrastructure.swift` | `SourceRoot` / `ResolvedSourceRoots` / `resolveSourceRoots`；brew 根 = `<brew --cache>/downloads`；pip 根 = `http-v2` / `http` / `wheels`（只加存在的），根存在但三子目录全缺 → `layoutUnrecognized` |
| App · 编排 | `AppModel.swift` | 逐根扫描并带 `source:`；保存时写 `appVersion`；版本变更时调 `clearCarrierForVersionChange(newAppVersion:keepingRound:)` |
| App · 界面 | `Pages.swift` / `MenuBarPopover.swift` / `DesignTokens.swift` | ① 页 3 列网格、浮层 444 pt、两个识别色与 `source(for:)` 映射 |
| 校验 | `verify_a9.sh` | 色表加入 `0xB37A4E` / `0x5FB3C9` |
| 文档 | `docs/contract/Residue-B1-功能用例集-v1.2.md` | 新增 §16（TC-110 ~ TC-116，7 条）+ §0 四个夹具；同步 §3 覆盖索引、§6 · D-1 统计（**顺带改正 v1.0 遗留的 98 条错账**）、§12 签核表；**既有编号与既有预期一条未改** |

### 14.2 前置缺陷的处置（§六 P0/P1）

| 编号 | 原问题 | 处置 | 证据 |
|---|---|---|---|
| **P0-1** | 缺失来源（brew / pip 未装）会让门槛永远不满足 | 门槛输入只取 `DecisionDomain.members`（快照内 `T ≥ 1`）；测试 `testAbsentSourcesDoNotBlockGateOrOccupyRows` | 单测 |
| **P0-2** | 自定义缓存根下候选归因为空 | `scan(source:)` 显式归因；测试 `testExplicitSourceAttributesCandidatesOutsideKnownPathFragments` | 单测 + 接线自检 46 |
| **P0-3** | `a` 的版本变更重置未接线、`appVersion` 从未写入 | 保存即写版本；加载时版本不同 → 清零并**保留轮次**；测试 `testClearCarrierForVersionChange` / `testV1FileStillLoadsAfterSchemaBump` | 单测 |
| **P0-4** | `K` 与「结算报告产出」无写入点 | **本轮仍未实现**（见 §十五）——CR-032 不改变「看得见、统得准、能举证」的定位 | 遗留 |
| **P1-1** | 段序插队会让老文件读数错位 | 新 case 追加在 `pipxRun` 之后；v1 文件迁移测试 | 单测 |
| **P1-2** | 上游总预算永不累计 | `UpstreamRunner` 改为类 + 锁累计；测试用临时 `uv` 脚本验证第二次调用因总预算被拒 | 单测 |

### 14.3 验证结果（本机，2026-11-14）

| 项 | 结果 |
|---|---|
| `swift build` / `swift build -c release` | 通过（Release 裁掉 DEBUG 自检入口后仍通过） |
| `swift test` | **312 个用例，0 失败** |
| `./ResidueApp/scripts/verify_a9.sh` | **88 项通过 / 0 失败** |
| `swift run ResidueApp --verify-wiring` | **46 项通过 / 0 失败** |
| `python3 ResidueApp/scripts/verify_codes.py` | **11 项通过 / 0 失败** |
| `./tests/contract/check_all.sh` | **全部通过**（PRD v5.6；结构 191 + CR-022 47 + 声明归零 + 单一定义） |
| `python3 tests/contract/verify_r2.py` | **全部通过**（R2 v1.9；结构 30 + 落地 65 + 归零 16 + 一致 10 + 自洽 2） |

**没有验的**：公证 / 钉票 / `spctl` / 干净机装机 / GUI 真实交互 / 回滚演练（A-10 项的既有六项，仍需外部资源）。

### 14.4 重渲染时发现并修掉的一处（不是「看图找感觉」）

| 现象 | 根因 | 处置 |
|---|---|---|
| ① 页来源名显示成 **`Homebrew…`**（截断） | 展示名 `Homebrew cache` 在 11 pt 下约 88 pt，而 ① 页列宽约 83 pt、浮层列宽 72 pt | `Source.brewCache.displayName` 改为 **`Homebrew`**（代码与样例数据统一取该属性，不再各写一份字符串）；重渲染后 ① 页与浮层均完整显示 |

> 这条正是 §八 阶段 3 预判的「`Homebrew cache` 必截断」。**判据不能只写「有这一项」，还要写「名称可读」**——DAC-107 已按最终展示名逐字写死。

---

## 十五、遗留与后续

| # | 项 | 为什么没在本轮做 | 建议 |
|---|---|---|---|
| **L-1** | ~~**B1 功能用例集未升版本**~~ **已关闭** | 已补 `Residue-B1-功能用例集-v1.2.md` §16（TC-110 ~ TC-116）：brew 只计瓶子（TC-110）/ ② 页标签（TC-111 / TC-112）/ ⑤ 页结论与不参与门槛（TC-113）/ 未装来源不占行不阻断（TC-114）/ 未装来源显示 `0 B`（TC-115）/ 布局未识别显示「—」（TC-116）；**用例编号追加、不改既有编号**；另加 RG-21 与 4 个输入缺口（G-6 ~ G-9） | 已交付；G-6（`pip cache` 行 ④/⑥ PRD 未逐字规定）与 G-7（结算链无写入点）待主理人裁定 |
| **L-2** | ~~**⑤ 页非判定域行的 ④ / ⑥ 取值与 PRD 字面不一致**~~ **已关闭（CR-033）** | 既有实现（`pipx` 行）只显示「不适用」、⑥ 显示 `a` / `b` 数值；PRD AC-09 判定要求 ④「不适用（不入判定域）」、⑥「不适用 · 未执行 L0 检查」。已按登记另开 `Residue-CR-033-第⑤页非判定域行取值逐字化.md` 修完：④ / ⑥ 逐字化、⑥ 改整格一句、④ / ⑥ 列宽重排（七列合计仍 ≤ 695 pt）、设计样例同步 | 已关闭；`pip cache` 行的 ③ 扫描时点标注与 ⑤ 列名分歧另见 CR-033 §六 R-2 / R-3 |
| **L-3** | **`K` / 报告产出仍无写入点** | 属结算链，独立立项；本轮不碰 | 结算链立项时一并处理；在此之前门槛仍点不亮（如实） |
| **L-4** | **pip 入域** | D2 裁决「先仅报告、观察一轮」 | 观察一轮后另出变更单；本单不预埋开关 |
| **L-5** | **设计稿只重渲染，未做真机走查** | 走查需要 GUI 与外部环境（A-10 范畴） | 按 A-10 执行单排期 |

---

## 十六、本单的硬边界（实施后仍然有效）

1. **删除仍只有一条路径**：`TrashExecutor` 原子 rename 到废纸篓，全文无 `rm` / `unlink`。
2. **上游命令仍只有只读定位**：新增的 pip 三条形态均为 `cache dir`；`pip cache purge` 被拒并有测试。
3. **未知仍显示「—」**：布局未识别、重启未扫描、未结算 —— 一律 `.unavailable`，不显示 0。
4. **不读文件内容 / 不读聊天 / 不读绘画**：本轮只增加缓存目录的**元数据**扫描。
