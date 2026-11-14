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
for f in Pages.swift PolicyPage.swift PrivacyPage.swift ReportPage.swift ConfirmDrawer.swift EvidencePage.swift MenuBarPopover.swift RootView.swift Components.swift DesignTokens.swift; do
  if [ -f "$UI_DIR/$f" ]; then ok "存在 ${f}（App 层视图）"; else bad "缺失 $f"; fi
done
# **页面模型在 Core**（不然「禁止算术」不可单测）
for f in PageModel.swift PageModelBuilder.swift; do
  if [ -f "$CORE_DIR/$f" ]; then ok "存在 ${f}（Core，可单测）"; else bad "缺失 $f"; fi
done

# 七个 page case（**限定在 Page 枚举块内**：PageGroup 也有 `= 0/1/2`，
# 全局 grep 会把它算进来，误报成 10 个）
PAGE_CASES=$(sed -n '/public enum Page:/,/^}/p' "$CORE_DIR/PageModel.swift" 2>/dev/null \
  | grep -cE "^[[:space:]]+case [A-Za-z_]+ = [0-6]([[:space:]]|$)" || true)
PAGE_CASES=${PAGE_CASES:-0}
if [ "$PAGE_CASES" -eq 7 ]; then
  ok "Page 枚举有 7 个 case（7 页 × 1 形态 = 7 ≤ 8）"
else
  bad "Page 枚举 case 数 = ${PAGE_CASES}（应为 7）"
fi

# 七页各有 View struct
PAGE_VIEWS=$(cat "$UI_DIR"/{Pages,PolicyPage,PrivacyPage,ReportPage,ConfirmDrawer,EvidencePage}.swift 2>/dev/null \
  | grep -cE "^struct (Overview|Environments|Policy|Privacy|Report|Confirm|Evidence)[A-Za-z_]*: View" || true)
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
VIEW_FILES="$UI_DIR/Pages.swift $UI_DIR/PolicyPage.swift $UI_DIR/PrivacyPage.swift $UI_DIR/ReportPage.swift $UI_DIR/ConfirmDrawer.swift $UI_DIR/EvidencePage.swift $UI_DIR/RootView.swift $UI_DIR/Components.swift $UI_DIR/MenuBarPopover.swift $UI_DIR/PageDesign.swift"
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
echo "--- 五、视觉基线落地（v2 · CR-031）---"
# ---------------------------------------------------------------------------
T="$UI_DIR/DesignTokens.swift"
for hex in 0x0D0F13 0x15181E 0x1B1F27 0xECEEF2 0x9AA1AC 0x6E7681 0x6C79F0 0xE5534B 0x46B98A 0xE8A84C 0x7C8CF8 0x56C596 0xB37A4E 0x5FB3C9; do
  if grep -qF -- "$hex" "$T" 2>/dev/null; then
    ok "色值 $hex 已落地"
  else
    bad "色值 $hex 缺失"
  fi
done

# 来源身份色必须由唯一映射函数给出（视图只查表，不自己挑色）
if grep -qF "static func source(for key: String)" "$T" 2>/dev/null; then
  ok "来源身份色有唯一映射（source(for:)）"
else
  bad "来源身份色缺少唯一映射"
fi

# 不得引入系统语义色（视觉基线 §二：状态色只有 token 里的几档）
# 允许 `Color.white`：按钮文字与低透明度分隔线用它，不承载状态语义。
if grep -qE 'Color\.(green|yellow|blue|orange|purple|pink|teal|indigo|red|gray)\b' "$UI_DIR"/*.swift 2>/dev/null; then
  bad "引入了系统语义色（状态色必须来自 DesignTokens）"
else
  ok "无系统语义色（状态色全部来自 DesignTokens）"
fi

# CR-031：比例必须由 Core 的 RatioSlot 预计算，视图不得接触分子/分母
if grep -q "struct RatioSlot" "$CORE_DIR/PageModel.swift" 2>/dev/null; then
  ok "RatioSlot 定义在 Core（比例不在视图层算）"
else
  bad "RatioSlot 未在 Core 定义"
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
  python3 - "$UI_DIR/Pages.swift" "$UI_DIR/PolicyPage.swift" "$UI_DIR/PrivacyPage.swift" \
    "$UI_DIR/ReportPage.swift" "$UI_DIR/ConfirmDrawer.swift" "$UI_DIR/EvidencePage.swift" \
    "$UI_DIR/MenuBarPopover.swift" "$UI_DIR/RootView.swift" <<'PYEOF' 2>/dev/null || echo "ERR"
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
if grep -qF 'onClearLogs()' "$UI_DIR/PrivacyPage.swift" 2>/dev/null; then
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
echo "--- 十、L0 判定的契约常量（本机绿、CI 红那一类）---"
# ---------------------------------------------------------------------------
# 背景：`L0Probe` 曾把 fd 列表的**数组下标**当成 fd 号用，注释还写着
# 「fd 号 = 数组下标（实测约束）」。本机进程 fd 恰好连续 0..7，下标与字段值相同，
# 实测"验证通过"；CI runner 上 fd 不连续（含 131/140/143/146）立刻错位。
#
# 后果不是测试红，是**误删**：用错的 fd 调 PROC_PIDFDVNODEPATHINFO 会拿到
# 别的 fd 的 (dev, ino) → L0 判「无活引用」→ 把正在被使用的文件移进废纸篓。
#
# 这类"实测巧合"写进注释后会被当成契约，所以除了修正代码，还要钉一条静态断言。

# fd 号必须来自结构体字段
# 判据用「读 .proc_fd 字段」而不是某个具体变量名 ——
# 变量名会随重构改（`fdInfo` → `info`），断言不该跟着腐坏。
# ⚠️ 不用 `\b`（单词边界）：macOS 的 BSD grep 不支持它，模式会静默不命中。
# 实测：`grep -E '\.proc_fd\b'` 未命中，`grep -E '\.proc_fd'` 命中。
# 这又是一条「工具行为跨实现不一致」——与 `plutil` / `NSError.domain` 同类。
if grep -qE '\.proc_fd' "$CORE_DIR/L0Probe.swift" 2>/dev/null; then
  ok "fd 号取自 proc_fdinfo.proc_fd 字段（不是数组下标）"
else
  bad "fd 号未取自 proc_fd 字段 → L0 判定会错位，可能误删活文件"
fi

# 不得用下标当 fd（查活的代码行，注释里的历史说明不算）
LIVE_FD_INDEX=$(grep -v '^[[:space:]]*//' "$CORE_DIR/L0Probe.swift" 2>/dev/null \
                | grep -cE 'let +fd *= *Int32\(j\)' || true)
if [ "${LIVE_FD_INDEX:-0}" -eq 0 ]; then
  ok "无「用数组下标当 fd 号」的活代码"
else
  bad "仍有 ${LIVE_FD_INDEX} 处用数组下标当 fd 号"
fi

# PROC_PIDLISTFDS 返回值是字节数，必须除以 stride
if grep -qF 'MemoryLayout<proc_fdinfo>.stride' "$CORE_DIR/L0Probe.swift" 2>/dev/null; then
  ok "PROC_PIDLISTFDS 返回值按 8 B stride 换算（不是当元素数）"
else
  bad "PROC_PIDLISTFDS 返回值未按 stride 换算 → 元素数会多 8 倍"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- 十一、L0 的 cwd 判据方向（契约 V6 · 写反了会误删）---"
# ---------------------------------------------------------------------------
# 契约原文（V6 定稿 · K2 裁定）：
#   「持有」判据 = `(dev, ino)` 命中同 uid 进程的 fd 集合，
#   **或候选（目录）是任一同 uid 进程 cwd 的祖先路径**
# 即 `isAncestor(candidate, of: cwd)`。
#
# 原实现写成 `isAncestor(cwd, of: candidate)` —— 方向相反。
# 后果：进程在 /a/b/c 工作、候选是 /a/b 时**判不出在用** → 删掉正在工作的目录。
# 而原来的测试按错误方向写了断言，所以本机全绿。
#
# 这类「测试把 bug 当规格」最难抓：断言、实现、注释三者自洽，只是都与契约相反。

if grep -qF 'isAncestor(path, of: cwd)' "$CORE_DIR/L0Probe.swift" 2>/dev/null; then
  ok "cwd 判据方向符合契约（候选是 cwd 的祖先）"
else
  bad "cwd 判据方向与契约相反 → 会删掉正在被工作的目录"
fi

# 反向锚：不得出现旧方向（活的代码行）
OLD_DIR=$(grep -v '^[[:space:]]*//' "$CORE_DIR/L0Probe.swift" 2>/dev/null \
          | grep -cE 'isAncestor\(cwd, of:' || true)
if [ "${OLD_DIR:-0}" -eq 0 ]; then
  ok "无「cwd 是候选的祖先」这一旧方向的活代码"
else
  bad "仍有 ${OLD_DIR} 处旧方向的 cwd 判据"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- 十二、容量上限的判定必须唯一且口径统一（AC-15 · CR-029）---"
# ---------------------------------------------------------------------------
# 背景：CR-029 抓到两处缺陷，根因都是「同一判定有两处实现 / 两个口径」：
#   ① 预检用目录自身 st_size、记账用递归逻辑字节 → 目录型候选上限不成立
#      （实测 200 KB vs 上限 150 KB，超 33%）
#   ② AppModel 的稳定后档漏了用户配置的上限 → 用户设置静默失效
#
# 这类缺陷**只靠单测守不住**——它需要「App 层自己算比例」这个前提成立。
# 所以再加一条静态断言：域内算术不得出现在 App 层。

# ① App 层不得自己做容量比例算术（0.10 / 0.20）
APP_CAP_ARITH=$(grep -v '^[[:space:]]*//' "$UI_DIR/AppModel.swift" 2>/dev/null \
                | grep -cE 'Int64\(Double\(total\)|\* *0\.(10|20)' || true)
if [ "${APP_CAP_ARITH:-0}" -eq 0 ]; then
  ok "App 层无容量比例算术（上限判定唯一在 Core）"
else
  bad "App 层出现 ${APP_CAP_ARITH} 处容量比例算术 → 上限判定有两处实现，必然分叉"
fi

# ② 上限判定的唯一实现处必须在 Core
if grep -qF 'public static func capacityCap(' "$CORE_DIR/TrashExecutor.swift" 2>/dev/null; then
  ok "容量上限判定在 Core（TrashExecutor.capacityCap）"
else
  bad "Core 里没有 capacityCap —— 上限判定无处安放"
fi

# ③ 预检与记账必须共用同一个字节口径函数（不得各写各的）
if grep -qF 'logicalBytes(of:' "$CORE_DIR/TrashExecutor.swift" 2>/dev/null; then
  ok "预检与记账共用 logicalBytes(of:)（同一口径）"
else
  bad "预检未走 logicalBytes(of:) → 预检与记账口径可能不一致（CR-029 的根因）"
fi

# ④ execute 必须接受预检值（AC-15：预检值随候选缓存到执行点）
if grep -qF 'preflightBytes' "$CORE_DIR/TrashExecutor.swift" 2>/dev/null; then
  ok "execute 支持预检值缓存（AC-15 / CR-022 偏差 2）"
else
  bad "execute 不接受预检值 → 契约要求的「预检值随候选缓存到执行点」无法满足"
fi

# ⑤ `t1` / `t2` 两个取数时点必须有载体（R2 已记「❌ 无载体」）
for field in bytesPreview bytesMeasuredAt; do
  if grep -qF "public let $field" "$CORE_DIR/TrashExecutor.swift" 2>/dev/null; then
    ok "ExecutionRecord 有 $field 载体（AC-15 的两时点判据有落点）"
  else
    bad "ExecutionRecord 缺 $field → AC-15 的「实际删除量」没有唯一取数时点，判据退化为恒真"
  fi
done

# ⑥ 实测超限必须能回滚（`blocked_cap` + 移回原位）
if grep -qF '实测超上限，已移回原位' "$CORE_DIR/TrashExecutor.swift" 2>/dev/null; then
  ok "有「实测超上限 → 移回原位」的回滚路径（IF-07：AC-15 是硬上限）"
else
  bad "缺实测超限回滚 → 预检通过但实际超限时上限会被突破"
fi

# ⑦ App 层必须把扫描期算好的 t1 传进去（IF-08 的唯一来源）
if grep -qF 'preflightBytes: preflight' "$UI_DIR/AppModel.swift" 2>/dev/null; then
  ok "生产路径传入扫描期缓存的 t1 预检值（IF-08）"
else
  bad "生产路径未传 t1 预检值 → 预检退化为执行时刻实时值，「预检通过→实测超限」路径不可达"
fi

# ⑧ **执行路径必须被接线自检走过**（唯一真动用户文件的模块）
if grep -qF 'TrashExecutor(trashDirectory:' "$UI_DIR/WiringSelfCheck.swift" 2>/dev/null; then
  ok "执行路径已被接线自检覆盖（不是只靠单测）"
else
  bad "接线自检未走过执行路径 → 「真动用户文件」那一层无端到端证据"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- 十三、扫描必须在主 actor 之外（2026-11-09 · 「点击扫描就卡住」）---"
# ---------------------------------------------------------------------------
# 背景：`AppModel` 是 `@MainActor` 隔离的。
# **`@MainActor` 类上的 `async` 函数并不会自动离开主线程** ——
# `async` 只让函数「可以被挂起」，函数体里的**同步代码仍在主 actor 上执行**。
#
# 于是原实现把整个扫描（实测 222,858 项 ≈ 12.2 秒的全同步 `stat`）
# 跑在主线程上 → 界面**彻底冻结**。
#
# 这类缺陷**单测看不出来**（单测不渲染界面），
# 所以除了并发单测，还要加**静态断言**钉住代码形态。

# ① 扫描引擎必须声明 Sendable（否则 Task.detached 送不进去）
if grep -qE 'public struct ScanEngine: Sendable' "$CORE_DIR/ScanEngine.swift" 2>/dev/null; then
  ok "ScanEngine 已声明 Sendable（可安全送进 Task.detached）"
else
  bad "ScanEngine 未声明 Sendable → 扫描无法离开主 actor，界面必卡"
fi

# ② runScan 里必须有 Task.detached（扫描搬走）
if grep -qF 'Task.detached' "$UI_DIR/AppModel.swift" 2>/dev/null; then
  ok "runScan 用 Task.detached 把扫描搬离主 actor"
else
  bad "runScan 无 Task.detached → 扫描在主 actor 上同步跑，界面会冻结"
fi

# ③ 扫描引擎本身不得被 @MainActor 隔离（否则搬走也没用）
if grep -qE '@MainActor' "$CORE_DIR/ScanEngine.swift" 2>/dev/null; then
  bad "ScanEngine 被 @MainActor 隔离 → 在后台任务里调它会被拉回主线程"
else
  ok "ScanEngine 未被 @MainActor 隔离（可在后台安全调用）"
fi

# ④ 必须有进度汇报（只搬走不汇报 = 用户看到「按了没反应」）
if grep -qF 'progressEvery' "$CORE_DIR/ScanEngine.swift" 2>/dev/null; then
  ok "扫描引擎支持进度回调（间隔可控）"
else
  bad "扫描引擎无进度回调 → 界面能动但没反馈，用户仍会以为卡死"
fi

# ⑤ 界面必须显示进度 + 提供取消
if grep -qF 'scanProgress.displayText' "$UI_DIR/RootView.swift" 2>/dev/null; then
  ok "界面显示扫描进度（用户看得到它在动）"
else
  bad "界面不显示扫描进度 → 「按了没反应」与卡死无异"
fi
if grep -qF 'app.cancelScan()' "$UI_DIR/RootView.swift" 2>/dev/null; then
  ok "界面提供取消扫描（12 秒不能反悔）"
else
  bad "界面无取消入口 → 用户必须等完 12 秒"
fi

# ⑥ **所有 `engine.scan` 调用都必须落在 `Task.detached` 块内**
#
# ⚠️ **第一版这条判据是错的**（已修）：
#   原写法是「grep 有没有 `let x = try engine.scan(`」——
#   但**合法的那个调用也在 detached 块里**（只是缩进更深），
#   按行匹配根本区分不了「在后台」与「在主 actor」。
#   证伪时注入了「主 actor 上直接调 engine.scan」，**断言没报红**。
#
# 正解：**按缩进层级判定** ——
# `Task.detached` 块内的调用，其缩进**严格大于**块起始行；
# 而主 actor 上的直接调用，缩进**小于或等于**块起始行。
#
# 这里用 Python 做结构判定（比 grep 可靠）：
DIRECT_ON_ACTOR=$(
  python3 - "$UI_DIR/AppModel.swift" <<'PYEOF' 2>/dev/null || echo "ERR"
import re, sys
lines = open(sys.argv[1], encoding='utf-8').read().split('\n')
# 找所有 `Task.detached` 的起始行，取其缩进作为「后台块」的基准
detached_indents = []
for i, l in enumerate(lines):
    if 'Task.detached' in l and not l.strip().startswith('//'):
        detached_indents.append((i, len(l) - len(l.lstrip())))
if not detached_indents:
    print("NO_DETACHED"); raise SystemExit

bad = []
for i, l in enumerate(lines):
    t = l.strip()
    if t.startswith('//'):
        continue
    if 'engine.scan(' not in l:
        continue
    indent = len(l) - len(l.lstrip())
    # 该调用必须**缩进深于**至少一个 detached 块
    # （调用所在行的缩进 > detached 起始行的缩进 → 它在块内）
    inside = any(indent > di for _, di in detached_indents)
    if not inside:
        bad.append(i + 1)
print(len(bad))
PYEOF
)
if [ "${DIRECT_ON_ACTOR}" = "0" ]; then
  ok "所有 engine.scan 调用都在 Task.detached 块内（扫描不会跑回主线程）"
elif [ "${DIRECT_ON_ACTOR}" = "NO_DETACHED" ]; then
  bad "AppModel 里找不到 Task.detached → 扫描在主 actor 上同步跑"
else
  bad "有 ${DIRECT_ON_ACTOR} 处 engine.scan 调用不在 detached 块内 → 扫描会跑回主线程"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=============================================="
echo "通过 $PASS 项 / 失败 $FAIL 项"
echo "=============================================="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
