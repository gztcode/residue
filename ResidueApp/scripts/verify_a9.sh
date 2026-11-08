#!/bin/bash
# =============================================================================
# Residue · A-9
#
# 【变量界定规则】**凡是 `$VAR` 后面紧跟中文/全角字符，一律写 `${VAR}`。**
# bash 会把 `$EMPTY_ACTIONS（` 整体当作变量名的一部分（全角括号是多字节），
# 于是报 `unbound variable` 而看起来像「变量没赋值」——这条坑在本脚本里
# 已经踩过至少 4 次，每次都要花几分钟才认出。写死在这里，别再踩。
 验收校验（七页骨架 + 语义位类型化）
#
# 用法：./scripts/verify_a9.sh
#
# 核心目的：把「界面禁止算术」（R2 §3 · L4）从**纪律要求**变成**机器断言**。
#
# A-9 验收口径（K2 台账）：
#   ① 七页可导航
#   ② 界面所有数字来自 Metrics / GateEvaluator
#   ③ 只读态显示「只读，不结算」
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

UI_DIR="Sources/ResidueApp"
CORE_DIR="Sources/ResidueCore"
PASS=0; FAIL=0

ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

echo "=============================================="
echo "A-9 验收校验（七页骨架）"
echo "=============================================="

# ---------------------------------------------------------------------------
echo ""
echo "--- 一、① 七页可导航 ---"
# ---------------------------------------------------------------------------
for f in Pages.swift RootView.swift Components.swift DesignTokens.swift; do
  if [ -f "$UI_DIR/$f" ]; then ok "存在 ${f}（App 层视图）"; else bad "缺失 $f"; fi
done
# **页面模型在 Core**（不然「禁止算术」不可单测）
for f in PageModel.swift PageModelBuilder.swift; do
  if [ -f "$CORE_DIR/$f" ]; then ok "存在 ${f}（Core，可单测）"; else bad "缺失 $f"; fi
done

# 七个 page case
PAGE_CASES=$(grep -cE "^[[:space:]]+case [A-Za-z_]+ = [0-6]([[:space:]]|$)" "$CORE_DIR/PageModel.swift" 2>/dev/null | head -1 || true)
PAGE_CASES=${PAGE_CASES:-0}
if [ "$PAGE_CASES" -eq 7 ]; then
  ok "Page 枚举有 7 个 case（7 页 × 1 形态 = 7 ≤ 8）"
else
  bad "Page 枚举 case 数 = ${PAGE_CASES}（应为 7）"
fi

# 七页各有 View struct
PAGE_VIEWS=$(grep -cE "^struct (Overview|Environments|Policy|Privacy|Report|Confirm|Evidence)[A-Za-z_]*: View" "$UI_DIR/Pages.swift" 2>/dev/null | head -1 || true)
PAGE_VIEWS=${PAGE_VIEWS:-0}
if [ "$PAGE_VIEWS" -ge 7 ]; then
  ok "七页视图 struct 齐（找到 $PAGE_VIEWS 个）"
else
  bad "七页视图 struct 只有 $PAGE_VIEWS 个（应 ≥ 7）"
fi

# 内容分发覆盖全部七页
if grep -q "switch selection" "$UI_DIR/RootView.swift" 2>/dev/null; then
  ok "RootView 按 selection 分发内容"
else
  bad "RootView 缺内容分发"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- 二、② 界面所有数字来自 Metrics（**禁止算术**）---"
# ---------------------------------------------------------------------------

# 2.1 UI 层不得出现「对两个 Int 做加减乘除」的表达式。
#     允许的例外：布局常量（Spacing/Radius/frame 宽度）、索引步进（i + 1）、
#                 字符串插值里的页码（pageIndex + 1）、日期计算。
#     判据：**数值不得来自 Metrics 之外的运算**——具体查「变量 ± 变量」形态。
SUSPECT=$(
  grep -nE '\$[A-Za-z_][A-Za-z0-9_]*\s*[-+*/]\s*\$?[A-Za-z_]' "$UI_DIR"/*.swift 2>/dev/null \
  | grep -vE 'Spacing|Radius|width|height|padding|frame|offset|opacity|size|cornerRadius' \
  || true
)
if [ -z "$SUSPECT" ]; then
  ok "UI 层无「变量与变量之间的数值运算」（布局常量已排除）"
else
  echo "      可疑行："
  echo "$SUSPECT" | sed 's/^/        /' | head -10
  bad "UI 层存在可疑的数值运算（可能绕过 Metrics）"
fi

# 2.2 UI 层不得对**域内度量**做运算（这是「L4 禁止算术」的实质）
#
# ⚠️ 判据要说清，否则会误报：
#   `xxx.count - 1` 是**数组下标边界**（取最后一个元素），属合法布局运算；
#   `ReportMatrix.columns[min(idx, ...)]` 是**索引裁剪**，也合法。
#   真正要禁的是「对 K / T / a / b / slotCount 这类**域内度量**做算术」——
#   那会产生契约里没有的第二个数。
# ⚠️ **只扫视图文件**：`AppModel.swift` 是编排层，`* 1000`（毫秒换算）
#    与 `/ 1_000_000`（错误文案里的 MB 显示）不是域内度量运算。
#    但**域内口径（如 M1 计数日推进）必须在 Core**——见下面的单独断言。
VIEW_FILES="$UI_DIR/Pages.swift $UI_DIR/RootView.swift $UI_DIR/Components.swift $UI_DIR/PageDesign.swift"
DOMAIN_ARITH=$(
  grep -nE '(slotCount|countedDays|missCount|pNowCount|fSetBits|totalBytes)[[:space:]]*[-+*/][[:space:]]*[A-Za-z0-9]' \
    $VIEW_FILES 2>/dev/null || true
)
if [ -z "$DOMAIN_ARITH" ]; then
  ok "UI 层无「对域内度量做算术」（K/T/a/b 均以 SemanticSlot 传递）"
else
  echo "$DOMAIN_ARITH" | sed 's/^/        /' | head -5
  bad "UI 层对域内度量做了算术（应交给 Metrics 侧算好）"
fi

# 2.2b 常见「第二套算法」模式
SECOND_ALGO=0
# 同样**只扫视图文件**：`* 1000`（毫秒）与 `/ 1000`（秒）属编排层的单位换算，
# 不是「对域内度量算百分比」。真正要禁的是视图里出现 `* 100`（百分比）、
# `/ 1024`（KB 换算——那是 `MetricUnit.formatBytes` 的职责，唯一一处）。
for pat in 'total - ' ' / total' '/ 1024'; do
  if grep -qF -- "$pat" $VIEW_FILES 2>/dev/null; then
    bad "视图层出现可疑运算模式「${pat}」（格式化应在 Core 的唯一一处）"
    SECOND_ALGO=1
  fi
done
if [ "$SECOND_ALGO" -eq 0 ]; then
  ok "UI 层无「百分比 / 单位换算 / 求差」类第二套算法"
fi

# 2.3 SemanticSlot 必须定义在 Core（可被单测约束），不得在 App 层
if grep -q "enum SemanticSlot" "$CORE_DIR/SemanticSlot.swift" 2>/dev/null; then
  ok "SemanticSlot 定义在 ResidueCore（可被单测约束）"
else
  bad "SemanticSlot 未在 ResidueCore 定义（放 App 层就无法单测）"
fi

if grep -q "enum SemanticSlot" "$UI_DIR"/*.swift 2>/dev/null; then
  bad "App 层重复定义了 SemanticSlot（两处定义 → 两套行为）"
else
  ok "App 层未重复定义 SemanticSlot"
fi

# 2.4 SemanticSlot 不得含闭包（类型级禁止运算的关键）
if grep -A 30 "enum SemanticSlot" "$CORE_DIR/SemanticSlot.swift" 2>/dev/null | grep -qE 'case .*\(.*->.*\)'; then
  bad "SemanticSlot 含闭包形态（闭包 = 允许任意运算，类型约束失效）"
else
  ok "SemanticSlot 不含闭包（运算无法藏进槽位）"
fi

# 2.5 页面渲染数值必须经 SemanticSlotView（不得自己 Text("\(int)"））
RAW_INT_TEXT=$(
  grep -nE 'Text\("\\\([^)]*(count|total|bytes|value|a|b|K|T)[^)]*\)"' "$UI_DIR"/*.swift 2>/dev/null \
  | grep -v "SemanticSlotView" || true
)
if [ -z "$RAW_INT_TEXT" ]; then
  ok "无「直接插值数值到 Text」的渲染（须经 SemanticSlotView）"
else
  echo "$RAW_INT_TEXT" | sed 's/^/        /' | head -5
  bad "存在绕过 SemanticSlotView 的数值渲染"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- 三、③ 只读态 ---"
# ---------------------------------------------------------------------------
if grep -qF '只读，不结算' "$CORE_DIR/SemanticSlot.swift" 2>/dev/null; then
  ok "只读态文案「只读，不结算」已定义"
else
  bad "缺只读态文案"
fi

if grep -q "ReadOnlyBanner" "$UI_DIR/RootView.swift" 2>/dev/null; then
  ok "只读态顶部说明条已接进外壳"
else
  bad "只读态说明条未接进外壳"
fi

# 只读态必须禁用写操作
if grep -q "disabled(model.readOnly)" "$UI_DIR"/*.swift 2>/dev/null; then
  ok "写操作在只读态被禁用"
else
  bad "写操作未按只读态禁用"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- 四、契约文案逐字（PRD / R2 唯一样式串）---"
# ---------------------------------------------------------------------------
check_copy() {
  local desc="$1" needle="$2" core_file="$3"
  if grep -qF -- "$needle" "$core_file" 2>/dev/null; then
    ok "$desc"
  else
    bad "${desc}（缺「${needle}」）"
  fi
}
C="$CORE_DIR/SemanticSlot.swift"
check_copy "M1 第二串「待结算扫描（无需操作）」" "待结算扫描（无需操作）" "$C"
check_copy "「本轮未结算」（报告未产出）" "本轮未结算" "$C"
check_copy "「—（由更高版本维护）」" "由更高版本维护" "$C"
check_copy "「14 日内可一键恢复」" "14 日内可一键恢复" "$C"
check_copy "「90 天，或可回收字节满 200 MB」" "90 天" "$C"
check_copy "清除范围含「不重置」" "不重置" "$C"

# ---------------------------------------------------------------------------
echo ""
echo "--- 五、视觉基线落地（最小集）---"
# ---------------------------------------------------------------------------
T="$UI_DIR/DesignTokens.swift"
for hex in 0x0F1115 0x16191F 0xE6E8EC 0x8B9099 0x5E6AD2 0xD9534F; do
  if grep -qF -- "$hex" "$T" 2>/dev/null; then
    ok "色值 $hex 已落地"
  else
    bad "色值 $hex 缺失"
  fi
done

# 不得引入第三档语义色（视觉基线 §二）
if grep -qE 'Color\.(green|yellow|blue|orange|purple|pink|teal|indigo)' "$UI_DIR"/*.swift 2>/dev/null; then
  bad "引入了第三档语义色（视觉基线 §二：只有两档状态色）"
else
  ok "无第三档语义色（只有信号色 + 危险色）"
fi

# 表格行高 32 固定
if grep -qF "32" "$T" 2>/dev/null; then
  ok "表格行高 32 pt 固定"
else
  bad "表格行高缺失"
fi

# 只深色（视觉基线 §六）
if grep -q "preferredColorScheme(.dark)" "$UI_DIR/RootView.swift" 2>/dev/null; then
  ok "本期只有深色（preferredColorScheme(.dark)）"
else
  bad "深色未固定"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- 六、数据层是否真接线（常在线判 NO-GO 的第一条理由）---"
# ---------------------------------------------------------------------------
# 背景：本项曾为「0 处实例化」——App 层只引用 SemanticSlot / StateLabel / UICopy
# 三个纯展示类型，业务逻辑一行都没进运行路径（176 个测试白跑）。
# **这条检查不许它静默回来。**
WIRED=0
UNWIRED=""
# ⚠️ 用 `-F` 字面匹配：`(` 在 ERE 里是元字符，`grep -E 'StateFile('` 匹配不到任何东西
#（第一版就是这么错的：报「未接线」而实际已接）。
for t in 'StateFile(' 'RecordWriter(' 'ScanEngine()' 'L0Probe.' 'PageModelBuilder.'; do
  if grep -qF -- "$t" "$UI_DIR"/*.swift 2>/dev/null; then
    WIRED=$((WIRED + 1))
  else
    UNWIRED="$UNWIRED $t"
  fi
done
if [ "$WIRED" -ge 4 ]; then
  ok "数据层已接线（$WIRED / 5 个核心类型在 App 层被调用）"
else
  bad "数据层接线不足：只有 $WIRED / 5（未接：${UNWIRED}）"
fi

if grep -q "PageModel.skeleton()" "$UI_DIR/RootView.swift" 2>/dev/null; then
  bad "产品路径仍在读 PageModel.skeleton()（硬编码假数据）"
else
  ok "产品路径不读渲染样例数据"
fi

if grep -q "advanceCountedDay" "$CORE_DIR/Metrics.swift" 2>/dev/null \
   && grep -q "advanceCountedDay" "$UI_DIR/AppModel.swift" 2>/dev/null; then
  ok "M1 计数日推进在 Core（编排层只调用，不自行加一）"
else
  bad "M1 计数日推进未归位到 Core（存在第二套算法风险）"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- 七、定时任务与登录项（ADR-02 / N3）---"
# ---------------------------------------------------------------------------
# 背景：这两项曾是**功能缺失**（源码 0 处），而 verify_a5 把它记成「环境所限」。
# 现在实现了，本节负责「不许它退回去」。
if grep -qF 'SMAppService.mainApp' "$UI_DIR/LoginItemManager.swift" 2>/dev/null; then
  ok "SMAppService.mainApp 已接入（登录项）"
else
  bad "SMAppService.mainApp 未接入 → 登录项能力缺失"
fi

# 四态必须逐个映射（ADR-02 原表）
MISSING_STATES=""
for st in enabled requiresApproval notRegistered notFound; do
  grep -qF ".$st" "$CORE_DIR/LoginItemState.swift" 2>/dev/null || MISSING_STATES="$MISSING_STATES $st"
done
if [ -z "$MISSING_STATES" ]; then
  ok "登录项四态齐（enabled / requiresApproval / notRegistered / notFound）"
else
  bad "登录项状态缺：${MISSING_STATES}"
fi

# 非 enabled 不得可调度（ADR-02 硬约束）
if grep -qF 'self == .enabled' "$CORE_DIR/LoginItemState.swift" 2>/dev/null; then
  ok "只有 .enabled 允许调度（其余三态不执行）"
else
  bad "allowsScheduling 未限定为 .enabled → 会把「登录项被关」显示成在跑"
fi

# 排程计算必须在 Core（可单测）
if [ -f "$CORE_DIR/SchedulePlanner.swift" ]; then
  ok "SchedulePlanner 在 Core（排程可单测）"
else
  bad "SchedulePlanner 不在 Core → 排程逻辑不可测"
fi

if grep -qF 'SchedulePlanner.isDue' "$UI_DIR/ScheduledRunner.swift" 2>/dev/null; then
  ok "定时任务壳调用 Core 排程（不自行判定到期）"
else
  bad "定时任务壳未调用 SchedulePlanner（存在第二套排程算法）"
fi

# 关窗驻留（ADR-02）
if grep -qF 'applicationShouldTerminateAfterLastWindowClosed' "$UI_DIR/AppDelegate.swift" 2>/dev/null; then
  ok "关窗驻留已实现（applicationShouldTerminateAfterLastWindowClosed）"
else
  bad "缺关窗驻留 → 用户点红叉就把定时任务关了"
fi

# ADR-02：**不设** LSUIElement
if grep -qF 'LSUIElement' "$UI_DIR/../Resources/Info.plist.in" 2>/dev/null; then
  bad "Info.plist 模板出现 LSUIElement（ADR-02 明确要求不设）"
else
  ok "Info.plist 模板未设 LSUIElement（符合 ADR-02）"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- 八、错误码表（R3 契约维度缺口：码只活在注释里）---"
# ---------------------------------------------------------------------------
# 背景：R3 契约维度评审指出 `"E-xxx"` 字面量在 Sources 出现 0 次，
# 23 个码全部只活在注释里 → 「码 ↔ 用例」核对无法机器化。
# 现已代码化，本段调用独立脚本核「代码 ↔ R2 文档」的一致性。
if [ -f "scripts/verify_codes.py" ]; then
  CODE_OUT=$(python3 scripts/verify_codes.py 2>&1)
  CODE_FAIL=$(echo "$CODE_OUT" | grep -c "^  ✗" || true)
  if [ "${CODE_FAIL:-0}" -eq 0 ]; then
    ok "错误码表与 R2 §6 一致（11 项：码集合 / 归类 / AC-14 三类 / 测试覆盖）"
  else
    echo "$CODE_OUT" | grep "^  ✗" | sed 's/^/        /'
    bad "错误码表校验失败 $CODE_FAIL 项"
  fi
else
  bad "缺 scripts/verify_codes.py"
fi

if grep -q "DiagnosticCode" "$CORE_DIR/DiagnosticCode.swift" 2>/dev/null \
   && grep -q "public enum DiagnosticCode" "$CORE_DIR/DiagnosticCode.swift"; then
  ok "DiagnosticCode 在 Core（可被单测约束）"
else
  bad "DiagnosticCode 不在 Core → 码表无法被单测约束"
fi

# E-101 / E-108 必须二分（归成一类 → AC-14 第一类永不出现）
if grep -q "case pathNotFound" "$CORE_DIR/ScanEngine.swift" 2>/dev/null \
   && grep -q "case pathDenied" "$CORE_DIR/ScanEngine.swift"; then
  ok "ScanError 已按成因二分（pathNotFound=E-101 / pathDenied=E-108）"
else
  bad "ScanError 未二分 → AC-14 第一类的授权指引永远不出现"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- 九、空实现检测（点了没反应、也不报错，比没有按钮更糟）---"
# ---------------------------------------------------------------------------
# 背景：本轮实测抓到 3 处「按钮存在但 action 为空」——
#   ④ 一键清除 / ⑥ 立即执行（只关抽屉）/ ⑦ 恢复。
# 这类缺陷最阴：**用户以为做成了**，而产品什么都不做、也不报错。
EMPTY_ACTIONS=$(
  python3 - "$UI_DIR/Pages.swift" "$UI_DIR/RootView.swift" <<'PYEOF' 2>/dev/null || echo "ERR"
import re, sys
bad = []
for path in sys.argv[1:]:
    src = open(path, encoding='utf-8').read()
    lines = src.split('\n')
    for i, line in enumerate(lines):
        # 形如：Button("X") {  → 下一行只有注释 → 再下一行 }
        m = re.search(r'Button\(.*\)\s*\{\s*$', line)
        if not m:
            continue
        j = i + 1
        body = []
        while j < len(lines) and lines[j].strip() not in ('}', ''):
            body.append(lines[j].strip())
            j += 1
        # 全是注释 = 空实现
        if body and all(b.startswith('//') for b in body):
            bad.append('%s:%d' % (path.split('/')[-1], i + 1))
print(' '.join(bad))
PYEOF
)
if [ -z "$EMPTY_ACTIONS" ]; then
  ok "无「空 action」按钮（点了会真的有反应，或按钮不存在）"
else
  bad "存在空 action 的按钮：${EMPTY_ACTIONS}（用户点了没反应也不报错）"
fi

# 主线动作必须真接上（清除 / 执行）
if grep -qF 'onClearLogs()' "$UI_DIR/Pages.swift" 2>/dev/null; then
  ok "④ 页一键清除已接真实动作（AC-12）"
else
  bad "④ 页一键清除仍是空实现"
fi
if grep -qF 'app.executeBatch()' "$UI_DIR/RootView.swift" 2>/dev/null; then
  ok "⑥ 页「立即执行」已接真实动作（AC-04）"
else
  bad "⑥ 页「立即执行」只关抽屉、未执行（**用户会以为清理过了**）"
fi
if grep -qF 'app.clearLogs()' "$UI_DIR/RootView.swift" 2>/dev/null; then
  ok "清除回调已从 AppModel 传入（不是 UI 层自己造）"
else
  bad "清除回调未接"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=============================================="
echo "通过 $PASS 项 / 失败 $FAIL 项"
echo "=============================================="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
