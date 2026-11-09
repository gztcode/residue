# Residue · A-10 发布准入执行单 v1.0

> **性质**：本文件是 `Residue-R2-技术方案-v1.6.md` §10.1 / §10.2 的**可执行落地单**，不是复述。
> 每步给：**命令原文 / 预期输出 / 失败判定 / 失败看哪里 / 本机能否执行**。
> **输入基线**：R2 技术方案 v1.6 §10.1（发布准入九步）、§10.2（回滚）、§10.3（schema 迁移矩阵）；`scripts/make_app.sh`、`scripts/verify_a5.sh`。
> **作者**：申必过（客户端）｜**日期**：2026-11-08
>
> ## 本文件的三条自我约束
> 1. **做不了的步骤一律标「阻塞」，不标「已就绪」**。缺身份的步骤写清「拿到身份后第一步做什么」（见 §7）。
> 2. **§10.1 本身不可执行的地方如实指出并给修法**（见 §5，共 7 条，其中 D4 是硬阻塞）。
> 3. 所有标「实测」的输出，都是本机 2026-11-08 跑出来的原文，命令可复跑。

---

## 0. 本机环境实测基线（2026-11-08）

| 项 | 实测值 | 命令 |
|---|---|---|
| 宿主系统 | **macOS 27.0.1 (26A434)**，arm64 | `sw_vers` / `uname -m` |
| 工具链 | Xcode 27.2 (27B52)，Apple Swift 6.4.2，SDK **27.2** | `xcodebuild -version` / `xcrun --show-sdk-version --sdk macosx` |
| 签名身份 | **0 valid identities found** | `security find-identity -v -p codesigning` |
| notarytool | 1.1.4 (43)，可用（缺凭据） | `xcrun notarytool --version` |
| 产物 | `build/Residue.app` 1.8 MB（主二进制 1,888,416 B）／`Residue.app.zip` 472 KB | `du -sh` / `ls -l` |
| zip SHA-256 | `a652e96ecbeac640f7b314b24465983bded3911c876c6775e7d390723b3d2c8e` | `shasum -a 256` |
| Mach-O | `Format=app bundle with Mach-O thin (arm64)`，`minos 14.0`，`sdk 14.0`，`flags=0x10002(adhoc,runtime)` | `codesign -dvvv` / `otool -l` |
| `spctl` | `build/Residue.app: rejected`，**exit 3** | `spctl --assess --type execute --verbose` |
| 首启落盘 | `~/Library/Application Support/Residue` **不存在** | `ls` |

> **一条必须记住的基线事实**：宿主是 macOS **27.0.1**，而产品最低支持 **14.0**。这台机器上**任何**「跑得通」都不构成 14.x / 15.x 的兼容证据。`LSMinimumSystemVersion=14.0` 迄今从未在 14.x 上被执行过——这是 S7 存在的唯一理由。

---

## 1. 编号映射（§10.1 原文编号错位，本单重排）

§10.1 正文的编号顺序是 `1,2,3,4,5,6,7,8,10,9`——第 10 条（注入点剥离）被插在第 8 与第 9 条之间。按原编号执行会漏步或错序，故本单重排并保留双向映射：

| 本单 | §10.1 原编号 | 内容 | 一句话判据 |
|---|---|---|---|
| **S1** | 1 | 组装 .app + 逐 Mach-O 签名 | 每个 Mach-O 都有 `Developer ID` 签名 + `Timestamp` |
| **S2** | 2 | `get-task-allow` 必须为 false | entitlements 里没有该键，或为 false |
| **S3** | 3 | `ditto` 打 zip → `notarytool submit --wait` | `status: Accepted` |
| **S4** | 4 | `stapler staple` 对 `.app`，再重打 zip | `stapler validate` 通过 |
| **S5** | 5 | `codesign --verify` + `spctl --assess` 双验 | verify exit 0；spctl `accepted` |
| **S6** | 6 | 产物形态（只发 zip，不分布裸 Mach-O） | zip 内含已 staple 的 .app |
| **S7** | 7 | 端到端装机（干净机） | 零人工干预、零崩溃、`scan.jsonl` 有记录 |
| **S8** | 8 | SHA-256 对账（重新下载再算） | 两值一致 |
| **S9** | 9 | 保留上一版归档 + 首演例外 | 首演：卸载 → 重装后为初始态 |
| **S10** | 10 | 测试注入点剥离 | `RESIDUE_TEST_` 出现次数 = 0 |

---

## 2. 前置条件矩阵（先看这张表，再决定今天能做什么）

| 步 | 需真身份（Developer ID） | 需干净机 | 需有网 | 本机状态 |
|---|---|---|---|---|
| S1 | **是**（ad-hoc 分支不需要，但 ad-hoc 产物不可公证） | 否 | 否 | ⚠ 部分可执行（只能跑 ad-hoc 分支） |
| S2 | 否 | 否 | 否 | ✅ 可执行（已通过） |
| S3 | **是** | 否 | **是**（连 Apple Notary Service） | ⛔ **阻塞** |
| S4 | **是**（前提是 S3 通过） | 否 | **是**（staple 要查 CloudKit 票据） | ⛔ **阻塞** |
| S5 | **是**（`spctl` 判据不可达） | 否 | 否 | ⚠ 半可执行（verify 通过，spctl 必然 rejected） |
| S6 | 否（形态可查，但「已 staple」不可查） | 否 | 否 | ✅ 可执行 |
| S7 | **是** | **是**（macOS 14 + 15 各一台） | 首启**必须断网**；其余步骤视 S7 子项 | ⛔ **阻塞**（三重：身份／干净机／**登录项未实现**） |
| S8 | 否（算值）／**是**（上传后复核需真产物） | 否 | **是**（复核阶段） | ⚠ 半可执行 |
| S9 | 否 | 否（首演例外本机可跑） | 否 | ⚠ 半可执行（见 S9 判据不可达） |
| S10 | 否 | 否 | 否 | ✅ 可执行（已通过） |

**结论：九步里本机只能完整执行 3 步（S2 / S6 / S10），2 步半可执行（S5 / S8），4 步被身份阻塞（S1 真身份分支 / S3 / S4 / S7）。**
S9 形式可跑但判据不可达（原因见 S9 与 C16）。

**要准备什么（一句话清单）**：
- 一台有 **Developer ID Application** 证书的 Mac（钥匙串里 `security find-identity -v -p codesigning` 能看到 1 个有效身份）；
- 一份公证凭据：Apple ID + **App 专用密码** + Team ID，或 App Store Connect **API Key（.p8 + Key ID + Issuer ID）**；
- 两台干净机：**macOS 14.x 一台、macOS 15.x 一台**（真机或全新虚拟机，未装过本产品）；
- 有网环境（S3 / S4 / S8b）。

---

## 3. 九步执行卡

> 统一前置：`cd /Users/<user>/WorkBuddy/2026-11-06-10-06-29/ResidueApp`
> 统一变量（S1 起一次设好，后续卡片直接引用）：
> ```bash
> export RESIDUE_VERSION=0.1.0                 # ⚠ 必须显式给，且与上一版不同（见 C11）
> export RESIDUE_BUILD=$(date +%Y%m%d%H%M)
> export CODESIGN_IDENTITY="Developer ID Application: <公司名> (<TEAMID>)"
> APP=build/Residue.app
> ZIP=build/Residue.app.zip
> PRESTAPLE=build/Residue.app.prestaple.zip
> ```

---

### S1 · 组装 .app + 逐 Mach-O 签名

**⚠ 前置缺陷**：`scripts/make_app.sh:105` 在**真身份分支**下使用 `--timestamp=none`，会产出**没有安全时间戳**的签名 → S3 公证必被拒。修法见 **C1**。**C1 修复前，S1 必须用手工命令替代脚本**：

```bash
# 1) 先按脚本完成组装（脚本的 [1/7]~[2/7] 是对的），但不要用它的 [3/7] 签名
./scripts/make_app.sh        # ad-hoc 跑一遍，只为拿到组装好的 bundle
# 2) 用正确 flags 重签（关键：--timestamp 不能带 =none）
codesign --force --options runtime --timestamp \
  --entitlements Resources/entitlements.plist \
  --sign "$CODESIGN_IDENTITY" "$APP/Contents/MacOS/Residue"
# 3) 回读
codesign -d --verbose=4 "$APP"
```

**预期输出**（`codesign -dvvv` 关键行）：
```
Authority=Developer ID Application: <公司名> (<TEAMID>)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
TeamIdentifier=<TEAMID>              # 不是 "not set"
Timestamp=<日期时间>                  # 必须存在；缺这一行 → 公证必拒
CodeDirectory ... flags=0x10000(runtime)   # 有 runtime，不能有 adhoc
```

**失败判定**（任一成立即失败）：
- `codesign` 非 0 退出；
- `TeamIdentifier=not set`（说明用了 `-`，即 ad-hoc）；
- **没有 `Timestamp=` 行**（`--timestamp=none` 的后果，见 C1）；
- `flags=` 里没有 `runtime`；
- `Signature=adhoc`。

**失败看哪里**：

| 报错原文 | 根因 | 处置 |
|---|---|---|
| `errSecInternalComponent` | 钥匙串被锁 / 私钥不可用 | `security unlock-keychain ~/Library/Keychains/login.keychain-db`；确认证书私钥在本机（不是只有 .cer） |
| `AMFIUnserializeXML: syntax error near line N` | entitlements plist 非法（XML 注释里出现连续两个连字符 `--`） | `plutil -lint Resources/entitlements.plist` |
| `code object is not signed at all` / `code signature invalid` | 签名顺序错（应先内层 framework/dylib，后外层 bundle） | 按 `find` 由深到浅重签；当前只有 1 个 Mach-O，加依赖后必须改脚本 |
| `The specified item could not be found in the keychain` | 身份串写错（大小写/TeamID 括号） | `security find-identity -v -p codesigning` 逐字复制 |

**本机状态**：⛔ 真身份分支不可执行（0 identities）。ad-hoc 分支已跑通（`已签: Contents/MacOS/Residue`，`flags=0x10002(adhoc,runtime)`）。

---

### S2 · `get-task-allow` 必须为 false

```bash
codesign -d --entitlements :- "$APP" 2>/dev/null | plutil -p -
# 期望：<dict/> 或空；绝不能出现 "get-task-allow" => 1
codesign -d --entitlements :- "$APP/Contents/MacOS/Residue" 2>/dev/null | grep -c "get-task-allow"
# 期望：0
```

**预期输出**：`<dict/>`（空字典，本产品刻意如此），`grep -c` 输出 `0`。

**失败判定**：出现 `"get-task-allow" => 1`，或 `grep -c` 输出 ≥ 1。

**失败看哪里**：
1. 是否用了 `swift build`（Debug）的产物？—— `make_app.sh:52` 是 `-c release`，但若手工拷了 `.build/debug/ResidueApp` 就会带；
2. `--entitlements` 是否被换成了 Xcode 的 `*.entitlements`（Debug 配置默认写 `get-task-allow=true`）；
3. `Resources/entitlements.plist` 是否被人加了键 → `plutil -lint` + `git diff`。

**本机状态**：✅ 已通过（`get-task-allow 不存在（正确）`）。

---

### S3 · 打 zip → 公证

**需真身份 + 需有网。**

```bash
# 3.0 一次性存公证凭据（二选一）
# A. Apple ID + App 专用密码（个人账号）
xcrun notarytool store-credentials "residue-notary" \
  --apple-id "<AppleID>" --team-id "<TEAMID>" --password "<App 专用密码>"
# B. App Store Connect API Key（团队账号，推荐）
xcrun notarytool store-credentials "residue-notary" \
  --key "<AuthKey_XXXX.p8 路径>" --key-id "<KEYID>" --issuer "<ISSUER-UUID>"

# 3.1 打「公证用」zip（注意文件名：这不是最终分发物，见 S4）
rm -f "$PRESTAPLE"
ditto -c -k --keepParent "$APP" "$PRESTAPLE"

# 3.2 提交并等待
xcrun notarytool submit "$PRESTAPLE" --keychain-profile "residue-notary" --wait
```

**预期输出**：
```
Conducting pre-submission checks for Residue.app.prestaple.zip and initiating connection to the Apple notary service...
Submission ID received
  id: <UUID>
Upload progress: 100.0%
Waiting for processing to complete.
Current status: Accepted........
Processing complete
  id: <UUID>
  status: Accepted
```

**失败判定**：`status: Invalid`（或 `Rejected`）。**记下 `id`——下一步全靠它。**

**失败看哪里**：**一律先拉日志，不要靠猜**：
```bash
xcrun notarytool log <上一步的 id> --keychain-profile "residue-notary"
```
日志 JSON 的 `issues[]` 每条有 `severity` / `message` / `path`。常见原因与对应修法：

| 日志 message 关键字 | 根因 | 修法 |
|---|---|---|
| `The signature does not include a secure timestamp` | 签名用了 `--timestamp=none` | **本仓库当前就会命中（C1）**；改用 `--timestamp`（无值，取 Apple 默认 TSA），重签重打 |
| `The executable does not have the hardened runtime enabled` | 漏 `--options runtime` | 重签加 `--options runtime` |
| `not signed with a valid Developer ID certificate` | 用了 ad-hoc 或 Apple Development 证书 | 换成 `Developer ID Application: ...` |
| `The executable requests the com.apple.security.get-task-allow entitlement` | Debug 余留 | 回到 S2 |
| `The file ... is not signed` / `Invalid bundle structure` | 漏签嵌套 Mach-O（Frameworks/PlugIns） | 逐个签内层后再签外层（S1） |
| `The bundle ... does not have a bundle identifier` | `Info.plist` 未进 bundle / 被 Resources 覆盖 | 检查 `$APP/Contents/Info.plist` |
| `HTTP 401 / 403`、`Unable to authenticate` | 凭据错（专用密码 vs 登录密码；API Key 的 issuer 缺失） | 重跑 `store-credentials` |

**本机状态**：⛔ 阻塞：需 Developer ID。**拿到身份后第一步**：先跑 `security find-identity -v -p codesigning` 确认有身份 → 修 C1 → 再 `store-credentials` → 再 submit。

---

### S4 · 钉票（对 `.app`，不是对 zip）→ 重打最终 zip

**需真身份 + 需有网。**

```bash
xcrun stapler staple "$APP"        # 参数是 .app
xcrun stapler validate "$APP"      # 必须通过
# 钉票之后才打最终分发 zip（票据在 .app 内，zip 本身不可 staple）
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | tee build/SHA256SUMS
```

**预期输出**：
```
Processing: build/Residue.app
The staple and validate action worked!
Processing: build/Residue.app
The validate action worked!
```

**失败判定**：`stapler` 非 0 退出；出现下列任一原文即失败（**本机实测原文，供比对**）：
- `The staple and validate action failed! Error 65.` + `Could not find base64 encoded ticket in response for 2/<cdhash>` → 该产物**从未被公证**或公证未 Accepted；
- `Residue.app does not have a ticket stapled to it.`（`stapler validate` 的失败原文）；
- `Stapler is incapable of working with ZIP archive files.`（**exit 66**，把 zip 当参数了）。

**失败看哪里**：
1. 是否把 `$ZIP` 当参数了？（上面的 exit 66 原文就是证据）
2. 公证是否真的 `Accepted`？回看 S3 的 `id` + `notarytool log`；
3. **cdhash 是否变了**：钉票后又重新签名 → cdhash 变 → 票据对不上。顺序必须是「签名 → 公证 → 钉票」，中间不许再签。
4. 是否在钉票前就打了最终 `$ZIP` 并准备上传？（**这是最容易犯的错，见 C9**）

**本机状态**：⛔ 阻塞：需先公证。已实测记录两条失败原文（`Error 65` / `exit 66`），可直接用于比对。

---

### S5 · 双验（`codesign` + `spctl`）

```bash
codesign --verify --deep --strict --verbose=2 "$APP"; echo "verify exit=$?"
spctl --assess --type execute --verbose=4 "$APP"; echo "spctl exit=$?"
```

**预期输出**：
```
$APP: valid on disk
$APP: satisfies its Designated Requirement
verify exit=0

$APP: accepted
source=Notarized Developer ID
origin=Developer ID Application: <公司名> (<TEAMID>)
spctl exit=0
```

**失败判定**（判据写死，因为 §10.1 第 5 条原文没给判据 —— 见 D3）：
- `verify exit != 0`；
- `spctl exit != 0`（**注意：`rejected` 的退出码是 3，不是 1**，本机实测 `rejected` / `exit=3`）；
- `source=` 不是 `Notarized Developer ID`（若是 `Developer ID` 说明未公证，若是 `no usable signature` 说明签名坏了）。

**失败看哪里**（二分法，别猜）：
```
verify 过 + validate 过 + spctl 拒  → Gatekeeper 缓存 / 票据未生效
   → sudo spctl --assess --type execute -vv "$APP" 再取一次详细原因
   → xattr -l "$APP"  看有没有残留 com.apple.quarantine（有就先 xattr -d 再评）
verify 拒                        → 签名被后续操作破坏（staple 后再改文件、或 zip 解压方式错）
validate 拒                      → 回到 S4
```
**禁止**用 `sudo spctl --master-disable` 让评估"通过"——那是关掉 Gatekeeper，不是验证。

**本机状态**：⚠ 半可执行。`codesign --verify` 已通过；`spctl` 实测 `rejected` / `exit=3`，**该判据在本机不可达**（ad-hoc 且未公证）。

---

### S6 · 产物形态

```bash
ls -l "$ZIP"
unzip -l "$ZIP" | head -5
# 确认 zip 里是 .app 而不是裸 Mach-O
unzip -l "$ZIP" | grep -c "Contents/MacOS/Residue"   # 期望 >= 1
```

**预期输出**：`Residue.app.zip` 存在；`unzip -l` 首行是 `Residue.app/`。

**判据**：
- 分发物**只有 `.zip`（内含已 staple 的 `.app`）**；
- **不分布裸 Mach-O**（不能 staple，用户下载后必被 Gatekeeper 拦）；
- **首发不发 `.dmg`**：`.dmg` 本体也要独立 `codesign` + `notarytool submit` + `stapler staple`，否则断网时 Gatekeeper 对映像本体评估为 `no usable signature` → 挂载即被拦，S7 不可达（§10.1 第 7 条 ⚠ 段已写明）。

**失败判定**：zip 里没有 `.app`；或发现 `.dmg` 但 `stapler validate` 未在 dmg 上跑过。

**本机状态**：✅ 形态可查（实测 `unzip -l` 内含 `Residue.app/Contents/MacOS/Residue`）。「已 staple」不可查。

---

### S7 · 端到端装机（干净机）

**需干净机 + 需真身份。首启必须断网。**

#### S7 操作序列（照做，不要跳）

| # | 动作 | 命令 / 操作 | 判据 |
|---|---|---|---|
| 1 | 准备干净机 | 全新 macOS **14.x** 一台 + 全新 macOS **15.x** 一台；**未装过本产品**（`ls ~/Library/Application\ Support/Residue` 不存在） | 目录不存在 |
| 2 | **断网** | 关闭 Wi-Fi，拔网线；`ping -c1 apple.com` 失败 | 确认无网（这是为了证明「不需要联网回查也能装」） |
| 3 | 下载并**保留 quarantine** | 从 GitHub Releases 下载 `Residue.app.zip`（用浏览器下载，不要用 `curl`，`curl` 不写 quarantine） | `xattr -p com.apple.quarantine ~/Downloads/Residue.app.zip` **有值** |
| 4 | 校验收到的包 | `shasum -a 256 ~/Downloads/Residue.app.zip` 与 Release 说明比对 | 一致（= S8） |
| 5 | 解压 | 双击解压（或 `ditto -x -k`），**不要 `xattr -d com.apple.quarantine`** | 解开后 `xattr -p com.apple.quarantine Residue.app` **仍有值**（本机已实测：quarantine 会随解压传递） |
| 6 | 装入 | 拖入 `/Applications`（Finder 拖拽，不是 `cp`） | `ls -d /Applications/Residue.app` |
| 7 | **首启**（断网状态下） | 双击 `/Applications/Residue.app` | ① 出现 Gatekeeper 首次确认框（「已检查…是否打开」）→ 点「打开」；② **不得出现**「无法打开，因为 Apple 无法检查其是否包含恶意软件」；③ 菜单栏出现 Residue 图标；④ **Dock 无图标**（`LSUIElement=true`） |
| 8 | 打开主界面 | 点菜单栏图标 → 「打开主界面…」（⌘O） | 七页可导航，无崩溃 |
| 9 | 采集范围明示 | 进 ④ 授权与隐私页 | 采集范围文案可见；无「白屏 / 无内容」 |
| 10 | **授权** | 观察 ④ 页的能力探测结论。**按 ADR-06：本步判据不是「FDA 已授」**，而是「未授时产品给出能力探测结论 + 可执行指引，核心流程不被整体阻断」 | 未授 FDA 时：页面给出结论与指引，**不白屏、不静默失败**；授了 FDA 后重进页面结论更新 |
| 11 | **首扫** | 触发首次扫描，等完成 | 扫描跑通；`ls -l ~/Library/Application\ Support/Residue/` 有 `state.residue`（或 `state.json`）；`records/scan.jsonl` 存在且非空 |
| 12 | **登录项** | 系统设置 → 通用 → 登录项与扩展 | 显示 Residue 且为**已启用**（`.enabled`）——**⛔ 当前无实现，见 D4** |
| 13 | **触发一次定时任务** | 等待/手动触发一次计划任务 | 任务真的跑了（`scan.jsonl` 新增一行）——**⛔ 当前无实现，见 D4** |
| 14 | **卸载**（按卸载说明，逐字执行） | ① 菜单栏 → 「退出」；② `pgrep -f "Residue.app/Contents/MacOS/Residue"` 无输出；③ 拖 `/Applications/Residue.app` 到废纸篓并清空；④ `rm -rf ~/Library/Application\ Support/Residue` | ①②③④ 全成功；`ls ~/Library/Application\ Support/Residue` → 不存在 |
| 15 | **重装** | 重复 #5–#7 | 装得上、开得起来 |
| 16 | 终判 | — | **除系统自身的授权对话框外零人工干预、零崩溃、`scan.jsonl` 有记录**（§10.1 第 7 条原文判据） |

#### S7 的失败判定（逐条可判真假）

| 现象 | 判定 | 看哪里 |
|---|---|---|
| 双击后提示「无法打开，因为 Apple 无法检查…」 | **失败**：公证/钉票没到位 | `spctl --assess` + `stapler validate`（S5/S4） |
| 双击后无任何反应 | **失败**：`LSUIElement=true` 下首次启动没有窗口提示，用户以为没装上 | 这是**产品问题**，不是打包问题：缺首启引导（见 C6） |
| 菜单栏有图标但 Dock 也有图标 | **失败**：`LSUIElement` 丢失 | `plutil -extract LSUIElement raw build/Residue.app/Contents/Info.plist` |
| 首启崩溃 | **失败**：多半是 14.x 上用了 15+/26+/27+ 的 API | `log show --last 5m --predicate 'process == "Residue"'`；崩溃报告 `~/Library/Logs/DiagnosticReports/Residue-*.ips` |
| 断网状态下装不上 | **失败**：产物仍需要联网回查 | 检查是否有任何网络代码（本产品应为 0） |
| `scan.jsonl` 为空 / 不存在 | **失败** | 记录目录与写入路径；`lsof -p <pid> | grep Residue` |
| 卸载后 `~/Library/Application Support/Residue` 仍在 | **失败**：卸载说明不可执行 | 重读卸载说明；确认路径大小写 |
| 重装后仍显示旧数据 | **失败**：有状态残留在别处 | `find ~/Library -name "*residue*" -maxdepth 4` |

**本机状态**：⛔ 阻塞，**三重**：
1. 无身份 → 过不了 Gatekeeper（实测 `spctl: rejected`）；
2. 无干净机（宿主 macOS 27.0.1，且无 14.x/15.x 环境）；
3. **#12 / #13 无实现**（全仓库 0 处 `SMAppService`、0 处 `Scheduler`/`Timer`）—— 这一条与身份无关，是**功能缺口**（D4 / C3）。

---

### S8 · SHA-256 对账

**S8a（本地算值，本机可执行）**
```bash
shasum -a 256 "$ZIP" | tee build/SHA256SUMS
# 期望：单行 "<64 hex>  build/Residue.app.zip"
```

**S8b（上传后重新下载再算，需有网 + Release 已发布）**
```bash
curl -L -o /tmp/residue-redownload.zip "<GitHub Release 资产 URL>"
shasum -a 256 /tmp/residue-redownload.zip
diff <(awk '{print $1}' build/SHA256SUMS) <(shasum -a 256 /tmp/residue-redownload.zip | awk '{print $1}')
```

**预期输出**：`diff` 无输出（两值一致）。

**失败判定**：两值不一致（上传损坏 / 传错文件 / 资产被替换）。

**失败看哪里**：GitHub Release 资产大小 vs 本地 `ls -l`；若不一致，**删掉资产重传**，不要改 Release 说明里的 SHA 去迁就下载物。

**同步要求**（§10.1 第 8 条原文）：SHA-256 **写进 Release 说明**；**README 的验证指引同步更新**。

**本机状态**：⚠ S8a 可执行（实测 `a652e96e…b3d2c8e`）；S8b 阻塞（资产未上传）。

---

### S9 · 保留上一版归档 + 首演例外

**S9a 归档（从第二版起强制；首发不适用）**
```bash
mkdir -p releases/"$RESIDUE_VERSION"
cp "$ZIP" releases/"$RESIDUE_VERSION"/Residue.app.zip
shasum -a 256 releases/"$RESIDUE_VERSION"/Residue.app.zip > releases/"$RESIDUE_VERSION"/SHA256SUMS
ls -l releases/"$RESIDUE_VERSION"/
```
**判据**：`releases/<上一版版本号>/` 里同时有 `Residue.app.zip` 与 `SHA256SUMS`。**从第二版起，没有上一版归档不许发布**（否则 §10.2 的回滚只是纸面条款）。

**S9b 首演例外（首发专用：装 → 卸载 → 重装）**

```bash
# 1) 装（用最终 zip，模拟用户路径）
rm -rf /tmp/firstrun && mkdir -p /tmp/firstrun
ditto -x -k "$ZIP" /tmp/firstrun
cp -R /tmp/firstrun/Residue.app /Applications/     # 无管理员权限时用 ~/Applications，并登记偏差

# 2) 首启（本地 build 无 quarantine，可直接 open）
open /Applications/Residue.app
sleep 2
pgrep -f "Residue.app/Contents/MacOS/Residue"      # 期望：有 pid
ls -la ~/Library/Application\ Support/Residue/     # 期望：state.residue / records/scan.jsonl 已生成

# 3) 卸载（严格按卸载说明，两个动作都要做）
osascript -e 'quit app "Residue"' 2>/dev/null || pkill -f "Residue.app/Contents/MacOS/Residue"
sleep 1
pgrep -f "Residue.app/Contents/MacOS/Residue"      # 期望：无输出
rm -rf /Applications/Residue.app
rm -rf ~/Library/Application\ Support/Residue
ls ~/Library/Application\ Support/Residue          # 期望：No such file or directory

# 4) 重装
cp -R /tmp/firstrun/Residue.app /Applications/
open /Applications/Residue.app
sleep 2
ls -la ~/Library/Application\ Support/Residue/
wc -l ~/Library/Application\ Support/Residue/records/scan.jsonl   # 期望：从 0 行重新开始
```

**判据**：重装后为**初始态**，`scan.jsonl` **重新开始**（不是接续卸载前的行数）。

#### 为什么首演判据挂「卸载」，不挂「一键清除」

这是 §10.1 第 9 条 ⚠ 段的核心，必须原样执行，**不许换成「一键清除」**：

| | 「一键清除」（产品内动作） | 「卸载」（用户手动删目录） |
|---|---|---|
| 作用范围 | `records/*.jsonl` + `state/journal.jsonl` + `state/checkpoints.json` + `state/migrating.json` + `state/*.bak` + `state/*.corrupt` + `state/*.tmp` | 整个 `~/Library/Application Support/Residue/` |
| 是否清 `state.residue` | **不清**（S-10 明确：清了就等于能一键洗掉 `a`，而 `a` 是唯一安全凭证） | **清**（目录都没了） |
| 是否受 M4「`a` 只在应用版本变更时清零」约束 | 受（不动 `a`） | 不受（无载体了） |
| 首演判据「重装后为初始态」是否可达 | **必然不可达**：`state.residue` 还在，轮次/`a`/计数日 全在 | 可达 |

**一句话**：把首演判据挂「一键清除」，等于要求产品做一件按设计**不允许做**的事——判据不是难，是**错**。所以首演唯一合法路径是「卸载 = 删 `/Applications/Residue.app` + 删整个 `~/Library/Application Support/Residue/`」。

**本机状态**：⚠ 半可执行。
- **形式可跑**：本机 ad-hoc 产物无 quarantine，`open` 能起来（实测进程 0.153 s 出现，`pkill` 后干净退出）。
- **判据不可达**：实测首启后 `~/Library/Application Support/Residue` **不存在** —— A-9 骨架未接数据层（已知遗留第 4 条），`scan.jsonl` 根本不会生成，`wc -l` 必然报「文件不存在」。**这不是 S9 的失败，是 S9 的前置未就绪**（C16）。

---

### S10（附条）· 测试注入点剥离

```bash
strings "$APP/Contents/MacOS/Residue" | grep -c "RESIDUE_TEST_"
# 期望：0（grep -c 无匹配时输出 0 且 exit 1，故用 || true 包住）
strings "$APP/Contents/MacOS/Residue" | grep "RESIDUE_TEST_" | head -5
```

**预期输出**：`0`，第二条命令无输出。

**失败判定**：计数 > 0。

**失败看哪里**：注入点是否被写在了 `#if DEBUG` 之外；`RESIDUE_TEST_` 是否被拼成了字面量常量；是否用 Debug 构建打了包。

**本机状态**：✅ 已通过（`无 RESIDUE_TEST_ 注入点残留`）。
**一条必须写清的边界**：`PageRenderer.swift` 用 `#if DEBUG` 包住，`-c release` 下**整段不编译**，所以 `strings` 扫不到是**必然**，不是"扫过了没问题"。这两件事的置信度不同，不要混为一谈（见 C-注记）。

---

## 4. 本机实际跑过的命令与输出摘要（执行证据）

```bash
cd /Users/<user>/WorkBuddy/2026-11-06-10-06-29/ResidueApp
./scripts/make_app.sh
./scripts/verify_a5.sh
./scripts/verify_a9.sh
codesign -d --verbose=4 build/Residue.app
spctl --assess --type execute --verbose build/Residue.app
security find-identity -v -p codesigning
xcrun stapler staple /tmp/staple_probe/Residue.app     # 对副本，预期失败
xcrun stapler staple /tmp/q_probe/Residue.app.zip      # 对副本，预期失败
```

| 脚本 / 命令 | 结果 | 原文摘要 |
|---|---|---|
| `make_app.sh` | 通过（ad-hoc） | `Build complete! (5.22秒)`；`共签 1 个 Mach-O`；`Hardened Runtime 已启用`；`SHA-256: a652e96e…b3d2c8e` |
| `verify_a5.sh` | **通过 20 项 / 失败 0 项 / 未覆盖 3 项** | 未覆盖 3 项原文见脚本尾段（staple / SMAppService / TCC 面板） |
| `verify_a9.sh` | **通过 31 项 / 失败 0 项** | 七页结构 / 无算术 / 只读态 / 契约文案 / 视觉基线 |
| `codesign -dvvv` | ad-hoc | `Signature=adhoc`、`TeamIdentifier=not set`、`flags=0x10002(adhoc,runtime)`、**无 `Timestamp=` 行** |
| `spctl --assess` | **rejected，exit 3** | `build/Residue.app: rejected` |
| `security find-identity` | **0 valid identities found** | — |
| `stapler staple <ad-hoc .app>` | **Error 65** | `CloudKit query for Residue.app (2/2031…) failed due to "Record not found".` / `Could not find base64 encoded ticket in response` / `The staple and validate action failed! Error 65.` |
| `stapler staple <.zip>` | **exit 66** | `Stapler is incapable of working with ZIP archive files.` |
| quarantine 传递 | 会传递 | zip 上 `0081;66a1b2c3;Safari;…` → 解开后 .app 上 `0081;00000000;;…`（值被重写但属性保留） |
| 首启 | 进程出现 | `open -n` → 进程 **0.153 s** 出现；`pkill` 后干净退出 |
| 首启落盘 | **无落盘** | `~/Library/Application Support/Residue` 不存在 |

> **对账口径**：以上是**收敛后**一轮的输出（`make_app.sh` → 两个 verify 脚本，均在本次会话内重跑过，不是中间轮次）。

---

## 5. §10.1 / §10.3 本身不可执行的地方（7 条，如实指出）

> 按团队要求：不自己圆过去。每条给「原文位置 → 问题 → 修法」。

| # | 位置 | 问题 | 修法 |
|---|---|---|---|
| **D1** | §10.1 正文 | **编号错位**：正文顺序为 `1,2,3,4,5,6,7,8,10,9`——第 10 条（注入点剥离）插在第 8 与第 9 条之间。按编号执行会漏步。 | 重排为 S1–S9 + S10 附条（本单 §1 已给双向映射）。**建议 R2 侧同步改正文顺序**。 |
| **D2** | §10.1 第 1 条 | 写 `codesign ... --entitlements ...` 但**没给 entitlements 路径**，也没说**哪些 Mach-O 该带**。当前只有 1 个 Mach-O 所以没暴雷；一旦加 `Frameworks/` 或 `PlugIns/`，脚本会把主程序的 entitlements 复制到 helper 上。 | 明确：**主可执行**带 `Resources/entitlements.plist`；**嵌套 code** 用 `--preserve-metadata=entitlements` 或不带 `--entitlements`；顺序先内层后外层。 |
| **D3** | §10.1 第 5 条 | 「`codesign --verify` + `spctl --assess` 双验」**没给判据**（什么算通过）。而 `spctl` 失败退出码是 **3**、成功要看到 `source=Notarized Developer ID`——不写死，执行时会被"没报错就算过"糊过去。 | 判据写死：`verify exit=0` 且 `spctl exit=0` 且输出含 `source=Notarized Developer ID`（本单 S5 已落）。 |
| **D4** | §10.1 第 7 条 ④ | 「登录项状态显示 `.enabled` 且**触发一次定时任务**」——**当前无实现**：全仓库 `SMAppService` 0 处、`Scheduler`/`Timer` 0 处。该步的阻塞原因**不是缺身份**，是**缺功能**，而 §10.1 完全没标这个依赖。 | 把 S7 拆两支：**S7a**（装机/首启/首扫/卸载/重装，阻塞原因 = 身份 + 干净机）、**S7b**（登录项 + 定时任务，阻塞原因 = **未实现**）。**S7b 未实现前，A-10 不得签"通过"**。 |
| **D5** | §10.1 第 8 条 | 「重新下载一次再算」在**发布前**不可执行（资产还没上传）。写成一个步骤会让执行者卡住或跳过。 | 拆为 **S8a**（本地算值，发布前）与 **S8b**（上传后下载复核，发布后 10 分钟内回填）。S8b 未回填 = Release 不算完成。 |
| **D6** | §10.3（第 546 行 / 第 575 行） | **正文断裂**：第 546 行标题「**`.bak` / `.corrupt` 的归属（v1.0 漏登记）**」下面没有正文；正文被甩到第 575 行，以「：放在 `state/` 下…」开头，缺主语。N7「一键清除范围」这条判据在阅读时断链。 | 把第 575 行拼回第 546 行标题之后，补主语「`.bak` / `.corrupt`：放在 `state/` 下…」。 |
| **D7** | §10 开头（第 485–486 行） | **层级错乱**：`## 10. 发布、回滚与兼容` 之后紧跟 `## 9.5 测试注入点约定`，9.5 被放在 10 之后且升为二级标题。 | 把 §9.5 移回 §9 之后，降为 `### 9.5`。 |

> **D4 是硬阻塞，D1/D3/D5 会让执行出错，D2/D6/D7 是文档质量。** 除 D4 需补功能外，其余均为改文档即可关闭。

---

## 6. 回滚演练（§10.2）—— 两支，各写判据

> **总前提**：回滚演练**必须用上一版归档**（S9a）。**首发不适用**（没有上一版），首发只做 S9b 首演例外。
> **未演练不许发布。**
> **回滚是降级、不是等价替代**——这句话必须写进 README 的「已知限制」，不能只写在 PRD 里。

### 演练序列（两支共用）

```
干净机 → 装旧版(0.1.0) → 产生数据（跑一次扫描，制造 a / countedDays / 轮次）
       → 升级到新版(0.2.0) → 产生数据
       → 回滚：退出 → 删 /Applications/Residue.app → 装回 0.1.0
       → 观察只读态 → 再装回 0.2.0
```

### 支 A · 本版**变更了** `schemaVersion`

| 判据 | 怎么测 | 通过条件（可判真假） |
|---|---|---|
| 数据无损 | 回滚前后各算一次 `shasum -a 256 ~/Library/Application\ Support/Residue/state.residue` | 两值**完全一致**（字节数也一致） |
| 只读提示可见 | 看窗口顶部 | 出现静态说明「数据由更高版本创建，本版本只读；**不能执行清理**」 |
| `a` 不被改写 | 看 ③ 页 / ⑤ 页的 `a` 读数 | 显示「**—（由更高版本维护）**」；**绝不显示 `0`**（显示 0 = 假值，比空白更危险） |
| 不写落盘物 | 回滚期间 `ls -lT ~/Library/Application\ Support/Residue/` 前后对比 + `lsof -p <pid> \| grep Residue` | mtime 全部不变；无写句柄 |
| ⑤ 页措辞 | 看 ⑤ 页 | 显示「**只读，不结算**」；**不是**「本轮未结算」（后者会被读成"等一会儿就有"） |
| 恢复可写 | 重装 0.2.0 | 只读条消失；写操作可用；数据仍是升级后的数据 |
| **禁止项** | 检查产品内 | 不得出现「重置本地状态」入口（重置会清掉 `a`）；不得出现任何外部下载地址（D2′） |

### 支 B · 本版**未变更** `schemaVersion`

| 判据 | 怎么测 | 通过条件（可判真假） |
|---|---|---|
| 数据无损 | 同支 A | `state.residue` SHA-256 完全一致 |
| **旧版直接正常加载，不进只读** | 装回 0.1.0 后看窗口顶部 | **无只读条**；无「数据由更高版本创建」文案 |
| 重装后状态一致 | 回滚前 / 重装 0.2.0 后各记一次 `a` / 轮次 / 计数日 | 三项读数**完全一致** |
| **反例守卫** | 若支 B 出现只读提示 | **判失败**，且原因只能是「`schemaVersion` 被误改」——登记为缺陷，不是演练通过 |
| 功能可用 | 回滚后跑一次扫描 | 能扫描、能出报告（不是只读态） |

> **为什么必须分两支**：§10.2 原文 v1.2 只写「只读提示可见」，在**未跳 schema 的版本上永远不可达**——照那一条演练，支 B 会永远"不通过"，然后被人解释成"演练做不了"。分开写才可判。

---

## 7. 拿到 Developer ID 之后的第一件事（按顺序，别跳）

```bash
# ① 确认身份真的在本机（不是只有 .cer）
security find-identity -v -p codesigning        # 期望：1 valid identities found
# ② 修 C1（make_app.sh:105 的 --timestamp=none）—— 不修，后面必被拒
# ③ 存公证凭据
xcrun notarytool store-credentials "residue-notary" --apple-id ... --team-id ... --password ...
# ④ 真身份打包（C1 修复后）
RESIDUE_VERSION=0.1.0 CODESIGN_IDENTITY="Developer ID Application: ..." ./scripts/make_app.sh
# ⑤ 逐条走 S3 → S4 → S5，每步记下输出原文
# ⑥ 再做 S7a（干净机）
```
**顺序不能反**：③ 之前不做 ④（会拿到 ad-hoc 产物）；⑤ 不通过不做 ⑥（在干净机上验一个过不了 Gatekeeper 的包是白跑）。

---

## 8. 客户端实现审查（A-5 / A-8 / A-9）

> **范围**：只评四类——技术栈与工程结构 / 原生交互范式 / 包体与启动 / 平台约束。
> **不评**：设计还原度（颜可读）、用例覆盖（查必究）、业务逻辑正确性（架构与质量）。
> **不重复**：本机无签名身份（已登记）、`PageRenderer` 的 `#if DEBUG`（已登记）、七页未接真实 Metrics（A-9 遗留第 4 条，已登记）。
> 每条给 **文件:行号** + **为什么会上线出事** + **修法**。没有"建议优化一下"。

### 8.1 问题清单（按严重度）

| # | 严重度 | 位置 | 一句话 |
|---|---|---|---|
| **C1** | **阻塞·上线必炸** | `scripts/make_app.sh:105` | 真身份分支用 `--timestamp=none` → **公证必被拒** |
| **C2** | **阻塞** | `Sources/ResidueApp/Pages.swift:10-19` + `:90-110` + `:474-495` | 无 `ScrollView`，而 ② 页 `limit ≤ 200` 行 → **183 行不可达** |
| **C3** | **阻塞** | 全仓库（`SMAppService` 0 处 / `Scheduler` 0 处） | 登录项与定时任务**未实现** → S7④ 判据不可达 |
| **C4** | 高 | `Sources/ResidueApp/ResidueApp.swift:52` + `RootView.swift:16-18` | `Window` + `@State`：**关窗即销毁全部界面状态** |
| **C5** | 高 | `Resources/Info.plist.in`（无 `CFBundleIconFile`）+ `Resources/` 无 `.icns` | 无应用图标 → Finder / 登录项 / TCC 面板显示通用图标 |
| **C6** | 高 | `Sources/ResidueApp/ResidueApp.swift`（全文无 `NSApplicationDelegate`） | `LSUIElement` 下重复启动/双击 Finder **无任何反馈**，用户以为打不开 |
| **C7** | 中 | `Sources/ResidueApp/PageModel.swift:119 / 125 / 150 / 159` | `let id = UUID()` → 每次刷新**行身份全变**，滚动位置丢失、diff 失效 |
| **C8** | 中 | `scripts/verify_a5.sh`（全文无产物新鲜度校验） | 实测：`build/Residue.app` 早于源码 6 分钟，脚本仍报「20 项通过」 |
| **C9** | 中 | `scripts/make_app.sh:215-218` | 真身份分支产出的 zip 是 **staple 前**的 zip，脚本不拦上传 |
| **C10** | 中 | `Package.swift:6` + 产物 `Format=Mach-O thin (arm64)` | 只出 arm64，而 macOS 14 仍支持 Intel → Intel 用户下载后无法运行，且不在公证环节暴露 |
| **C11** | 低 | `scripts/make_app.sh:35` + `ResidueCore/StateStore.swift:147` | `RESIDUE_VERSION` 默认 `0.1.0` 且不强制 → 忘改版本号则 M4「版本变更清零」静默不触发 |
| **C12** | 低 | `Sources/ResidueApp/ResidueApp.swift:33` | `NSApp.activate(ignoringOtherApps:)` macOS 14 起弃用 |
| **C13** | 低 | `Sources/ResidueApp/RootView.swift:142-157` | 侧栏用 `Button(.plain)` → 无键盘导航、无焦点环、无列表语义 |
| **C14** | 低 | `scripts/make_app.sh:112-121` | `--entitlements` 施加到**每个** Mach-O（加 Frameworks 后会污染 helper） |
| **C15** | 观察 | `Sources/`（0 处 `#available`）+ 产物 `sdk 14.0 / minos 14.0` | 不是缺陷（编译器已强制可用性），但**二进制从未在 14.x 跑过** |
| **C16** | 观察 | 首启无落盘（实测） | A-9 未接数据层 → S9b 判据不可达（已知遗留第 4 条的下游影响） |

---

### 8.2 逐条详情与修法

#### C1 · `make_app.sh:105` 真身份分支产出**不可公证**的签名（阻塞）

```bash
105  SIGN_FLAGS=(--force --options runtime --timestamp=none)
106  if [ "$IDENTITY" = "-" ]; then
107    SIGN_FLAGS=(--force --options runtime)   # ad-hoc 不能用 --timestamp
108  fi
```
逻辑是**反的**：基础值设成 `--timestamp=none`，然后只在 ad-hoc 分支**去掉**它 —— 结果**只有 ad-hoc 分支是对的**，真身份分支（唯一需要时间戳的分支）拿到的是 `--timestamp=none`。

实测证据：`codesign --force --sign - --options runtime --timestamp=none` **退出码 0**（标志被接受，不报错）—— 也就是说它不会在执行时暴露，会**静默产出没有安全时间戳的签名**，然后在 S3 被 Apple 拒。

**为什么会上线出事**：这个 bug 在 ad-hoc 开发期**永远看不到**（ad-hoc 本来就没时间戳），只在拿到 Developer ID 的第一次真实发布时炸，而那时离发版只剩几小时。日志原文是 `The signature does not include a secure timestamp`，看日志的人第一反应会怀疑证书或网络，不会想到是自己脚本里一个 `=none`。

**修法**（改 4 行）：
```bash
# ad-hoc：不能有 --timestamp（ad-hoc 没有 Team ID，TSA 会拒）
# 真身份：必须有 --timestamp（无值 → 用 Apple 默认 TSA），否则公证必拒
if [ "$IDENTITY" = "-" ]; then
  SIGN_FLAGS=(--force --options runtime)
else
  SIGN_FLAGS=(--force --options runtime --timestamp)
fi
```
并在 `[4/7]` 加一条断言，让它在本地就炸，而不是等到 Apple 那边：
```bash
if [ "$IDENTITY" != "-" ]; then
  codesign -d --verbose=4 "$APP" 2>&1 | grep -q "Timestamp=" \
    || { echo "✗ 真身份签名缺安全时间戳 → 公证必被拒（§10.1 第 1 条）" >&2; exit 1; }
fi
```

---

#### C2 · ②/⑦ 页内容**不可达**（阻塞）

`Pages.swift:10-19` 把原因写得很清楚：
```
## 本版**不使用 `ScrollView`**（一个踩过的坑）
`ImageRenderer` 不渲染 `ScrollView` 的内容 → 用 ScrollView 包着的页在离屏渲染里是整页空白
```

**问题不是"没有 ScrollView"，是"开发期渲染工具反向决定了产品版式"。**

**为什么会上线出事**（用数字说）：
- `Pages.swift:90-110` 的 `EnvironmentsPage` 是 `VStack { ForEach(model.candidateRows) { ... .frame(height: 32) } }`，**外面没有任何滚动容器**；
- ② 页数据源上限是 **`limit ≤ 200` 行/页**（R2 ADR-01 第 44 行原文：「第 ② 页候选清单用分页数据源（IF-06，`limit ≤ 200`）」）；
- 窗口可用高度 ≈ `640 − 页头(≈45) − 分页条(≈29)` ≈ **566 pt**；
- `32 pt × 200 行 = 6400 pt` → **一屏只能看到 17 行，其余 183 行在窗口外，且无任何手段可达**（不能滚、不能缩放、分页条也救不了单页内的 200 行）。
- ⑦ 页 `EvidencePage`（`:474-495`）同样问题：执行记录条数无上限（`evidence.jsonl` 10 万条量级，见 R2 §7.5），`VStack` 直排必炸。

**顺带一个 ADR 偏离**：R2 ADR-01 第 44 行指定「第 ⑤ 页矩阵用 `Table` + 固定列宽」，实现改成了自建 `HStack` 网格（`Pages.swift:316-345`）。同一个根因（`Table` 在 `ImageRenderer` 下也渲染不出来）。代价是**丢了表格的无障碍语义**：VoiceOver 读不出「第 3 行第 5 列 = 第 2 轮」，只能读成一串孤立文本。

**修法**（不要删渲染工具，把依赖方向倒过来）：
1. 引入渲染模式开关（只在 DEBUG 存在）：
   ```swift
   // PageModel.swift 或 DesignTokens.swift
   private struct RenderModeKey: EnvironmentKey { static let defaultValue = false }
   extension EnvironmentValues { var residueRenderMode: Bool {
       get { self[RenderModeKey.self] } set { self[RenderModeKey.self] = newValue } } }
   ```
2. 产品路径改用滚动容器：
   ```swift
   // EnvironmentsPage / EvidencePage
   ScrollView {
       LazyVStack(spacing: 0) { ForEach(model.candidateRows) { ... } }
   }
   ```
3. `RenderWrapper`（`PageRenderer.swift:77`）在 `.environment(\.residueRenderMode, true)` 下走**非滚动**分支（`VStack` 直排），并在渲染时用 `.frame(height: contentHeight)` 撑开；
4. ⑤ 页产品路径换回 `Table`，渲染路径保留自建网格；
5. 加断言：`ScrollView` 出现在 ②/⑦ 页（`verify_a9.sh` 加一条 grep），渲染模式下出现 `residueRenderMode`。

---

#### C3 · 登录项与定时任务**未实现**（阻塞，且被误记成"未覆盖"）

实测：`Sources/` 下 `SMAppService` **0 处**、`Scheduler`/`Timer`/`LaunchAgent` **0 处**。

**为什么会上线出事**：`verify_a5.sh:195-200` 把「② SMAppService 在 .app 下不抛签名错」标成 `⊘ 未覆盖（无身份）`。这个措辞把两件事混成一件：
- 真原因 A：无身份 → 确实测不了签名错；
- 真原因 B：**代码里根本没有调用 `SMAppService`** → 就算有身份也测不了，因为**没有可测对象**。

而 §10.1 第 7 条 ④ 的判据是「登录项状态显示 `.enabled` 且触发一次定时任务」——这一条与身份无关，是**功能缺口**。若 A-10 按"未覆盖 3 项"签字，等于把一个**未实现**的功能记成"环境所限"。

**修法**：
1. `verify_a5.sh` 的 ② 改成两段判定：
   ```bash
   if ! grep -rq "SMAppService" Sources/ ; then
     bad "SMAppService 未被调用：登录项功能未实现（不是环境所限）"
   elif [ "$IDENTITY_OK" = true ]; then
     skip "需在真身份 GUI 会话实跑"
   else
     skip "本机无 Developer ID 身份"
   fi
   ```
2. 把「登录项 + 定时任务」立为独立任务项（不是 A-10 的一部分），A-10 的 S7 拆成 S7a/S7b（D4）；
3. 在此之前，**A-10 结论只能是"结构就绪，功能未就绪"，不能是"通过"**。

---

#### C4 · `Window` + `@State`：关窗即销毁全部界面状态（高）

```swift
// ResidueApp.swift:52
Window("Residue", id: "main") { RootView() }

// RootView.swift:16-18
@State private var selection: Page = .overview
@State private var showConfirmDrawer = false
@State private var model = PageModel.skeleton()
```

`Window`（不是 `WindowGroup`）在用户点红点关闭时**销毁场景与内容视图**，`@State` 全部丢弃；下次 `openWindow(id: "main")` 是**全新构造**。

**为什么会上线出事**：这是**菜单栏常驻 App 的用户常态**——用户不"退出"App，用户"关掉窗口"把界面收起来，几秒后再点菜单栏打开。当前实现下，这个动作等于：
- 选中的页回到 ①（用户正在 ⑤ 看报告，关一下窗就丢了）；
- 确认抽屉的选择清空；
- **接真实 Metrics 后：正在跑的扫描连同进度一起没了，且没有任何提示**——用户看到的是"我明明在扫，怎么又回到初始态"。

**修法**（二选一，推荐 1）：
1. 把界面状态提到 App 级，由 `@main` 持有：
   ```swift
   @Observable final class AppModel { var selection: Page = .overview; var model = PageModel.skeleton() }
   @main struct ResidueApp: App {
       @State private var appModel = AppModel()
       Window("Residue", id: "main") { RootView().environment(appModel) }
   }
   ```
2. 或保留 `@State`，但阻止窗口销毁：`NSApplicationDelegateAdaptor` 里拿 `NSApp.windows.first`，设 `isReleasedWhenClosed = false`，并在 `windowShouldClose` 里 `orderOut` 而不是 close。

**验收**：打开 ⑤ 页 → 关闭窗口 → 从菜单栏重开 → 仍在 ⑤ 页。

---

#### C5 · 无应用图标（高）

`Resources/` 只有 `Info.plist.in` 与 `entitlements.plist`，**无 `.icns`**；`Info.plist.in` **无 `CFBundleIconFile`**。实测 `codesign -dvvv` 显示 `Sealed Resources ... files=0`。

**为什么会上线出事**：
- Finder 里 `/Applications/Residue.app` 是**通用白色图标**——一个"清理工具"用白纸图标，用户第一反应是"这是不是个假 App / 装坏了"；
- **系统设置 → 登录项**列表、**TCC 授权面板**、**活动监视器**全都显示通用图标 → 用户在一堆条目里认不出哪个是本产品，容易误关/误授；
- S7③（TCC 面板能认到）的可发现性直接依赖它。

**修法**：
1. 出 `Resources/AppIcon.icns`（1024/512/256/128/32/16 六档）；
2. `Info.plist.in` 加 `<key>CFBundleIconFile</key><string>AppIcon</string>`；
3. `make_app.sh:83-91` 的资源拷贝循环已覆盖 `Resources/*`（会跳过 `Info.plist.in`/`entitlements.plist`），`.icns` 会自动进 `Contents/Resources/` —— **但要加断言**：`[ -f "$CONTENTS/Resources/AppIcon.icns" ] || exit 1`；
4. `verify_a5.sh` 加一条：`plutil -extract CFBundleIconFile raw` 非空 且 对应文件存在。

---

#### C6 · `LSUIElement` 下重复启动无任何反馈（高）

`ResidueApp.swift` 全文没有 `NSApplicationDelegate`，也没有 `applicationShouldHandleReopen`。

**为什么会上线出事**：产品无 Dock 图标（`LSUIElement=true`，正确）。于是用户在 Finder / Launchpad 里再次双击 `/Applications/Residue.app` 时：
- 系统发现进程已在跑 → 走 reopen 路径 → **无人实现 `applicationShouldHandleReopen`** → **什么都不发生**；
- 用户视角：双击了，没反应 → "这 App 坏了" → 再双击三次 → 去 GitHub 提 issue。
- 同一个坑还会命中 `open -a Residue`（脚本/快捷指令路径）。

**修法**：
```swift
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first?.makeKeyAndOrderFront(nil) }
        NSApp.activate()
        return true
    }
}
@main struct ResidueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    ...
}
```
**验收**：App 在跑且窗口已关 → Finder 双击 App → 主窗口出现并前置。

---

#### C7 · `PageModel.swift:119/125/150/159` 行身份每次刷新都变（中）

```swift
struct OverviewBlock: Identifiable { let id = UUID(); ... }   // :119
struct CandidateRow:  Identifiable { let id = UUID(); ... }   // :125
struct ReportRow:     Identifiable { let id = UUID(); ... }   // :150
struct EvidenceRow:   Identifiable { let id = UUID(); ... }   // :159
```

`let id = UUID()` 在**每次构造**时生成新值。`PageModel` 是值类型，任何字段变化（接真实 Metrics 后 = 每 100 ms 一次进度刷新）都会重建整个 `PageModel`，于是**所有行的 `id` 全变**。

**为什么会上线出事**：
- SwiftUI 靠 `id` 判断"这是同一行"，`id` 全变 = 全部行被当作**删除 + 新增** → `ForEach` diff 失效；
- ② 页滚到第 150 行，刷新一次 → **滚动位置跳回顶部**；
- 行内动画（徽标淡入、数值滚动）每次刷新重播；
- 200 行 × 每 100 ms 重建 = 主线程持续做无意义的身份计算 → 掉帧，且在低端 Intel Mac 上更明显。

**修法**：`id` 用业务稳定键：
```swift
struct CandidateRow: Identifiable { let path: String; var id: String { path }; ... }
struct OverviewBlock: Identifiable { let source: String; var id: String { source }; ... }
struct EvidenceRow:   Identifiable { let recordID: String; var id: String { recordID }; ... }
struct ReportRow:     Identifiable { let source: String; var id: String { source }; ... }
```
（`ReportRow.source` 天然唯一；`EvidenceRow` 用 `execution.jsonl` 的记录 id。）

---

#### C8 · 校验脚本不查"产物是否比源码新"（中）

实测：
```
2026-11-08 17:12:56  build/Residue.app/Contents/MacOS/Residue   ← 产物
2026-11-08 17:18:50  Sources/ResidueApp/Pages.swift             ← 源码（晚 6 分钟）
2026-11-08 17:19:18  Sources/ResidueApp/Components.swift        ← 源码（晚 6 分钟）
```
在这个状态下跑 `verify_a5.sh`，输出是 **「通过 20 项 / 失败 0 项」**——它验的是一个**不含最后两次改动的旧包**。

**为什么会上线出事**：这是最典型的"绿灯骗人"。发布日有人改了 UI 一行、忘了重打、直接跑 verify 拿绿灯、上传 → 用户拿到的是旧包。事后查日志会发现"验过"，但验的不是发出去的那个。

**修法**（`verify_a5.sh` 开头加 8 行）：
```bash
NEWEST_SRC="$(find Sources Package.swift Resources -newer "$APP/Contents/MacOS/Residue" -type f 2>/dev/null | head -5)"
if [ -n "$NEWEST_SRC" ]; then
  echo "✗ 产物比源码旧，先重跑 ./scripts/make_app.sh：" >&2
  echo "$NEWEST_SRC" >&2
  exit 1
fi
```
并在 `verify_a5.sh` 输出里打印产物 mtime 与 zip SHA-256（已有 SHA，补 mtime）。

---

#### C9 · 真身份分支产出的 zip 是"staple 前"的 zip（中）

```bash
215  ZIP="$BUILD_DIR/$APP_NAME.app.zip"
218  ditto -c -k --keepParent "$APP" "$ZIP"
...
243  ⚠ 钉票后须**重新打 zip**（zip 本身不可 staple，票据在 .app 内）
```
脚本先把 zip 打好，然后在第 7 步用**注释**提醒"要重打"。真身份分支下，`build/Residue.app.zip` 这个文件名会同时指代"待公证的 zip"和"待分发的 zip"，**只靠人记**。

**为什么会上线出事**：`notarytool submit` 用的就是 `Residue.app.zip`，人的肌肉记忆是"脚本产出的 zip 就是发布物" → 直接把**未钉票**的 zip 传到 GitHub。用户断网安装时 Gatekeeper 拿不到票据 → 被拦 → S7 全线不可达，而发布方本地一切绿灯。

**修法**：
1. 中间产物改名，让错的文件名不存在：`build/Residue.app.prestaple.zip`（S3 用），最终 `build/Residue.app.zip` 只在 `stapler validate` 通过后生成；
2. 真身份分支下，脚本末尾**不产出** `Residue.app.zip`，而是打印：
   ```
   下一步：xcrun notarytool submit build/Residue.app.prestaple.zip ...
   ```
3. 加一道断言：`if [ -f "$ZIP" ] && ! xcrun stapler validate "$APP"; then echo "✗ 存在最终 zip 但 .app 未钉票" >&2; exit 1; fi`

---

#### C10 · 只出 arm64（中）

实测 `codesign -dvvv` → `Format=app bundle with Mach-O thin (arm64)`；`lipo -archs` → `arm64`。

**为什么会上线出事**：`LSMinimumSystemVersion = 14.0` 意味着产品**声明**支持 macOS 14，而 macOS 14 仍支持 Intel Mac。Intel 用户下载后得到的是"此应用无法在你的 Mac 上运行"——**而且这个错不在公证环节暴露**（公证只看签名，不看架构），发布方看不到任何红灯。

**修法**（二选一，必须选一个并写进 Release 说明）：
1. **声明不支持 Intel**（推荐首发）：README + Release 说明 + 产品页写「仅支持 Apple Silicon（arm64）」；`Info.plist` 不需要改（`LSMinimumSystemVersion` 是系统版本，不是架构）；
2. **出 universal**：`swift build -c release --arch arm64 --arch x86_64`，`lipo -archs` 验出 `arm64 x86_64`，包体约翻倍（≈3.6 MB，仍远低于任何预算），并在 S7 里**加一台 Intel 干净机**。

---

#### C11 · `RESIDUE_VERSION` 默认值 + M4 清零（低，但会静默违约）

```bash
# make_app.sh:35
VERSION="${RESIDUE_VERSION:-0.1.0}"
```
```swift
// StateStore.swift:147
public func resetIfVersionChanged(state: inout PersistedAppState, currentVersion: String) -> Bool {
    guard !state.appVersion.isEmpty, state.appVersion != currentVersion else { ... return false }
    state.resetCarrierForVersionChange(newVersion: currentVersion)   // 清 F / C_done / 位槽 / a
}
```

**为什么会上线出事**：契约 M4 规定「应用版本变更时 `a` 一并清零」。若发布时忘了 `export RESIDUE_VERSION`，两个不同版本的包都叫 `0.1.0` → `appVersion` 不变 → **载体不清零**，与 M4 相反。这是**静默违约**：不报错、不告警，只有事后比对 `state.json` 才发现。反过来，如果每次都随手改版本号，用户的 `a`（唯一安全凭证）每次都被清——**两个方向都是契约违约**。

**修法**：发布模式下强制显式给定，并在脚本里断言"与上一版不同"：
```bash
if [ -z "${RESIDUE_VERSION:-}" ] && [ "${RESIDUE_RELEASE:-0}" = "1" ]; then
  echo "✗ 发布模式必须显式给 RESIDUE_VERSION（M4 依赖它判定清零）" >&2; exit 1
fi
# 与上一版归档比对
if [ -f "releases/$VERSION/SHA256SUMS" ]; then
  echo "✗ 版本号 $VERSION 已存在归档，版本号未变更 → M4 清零不会触发" >&2; exit 1
fi
```
并把「本版是否变更版本号 / 是否变更 `schemaVersion`」写进 Release 说明的固定两行（回滚演练分支援引这两行）。

---

#### C12 · `NSApp.activate(ignoringOtherApps:)` 弃用（低）

`ResidueApp.swift:33`。macOS 14 起弃用，编译有 deprecation 告警。修法：`NSApp.activate()`（macOS 14+ 语义等价，且是当前推荐写法）。

---

#### C13 · 侧栏无键盘导航 / 无列表语义（低）

`RootView.swift:142-157` 的 `NavRow` 是 `Button { } .buttonStyle(.plain)` 排在一个 `VStack` 里。

**为什么会上线出事**（不是审美）：
- **无 ⌘1–⌘7**：macOS 用户的习惯是键盘切页；当前 7 页只能鼠标点；
- **无焦点环**：Tab 键遍历时看不到焦点在哪（`.plain` 去掉了按钮外观，但没补 focus ring）；
- **无列表语义**：VoiceOver 读不到"7 项中的第 3 项"，也读不到"已选中"。

**修法**：
1. 每行加 `.keyboardShortcut(KeyEquivalent(Character("\(page.rawValue + 1)")), modifiers: .command)`；
2. 或整体换成 `List(Page.allCases, selection: $selection) { ... }`（自带选中语义、焦点、VoiceOver 支持）；
3. 行上补 `.accessibilityAddTraits(selected ? [.isSelected] : [])`。

---

#### C14 · `--entitlements` 施加到每个 Mach-O（低，但是结构性坑）

`make_app.sh:112-121` 对 `find "$APP" -type f` 里每个 Mach-O 都传 `--entitlements "$ENTITLEMENTS"`。当前只有 1 个 Mach-O 所以无害；一旦加 `Frameworks/*.framework` 或 `PlugIns/*.appex`，helper 会带**主程序**的 entitlements。公证一般接受，但语义错误，且将来若要开沙盒会立刻出问题。

**修法**：
```bash
codesign --force --options runtime --timestamp \
  --preserve-metadata=entitlements --sign "$IDENTITY" "$candidate"   # 嵌套 code
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$CONTENTS/MacOS/Residue"  # 仅主可执行
```

---

#### C15 · SDK/minos 与"从未在 14.x 跑过"（观察，不是缺陷）

`otool -l` → `minos 14.0` / `sdk 14.0`；宿主 Xcode 27.2 / SDK 27.2；`Sources/` 里 **0 处 `#available`**。

**结论要说清**：这不是缺陷。Swift 编译器对"部署目标 14.0 却用了 15+ API"是**编译期报错**，所以"零 `#available`"恰恰说明**没用到 14.0 之后才有的 API**（或都已由标准库处理）。

**真正的风险在别处**：这个二进制**从未在任何 14.x / 15.x 上被执行过**（宿主是 27.0.1）。同一份代码在不同系统版本上的行为差异（SwiftUI 布局、`MenuBarExtra` 渲染、TCC 提示文案）**只能靠 S7 的干净机覆盖**。这就是 S7 不能跳的原因，也是它被标"阻塞"的原因。

---

#### C16 · 首启不落盘 → S9b 判据不可达（观察）

实测：`open build/Residue.app` 后 `~/Library/Application Support/Residue` **不存在**。

**这不是 bug**，是 A-9 骨架未接数据层（已登记遗留第 4 条）的直接后果。但它有一个**下游影响必须登记**：§10.1 第 9 条首演例外的判据是「重装后为初始态、`scan.jsonl` 重新开始」——**当前跑这条命令必然报「文件不存在」**。执行 S9b 的人会误以为"卸载说明有问题"，实际是**产品还没开始写文件**。

**修法**：S9b 在 A-9 之后、接真实数据层之后再执行；在此之前 S9b 的状态是「**前置未就绪**」，不是「通过」也不是「失败」。

---

### 8.3 包体与启动

| 指标 | 平台 | 预算 | 实测（Release / ad-hoc） | 结论 |
|---|---|---|---|---|
| `.app` 包体 | macOS arm64 | PRD 未给数值；客户端建议 ≤ 30 MB（零依赖单 App） | **1.8 MB**（主二进制 1,888,416 B，无资源文件 `files=0`） | ✅ 远低于建议值 |
| 分发 zip | macOS arm64 | — | **472 KB** | ✅ |
| 冷启动（进程就绪） | macOS 27.0.1 / arm64 | 客户端建议 ≤ 800 ms（进程出现） | **0.153 s**（`open -n` → `pgrep` 命中，50 ms 轮询，单次测量） | ✅ 但**不是首帧** |
| 首帧 | macOS arm64 | 建议 ≤ 400 ms | **未测** | ⚠ 无头会话无法测（`screencapture` 全黑，`PageRenderer.swift:8-9` 已记录）；须在 S7 干净机上用 `os_signpost` 或录屏帧计数补测 |
| 常驻内存 | — | — | **未采集** | ⚠ 本会话 `ps` 被沙箱拒绝（`operation not permitted: ps`），须在 S7 机器上用活动监视器补 |
| Universal（含 Intel） | — | — | **无**（thin arm64） | ⚠ 见 C10：要么声明只支持 Apple Silicon，要么出 universal（包体约 ×2 = 3.6 MB，仍可接受） |

**启动路径浪费检查**（`grep` 实测）：
- App 层（`Sources/ResidueApp/`）**0 处** `FileManager` / `Data(contentsOf:)` / 网络调用 —— 启动不做 IO；
- `ResidueApp.init()` 只做一次 `#if DEBUG` 判断（Release 下整段不编译）；
- `PageModel.skeleton()` 是纯内存构造，一次性；
- 结论：**启动路径没有明显浪费**。首帧的未知量在 SwiftUI 首窗口布局（`Window` + 7 页视图树），只能实测。

---

### 8.4 平台一致性差异（单平台产品，此项只登记"跨系统版本"差异）

| 业务对象 | 字段/状态/交互 | macOS 14 | macOS 15 | macOS 27（宿主） | 是否需统一 |
|---|---|---|---|---|---|
| 菜单栏图标 | `MenuBarExtra` 渲染尺寸/间距 | 未测 | 未测 | 已见（SF Symbol `internaldrive`） | 系统决定，不自行统一 |
| 首启 Gatekeeper 对话框 | 文案与按钮 | 未测 | 未测 | 未测（本机无 quarantine 产物） | 系统决定；S7 须逐版本截图留档 |
| TCC 授权面板 | 条目显示与图标 | 未测 | 未测 | 未测 | 系统决定；依赖 C5 的图标 |
| 登录项（`SMAppService`） | 系统设置里的位置 | 未测（**未实现**） | 未测 | 未测 | — |
| 深色模式 | 全部七页 | 未测 | 未测 | 已定 `preferredColorScheme(.dark)` | 产品只做深色，无需统一 |

> 本产品是**单平台（macOS）单产物**，没有 iOS/Android/鸿蒙一致性表。上表的作用只有一个：**别把"在 27 上看着对"当成"在 14 上对"**。

---

## 9. 已知缺口与阻塞登记

| # | 缺口 | 影响 | 建议处理 | 是否阻塞发布 |
|---|---|---|---|---|
| B1 | 无 Developer ID 身份（0 identities） | S1 真身份分支 / S3 / S4 / S5 的 spctl 判据 / S7 全部不可执行 | 拿到证书后按 §7 顺序执行 | **是** |
| B2 | `make_app.sh:105` `--timestamp=none`（C1） | 拿到身份后第一次公证必被拒 | 改 4 行 + 加断言 | **是** |
| B3 | 登录项 + 定时任务未实现（C3 / D4） | S7④ 判据不可达；`verify_a5.sh` 的"未覆盖"措辞失真 | 立独立任务项；S7 拆 S7a/S7b | **是** |
| B4 | ②/⑦ 页无滚动容器（C2） | 200 行/页 → 183 行不可达 | 产品路径加 `ScrollView`，渲染模式开关 | **是** |
| B5 | 无干净机（宿主 macOS 27.0.1） | 14.x / 15.x 兼容性零证据 | 备 macOS 14 + 15 各一台 | **是** |
| B6 | 首帧 / 常驻内存未测 | 性能预算无实测值 | S7 机器上用 `os_signpost` + 活动监视器补 | 否（但须在发布前补） |
| B7 | 只出 arm64（C10） | Intel 用户装不上 | 声明仅 Apple Silicon，或出 universal | 否（声明即关闭） |
| B8 | 无应用图标（C5） | 可发现性 / 专业度 / 登录项与 TCC 识别 | 加 `.icns` + `CFBundleIconFile` + 断言 | 否（但首发建议带） |
| B9 | `state.residue` 与 `state.json` 两个载体并存（`ResidueStateFile.swift` vs `StateStore.swift`） | 卸载说明只写"删整个目录"所以**不影响 S9**；但 A-7 升级后旧载体是否还需要迁移，客户端侧看不到结论 | 交架构确认哪个是唯一载体（不在我范围） | 否 |
| B10 | 包体/启动预算 PRD 未给数值 | 无法判"是否达标" | 由架构补预算数值 | 否 |

---

## 10. 一句话结论

**九步里本机只能完整执行 3 步（S2 / S6 / S10），2 步半可执行（S5 / S8），4 步被身份阻塞（S1 真身份分支 / S3 / S4 / S7）。**
其中 **S7 是三重阻塞**：无身份 + 无干净机 + **登录项与定时任务根本没实现**（这一条与身份无关，是功能缺口，§10.1 没标）。

**A-10 当前状态：结构就绪，发布准入未就绪。** 拿到 Developer ID 前，能推进的不是"跑九步"，而是先关掉 **C1 / C2 / C3** 这三个会在发布日当天炸的问题。

---

## 11. 发布把关结论（常在线）

> **编号说明**：主理人指令要求本节标 `§9`；本文件 §9 已被「已知缺口与阻塞登记」占用，为避免改动既有编号，本节编为 **§11**，内容与格式按指令执行。
> **我不是来评审这份执行单写得好不好**（那写得比我见过的平均水平好，尤其 §5 的 D1–D7 和 §9 的 B1–B10）。我来判**一件事：以当前产物状态，明天能不能发。**
> **我复核的时间**：2026-11-08 18:0x，`ResidueApp` 目录 mtime `18:02`。**执行单 mtime 是 17:44 —— 我读的是比它新的代码。** 下面凡是与该单结论不一致的地方，我都给了命令与文件行号。

---

## 发布把关结论

- **结论：不可发（NO-GO）**

一句话：**这个产物是一个没有数据层的 UI 外壳，签名链不可通过，两个核心机制（登录项 / 定时任务）在源码里是 0 处。三者任一单独成立就已经不能发，现在是三条同时成立。**

### 三条理由（每条都附我自己的实测，不引用别人的结论）

| # | 理由 | 我的实测证据 | 为什么这一条单独就能否掉发布 |
|---|---|---|---|
| **1** | **产物没有数据层：`ResidueCore` 9417 行逻辑从未进入运行路径** | `grep -c "StateStore(\|RecordWriter(\|StateFile("` → Sources 下 **0 处**；App 层 `Metrics\|SourceL0State\|ObservationWindow` → **每文件 0 处**；`PageModel.swift` 文件头自述「**本阶段只做骨架**」；首启后 `~/Library/Application Support/Residue` **不存在** | 用户双击装好后能看见七页，但**扫描不跑、不落盘、不判 L0、不删任何东西**。发出去的是"一个看起来能用的界面"，产品对外承诺的 19 个 AC 里**没有任何一个在运行路径上**。这不是"缺陷"，是"能力不存在"——按我的规矩前者可等、后者不能发 |
| **2** | **签名链不可通过：用户装不上** | `security find-identity -v -p codesigning` → **0 valid identities found**；`codesign -dvvv` → `Signature=adhoc`、**无 `Timestamp=` 行**；`spctl --assess --type execute` → **`rejected`, exit 3** | Gatekeeper 会在**双击那一刻**拦住，`装上` 这一步就断，§10.1 的第 3–9 条全部失去意义。这一条与我的判断无关，是系统行为：`spctl` 已经替我判了 |
| **3** | **两个核心机制在源码里不存在：登录项 0 处、定时任务 0 处** | `grep "SMAppService"` → **No matches found**；`grep "Scheduler\|Timer\|LaunchAgent\|launchctl"` → **No matches found** | 产品的核心承诺是「14 天观察期 + 每日定时执行 + 达标后自动删」。**没有定时任务，自动删除永远不会自己发生**——用户点亮后什么都不会发生，且界面上找不到解释。没有登录项，用户重启后产品根本不在。这两条**不是「未覆盖」，是「不存在」** |

### 我另外核出的一条（执行单没写）

**`Pages.swift:268-270`：「一键清除采集物与日志」按钮的 action 是空的**：

```swift
Button("一键清除采集物与日志") {
    // 骨架阶段：动作由后续接 StateStore / RecordWriter
}
```

这带来一个与 §10.1 第 9 条强相关的后果，见下面第二节。

---

## 一、九步独立复核（不照抄「3 步可跑」，我自己数出来是 1 步）

我用的判定口径比执行单**更严一格**：一步算"通过"必须同时满足 ① 命令能跑 ② **判据可达** ③ 判据**当前已满足**。只有 ① 不算通过。

| 步 | 执行单判 | 我的复核 | 我实测到的 | 差异说明 |
|---|---|---|---|---|
| **S1** 组装 + 逐 Mach-O 签名 | ⚠ 部分 | **不可通过** | ad-hoc 分支能产出包；真身份分支代码**已修**（`make_app.sh:112-121` 现在是 `--timestamp` 无 `=none`，且 `:182` 有 `Timestamp=` 断言）→ **但无身份，这个分支从未被执行过一次**，改对了没验过等于没改 | 执行单 §9 的 **B2 仍把 C1 列为阻塞——已过时**，会让人重复做已完成的活 |
| **S2** `get-task-allow` = false | ✅ 通过 | ✅ **通过（唯一一条）** | `codesign -d --entitlements :-` → `<dict></dict>`，`get-task-allow` **0 处** | 一致 |
| **S3** 公证 | ⛔ 阻塞 | ⛔ 阻塞 | 无身份、无凭据、资产未上传 | 一致 |
| **S4** 钉票 | ⛔ 阻塞 | ⛔ 阻塞 | 依赖 S3 | 一致 |
| **S5** 双验 | ⚠ 半可执行 | **必然判失败** | `codesign --verify` 能过；`spctl` 实测 `rejected` → 判据**不是"半可执行"，是"当前必然不通过"** | 措辞差异重要：半可执行会让人以为"再努一下就过"，实际是"再努也要等身份" |
| **S6** 产物形态 | ✅ 可执行 | **不可签字** | 判据两条：① zip 内含 `.app` ✅（我核 `Residue.app.zip` 482681 B）；② 内含**已 staple** 的 `.app` ❌ **不可判**（无票据） | 执行单把"形态可查"当成了"步骤可执行"。判据有一半不可达就不能签字 |
| **S7** 端到端装机 | ⛔ 三重阻塞 | ⛔ **五重阻塞** | 执行单说三重（身份 / 干净机 / 登录项+定时任务）。我再加两重：④ **首扫不落盘 → 判据 #11「`scan.jsonl` 存在且非空」也不可能通过**；⑤ **数据层未接线 → #8「七页可导航无崩溃」能过，但 #9 之后的每一步都在验不存在的功能** | 这是本次把关最重要的一处修正：S7 不是"等身份就能跑"，是**等数据层才能跑** |
| **S8** SHA-256 对账 | ⚠ 半 | S8a ✅ / S8b ⛔ | S8a 我复算过 zip 存在（482681 B）；S8b 资产未上传 | 一致 |
| **S9** 归档 + 首演例外 | ⚠ 半（判据不可达） | **不可判，且判据恒真** | 见第二节 | **这是我判得最重的一处，与执行单结论方向一致但理由不同** |
| **S10** 注入点剥离 | ✅ 通过 | **能跑，但零证据价值** | `strings \| grep -c "RESIDUE_TEST_"` → **0**（我实测）；但这个 0 是**必然**的：`PageRenderer` 整段在 `#if DEBUG` 内，Release 不编译 → 扫不到是构造决定的，不是扫过了没问题 | 执行单 §3 S10 已经自己写了这条边界（很诚实），但 §2 前置矩阵里仍标 ✅ 可执行 → 两处口径不一致。**一条恒真的判据不该出现在"已通过"一栏** |

**我的计数**：**完整通过 1 步（S2）｜ 半数判据可判 2 步（S6 形态 / S8a）｜ 不可通过 7 步。**
执行单说 3 步完整（S2/S6/S10）。**差的 2 步就是 S6 的"已 staple"和 S10 的"恒真"。**

---

## 二、首演判据挂「卸载」还是「一键清除」—— 核完：文档判断对，但理由少了一条，且判据本身恒真

**结论：挂「卸载」正确，不许换成「一键清除」。三份材料一致，代码与文档不矛盾。**

| 我核的对象 | 实测 | 与文档是否一致 |
|---|---|---|
| `R2 §10.1 第 9 条` 原文（第 521 行） | 「**首演判据只能挂「卸载」，不能挂「一键清除」**——否则按设计必然失败」 | ✅ 执行单 §3 S9b 的引述**逐字准确** |
| `StateFile.swift:12 / 235-236` | 「N7「一键清除全部采集物与日志」**不作用于它**」；`clearCarrierForVersionChange` 注释「⚠️ **这不是 N7 的「一键清除」**——本方法只由「应用版本变更」路径调用」 | ✅ 代码印证设计 |
| `StateStore.swift:101` / `ResidueStateFile.swift:11` / `Metrics.swift:158,199` | 三处均写「一键清除**不作用于**它」 | ✅ 四处口径统一，没有一处走样 |
| `Pages.swift:268-270` | 一键清除按钮 **action 为空**（`// 骨架阶段：动作由后续接 StateStore / RecordWriter`） | ⚠️ **文档没写这一条** |

**这里有两个必须补进执行单的点**：

1. **"挂一键清除不可达"的真实原因比执行单写的更彻底**。执行单给的理由是「M4 不允许清 `a`，所以按设计必然失败」——**对的，但不是唯一理由，而且不是今天最大的理由**。今天最大的理由是：**那个按钮的 action 是空的，它连"清记录"都没实现**。也就是说，即使有人不顾 M4 硬把判据挂上去，结果也不是"清掉了 `a`"（那至少说明它在工作），而是**点击后什么都没发生**。理由要写成两条：① 设计不允许 ② 实现不存在。只写①，会让人以为"等功能接好了就能用一键清除做首演"。

2. **S9b 的判据在当前产物上是恒真的，签字等于零信息。** S9b 判据是「重装后为初始态、`scan.jsonl` 从 0 行重新开始」。而实测首启不落盘、`~/Library/Application Support/Residue` 不存在 → `scan.jsonl` 从来没有过 → 「从 0 行重新开始」**必然成立**，不管卸载干不干净。执行单 §3 已经诚实标了「判据不可达（C16）」，但 §9 把它归进「⚠ 半可执行」——**恒真判据不是"半可执行"，是"零判别力"**，必须等数据层接线后重跑，否则这一栏的"通过"是假的。

---

## 三、回滚演练两支（§10.2）—— 判据文本可判，但在当前产物上 **0 条可执行**

我按要求逐条判"可判性"，判法：这条判据**今天能不能真的做出真/假**。

**先判共同前置（两支共用的演练序列）**：

```
干净机 → 装旧版(0.1.0) → 产生数据（跑一次扫描，制造 a / countedDays / 轮次）→ ...
```

**第 3 步「产生数据」不可执行**，两个独立原因：
- 首发**没有上一版归档**（执行单 §6 总前提已写「首发不适用」，但没说清"因此两支今天都不可判"）；
- **产品不落盘、不产生 `a`/`countedDays`/`轮次`**（本节第二节实测）。

→ **两支的共用前置断了，下面的逐条判定都建立在一个不可执行的前置上。** 这个事实必须先写进 §6，否则会有人照着跑，然后在第 3 步卡住，再被人解释成"演练做不了"——**这正是执行单 §6 末段自己批评过的那个病**（"v1.2 只写只读提示可见，在未跳 schema 的版本上永远不可达，照那一条演练支 B 会永远不通过，然后被人解释成演练做不了"）。

**支 A（本版变更了 `schemaVersion`）7 条判据**：

| 判据 | 文本可判? | 今天可执行? | 我的判定 |
|---|---|---|---|
| 数据无损（`state.residue` SHA-256 前后一致） | ✅ | ❌ | 文件不存在，`shasum` 直接报错。**不是"不一致"，是"无从算起"** |
| 只读提示可见 | ✅ | ❌ | 依赖能产生数据的旧版 |
| `a` 不被改写（显示「—（由更高版本维护）」） | ✅ | ❌ | 界面无真实 `a` 读数（App 层 0 处 `Metrics`），**这条判据没有可观测对象** |
| 不写落盘物（mtime 不变 / 无写句柄） | ✅ | ❌ | **今天恒真**：没有任何代码会写，所以"不写"必然成立，零判别力 |
| ⑤ 页措辞「只读，不结算」≠「本轮未结算」 | ✅ | ⚠️ | 文案在 `SemanticSlot` 里有（`SemanticSlot.swift:252-257`），**这条今天反而能判**——是两支里唯一能跑的 |
| 恢复可写（重装 0.2.0） | ❌ **不可判** | ❌ | 原文只写「数据仍是升级后的数据」，**没给比对基准**。什么叫"仍是"？必须写成「重装 0.2.0 后 `state.residue` 的 SHA-256 与"升级后、回滚前"记录的值逐字节一致」才可判 |
| 禁止项（无「重置本地状态」入口 / 无外部下载地址） | ✅ | ⚠️ | 可 grep 源码判，今天能判 |

**支 B（未变更 `schemaVersion`）5 条判据**：

| 判据 | 文本可判? | 今天可执行? | 我的判定 |
|---|---|---|---|
| 数据无损 | ✅ | ❌ | 同支 A |
| 旧版直接正常加载、不进只读 | ✅ | ❌ | 前置不可达 |
| 重装后状态一致（`a` / 轮次 / 计数日 三项一致） | ✅ | ❌ | **三项读数界面上都没有** → 无可观测对象 |
| 反例守卫（出现只读提示即判失败） | ✅ | ❌ | 前置不可达 |
| 功能可用（回滚后跑一次扫描能出报告） | ✅ | ❌ | 扫描能力未接线 |

**我给出的判定**：**两支共 12 条判据，今天可执行的 2 条（支 A 的 ⑤ 页措辞、禁止项 grep）、恒真 1 条（不写落盘物）、不可判 1 条（"数据仍是升级后的数据"缺基准）、其余 8 条前置不可达。**

**修法（给到可直接改的粒度）**：
1. §6 总前提补一句硬前置：「**回滚演练的前置 = ① 有上一版归档 ② 数据层已接线并能产生 `a`/`countedDays`/轮次 ③ 界面读数已接真实 `Metrics`。三者缺一，两支均为「不可判」，不是「通过」也不是「失败」。**」
2. 支 A「恢复可写」的判据改成可对账的形式（写上 SHA-256 基准值来源）。
3. 支 A「不写落盘物」加反向锚：**必须同时验证「回滚前该文件存在」，否则"mtime 不变"在文件不存在时恒真**——这跟 `TC-025` 的 `filesScanned ≥ 1`、`TC-087` 的 `upstreamCommands ≥ 1` 是同一个病，我在冒烟集评审里已经抓过一次，这是第三次出现同一形态。

---

## 四、已知硬缺口逐条判「是否发布阻塞」

> 判法（这是我的铁律）：**「没实现」不是「未覆盖」。功能不存在 = 不能发；功能存在但没验过 = 可以带观测项发。**

| # | 缺口 | 是发布阻塞? | 我的理由 |
|---|---|---|---|
| 1 | **`SMAppService` 源码 0 处（登录项未实现）** | ✅ **是** | 功能**不存在**。用户重启后产品不在，且界面上没有任何"我还在"的证据。这是**产品级缺失**，不是环境所限。执行单 §8 C3 已把它从"未覆盖"纠正为"未实现"——**这个纠正是这份文档最有价值的一处，我完全同意**，并再加一句：它还连带否掉了 S7 的第 12 项判据 |
| 2 | **`spawn` 定时任务未实现** | ✅ **是** | 功能**不存在**，且它是**核心能力的执行机构**：没有它，「14 天观察期」「达标后自动删除」全是空承诺。更直接的影响：**冒烟集主链 `SM-01` 的前置就是"构造定时执行点"，今天第一条冒烟就跑不了**（我在冒烟集评审 B5/S8 已登记） |
| 3 | **无 Developer ID 身份（0 identities）** | ✅ **是** | 用户**装不上**（`spctl` 已判 `rejected`）。可以靠"让用户右键打开"绕过，但那是**把安装成本转移给用户**，且首发就这么干等于承认自己没签。不绕 |
| 4 | **无干净机（宿主 macOS 27.0.1）** | ❌ **不是产品缺陷类阻塞；但构成「准入签字」阻塞** | 这条要分清两件事：**"我们没测 14.x/15.x"≠"14.x 上一定坏"**。我不能因为没测就判产品有缺陷（那是把未覆盖当缺陷，跟"把没实现当未覆盖"是同一个错的镜像）。但它确实让 `§10.1 第 7 条` 无法签字，而该条是强制步骤 → **A-10 不能签"通过"**。区别在于：缺口 1–3 是"产品要改"，缺口 4 是"我们要备一台机器"。前者不能发，后者是"发之前必须有证据" |
| 5 | **`.app` 只有 arm64** | ❌ **不是**（有前置条件） | 唯一的关闭条件是 **Release 说明 + README + 产品页三处明确写「仅支持 Apple Silicon（arm64）」**。写了就不是阻塞；**不写就是阻塞**——因为 Intel 用户得到的错是「此应用无法在你的 Mac 上运行」，而**这个错不会在公证环节暴露**，发布方看不到任何红灯（执行单 C10 说得对）。这类"静默差评来源"我最不能接受 |

**我另外加的、执行单没列进 §9 的一条阻塞**：

| # | 缺口 | 是发布阻塞? | 理由 |
|---|---|---|---|
| 6 | **数据层未接线（`ResidueCore` 未被 App 层实例化，0 处）** | ✅ **是** | 这是缺口 1–2 的**上游**：不是"某个功能没做"，是"所有功能都没有调用入口"。执行单把它记在 §8 C16「观察」级，我认为**定级错了**——C16 写的是"首启不落盘 → S9b 判据不可达"，看起来像测试问题；实际是"产品不工作"。**一个被记为「观察」的事实，实际是最重的那一条**。这是我对这份文档唯一一处实质性反对 |

---

## 五、上线前检查单（按我的标准过一遍，逐项给真实状态）

> 结论是不可发，所以这张表不是"发之前要勾的清单"，而是**"为什么现在勾不了"的证据表**。

| 检查项 | 要求 | 状态 |
|---|---|---|
| 配置已提交 | 发布配置在版本管理里，无手工改机 | ✅ 满足（`make_app.sh` / `Info.plist.in` / `entitlements.plist` 均在仓） |
| 迁移脚本已备份 | 数据变更 100% 有备份点与回滚验证 | ⛔ **本版无数据变更**（首发），但 `state.residue` 的 `.bak` 语义已在 `StateFile.swift:189-193` 实现 ✅；**回滚演练未做**（§三：0 条可执行） |
| 监控已就绪 | 至少三个可判好坏的指标 | ⛔ **不存在**：App 层 0 处 `Metrics`，无任何运行期指标出口。零外发的产品没有远端监控是**设计选择**（正确），但**本地指标必须能在界面上读出来**——现在界面读数是 `SemanticSlot` 占位值 |
| 告警已配置 | 阈值而非"关注一下" | ⛔ **不适用（无远端）/ 未建（本地）**：见下方"观察指标"三条 |
| 回滚脚本已验证 | 回滚路径预先验证过（含数据兼容） | ⛔ **未验证**：上一版归档不存在，两支演练 0 条可执行 |
| 值班已排 | 具体人 + 响应时限，不写"相关同学" | ⛔ **不出**（无发布则无值班；出了就是给一个不存在的发布排班） |
| 安全类 P0 已清零 | 未清零不发，不受"紧急修复"例外 | ⚠️ **无法判定**：`R2-安全合规检查表 v1.0` 已有，但**没有任何一条经过实现验证**（产品没有运行路径）。这一项今天的状态是"未知"，不是"清零" |
| 无明文密钥/凭据进配置 | 敏感值走注入不进代码 | ✅ 满足（`grep` 未见密钥；公证凭据走 `notarytool store-credentials`，正确） |
| 敏感配置走注入而非代码 | 测试注入点不得进发布版 | ✅ `RESIDUE_TEST_` = 0（我实测）——**但如前述，这个 0 是构造决定的，证据价值低** |
| **门禁：装机可执行** | 用户双击能装上 | ⛔ **不满足**：`spctl` rejected |
| **门禁：主能力可用** | 至少一条主旅程端到端可跑 | ⛔ **不满足**：无数据层，0 条主旅程可跑 |

---

## 六、观察指标（重开闸门前必须先建好这三个，否则下次评审我还是签不了）

> 按我的规矩只看三个。现在**一个都不存在**，所以我出的是"要有哪三个"，不是"阈值多少"。

| 指标 | 基线 | 告警阈值（建议） | 判断动作 |
|---|---|---|---|
| **首扫成功率**（首启后 60 s 内 `scan.jsonl` 新增 ≥ 1 行 / 首启次数） | 无（未接线） | < 95% | 低于阈值即回滚：安装面问题优先于功能问题 |
| **`rename_to_trash` 计数 vs 候选集大小**（每次执行后） | 无 | 执行数 > 候选数 **或** 执行数 = 0 而候选 > 0 | 前者 = 删了不该删的（立即停机，这是资损）；后者 = 该删没删（能力不可用） |
| **`contentReads` / `upstreamCommands` 两个"必须非恒真"的诊断字段落盘率** | 无 | 任一条缺失率 > 0% | 缺失即视为"无法证明"，按不通过处理——**这两个字段是整套验收的地基，它们恒真则全部 AC 作废** |

> 第三条是专门为这个项目挑的：`RG-08` / `RG-09` 两条回归都是"判据无载体 → 恒真"，说明这个坑已经踩过两次。**上线后第一个要盯的不是功能，是这两个字段还在不在。**

---

## 七、回滚方案（今天只能给"条件"，给不了"步骤"）

因为**没有可回滚的上一版**，以下按"什么时候才能有回滚方案"写，而不是假装有：

| 触发条件 | 回滚步骤 | 预计耗时 | 数据兼容性 | 验证方式 |
|---|---|---|---|---|
| 首发即不可用（装不上 / 首启崩） | 撤下 Release 资产 → 发公告 | ≤ 10 min | 无数据产生，无需兼容处理 | `curl` 资产 URL 返回 404 + Release 页显示撤回 |
| 次版起：首扫成功率 < 95% | 退出 → 删 `/Applications/Residue.app` → 装回 `releases/<上一版>/Residue.app.zip` | ≤ 10 min（含下载） | **必须先知道上一版与新版是否跳 `schemaVersion`**（决定进不进只读态） | 装回后 `state.residue` SHA-256 与升级前记录值一致 |
| 次版起：`rename_to_trash` 计数异常 | **立即关自动删除开关**（止损优先），再回滚 | ≤ 5 min（关开关本身 ≤ 30 s） | 同上 | 执行日志 `rename_to_trash` 停止新增 |

> **顺序不能反**：任何"删错"类异常，**第一步是关开关，不是回滚**。回滚要下载 + 安装（10 min），关开关是 30 s。事故里 10 分钟和 30 秒的差别就是多删多少东西的差别。
> **"回滚是降级、不是等价替代"这句必须写进 README 的「已知限制」**（R2 §10.2 原文要求）。执行单 §6 已引用，我确认这条必须落地——不然用户以为退回旧版就一切照旧，实际是**只读、不能清理**。

---

## 八、值班与升级路径

**本版不出值班表。** 理由：没有发布就没有需要值班的对象，出一张表等于伪造一个"我们准备好接住了"的印象。

真要说的话，只有一条：**如果有人在流程压力下决定"带缺陷发"，那必须同时满足「发布窗口有人在线 4 小时」+「回滚包已就位」+「开关能关掉那个功能」。今天这三条一条都不成立——连开关都没有（`Scheduler` 0 处，没有可关的任务）。**

---

## 九、我对这份执行单的总体评价（先说好的，再说要改的）

**做得好的三处（我认可，不需要改）**：
1. **§5 的 D1–D7 把 `§10.1` 自身的 7 处不可执行点挖出来了**，尤其 D4「登录项的阻塞原因不是缺身份是缺功能，而 §10.1 完全没标这个依赖」——这句话救了一次误判。
2. **§8 C3 把"未覆盖"纠正为"未实现"**。这正是我在这一轮里被要求守住的那条线，文档自己先守住了。
3. **§3 S10 主动写了"扫不到是必然，不是扫过了没问题"** ——没有把恒真判据冒充证据，这在这类文档里很少见。

**必须改的三处（按危害排序）**：
1. **§9 的阻塞登记已过时**：B2（C1 `--timestamp=none`）和 B4（C2 无 ScrollView）**都已修**——我实测 `make_app.sh:112-121` 真身份分支已是 `--timestamp` 且 `:182` 有断言；`Pages.swift:97` / `:554` 已是 `ScrollView { ... }` 且带 `renderMode` 开关。执行单 mtime 17:44 早于代码 mtime 18:02。**照 §9 排期会让人重做两件已完成的活。**
2. **`Pages.swift:10-11` 的头部注释与代码矛盾**：注释还写着「本版**不使用 `ScrollView`**」，而 92–97 行就是 `ScrollView`。**我一开始就被它误导了**（按注释判 C2 仍是阻塞，看了代码才发现已修）。这种注释比没有注释危险，建议改成「历史记录：曾因 `ImageRenderer` 删过 `ScrollView`，现改为环境开关」。
3. **§8 C16 的定级错了**：把"数据层未接线（首启不落盘）"记为**「观察」级**，实际它是**最重的阻塞**。建议升为 **C0 / 阻塞**，并在 §9 加一行 B0。**理由**：一份文档里最重的事实被标成最轻的等级，读的人会按等级排优先级，然后去修 C1（已修）而不是修 C0。

---

## 十、重开闸门的条件（我下次签"可发"需要看到什么）

按顺序，前三条不清，后面不用看：

1. **数据层接线**：App 层出现 `StateStore(` / `RecordWriter(` 的真实实例化，首启后 `~/Library/Application Support/Residue/state.residue` 与 `records/scan.jsonl` 真实生成。
2. **登录项 + 定时任务实现**：`SMAppService` ≥ 1 处、调度器 ≥ 1 处，且**手动能触发一次执行**（否则冒烟集主链仍然跑不了）。
3. **身份到位**：`security find-identity -v -p codesigning` = 1，`spctl --assess` = `accepted`（`source=Notarized Developer ID`）。
4. 干净机 macOS 14.x + 15.x 各一台，S7a 逐条留档。
5. 冒烟集按 R3.5 第 3 轮修完（砍 2 加 2、换 2 条、补锚），且**能真的在 15 分钟内跑完**。
6. 回滚演练两支在**有上一版归档**的前提下各跑一遍（首发跳过一次，次版起强制）。
7. Release 说明 + README 写明「仅支持 Apple Silicon（arm64）」。

**这 7 条全绿之后，我才会出《发布方案》那张表（发布方式 / 灰度节奏 / 观察时长 / 变更窗口 / 负责人）。今天出那张表是自欺。**

---

## 十一、口径声明

1. **我不做"有条件通过"**。这份文档里我只能写两个词：可发 / 不可发。今天写的是**不可发**。
2. **我不把"没实现"算成"未覆盖"**。登录项、定时任务、数据层接线三条我今天全判阻塞，理由都是"不存在"，不是"没验"。
3. **我也不把"未覆盖"算成"有缺陷"**。无干净机我判"不构成产品缺陷类阻塞，但构成准入签字阻塞"——这个区分很重要，否则我会用"没测"去否掉一个可能没问题的产品，那和用"没实现"去骗过闸门是同一种错。
4. **我复核的是比我手上文档更新的代码**。凡是与执行单结论冲突处，我都给了命令与行号，不复述别人的判断。

