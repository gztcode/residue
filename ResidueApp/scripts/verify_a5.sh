#!/bin/bash
# =============================================================================
# Residue · A-5 验收校验（ADR-10 / §10.1）
#
# 用法：./scripts/verify_a5.sh [.app 路径]
#
# 这份脚本的**核心价值是「如实分级」**：
#   把 A-5 的三条验收口径拆成「本机可验」与「必须有真身份才能验」两组，
#   后者**明确标为未覆盖**，而不是默默算通过。
#
# A-5 验收口径（K2 台账）：
#   ① 产出可 `stapler staple` 的 `.app`
#   ② `SMAppService` 在 `.app` 下不抛签名错
#   ③ TCC 面板能认到
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

# ---------------------------------------------------------------------------
# 【跨版本健壮性】从 Info.plist 取一个键的值；**键不存在时输出空串**
#
# ⚠️ **不能用 `plutil -extract <key> ... || echo ""`**：
#   macOS 15 上 `plutil -extract` 在键不存在时**把错误信息写进 stdout**（不是 stderr），
#   于是 `||` 兜底分支不会触发，错误文本被当成键值。
#   实测（GitHub macOS-15 runner）：
#     LSUI = "build/Residue.app/Contents/Info.plist: Could not extract value, error: ..."
#   结果断言把「键不存在」判成「设了错值」→ **误报**。
#   同一脚本在本机 macOS 27 上是「空串 + 非零退出码」，所以本地永远绿。
#
#   这与本项目此前 4 次「校验脚本自己说谎」同类，但方向相反：
#   前几次是**漏报**（该红的时候绿），这次是**误报**（该绿的时候红）。
#   **判据不可靠，两个方向都会出错。**
#
# 用 PlistBuddy 先判存在性再取值，行为跨版本一致。
plist_get() {
  local key="$1" plist="$2"
  if /usr/libexec/PlistBuddy -c "Print :$key" "$plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null
  else
    echo ""
  fi
}

APP="${1:-build/Residue.app}"
PASS=0; FAIL=0; SKIP=0; SKIPPED_ITEMS=()

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
skip() { echo "  ⊘ $1"; SKIP=$((SKIP+1)); SKIPPED_ITEMS+=("$1"); }

echo "=============================================="
echo "A-5 验收校验：$APP"
echo "=============================================="

if [ ! -d "$APP" ]; then
  echo "✗ 找不到 .app：${APP}（先跑 ./scripts/make_app.sh）" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- 一、bundle 结构（ADR-10 要求的最小子集）---"
# ---------------------------------------------------------------------------
for p in "Contents/Info.plist" "Contents/MacOS/Residue"; do
  if [ -e "$APP/$p" ]; then ok "存在 $p"; else bad "缺失 $p"; fi
done

if [ -f "$APP/Contents/_CodeSignature/CodeResources" ]; then
  ok "存在签名资源 CodeResources"
else
  bad "缺 _CodeSignature/CodeResources（未签名）"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- 二、Info.plist 关键键（ADR-10 逐条）---"
# ---------------------------------------------------------------------------
PLIST="$APP/Contents/Info.plist"
if plutil -lint "$PLIST" > /dev/null 2>&1; then ok "Info.plist 是合法 plist"; else bad "Info.plist 不合法"; fi

check_key() {
  local key="$1" want="$2"
  local got
  got="$(plist_get "$key" "$PLIST")"
  if [ "$got" = "$want" ]; then
    ok "$key = $want"
  else
    bad "$key = '${got}'（应为 '$want'）"
  fi
}

check_key "CFBundleIdentifier" "com.residue.app"
check_key "LSMinimumSystemVersion" "14.0"

for k in CFBundleShortVersionString CFBundleVersion NSHumanReadableCopyright; do
  v="$(plist_get "$k" "$PLIST")"
  if [ -n "$v" ]; then ok "$k 有值（${v}）"; else bad "$k 缺失或为空"; fi
done

# 菜单栏形态（**ADR-02 原文：不设 LSUIElement** —— 需要主窗口与常规激活行为）
# ⚠️ 本检查曾写成「必须为 true」，把断言钉在了错的一侧；ADR-02 从未如此要求。
LSUI=$(plist_get LSUIElement "$PLIST")
if [ -z "$LSUI" ]; then
  ok "未设 LSUIElement（符合 ADR-02：需要主窗口与 Dock 激活行为）"
else
  bad "设了 LSUIElement = $LSUI → 失去 Dock 与常规激活（ADR-02 明确要求不设）"
fi

# 图标（C5：缺它时 Finder / 登录项 / TCC 面板显示白纸，影响 A-5 ③ 可发现性）
if [ -f "$APP/Contents/Resources/Residue.icns" ]; then
  ok "应用图标已打入 bundle（Residue.icns）"
else
  bad "bundle 内缺 Residue.icns → Finder/登录项/TCC 显示通用白纸图标"
fi
if [ "$(plist_get CFBundleIconFile "$PLIST")" = "Residue" ]; then
  ok "Info.plist 声明 CFBundleIconFile = Residue"
else
  bad "Info.plist 未声明 CFBundleIconFile"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- 三、签名与 Hardened Runtime（§10.1 第 1、2 条）---"
# ---------------------------------------------------------------------------
if codesign --verify --deep --strict "$APP" > /dev/null 2>&1; then
  ok "codesign --verify --deep --strict 通过"
else
  bad "codesign --verify 失败（签名损坏）"
fi

# 注意 `grep -q` 与 `pipefail` 的冲突（本脚本也开了 pipefail）：
# `grep -q` 命中后立即退出，上游写管道时收到 SIGPIPE（141），
# 整条管道被判成失败 → 明明匹配却走 else 分支。全部改成 `grep … >/dev/null`。
if codesign -d --verbose=2 "$APP" 2>&1 | grep "flags=.*runtime" >/dev/null; then
  ok "Hardened Runtime 已启用（公证前提）"
else
  bad "Hardened Runtime 未启用 → 公证必被拒"
fi

# 逐 Mach-O 都被签（ADR-10「逐 Mach-O 签名」）
MACHO_UNSIGNED=0
while IFS= read -r -d '' f; do
  if file "$f" | grep "Mach-O" >/dev/null; then
    if ! codesign --verify "$f" > /dev/null 2>&1; then
      MACHO_UNSIGNED=$((MACHO_UNSIGNED+1))
      echo "      未签: ${f#$APP/}"
    fi
  fi
done < <(find "$APP" -type f -print0)
if [ "$MACHO_UNSIGNED" -eq 0 ]; then ok "bundle 内所有 Mach-O 均已签名"; else bad "$MACHO_UNSIGNED 个 Mach-O 未签名"; fi

# entitlements：不得含 get-task-allow=true，不得含 com.apple.security.*
ENT="$(codesign -d --entitlements :- "$APP" 2>/dev/null || true)"
if echo "$ENT" | grep -A1 "get-task-allow" 2>/dev/null | grep "<true/>" >/dev/null; then
  bad "entitlements 含 get-task-allow=true（公证必被拒）"
else
  ok "无 get-task-allow=true"
fi
if echo "$ENT" | grep "com.apple.security" >/dev/null; then
  bad "entitlements 含 com.apple.security.*（首版应为空：非沙盒 + 零外发）"
else
  ok "无 com.apple.security.*（非沙盒、零外发）"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- 四、测试注入点剥离（§10.1 第 10 条）---"
# ---------------------------------------------------------------------------
BIN="$APP/Contents/MacOS/Residue"
HITS="$(strings "$BIN" | grep -c "RESIDUE_TEST_" || true)"
if [ "$HITS" -eq 0 ]; then
  ok "无 RESIDUE_TEST_ 注入点（§9.5 未进发布版）"
else
  bad "发现 $HITS 处 RESIDUE_TEST_ 痕迹"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- 五、架构与最低系统（可执行性）---"
# ---------------------------------------------------------------------------
ARCH="$(lipo -archs "$BIN" 2>/dev/null || echo unknown)"
case "$ARCH" in
  *arm64*|*x86_64*) ok "架构可执行：$ARCH" ;;
  *) bad "架构不可识别：$ARCH" ;;
esac

MIN_OS="$(otool -l "$BIN" | grep -A3 LC_BUILD_VERSION | grep minos | awk '{print $2}' | head -1)"
if [ -n "$MIN_OS" ]; then
  case "$MIN_OS" in
    1[4-9].*|[2-9][0-9].*) ok "Mach-O 最低系统 macOS ${MIN_OS}（≥ 基线 14.0）" ;;
    *) bad "Mach-O 最低系统 $MIN_OS 低于基线 14.0" ;;
  esac
else
  skip "未读到 minos（旧式 LC_VERSION_MIN_MACOSX）"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- 六、分发载体（§10.1 第 3 条）---"
# ---------------------------------------------------------------------------
DMG="build/Residue.app.dmg"
if [ -f "$DMG" ]; then
  ok "存在分发载体 .dmg"
  # dmg 必须保留签名：挂载后 .app 仍能 verify。
  # 用只读 + nobrowse 挂载，验完立刻卸载，不留挂载点。
  MNT="$(mktemp -d)"
  if hdiutil attach "$DMG" -mountpoint "$MNT" -nobrowse -readonly -quiet 2>/dev/null; then
    if [ -d "$MNT/Residue.app" ]; then
      ok "dmg 内含 Residue.app"
      if codesign --verify --deep --strict "$MNT/Residue.app" > /dev/null 2>&1; then
        ok "dmg 内 .app 签名完好（挂载后仍可 verify）"
      else
        bad "dmg 内 .app 签名损坏（打包方式破坏了签名）"
      fi
      # 拖拽安装的前提：Applications 快捷方式必须在根上
      if [ -L "$MNT/Applications" ]; then
        ok "dmg 含 /Applications 快捷方式（可直接拖拽安装）"
      else
        bad "dmg 缺 Applications 快捷方式（用户需手动找「应用程序」）"
      fi
    else
      bad "dmg 内缺 Residue.app"
    fi
    hdiutil detach "$MNT" -quiet 2>/dev/null || true
  else
    bad "dmg 无法挂载"
  fi
  rmdir "$MNT" 2>/dev/null || true
  echo "     SHA-256: $(shasum -a 256 "$DMG" | awk '{print $1}')"
else
  bad "缺分发载体 .dmg"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- 七、A-5 验收口径逐条落状态 ---"
# ---------------------------------------------------------------------------
IDENTITY_OK=false
if security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" >/dev/null; then
  IDENTITY_OK=true
fi

echo "  ① 产出可 stapler staple 的 .app"
if [ "$IDENTITY_OK" = true ]; then
  skip "需先公证（notarytool submit）后才可 staple —— 本脚本不代替 A-10 第 3~5 步"
else
  skip "本机无 Developer ID 身份 → 无法公证 → 无法 staple。**结构已就绪，钉票属 A-10**"
fi

echo "  ② SMAppService 在 .app 下不抛签名错"
# ⚠️ 这里必须区分两件事，否则验证脚本会说谎：
#   (a) **代码里根本没实现 SMAppService** → 记「未实现」，不是「未覆盖」
#   (b) 实现了但因无身份无法验 → 记「未覆盖（环境所限）」
# 客户端审查（申必过）实测：源码中 SMAppService 出现 0 处 → 属 (a)。
SMAPP_COUNT=$(grep -rc "SMAppService" Sources/ 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')
if [ "${SMAPP_COUNT:-0}" -eq 0 ]; then
  skip "**未实现**：源码中 SMAppService 出现 0 处 —— 这不是「环境所限」，是「功能缺失」。登录项能力根本没写，与有没有签名身份无关"
else
  if [ "$IDENTITY_OK" = true ]; then
    skip "已实现（$SMAPP_COUNT 处），需在有真身份的 GUI 会话中实跑（本脚本不做 GUI 交互）"
  else
    skip "已实现（$SMAPP_COUNT 处），但 ad-hoc 下必抛 kSMErrorInvalidSignature —— 需真身份验证"
  fi
fi

echo "  ③ TCC 面板能认到"
skip "需 GUI 会话中打开「系统设置 → 隐私与安全性 → 完全磁盘访问权限」人工确认；命令行无法替代"
echo "      （注：产品本身不申请 FDA，此条验的是「装上后能被系统识别为可授权的 App」）"

if ! $IDENTITY_OK; then
  echo ""
  echo "  ⚠ 本机无 Developer ID 身份（security find-identity 为 0 个）。"
  echo "    A-5 的**结构部分已全部达成**；②③ 与公证/钉票/端到端装机同属 A-10，"
  echo "    **必须在有真身份的机器上完成，不得以本脚本通过为由跳过**。"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- 六、发布链路的顺序正确性（客户端审查 C1 / C9）---"
# ---------------------------------------------------------------------------
# 这两条都是「只在拿到真身份的第一次真实发布时才炸」的缺陷，
# 而那时离发版只剩几小时 → **必须用静态断言钉住**，不能靠下次人记得。

# C1：真身份分支不得带 --timestamp=none（缺安全时间戳 → notarytool 必被拒）
if grep -q 'timestamp' "scripts/make_app.sh" 2>/dev/null; then
  # ⚠️ **只查非注释行**。
  # 注释里出现「旧写法」是**留痕**（说明这条为什么被改掉），不是缺陷。
  # 判据写太粗会误报 —— 这是本项目的第三次同类教训
  # （前两次：`count - 1` 被当成域内算术、`grep -E 'StateFile('` 报未接线）。
  LIVE_NONE=$(grep -v '^[[:space:]]*#' "scripts/make_app.sh" 2>/dev/null \
              | grep -cF -- '--timestamp=none' || true)
  if [ "${LIVE_NONE:-0}" -gt 0 ]; then
    bad "**非注释行**里仍出现 --timestamp=none（公证必被拒，且 codesign 退出码为 0 不报错）"
  else
    ok "非注释行无 --timestamp=none（C1 已修；注释里的留痕不算）"
  fi
  if grep -q 'Timestamp=' "scripts/make_app.sh" 2>/dev/null; then
    ok "有「缺时间戳即失败」的断言（不靠人记得看）"
  else
    bad "缺「缺时间戳即失败」的断言"
  fi
else
  bad "make_app.sh 里找不到 timestamp 处理"
fi

# C9：先提公证 → 对 dmg 钉票 → 重算 SHA-256；真身份未公证时 dmg 须改名
CONTRACT_CHECK=$(
  python3 - "scripts/make_app.sh" <<'PYEOF' 2>/dev/null || echo FAIL
import sys
src = open(sys.argv[1], encoding='utf-8').read()
i_submit = src.find('notarytool submit')
i_staple = src.find('stapler staple')
i_unnotarized = src.find('UNNOTARIZED')
if min(i_submit, i_staple, i_unnotarized) < 0:
    print('FAIL'); raise SystemExit
# 钉票对象必须是 dmg（票据在分发载体外层），不能是裸 .app
staple_dmg = src.find('stapler staple "$DMG"', i_staple) >= 0
# 钉票会改写 dmg → 哈希必须在其后重算
i_hash2 = src.find('SHA256="$(shasum', i_staple) >= 0
ok = staple_dmg and i_submit < i_staple and i_hash2
print('PASS' if ok else 'FAIL')
PYEOF
)
if [ "$CONTRACT_CHECK" = "PASS" ]; then
  ok "提交公证 → 对 dmg 钉票 → 重算 SHA-256 顺序正确（C9）"
  ok "真身份但未公证时 dmg 改名为 UNNOTARIZED（用名字阻止误传，不只靠注释）"
else
  bad "公证/钉票顺序不对，或缺 UNNOTARIZED 改名（会发出无票据的 dmg）"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- 七、README = 唯一信任面（CR-003 裁决：无官网，只走 GitHub Releases）---"
# ---------------------------------------------------------------------------
# README 不是文档，是**发布准入的一部分**：
# 用户怎么确认下载到的是真货、被 Gatekeeper 拦了怎么办、怎么卸载、
# 「仅 Apple Silicon」这个限制写没写——这些只在这一个文件里。
# 缺一条，用户就得靠猜。

README="../README.md"
if [ -f "$README" ]; then
  ok "README 存在"

  # C10：仅 arm64 必须在 README 写明（不写就是发布阻塞）
  if grep -q "仅 Apple Silicon" "$README" 2>/dev/null; then
    ok "写明「仅 Apple Silicon」（C10：不写就是阻塞，Intel 用户那个错公证环节看不到）"
  else
    bad "README 未写明「仅 Apple Silicon」→ Intel 用户会白下载，而发布方看不到红灯"
  fi

  # 信任面的三条验证手段
  for pat in "shasum -a 256" "spctl --assess" "codesign --verify"; do
    if grep -qF -- "$pat" "$README" 2>/dev/null; then
      ok "README 含验证命令：$pat"
    else
      bad "README 缺验证命令：$pat（无官网时这是唯一信任面）"
    fi
  done

  # 未公证时的放行步骤（macOS 15+ 必须有）
  if grep -q "仍要打开" "$README" 2>/dev/null; then
    ok "README 含未公证时的系统设置放行步骤"
  else
    bad "README 缺未公证时的放行步骤（macOS 15+ 用户会卡死在这一步）"
  fi

  # 卸载顺序（反了会留下找不到目标的登录项）
  if grep -q "登录项" "$README" 2>/dev/null && grep -q "先关自动删除" "$README" 2>/dev/null; then
    ok "README 含卸载顺序（先关自动删除 → 移除登录项 → 删 App）"
  else
    bad "README 缺正确的卸载顺序"
  fi

  # 零外发声明（T4）
  if grep -q "零遥测" "$README" 2>/dev/null || grep -q "不外发" "$README" 2>/dev/null; then
    ok "README 含零外发声明（T4）"
  else
    bad "README 缺零外发声明"
  fi

  # 已如实登记限制（不是「什么都好」的营销页）
  if grep -q "已知限制" "$README" 2>/dev/null; then
    ok "README 有「已知限制」节（不粉饰）"
  else
    bad "README 缺「已知限制」节"
  fi
else
  bad "缺 README.md（CR-003：无官网 → README 是唯一信任面）"
fi

# ---- README 的承诺必须与实现一致 ----
# 这是比「README 存在」更重要的检查：文档骗人是比代码 bug 更贵的事故。
if [ -f "$README" ] && grep -q "TrashExecutor.swift. 里..没有任何删除调用" "$README" 2>/dev/null; then
  RM_IN_EXEC=$(grep -v '^[[:space:]]*//' Sources/ResidueCore/TrashExecutor.swift 2>/dev/null \
               | grep -cE '(removeItem|unlink|[^a-zA-Z]rm[^a-zA-Z])' || true)
  # ⚠️ 不用 `\b`：macOS 的 BSD grep 不支持单词边界（GNU 扩展），会静默不命中。
  # 用「前后都不是字母」的字符类代替。
  if [ "${RM_IN_EXEC:-0}" -eq 0 ]; then
    ok "README 承诺「TrashExecutor 无删除调用」，实测一致（且已写明 StateFile 删的是自己的临时文件）"
  else
    bad "README 声称 TrashExecutor 无删除，实际有 ${RM_IN_EXEC} 处（**文档骗人**）"
  fi
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- 八、README 的并发承诺必须与实现一致（CR-030）---"
# ---------------------------------------------------------------------------
# README 是**唯一信任面**（CR-003 裁决：无官网）。
# 它现在承诺「扫描在后台线程跑 / 实时显示进度 / 可取消」——
# 这三条**每一条都要能在实现里指出来**，否则就是文档骗人。

README2="../README.md"
if [ -f "$README2" ]; then
  if grep -q "后台线程" "$README2" 2>/dev/null; then
    # 承诺 ①：后台线程 → 实现里必须有 Task.detached
    #
    # ⚠️ **只查非注释行**。
    # `AppModel` 的文档注释里写着「重活进 `Task.detached`」——
    # 若连注释一起 grep，**注释本身就满足了判据**，
    # 于是「代码里根本没有 detached」也照样绿。
    #
    # 这与本项目此前 4 次「校验脚本自己说谎」同类：
    # **判据命中了不该命中的东西 → 假绿。**
    LIVE_DETACHED=$(grep -v '^[[:space:]]*//' "Sources/ResidueApp/AppModel.swift" 2>/dev/null \
                    | grep -cF 'Task.detached' || true)
    if [ "${LIVE_DETACHED:-0}" -gt 0 ]; then
      ok "README 承诺「后台线程」→ 实现确有 Task.detached（活的代码行）"
    else
      bad "README 说后台线程，实现里没有活的 Task.detached（**文档骗人**）"
    fi
  fi

  if grep -q "已扫描" "$README2" 2>/dev/null; then
    # 承诺 ②：实时显示进度 → 实现里必须有进度回调 + 界面显示
    if grep -qF 'progressEvery' "Sources/ResidueCore/ScanEngine.swift" 2>/dev/null \
       && grep -qF 'scanProgress.displayText' "Sources/ResidueApp/RootView.swift" 2>/dev/null; then
      ok "README 承诺「实时显示已扫描 N 项」→ 引擎有进度回调且界面有显示"
    else
      bad "README 承诺实时进度，实现里找不到进度回调或界面显示（**文档骗人**）"
    fi
  fi

  if grep -q "随时取消" "$README2" 2>/dev/null; then
    # 承诺 ③：可取消 → 实现里必须有取消令牌 + 取消入口
    if grep -qF 'CancelBox' "Sources/ResidueApp/ScanInfrastructure.swift" 2>/dev/null \
       && grep -qF 'app.cancelScan()' "Sources/ResidueApp/RootView.swift" 2>/dev/null; then
      ok "README 承诺「随时取消」→ 实现有取消令牌与取消按钮"
    else
      bad "README 承诺可取消，实现里找不到取消机制（**文档骗人**）"
    fi
  fi

  # **诚实性**：README 必须承认「扫描本身仍要十几秒」
  # —— 只说「不卡」而不说「仍然慢」，那是**避重就轻**。
  if grep -q "扫描本身要十几秒" "$README2" 2>/dev/null; then
    ok "README 如实写明「扫描本身仍要十几秒」（不避重就轻）"
  else
    bad "README 只说界面不卡、没说扫描本身仍慢 → **避重就轻**，等于误导"
  fi
fi

# ---------------------------------------------------------------------------
echo ""
echo "=============================================="
echo "通过 $PASS 项 / 失败 $FAIL 项 / 未覆盖 $SKIP 项"
if [ "$SKIP" -gt 0 ]; then
  echo ""
  echo "未覆盖项（如实登记，不算通过）："
  for s in "${SKIPPED_ITEMS[@]}"; do echo "  ⊘ $s"; done
fi
echo "=============================================="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
