#!/bin/bash
# 本地自动处理 issue：triage →（可复现才）fix → 开 PR
#
# 设计要点见同目录 README.md。一句话：
#   **能不能复现，由「在 main 上会红的测试」说了算。**
#   编不出这个测试，就只贴分析评论，不碰生产代码。
#
# 用法：
#   ./tools/auto/poll.sh --once          处理当前未关闭 issue 后退出
#   ./tools/auto/poll.sh --loop 1800     每 1800 秒轮询一次
#   ./tools/auto/poll.sh --issue 42      只处理 #42（调试用）
set -uo pipefail

REPO="gztcode/residue"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/residue-auto"
mkdir -p "$STATE"/{runs,done,logs}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$STATE/logs/poll.log"; }

# 允许 claude 调用的工具。**未列出的一律拒绝**（dontAsk 模式不会挂起等输入）。
# 刻意不包含：rm / curl / git push / gh 写操作 / git checkout / git reset。
ALLOWED=(
  "Read" "Write" "Edit" "Grep" "Glob"
  "Bash(gh issue view:*)"
  "Bash(swift build:*)" "Bash(swift test:*)" "Bash(swift run:*)"
  "Bash(git status:*)" "Bash(git diff:*)" "Bash(git log:*)"
  "Bash(./scripts/verify_a9.sh)"
  "Bash(python3 scripts/verify_codes.py)"
  "Bash(./tests/contract/check_all.sh)"
  "Bash(python3 tests/contract/verify_r2.py)"
  "Bash(python3 tests/contract/verify_counts.py)"
)

run_claude() {
  local prompt_file="$1" issue="$2" out="$3"
  local prompt
  prompt="$(sed "s/{{ISSUE}}/$issue/g" "$prompt_file")"
  # 20 分钟上限。实测：`dontAsk` 遇到白名单外的命令会**拒绝**（不会执行），
  # 但会多花一轮解释，单次调用可能两三分钟。超过 20 分钟基本是卡住了。
  timeout 1200 claude -p "$prompt" \
    --permission-mode dontAsk \
    --allowedTools "${ALLOWED[@]}" \
    --output-format json \
    > "$out" 2>"${out%.json}.err"
}

# 从 AUTO_RESULT.json 取字段（读不到就返回空）
field() { python3 -c '
import json,sys
try:
    v=json.load(open(sys.argv[1])).get(sys.argv[2],"")
except Exception:
    print(""); raise SystemExit
if isinstance(v, bool):
    print("true" if v else "false")
elif isinstance(v, list):
    print("\n".join("- "+str(x) for x in v))
elif v is None:
    print("")
else:
    print(v)
' "$1" "$2" 2>/dev/null; }

process_issue() {
  local N="$1"
  local RUN="$STATE/runs/$(date '+%Y%m%d-%H%M%S')-issue-${N}"
  local WT="/tmp/residue-auto-${N}"
  local BR="auto/issue-${N}"

  mkdir -p "$RUN"
  log "── issue #${N} 开始 ──"

  # 清理可能残留的 worktree / 分支
  git -C "$REPO_ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || true
  git -C "$REPO_ROOT" branch -D "$BR" >/dev/null 2>&1 || true

  if ! git -C "$REPO_ROOT" worktree add -b "$BR" "$WT" origin/main >"$RUN/worktree.log" 2>&1; then
    log "issue #${N}：建 worktree 失败，跳过"; return 1
  fi

  cd "$WT" || return 1

  # ── 阶段 1：triage ─────────────────────────────────────────
  log "issue #${N}：triage"
  run_claude "$HERE/triage.md" "${N}" "$RUN/triage.json"

  if [ ! -f "$WT/AUTO_RESULT.json" ]; then
    log "issue #${N}：triage 没产出 AUTO_RESULT.json（见 $RUN/triage.err）"
    gh issue comment "${N}" --repo "$REPO" --body "自动分析未能产出结论（triage 无结果文件）。需要人看。" || true
    cd "$REPO_ROOT"; git worktree remove --force "$WT" >/dev/null 2>&1; git branch -D "$BR" >/dev/null 2>&1
    return 1
  fi

  cp "$WT/AUTO_RESULT.json" "$RUN/triage-result.json"
  local reproduced reason
  reproduced="$(field "$WT/AUTO_RESULT.json" reproduced)"
  reason="$(field "$WT/AUTO_RESULT.json" reason)"

  if [ "$reproduced" != "true" ]; then
    log "issue #${N}：不可复现 —— 只贴分析，不改代码"
    {
      echo "## 自动分析：未能复现"
      echo
      echo "$reason"
      echo
      echo "<sub>判据：能否写出一条在当前 \`main\` 上会红的测试。写不出来就不改生产代码。</sub>"
    } > "$RUN/comment.md"
    gh issue comment "${N}" --repo "$REPO" --body-file "$RUN/comment.md" || true
    cd "$REPO_ROOT"; git worktree remove --force "$WT" >/dev/null 2>&1; git branch -D "$BR" >/dev/null 2>&1
    touch "$STATE/done/${N}"
    return 0
  fi

  # ── 阶段 2：fix ────────────────────────────────────────────
  log "issue #${N}：已复现，进入修复"
  run_claude "$HERE/fix.md" "${N}" "$RUN/fix.json"
  cp "$WT/AUTO_RESULT.json" "$RUN/final-result.json" 2>/dev/null || true

  local fixed
  fixed="$(field "$WT/AUTO_RESULT.json" fixed)"
  if [ "$fixed" != "true" ]; then
    log "issue #${N}：修复未完成 —— 贴评论，不推"
    {
      echo "## 已复现，但自动修复未完成"
      echo
      echo "复现依据：$(field "$WT/AUTO_RESULT.json" test_file) / $(field "$WT/AUTO_RESULT.json" test_name)"
      echo
      echo "卡在：$(field "$WT/AUTO_RESULT.json" blocked)"
      echo
      echo "<sub>失败测试已保留在分支 \`$BR\`，可人工接手。</sub>"
    } > "$RUN/comment.md"
    gh issue comment "${N}" --repo "$REPO" --body-file "$RUN/comment.md" || true
    cd "$REPO_ROOT"; git worktree remove --force "$WT" >/dev/null 2>&1
    touch "$STATE/done/${N}"
    return 1
  fi

  # ── 验收：全绿才推 ─────────────────────────────────────────
  # 外层自己重跑一遍，不采信 claude 报的结果 —— 它说自己全绿不算数。
  log "issue #${N}：外层复验"
  local ok=1
  ( cd "$WT/ResidueApp" && swift test >"$RUN/verify-test.log" 2>&1 ) || ok=0
  ( cd "$WT" && ./tests/contract/check_all.sh >"$RUN/verify-contract.log" 2>&1 ) || ok=0
  if [ -f "$WT/tests/contract/verify_counts.py" ]; then
    ( cd "$WT" && python3 tests/contract/verify_counts.py >"$RUN/verify-counts.log" 2>&1 ) || ok=0
  else
    echo "基线（origin/main）上还没有 verify_counts.py，跳过。" >"$RUN/verify-counts.log"
    log "issue #${N}：基线没有 verify_counts.py，跳过该项"
  fi

  if [ "$ok" -ne 1 ]; then
    log "issue #${N}：外层复验失败，不推送"
    gh issue comment "${N}" --repo "$REPO" --body "自动修复跑完了，但**外层复验没过**（\`swift test\` / \`check_all\` / \`verify_counts\` 至少一项红）。不推送。日志未上传，需要人接手。" || true
    cd "$REPO_ROOT"; git worktree remove --force "$WT" >/dev/null 2>&1
    touch "$STATE/done/${N}"
    return 1
  fi

  # ── 提交、推送、开 PR ──────────────────────────────────────
  local summary
  summary="$(field "$WT/AUTO_RESULT.json" summary)"
  git -C "$WT" add -A
  git -C "$WT" commit -q -m "fix: issue #${N} 自动修复

$summary

复现方式：先写失败测试并在 main 上确认红，再改生产代码。
详见 PR 正文。" || { log "issue #${N}：提交失败"; cd "$REPO_ROOT"; return 1; }

  # PR 正文先生成：dry-run 时也要能检查最终产物。
  {
    echo "## 自动修复：issue #${N}"
    echo
    echo "**判据**：能写出一条在 \`main\` 上会红的测试。写不出来就不会有这个 PR。"
    echo
    echo "### 复现"
    echo '```'
    field "$WT/AUTO_RESULT.json" failure_output
    echo '```'
    echo
    echo "### 改动"
    field "$WT/AUTO_RESULT.json" files_changed
    echo
    echo "### 外层复验"
    echo "- \`swift test\`：$(grep -E 'Executed [0-9]+ tests' "$RUN/verify-test.log" | tail -1 | sed 's/^[[:space:]]*//')"
    echo "- \`check_all\`：$(tail -1 "$RUN/verify-contract.log" | sed 's/^[[:space:]]*//')"
    echo "- \`verify_counts\`：$(tail -1 "$RUN/verify-counts.log" | sed 's/^[[:space:]]*//')"
    echo
    echo "> 合并必须人点。自动化只到「开 PR」为止。"
  } > "$RUN/pr.md"

  if [ "${AUTO_DRY_RUN:-0}" = "1" ]; then
    log "issue #${N}：dry-run —— 已提交，跳过 push 与 PR（分支 $BR 保留在 ${WT}）"
    touch "$STATE/done/${N}"
    cd "$REPO_ROOT"
    return 0
  fi

  git -C "$WT" push -q -u origin "$BR" || { log "issue #${N}：推送失败"; cd "$REPO_ROOT"; return 1; }

  if gh pr create --repo "$REPO" --base main --head "$BR" \
       --title "fix: issue #${N}" --body-file "$RUN/pr.md"; then
    log "issue #${N}：PR 已开"
    touch "$STATE/done/${N}"
  else
    log "issue #${N}：开 PR 失败（分支已推送，可手动开）"
  fi

  cd "$REPO_ROOT"
  git worktree remove --force "$WT" >/dev/null 2>&1
}

main() {
  local mode="${1:---once}"
  case "$mode" in
    --issue)
      process_issue "$2"; exit $?
      ;;
    --loop)
      local interval="${2:-1800}"
      log "轮询模式启动，间隔 ${interval}s"
      while true; do
        one_pass
        sleep "$interval"
      done
      ;;
    --once|*)
      one_pass
      ;;
  esac
}

one_pass() {
  local nums
  nums="$(gh issue list --repo "$REPO" --state open --limit 50 \
            --json number,labels \
            --jq '.[] | select(.labels | map(.name) | index("auto-skip") | not) | .number' 2>/dev/null)"
  if [ -z "$nums" ]; then log "没有待处理 issue"; return 0; fi
  for n in $nums; do
    if [ -f "$STATE/done/$n" ]; then continue; fi
    process_issue "$n"
  done
}

main "$@"
