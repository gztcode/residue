## 评审单 R2 · macOS 客户端（第 3 轮 · 闭环核验）

- 结论：**不通过**
- 评审对象：`Residue-R2-技术方案-v1.2.md`（正文自述 v1.2，但文件第 1 行标题仍写「v1.1」——非阻塞，仅提醒下轮别按标题归档）
- 评审人：申必过（客户端）
- 上轮单子：`Residue-R2-评审单-客户端-第2轮.md`（阻塞 1 / 建议 10）
- 本轮口径：B1 只判闭环；新问题只收「由 v1.2 这四处改动**新引入**」的，每行必须能指到具体那一处
- 取证：本机 macOS 27.0.1（26A434）/ arm64 / APFS 实跑，命令与输出见文末「附 · 本轮实测」

---

## B1 闭环核验

| 上轮问题 | v1.2 落点 | 闭环? | 依据 |
|---|---|---|---|
| **B1** §7.3「每日全量」与「每 7 天全量」并存、快照未绑定 `full` → 若取 7 天分支则 `T` 由部分候选集确定、**系统性偏小且静默**（AC-20 只比同一次扫描，查不出）→ 门槛朝「更易点亮」松 | §7.3 末两段（第 5 段「快照必须由 `full` 取」+ 第 6 段「与 M1 的边界」） | **已闭环** | 修的是机制不是措辞：M3「`T` 只来自本轮首次成功扫描」被显式绑定到 `mode == full`——「开轮后第一次扫描强制 `full`」，且此前若发生 `incremental` **不取快照、`T` 待重取**。于是「没有 `full` 就没有 `T`」成了同一句话，7 天分支再也不能偷偷定义 `T`；同时明确 `incremental` 仍 +1 计数日、不改 M1 口径。上轮的攻击面（`T` 偏小且静默）消失 |

**残留（不计阻塞、不重开 B1）**：§7.3 第 2 段仍保留「或每 7 天全量（N3 建议值）」，新候选进 `F` 的最早时点仍随之后移 → `a` 的观测窗口可能被截短 1–6 天。该影响已由 §12.3-3「增量不发现深层新候选」登记为能力边界，且不再污染 `T` 口径，故不属于本轮「未闭环」；建议随 R3 用例补一句实测值即可。

---

## 由 v1.2 改动新引入的问题（3 条，均为阻塞）

| # | 位置 | 由哪处改动引起 | 真机上会发生什么 | 修法 |
|---|---|---|---|---|
| **1** | §10.1 第 6 条 × 第 7 条② | **第 7 条（v1.2 新增）**要求「干净机 + **先断网** + 保留 `com.apple.quarantine` + 从 `.dmg` 拖入 `/Applications`」；而第 6 条（v1.1）的分发物 `.dmg` 从来没进过 `notarytool`，也没 `stapler staple`——v1.1 只 staple 了 `.app`。新判据把这条空白变成了硬失败 | 干净机断网、双击带 quarantine 的 `.dmg` 时，Gatekeeper 评估的对象是**磁盘映像本体**（`-t open --context context:primary-signature`），`hdiutil` 产出的 dmg 无签名、无内嵌票据 → `rejected / source=no usable signature`（本机同构实测 exit=3），`stapler validate` 直说 `does not have a ticket stapled`。断网时没有「联网回查」这条兜底 → 用户在**挂载这一步**就被拦（「无法打开，因为 Apple 无法检查其是否包含恶意软件」）。`.app` 已 staple **替代不了** dmg 本体的评估 → 第 7 条五步断在第 ② 步，判据不可达。（离线校验本身没问题：票据内嵌即本地判，本机多个已 staple 的第三方 app `stapler validate` 全部本地通过） | 第 6 条产物定型后对 `.dmg` 再走一遍：`notarytool submit Residue.dmg --wait` → `stapler staple Residue.dmg` → `stapler validate Residue.dmg`，并把 dmg 纳入第 8 条的 SHA-256 对象；若不想加机器，则第 6/7 条统一改为分发「已 staple 的 `.app` 的 zip」，第 7 条②相应改「解压 zip 到 `/Applications`」 |
| **2** | §7.3 末段（「`T` 保持『待重取』」）× §5.1 `headerJSON` | **第 5 段（v1.2 新增）**造出了 `T` 的第三种状态「待重取」；而 §5.1 的可空性只给了 `K`/`J`（`null`），`T` 写的是 `"T": 0`——新状态在状态文件里**没有表示** | 实现只有两条路，都错：① 按 schema 写 0 → `H = min(30, T) = 0` → 观察期门槛恒满足，判定在「开轮后第一次 `full` 之前」就能达标；界面上 `T` 显示 0 天是**假值**，正是 §10.2 第一条禁的那类。② 按语义写 `null` → `T` 非可空、解码失败 → `E-302`，把用户推到「重置本地状态」那个二次确认框。且该分支不罕见：`E-101`（来源不可读）/`E-102`（卷只读）/连续 `E-103` 都会让 `full` 迟迟不成立，一个 14 天轮次可能全程停在「待重取」 | §5.1 把 `T`/`K`/`J` 统一为可空（`"T": null`）；§7.3 补一句：`T == nil` 时该来源按 P4「无法判定」——**不点亮、不进删除候选、不推进判定**；`H` 只在 `T != nil` 时计算；界面按「—（待重取）」渲染，不得渲染 0 |
| **3** | §10.1 第 9 条 + §10.2 第 4 条（回滚演练） | **两条都是 v1.2 新增的准入判据**，且互为前提，但都没写清「第一个版本」与「未跳 schema 的版本」怎么过 | ① **首发互锁**：1.0.0 不存在「上一版」→ 第 9 条「无上一版归档则不许发布」直接拒绝发布；§10.2 演练还要求「用上一版归档包…装旧版→升级」，同样无物可用。两条判据在第一个包上互为前提，产品出不了第一个版本。② **非跳版发布判据不可达**：`schemaVersion` 未 +1 的发布（§10.3 规定只在确有不合规变更时才迁移）回滚后，旧版遇到同版本 schema 走「相同 → 直接加载」，**根本不会进只读** → 演练判据第 3 条「只读提示可见」不可达，演练要么卡死要么被写成假通过 | 第 9 条加一句「首版以本次包自身为基线，第 9 条与 §10.2 第 4 条自 1.0.1 起生效」；§10.2 第 4 条补「演练用的『更高版本数据』由 `state.residue` 的 `schemaVersion + 1` 副本构造（或临时构建一个跳版包），**不依赖本次发布是否跳版**」 |

---

## 四处改动的 macOS 可执行性（逐处一句话）

| 改动处 | 可执行? | 判据 |
|---|---|---|
| §7.3 末两段（快照强制 `full`） | **机制可执行**，但缺状态表示 | 纯调度器闸门（「本轮未取快照 → `incremental` 不写 `T`」），无任何 macOS API 依赖，落地成本为几个分支；卡住的是「待重取」在 §5.1 里写不出来（见阻塞 2） |
| §10.1 第 7–9 步（装机检查 / SHA-256 / 归档） | **8、9 可执行；7 不可执行** | 第 8 条 `shasum -a 256` 两次比对、第 9 条留档，都是纯操作；第 7 条的「断网 + `.dmg`」死在未公证的 dmg 本体（见阻塞 1）。附两条执行前提（非阻塞）：④「触发一次定时任务」需在检查单里写死「安装后 5 分钟」的定时点，否则要等满一天；步骤顺序应为 8→9→7，按字面 7 在 8 前会「断网→再联网→再断网」反复切网 |
| §10.2 只读四条（含「未演练不许发布」） | **前三条可执行；第四条不可执行** | 只读模式本身就是「不写」，未知字段渲染「—（由更高版本维护）」是纯展示层判定，`headerJSON` 可读、段表按 `(sourceIndex, kind)` 跳过未知段即可；第四条的两类发布上前提不成立（见阻塞 3）。补充：判据②「`a` 在原版本内不变」不是恒真——它能抓出「只读模式偷偷写了」，这条留着 |
| §10.3 `migrating.json` + 预检 `3× + 64MB` | **可执行** | 算术自洽：336 MB 状态 → 需 ≥ 1072 MB，峰值 = 原件 336 + `.bak` 336 + 新件 336 = 1008 MB，留 64 MB 余量成立；`statfs` 取值在 APFS 上偏保守（本机三口径 170.6 / 180.4 / 158.3 GB，`f_bavail` = availableCapacity，比 important-usage 低 ~5%，不会误放行），失败面还有 `E-303`/`E-305` 兜。两条非阻塞备注：① 64 MB 只覆盖「新件 ≤ 原件 +19%」，建议分子改 `max(原件, 预估新件)`；② `step` 值每步都要一次原子写，否则断电三态判定的 `step < 4` 判不准 |

---

## 附 · 本轮实测（macOS 27.0.1 / arm64 / APFS，可复跑）

| 编号 | 断言 | 命令 | 结果 |
|---|---|---|---|
| **F1** | 磁盘映像本体是被单独评估的对象，且未签名的 dmg 无票据 | `hdiutil create -srcfolder Residue.app -format UDZO Residue.dmg`（内含 `codesign -s - --options runtime` 的 `.app`，`flags=0x10002(adhoc,runtime)`）→ `xattr -w com.apple.quarantine "0083;…;Safari;"` → `spctl -a -vvv -t open --context context:primary-signature Residue.dmg` | `rejected` / **`source=no usable signature`**，exit=3 → `.app` 的签名状态不影响 dmg 本体的评估结论 |
| **F2** | 该 dmg 上没有任何可离线回查的票据 | `xcrun stapler validate Residue.dmg` | `Residue.dmg does not have a ticket stapled to it.` |
| **F3** | 票据内嵌即可本地判定，不需要联网 | 遍历 `/Applications/*.app` 跑 `stapler validate`；取首个通过者（`CC Switch.app`）跑 `spctl -a -vvv -t exec` | 多个第三方 app（CC Switch / ChatGPT / Clash Verge / DeepSeek Harness / HapiGo…）`stapler validate` 本地通过；`spctl` 判 `accepted` / `source=Notarized Developer ID` → 断网能验的**前提是包内已有票据**，`.app` 有、dmg 没有 |
| **F4** | APFS 三种可用空间口径的偏差 | `URLResourceValues` 的 `volumeAvailableCapacity` / `…ForImportantUsage` / `…ForOpportunisticUsage` 与 `statfs.f_bavail × bsize` | 170.6 GB / 180.4 GB / 158.3 GB；`statfs` 与 `availableCapacity` 相等 → 按 `statfs` 做 §10.3 预检偏保守，不是风险点 |

> 复跑料在 `/tmp/rz3`（`Residue.app` / `Residue.dmg` / `cap.swift`），可整段重放。
