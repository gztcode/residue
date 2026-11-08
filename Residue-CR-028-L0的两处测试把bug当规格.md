# CR-028 · L0 的两处「测试把 bug 当规格」

> **性质**：实现层 P0 缺陷 + 测试有效性缺陷
> **提出**：程必达（交付总监）
> **发现路径**：CR-027 末尾我写了「所有依赖本机布局的断言都要复核」，本轮执行该复核
> **PRD 影响**：**无**。不改 AC、不改判据定义 —— 本单是把实现**改回契约原样**。

---

## 为什么这两条比 CR-027 那三条更难发现

CR-027 的三条（fd 下标 / 管道吞退出码 / plutil 输出流）都有「外部信号」：
CI 会红、日志会异常、SHA 会对不上。**本轮这两条没有任何外部信号**：

- 测试全绿
- 校验脚本全绿
- 界面渲染正常
- 契约文档看起来"跟代码一致"

因为**断言、实现、注释三者自洽 —— 只是三者都与契约相反**。

> 一个错误被写进代码、写进注释、写进测试，它就获得了三重背书。
> 而唯一能反驳它的东西（契约原文）在另一个文件里，没人去对照。

---

## D-4 · cwd 判据方向写反（**P0 · 会删掉正在被工作的目录**）

### 契约原文（V6 定稿 · K2 裁定，R2 ADR-03）

> 「持有」判据 = 该候选的 `(dev, ino)` 出现在任一同 uid 进程的 fd 集合中，
> **或候选（目录）是任一同 uid 进程 cwd 的祖先路径**

即 `isAncestor(candidate, of: cwd)` —— **cwd 在候选里面**。

### 实现写成了

```swift
// 注释：「候选是某进程 cwd 的祖先（目录）」
for cwd in snapshot.cwdPaths where isAncestor(cwd, of: path)   // ← cwd 是候选的祖先
```

注释是对的，代码是反的。**注释和代码互相矛盾，但没人读出来** —— 因为 `isAncestor(cwd, of: path)`
读起来也像「cwd 在候选之前」，而参数名 `path` 与 `cwd` 的次序不显眼。

### 后果（两个方向完全不同）

| 场景 | 契约 | 原实现 | 实际影响 |
|---|---|---|---|
| 候选 `/a/b`，进程 cwd = `/a/b/c/d`（**在候选里工作**） | **判在用** | 判不出 | **把正在工作的目录整个 rename 进废纸篓** |
| 候选 `/a/b/c`，进程 cwd = `/a/b`（在外面） | 不判在用 | 判在用 | 只是少删一点，无害 |

第一行是灾难。而且它偏偏发生在**最典型的使用场景**：开发者在项目目录里跑着 `npm install`，
uv/npm 的缓存在上级目录 —— 产品把项目目录当缓存删了。

### 为什么原测试没抓到

原测试 `testDirectoryCandidateHeldWhenProcessCwdInside`：

```swift
snapshot.cwdPaths = ["/tmp/some/workdir"]        // cwd
let dirPath = "/tmp/some/workdir/sub"            // 候选在 cwd 之下
XCTAssertTrue(isHeld(..., path: dirPath, ...), "进程 cwd 是候选目录的祖先 → 判定为被持有")
```

**它把错误方向写成了断言**，还把错误方向写进了断言的说明文字里。

这就是「测试把 bug 当规格」：测试一旦按错误语义写，它就从"防线"变成了"背书"。
**而且它会让人更加确信自己是对的** —— 有测试为证。

### 修法

```swift
if isDirectory {
    for cwd in snapshot.cwdPaths where isAncestor(path, of: cwd) {
        return true
    }
}
```

同时把原测试改成契约语义，并**加一条反向断言**：

```swift
// 候选在 cwd 之下 → 契约不判在用。
// 这不是遗漏，是刻意取舍：若也判在用，那么任何进程只要 cwd 是 /Users/<user>，
// 家目录下所有缓存都不可删 —— 产品直接失效。
XCTAssertFalse(isHeld(..., path: "/tmp/some/workdir/sub", by: outside))
```

### 防再犯（`verify_a9.sh` 第十一节，2 项）

| 断言 | 内容 |
|---|---|
| 1 | `L0Probe.swift` 必须出现 `isAncestor(path, of: cwd)` |
| 2 | **活的代码行**里不得出现 `isAncestor(cwd, of:` |

---

## D-5 · `degraded = true` 分支零测试覆盖

### 问题

`degraded` 是 **AC-14 第一类（权限受阻）的唯一入口** —— 它一变真，④ 页四档就必须
给出「所缺权限 + 授权指引条目 ID」三要素。

而这条分支此前**一条测试都没有**。两个相关测试都是同义反复：

```swift
// testCrossUIDDoesNotSetDegraded
if snapshot.coverage.statOtherUID > 0 {
    XCTAssertGreaterThan(snapshot.coverage.statOtherUID, 0)   // ← 在 if 里断言自己 > 0
}

// testDegradedOnlyWhenSameUIDFails
if sameUIDTotal > 0 && sameUIDRead > 0 {
    XCTAssertFalse(snapshot.degraded)   // ← 只验「本机不降级」
}
```

两者**只在真机能观察到的方向做断言**。而「该降级时会降级」从未被验过。

**一条永远不为真的分支，等于没实现。** 它会在界面上表现为「AC-14 第一类的
授权指引永远不出现」，而所有测试全绿 —— 与 D-4 完全同构。

### 为什么必须靠注入

架构裁定（CR 里已确认）：「同 uid 进程 fd 枚举失败」在真机上**不可确定性构造**：

| 尝试 | 实测结果 |
|---|---|
| `chmod 000` 来源根 | 只撞 `E-101`（枚举 fd 跟来源目录权限无关） |
| `PT_DENY_ATTACH` 子进程 | `returned=360 errno=0`，不产生 EPERM |
| `sandbox-exec` | 本机会话被拒，且方向本就错 |
| 自然态 | `same=663`、失败 1 条、`errno=ESRCH`、**EPERM 计数 0** |

且架构明确裁定**不加第 7 个注入点**（注入点会改判定路径，违反 §9.5 边界）。

### 修法：抽 `ProcessProbe` 依赖注入点

```swift
public protocol ProcessProbe: Sendable {
    func fdList(pid: pid_t) -> FDList
    func identity(pid: pid_t, fd: Int32) -> FileIdentity?
    func cwd(pid: pid_t) -> String?
}

public struct SystemProcessProbe: ProcessProbe { /* 真实系统调用 */ }
```

`snapshot(probe:processTable:)` —— 两个都可注入，默认走真实。

**这不动判定逻辑，只换数据来源**。判定分支（`uid != myUID` 跳过 / `errno == EPERM` 降级）
一行没改，只是现在能喂给它想要的输入。

### 新增 10 条测试（`L0SnapshotAssemblyTests.swift`）

| # | 测试 | 验什么 |
|---|---|---|
| 1 | `testDegradedWhenSameUIDEnumerationFails` | **EPERM → degraded = true**（此前从未验过） |
| 2 | `testNotDegradedWhenErrnoIsNotEPERM` | ESRCH（进程退出）不是权限问题 → 不降级 |
| 3 | `testCrossUIDNeverDegrades` | 跨 uid 的 EPERM 不得计入（否则多人机器永远降级） |
| 4 | `testOnePermissionFailureDegradesWholeSnapshot` | 一个读不到即整体降级，**但已读到的身份仍保留** |
| 5 | `testEmptyProcessTableIsNotDegraded` | 空表 ≠ 读失败（两者混同会把空环境误判成权限问题） |
| 6 | `testExcludedOnlyOpenerMeansNotHeld` | 只有排除者打开 → 不算被持有（自污染防护的核心） |
| 7 | `testExcludedPlusRealOwnerStillHeld` | 排除者 + 真实持有者 → **仍算被持有**（只删该 pid，不删整个身份） |
| 8 | `testSelfIsExcludedByDefaultInAssembly` | 自身默认排除（IF-03 要求） |
| 9 | `testDirectoryHeldByCwdDescendant` | cwd 在候选之下 → 目录在用 |
| 10 | **`testDegradedProducesPermissionTripleInUI`** | **端到端**：degraded → ④ 页「所缺权限 + E-501」 |

第 10 条最要紧：它把「内核层面看不见」与「用户能看到那句『请到系统设置允许』」连起来。
少了这一环，前面所有 `degraded` 断言都只是内部状态。

---

## 顺带修正的两个测试自身错误

1. **`otherUID = 501` 写死** —— 本机用户 uid 恰好就是 501，于是「跨 uid」退化成「同 uid」，
   四条断言同时失败。改为 `myUID &+ 1`。
   > 「造一个不同 uid 的测试对象」这件事，**不能靠猜一个数字**。
2. **`identities` 未配** —— fd 查不到身份，倒排表必空，「降级时保留已读信息」那条断言
   变成在测空气。补上。

---

## 影响面

| 对象 | 影响 |
|---|---|
| **PRD / R2** | **无**。D-4 是把实现改回契约原样，不是改契约 |
| **`L0Probe.swift`** | `isHeld` 方向修正；抽 `ProcessProbe` / `SystemProcessProbe` / `realProcessTable`；`ProcessEntry` / `FDList.init` 公开 |
| **`L0ProbeTests.swift`** | 原 cwd 测试改名 + 改语义 + 加反向断言；`testProcPidListFds*` 改调生产原语（CR-027 遗留） |
| **新增** | `L0SnapshotAssemblyTests.swift`（10 条） |
| **`verify_a9.sh`** | 新增第十一节（2 项），现 **56 项** |
| **测试总数** | 245 → **255**（+10） |
| **工时** | 0.35 人日（复核 0.1 / D-4 定位与修 0.1 / D-5 抽注入点 0.1 / 测试与断言 0.05） |

---

## 一条方法论

**「本机绿」不是证据，「造出能分岔的样本后绿」才是。**

本轮两条缺陷的共同点：**它们都能被本机的一个巧合掩盖**。

| 缺陷 | 掩盖它的巧合 |
|---|---|
| CR-027 D-1（fd 下标） | 本机进程 fd 恰好连续 |
| 本单 D-4（cwd 方向） | 本机测试恰好按错误方向写了断言 |
| 本单 D-5（degraded 零覆盖） | 本机恰好不降级，所以"不降级"永远为真 |

三种巧合，一个共性：**它们让"通过"变得廉价**。

所以复核的判据不是「测试过不过」，而是：

> **这条断言若把实现改错，它会红吗？**

不会红的断言，不构成防线。

---

**结论**：已落地。`swift test` **255 全绿**，`verify_a9` **56/56**，`--verify-wiring` 36/36。

**⚠️ `v0.1.0` 的发布包含 D-4** —— 需要发 `v0.1.1`。
