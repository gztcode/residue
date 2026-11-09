#!/bin/bash
# Residue PRD 全量校验入口
# 用法：./tests/contract/check_all.sh [PRD路径]
#
# ⚠ 默认路径**自动发现最新版本**（不写死版本号）——
#   写死版本号会「核旧稿却打印全部通过」（第 18 轮 S18-07 的教训；
#   本脚本此前写死 v5.2 → CR-022 落地时才发现它在核旧稿）。
#
# 目录重组后：契约文档在 docs/contract/，本脚本在 tests/contract/。
# 通过**脚本自身位置**推导仓库根，不依赖调用者的 cwd。
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"          # tests/contract
ROOT="$(cd "$HERE/../.." && pwd)"               # 仓库根
CONTRACT="$ROOT/docs/contract"

if [ $# -ge 1 ]; then
  P="$1"
else
  P=$(ls "$CONTRACT"/Residue-PRD-v*.md 2>/dev/null | sort -V | tail -1)
  [ -z "$P" ] && { echo "找不到 docs/contract/Residue-PRD-v*.md"; exit 1; }
fi

echo "=========================================="
echo "Residue PRD 校验：$(basename "$P")"
echo "=========================================="
fail=0

# 这些脚本内部用相对文件名（glob 'Residue-PRD-v*.md' 等），
# 故在 docs/contract/ 下执行；脚本本身用绝对路径调用。
cd "$CONTRACT"
for s in verify18.py verify_claims.py verify_single_def.py verify_cr022.py; do
  echo ""
  echo "--- $s ---"
  if [ -f "$HERE/$s" ]; then
    python3 "$HERE/$s" "$P" || fail=1
  else
    # 缺脚本**必须失败**。此前这里是静默跳过：把四个脚本全删掉，
    # 本脚本仍打印「✅ 全部校验通过」并 exit 0 —— 与 ci.yml 那次
    # 「管道吞退出码导致永远绿」是同一类假绿，只是发生在「文件不见了」这个方向。
    echo "❌ 缺少校验脚本：$s"
    fail=1
  fi
done
echo ""
if [ "$fail" = "0" ]; then
  echo "✅ 全部校验通过"
else
  echo "❌ 存在失败项"
fi
exit $fail
