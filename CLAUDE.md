# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 一、这是什么

**Residue** —— macOS 菜单栏 App（Swift 6 / SwiftUI / macOS 14+ / 仅 arm64 / 零第三方运行期依赖）。

看清 `uv` / `npm(npx)` / `pipx` 在本机留下的缓存，只读统计 → **14 天影子观察期**证明自己判得准 → 才允许动手，且动手只做**原子 rename 到废纸篓**。

代码在 `ResidueApp/`；`docs/` 下 133 份 `.md` 是**契约文档**，不是笔记 —— 见 §五。根目录只留 `README.md` / `ARCHITECTURE.md` / `CLAUDE.md` 三份导航文件。

## 二、常用命令

全部命令在 `ResidueApp/` 目录下执行（SwiftPM 包根）。

```bash
swift build                      # 编译
swift build -c release           # Release 会裁掉 #if DEBUG 的自检入口，必须单独验
swift test                       # 全部单测（当前 276 个）
swift test --filter "MetricsTests"                                    # 跑一个测试类
swift test --filter "ResidueCoreTests.MetricsTests/testThresholdIsMinOf30AndTotal"  # 跑单个用例

python3 scripts/verify_codes.py   # 错误码表 ↔ 文档一致性（11 项）
./scripts/verify_a9.sh            # 页面结构 + 界面禁算术 + 数据层接线 + 空实现（当前 72 项）
swift run --disable-sandbox ResidueApp --verify-wiring /tmp/wiring   # 接线自检（真 IO 往返，当前 45 项）
swift run --disable-sandbox ResidueApp --render-pages design-renders # 重渲染 16 张设计稿
./scripts/make_app.sh             # 产出 build/Residue.app + .zip（无证书时 ad-hoc 签名）
./scripts/verify_a5.sh            # 产物结构校验（需先跑 make_app.sh）
```

**文档基线校验**在 `tests/contract/`，脚本从自身位置推导仓库根，任意 cwd 都能跑：

```bash
./tests/contract/check_all.sh        # PRD v5.5：4 个脚本（结构落点 191 + CR-022 47 + 声明归零 + 单一定义）
python3 tests/contract/verify_r2.py  # R2 v1.8：结构 30 + 落地 65 + 归零 16 + 一致 10 + 自洽 2
```

`check_all.sh` 与 `verify_r2.py` 都**自动发现最新版本号**（不写死），新增版本文档后无需改脚本。历史版校验脚本（`verify3.py`…`verify18.py`、`verify_claims.py`、`verify_cr022.py`、`verify_single_def.py`）同放此处，保留备查。

跑 GUI：`swift run ResidueApp`（菜单栏常驻，无 Dock 图标）。

## 三、代码架构

### 分层

```
ResidueApp/
├── Sources/ResidueCore/    纯逻辑，零 UI 依赖 —— 所有判定、算术、序列化都在这里
├── Sources/ResidueApp/     SwiftUI 界面 + IO 编排（AppModel）
├── Tests/ResidueCoreTests/ 单测只覆盖 ResidueCore
└── scripts/                打包与契约校验脚本
```

**依赖方向单向**：`ResidueApp` → `ResidueCore`，反之绝无。Core 里出现任何 SwiftUI / AppKit 引用即为违规。

### 数据流

```
AppModel（@MainActor，编排层）
  ├─ 扫描 ─→ Task.detached { ScanEngine + L0Probe }   ← 必须离开主 actor
  ├─ 判定 ─→ GateEvaluator（Core）      「能不能点亮」
  ├─ 聚合 ─→ PageModelBuilder（Core）  「每页显示什么」
  └─ 渲染 ─→ PageModel → SemanticSlotView（SwiftUI）
```

**AppModel 只做编排，不做判定、不做算术。** 判定在 `GateEvaluator`，聚合/格式化在 `PageModelBuilder`。

### 关键文件

| 文件 | 作用 |
|---|---|
| `Core/Metrics.swift` | M1–M6 六个指标的唯一算式。`T`/`K`/`J`/`a`/`b` 定义在此 |
| `Core/SemanticSlot.swift` | 「界面禁止算术」的**类型级**实现 + `UICopy`（契约文案唯一样式串） |
| `Core/ScanEngine.swift` | 两阶段扫描、断点续扫、来源路径匹配 |
| `Core/L0Probe.swift` | 活引用判定（`proc_pidinfo` / `proc_pidfdinfo`），文件身份 = `(dev, ino)` |
| `Core/TrashExecutor.swift` | 只做 `moveItem`，**全文无 `rm`/`unlink`**（可 grep 验证） |
| `Core/ResidueStateFile.swift` | `state.residue` 二进制载体：Magic `RSD1` + 段表 + CRC32 |
| `Core/DiagnosticCode.swift` | 24 个错误码的唯一定义处（`E-101`…`E-501`），带 §8 归类 |
| `Core/Preferences.swift` | 运行期偏好 + `CollectionPolicy`（三状态采集判定，写错会锁死产品） |
| `Core/SchedulePlanner.swift` | 定时排程纯函数，含确定性抖动（不用随机数——随机不可单测） |
| `App/AppModel.swift` | 真实 IO 编排层 |
| `App/WiringSelfCheck.swift` | `--verify-wiring` 入口（**DEBUG-only**） |
| `App/PageRenderer.swift` | `--render-pages` 入口（**DEBUG-only**） |

### 落盘位置

`~/Library/Application Support/Residue/` 下：

- `state.residue`（+ `.bak` / `.tmp` / `.corrupt`）—— 观察期进度、误判记录、位图。**不含文件名清单**
- `records/{execution,scan,evidence}.jsonl` —— 执行记录、扫描日志、举证链
- `preferences.json` —— 运行期偏好
- `state/schedule.json` —— 排程运行期态

## 四、核心设计不变量

改动前必须理解这五条 —— 它们被脚本与测试守着，破坏它们不会立刻报错，但会让产品静默退化。

### 1. 界面禁止算术（类型级约束）

界面拿到的只能是**已算好的字符串**。`SemanticSlot` 是封闭枚举，不接受闭包、不接受算术表达式；`K`/`T`/`a`/`b` 全部在 Core 侧算好再传下去。

`verify_a9.sh` 第二节用 grep 拦下视图层里对域内度量（`slotCount`/`countedDays`/`missCount`/`pNowCount`…）的运算，以及 `/ 1024`、`* 100` 这类第二套算法。

### 2. 同一判定只有一个实现处

判定、算术、格式化各自只能有一处实现。要加新逻辑，先确认不是在写第二套。

### 3. 不把未知判为安全

看不见的东西如实显示「无法判定」，**不显示 0、不猜**。`.unavailable` 是正式槽位值；`nil ≠ 0`（`nil` → 「—」，0 会被读成「今天到期」）。

跨 uid 进程恒 `EPERM` 是 APFS/TCC 正常行为 → 计入 `coverage.statOtherUID`（不上界面），**不计入** `degraded`。`degraded = true` 仅当「同 uid 进程枚举失败」。

### 4. 删之前先证明自己判得准

14 天影子观察期不是可选项。门槛（`GateEvaluator.isQualified`）：观察期已满 ∧ `K ≥ H` ∧ `a = 0` ∧ `b ≥ 1`，且判定域非空。观察期不可跳过。

### 5. 删除只做 rename 到废纸篓

`TrashExecutor` 只 `moveItem` 到 `~/.Trash`，**从不直接删除**。恢复 = 从废纸篓 rename 回原路径（`execution.jsonl` 里的 `restorePath` 是唯一依据）。

上游命令（`UpstreamCommand.swift`）是**封闭白名单**，只允许只读定位命令；不在白名单的一律拒绝。**每次调用必须落一行**到 `scan.jsonl` 的 `upstreamCommands` —— 未落盘即「无法证明」，验收按不通过处理。

## 五、文档是验收依据，不是背景介绍

`docs/` 下 133 份 `.md` 分四类，各占一个目录：

| 目录 | 类别 | 例子 | 约束 |
|---|---|---|---|
| `docs/contract/` | **契约基线** | `Residue-PRD-v5.5.md`、`Residue-R2-技术方案-v1.8.md`、`Residue-视觉基线-v1.1.md`、`Residue-DAC-v2.0.md`、`Residue-B1-功能用例集-v1.0.md` | 改它需要**变更单** |
| `docs/changes/` | **变更单** | `Residue-CR-0xx-*.md` | **冻结后的唯一修改入口**。无单号的改动判无效 |
| `docs/reviews/` | **评审单** | `Residue-CR-009-终审单-{架构,设计,质量}-第N轮.md` | 结论只有「通过 / 不通过」 |
| `docs/ledger/` | **运行期记录** | `Residue-Phase3-闸门台账.md`（当前真实状态）、`Residue-A10-发布准入执行单-v1.0.md` | |

校验脚本在 `tests/contract/`（见 §二）。历史文档内部仍以裸文件名互相引用 —— 那是**当时决策的记录**，不随目录迁移改写。

**代码与文档对不上就是缺陷**，不是「文档过时了」。

- 新增来源 → 改 `Source` 封闭枚举 + `SourceRule.defaults`，须出变更单
- 新增错误码 → 改 `DiagnosticCode`，`verify_codes.py` 会核对码表 ↔ R2 §6
- 新增/修改界面文案 → 改 `UICopy`，`verify_a9.sh` 第四节逐字核对

## 六、CI 验什么 / 不验什么

`.github/workflows/ci.yml`（macOS-15 / arm64）按序跑：编译 → release 编译 → 单测 → 码表 → a9 → 接线自检 → 打包 → a5 → PRD 基线 → R2 基线 → 重渲染设计稿。

**CI 绿 ≠ 可发布。** 验不了的六项（需外部资源，属 A-10 发布准入）：公证、钉票、`spctl` 通过、干净机装机、GUI 交互/滚动/焦点可达性、回滚演练。

未公证产物文件名带 `UNNOTARIZED` —— 名字是唯一会被真正看见的声明。

## 七、踩过的坑（改代码前先看）

这些是本仓库真实踩过并修好的，写测试时不要重新踩：

1. **`fd` 号取自结构体字段 `proc_fd`，不是数组下标。** 本机 fd 恰好连续 → 下标与 fd 号数值相同 → 实测「通过」；CI runner 上不连续 → 立刻错位 → **可误删活文件**。教训：**「两个值相等」不等于「它们同义」**，测试要造出能区分两者的样本。
2. **`PROC_PIDFDVNODEPATHINFO` 返回的是 `vnode_fdinfowithpath`（1200 B），不是 `vnode_info_path`。** 误解析会读出 `dev=1, ino=0` 的垃圾值 → L0 恒判「无活引用」→ 误删正在被使用的文件。缓冲区传 < 1200 B 会 `ENOMEM` 失败。
3. **`(error as NSError).code` 在 `NSCocoaErrorDomain` 下不是 errno。** 直接比较 `== EACCES` 永远 false → `E-108` 一次都不会抛 → 授权指引永远不出现，且**没有任何报错**。
4. **断点续扫的粒度是「叶子条目名字集合」，不是字典序水位。** APFS `readdir` 是哈希序，字典序水位会漏掉 70% 候选。目录**每次都要重新枚举**（只跳过已完成的叶子），否则未扫完的子树永远不被遍历。
5. **cwd 祖先判定方向**：契约要「候选是 cwd 的祖先」（`isAncestor(path, of: cwd)`），写反了会删掉正在被工作的目录。原测试按错误方向写断言 → **测试把 bug 当成了规格**。
6. **JSONEncoder / JSONDecoder 的 `dateEncodingStrategy` 必须成对。** 不对称 → `save` 成功、`load` 永远失败 → 偏好永远存不住，**完全静默**。
7. **`b`（L0 检查次数）≠ `pNowCount`（被持有数）。** 混为一谈时「缓存满满但没人用」这种最理想场景会 `b = 0` → 门槛永远不满足。
8. **`@MainActor` 类上的 `async` 函数不会自动离开主线程。** 扫描是重 I/O（实测两来源合计约 13 s）→ 必须 `Task.detached` + 进度汇报 + 可取消，三件缺一不可，否则都是「卡住」。

## 八、提交与工作流约定

- 分支：`main` 为基线，功能分支用 `gztcode/*`。
- commit message：`fix(scope): 中文描述` / `docs: ...` / `fix(test): ...`，描述里带上级别与根因（如 `P0 · 会删掉正在被工作的目录`）。
- **CI 的 shell 必须开 `pipefail`。** 本仓库曾因 `swift test | tail -40` 吞掉退出码，导致 workflow「永远绿」= 没有 CI。
- **不要在 `swift test` 输出上加 `| tail -N`** —— 失败时详情被截掉，排障看不到关键行。
- 改代码时优先**先写能复现的测试**（尤其真文件系统相关：`MemoryFS` 是扁平的，永远不会递归，很多缺陷只在真 FS 上暴露）。
- 不要在测试里复制生产解析逻辑（第二份实现会各自腐坏）；要造中间结果就把它提成生产的公开原语（如 `L0Probe.vnodeFDList`）。
