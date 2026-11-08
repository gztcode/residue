#!/bin/bash
# Residue PRD 全量校验入口
# 用法：./check_all.sh [PRD路径]
#
# ⚠ 默认路径**自动发现最新版本**（不写死版本号）——
#   写死版本号会「核旧稿却打印全部通过」（第 18 轮 S18-07 的教训；
#   本脚本此前写死 v5.2 → CR-022 落地时才发现它在核旧稿）。
set -u
cd "$(dirname "$0")"

if [ $# -ge 1 ]; then
  P="$1"
else
  P=$(ls Residue-PRD-v*.md 2>/dev/null | sort -V | tail -1)
  [ -z "$P" ] && { echo "找不到 Residue-PRD-v*.md"; exit 1; }
fi

echo "=========================================="
echo "Residue PRD 校验：$P"
echo "=========================================="
fail=0
for s in verify18.py verify_claims.py verify_single_def.py verify_cr022.py; do
  if [ -f "$s" ]; then
    echo ""
    echo "--- $s ---"
    python3 "$s" "$P" || fail=1
  fi
done
echo ""
if [ "$fail" = "0" ]; then
  echo "✅ 全部校验通过"
else
  echo "❌ 存在失败项"
fi
exit $fail
