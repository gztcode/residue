# Residue

[![CI](https://github.com/gztcode/residue/actions/workflows/ci.yml/badge.svg)](https://github.com/gztcode/residue/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/gztcode/residue?label=release)](https://github.com/gztcode/residue/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](https://github.com/gztcode/residue)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange?logo=swift)](https://swift.org)
[![License](https://img.shields.io/github/license/gztcode/residue)](LICENSE)

**简体中文** · [English](README.en.md)

> 看清 AI 工具在你自己机器上留下的缓存，然后**在证明自己判断准确之后**，安全地收回它。

`uv`、`npm/npx`、`pipx`、`Homebrew`、`pip` 这些包管理器会在你不知情的时候攒下几十 GB 缓存。Residue 只做三件事：

| # | 它做什么 | 它不做什么 |
|---|---|---|
| 1 | **只读地**告诉你各来源占了多少 | 不申请完全磁盘访问，不读文件内容 |
| 2 | 用 **14 天影子观察期**先证明自己判断得准 | 观察期不可跳过、不可加速 |
| 3 | 动手时只做**原子 rename 到废纸篓**，14 天内可一键恢复 | 从不直接删除、从不覆盖同名文件 |

> **它不会自己删东西。** 自动删除必须你亲手点亮，而点亮之前它要先证明自己判断得准。

---

## 为什么值得信任

这个产品的安全不靠承诺，靠**能被机器复核的结构**：

```
只读扫描 ──→ 14 天影子观察 ──→ 门槛判定 ──→ 你点亮开关 ──→ rename 到废纸篓
   │              │                  │                        │
   │              │                  └─ K ≥ H ∧ a = 0 ∧ b ≥ 1  └─ 14 天内可恢复
   │              └─ 每一轮都记录「它以为可回收」与「实际有人在用」的差异
   └─ proc_pidinfo 判活引用，文件身份 = (dev, ino)，不是路径
```

- **删除动作只有 `moveItem`。** `Sources/ResidueCore/TrashExecutor.swift` 里**没有任何删除调用**，可以直接 `grep` 验证。
- **未知不等于安全。** 看不见的进程如实显示「无法判定」，不显示 0、不猜。
- **上游命令是封闭白名单**，只允许只读定位命令；每次调用都落盘到 `scan.jsonl`，未落盘按「无法证明」处理。

---

## 系统要求

| 项 | 要求 |
|---|---|
| macOS | **14.0 或更高** |
| 处理器 | **仅 Apple Silicon（arm64）** |
| 网络 | **完全不需要**（产品零外发） |

> **为什么只有 Apple Silicon**：首发不提供 Intel 构建。这不是「以后再说」——**Intel Mac 上跑不了**，请勿尝试。
> 若你需要 Intel 版本，请在 Issues 里说明，这会进入版本规划。

---

## 安装

1. 从 [Releases](../../releases) 下载最新的 `Residue.app.dmg`
2. 双击打开磁盘映像，把 `Residue.app` **拖进「应用程序」文件夹**
3. 推出磁盘映像，在「应用程序」里双击打开

> ⚠️ **必须放进「应用程序」**。从磁盘映像 / 下载目录 / 桌面直接运行会让 macOS 把 App 放进随机只读路径（App Translocation），
> 后果是**登录项注册失效、定时任务不会执行**。产品会检测这个状态并在界面顶部提示你。

### 首次打开被 Gatekeeper 拦下怎么办

**分两种情况，请先看 Releases 说明里写的是哪一种：**

#### 情况 A：Releases 说明标注「已公证」（正式版本）

正常双击即可打开。若仍被拦，说明下载不完整——请重新下载并**核对 SHA-256**（见下节）。

#### 情况 B：Releases 说明标注「未公证 / dev build」

macOS 15 起对未公证的 App 会直接拒绝，需要手动放行一次：

1. 双击 `Residue.app`，出现拦截提示后点「完成」
2. 打开 **系统设置 → 隐私与安全性**，向下滚动到「安全性」
3. 找到关于 Residue 的提示，点 **「仍要打开」**
4. 再双击一次 `Residue.app`，在弹窗里点「打开」

> 这个放行只需做一次。**不要**用 `sudo spctl --master-disable` 关掉全局 Gatekeeper —— 那会让整台机器失去保护。

---

## 验证你下载的文件是完整的

每个 Release 都会附一个 `SHA-256` 值。下载后自己算一遍：

```bash
cd ~/Downloads
shasum -a 256 Residue.app.dmg
```

把输出与 Releases 说明里的值**逐字符比对**。不一致就不要打开，重新下载。

再验证签名链：

```bash
# 情况 A（已公证）应看到：source=Notarized Developer ID
spctl --assess --type execute --verbose=4 /Applications/Residue.app

# 两种情况下这条都应通过（签名本身完整性）
codesign --verify --deep --strict --verbose=2 /Applications/Residue.app
```

> **为什么把验证步骤写得这么细**：本产品**没有官网**，只有这个仓库。所以「你怎么确认下载到的是我发的那个文件」
> 只能靠这两条命令。**这是唯一的信任面，不是客套话。**

---

## 它到底看什么、不看什么

<details open>
<summary><b>会看</b></summary>

- `uv` / `npm` / `pipx` / **Homebrew** / **pip** 的**缓存目录**：路径、条目数、字节数、创建时间
- 同 uid 进程的**文件描述符归属**（判断某个缓存是否正被某个进程使用）—— 用它决定「这个能不能删」
- `uv` / `npm` / **Homebrew** / **pip** 的**只读定位命令**输出（`uv cache dir` / `brew --cache` / `pip cache dir` 这类，用于找到缓存位置）

</details>

<details open>
<summary><b>不会看 / 不会做</b></summary>

| 不做 | 为什么 |
|---|---|
| **不读文件内容** | 它只需要判断「占用多少」和「有没有人在用」，读内容既不必要也不该做 |
| **不扫描个人文件** | 只在你明确指定的缓存来源根下工作（默认是那五个包管理器的缓存目录） |
| **不申请完全磁盘访问（FDA）** | 它不需要。跨 uid 的进程看不见就如实说「看不见」，**不会假装看得见** |
| **不外发任何数据** | 零遥测、零崩溃上报、零版本检查。导出报告是**你手动触发**的本地文件 |

</details>

### 会写什么

只写两个地方，都在 `~/Library/Application Support/Residue/`：

- `state.residue` —— 观察期进度、误判记录、位图（**不含文件名清单**）
- `records/*.jsonl` —— 扫描日志、执行记录（供你导出报告）

**清理你的缓存时，只做原子 rename 到废纸篓，从不直接删除。**

> 一处例外要说清：它会**删除自己的**临时文件（写状态时的 `.tmp`）、失败的备份（`.bak`）和损坏现场的旧副本（`.corrupt`）。
> 那是它自己的载体，不是你的数据。`Sources/ResidueCore/TrashExecutor.swift` 里**没有任何删除调用**——这是可以被 `grep` 验证的。

---

## 卸载

1. 在 Residue 界面里：**③ 清理策略 → 定时任务 → 关闭自动删除**
2. **系统设置 → 通用 → 登录项** → 移除 Residue
3. 退出 Residue（菜单栏图标 → 退出）
4. 把 `/Applications/Residue.app` 拖进废纸篓
5. 删除残留数据：

```bash
rm -rf ~/Library/Application\ Support/Residue
```

> 第 5 步会**永久删除观察期进度与误判记录**（`a`）。如果你只是重装，跳过它。
> 顺序很重要：**先关自动删除、再移除登录项、最后删 App**——反过来的话定时任务会留下找不到目标的登录项。

---

## 已知限制（不粉饰）

| # | 限制 | 影响 |
|---|---|---|
| 1 | **仅 Apple Silicon** | Intel Mac 无法运行 |
| 2 | **跨 uid 进程的 fd 不可枚举** | 只能判断「你登录的这个用户」的进程；别的用户的进程看不见，界面会如实显示「无法判定」 |
| 3 | **增量扫描不发现深层新候选** | 新装的包要到下一次全量扫描（默认每日 1 次）才进清单 |
| 4 | **只支持五个来源，其中三个可自动删除** | 可自动删除：`uv` / `npm(npx)` / **Homebrew**（只算 bottle 文件）；**仅报告**：`pipx` / **pip**。其他包管理器的缓存不进候选 |
| 5 | **观察期不可跳过** | 14 天影子观察是设计的核心，不是可选项 —— 没有足够样本就点亮自动删除，等于让它在看不见的情况下删东西 |
| 6 | **全量扫描本身要十几秒** | 缓存大时（实测 22 万项 ≈ 12 秒）**扫描本身要十几秒**。但扫描在**后台线程**跑，界面全程可操作，并实时显示「已扫描 N 项」与耗时，**也可以随时取消**。（限制的是耗时，不是卡死 —— 界面不会冻住） |
| 7 | **未公证版本需手动放行一次** | 见上方「首次打开被 Gatekeeper 拦下怎么办」情况 B |

---

## 多语言

界面文案内置 **简体中文 / English** 两套，跟随系统语言；也可以在
**系统设置 → 通用 → 语言与地区 → 应用程序** 单独为 Residue 选择语言。

> 契约文档（`docs/contract/`）与发布说明仍以简体中文为准 —— 它们是验收依据，逐字判定。

---

## 工程质量

```bash
cd ResidueApp
swift test                                  # 312 个单测（Core 层，零 UI 依赖）
./scripts/verify_a9.sh                      # 页面结构 + 界面禁算术 + 数据层接线（72 项）
python3 scripts/verify_codes.py             # 错误码表 ↔ 文档一致性（11 项）
swift run --disable-sandbox ResidueApp --verify-wiring /tmp/w   # 真 IO 往返（45 项）
./scripts/make_app.sh && ./scripts/verify_a5.sh                 # 产物结构（42 项）
```

外加两套文档基线：PRD 238 项、R2 123 项。CI 每次构建都会全部重跑，并校验
「注释里声明的项数 = 实测值」—— **数字对不上就红**。

见 **[ARCHITECTURE.md](ARCHITECTURE.md)** —— 仓库结构、怎么自己跑全部校验、以及**这个版本明确不能保证什么**（未公证、仅 arm64、GUI 未做交互验证）。

那里还有一句值得先知道的话：**「CI 绿」不等于「可发布」**。

---

## 反馈

- **Bug / 功能请求**：[Issues](../../issues)
- 附上导出报告能大幅缩短排查时间：**⑦ 举证链与日志 → 导出脱敏报告**
  （报告已脱敏：用户名 → `<user>`、主目录 → `<path>`、主机名 → `<host>`；**不含文件内容**；由你手动导出，产品不会自动上传）

> 报告里的「上游命令的调用次数 / 执行次数」两列值得看一眼：**执行次数必须为 0**。
> 那是产品在证明自己没调用过任何会直接删除文件的命令。

---

## 许可

见 [LICENSE](LICENSE)。
