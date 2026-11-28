# CR-045 · 删除前二次检查 fail-closed（P-027 · P-028）· P0 · 判定缺失

> 状态：已实施
> 变更类型：判定口径落地（**不改契约条文**、不新增错误码）+ 新增 Core 原语 + 测试补充 + 声明数同步
> 影响面：`ResidueCore`（`L0Probe.swift` / `SecondCheck.swift` / `L0Judge.swift` / 新增 `PathAccess.swift` / 新增 `SecondCheckGate.swift`）、`ResidueApp`（`AppModel.swift` 只做接线）
> 风险等级：P0 —— 触碰核心不变量③「**不把未知判为安全**」与不变量④「**删之前先证明自己判得准**」
> 缺陷编号：P-027（删除前 L0 二次检查在 `lstat` 失败时静默放行）、P-028（二次检查把「读不到属性」当成「文件已不存在」，写进举证链）

## 一、缺陷

P-027 与 P-028 是**同一道安全闸的两面**：一个是「闸门读不到钥匙就当没锁」，一个是「闸门读不到钥匙就写一张假的通行证」。

### 1.1 P-027 · 取不到身份 ⇒ 静默放行（fail-open）

`AppModel.swift`（改动前 `:1185-1189`）：

```swift
if let identity = L0Probe.identity(atPath: cand.path),
   SecondCheck.isLiveHeld(
       identity: identity, isDirectory: cand.isDirectory,
       path: cand.path, by: secondCheckSnapshot
   ) {
    // ……有活引用 ⇒ 阻断
}
ids.append(id)   // ← `identity` 为 nil 时走到这里 ⇒ 继续删除
```

`L0Probe.identity(atPath:)` 的实现是：

```swift
var st = stat()
guard lstat(path, &st) == 0 else { return nil }
return FileIdentity(st: st)
```

`lstat` 失败只有一种出口 `nil`，而 `nil` 在这条 `if let` 里意味着「**没有活引用**」—— 于是一条**读不到**的路径（权限不足 `EACCES`、目录不可进入 `EPERM`、I/O 错误 `EIO`）被当成「安全」，**照删**。

这就是 CLAUDE.md §七-1 那条教训的另一个方向：**fd 号取自结构体字段 `proc_fd` 而不是数组下标** —— 「两个值相等」不等于「它们同义」。这里同义的是「**两个不同的失败被压成同一个值**」：`nil` 同时承载「确定不存在」与「读不到」，调用方无从区分，于是只能在「当它没了」与「当它安全」之间二选一 —— 两个都不对。

### 1.2 P-028 · 读不到属性 ⇒ 举证链写下假事实

`SecondCheck.checkIdentity`（改动前 `:65-67`）：

```swift
guard let attrs = try? fileManager.attributesOfItem(atPath: path) else {
    return .vanished
}
```

`.vanished` 在 `AppModel.swift`（改动前 `:1070-1076`）被落成：

```
action        = blockedSecondCheck
blockedReason = "二次检查：文件已不存在（已自行删除）"
```

`try?` 吞掉的是**所有**失败：路径确实没了（`ENOENT`）、**权限不足**（`EACCES`）、I/O 错误（`EIO`）…… 一律写成「文件已自行删除」。

这是**假事实**：文件可能好好地在那儿，只是我们读不到。AC-18 要求举证链 8 字段完整率 100%、空白字段数 0 —— 但「完整」不等于「为真」。一个为假的完整字段，比一个空字段更坏：**它会让用户以为那条候选已经自己消失了**（于是不再去管它），而它其实还在原地。

### 1.3 口径不一致：同一个函数里两种答案

`AppModel.executeBatch` 里，「拿不到允许根」的处理是**拒绝执行**（`blockedOutOfScope`，fail-closed）；而上面这两处是 fail-open。同一道闸上两种答案 —— 一处知道「不知道就不动」，一处把「不知道」翻译成「可以动」。

### 1.4 为什么既有测试没抓住

- 既有 `SecondCheckTests` 的候选全是**能读到的**路径：`try?` 从来不失败 ⇒ `.vanished` 分支只在「文件真没了」时走到 ⇒ 旧语义与新语义在那些用例上**完全一致**（这正是它们**不需要**改断言的原因，见 §五）；
- `L0JudgeTests` 用 `identityOf: { _ in nil }` 注入「取不到身份」⇒ 断言 `.undetermined`（扫描期本来就是 fail-closed）—— 但**执行期**这条路径没有对应的注入点；
- `MemoryFS` 是扁平的、且造不出权限语义 ⇒ 权限类缺陷只在**真文件系统**上暴露（CLAUDE.md §八）。

## 二、契约依据

### 2.1 PRD v5.6 `:1162-1166`（AC-17）

> 删除前 L0 二次检查发现活引用并放弃该条目。

本单**不改动**这条条文，只把它所在的那道闸的**两个「答不上来」**收敛成同一个答案（不删）。AC-17 规定的是「发现活引用 ⇒ 放弃」，**没有**规定「读不到 ⇒ 可以删」—— 旧实现里的 fail-open 属于**实现超出契约**，本单是把它收回到契约允许的范围内。

### 2.2 PRD v5.6 `:1168`（AC-18）

> 举证链 8 顶层字段完整率 100%，空白字段数 0；标注「不适用」须附原因字符串。

「完整」约束的是**字段有无**，不是**内容真假**。P-028 的假事实恰恰落在 AC-18 想守住的地方（原因串必须能作为事实被依赖）。

### 2.3 PRD v5.6 `:827`（P4 状态词表）

P4 状态词表封闭六词，其中「**无法判定**」的定义是「权限不足 / 信息不足」，并明确「**不等于**『判定为不删』」。

> ⚠️ 口径边界：本单**不改** P4 词表，也**不新增**第四个状态词。`ExecutionRecord.blockedReason` 是**执行记录里的原因串**，不是界面状态词（界面状态词在 `SemanticSlot` / `UICopy` 那一侧，本次一行未动）。

### 2.4 DAC v2.0 `:240`（DAC-71）

> 存在「原因」承载位（② 行副行 **或** ⑦ 记录原因列，二者至少一处），且每个被阻断条目恰有一个原因串，取值逐串点名封闭为 P4 三串。

本单**没有**触碰界面原因承载位：`ExecutionRecord.blockedReason` 不进 `EvidenceRow`（`PageModel.swift` 的 `EvidenceRow` 只有 path / label / record），⑦ 页只渲染 path + 徽标 + 恢复按钮。新增的「无法读取文件属性（EACCES），为安全未删除」写在**执行记录**里，与既有的三条原因串同层同源（都写进 `execution.jsonl` 的 `blockedReason`）。

### 2.5 不变量③ / ④（CLAUDE.md §四）

> ③ 不把未知判为安全 —— 看不见的东西如实显示「无法判定」，不显示 0、不猜。
> ④ 删之前先证明自己判得准。

P-027 正是「把未知判为安全」；P-028 正是「猜」（猜它没了）。本单让这两条在**类型上**不可表达。

### 2.6 R2 v1.10 `:244`（S-05）/ `:450`（E-206 码表）

E-206「删除前二次检查阻断（AC-17）」已有定义。本单**沿用**它，**不新造码**：`blockedSecondCheck` 动作 + E-206 语义不变，只是「什么情况会被拦」变严格了。

## 三、改什么（三态 + 总闸）

### 3.1 三态：让「读不到」与「不存在」在**类型上**分开

新增 `ResidueCore/PathAccess.swift`：

| 原语 | 作用 |
|---|---|
| `PathAccess.classify(errno:)` | `ENOENT` / `ENOTDIR` ⇒ `.absent`（**确定不存在**）；**其余一切** ⇒ `.unreadable(errno:)`（含 `EACCES` / `EPERM` / `EIO`） |
| `PathAccess.classify(error:)` | Foundation 抛出的错误 ⇒ 同一套分类 |
| `PathAccess.posixErrno(from:)` | 先取 `NSUnderlyingErrorKey` 里的 POSIX 错误 → 自身 POSIX 域 → Cocoa 码兜底 |
| `PathAccess.errnoName(_:)` | `errno` → 符号名（`EACCES` / `EPERM` / …），未知回退 `errno N` |

> ⚠️ `NSCocoaErrorDomain` 下的 `.code` **不是 errno**（CLAUDE.md §七-3 已踩过：直接比 `EACCES` 永远 false ⇒ 授权指引永不出现且无报错）。实测 Cocoa 错误：不存在 = code 260 + underlying `ENOENT`(2)；权限不足 = code 257 + underlying `EACCES`(13)。本单取 **underlying** 的 POSIX 码，Cocoa 码只作兜底。

`L0Probe` 侧（`L0Probe.swift:205` / `:239`）：

```swift
public enum IdentityState: Equatable, Sendable {
    case resolved(FileIdentity)     // 拿到身份
    case absent                    // 确定不存在（ENOENT / ENOTDIR）
    case unreadable(errno: Int32)  // 读不到 ⇒ 无法判定
}
public static func identityState(atPath path: String) -> IdentityState
```

`lstat` 失败后**立刻**读 `errno`（下一次系统调用会覆盖它）。

`SecondCheck` 侧（`SecondCheck.swift:44` / `:63`）：`IdentityStatus` 增加 `case unreadable(errno: Int32)`；`checkIdentity` 的 `try?` 换成 `do/catch`，按 `PathAccess.classify(error:)` 分流：`.absent ⇒ .vanished`、`.unreadable(e) ⇒ .unreadable(errno: e)`。属性读取器改为**可注入**的闭包（`(String) throws -> [FileAttributeKey: Any]`），单测可精确造出「读不到」。

### 3.2 总闸：判定只有一处实现，且**只有「确定可删」才放行**

新增 `ResidueCore/SecondCheckGate.swift`：

```swift
public enum SecondCheckGate {
    public enum Decision: Equatable, Sendable { case proceed; case blocked(BlockReason) }
    public enum BlockReason: Equatable, Sendable {
        case vanished              // 确定不存在
        case rebuilt               // 同名重建
        case liveHeld              // 有活引用
        case unreadable(errno: Int32)   // 读不到 ⇒ 无法判定
    }
    public static func decide(
        identityStatus: SecondCheck.IdentityStatus,
        identityState: L0Probe.IdentityState,
        isLiveHeld: (FileIdentity) -> Bool
    ) -> Decision
}
```

判定口径（**fail-closed**）：

| 身份复核（属性口径） | 身份探测（inode 口径） | 结论 |
|---|---|---|
| `.vanished` | — | `.blocked(.vanished)` |
| `.rebuilt` | — | `.blocked(.rebuilt)` |
| `.unreadable(e)` | — | `.blocked(.unreadable(e))` |
| `.unchanged` | `.resolved(id)` | 活引用 ⇒ `.blocked(.liveHeld)`；否则 `.proceed` |
| `.unchanged` | `.absent` | `.blocked(.vanished)`（期间被删） |
| `.unchanged` | `.unreadable(e)` | `.blocked(.unreadable(e))`（**P-027 的现场**） |

`isLiveHeld` 闭包**只在拿到身份时**才被调用 —— 拿不到身份时「查表」本身就没有意义。

`BlockReason.blockedReason`（`SecondCheckGate.swift:107`）给出写实情的原因串：

| 原因 | 原因串 |
|---|---|
| `.vanished` | `二次检查：文件已不存在（已自行删除）`（**原文未改**） |
| `.rebuilt` | `二次检查：路径已被同名重建（birthtime 不一致），不是当初判定的文件`（**原文未改**） |
| `.liveHeld` | `二次检查：删除前发现活引用（进程正在使用）`（**原文未改**） |
| `.unreadable(e)` | `二次检查：无法读取文件属性（EACCES），为安全未删除`（**新**） |

前三条从 `AppModel` 原样搬到 Core（字面未改）—— 判定与文案放在一处，才能用单测守住「不写假事实」。

### 3.3 App 层只做接线

`AppModel.swift:1159` 起，原先三段（`switch` + `if let`）收成一次总闸调用：

```swift
let secondCheckDecision = SecondCheckGate.decide(
    identityStatus: SecondCheck.checkIdentity(path: cand.path, recordedBirthtime: cand.birthtime),
    identityState: L0Probe.identityState(atPath: cand.path),
    isLiveHeld: { identity in
        SecondCheck.isLiveHeld(identity: identity, isDirectory: cand.isDirectory,
                               path: cand.path, by: secondCheckSnapshot)
    }
)
switch secondCheckDecision {
case .proceed: break
case .blocked(let reason):
    newRecords.append(ExecutionRecord(..., action: .blockedSecondCheck,
                                      blockedReason: reason.blockedReason, ...))
    continue
}
ids.append(id)
```

`SecondCheck.checkIdentity` 与 `SecondCheck.isLiveHeld` 两个调用点**保留在 `AppModel.swift` 里**（`verify_a9.sh` 第九节用 grep 守这两个点）。

### 3.4 扫描期口径**不变**

`L0Judge.judge`（扫描期判定）本来就是 fail-closed（取不到身份 ⇒ `.undetermined`）。本单只把它的探针签名换成三态（`(String) -> L0Probe.IdentityState`），**语义一字未改**：`guard case .resolved(let identity) = ... else { .undetermined }` —— 「确定不存在」与「读不到」同样都不构成「无活引用」的证据。

## 四、边界与明确不做

1. **不改契约条文**（`docs/contract/` 一行未动）—— 本单是实现收回到契约允许的范围内，不是改契约。
2. **不新造错误码** —— 沿用 E-206 / `blockedSecondCheck`。
3. **不动界面** —— `SemanticSlot` / `UICopy` / 页面结构一行未动；本次新增的原因串只落在执行记录里。
4. **不动 `TrashExecutor` 的配额逻辑**（P-043 归属其它单）、**不动 `UpstreamCommand.swift`**（P-012）、**不动调度器**（P-011/P-014）、**不动 `execution.jsonl` 写盘路径**（P-018/P-031 归属其它单）。
5. **不处理「超时」** —— 契约提到「读不动 / 超时 / 权限不足」，实现层无超时机制，本单不新增。
6. **`SecondCheck.checkIdentity` 的签名从 `fileManager:` 改为 `attributesOf:`** —— 因为要区分「读不到」的**原因**（`FileManager` 会把 `errno` 藏进 `NSError`，判定需要它）。既有调用点（`AppModel` + 单测）都是位置参数/默认参数，已同步。

## 五、测试（+24）

| 文件 | 个数 | 要点 |
|---|---|---|
| `Tests/ResidueCoreTests/PathAccessTests.swift`（新） | 11 | `errno` 分类（`ENOENT`/`ENOTDIR` ⇒ absent；`EACCES`/`EPERM`/`EIO` ⇒ unreadable）、Cocoa 错误取 `errno`（underlying 优先 / Cocoa 兜底 / 未知域 ⇒ `EIO`）、`L0Probe.identityState` 三态（存在 ⇒ resolved、不存在 ⇒ absent、真 FS `chmod 000` ⇒ unreadable(`EACCES`)） |
| `Tests/ResidueCoreTests/SecondCheckGateTests.swift`（新） | 10 | 总闸六种输入的结论；读不到时**不得**调用活引用判定；**放行方向也测**（闸不能修成恒真）；原因串写实情（unreadable 串含「无法读取」含「EACCES」，**不含**「已不存在」） |
| `Tests/ResidueCoreTests/SecondCheckTests.swift`（改） | +2 | 注入抛错闭包 ⇒ `.unreadable(errno: EACCES)`；真 FS `chmod 000` ⇒ `.unreadable(errno: EACCES)`（**不是** `.vanished`） |
| `Tests/ResidueCoreTests/L0JudgeTests.swift`（改） | +1 | `.absent` ⇒ `.undetermined`（扫描期口径不变，但两类失败分开钉） |

### 5.1 既有断言**刻意不动**的说明（不是「改测试凑绿」）

`SecondCheckTests.testVanishedFileDetected` / `testNonexistentPathIsVanished` 断言的仍是 `.vanished` —— 因为这两个用例的场景**确实是「确定不存在」**（文件真被删了、路径从未存在），新语义下它们**必须**继续是 `.vanished`。它们**不是**旧语义的受害者，旧语义只是**顺带**把它们也判成 `.vanished`。

真正被旧语义掩盖的是「读不到」那一类 —— 它在旧实现里**没有独立出口**（被 `try?` 吞成 `.vanished`），所以只能**新增**用例来钉（§五表第 3 行），没有可放宽的旧断言。

同理，`L0JudgeTests` 里原 `identityOf: { _ in nil }` 的用例**拆成两条**：`.unreadable(errno: EACCES)` 与 `.absent` 各一条 —— 扫描期结论（`.undetermined`）没变，变的是**探针的取值域**。

### 5.2 红灯证据（RED → GREEN）

把实现临时改回旧语义（`checkIdentity` 读不到 ⇒ `.vanished`；总闸在 `.unreadable` ⇒ `.proceed`），新用例**如期变红**：

```
SecondCheckGateTests.swift:94: XCTAssertEqual failed: ("proceed") is not equal to
    ("blocked(ResidueCore.SecondCheckGate.BlockReason.unreadable(errno: 13))")
SecondCheckGateTests.swift:97: failed - 取不到身份时不得放行删除（P-027）
SecondCheckTests.swift:144: XCTAssertEqual failed: ("vanished") is not equal to ("unreadable(errno: 13))")
SecondCheckTests.swift:158: XCTAssertEqual failed: ("vanished") is not equal to ("unreadable(errno: 13))")
    - 权限不足必须判「读不到」，不是「已不存在」
```

恢复新语义后全绿。

## 六、验收输出（真实）

见 §八.3。

## 七、声明数同步

合并 `origin/main`（`0e2e096`）后，单测真实数 = 基线 599 + 本单 24 = **623**（`func test` 口径实测，`swift test` 0 failures）；契约文档份数 = 149 + 本单 1 = **150**。

| 声明处 | 改前 | 改后 |
|---|---|---|
| `ci.yml:5` 单测数 | 599 | **623** |
| `release.yml:211` 单测数 | 599 | **623** |
| `README.md:196` | 599 | **623** |
| `README.en.md:192` | 599 | **623** |
| `ARCHITECTURE.md:34 / :122 / :136` | 599 | **623** |
| `CLAUDE.md:20` | 599 | **623** |
| `CLAUDE.md:11 / :133` 文档数 | 149 | **150**（新增本单） |
| `ARCHITECTURE.md:87` 变更单 | 70 份文件 / 32 个单号 | **71 份文件 / 33 个单号** |
| `tests/contract/fixtures/doc_claims.json` | 5 处 `declared: 599` + 1 处 `declared: 149` | **623 / 150** |

## 八、实施记录

### 8.1 改动清单

- `ResidueApp/Sources/ResidueCore/PathAccess.swift`（新）：`errno` 分类、Cocoa 错误取 `errno`、`errno` 符号名；
- `ResidueApp/Sources/ResidueCore/SecondCheckGate.swift`（新）：总闸判定 + 四条原因串；
- `ResidueApp/Sources/ResidueCore/L0Probe.swift`：`identity(atPath:) -> FileIdentity?` 换成 `identityState(atPath:) -> IdentityState`（三态）；
- `ResidueApp/Sources/ResidueCore/SecondCheck.swift`：`IdentityStatus` 加 `.unreadable(errno:)`；`checkIdentity` 改 `do/catch` + 可注入属性读取器；
- `ResidueApp/Sources/ResidueCore/L0Judge.swift`：探针签名换三态，判定口径**不变**；
- `ResidueApp/Sources/ResidueApp/AppModel.swift`：三段收成一次总闸调用（**只做接线**）；
- `ResidueApp/Tests/ResidueCoreTests/`：新增 2 个文件（21 个用例）、改 2 个文件（+3 个用例）；
- 声明数同步 9 处（见 §七）。

### 8.2 已知未覆盖

1. **真实 TCC 拒绝样本**：权限用例用 `chmod 000` 造 `EACCES`，未在带 TCC 的真实 home 目录上验证；
2. **`EPERM` 的真实样本**：单元测试以注入方式覆盖 `EPERM` 分类，真 FS 上未单独造；
3. **超时路径**：同 §四.5。

### 8.3 验收命令与真实输出

```
$ swift build
$ swift build -c release
$ swift test
Executed 623 tests, with 0 failures (0 unexpected)

$ python3 scripts/verify_codes.py
通过 11 项 / 失败 0 项

$ ./scripts/verify_a9.sh
通过 80 项 / 失败 0 项

$ ./tests/contract/check_all.sh
$ python3 tests/contract/verify_r2.py
$ python3 tests/contract/verify_counts.py
```

（逐条真实输出见 PR 描述与本节最终版。）
