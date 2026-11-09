# CR-027 · 首次 CI/Release 暴露的三处缺陷

> **性质**：实现层 P0 缺陷 + 流程缺陷
> **提出**：程必达（交付总监）
> **发现路径**：建 GitHub 仓库 → 首次 CI → **首次 Release 失败**
> **PRD 影响**：**无**。不改任何 AC、不改判定口径、不改字段定义。

---

## 总览：三条都是同一类，但成因完全不同

「本机全绿、CI 红」通常被当成环境问题打发掉。这次三条**都不是环境问题**——每一条在本机也是错的，只是本机的巧合把它掩盖了。

| # | 缺陷 | 严重度 | 本机为什么绿 |
|---|---|---|---|
| **D-1** | **`L0Probe` 把 fd 数组下标当 fd 号** | **P0 · 可误删活文件** | 本机进程 fd 恰好连续 `0..7`，下标与字段值相同 |
| **D-2** | **CI 的 `Test` step 用管道吞掉退出码** | **流程 · CI 永远绿** | 它从来不会红，所以没人发现它没在验 |
| **D-3** | `plutil -extract` 失败的输出流跨版本不同 | 中 · 误报 | macOS 27 错误走 stderr，macOS 15 走 stdout |

---

## D-1 · fd 号来自结构体字段，不是数组下标（**P0**）

### 错在哪

原实现：

```swift
// 注释还写着：「fd 号 = 数组下标（实测约束）」
let fd = Int32(j)          // j 是数组下标
...
proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, ...)   // 用这个错的 fd 去查
```

但 `struct proc_fdinfo` **有 `proc_fd` 字段**：

```c
struct proc_fdinfo { int32_t proc_fd; uint32_t proc_fdtype; };
```

### 后果不是测试红，是**误删**

用错的下标去查 `PROC_PIDFDVNODEPATHINFO`，拿到的是**另一个 fd** 的 `(dev, ino)`。
那个身份进倒排表 → 若恰好对不上任何候选，L0 就判「无活引用」→ **把正在被进程使用的文件 rename 进废纸篓**。

而产品的核心承诺是「只清没人用的」。**这条错了，承诺就是假的。**

### 错因值得单独记：把「值恰好相等」当成「定义如此」

本机实测：

```
returned = 64 B → 8 项 → 下标 {0..7}
fcntl(fd, F_GETFD) 扫出的实际 fd 集合 = {0,1,2,3,4,5,6,7}
→ 完全一致，"验证通过"
```

于是当时把「fd 号 = 数组下标」写进了代码注释，还标成「实测约束 1」。

**问题在于：本机 fd 恰好连续。** 一个进程的 fd 是 `{0,1,2,3,4,5,6,7}` 时，
「下标 3」与「fd 号 3」是同一个数 —— 这份实测**无法区分两种解释**。

CI runner 上 fd 是 `{0,1,2,3,4,7,131,140,143,146}`（Xcode / 测试运行器开了很多东西），
下标与 fd 号立刻错位：

```
按 8 B stride 解析出的下标集合: {0,1,2,3,4,5,6,7}   ← 错，这是下标
fcntl 实测集合:              {0,1,2,3,4,7,131,140,143,146}   ← 对
```

> **教训（写进代码注释）**：
> **「两个值相等」不等于「它们同义」。实测必须造出能区分两种解释的样本，
> 否则你验证的是巧合——而巧合会被你当成契约写进文档，然后误导后来的人。**

这条与本项目已有的教训是同族：A-6 抓到「`PROC_PIDLISTFDS` 每项 24 B 是错的（8 B 才对）」，
也是「按字面/按巧合实现会静默产出错误数据」。区别是那次是**文档错**，这次是**我自己的实测结论错**。

### 修法

```swift
let fd = fdInfo.proc_fd
```

并且更正注释里那条错误的「实测约束 1」，把错因完整写进去（不是删掉了事）。

### 防再犯（`verify_a9.sh` 第十节，3 项）

| 断言 | 内容 |
|---|---|
| 1 | `L0Probe.swift` 里必须出现 `fdInfo.proc_fd` |
| 2 | **活的代码行**里不得出现「用数组下标当 fd」（注释里的历史说明不算） |
| 3 | `PROC_PIDLISTFDS` 返回值必须按 `MemoryLayout<proc_fdinfo>.stride` 换算 |

---

## D-2 · CI 的 `Test` step 吞掉退出码（**流程缺陷，比 D-1 更值得记**）

### 现象

第一次发 Release 时：

- **CI 的 `Test` step：绿**
- **Release 的 `swift test`（无管道）：红**

### 原因

CI 里为了只显示末尾摘要，写成了：

```bash
swift test 2>&1 | tee /tmp/test.log | tail -40
```

bash 默认的管道退出码取**最后一个命令**（`tail`）的。`tail` 永远成功 → **这一步永远绿。**

### 这意味着什么

**这个 workflow 曾经是「永远绿的」，等于没有 CI。**

更糟的是：它是**主动隐瞒**——它在报告"测试通过"，而实际上测试可能早就红了。
这比没有 CI 更危险，因为没人会去查一个绿着的东西。

### 修法

workflow 级开 `pipefail`：

```yaml
defaults:
  run:
    shell: bash -o pipefail {0}
```

两个 workflow 都加。并在 `Test` step 上写了注释：「若把 `defaults.run.shell` 去掉，这一步会重新变成永远绿」。

### 一条附带收获

**D-1 能被发现，正是因为 Release 的 `swift test` 没走管道。**
如果我一开始就只在 CI 里验，这个 P0 会一直藏着——直到某个用户的生产文件被删。

> **反面教训**：CI 全绿的时候，要问一句「它是真的验了，还是只是没报错」。

---

## D-3 · `plutil -extract` 的输出流跨版本不同（误报）

### 现象

CI 在 `Verify .app structure` 红：

```
✗ 设了 LSUIElement = build/Residue.app/Contents/Info.plist: Could not extract value, error: ...
```

### 原因

```bash
LSUI=$(plutil -extract LSUIElement raw -o - "$PLIST" 2>/dev/null || echo "absent")
```

`plutil -extract` 在**键不存在**时：

| 系统 | 行为 |
|---|---|
| macOS 27（本机） | 空 stdout + 非零退出码 → `\|\|` 兜底生效 → `"absent"` → 断言正确 |
| **macOS 15（CI）** | **错误信息写进 stdout** → `\|\|` 不触发 → 错误文本被当成键值 → **误报「设了错值」** |

### 修法

用 `PlistBuddy` 先判存在性再取值（行为跨版本一致），封装成 `plist_get()`：

```bash
plist_get() {
  local key="$1" plist="$2"
  if /usr/libexec/PlistBuddy -c "Print :$key" "$plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null
  else
    echo ""
  fi
}
```

4 处调用全替换（含 `CFBundleIconFile`），并确认无活的 `plutil -extract` 残留。

### 与本项目已有 4 次「校验脚本自己说谎」的关系

| 次 | 脚本 | 方向 |
|---|---|---|
| 1 | `verify_a5` 把「`SMAppService` 未实现」记成「环境所限」 | **漏报** |
| 2 | `grep -E 'StateFile('` —— `(` 是元字符 | **漏报** |
| 3 | `LSUIElement` 断言写成与 ADR-02 相反 | **反向断言** |
| 4 | C1 断言命中注释里的留痕 | **误报** |
| **5** | `plutil -extract` 输出流 | **误报** |

**结论：判据不可靠时，两个方向都会出错。** 前几次是「该红时绿」，这次是「该绿时红」。
而 D-2 是第三种：**「根本没在判，却显示通过」**。

---

## 影响面

| 对象 | 影响 |
|---|---|
| **PRD / R2** | 无 |
| **`L0Probe.swift`** | `fd` 来源改为结构体字段；注释更正（含错因） |
| **`.github/workflows/*.yml`** | 均加 `defaults.run.shell: bash -o pipefail {0}` |
| **`verify_a5.sh`** | 新增 `plist_get()` helper，4 处调用替换 |
| **`verify_a9.sh`** | 新增第十节（3 项），现 **54 项** |
| **测试** | 243 项不变（`testProcPidListFdsReturnsBytesAndFdsAreIndices` 本就有区分力，只是本机无法暴露） |
| **工时** | 0.3 人日（CI 排查 0.1 / D-1 定位与修 0.1 / D-2 D-3 与断言 0.1） |

---

## 一条必须说清的判断

**D-1 是本项目迄今最严重的一处实现缺陷**，因为它的失败形态是「静默删错东西」，
而不是「报错」或「显示异常」。

而它之所以能被抓到，靠的是两件偶然：
1. Release workflow 里的 `swift test` **没有走管道**（否则会被 D-2 一起吞掉）
2. CI runner 的 fd 布局**恰好不连续**（否则永远绿）

**两个偶然凑在一起才暴露了一个 P0。** 这提醒我：剩下的「本机绿」项里，
大概率还有同类——那些**本机环境恰好满足某个巧合**才能通过的断言。

已登记为遗留：**所有依赖「本机进程/文件系统布局」的断言都要复核一遍能否造出区分性样本**。
