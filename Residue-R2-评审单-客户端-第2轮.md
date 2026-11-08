## 评审单 R2 · macOS 客户端（第 2 轮）

- 评审对象：`Residue-R2-技术方案-v1.1.md`
- 评审人：申必过（客户端）
- 上轮单子：`Residue-R2-评审单-客户端.md`（B1–B9 阻塞 / S1–S4 建议）
- 结论：**不通过** · 阻塞 1 / 建议 10
- 本轮范围：只做两件事——(a) 逐条验 B1–B9 是否真闭环；(b) 只在 ADR-10 / ADR-03 同 uid / ADR-06 与 AC-14 偏差 / §7.3+§7.2 四处找新问题。不重开 PRD 判定规则，不评数据模型内部一致性。
- 取证：本机 macOS 26 / arm64 / APFS 实跑，新增取证见文末「附 · 本轮实测」，可复跑。

**前置核对**：§15「客户端评审 9 条」的 9 行处置逐行对回正文，**无「声称已改、正文没改」的行**（B1→ADR-10 实存、B2→ADR-03 失败判据实改、B3→ADR-06 重写、B4→理由段替换、B5→四态表存在、B6→全篇 `getdirentries64` 只剩 §5.5 一处措辞残留、B7→mtime 触发已删、B8→六步在、B9→§10.2 已改）。故本轮不再有「写了等于没写」的假闭环。

---

## B1–B9 闭环核验

| # | 上轮问题 | v1.1 落点 | 闭环? | 依据 |
|---|---|---|---|---|
| **B1** | 无 `.app` bundle → 登录项 / FDA 面板 / 公证三链开发期一条都跑不起来 | ADR-10（新增）、§11 映射、§15 | **已闭环** | 上轮死的不是「缺 Xcode」，是「缺 bundle 这个载体 + 把签名当发布环节」。ADR-10 把 bundle 单列成 ADR，给出产物树（`Contents/{MacOS, Info.plist, Resources, _CodeSignature}`）并写死「依赖 .app 身份的能力只在 .app 下验收」——三条链不再卡在第一步。剩余是 plist 具体键与签名动作，属一行级补写（建议 S5），不动结构。实测佐证：手工组装 bundle 加 `codesign --sign - --options runtime` 后 `_CodeSignature/` 自动生成、`flags=0x10002(adhoc,runtime)`（E2） |
| **B2** | `degraded` 恒 true（跨 uid 恒 EPERM）；`proc_pidinfo` 失败返回 0 而非 −1 | ADR-03、IF-03、§12.3-2、§15 | **已闭环** | 三件事同时落地：① 按 uid 预过滤；② 判据改成 `returned == 0 && errno == EPERM`（不再判 `r < 0`）；③ 跨 uid 只进 `coverage.statOtherUID`、**不计 degraded**，且明写「跨 uid 恒 EPERM 与 FDA 无关」。按这三条实现，本机那 173 个非本 uid 进程不再污染判定，`degraded` 只剩「连自己 uid 都读不到」这一个真语义，M4 的「FDA 未授予」分支不会再对所有用户点火 |
| **B3** | 三条 canary 全部退化为常量 → `fullDiskAccess` 是常函数、产品永久只读 | ADR-06、IF-04、§12.1 #4、§15 | **已闭环** | 三条 canary 被整体删除，改 `{sourceRootReadable, sameUIDEnumeration, trashWritable}` 三个「能不能干活」的信号，并写死「不判断 FDA」。常函数消失、永久只读态消失。`~/.Trash` 仍是恒真探针，但它现在只是能力自检的正向占位而非授权代理，恒真无害；E-202 的真判据留在 rename 失败分支。残留：FDA 指引挂在 ① 上会误导（见建议 S11） |
| **B4** | 弃用 lsof 的理由①（O(候选数) 调用）判断反了，且被当首要理由 | ADR-03 弃用理由段、§9 S-07、§15 | **已闭环** | 理由换成「静默丢权 →『没有 fd』与『看不到』不可区分 → 失败不可归因」+ 文本解析串行 + PATH 面，并明写「**性能不作为理由**」。S-07 只剩「不 fork/exec」的正向约束，无错前提残留。R3 不会再按「lsof 太慢」设计用例 |
| **B5** | `status` 四态未映射；Translocation 下仍显示「已启用」 | ADR-02 四态表 + 代价②、§15 | **已闭环** | 上轮点名的三种「说错话」逐一有了着落：① `notRegistered` 文案改「未注册为登录项」（不再把「从未注册」归因成「用户关了」）；② `requiresApproval` 独立一档且标「不执行」；③ 启动校验 `Bundle.main.bundlePath` 兜 Translocation。补充一点让这条更稳：只要能看见界面，就说明进程此刻在跑，所以 `.enabled` + 在跑 不构成「假装」；「假装在跑」唯一真实形态是「登录项没生效而用户以为明天会扫」，已被路径校验 + 非 `.enabled` 三态覆盖 |
| **B6** | `getdirentries64` 在 arm64 `libSystem` 无符号，按字面实现编不过 | ADR-04 阶段 1、§15 | **已闭环** | 阶段 1 改 `readdir` + APFS `d_type`，`DT_UNKNOWN` 保留单条 `lstat` 兜底；全篇已无该符号的可执行语义。残留两处：`getattrlistbulk` 缺「首 4 字节 = 记录长度」的步进约束（上轮 S2① 未落地）、§5.5 还写着「`getdirentries64` 无稳定 offset」（措辞残留，结论仍成立）——都进建议 S6，不影响 B6 关闭 |
| **B7** | §7.3「目录 mtime 变化则重扫」在 uv/npm 上必触发 → 增量退化为全量 | §7.3、§12.3-3、§15 | **已闭环** | mtime 触发被整体删除，改「① 只对已登记候选批量重取属性 + ② 来源根/一级 dirent 计数粗差」，并如实登记「增量不发现深层新候选」。按此实现，增量不再遍历 `archive-v0` 子树：30 万候选 0.9 s + 根 10 万 dirent 3 s ≈ 4 s，对 N1「≤ 30 s」有 7× 余量，上轮「超 5–20×」的攻击面消失。它带来的**新**口径问题见阻塞 1，不属 B7 未闭合 |
| **B8** | 公证 5 处漏项，错法都是「公证过了但用户装不上」 | §10.1 六步、§15 | **已闭环** | 五条逐一在位：逐个 Mach-O 签 + 明写「不用 `--deep` 代替逐个签」、`get-task-allow` 必须 false、`ditto` 成 zip 再 `notarytool submit`（不再喂裸 `.app`）、`staple` 对 `.app` 而非 zip、`.zip` 不可 staple 且票据在 `.app` 内；顺序（签→zip→submit→staple .app→出包→双验）也是对的。`codesign --verify --deep` 只用于 verify，不违反上轮那条。残留：缺三条机器断言命令（建议 S9） |
| **B9** | `E-301` 在 D2′ 下是死胡同 + 拿唯一安全凭证当默认代价 | §10.2、ADR-07、IF-09、§15 | **已闭环** | 改成只读降级、明写「不写、不清、不迁移」「不提供降级迁移」「**不引导「重置本地状态」**」——破坏性入口不再与「升级」并列，上轮「让用户在不知情下自毁证据」的路径被切断；`E-301` 也降为提示、不作拒绝。残留：提示文案未带版本号、`E-302` 分支的「重置」仍无二次确认与损失明示（建议 S10） |

**小结：B1–B9 全部已闭环，无「部分」。** 上轮 9 条指的都是「按字面实现会撞墙或造错数据」，v1.1 每条都换了机制（不是换措辞），且换法与我给的修法方向一致。

---

## 四处新问题的判断

| 位置 | 判断 | 依据 |
|---|---|---|
| **ADR-10 · `make_app.sh` 手工组装 `.app`** | **方案成立，够用；但缺 3 个 plist 键 + 未写死签名动作 → 建议 S5，不阻塞** | 逐问回答见下 |
| **ADR-03 · 只枚举同 uid（`sudo` 起的 root 进程看不到）** | **可接受，不是新阻塞** | ① `sudo` 默认不继承 `HOME`（落到 `/var/root`）→ sudo 起的 `uv`/`npm` 缓存写在 **root 自己的域**，根本不在扫描根里，「看不到」与「不在范围内」同义；② 只有 `sudo -E` / `--preserve-env` / `sudo -H` 误用才会让 root 进程持有用户缓存中的文件，属少数路径（本机 `~/.cache` + `~/.npm` 深度 5 内 root-owned 文件 = **0**，E3）；③ 即便命中，删除走同卷 rename：目标由 root 拥有且目录不可写 → `EACCES`/`EPERM` → 记 `failed` 不误删；真正危险的窗口只剩「文件属用户 + 被 root 进程持有」，极窄；④ §12.3-2 已把「同 uid 之外不参与 L0」登记为能力边界。→ 只建议 S12 补一句具名场景 |
| **ADR-06 · FDA 降为「失败后指引」，与 AC-14 Given 的偏差** | **已登记为 §12.1 #4 并指向 CR-022；我认可「登记 + 不擅自改 AC」这个处理方式** | ① 位置对：ADR-06 正文、§12.1 #4、§15 B3 三处互相指得通，处置栏写明「需 CR-022」而非「已改口径」；② 程序对：PRD 冻结期改 AC 等于绕过变更单，#4 只登记冲突 + 给建议改法 + 标 PM 裁决，是唯一合规路径；③ 结论可测性没丢：AC-14 的 Then（P4「无法判定」+ 逐条归因 + 授权指引条目）在 v1.1 里仍可构造，`E-107`（上游能力）与 `E-501`（权限）分工也写清了，退化的是 Given 的构造方式、不是判定结论。仅建议 S11 把「Given①『FDA 被拒』同样失去区分度」补进 #4（现在只写了第三类），否则 R3 只能测第三类，AC-14 会退化成「过但没测」 |
| **§7.3 增量 + §7.2 全量 118 s 的组合** | **「每日 1 次全量」本身现实；但 §7.3 同时留了「每 7 天全量」分支且快照未绑定 full → 成立一条阻塞（阻塞 1）** | ① **每日全量的预算完全够**：118 s/天 = 单核 **0.14% 日均**（N2 给的是 3%），只受 N1 的 600 s 约束，5× 余量；真机代价是每天约 2 min 磁盘唤醒，电池场景由 `E-103` 兜。所以「每日 1 次全量现实吗」→ 现实，不需要改。② **但同一段里两句话不能同时实现**：「每日全量（N3 默认每日 1 次）」与「每 7 天全量（N3 建议值）」并列，V7 又留着待回填 → 实现方必须赌一个。③ **若赌「7 天 full」，`T` 偏小成立，且方向不安全**：快照日（第 14 计数日）最后一次全量可能在 6 天前 → `T` 只统计到旧候选集；`K+J=T` 仍自洽、AC-20 的三项一致性也不会报错（它比的是同一次扫描内的文件数/字节数/清单），偏差**静默**。更重的是 `a`：新候选进入 `F` 的第一天被推后 1–6 天，它在 14 个计数日里的**可观测天数被截短**，而 `a` 恰恰靠「进过 `F` + 当时仍被持有」来计错 → 观测越短、`a` 越少、门槛越松，与 S2「错 1 次永久不允许点亮」方向相反。④ 这不是措辞问题：它决定 `T` 与 `a` 两个唯一安全量的口径，且修法只要两句。 |

### ADR-10 逐问回答（对应上表第 1 行）

- **没有 Xcode 工程、手写 `Info.plist`，macOS 14+ 够不够？** 够。bundle 是目录约定，不是 Xcode 产物；`NSBundle` 只读 `Info.plist`。实测（E1/E2）：`mkdir` 出的 `t.app` + 手写 plist + 一个可执行，`NSBundle` 正确读到 id，`codesign` 正常签，`_CodeSignature/` 自动生成。**不需要 Xcode，也不需要 `.xcodeproj`。**
- **`SMAppService` 接受这种手工 bundle 吗？** 接受——它的门槛在「有没有有效 code signature + 路径是否稳定」，不在「谁把文件拷进 `Contents/`」。所以两件事必须是硬前置，ADR-10 现在只写了半件：① 必须真跑 `codesign`（未签名时 `codesign -dvv` 直接 `code object is not signed at all`，E1）；② 测登录项时 bundle 要放 `/Applications`，`build/Residue.app` 里注册出来很容易变成「已注册但不启动」——而这正是 B1 当初要消灭的症状。
- **缺 `PkgInfo` 会怎样？** 无影响。该文件自 10.8 起非必需；实测本机 `/Applications` 39 个应用里 **7 个没有 `PkgInfo`**（DaVinci Resolve、Clash Verge、DJI Studio 等）且正常工作（E4）。**不用为它加步骤。**
- **缺 `_CodeSignature`（即未签名）首次运行会怎样？** 分三层，差别很大：① **能启动**——本机构建不带 quarantine，Gatekeeper 不拦；② 但 `SMAppService.register()` 抛 `kSMErrorInvalidSignature`（B1 的原坑原地复活），`spctl -a` 直接 `rejected / source=no usable signature`（E1）；③ **TCC 授权按 cdhash 记**，重编一次 cdhash 就变 → FDA 授权不跨构建保留，AC-14 验收会在「刚授完权又归零」里打转。所以 `_CodeSignature/` 不是「多造一个目录」，它是 `codesign` 的产物——脚本里必须有一行 `codesign`，而不是 `mkdir`。
- **缺键的具体后果**：`CFBundleExecutable` 缺失时 `NSBundle` 会按 **bundle 目录名**兜底（实测 `b.app` → `Contents/MacOS/b`，E1），当前「`Residue.app` 里放 `Residue`」的命名恰好命中，所以现在能跑；一旦产物改名（比如以后加个 `Residue-arm64`）就静默变 `nil`。`CFBundlePackageType`（`APPL`）、`NSPrincipalClass`（`NSApplication`）同属「现在靠巧合、以后靠运气」的一类。→ S5。

---

## 阻塞项

| # | 位置 | 原文片段 | 真机上会发生什么 | 修法 |
|---|---|---|---|---|
| **1** | §7.3（连带 §12.3-3、§13 V7） | 「新候选由每日全量（N3 默认每日 1 次）或每 7 天全量（N3 建议值）发现。**后果**：新装的包可能要到下一次全量才进清单。」 | 若实现取「每 7 天全量」（同一段里合法的一支）：观察期第 14 个计数日取快照时，最后一次全量可能在 6 天前 → `T` 只覆盖旧候选集，**新装包全不在内**；`K + J = T` 因同源仍自洽，AC-20 的三项一致性（文件数/字节数/清单）比的是同一次扫描，**不会报错**，偏差全程静默。同时每个新候选进入 `F` 的第一天被推后 1–6 天，14 个计数日里可观测天数被截短 → `a`（唯一的安全凭证）少记 → 门槛在「更容易点亮」的方向被放宽。另：`§7.3` 没说「增量成功是否推进计数日」，若推进则等于「用不含新候选的扫描换取观察期进度」，同一条偏差会每天都在发生 | §7.3 写死三句，不加机制：① `countedDays` 达到上限（14）的那次扫描 `mode` 必须 = `full`，`T`/`K`/`J` 只从这次扫描产出；② 「每 7 天全量」降级为「每日全量不可达时（低电量 / 长时休眠 / 设备关机）的兜底」，并明确兜底之后**必须先补一次 full 才允许推进计数日**；③ §12.3-3 增一句「走兜底路径时 `a` 的观测窗口相应截短 1–6 天，属已登记偏差，需 PM 知悉」。不改 M3/M4 定义、不改 N3 |

---

## 建议项

| # | 位置 | 建议 | 是否超范围 |
|---|---|---|---|
| **S5** | ADR-10 | ① `Info.plist` 补 `CFBundleExecutable`（= 产物名）、`CFBundlePackageType = APPL`、`NSPrincipalClass = NSApplication`；② `make_app.sh` 末尾写死一行 `codesign --force --sign - --options runtime --timestamp=none build/Residue.app`（本地）/ Developer ID（release），并注明 `_CodeSignature/` 是它的产物、不是 `mkdir` 出来的；③ 注明「登录项 / TCC 验收须把 bundle 放到 `/Applications` 再跑」；④ `PkgInfo` 不必造 | 否（补键与一行命令） |
| **S6** | ADR-04 硬约束 + §5.5 | ① 补第 4 条解析约束：「**每条记录首 4 字节 = 本条长度**，按它步进，不定长步进」（上轮 S2① 未落地，这是三条里最容易在第二条记录起静默错位的一条）；② §5.5 断点理由里的 `getdirentries64` 改指 `readdir`（结论不变，只是去残留） | 否（实现约束） |
| **S7** | §7.2 | 「30 k 条/s 是冷缓存下限（warm 可达 60–80 k）」里的 60–80 k 与实测 warm 548–744 k 差约 10×。建议写「保守取值，非实测基线；实测 warm 见评审单」——否则下一个人会拿 60–80 k 做容量规划，把 118 s 算成 40 s | 否（只补标注） |
| **S8** | §7.1 / N2「内存增量 ≤ 80 MB」 | **上轮 S4 未处置**：口径仍未定。建议在 R3 用例里定死「开启采样前后的**同进程 RSS 增量**」+ 固定基线采样法，否则 AC-20 / S5 判「超标」时无法自证 | 否（只定测量口径） |
| **S9** | §10.1 | 六步之外补三条**机器断言**（现在是「要求」，不是「检查」）：`codesign -dvv` 输出含 `flags=0x10000`；`codesign -d --entitlements :- \| grep -c get-task-allow` 必须为 0；**断网**下 `spctl -a -vvv` 必须 accepted。另：出 `.dmg` 后可对 dmg 再 `stapler staple`（可选但便宜，保证 dmg 本体离线可验） | 否（同属 F8–F10） |
| **S10** | §10.2 / §6 `E-301`、`E-302` | ① `E-301` 文案带两个版本号（`headerJSON.appVersion` 已有，不用加字段）；② `E-302` 分支的「重置」仍是无保护入口——上轮 B9 只切掉了 `E-301` 那条，建议同一套标准：二次确认 + 明示损失（「将丢失 <N> 天观察期与全部 `a` 记录」） | 否（文案与确认框） |
| **S11** | ADR-06 / §12.1 #4 | ① FDA 指引只挂在「② 同 uid fd 枚举失败」；① `opendir(来源根)` 失败先按 `E-101`（路径变更/权限）处理——`~/.cache/uv` 不在 TCC 保护范围内，给 FDA 指引等于又请用户授一个改不了行为的最高权限（B3 的原病）；② §12.1 #4 补「Given①『FDA 被拒』同样失去区分度」，否则 AC-14 只剩第三类可测 | 否（指引挂载点 + 登记补句） |
| **S12** | ADR-03 / §12.3-2 | 能力边界补一句具名场景「含 `sudo -E` 启动的 root 开发进程」；`coverage.statOtherUID` 落进诊断快照（字段已有、不上界面），事后能归因「为什么这个包没被拦」 | 否（诊断用） |
| **S13** | §7.3 预算行 | 补 L0 快照 1.5 s（§7.2 已列此项）：0.9 + 3 + 1.5 ≈ **5.4 s**，仍 < 10 s / 30 s，但别让实现方以为 3.9 s 是全部——差的就是「是否被持有」这件事本身 | 否（预算对齐） |
| **S14** | §10.3 | 补发布纪律：「`schemaVersion` 只在确有不兼容变更时 +1」——无自动更新通道的产品承担不起频繁跳版（上轮 B9 的附带项，未落地） | 否（发布纪律） |

---

## 附 · 本轮实测取证（macOS 26 / arm64 / APFS，可复跑）

| 编号 | 断言 | 取证件 | 结果 |
|---|---|---|---|
| **E1** | 未签名手工 bundle 的行为；缺 `CFBundleExecutable` 时 `NSBundle` 如何解析 | `mkdir /tmp/{a,b}.app/Contents/MacOS` + 手写 `Info.plist`（`b` 只留 `CFBundleIdentifier`）+ `swift` 读 `Bundle.executableURL`；`codesign -dvv` / `spctl -a -vv` | 未签名 → `code object is not signed at all`、`spctl: rejected / source=no usable signature`。缺 `CFBundleExecutable` 时 `NSBundle` 按**目录名**兜底：`b.app` → `Contents/MacOS/b`（能解析）；`name=NIL`、`pkgType=NIL` |
| **E2** | 空 entitlements 不影响 hardened runtime；`_CodeSignature` 是 `codesign` 的产物 | `codesign --force --sign - --options runtime /tmp/t.app`（不传 `--entitlements`） | `Contents/` 下自动出现 `_CodeSignature`；`flags=0x10002(adhoc,runtime)`、`Signature=adhoc`。→ ADR-10「entitlements 首版为空」与 `runtime` 不冲突；`_CodeSignature` 不能靠 `mkdir` 造 |
| **E3** | `sudo` 场景是否普遍污染用户缓存 | `find ~/.cache ~/.npm -maxdepth 5 -user root` | **0 条**（支撑「同 uid 过滤可接受」） |
| **E4** | `PkgInfo` 是否必需 | 遍历 `/Applications/*.app` 检查 `Contents/PkgInfo` | 39 个应用中 **7 个缺** `PkgInfo`（DaVinci Resolve / Clash Verge / DJI Studio / Status Trio 等）且正常安装运行 → 非必需 |

> 附注：`ps` 在本会话被沙箱拒绝（`operation not permitted`），故「root 开发进程数量」一栏改用 E3 的 root-owned 文件计数替代；跨 uid / 同 uid 的 `proc_pidinfo` 数据沿用上一轮 `pcount2.c` 的实测（667 进程 / 173 非本 uid / 同 uid 493-493 成功），本轮结论不依赖新样本。
