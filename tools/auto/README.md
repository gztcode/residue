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
```

首次运行前确认：

```bash
gh auth status          # 需要 repo 权限
claude --version        # 需要能非交互运行
```

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
