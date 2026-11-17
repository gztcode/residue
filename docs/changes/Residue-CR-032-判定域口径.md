# CR-032 · 判定域口径（快照内命中）· P0 · 无快照的域内来源永久堵死门槛

> **缺陷**：门槛链的**判定域**用「枚举口径」（`uvCache` / `npmNpx` 恒在域内），
> 而契约要求判定域 = **本轮观察期开始快照内命中的来源**
> ⇒ 域内但**本轮无快照**的来源（`T = null`）**永久堵死** `GateEvaluator.isQualified`
> ⇒ **产品永远点不亮**
> **契约依据**：PRD v5.6 · 观察期规则表「判定域」行 / R9 / 架构 A1；
> R2 v1.9 §5.1 / §5.5；AC-08 组 B Given
> **性质**：**实现错误**（契约侧已写对，代码没照做 —— 与 CR-031 的「功能缺失」不同类）
> **状态**：**已实现**（待评审）
>
> **修订记录**：
> - **v1 · 2026-11-17**：初稿。本单是 CR-031 §8.3-ii 登记项的实现，
>   并附带订正 CR-031 §8.3-i 的一条**登记错误**（见 §五）。
> - **v2 · 2026-11-17**：实现完成。RED → GREEN 实测记录见 §九；验收判据 12 项全部通过。

---

## 一、缺陷

### 1.1 现象

只有 `uv` 缓存、没有 `npm` / `npx` 缓存的用户（很常见）：

- `uv` 一路达标（`K ≥ H`、`a = 0`、`b ≥ 1`、观察期已满、结算凭证已产出）；
- `npmNpx` **始终无候选** ⇒ 从未取过快照 ⇒ `T = null`；
- 结果：**`uv` 再达标也点不亮**，且第 ③ 页把 `npmNpx` 列为未达项。

### 1.2 复现路径（代码级）

`ResidueCore/Metrics.swift` 的 `GateEvaluator.isQualified`：

```swift
let domain = sources.filter { $0.source.isInDecisionDomain }   // ← 枚举口径
guard !domain.isEmpty else { return false }
guard settlementProduced, progress.isDayQuotaReached else { return false }
for input in domain {
    if input.undetermined { return false }
    guard let k = input.attributable, let t = input.total else { return false }   // ← T = null ⇒ 永久 false
    ...
}
```

`Source.isInDecisionDomain` 是**来源的固有属性**（`uvCache` / `npmNpx` ⇒ `true`），
与「本轮有没有快照」**无关**。而 `T = null` 的来源在 `guard let t = input.total` 处
**直接判死** ⇒ 永久堵死。

### 1.3 第二个后果：误报未达项

同一处口径错误在 `GateEvaluator.unmetItems` 上产生**第二个可见症状**：
域外（无快照）的来源满足 `a = 0` 且 `b = 0` ⇒ 落入 `else if let b = input.checkCount, b == 0`
⇒ 被列为「**L0 误判**」未达项。

它从未参与过任何判定，却被界面报成「判错过」——
**这是把「没判定」说成「判错了」**，违反不变量③「不把未知判为安全 / 如实呈现」。

### 1.4 与 CR-031 的关系

CR-031 修的是「门槛量 `K` / `a` / `producedAt` 从未被写过非空值」。
本单修的是「门槛链的**判定域口径**错了」。
**两者必须都修，产品才可能点亮** —— 缺任一个，`isQualified` 恒 `false`。

---

## 二、根因

### 2.1 两套口径并存

| 口径 | 定义 | 契约位置 | 代码位置 | 状态 |
|---|---|---|---|---|
| **枚举口径** | `Source.isInDecisionDomain` | —— | `Metrics.swift` `isQualified` | **错**（在用） |
| **快照口径** | 本轮观察期开始快照内命中 | PRD v5.6 架构 A1 / R9 | `Metrics.swift` `DecisionDomain.members` | **对**（**生产零调用**） |

`DecisionDomain.members(snapshotSources:)` 的文档注释已经把正确口径写清楚了：

> 判定域成员 = **本轮观察期开始快照内命中的来源**（契约：判定域以快照内命中为准）。
> 新入域但无本轮快照的来源**不属于判定域**，不参与逐来源判定、不阻断点亮。

⇒ **正确的原语已经存在，只是没人调用。**

### 2.2 为什么「一直没人发现」

`uv` / `npm` **两个来源都有候选**时，第二次成功全量扫描后两者 `T` 都非空 ⇒ 口径差异不可见。
只有「某个域内来源**始终无候选**」时才暴露 —— 而这恰好是单一工具链用户的常态。

---

## 三、改什么

### 3.1 判定域的唯一定义处不动

`DecisionDomain.members(snapshotSources:)` **保持原样**，仍是判定域的**唯一定义处**（不变量②）。

### 3.2 `GateEvaluator` 签名变更：判定域改为**显式入参**

```swift
public static func unmetItems(
    progress: ObservationProgress,
    settlementProduced: Bool,
    decisionDomain: Set<Source>,      // ← 新增
    sources: [SourceGateInput]
) -> UnmetItems

public static func isQualified(
    progress: ObservationProgress,
    settlementProduced: Bool,
    decisionDomain: Set<Source>,      // ← 新增
    sources: [SourceGateInput]
) -> Bool
```

- **不给默认值** —— 编译期强制每个调用点表态，避免「漏传 ⇒ 静默按错误口径判定」。
- 内部一律按 `decisionDomain.contains(input.source)` 取域内来源，
  **删掉 `isQualified` 里的 `filter { $0.source.isInDecisionDomain }`**（枚举口径的第二份实现）。
- `sources` 仍传**全部来源**（含域外），由 `GateEvaluator` 统一过滤 ⇒ 调用方传错也不会误判。

### 3.3 `PageModelBuilder` 采集判定域

载体里的判据：`SourceHeaderEntry.snapshotTaken == true` ⇔ 该来源**本观察期已取快照**。

依据（均为生产代码既有事实，非本单新增）：

| 事实 | 位置 |
|---|---|
| 取快照时**同时**写 `snapshotTaken = true` 与 `T = current.count` | `ObservationWriteback.apply` ③ |
| 结算**不改** `T` / `snapshotTaken` | `ObservationWriteback.apply` ④ |
| 迁移 / 版本变更重置时**两者同时清零** | `StateHeader.resetObservationCredentials()` ② |

⇒ `snapshotTaken` 与 `T != null` **恒同步**，用前者语义更清楚（它就是「有没有快照」那位）。

```swift
let snapshotSources = Set(header.sources.filter { $0.snapshotTaken }.map { $0.source })
let decisionDomain = DecisionDomain.members(snapshotSources: snapshotSources)
```

### 3.4 不动的地方（外科手术边界）

| 位置 | 为何不动 |
|---|---|
| `PageModelBuilder` 第 ② 页 `participation`（`isInDecisionDomain`） | 那是**来源固有属性**的呈现（`pipx` 永远只报告），不是门槛判定 |
| `PageModelBuilder` 其余三处 `isInDecisionDomain` | 同上，页面呈现 |
| `Source.isInDecisionDomain` | 枚举本身不变，只是**不再**被用作判定域 |
| 只读态相关的一切（`readOnly` 守卫、`UICopy.readOnlyNoSettlement`） | 核实后**无缺陷**（见 §五） |

---

## 四、影响面

| 文件 | 改动 |
|---|---|
| `ResidueCore/Metrics.swift` | `GateEvaluator` 两处签名 + 删枚举口径过滤 + 调用 `DecisionDomain.members` |
| `ResidueCore/PageModelBuilder.swift` | 采集判定域并传入两处调用 |
| `Tests/ResidueCoreTests/MetricsTests.swift` | 现有用例**机械补一个 `decisionDomain` 参数**（断言逻辑不动）+ 新增用例 |
| `Tests/ResidueCoreTests/PageModelBuilderTests.swift` | 新增用例 |

⚠️ **单测只覆盖 `ResidueCore`** ⇒ `AppModel` 侧不需要改动，本单**不碰** `AppModel`。

⚠️ 现有 `MetricsTests` 用例需补参数 —— 这是**签名变更导致的机械适配**，
**断言与被测语义一律不动**（新增用例才是行为变更的证据）。

---

## 五、附带订正：CR-031 §8.3-i 的登记错误

CR-031 §8.3-i 登记：「迁移的恢复分支保留迁移前凭证 ⇒ 恢复后到下次启动之间，
门槛**可能用旧 schema 的凭证点亮**」，并留问「只读态是否完全阻断门槛链需另单核实」。

**本单核实结论：该风险在当前实现下不成立。**

| 核实点 | 结论 | 依据 |
|---|---|---|
| schema 1 载体是否含 `K` / `J` / `settlement` 值？ | **恒为 null** | CR-031 实施前，`K` / `J` / `producedAt` **从未被写过非空值** ⇒ 旧载体里本就没有可保留的凭证 |
| 恢复后的载体会不会被当作已达标？ | **不会** | 恢复写回的仍是 schema 1 载体 ⇒ 下次启动**再次走迁移** ⇒ 迁移时 `resetObservationCredentials()` 清零 ⇒ 观察期从头开始 |
| 只读态是否阻断门槛链？ | **完全阻断** | ① `PageModelBuilder` 只读分支 `model.canLightUp = false`（`PageModelBuilder.swift:142`）② 界面开关 `canLightUp && !model.readOnly`（`Pages.swift:290`）③ 执行按钮同上（`Pages.swift:839`）④ 写入与执行在 `AppModel` 侧均有 `guard !readOnly` ⑤ 已有单测 `PageModelBuilderTests.swift:68`「只读态不得可点亮」 |

⇒ §8.3-i 记的是一条**在当前实现下不存在的风险**（登记时未核实「旧载体里有没有凭证」）。
本单在 CR-031 中加一条 v7 修订记录指向此处，**并把该风险标注为「核实后不成立」**。

---

## 六、不做的事（明确边界）

| 项 | 归属 | 理由 |
|---|---|---|
| §1.7-a「未达标自动开下一轮」（`round` 从不递增） | **另开单** | 需要完整轮次设计（轮次触发条件 / 重锚点 / 与 `T` 待重取的交互），不是口径问题 |
| §1.7-c / §1.7-d 第 ⑤ 页列集合（失联 `J` / L2 误判数列） | **另开单** | 要动 `UICopy` + 视觉基线 + 16 张设计稿重渲染 —— 与本单无关 |
| §1.7-e `evidence.jsonl` 从不写入 | **另开单** | 需先定义取证字段 |
| 只读态的呈现 | **不做** | 核实后无缺陷（§五） |
| 轮次自动推进之外的「重置」路径 | **不做** | 迁移路径已正确重置 |

---

## 七、验收判据

| # | 判据 | 验证方式 |
|---|---|---|
| 1 | 域内来源**无快照**（`T = null`）⇒ **不阻断**点亮 | 单测：`MetricsTests` |
| 2 | 域内来源**无快照** ⇒ **不产**任何未达项（不误报「L0 误判」） | 单测：`MetricsTests` |
| 3 | 判定域**为空** ⇒ 仍**不可**点亮（全称量词在空集上恒真） | 单测（既有）+ 新增 |
| 4 | 判定域内来源 `K < H` ⇒ 不可点亮 + 未达项「样本不足」 | 单测（既有，断言不动） |
| 5 | 判定域内来源 `a ≠ 0` ⇒ 不可点亮 | 单测（既有，断言不动） |
| 6 | 端到端：`uv` 达标 + `npm` 无快照 ⇒ `canLightUp == true` | 单测：`PageModelBuilderTests` |
| 7 | 判定域口径**只有一个实现处** | 审查：`isInDecisionDomain` 不再出现在 `GateEvaluator` 内 |
| 8 | 全部单测通过 | `swift test` |
| 9 | 页面结构 / 界面禁算术 / 数据层接线未破 | `./scripts/verify_a9.sh` |
| 10 | 错误码表一致 | `python3 scripts/verify_codes.py` |
| 11 | 真 IO 往返自检通过 | `--verify-wiring` |
| 12 | 文档基线未破 | `check_all.sh` + `verify_r2.py` |

---

## 八、TDD 步骤

1. **RED**：`MetricsTests` 加「域内无快照来源不阻断点亮」+「域内无快照来源不产未达项」
   ⇒ 实测现状两条均失败（`isQualified` 恒 `false`；未达项多一条「L0 误判」）
2. **RED**：`PageModelBuilderTests` 加「`uv` 达标 + `npm` 无快照 ⇒ 可点亮」
3. **GREEN**：`Metrics.swift` 改 `GateEvaluator` 两处（签名 + 过滤 + 调 `DecisionDomain.members`）
4. **GREEN**：`PageModelBuilder.swift` 采集判定域并传入
5. **适配**：`MetricsTests` 现有用例机械补 `decisionDomain` 参数（断言不动）
6. **回跑**：全量校验（§七 第 8–12 项）

---

## 九、实施记录

> 实施日期：2026-11-17 · 分支：`gztcode/gate-link` · 基线：`17c4cbd`

### 9.1 TDD 实测（RED → GREEN）

**RED**（生产代码只加签名参数、行为未改）：

```
$ swift test > /tmp/cr032_red.log 2>&1 ; echo exit=$?
exit=1
	 Executed 445 tests, with 4 failures (0 unexpected) in 2.346 (2.368) seconds
```

4 处失败**全部是断言失败**（无编译错误），逐条原文：

| # | 用例 | 断言原文 | 对应判据 |
|---|---|---|---|
| 1 | `MetricsTests.testDomainSourceWithoutSnapshotDoesNotBlockLightUp` | `XCTAssertTrue failed - 域内但本轮无快照的来源不得阻断点亮` | §七 #1 |
| 2 | `MetricsTests.testDomainSourceWithoutSnapshotProducesNoUnmetItem` | `XCTAssertTrue failed - 无快照的来源从未参与判定，不得出现在未达项里（实为 [ResidueCore.UnmetSourceEntry(source: ResidueCore.Source.npmNpx, item: ResidueCore.UnmetSourceItem.l0Misjudged(missCount: Optional(0), checkCount: Optional(0), undetermined: false))]）` | §七 #2 |
| 3 | `PageModelBuilderTests.testDomainSourceWithoutSnapshotDoesNotBlockLightUp` | `XCTAssertTrue failed - 域内但本轮无快照的来源不得阻断点亮` | §七 #6 |
| 4 | 同上（该用例第 2 条断言） | `XCTAssertFalse failed - 无快照的来源从未参与判定，不得出现在未达项里（实为「npm/_npx · L0 误判」）` | §七 #2 端到端 |

⇒ 失败原因与 §八 步骤 1–2 的预期**逐条吻合**：`isQualified` 恒 `false`、未达项多一条「L0 误判」。

**GREEN**（改 `GateEvaluator` 两处 + `PageModelBuilder` 采集判定域）：

```
$ swift test > /tmp/cr032_green.log 2>&1 ; echo exit=$?
exit=0
	 Executed 445 tests, with 0 failures (0 unexpected) in 2.131 (2.153) seconds
```

**最终复跑**（导航文档项数同步之后）：

```
	 Executed 445 tests, with 0 failures (0 unexpected) in 2.092 (2.114) seconds
```

既有 440 个用例**断言一字未改**（只机械补 `decisionDomain:` 参数）⇒ 回归为零。

### 9.2 项数变化

| 项 | 改前 | 改后 | 说明 |
|---|---|---|---|
| 单测总数 | 440 | **445** | 新增 5：`MetricsTests` 3 + `PageModelBuilderTests` 2 |
| `docs/` 下 `.md` 份数 | 136 | **137** | +CR-032 |
| `docs/changes/` 文件数 | 58 | **59** | +CR-032 |
| 变更单单号数 | 20 | **21** | +`CR-032`（现存 `CR-001`…`CR-010`、`CR-022`…`CR-032`） |
| a9 校验项 | 80 | 80 | 不变 |
| 错误码校验项 | 11 | 11 | 不变 |
| 接线自检项 | 79 | 79 | 不变 |

导航文档（`ARCHITECTURE.md` / `CLAUDE.md` / `README.md` / `README.en.md`）共 9 处项数声明同步为 445 / 137。

### 9.3 §七 验收判据逐条实测

| # | 判据 | 实测证据 |
|---|---|---|
| 1 | 域内来源无快照 ⇒ 不阻断点亮 | 新增 `MetricsTests.testDomainSourceWithoutSnapshotDoesNotBlockLightUp` ⇒ GREEN 通过；RED 时断言失败 |
| 2 | 域内来源无快照 ⇒ 不产未达项 | 新增 `MetricsTests.testDomainSourceWithoutSnapshotProducesNoUnmetItem` ⇒ GREEN 通过；RED 时实为 `l0Misjudged(missCount: 0, checkCount: 0)` |
| 3 | 判定域为空 ⇒ 不可点亮 | 既有 `testEmptyDomainNeverQualified`（判定域传 `DecisionDomain.members(snapshotSources: [.pipxRun])` ⇒ 空集）⇒ 通过，断言未改 |
| 4 | 域内 `K < H` ⇒ 不可点亮 + 「样本不足」 | 既有用例（断言未改）⇒ 通过 |
| 5 | 域内 `a ≠ 0` ⇒ 不可点亮 | 既有用例（断言未改）⇒ 通过 |
| 6 | 端到端：`uv` 达标 + `npm` 无快照 ⇒ `canLightUp == true` | 新增 `PageModelBuilderTests.testDomainSourceWithoutSnapshotDoesNotBlockLightUp` ⇒ GREEN 通过；RED 时 `canLightUp` 断言失败 |
| 7 | 判定域口径只有一个实现处 | `grep -n "isInDecisionDomain" Sources/ResidueCore/Metrics.swift` ⇒ 仅 2 处：`52`（`Source.isInDecisionDomain` 定义）、`501`（`DecisionDomain.members` 内）；`GateEvaluator` 区间（610–684 行）内 **0 处** |
| 8 | 全部单测通过 | `swift test` ⇒ exit=0，`Executed 445 tests, with 0 failures` |
| 9 | 页面结构 / 界面禁算术 / 数据层接线未破 | `./scripts/verify_a9.sh` ⇒ exit=0，通过 80 项 / 失败 0 项 |
| 10 | 错误码表一致 | `python3 scripts/verify_codes.py` ⇒ exit=0，通过 11 项 / 失败 0 项 |
| 11 | 真 IO 往返自检通过 | `swift run --disable-sandbox ResidueApp --verify-wiring /tmp/cr032_wiring` ⇒ exit=0，通过 79 项 / 失败 0 项 |
| 12 | 文档基线未破 | `./tests/contract/check_all.sh` ⇒ exit=0（结构落点 191 项 + CR-022 47 项 + 9 条「已实删」声明归零 + 单一定义无冲突）；`python3 tests/contract/verify_r2.py` ⇒ exit=0，结构 30 + 落地 65 + 归零 16 + 一致 10 + 自洽 2 |

附加：`swift build -c release` ⇒ exit=0，`Build complete`。

### 9.4 已核实的副作用（在本单范围内）

`unmetItems` 改为按判定域过滤后，**恒「仅报告」的 `pipxRun` 不再出现在未达项里**（它本就在判定域外）。
与既有 `PageModelBuilderTests.testReportOnlySourceRow` 的「仅报告 / 不适用」呈现一致；
本单 §3.2 已声明该过滤在设计范围内。**无既有测试依赖旧行为**（440 个既有用例在 GREEN 全绿）。

### 9.5 未改动 / 待裁决

- `Source.isInDecisionDomain` 枚举本身未动 —— 仍用于**来源固有属性**的呈现（第 ② 页 `participation`）与 `AppModel` / `ObservationWriteback` 的来源筛选，**不再是判定域口径**。
- `docs/changes/` 内**无同名重复文件**（`/bin/ls` 核实仅 `Residue-CR-032-判定域口径.md` 一份）。
- **发现但未擅自修改**：`ARCHITECTURE.md` §二 表格仍写 `Residue-PRD-v5.5.md` / `Residue-R2-技术方案-v1.8.md`，实际最新为 v5.6 / v1.9（两文件仍存在 ⇒ 链接不失效，只是非最新）—— 待另单订正。
