#!/bin/bash
# poll.sh 的离线自测。
#
# 断言三条硬门槛不被绕过：
#   1. 不处理「无法复现」的 issue —— 写不出在 main 上会红的测试，就只贴评论
#   2. 不改契约文档（`docs/**`）—— 机器不代签变更单
#   3. 不合并 PR —— 合并必须人点
#
# 跑法：./tools/auto/poll.sh --self-test   （退出码 0 = 全过）
#
# ## 怎么保证「不碰真东西」
#   · 临时目录里造一个**假仓库**（假 origin + 假 main），poll.sh 在它上面跑；
#   · PATH 最前面放**桩**（claude / gh / timeout / swift），所有外部调用都被接管；
#   · 断言只看三样：桩记下的调用日志、假 origin 的分支状态、poll.sh 的退出码。
#     真实仓库、真实凭据、真实网络，全程不参与。
#
# ## fixture 的性质
#   `fixtures/` 下的 JSON 是**按 gh 真实输出结构合成的样本**（仓库当时还没有 issue，
#   无从录制）。桩按 gh 的真实行为消费它们：triage 阶段用 `gh issue view` 取 issue，
#   `gh issue list` 按 `--jq` 的口径过滤 `auto-skip` 标签。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
POLL="$HERE/poll.sh"
FIXTURES="$HERE/fixtures"
ISSUE_JSON="issue-101.json"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/residue-auto-selftest.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; }

# assert <描述> <命令...> —— 命令退出码 0 记通过
assert() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

# assert_not <描述> <命令...> —— 命令退出码非 0 记通过
assert_not() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then bad "$desc"; else ok "$desc"; fi
}

# ── 假仓库：假 origin（裸）+ 假 main ──────────────────────────────
setup_fake_repo() { # $1 = 场景根目录
  local root="$1"
  mkdir -p "$root"

  git init -q --bare -b main "$root/origin.git"

  mkdir -p "$root/src"
  git -C "$root/src" init -q -b main
  git -C "$root/src" config user.email "selftest@example.invalid"
  git -C "$root/src" config user.name "Residue Auto Self Test"
  git -C "$root/src" config commit.gpgsign false

  # 外层复验要在这棵树上跑 —— 给能立刻成功的桩
  mkdir -p "$root/src/ResidueApp/Sources/ResidueCore" "$root/src/tests/contract"
  printf '// 占位\n' > "$root/src/ResidueApp/Sources/ResidueCore/Dummy.swift"
  printf '#!/bin/bash\necho "通过 1 项 / 失败 0 项"\n' > "$root/src/tests/contract/check_all.sh"
  chmod +x "$root/src/tests/contract/check_all.sh"
  printf 'print("一致 1 项 / 不一致 0 项 / 未覆盖 0 项")\n' > "$root/src/tests/contract/verify_counts.py"

  git -C "$root/src" add -A
  git -C "$root/src" commit -q -m "基线"
  git -C "$root/src" remote add origin "$root/origin.git"
  git -C "$root/src" push -q origin main

  # poll.sh 用的仓库（origin 指回假 origin）
  git clone -q "$root/origin.git" "$root/repo"
  git -C "$root/repo" config user.email "selftest@example.invalid"
  git -C "$root/repo" config user.name "Residue Auto Self Test"
  git -C "$root/repo" config commit.gpgsign false

  git -C "$root/origin.git" rev-parse main > "$root/main.sha"
}

# ── 桩：接管所有外部调用 ──────────────────────────────────────────
setup_stubs() { # $1 = 桩目录
  local stub="$1"
  mkdir -p "$stub"

  # timeout：透传（自测不测超时行为，也就不依赖系统装没装 GNU timeout）
  cat > "$stub/timeout" <<'EOF'
#!/bin/bash
shift
exec "$@"
EOF

  # swift：外层复验要用。桩吐出 poll.sh 解析的那行格式。
  cat > "$stub/swift" <<'EOF'
#!/bin/bash
case "$1" in
  test) echo "Executed 2 tests, with 0 failures" ;;
  *)   echo "stub swift: $*" ;;
esac
exit 0
EOF

  # gh：记下每一次调用；`issue list` 按 poll.sh 的 --jq 口径过滤 auto-skip
  cat > "$stub/gh" <<'EOF'
#!/bin/bash
echo "gh $*" >> "$SELFTEST_GH_LOG"
case "$1 $2" in
  "issue list")
    python3 - <<'PY'
import json, os
path = os.path.join(os.environ["SELFTEST_FIXTURES"], "issues.json")
for it in json.load(open(path)):
    if any(l.get("name") == "auto-skip" for l in it.get("labels", [])):
        continue
    print(it["number"])
PY
    ;;
  "issue view")
    echo "--- issue json ---" >> "$SELFTEST_GH_LOG"
    cat "$SELFTEST_FIXTURES/$SELFTEST_ISSUE_JSON" >> "$SELFTEST_GH_LOG"
    cat "$SELFTEST_FIXTURES/$SELFTEST_ISSUE_JSON"
    ;;
  "issue comment")
    prev=""
    for a in "$@"; do
      case "$prev" in
        --body-file)
          echo "--- comment body ---" >> "$SELFTEST_GH_LOG"
          cat "$a" >> "$SELFTEST_GH_LOG"
          echo >> "$SELFTEST_GH_LOG"
          ;;
        --body)
          echo "--- comment body ---" >> "$SELFTEST_GH_LOG"
          printf '%s\n' "$a" >> "$SELFTEST_GH_LOG"
          ;;
      esac
      prev="$a"
    done
    ;;
esac
exit 0
EOF

  # claude：按提示词分阶段（triage / fix），产出对应 fixture 的 AUTO_RESULT.json
  cat > "$stub/claude" <<'EOF'
#!/bin/bash
prompt=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) prompt="$2"; shift 2 ;;
    *) shift ;;
  esac
done
echo '{}'
phase=fix
case "$prompt" in
  *"任务：判定 issue"*) phase=triage ;;
esac
F="$SELFTEST_FIXTURES"
if [ "$phase" = "triage" ]; then
  # 真实流程里，模型自己用 `gh issue view` 取 issue —— 这里也走一遍，
  # 于是「录制的 issue JSON」才真的是 triage 的输入。
  gh issue view "$SELFTEST_ISSUE_NUMBER" --json title,body,labels,comments >/dev/null 2>&1 || true
  if [ "$SELFTEST_SCENARIO" = "not_reproducible" ]; then
    cp "$F/result-not-reproducible.json" ./AUTO_RESULT.json
  else
    cp "$F/result-reproduced.json" ./AUTO_RESULT.json
  fi
else
  cp "$F/result-fixed.json" ./AUTO_RESULT.json
  # 模拟模型改了生产代码 + 测试
  mkdir -p ResidueApp/Sources/ResidueCore ResidueApp/Tests/ResidueCoreTests
  printf '// 自测桩：模拟修复\n' >> ResidueApp/Sources/ResidueCore/Dummy.swift
  printf '// 自测桩：模拟测试\n' >> ResidueApp/Tests/ResidueCoreTests/DummyTests.swift
  if [ "$SELFTEST_SCENARIO" = "contract_violation" ]; then
    mkdir -p docs/contract
    printf '\n<!-- 自测桩：模拟改了契约文档 -->\n' >> docs/contract/Residue-PRD-v5.6.md
  fi
fi
exit 0
EOF

  chmod +x "$stub/timeout" "$stub/swift" "$stub/gh" "$stub/claude"
}

# ── 跑一个场景 ───────────────────────────────────────────────────
# run_case <场景名> <issue 号> [模式]
#   模式默认 "--issue <issue 号>"；传 "--once" 则走整轮轮询。
run_case() { # $1 = 场景名  $2 = issue 号  $3 = 模式（可选）
  local scenario="$1" N="$2" mode="${3:---issue}"
  local root="$TMP/$scenario"
  setup_fake_repo "$root"
  setup_stubs "$root/stubs"
  : > "$root/gh.log"
  mkdir -p "$root/wt"
  (
    export PATH="$root/stubs:$PATH"
    export RESIDUE_AUTO_REPO="acme/fake-residue"
    export RESIDUE_AUTO_REPO_ROOT="$root/repo"
    export RESIDUE_AUTO_STATE="$root/state"
    export RESIDUE_AUTO_WORKTREE_ROOT="$root/wt"
    export SELFTEST_SCENARIO="$scenario"
    export SELFTEST_GH_LOG="$root/gh.log"
    export SELFTEST_FIXTURES="$FIXTURES"
    export SELFTEST_ISSUE_JSON="$ISSUE_JSON"
    export SELFTEST_ISSUE_NUMBER="$N"
    unset AUTO_DRY_RUN
    if [ "$mode" = "--once" ]; then
      "$POLL" --once
    else
      "$POLL" --issue "$N"
    fi
  ) > "$root/poll.log" 2>&1
  echo "$?" > "$root/exit.code"
}

echo "=== poll.sh 离线自测 ==="
echo "临时目录：$TMP"
echo

# ── 场景 1：issue 无法复现 ───────────────────────────────────────
echo "--- 场景 1：issue 无法复现（门槛 1）---"
run_case not_reproducible 101
root="$TMP/not_reproducible"
code="$(cat "$root/exit.code")"
assert "无法复现时 poll.sh 正常退出（0）" test "$code" -eq 0
assert "triage 取的是录制的 issue JSON" grep -q 'issue json' "$root/gh.log"
assert "贴了分析评论" grep -q '^gh issue comment' "$root/gh.log"
assert "评论内容确实是「未能复现」" grep -q '未能复现' "$root/gh.log"
assert_not "没有开 PR" grep -q '^gh pr create' "$root/gh.log"
assert_not "没有推送任何分支到 origin" \
  git -C "$root/origin.git" rev-parse --verify --quiet refs/heads/auto/issue-101
assert "origin/main 没被动过" test \
  "$(git -C "$root/origin.git" rev-parse main)" = "$(cat "$root/main.sha")"
echo

# ── 场景 2：修复顺手改了契约文档 ─────────────────────────────────
echo "--- 场景 2：修复顺手改了契约文档（门槛 2）---"
run_case contract_violation 101
root="$TMP/contract_violation"
code="$(cat "$root/exit.code")"
assert_not "改了 docs/ 时 poll.sh 以非 0 退出（拒绝提交）" test "$code" -eq 0
assert "贴了拦下评论" grep -q '^gh issue comment' "$root/gh.log"
assert "评论点名了被改的契约文件" grep -q 'docs/contract/Residue-PRD-v5.6.md' "$root/gh.log"
assert_not "没有开 PR" grep -q '^gh pr create' "$root/gh.log"
assert_not "没有推送任何分支到 origin" \
  git -C "$root/origin.git" rev-parse --verify --quiet refs/heads/auto/issue-101
assert "origin/main 没被动过" test \
  "$(git -C "$root/origin.git" rev-parse main)" = "$(cat "$root/main.sha")"
echo

# ── 场景 3：正常路径 ─────────────────────────────────────────────
echo "--- 场景 3：正常路径（门槛 3 · 不合并）---"
run_case normal 101
root="$TMP/normal"
code="$(cat "$root/exit.code")"
assert "正常路径退出码 0" test "$code" -eq 0
assert "开了 PR" grep -q '^gh pr create' "$root/gh.log"
assert "PR 以 main 为 base" grep -q -- '--base main' "$root/gh.log"
assert "分支已推到 origin" \
  git -C "$root/origin.git" rev-parse --verify --quiet refs/heads/auto/issue-101
assert "origin/main 没被动过" test \
  "$(git -C "$root/origin.git" rev-parse main)" = "$(cat "$root/main.sha")"
echo

# ── 场景 4：整轮轮询（auto-skip 标签的 issue 不该被碰）──────────
echo "--- 场景 4：整轮轮询（标签过滤）---"
run_case sweep 101 --once
root="$TMP/sweep"
code="$(cat "$root/exit.code")"
assert "整轮轮询退出码 0" test "$code" -eq 0
assert "只处理了没有 auto-skip 的 issue" grep -q 'gh issue view 101' "$root/gh.log"
assert_not "带 auto-skip 的 issue 102 没被碰" grep -q 'gh issue view 102' "$root/gh.log"
assert "只开了一个 PR" test "$(grep -c '^gh pr create' "$root/gh.log")" -eq 1
assert "poll.sh 仍按 auto-skip 标签过滤" grep -q 'auto-skip' "$POLL"
echo

# ── 门槛 3 的结构性检查 ──────────────────────────────────────────
echo "--- 门槛 3 · 结构性检查 ---"
assert_not "poll.sh 里没有合并命令（gh pr merge / --auto-merge）" \
  grep -nE 'gh[[:space:]]+pr[[:space:]]+merge|--auto-merge' "$POLL"
assert_not "poll.sh 里没有把 main 推上去的命令" \
  grep -nE 'push[^&|;]*main' "$POLL"
merged=0
for f in "$TMP"/*/gh.log; do
  if grep -qE '^gh .*(pr merge|--auto-merge)' "$f"; then merged=1; fi
done
assert "所有场景全程没有任何合并调用" test "$merged" -eq 0
echo

echo "=============================================="
echo "通过 ${PASS} 项 / 失败 ${FAIL} 项"
echo "=============================================="
if [ "$FAIL" -ne 0 ]; then
  echo "❌ 自测失败 —— poll.sh 有门槛被绕过了。"
  exit 1
fi
echo "✅ 三条硬门槛都没被绕过"
exit 0
