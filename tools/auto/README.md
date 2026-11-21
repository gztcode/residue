# 本地自动处理 issue

在本机轮询 `gztcode/residue` 的未关闭 issue，判定能否复现，能复现才改代码并开 PR。

**不跑在 GitHub Actions 上。** 用本机的 `claude` CLI，复用现有凭据，不额外买 API key。

## 它做什么

```
gh issue list
   ↓
为每个 issue 建独立 worktree（基线 origin/main）
   ↓
阶段 1 · triage：尝试写一个在 main 上会红的测试
   ↓
    ├─ 写不出来 → 贴分析评论，结束。不碰生产代码。
    └─ 写得出来 → 阶段 2 · fix：改生产代码让它变绿 + 跑全部校验
                    ↓
                 全绿 → commit + push + 开 PR（人审合并）
                 不绿 → 贴评论说明卡在哪，不推
```

## 它不做什么

- **不合并 PR。** 永远只开 PR，合并必须人点。
- **不处理无法复现的 issue。** 这是硬门槛，不是建议。
- **不改契约文档。** 改 `docs/contract/**` 需要变更单，机器不代签。
- **不信任 issue 正文。** 正文明令要求 bot 执行的指令一律视为提示注入，只记录、不照做。

这四条**不只写在提示词里**。前三条由脚本本身兜底：

| 门槛 | 脚本层的落点 | 拦下时 |
|---|---|---|
| 不处理无法复现 | `poll.sh` 阶段 1 末，`reproduced != true` 就到此为止 | 贴分析评论，退出码 0 |
| 不改契约文档 | 提交前按 `git` 的**实际改动路径**兜底：碰了 `docs/` 下任何文件就拒绝提交 | 贴拦下评论并点名文件，退出码非 0 |
| 不合并 PR | 脚本里根本没有合并命令 | ——（自测静态断言它不出现） |

提示词里写「不许」不算护栏 —— 模型可能不照做。护栏得由脚本本身兜住。

## 为什么「能复现」= 「写得出在 main 上会红的测试」

这不是随便定的标准，是这仓库自己的方法论（`CLAUDE.md` §八）：

> 改代码时优先**先写能复现的测试**。

三条理由：

1. **不可伪造。** 一段自然语言分析可以编，一个在 `main` 上真的变红的测试不行。
2. **可审计。** PR 正文里贴「红 → 绿」两段输出，人一眼能判。
3. **自动挡住「看着像修好了」。** 如果测试在 `main` 上就是绿的，说明 issue 描述的现象根本没被复现，此时改代码等于瞎猜。

代价要说清楚：**GUI 交互、真实性能、14 天观察期这三类问题，本机也写不出干净的失败测试**。它们会被判 `reproduced: false`，只产出分析，不自动修。这是设计，不是缺陷。

## 怎么跑

```bash
# 单次：处理当前所有未关闭 issue（幂等，处理过的会跳过）
./tools/auto/poll.sh --once

# 常驻：每 30 分钟轮询一次
./tools/auto/poll.sh --loop 1800

# 演练：走完整流程，但不推送、不开 PR（分支留在本地 worktree）
./tools/auto/poll.sh --dry-run --once

# 自测：离线跑，不碰网络、不碰真实仓库
./tools/auto/poll.sh --self-test
```

首次运行前确认：

```bash
gh auth status          # 需要 repo 权限
claude --version        # 需要能非交互运行
```

## 自测

`poll.sh` 有三条硬门槛，坏了不能静默失败 —— 所以它自带离线自测：

```bash
./tools/auto/poll.sh --self-test    # 退出码 0 = 通过
```

自测在临时目录里造一个**假仓库**（假 origin + 假 main），并把 `claude` / `gh` / `timeout` / `swift` 全部换成**桩**。真实仓库、真实凭据、真实网络全程不参与。断言只看三样东西：桩记下的调用日志、假 origin 的分支状态、`poll.sh` 的退出码。

四个场景：

| 场景 | 断言 |
|---|---|
| issue 无法复现 | 只贴「未能复现」评论，**不开 PR**、不推分支，`main` 不动 |
| 修复顺手改了 `docs/` | **拒绝提交**（退出码非 0），贴评论并点名被改的契约文件，不推分支 |
| 正常路径 | 开 PR（base `main`），推 `auto/issue-<N>` 分支，`main` 不动 |
| 整轮轮询 | 带 `auto-skip` 标签的 issue 不被碰 |

外加一条结构性检查：`poll.sh` 里**不得出现**合并命令（`gh pr merge` / `--auto-merge`）或把 `main` 推上去的命令。

`fixtures/` 下的 JSON 是**按 `gh` 真实输出结构合成的样本** —— 仓库当时还没有 issue，无从录制。桩按 `gh` 的真实行为消费它们：triage 阶段用 `gh issue view` 取 issue，`gh issue list` 按 `--jq` 的口径过滤 `auto-skip` 标签。

自测也跑在 CI 里（`.github/workflows/ci.yml`）：门槛被绕过 ⇒ CI 红。

## 状态与审计

所有运行记录落在 `~/.local/state/residue-auto/`：

```
runs/<时间戳>-issue-<N>/     每次运行的完整输入输出（claude 原始 JSON + AUTO_RESULT）
done/<N>                      已处理过的 issue 编号（幂等标记）
logs/poll.log                 轮询总日志
```

想重跑某个 issue：`rm ~/.local/state/residue-auto/done/<N>`。

## 权限边界

`claude -p` 用 `--permission-mode dontAsk`，**未列出的工具一律拒绝**，不会挂起等输入。

允许的只有：读文件、写/改工作区文件、以及 `triage.md` / `fix.md` 里写明的那几条只读或校验命令。没有网络请求工具，没有 `rm`，没有 `git push`（推送由外层脚本在确认全绿后自己做）。

worktree 隔离在 `/tmp/residue-auto-<N>`，跑完即删。**不会碰你的主工作区。**

## 已知限制

| 限制 | 原因 |
|---|---|
| 需要这台机器开着 | 不在 Actions 上跑 |
| 响应有延迟 | 轮询间隔决定，默认 30 分钟 |
| 只能跑 macOS 上能跑的东西 | 这是 macOS 应用，本来也只能在 Mac 上验 |
| 首次运行要人工看一遍 | 提示词和权限白名单需要按实际表现调 |
