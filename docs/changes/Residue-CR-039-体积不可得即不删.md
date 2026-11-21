# CR-039 · 体积不可得即不删（E-207 从死码变成可达路径）· P0 · 判定缺失

> 状态：已实施
> 变更类型：执行语义落地（**不改契约条文**，不改 `ExecutionRecord` 载体结构）+ 测试补充 + 文档就地标注
> 影响面：`ResidueCore`（`TrashExecutor.swift`）；`docs/contract/Residue-R2-技术方案-v1.10.md` §6.3.5 第 3 条
> 风险等级：P0 —— 触碰核心不变量③「**不把未知判为安全**」。读不动的目录按「读到的部分」计价，等于让硬上限建立在猜测上

## 一、缺陷

### 1.1 现象

`recursiveLogicalBytesResult(atPath:)` 一直返回二元组 `(bytes, unreadable)`：

- `bytes` —— 读到的递归逻辑字节；
- `unreadable` —— 读不动的条目计数（权限不足、枚举失败等）。

但 `TrashExecutor.execute(...)` 只取 `bytes`，**`unreadable` 在拿到后即被丢弃**。后果链条：

1. 候选目录里只要有一个子项读不动（如 `chmod 000` 的子目录、TCC 拒绝），`bytes` 就是**偏小**的；
2. 这个偏小的值照常参与「预检 ≤ 上限」，并照常 `moveItem` 到废纸篓；
3. 契约要求「宁可少删，不可让上限失效」—— 而这里恰恰是**拿未知当已知**，硬上限 Σ measured ≤ `capacityCap` 的分子被低估；
4. `DiagnosticCode.e207` 与 `ExecutionAction.blockedSizeUnknown` 都**有定义、无产出点** —— E-207 是死码。

R2 v1.10 §25.4（历史评审记录）已如实登记过这一点：「`E-204`/`E-206`/`E-207` 连**产出点**都没有（`blocked_out_of_scope` / `blocked_second_check` / `blocked_size_unknown` 三个动作值有定义、**永不产出**）」。

### 1.2 复现路径（代码级）

```
候选目录/
├── payload.bin          ← 可读
└── locked/              ← chmod 000
    └── payload.bin
```

- `recursiveLogicalBytesResult` 枚举到 `locked/` 时读不动 → `unreadable = 1`，`bytes` 只含 `payload.bin`；
- 旧实现不看 `unreadable` → 照常 rename 到 `~/.Trash`；
- `execution.jsonl` 记为 `renameToTrash`，`bytes` 偏小。

### 1.3 为什么既有测试没抓住

- 既有用例的候选都是**全可读**目录，`unreadable` 恒为 0，分支从未被走到；
- `MemoryFS` 是**扁平**的、不递归，权限语义也无法模拟 —— 这个缺陷只在真文件系统上暴露。

### 1.4 与其它单的关系

- **不是** IF-08 的 `t2` 超限回滚（那条已实现，见 CR-020/CR-024）：`t2` 讲的是「rename 之后实测超了怎么办」，本单讲的是「**rename 之前就不该动**」。
- **不是** `E-204`/`E-205` 那类历史死码清理：本单只让 E-207 可达，不顺手处理其它死码。

## 二、契约依据

### 2.1 R2 v1.10 `:239`（IF-07）

> - 递归量**读不动 / 超时 / 权限不足** → `E-207`，**该候选不入删除候选集**（宁可少删，不可让上限失效）。

### 2.2 R2 v1.10 `:240`（IF-07 失败列表）

> - 失败：`E-201` 源不存在 / `E-202` 废纸篓不可写 / `E-203` 跨卷 / `E-204` 符号链接或越界路径 / `E-205` 同名冲突无法消解 / `E-207` 体积不可得。

### 2.3 R2 v1.10 `:451`（错误码表）

> | `E-207` | 目录递归体积不可得 | 错误 | 「体积不可得，未删除」 |

### 2.4 CLAUDE.md 核心不变量③

> **不把未知判为安全**：看不见的东西如实显示「无法判定」，**不显示 0、不猜**。

### 2.5 措辞边界：**「该候选不入删除候选集」≠「本轮停止」**

IF-07 对两种失败用了不同措辞：

| 情形 | 契约措辞 | 实现动作 |
|---|---|---|
| 某候选体积不可得（E-207） | **该候选**不入删除候选集 | 只排除这一条，其余候选继续 |
| `t2` 实测超上限 | **本轮停止**后续删除 | 移回原位、`blocked_cap`、`break` |

本单严格按字面落地，**没有**把 E-207 升级成「停止本轮」。

## 三、改什么（代码链）

`unreadable` 从 `recursiveLogicalBytesResult` 一路带到 `execute`，闸门设在唯一的删除入口 `moveToTrash`。

| # | 位置 | 改动 |
|---|---|---|
| 1 | `moveToTrash(_:source:now:previewBytes:)` | 目录候选一律调 `recursiveLogicalBytesResult` 拿到 `(bytes, unreadable)`；`unreadable > 0` 时**在 `moveItem` 之前**返回 `blockedSizeUnknown` 记录 |
| 2 | 同上 | 记录字段：`action = .blockedSizeUnknown`、`blockedReason = DiagnosticCode.e207.summary`（「体积不可得，未删除」）、`restorePath = nil`、`bytesMeasuredAt = nil`、`bytes = 读到的部分`（**偏小、不可信，仅供排查**）、`bytesKind = .dirRecursive` |
| 3 | `execute(...)` | 收到 `.blockedSizeUnknown` 记录时：`records.append(rec)` + `continue` —— **不累加 `deletedBytes`、不做 `t2`、不 `break`** |
| 4 | `execute(...)` | 预检/`t1` 逻辑不变：仍把缓存值作为 `previewBytes` 传入，仍先做「累计 + 本条 > 上限 → 顺延」 |

### 3.1 为什么闸门放在 `moveToTrash`，而不是 `execute`

- **同一判定只有一个实现处**：`moveToTrash` 是公开的删除入口，直接调用它的测试/调用方与批量路径共享同一道闸门；放在 `execute` 会留下「直接调用绕过判定」的第二条路。
- `execute` 只做**路由**（识别记录、决定是否继续），不做判定 —— 与「AppModel 只编排」同构。

### 3.2 为什么**即使有缓存 `t1` 也必须重测一次**

`preflightBytes: [CandidateID: Int64]` 只携带**字节数**，不携带「读没读全」。若因为「已经有缓存值」就跳过检测：

- 缓存值本身就是当年用 `unreadable` 被丢弃的旧算法算出来的；
- 缺陷会以「看起来用了 t1、其实绕过了判定」的形式继续存活。

所以目录候选在 `moveToTrash` 里**无条件**重新 `recursiveLogicalBytesResult` 一次：缓存值只用于 `bytesPreview`（`t1`）与预检上限比较，**不用于**「可否删除」的判定。

### 3.3 没有动的地方（外科手术式改动）

- `t2` 的 `measureLogicalBytes(at: dest)` 与「实测超限 → 移回原位 + `blocked_cap` + 停止本轮」**一行未改**；
- `moveToTrash` 仍只做 `moveItem`，全文无 `rm`/`unlink`；
- `ExecutionRecord` 结构、`ExecutionOutcome` 字段未改；
- 非目录候选：`unreadable` 恒 0（单文件 `stat` 要么成功要么抛错），行为与改前一致。

## 四、边界与明确不做

| 项 | 处置 |
|---|---|
| 契约提到的「**超时**」 | **本次未覆盖**：`recursiveLogicalBytesResult` 没有超时参数，实现层也没有超时机制。契约措辞是「读不动 / 超时 / 权限不足」，本单只让「读不动 / 权限不足」可达。**如实登记，不假装覆盖** |
| 真实 TCC 拒绝样本 | 测试用 `chmod 000` 子目录模拟「读不动」；TCC 拒绝同样是 `unreadable += 1` 的路径，但未在测试里单列 |
| `E-204` / `E-205` 等历史死码 | **不碰**（不在本单范围，避免顺手重构） |
| `preflightBytes` 载体结构 | **不改**（不引入「可读性位图」这类第二套载体） |

## 五、测试（+4）

| 测试 | 位置 | 断言要点 |
|---|---|---|
| `testVolumeUnavailableCandidateIsSkippedAndRecordedWithE207` | `TrashExecutorTests.swift:759` | 走 `execute`：候选仍在原位、废纸篓为空、1 条 `blockedSizeUnknown` 记录、`blockedReason == DiagnosticCode.e207.summary`、`restorePath == nil`、`deletedBytes == 0`、`failures` 为空 |
| `testMoveToTrashReturnsVolumeUnavailableRecordWithoutStrandingItem` | `TrashExecutorTests.swift:805` | 直接调 `moveToTrash`：返回记录同上，且条目**未被挪走**（不产生「废纸篓里有、记录里没有」的孤儿） |
| `testVolumeUnavailableDoesNotStopRemainingDeletions` | `TrashExecutorTests.swift:827` | `[坏, 好]` 两候选：2 条记录，`[0]` 为 `blockedSizeUnknown`、`[1]` 为 `renameToTrash`，`deletedBytes` 只计好条目 —— 证明「只排除这一条」 |
| `testE207HasAProducingPath` | `DiagnosticCodeTests.swift:289` | **错误码可达性（防死码）**：在真实执行路径上产出 `blockedReason == DiagnosticCode.e207.summary` 的记录 |

测试辅助：`tearDown` 里 `restoreReadPermissions(under:)` 用两遍 `chmod 0o755` 恢复权限，保证 `chmod 000` 的临时目录可被清理（否则下一次跑测试会因残留目录失败）。

> 这 4 个测试是前任 worker 先写的。接单后逐条核对，**它们正确描述了契约**（`unreadable > 0` ⇒ 该候选不删且记录带 E-207），故**原样保留**，由实现去满足它们；断言未做任何放宽。

## 六、验收输出（真实）

> 以下为 rebase 到最新 `origin/main`（PR #6 已合入）后**重跑**的输出。

```
$ swift build
ok (build complete)

$ swift build -c release
ok (build complete)

$ swift test
Executed 564 tests, with 0 failures (0 unexpected) in 2.364 (2.392) seconds

$ python3 scripts/verify_codes.py
通过 11 项 / 失败 0 项

$ ./scripts/verify_a9.sh
通过 80 项 / 失败 0 项

$ swift run --disable-sandbox ResidueApp --verify-wiring /tmp/wiring
通过 117 项 / 失败 0 项

$ ./tests/contract/check_all.sh
通过 191 项
全部通过：9 条「已实删」声明的全文命中数均为 0
全部通过：未发现「新增定义但旧定义未删」的数量冲突
通过 47 项
✅ 全部校验通过

$ python3 tests/contract/verify_r2.py
✅ 全部通过（结构 30 + 落地 65 + 归零 16 + 一致 10 + 自洽 2）

$ python3 tests/contract/verify_counts.py
一致 9 项 / 不一致 0 项 / 未覆盖 4 项
✅ 全部一致
```

## 七、声明数同步

合并 `origin/main`（含 PR #6）后，单测真实数 = 基线 555 + 本单 4 + main 侧 N7 5 = **564**；接线自检 = main 侧 117（本单未改接线检查）。两处都不沿用任何一方分支的旧数字：

| 声明处 | 改前 | 改后 |
|---|---|---|
| `ci.yml:5` 单测数 | 555 | **564** |
| `release.yml:211` 单测数 | 555 | **564** |
| `README.md:195` | 555 | **564** |
| `README.en.md:191` | 560（main 侧已先行修正旧值 445） | **564** |
| `ARCHITECTURE.md:34 / :122 / :136` | 555 | **564** |
| `CLAUDE.md:20` | 555 | **564** |
| `CLAUDE.md:11 / :133` 文档数 | 143 | **144**（新增本单） |
| `ARCHITECTURE.md:87` 变更单 | 64 份文件 / 26 个单号 | **65 份文件 / 27 个单号** |

`verify_counts.py`：一致 9 项 / 不一致 0 项。

## 八、实施记录

### 8.1 起点与接手判定

- 起点：前任 worker 因 API 配额中断，留下 2 个测试文件改动（+219 行）、无实现改动；
- 接手动作：先 `git diff` 逐条读测试 → 判定「描述正确」→ **保留**，不重写、不放宽；
- 只补实现，让红灯转绿。

### 8.2 改动清单

- `ResidueApp/Sources/ResidueCore/TrashExecutor.swift`：`moveToTrash` 增加 E-207 闸门；`execute` 增加 `.blockedSizeUnknown` 路由；
- `ResidueApp/Tests/ResidueCoreTests/TrashExecutorTests.swift`：前任 +166 行，**未改**；
- `ResidueApp/Tests/ResidueCoreTests/DiagnosticCodeTests.swift`：前任 +53 行，**未改**；
- `docs/contract/Residue-R2-技术方案-v1.10.md` §6.3.5 第 3 条：就地标注已落地（**不改版本号**，沿用 v1.10 的 `〔v1.10 · CR-0xx〕` 就地标注惯例）；
- `docs/ledger/Residue-Phase3-闸门台账.md`：新增 2026-11-21 小节，关闭「`unreadable` 未按契约走 `E-207`」；
- 声明数同步 7 处（见 §七）。

### 8.3 验收命令与真实输出

全部命令已在实施后逐条执行，输出见 §六。补充两条口径说明：

- `swift test` **未加 `| tail`**（本仓库踩过「管道吞退出码 → CI 永远绿」的坑），失败详情不会被截掉；
- `verify_counts.py` 里有 4 项标为「未覆盖」（`--verify-wiring` 与 `verify_a5` 需编译产物/打包件，脚本不实测），**不假装通过**。

### 8.4 已知未覆盖

1. **「超时」路径**：契约提到「读不动 / 超时 / 权限不足」，实现层无超时机制，本单未新增 —— 需要给 `recursiveLogicalBytesResult` 加截止时间，属独立改动。
2. **真实 TCC 拒绝样本**：测试用 `chmod 000` 模拟，未在带 TCC 的真实 home 目录上验证。

### 8.5 与 R2 §25.4 的关系

§25.4 是**历史评审记录**（R3 契约评审当时的结论），**不改写**。本次只在 §6.3.5（实现层限制清单）就地标注「已落地」，让「当前真实状态」与「历史记录」各归其位。

### 8.6 合并前的 rebase 记录

PR #6 合入 `main` 后，本分支 rebase 到最新 `origin/main`。冲突只在声明数字行（`ci.yml` / `release.yml` / `ARCHITECTURE.md` / `CLAUDE.md` / `README.md`），按「两侧都不沿用」处理：rebase 完成后跑一次 `swift test` 取合并后的真实数 **564**，再统一写入全部声明处；接线自检取合并后的 **117**（main 侧 +6）。`TrashExecutor`、4 个测试与 R2 §6.3.5 无冲突，原样保留。
