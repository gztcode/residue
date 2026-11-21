# CR-040 · `Source` 枚举声明序的隐式 ABI 显式化 + 机器守卫 · P0 · 中间插入一个 case 即静默误删

> 状态：已实施（代码 + 守卫 + 自证随本 PR 提交）
> 变更类型：契约层面的 **ABI 声明**（不改落盘格式、不改已有 `sourceIndex` 取值、不新增来源 case）
> 影响面：`ResidueCore`（`Metrics.swift` / `ResidueStateFile.swift`）、`ResidueCoreTests`（新增 `SourceABITests.swift`）、单测数声明 571 → 575
> 风险等级：P0 —— 触碰不变量④「删之前先证明自己判得准」；破坏方式**不报错、不告警**，只是把 `a` 归错来源

---

## 一、缺陷

### 1.1 现象

`state.residue` 的段表用 `sourceIndex u8` 索引来源（`ResidueStateFile.swift` §5.1 格式），
而这个字节的历史取值就是 `Source` 枚举的**声明序**：

```swift
public enum Source: String, Codable, Sendable, CaseIterable {
    case uvCache = "uv_cache"              // sourceIndex 0
    case npmNpx = "npm_npx"                // sourceIndex 1
    case pipxRun = "pipx_run"              // sourceIndex 2
    case homebrewDownloads = "brew_downloads"          // 3
    case cargoRegistryCache = "cargo_registry_cache"   // 4
    case pnpmStore = "pnpm_store"          // 5
    case bunCache = "bun_cache"            // 6
}
```

也就是说：**枚举的声明顺序 = 落盘格式的一部分，但它长得像普通代码。**

若有人在枚举**中间**插入一个 case：

- 写方按新声明序写 `sourceIndex`，读方按新声明序反解 ⇒ **新旧载体的段索引整体错位**；
- 误判数 `a` 归到**错误来源** ⇒ 该来源的门槛判定用了别人的 `a` ⇒ 不变量④静默失效；
- 观察期重置**救不了**：`decisionDomainChanged` 分支走
  `performObservationReset(preservingMissCount: true)`，**保留 `a`** ⇒ 错位的值被原样留下。

### 1.2 现有守卫为什么不够

- `Source.decisionDomainSignature` 按 `allCases` 顺序拼接，顺序变了会触发重置 ——
  但它**只能触发重置，不能修正错位**，且重置保留 `a`。
- `verify_a9.sh` / `verify_codes.py` / `verify_r2.py` / `verify_counts.py` /
  `--verify-wiring` 里**没有一处**断言 `Source` 的 case 列表、顺序或落盘索引。
- `CLAUDE.md` §七 9 只有**文字约定**（「新 case 只能追加到枚举末尾」），没有机器判据。

### 1.3 活的触发源

PR #4（`gztcode/cr-032-brew-pip`）在同一位置新增 `brewCache` / `pipCache`，
若解决冲突时插在 `pipxRun` 之后（即现 main 四个新 case 之前），即命中本缺陷。

---

## 二、契约依据

- `CLAUDE.md` §四 不变量④「删之前先证明自己判得准」；§七 9「给 `Source` 枚举加新 case 只能追加到末尾」。
- `ResidueStateFile.swift` 文件头硬约束 1「段序固定」与读方「按 `(sourceIndex, kind)` 索引，不按位置猜」。
- **代码与文档对不上就是缺陷**（`CLAUDE.md` §五）—— 文字约定必须变成机器断言。

本单把这条约定升格为**契约层面的 ABI 声明**：
`sourceIndex` 的取值不是「恰好等于声明序下标」的巧合，而是 `Source.stableIndex` 的显式定义。

---

## 三、改什么

### 3.1 显式化：`Source.stableIndex`（`Metrics.swift`）

新增计算属性与反解构造器：

```swift
public var stableIndex: UInt8 { /* switch，逐 case 显式给出 0…6 */ }
public init?(stableIndex: UInt8) { /* allCases.first(where:)；未知 → nil */ }
```

- 已发布的值**永不可改**（同 `rawValue`）；新来源只能取**当前最大值 + 1**。
- **不改落盘格式**：段表仍是 `sourceIndex u8`，粒度、字节布局一律不动。
- **不改任何已有取值**：0…6 与历史文件逐位一致。

### 3.2 读写改走 `stableIndex`（`ResidueStateFile.swift`）

- 写方：`for source in Source.allCases { let index = source.stableIndex }`
  （原来取 `enumerated()` 的序号）。
- 读方：`guard let source = Source(stableIndex: seg.sourceIndex) else { throw E-304 }`
  （原来用 `sourceList[Int(seg.sourceIndex)]`）。

语义等价、字节产物逐字节不变（`testEncodeIsDeterministic` 仍绿），
但映射从「隐式下标」变成「唯一显式入口」。

### 3.3 机器守卫：`ResidueCoreTests/SourceABITests.swift`（4 条）

| 用例 | 守什么 | 失败场景 |
|---|---|---|
| `testSourceDeclarationOrderIsFrozenABI` | 冻结表 `(rawValue, stableIndex)` 与 `allCases` 逐项相等 | **中间插入 / 换序 / 改值** |
| `testStableIndexIsContiguousBijection` | `stableIndex` = `0..<count` 连续双射、可反解、越界为 `nil` | 重号 / 跳号 / 反解串源 |
| `testStateFileIndexesGoThroughStableIndex` | 读取 `ResidueStateFile.swift` 源码，断言含 `stableIndex` / `Source(stableIndex:`，且**不含** `Source.allCases.enumerated()` 与 `sourceList[...]` | **有人绕过 `stableIndex` 写第二套映射** |
| `testSegmentIndexMapsBackToTheSameSource` | 每来源载荷 encode→decode 后仍回到同一来源 | 段索引错位（文件能读、`a` 归错） |

**为什么落在单测而不是新契约脚本**：`swift test` 已在 CI 与 release pre-flight 里跑，
天然生效、与任何进行中的分支零冲突；若再加一个 `tests/contract/verify_source_abi.py`
就会把「冻结表」写成第二份实现（各自腐坏）。本单遵守「同一判定只有一个实现处」。

---

## 四、影响面

| 文件 | 改动 |
|---|---|
| `ResidueApp/Sources/ResidueCore/Metrics.swift` | 新增 `stableIndex` / `init?(stableIndex:)` |
| `ResidueApp/Sources/ResidueCore/ResidueStateFile.swift` | 读写段索引改走 `stableIndex`；注释同步 |
| `ResidueApp/Tests/ResidueCoreTests/SourceABITests.swift` | 新增（4 个用例） |
| `CLAUDE.md` / `README.md` / `ARCHITECTURE.md`（×3） | 单测数 571 → 575 |
| `.github/workflows/ci.yml` / `release.yml` | 单测数 571 → 575 |

不动的：`Source` 枚举成员与顺序、`rawValue`、`SourceRule`、载体格式、`sourceIndex` 取值。

---

## 五、不做的事

- **不新增来源 case**（brew/pip 接入是 CR-032 的事，须单独出单）。
- **不改落盘格式**（schema 版本不变、段表布局不变）。
- **不写第二份**：不加平行契约脚本；不在 `check_all.sh` 里再判一次。
- 不顺手重构 `ResidueStateFile.swift` 的其它段处理。

---

## 六、验收判据

1. `swift build` 通过；`swift test` 0 failures（575）。
2. **自证红**：把 `npmNpx` 与 `pipxRun` 换序 ⇒ `SourceABITests` 失败（贴输出见 §七）。
3. **自证红（绕过）**：把写方改回 `Source.allCases.enumerated()` ⇒
   `testStateFileIndexesGoThroughStableIndex` 失败。
4. **自证绿**：两处还原 ⇒ 4/4 通过。
5. 其余验收链（码表 / a9 / 接线自检 / PRD 基线 / R2 / 计数）全绿。

---

## 七、实施记录

（以下输出为实施时实测；换序与绕过均为临时变异，已还原。）

### 7.1 换序 → 红

把 `npmNpx` / `pipxRun` 两个 case 对调后 `swift test --filter SourceABITests`：

```
SourceABITests.swift:50: error: -[... testSourceDeclarationOrderIsFrozenABI] :
  XCTAssertEqual failed: ("pipx_run") is not equal to ("npm_npx") -
  声明序第 1 位应是 npm_npx，实际 pipx_run —— 在枚举中间插入/换序会让存量载体的 sourceIndex 整体错位（载体 ABI 破坏）
SourceABITests.swift:55: error: -[... testSourceDeclarationOrderIsFrozenABI] :
  XCTAssertEqual failed: ("2") is not equal to ("1") -
  pipx_run 的落盘索引应为 1，实际 2 —— 已发布的 stableIndex 不可改
SourceABITests.swift:50: error: -[... testSourceDeclarationOrderIsFrozenABI] :
  XCTAssertEqual failed: ("npm_npx") is not equal to ("pipx_run") - 声明序第 2 位应是 pipx_run…
SourceABITests.swift:55: error: -[... testSourceDeclarationOrderIsFrozenABI] :
  XCTAssertEqual failed: ("1") is not equal to ("2") - npm_npx 的落盘索引应为 2，实际 1…
SourceABITests.swift:69: error: -[... testStableIndexIsContiguousBijection] :
  XCTAssertEqual failed: ("[0, 2, 1, 3, 4, 5, 6]") is not equal to ("[0, 1, 2, 3, 4, 5, 6]") -
  stableIndex 必须覆盖 0..<7 且不重不漏
Executed 4 tests, with 5 failures (0 unexpected)
EXIT=1
```

### 7.2 绕过 `stableIndex` → 红

把写方改回 `for (sourceIndex, source) in Source.allCases.enumerated()` 后
`swift test --filter "SourceABITests/testStateFileIndexesGoThroughStableIndex"`：

```
SourceABITests.swift:105: error: -[... testStateFileIndexesGoThroughStableIndex] :
  XCTAssertTrue failed - 写方必须用 source.stableIndex 落盘段索引
SourceABITests.swift:113: error: -[... testStateFileIndexesGoThroughStableIndex] :
  XCTAssertFalse failed - 发现 Source.allCases.enumerated() —— 段索引不得依赖声明序下标这个隐式巧合
EXIT=1
```

### 7.3 还原 → 绿

两处还原后：

```
swift test --filter SourceABITests
Executed 4 tests, with 0 failures (0 unexpected)
EXIT=0

swift test
Executed 575 tests, with 0 failures (0 unexpected)
EXIT=0
```

### 7.4 rebase 到 main（含 #8）后复跑

§7.1–7.3 是分支刚建立时（基线 559）的实测。rebase 到 `fd45ee8` 后重做两组变异，命中面比原先更大 —— 换序后全量 575 个单测里 10 条断言失败、5 个用例变红；绕过写方后 2 条断言失败：

```
# 换序 npmNpx / pipxRun 后全量 swift test
Executed 575 tests, with 10 failures (0 unexpected)
EXIT=1
失败用例：PageModelBuilderTests.testOverviewBlocksAggregatePerSource
          SourceABITests.testSourceDeclarationOrderIsFrozenABI
          SourceABITests.testStableIndexIsContiguousBijection
          SourceExpansionTests.test_sourceRawValuesOfFirstThreeAreUnchanged
          SourceExpansionTests.test_sourceRootsResolveProducesSevenRoots
```

```
# 写方改回 Source.allCases.enumerated() 后全量 swift test
SourceABITests.swift:105: error: XCTAssertTrue failed - 写方必须用 source.stableIndex 落盘段索引
SourceABITests.swift:113: error: XCTAssertFalse failed - 发现 Source.allCases.enumerated() —— 段索引不得依赖声明序下标这个隐式巧合
Executed 575 tests, with 2 failures (0 unexpected)
EXIT=1
```

两处均已还原；还原后 `swift test` 575 / 0 failures、`--verify-wiring` 117 / 0 failures。
