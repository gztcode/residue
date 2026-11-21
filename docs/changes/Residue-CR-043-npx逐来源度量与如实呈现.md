# CR-043 · `~/.npm/_npx` 逐来源度量 · ⑦ 页独立条目 · README 已知限制 · P2

> 状态：已实施
> 变更类型：**纯度量**（**不加 `Source` case、不改声明序、不改 `T`/`K`/`J`/`a`/`b` 任何判定**）
> 影响面：`ResidueCore`（新增 `SourceScanStats`、`PageModel` / `PageModelBuilder` / `SemanticSlot` / `RecordWriter`）、`ResidueApp`（`AppModel` / `Pages` / `DesignSampleData`）、`README.md` / `README.en.md`、`docs/ledger/`、单测 9 个
> 风险等级：P2 —— 不触碰五条核心不变量；风险集中在「统计被误当成判定输入」与「耗时口径被误读」

---

## 一、缺陷

### 1.1 扫描慢，但界面不说是谁慢

台账实测（2026-11-09 · 本机）：

| 来源 | 项数 | 耗时 |
|---|---|---|
| `~/.cache/uv` | 115,875 | 6.44 s |
| `~/.npm/_npx` | 106,983 | **6.79 s** |
| 合计 | 222,858 | 12.21 s |

`_npx` 一个目录就占掉**一半以上**扫描时间，且它**只增不减**（每次 `npx` 运行都留一份临时安装）。
但 ⑦ 页此前只显示**合计**项数与总耗时 —— 用户看到「扫描要 12 秒」，看不到「这一半时间花在哪儿」，
也就无从判断该不该自己动手。

### 1.2 台账把这一项登记为「未处理」，用户没有出路

`docs/ledger/Residue-Phase3-闸门台账.md` 原文：`~/.npm/_npx` 只增不减 | **未处理** —— 这才是「越用越慢」的根因。

产品**不应该**代删它：那是 **npm 自己的缓存**，不是 Residue 的采集物。
但如果只写「未处理」，用户读完仍然不知道**自己能做什么**。这是文档缺陷，不是能力缺陷。

---

## 二、修法（三条，全部是「度量 + 如实呈现」）

### 2.1 逐来源统计：项数 + 耗时

新增 `Sources/ResidueCore/SourceScanStats.swift`：

```swift
public struct SourceScanStat: Codable, Sendable, Equatable {
    public let source: String      // `Source.rawValue`，**不是**新枚举
    public let items: Int          // 本次该来源扫描到的项数
    public let durationMs: Int     // 本次该来源耗时
}
```

`SourceScanStats.make(_:)` 负责排序：**耗时降序**（第一名就是「慢在这里」的答案）；
同耗时按 `Source.allCases` **声明序**（确定性 —— 同一份数据两次渲染不会换位置）；
**不认识的来源不丢、不猜**，按 `rawValue` 排在最后。
`milliseconds(from:to:)` 四舍五入（不是截断 —— 截断会让 6.789 s 显示成 6.78，与台账口径对不上），负数钳 0（时钟回拨不渲染「−3 秒」）。

**计时点**：`AppModel.runScan` 在 `engine.scan(...)` 调用**前后各取一次 `Date()`**。

> ⚠️ 不能用 `ScanResult.finishedAt − ScanResult.startedAt`：`startedAt` 是 `runScan` 传入的**整轮起始时刻**，
> 相减得到的是「累计偏移」而不是该来源耗时。上一来源扫得久，下一来源的「耗时」就会被虚增。

### 2.2 体积：复用既有候选字节，不写第二套求和

`SourceScanStat` **不带 bytes**。界面上的「候选体积」直接复用 `PageModelBuilder` 已有的
`bytesBySource`（按来源聚合的候选字节）—— 同一判定/聚合只允许一处实现（CLAUDE.md §四-2）。
列名如实写「**候选体积**」：它是候选文件字节之和，不是目录 `st_size`，也不是磁盘占用。

未知来源（`Source(rawValue:) == nil`）的体积给 `.unavailable(reason:)`，**不给 0**（不变量③：不把未知判为安全）。

### 2.3 界面：⑦ 页新增「本次扫描 · 各来源」

| 列 | 内容 | 槽位 |
|---|---|---|
| 来源 | `Source.displayName` | `.text` |
| 项数 | 该来源本次扫描项数 | `.metric(_, unit: .items)` |
| 候选体积 | `bytesBySource` 聚合值 | `.metric(_, unit: .bytes)` |
| 耗时 | Core 侧格式化后的字符串 | `.text` |

- 视图层**零算术**：所有数字在 `PageModelBuilder` 里算好，视图只摆槽位（不变量①）。
- 表头文案「本次扫描 · 各来源（耗时从长到短）」由 `Pages.swift` 就地 `L.pick`，与相邻两节一致；
  单元格文案的唯一样式串在 `UICopy`（`scanSourceDuration` / `npxCacheNote`），`verify_a9.sh` 第四节逐字核对。
- 节尾固定一段 `UICopy.npxCacheNote`：说明 `_npx` 只增不减、**产品不代删**、用户可自行
  `rm -rf ~/.npm/_npx`（下次 `npx` 会重新下载）。
- 统计为空（从未扫描 / 扫描中）时**整节不渲染** —— 不编造 0 行。

### 2.4 `scan.jsonl` 落盘

`ScanLogRecord` 新增 `sourceStats: [SourceScanStat]`（缺省空数组，旧记录不受影响）。
同一份统计既上界面也进日志，事后排障不必靠界面复现。

---

## 三、为什么**不**给 `Source` 加 case

`_npx` 是 `npmNpx` 这个 `Source` 下的**子路径**，但更关键的是：**它已经是独立的扫描根** ——
`SourceRoots.resolve` 里 `npmNpx` 的根就是 `~/.npm/_npx`（不是 `~/.npm`）。
所以「逐来源统计」天然就是「`_npx` 单独统计」，**不需要子路径区分，更不需要新 case**。

而给 `Source` 加 case 有明确的破坏性：`Source` 的**声明序**是 `state.residue` 段表 `sourceIndex u8` 的隐式 ABI
（CLAUDE.md §七-9）。中间插入会让存量载体的段索引整体错位 —— `uv` 的数据被读成别家的，
误判数 `a` 归到错误的来源上，**不变量④（删之前先证明自己判得准）静默失效**。
`SourceABITests` 会直接判红，但「测试能拦住」不是可以随便动的理由。

---

## 四、口径说明（为什么不复用已有实现）

| 问题 | 结论 | 理由 |
|---|---|---|
| 耗时为什么走 `.text` 而不是 `.metric`？ | 必须 `.text` | `MetricUnit` 只有 `.bytes` / `.items` / `.times` / `.days` / `.none`，**没有秒/毫秒**。用 `.metric(6, .none)` 会把 6.79 s 截成 6 —— `uv`（6.44）与 `_npx`（6.79）会显示成同一个数，恰好抹掉本单要呈现的差别 |
| 为什么不改 `ScanProgress.displayText` 的 `%.1f 秒`？ | 不改 | 那是**扫描中**的实时进度（一位小数、持续刷新），本单是**扫描完成后**的逐项账单（两位小数、定位到具体来源）。两个用途、两个精度，强行合并会让实时进度抖动得更厉害 |
| 为什么体积取候选体积而不是目录字节？ | 候选体积 | 与 ① 页「候选总字节」同源（`bytesBySource`），用户能对上账；目录 `st_size` 对 `pnpm` / `bun` 这类整块粒度来源是错的（CR-041 §2.1 已踩过） |
| 为什么排序放在 Core？ | 确定性 | 排序是判定式逻辑（同耗时靠什么决胜），放视图层会变成第二套实现，且无法单测 |

---

## 五、纯度量自证（本单最关键的断言）

要求是：**加了统计之后，扫描结果（各来源 `H` / `K` / `a` / `b`）与之前完全一致**。

`PageModelBuilderTests.testSourceScanStatsDoNotChangeAnyJudgment` 用**同一份载体 + 同一批候选**构建两份模型
（一份不带 `sourceScanStats`、一份带），逐项断言：

- `reportRows.map(\.cells)` —— ⑤ 页矩阵，`K` / `T` / `a` / `b` 都在里面；
- `pageLevelSlot` / `reportProduced` / `overviewBlocks`（`title` + `slot`）/ `totalFootprintBytes` / `remainingDays` / `canLightUp`；
- `confirmItemCount` / `confirmBytes` / `deferredCountSlot`。

**除 `sourceScanRows` 外全部逐槽相等**，且无统计时 `sourceScanRows` 为空。
这条断言比「跑完没崩」强：它是「统计不参与判定」的机器证据。

`SourceScanStatsTests.testNpxAndUvCountedIndependently` 用真 `ScanEngine` + `MemoryFS` 造**两棵形状不同**的树，
断言 `_npx` 与 `uv` 的项数各自独立、合计无损 —— 若统计把两棵树混算，断言立刻失败。

---

## 六、已知缺口（如实登记）

1. **只反映「本次扫描」**：统计不落 `state.residue`，进程重启后界面为空，直到下一次全量扫描。
   这是有意的 —— `state.residue` 的段表是 ABI，为一个诊断字段扩段不值得。
   需要历史对比时看 `scan.jsonl` 的 `sourceStats`。
2. **增量扫描的 `items` 是「复核条数」不是「目录项数」**：增量只复核已登记候选（CR-041 §2.1），
   数字比全量小一个量级，这是如实反映，不是统计错。界面上「本次扫描」标题已限定口径。
3. **耗时含冷缓存差异**：同一台机器两次扫描的耗时可能相差明显（页缓存命中率不同）。
   本单呈现的是「这一次」，不是「平均值」。
4. **`_npx` 仍然只增不减**：本单**不清理**，只让用户看见并能自助。台账状态从「未处理」改为
   「未处理，但已度量并如实呈现」。

---

## 七、落点穷举表

| 文件 | 落点 | 改什么 |
|---|---|---|
| `Sources/ResidueCore/SourceScanStats.swift` | 新文件 | `SourceScanStat` + `milliseconds(from:to:)` + `make(_:)` |
| `Sources/ResidueCore/SemanticSlot.swift` | L396 | `UICopy.scanSourceDuration(milliseconds:)`（两位小数，中英双版） |
| 同上 | L411 | `UICopy.npxCacheNote`（只增不减 + 用户自助命令 + 产品不代删） |
| `Sources/ResidueCore/PageModel.swift` | L306 | `PageModel.sourceScanRows: [SourceScanRow]` |
| 同上 | L349 | `struct SourceScanRow`（四列槽位） |
| `Sources/ResidueCore/PageModelBuilder.swift` | L58 / L95 / L115 | `Input.sourceScanStats`（缺省 `[]`） |
| 同上 | L470–489 | ⑦ 段：只读统计 → `sourceScanRows`（不参与任何判定） |
| `Sources/ResidueCore/RecordWriter.swift` | L54 / L133 / L146 | `ScanLogRecord.sourceStats`（缺省 `[]`） |
| `Sources/ResidueApp/AppModel.swift` | L131 | `ScanJob.sourceStats` |
| 同上 | L174–175 | `lastSourceScanStats`（重扫前清空语义） |
| 同上 | L493 | `rebuild()` 传 `isScanning ? [] : lastSourceScanStats`（扫描中不显示上一次的统计） |
| 同上 | L663 / L698–701 | `scanBegan` 计时 + 每来源追加统计 |
| 同上 | L897 / L912 | `make(...)` 排序后落 `scan.jsonl` |
| `Sources/ResidueApp/Pages.swift` | L1045–1090 | ⑦ 页「本次扫描 · 各来源」新节 |
| `Sources/ResidueApp/DesignSampleData.swift` | L310 | 7 行真实量级样例（供 `--render-pages`） |
| `Tests/ResidueCoreTests/SourceScanStatsTests.swift` | 新文件 | 7 个单测 |
| `Tests/ResidueCoreTests/PageModelBuilderTests.swift` | 类末 | 2 个单测（纯度自证 + 逐列正确性） |
| `README.md` | 已知限制 #9 | `_npx` 只增不减 + 用户自助命令 + 产品不代删 |
| `README.en.md` | Known limitations #9 | 同上（英文） |
| `docs/ledger/Residue-Phase3-闸门台账.md` | 实测节 + 诚实登记表 | 口径从「未处理」改为「已度量、如实呈现、不代删」 |

---

## 八、单测

| 用例 | 断言 |
|---|---|
| `testMillisecondsRoundsToNearest` | 6.789 s → 6789；1.2346 s → 1235（四舍五入不截断） |
| `testMillisecondsClampsNegativeToZero` | 时钟回拨 → 0，不出现负数 |
| `testMakeSortsByDurationDescending` | 耗时降序，`items` 跟着自己的来源走 |
| `testMakeBreaksTiesBySourceDeclarationOrder` | 同耗时按 `Source` 声明序，与输入顺序无关 |
| `testMakeKeepsUnknownSourceLast` | 未知来源不丢弃、排在最后 |
| `testDurationTextKeepsTwoDecimals` | 文案保留两位小数（`6.79` / `0.03`） |
| `testNpxAndUvCountedIndependently` | 真引擎 + `MemoryFS` 两棵不同形状的树 ⇒ `_npx` 与 `uv` 项数各自独立、合计无损 |
| `testSourceScanStatsDoNotChangeAnyJudgment` | 有无统计两份模型**逐槽相同**（除 `sourceScanRows`）—— 纯度自证 |
| `testSourceScanRowsCarryOwnItemsBytesAndDuration` | `_npx` 行的项数 / 候选体积（= 该来源候选字节之和）/ 耗时正确；builder 不重排 |

**单测总数**：575 → **584**（新增 9，`swift test` 实测 0 failures）。
已同步 `.github/workflows/ci.yml:5`、`.github/workflows/release.yml:211`、`README.md:196`、
`README.en.md:192`、`ARCHITECTURE.md:34 / 122 / 136`、`CLAUDE.md:20`、
`tests/contract/fixtures/doc_claims.json`（5 处 `declared`，只改数值）。

---

## 九、验收（实测）

| 命令 | 预期 | 实测 |
|---|---|---|
| `swift build` | 成功 | ✅ Build complete |
| `swift test` | 0 failures | ✅ **584 tests / 0 failures** |
| `python3 scripts/verify_codes.py` | 11 / 0 | ✅ 11 / 0 |
| `./scripts/verify_a9.sh` | 80 / 0 | ✅ 80 / 0 |
| `swift run --disable-sandbox ResidueApp --verify-wiring /tmp/wiring` | 117 / 0 | ✅ 117 / 0 |
| `./tests/contract/check_all.sh` | 191 + 47 | ✅ 191 + 47，声明一致 35 条 / 未覆盖 0 |
| `python3 tests/contract/verify_r2.py` | 123 | ✅ |
| `python3 tests/contract/verify_counts.py` | 全部一致 | ✅ |
| `python3 tests/contract/verify_doc_claims.py` | 全部一致 | ✅ |

---

## 十、导航项数同步

本单新增 1 份变更单。rebase 到 `origin/main`（含 #11 的 CR-044）后按实测重算：
`docs/` **147 → 148 份**；`docs/changes/` **68 → 69 份**；单号 **30 → 31 个**。

| 文件 | 旧 | 新 |
|---|---|---|
| `CLAUDE.md:11` | 147 份 | 148 份 |
| `CLAUDE.md:133` | 147 份 | 148 份 |
| `tests/contract/fixtures/doc_claims.json`（`docs_md`） | 147 | 148 |
| `ARCHITECTURE.md:87` | 68 份文件 / 30 个单号 | 69 份文件 / 31 个单号 |

> 分支开发期间 `ARCHITECTURE.md:87` 的份数声明一度落后实测 1 个（`66 / 28` vs 实测 `67 / 29`）。
> 本单按 rebase 后实测统一为 `69 / 31`；这是修正陈旧声明，不是新增口径。
