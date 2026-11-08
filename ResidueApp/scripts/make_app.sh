#!/bin/bash
# =============================================================================
# Residue · .app 打包脚本（ADR-10 / §10.1 / §10.2）
#
# 用法：
#   ./scripts/make_app.sh                     # 本地开发：ad-hoc 签名
#   CODESIGN_IDENTITY="Developer ID Application: X (TEAMID)" ./scripts/make_app.sh
#                                             # 发布：真身份签名
#
# 产出：
#   build/Residue.app                        # 可 launch 的 .app
#   build/Residue.app.zip                    # 分发载体（内含已 staple 的 .app）
#
# ## 为什么必须产出 .app 而不是裸 Mach-O（ADR-10 的核心）
#   - `SMAppService`（登录项）在裸 Mach-O 下抛 `kSMErrorInvalidSignature`
#   - TCC 授权面板**只认 .app**（Full Disk Access 那一栏要能看见产品）
#   - `notarytool` **只吃 .zip / .dmg**，不吃裸 .app
#   所以「登录项 / 授权 / 公证」三条链全部依赖 bundle 身份 —— 这是结构性前置，
#   不是打包细节。缺了它，这三条链在开发期全废。
#
# ## 幂等与可重复
#   每次运行都从 `build/` 干净重建，不增量叠加（避免残留的旧签名让验证假通过）。
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT_ROOT="$(pwd)"
APP_NAME="Residue"
BUNDLE_ID="com.residue.app"
BUILD_DIR="$PROJECT_ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"

# 版本号：优先取环境变量；否则从 git describe 或日期生成
VERSION="${RESIDUE_VERSION:-0.1.0}"
BUILD_NUMBER="${RESIDUE_BUILD:-$(date +%Y%m%d%H%M)}"

# 签名身份：空 = ad-hoc（仅本地可跑，不可公证）
IDENTITY="${CODESIGN_IDENTITY:--}"

echo "=============================================="
echo "Residue · .app 打包"
echo "  版本      : $VERSION ($BUILD_NUMBER)"
echo "  签名身份  : $([ "$IDENTITY" = "-" ] && echo "ad-hoc（本地开发，不可公证）" || echo "$IDENTITY")"
echo "=============================================="

# ---------------------------------------------------------------------------
# 1. 编译 Release
# ---------------------------------------------------------------------------
echo ""
echo "--- [1/7] 编译 Release ---"
swift build -c release --disable-sandbox
BIN="$(swift build -c release --disable-sandbox --show-bin-path)/ResidueApp"
if [ ! -f "$BIN" ]; then
  echo "✗ 找不到可执行产物：$BIN" >&2
  exit 1
fi
echo "  产物: $BIN"

# ---------------------------------------------------------------------------
# 2. 组装 bundle 骨架
# ---------------------------------------------------------------------------
echo ""
echo "--- [2/7] 组装 bundle ---"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN" "$CONTENTS/MacOS/$APP_NAME"
chmod +x "$CONTENTS/MacOS/$APP_NAME"

# Info.plist：从模板注入版本号
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
    "$PROJECT_ROOT/Resources/Info.plist.in" > "$CONTENTS/Info.plist"

# 校验 Info.plist 是合法 plist（写错 plist 会让 app 静默不启动）
if ! plutil -lint "$CONTENTS/Info.plist" > /dev/null; then
  echo "✗ Info.plist 不合法" >&2
  exit 1
fi
echo "  Info.plist 合法"

# 复制资源（若有）
if [ -d "$PROJECT_ROOT/Resources" ]; then
  for f in "$PROJECT_ROOT/Resources"/*; do
    base="$(basename "$f")"
    case "$base" in
      Info.plist.in|entitlements.plist) continue ;;   # 模板/签名用，不进 Resources
    esac
    [ -f "$f" ] && cp "$f" "$CONTENTS/Resources/"
  done
fi

# 图标必须进 bundle（否则 Finder/登录项/TCC 显示白纸）
if [ -f "$PROJECT_ROOT/Resources/Residue.icns" ]; then
  cp "$PROJECT_ROOT/Resources/Residue.icns" "$CONTENTS/Resources/"
else
  echo "⚠ 缺 Resources/Residue.icns —— 图标将显示为通用白纸（影响 TCC 面板可发现性）"
fi

# PkgInfo（可选但标准）
printf 'APPL????' > "$CONTENTS/PkgInfo"

# ---------------------------------------------------------------------------
# 3. 逐 Mach-O 签名（ADR-10 / §10.1 第 1 条）
# ---------------------------------------------------------------------------
echo ""
echo "--- [3/7] 逐 Mach-O 签名 ---"
ENTITLEMENTS="$PROJECT_ROOT/Resources/entitlements.plist"

# 注意签名顺序：**先内层后外层**（有嵌套时）。当前无嵌套 framework/dylib，
# 但脚本按通用顺序写，加依赖时不必改。
#
# ⚠️ 时间戳分支（这里曾经**写反过**，是审查发现的致命缺陷）：
#   - **真身份（发布）必须带 `--timestamp`** —— 安全时间戳是公证的硬要求，
#     缺了 `notarytool` 必被拒。且 `codesign ... --timestamp=none` **退出码是 0**
#     （静默生效），开发期用 ad-hoc 根本看不到这个问题。
#   - **ad-hoc 不能用 `--timestamp`**（没有证书可盖时间戳）。
#   原实现把 `--timestamp=none` 放在默认分支、只在 ad-hoc 时去掉 → 恰好相反。
if [ "$IDENTITY" = "-" ]; then
  # ad-hoc：不加时间戳（也不可能加）
  SIGN_FLAGS=(--force --options runtime)
  echo "  签名模式: ad-hoc（无时间戳 — 不可公证）"
else
  # 真身份：**必须**要安全时间戳，否则公证必被拒
  SIGN_FLAGS=(--force --options runtime --timestamp)
  echo "  签名模式: Developer ID + 安全时间戳（可公证）"
fi

# 找出 bundle 内所有 Mach-O 并逐个签名
MACHO_COUNT=0
while IFS= read -r -d '' candidate; do
  if file "$candidate" | grep -q "Mach-O"; then
    codesign "${SIGN_FLAGS[@]}" \
      --entitlements "$ENTITLEMENTS" \
      --sign "$IDENTITY" \
      "$candidate"
    MACHO_COUNT=$((MACHO_COUNT + 1))
    echo "  已签: ${candidate#$APP/}"
  fi
done < <(find "$APP" -type f -print0)

if [ "$MACHO_COUNT" -eq 0 ]; then
  echo "✗ bundle 内没有任何 Mach-O，打包无效" >&2
  exit 1
fi
echo "  共签 $MACHO_COUNT 个 Mach-O"

# ---------------------------------------------------------------------------
# 4. 校验签名 + entitlements 不含 get-task-allow（§10.1 第 2 条）
# ---------------------------------------------------------------------------
echo ""
echo "--- [4/7] 校验签名与 entitlements ---"
codesign --verify --deep --strict "$APP" || { echo "✗ codesign --verify 失败" >&2; exit 1; }
echo "  codesign --verify --deep --strict 通过"

# get-task-allow 必须为 false / 不存在（否则公证必被拒）
ENT_OUT="$(codesign -d --entitlements :- "$APP" 2>/dev/null || true)"
if echo "$ENT_OUT" | grep -q "get-task-allow"; then
  # 若存在，其值必须是 false
  if echo "$ENT_OUT" | grep -A1 "get-task-allow" | grep -q "<true/>"; then
    echo "✗ entitlements 含 get-task-allow = true → 公证必被拒（§10.1 第 2 条）" >&2
    exit 1
  fi
  echo "  get-task-allow 存在但为 false（可接受）"
else
  echo "  get-task-allow 不存在（正确）"
fi

# 断言没有任何 com.apple.security.*（首版非沙盒、零网络）
if echo "$ENT_OUT" | grep -q "com.apple.security"; then
  echo "⚠ entitlements 含 com.apple.security.* —— 首版应为空（非沙盒、零外发）" >&2
  echo "$ENT_OUT" | grep "com.apple.security" >&2
  exit 1
fi
echo "  无 com.apple.security.*（非沙盒、零外发）"

# 断言测试注入点未进发布版（§10.1 第 10 条 / §9.5）
if strings "$CONTENTS/MacOS/$APP_NAME" | grep -q "RESIDUE_TEST_"; then
  echo "✗ Release 产物含 RESIDUE_TEST_ 前缀的测试注入点（§9.5 绝不能进发布版）" >&2
  strings "$CONTENTS/MacOS/$APP_NAME" | grep "RESIDUE_TEST_" | head -5 >&2
  exit 1
fi
echo "  无 RESIDUE_TEST_ 注入点残留"

# 断言：真身份签名必须带安全时间戳（否则公证必被拒）
# 这条断言的存在意义：`--timestamp=none` 的退出码是 0、静默生效，
# 靠人看日志发现不了；只能靠机器断言。
if [ "$IDENTITY" != "-" ]; then
  if codesign -dv --verbose=4 "$APP" 2>&1 | grep -q "^Timestamp="; then
    echo "  安全时间戳存在（公证前提满足）"
  else
    echo "✗ 真身份签名但缺安全时间戳 → notarytool 必被拒（检查 --timestamp 是否被误设为 none）" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 5. 冒烟：bundle 完整性 + 架构（**不直接执行 GUI app**）
# ---------------------------------------------------------------------------
echo ""
echo "--- [5/7] bundle 结构冒烟 ---"
if [ ! -f "$CONTENTS/MacOS/$APP_NAME" ]; then
  echo "✗ 主可执行缺失" >&2
  exit 1
fi

# ⚠ 不要直接执行主可执行来冒烟：
#   GUI app（SwiftUI App 生命周期）会进入 NSApplication run loop **永不返回**，
#   脚本会被超时杀掉（实测 exit 137 = SIGTERM）。这是踩过的坑。
#   正确做法：验 Mach-O 架构与最低系统版本，GUI 可用性交给 `open` + 进程检查。

# 架构必须匹配本机可执行（arm64 或 universal）
ARCH_INFO="$(lipo -archs "$CONTENTS/MacOS/$APP_NAME" 2>/dev/null || echo "unknown")"
case "$ARCH_INFO" in
  *arm64*|*x86_64*) echo "  架构: $ARCH_INFO" ;;
  *) echo "✗ 无法识别的架构：$ARCH_INFO" >&2; exit 1 ;;
esac

# 最低系统版本必须存在且为 14.0（产品基线）
MIN_OS="$(otool -l "$CONTENTS/MacOS/$APP_NAME" | grep -A3 LC_BUILD_VERSION | grep minos | awk '{print $2}' | head -1)"
if [ -z "$MIN_OS" ]; then
  echo "  ⚠ 未读到 minos（可能是旧式 LC_VERSION_MIN_MACOSX）"
else
  echo "  最低系统: macOS $MIN_OS"
  case "$MIN_OS" in
    1[4-9].*|[2-9][0-9].*) : ;;
    *) echo "✗ 最低系统 $MIN_OS 低于产品基线 14.0（LSMinimumSystemVersion 与 Mach-O 不一致）" >&2; exit 1 ;;
  esac
fi

# Hardened Runtime 必须启用（公证前提，§10.1）
if codesign -d --verbose=2 "$APP" 2>&1 | grep -q "flags=.*runtime"; then
  echo "  Hardened Runtime 已启用"
else
  echo "✗ Hardened Runtime 未启用 → 公证必被拒（§10.1）" >&2
  exit 1
fi

echo "  bundle 结构完整"

# ---------------------------------------------------------------------------
# 6. 打包分发载体（§10.1 第 3 条）
# ---------------------------------------------------------------------------
echo ""
echo "--- [6/7] 打包分发载体 ---"
ZIP="$BUILD_DIR/$APP_NAME.app.zip"
rm -f "$ZIP"
# ditto 保留资源分叉与签名（zip -r 会破坏签名）
ditto -c -k --keepParent "$APP" "$ZIP"
echo "  产出: $ZIP"

SHA256="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "  SHA-256: $SHA256"
echo "  （注：此 SHA-256 只对本轮产物有效；**公证钉票后 .app 会变，必须重打 zip 并重算**）"

# ---------------------------------------------------------------------------
# 7. 公证与钉票（**真身份下自动做，且必须重打 zip**）
# ---------------------------------------------------------------------------
echo ""
echo "--- [7/7] 公证与钉票 ---"

if [ "$IDENTITY" = "-" ]; then
  cat <<'EOF'
  ⚠ 本次为 ad-hoc 签名（本机无 Developer ID 身份）。
    - 可验证：bundle 结构 / Info.plist / entitlements / 逐 Mach-O 签名 / codesign --verify
    - 不可验证：notarytool 公证 / stapler 钉票 / spctl 评估 / 干净机端到端装机
    → 上面四项属 A-10「发布准入」，**必须在有真身份的机器上做，不得跳过**。
EOF
elif [ -z "${NOTARY_PROFILE:-}" ]; then
  # ---------------------------------------------------------------------
  # **真身份但没给公证 profile** —— 这是最危险的中间态
  # ---------------------------------------------------------------------
  #
  # 客户端审查 C9 指出：原脚本只靠「注释提醒」要求钉票后重打 zip。
  # 而实际上，一个已签名但**未公证未钉票**的 zip 完全能传上去 ——
  # 用户下载后 Gatekeeper 会拦，但**发布方看不到红灯**（公证环节才暴露）。
  #
  # 所以这里做的不只是提醒，而是**让这个 zip 无法被误当成发布物**：
  # 把文件名改成 `UNNOTARIZED`。名字会出现在 Releases 资产列表里，
  # 任何人看一眼就知道它还没走完流程。
  UNNOTARIZED_ZIP="$BUILD_DIR/$APP_NAME.app.UNNOTARIZED.zip"
  mv "$ZIP" "$UNNOTARIZED_ZIP"
  ZIP="$UNNOTARIZED_ZIP"
  SHA256="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
  cat <<EOF
  ⚠⚠ **本产物未公证、未钉票，不可用于发布。**
    已把 zip 改名为：$(basename "$ZIP")
    —— 改名不是洁癖：名字会出现在 Releases 资产列表里，
       **看一眼就知道它没走完流程**。只靠注释提醒是不够的（C9）。

  要完成发布准入（§10.1 第 3–5 条），重跑并给出公证 profile：
    NOTARY_PROFILE=<keychain-profile> CODESIGN_IDENTITY="Developer ID Application: …" \
      ./scripts/make_app.sh

  那条路径会自动做：submit → staple → **重打 zip** → **重算 SHA-256** → spctl 验证。
  （`xcrun notarytool store-credentials <profile>` 可创建 profile）
EOF
else
  # ---------------------------------------------------------------------
  # **完整公证流程**（真身份 + profile）
  # ---------------------------------------------------------------------
  echo "  ① 提交公证（profile: ${NOTARY_PROFILE}）"
  xcrun notarytool submit "$ZIP" --keychain-profile "${NOTARY_PROFILE}" --wait

  echo "  ② 对 .app 钉票（zip 本身不可 staple，票据在 .app 内）"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"

  # **关键**：钉票改写了 .app 内的票据 → 之前的 zip 与 SHA-256 全部失效。
  # 必须重打、重算，否则发出去的 zip 里没有票据（用户离线时 Gatekeeper 会拦）。
  echo "  ③ 重打 zip（钉票后 .app 已变更，旧 zip 失效）"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"

  echo "  ④ 重算 SHA-256"
  SHA256="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

  echo "  ⑤ spctl 评估（成功须看到 source=Notarized Developer ID，失败退出码是 3 不是 1）"
  if spctl --assess --type execute --verbose=4 "$APP" 2>&1 | tee /dev/stderr | grep -q "Notarized Developer ID"; then
    echo "  ✓ 公证链完整（Notarized Developer ID）"
  else
    echo "  ✗ spctl 未通过 —— 不得发布。常见原因：get-task-allow 为 true / 签名不完整 / 当前在离线环境" >&2
    exit 1
  fi
fi

echo ""
echo "=============================================="
echo "完成"
echo "  .app  : $APP"
echo "  .zip  : $ZIP"
echo "  SHA256: $SHA256"
echo "=============================================="
