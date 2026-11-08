# Residue · R2 技术方案 v1.1

> **输入基线**：`Residue-PRD-v5.3.md`（**冻结**，1268 行）。本方案**不改动**任何 AC 编号 / 页面 / 状态类 / 用户动作 / 指标定义。
> **基线冲突处理**：与冻结 PRD 冲突时**一律以 PRD 为准**，并把冲突登记进 §12，不静默改口径。
> **版本说明**：本文件即**最新版 v1.6**（**K2 交底后修订**）。v1.0 ~ v1.5 **归档留存**，改动全表见 §15 ~ §20。评审单中凡称「v1.0 ~ v1.5」的均指本文件的前序版本。
>
> **v1.6 修订说明（K2 交底裁定落地）**：本版只落**实现层事实修正**与**契约补写**，**不动已冻结的契约签名与验收口径**，故**不重开 R2 评审**：
> - **ADR-03 / IF-03**：文件身份由 `vnodeid` 改为 **`(vst_dev, vst_ino)`**（K2 实测：macOS 的 `struct vnode_info` **没有 `vnodeid` 字段**）；补 **`PROC_PIDLISTFDS` 返回值是字节数、每项 8 B、fd 号 = 数组下标** 的实现约束。**〔2026-11-08 · A-6 实现层实测更正〕v1.6 原写「每项 24 B」是错的**——24 B 是 `state.residue` **段表项**的尺寸，被误套到 fd 列表上；实测 `sizeof(struct proc_fdinfo)` = **8 B**（`int32 proc_fd` + `uint32 proc_fdtype`），按 24 B 解析会读进 **3 倍脏数据**。
> - **§5.5 断点水位**：由「名字**典序**最大值」改为「**已完成名字集合 + 三项摘要自证**」（K2 实测：APFS `readdir` 是**哈希序**，原方案漏 70% 候选）。
> - **IF-08**：**预检取值的唯一来源 = `t1` 预览值**（不是执行时刻实时值）；两种拦截的动作值与原因串值域封闭。
> - **新增 §9.5 测试注入点约定**（时钟 / 电量 / L2 / 来源枚举 / 候选），边界写死：只在测试构建生效、只影响可观测字段、不改判定逻辑、不落盘；§10.1 增第 10 条 Release 剥离检查。
> - **§6 `E-501`**：未达项文案由「未取得 Full Disk Access」改为「**无法枚举本用户进程**」（ADR-06 已不判 FDA，说「未取得 FDA」= 说了一件产品不知道的事）。
> - **§5.4 `diagnostics`** 增 **`contentReads`** 计数位（AC-07「内容读取数为 0」原本无载体 → 恒真）。
> - **ADR-02**：「无常驻」统一为**任务级**表述（与冻结 PRD 的 AC-10 进程级表述的冲突，改 R2 一侧；PRD 侧走 CR-022）。
> - **§13 V6 定稿**：「持有」判据 = `(dev, ino)` 命中同 uid 进程的 fd 集合，或候选（目录）是同 uid 进程 cwd 的祖先。
>
> **v1.1 修订说明**：R2 第 1 轮评审（数据存储 11 条 + 客户端 9 条，全部为阻塞）**全部采纳**。其中 **6 条是「按 v1.0 字面实现会直接撞墙或造出错误数据」**，不是措辞问题：`blobLayout` 段偏移不可解、段序随字典序漂移、位图段长按置位数而非槽数、`getdirentries64` 在 arm64 无符号、目录 `st_size` 当字节数、`proc_pidinfo` 失败返回 0 而非 −1。逐条处置见 §15。
>
> **v1.2 修订说明**：R2 第 2 轮（客户端复核 1 条 + 质量与安全首评 9 条 + 发布与运维首评 10 条 = **20 条阻塞**）**全部采纳**。其中三条最重：
> - **SRE**：「六步公证只能证明『包是干净的』，证明不了『装上能用、坏了能退、退了能交代、删了能复原』」→ 补**端到端装机检查 / SHA-256 对账 / 上一版归档 / 回滚演练 / 导出报告五段内容**。
> - **质量**：AC-19「直接删文件的上游命令次数 = 0」与 AC-17 TOCTOU **此前都没有可判载体**（前者恒真、后者只能靠撞竞态）→ 补 `scan.jsonl.upstreamCommands` 与「首检 = 扫描时 / 二检 = 执行前」的确定性构造步骤。
> - **质量**：`E-204` 原被错归「无权限」，而 §8 的「无权限」封闭为三类 OS 权限受阻 → 改归「错误」。
> 另登记两条**必须回流 PRD 的偏差**（#6 N7「一键清除」字面与已裁决口径的张力；#7 M4 未限定「持有」的进程范围），随 **CR-022** 一并提。第 2 轮 20 条的逐条处置见 §16。

---

## 0. 范围与明确不做

**覆盖**：进程模型 / 授权路径 / 模块分层 / 接口契约 / 数据模型 / 容量与延迟预算 / 错误码 / 并发与一致性 / 工程结构与打包 / 发布与回滚 / 可观测性。

| 不做 | 依据 |
|---|---|
| 服务端、账号体系、网络请求、遥测、崩溃上报、自动更新 | §6 交付形态 / N7 / N8 / D2′ / D4 |
| SQLite / 第三方依赖 / 包管理依赖 | ADR-09 |
| 系统扩展、LaunchDaemon、提权、EndpointSecurity | N5 / P3 / AC-14 |
| 规则版本退回（U1）、熔断回退（S4） | CR-009 收窄（AC-16 整条与 S4 本期不交付） |

---

## 1. 选型决策（ADR）

### ADR-01 · UI 框架：SwiftUI + 必要处 AppKit bridging

- **决策**：Swift 6 + SwiftUI，部署目标 **macOS 14.0**。第 ⑤ 页矩阵用 `Table` + 固定列宽；第 ② 页候选清单用分页数据源（IF-06，`limit ≤ 200`）。
- **替代**：全 AppKit（7 页 × 九态工作量翻倍）/ Catalyst（读不到 `~/.cache`）/ Electron（违反 N1/N2 与「单一原生形态」）。
- **代价**：SwiftUI `List` 在 > 5 万行掉帧 → **分页是渲染正确性要求**，不是优化。
- **约束**：§6 交付形态 / N6 / AC-01。

### ADR-02 · 进程模型：单 `.app` + `SMAppService.mainApp` 登录项 + 菜单栏常驻

- **决策**：**一个进程**（UI 与调度器同进程）；`SMAppService.mainApp` 注册登录项；关窗后驻留（`NSStatusItem` + `applicationShouldTerminateAfterLastWindowClosed = false`）；`Info.plist` **不设 `LSUIElement`**（需要主窗口，设了会失去 Dock 与常规激活行为）。不做 XPC 双进程。
- **替代**：`SMAppService.agent`（独立 helper + plist + 嵌套签名，且要经 XPC 传 375 KB 级位图，复杂度换不到收益）/ 无后台（违反 N3、AC-20）。
- **`status` 四态必须如实映射**（v1.0 只写了「已关闭」，会被评审判为不可实现）：

| `SMAppService.Status` | 界面文案（第 ③ 页既有语义位） | 定时任务 |
|---|---|---|
| `.enabled` | 「定时任务已启用」 | 正常 |
| `.requiresApproval` | 「**待你在系统设置中允许**（系统设置 → 通用 → 登录项）」 | **不执行** |
| `.notRegistered` | 「未注册为登录项」 | **不执行** |
| `.notFound` | 「登录项注册丢失，需重新安装」 | **不执行** |

- **「无常驻」的准确表述（K2 质量组指出与 AC-10 的进程级表述冲突）**：本产品的判据是**任务级**——「**无常驻采样任务在运行**」，**不是「无常驻进程」**（本产品是单进程 + 菜单栏常驻，进程本来就该在）。冻结 PRD 的 AC-10 进程级表述走 CR-022 一并改（**同一事实两处写，只能改一处：此处改 R2，PRD 留待 CR-022**）。
- **代价（如实登记）**：① 用户关掉登录项 → 定时任务不执行，界面必须显示上表的非 `.enabled` 文案，**不得假装在跑**；② `.enabled` 但 App Translocation（从 `.dmg` 直接运行未拖入「应用程序」）时，**迁移后路径变化可能导致「每日扫描 0 次仍显示已启用」** → 启动时校验 `Bundle.main.bundlePath` 是否为 `/Applications/Residue.app`，否则在第 ① 页提示「请先拖入「应用程序」」；③ 单进程崩溃 = 调度器与 UI 同死，靠 §8.4 journal 兜底。
- **约束**：N3 / N4 / AC-20 / §6（不装 LaunchDaemon、不提权）。

### ADR-03 · L0 活引用判定：`libproc` 直接枚举 fd，**不 spawn `lsof`**

- **决策**：`sysctl(KERN_PROC_ALL)` 取进程表 → **只处理同 uid 进程** → `proc_pidinfo(PROC_PIDLISTFDS)` 取 fd 列表 → `proc_pidfdinfo(PROC_PIDFDVNODEPATHINFO)` 取 vnode 信息 → 建 **`(设备号 vst_dev, inode vst_ino) → [pid]`** 倒排；再取 `PROC_PIDVNODEPATHINFO` 的 cwd 路径集合。判定「持有」= 候选的 `(dev, ino)` 命中倒排，**或**候选（目录）是某进程 cwd 的祖先。
  - **⚠ 文件身份 = `(vst_dev, vst_ino)`，不是 `vnodeid`**（K2 实测更正）：macOS SDK 的 `struct vnode_info` **只有 `vi_stat / vi_type / vi_fsid`，没有 `vnodeid` 字段**。R2 v1.5 写的「取 `vnodeid`」在字面实现下拿不到。**产品自建 `UInt64` 键**（`(dev << 32) | ino` 或等价无冲突编码）做倒排。
  - **⚠ `PROC_PIDLISTFDS` 的返回值是**字节数**，不是元素数**：实测每项 **8 B**（`struct proc_fdinfo` = `int32 proc_fd` + `uint32 proc_fdtype`）、**fd 号 = 数组下标**。**〔2026-11-08 · A-6 实现层实测更正〕v1.6 原写「每项 24 B」是错的**——24 B 是 `state.residue` **段表项**的尺寸（§5.1），被误套到 fd 列表上；**按 24 B 解析会读进 3 倍脏数据** → fd 号全是垃圾 → **L0 恒判「无活引用」→ 误删正在被使用的文件**。实测（`returned=64` → 8 项）与 `fcntl` 实测 fd 集合 `{0..7}` **逐一对应**，fd 号即下标。**该约束必须写死**，否则第二个实现者还会踩。
  - **⚠⚠ `PROC_PIDFDVNODEPATHINFO` 的返回结构是 `vnode_fdinfowithpath`，不是 `vnode_info_path`**（**2026-11-08 · A-6 实测新发现**）：`struct vnode_fdinfowithpath` = `proc_fileinfo pfi`（**24 B**）+ `vnode_info_path pvip` → **`pvip` 起始于偏移 24**（实测 `dev`@24、`ino`@32）。**若误按 `vnode_info_path` 解析，会把 24 字节头当成 `vi_stat` 开头 → 读出 `dev=1, ino=0` 的垃圾值 → 与 `stat()` 的身份永远对不上 → L0 恒判「无活引用」→ 误删活文件**。实测 `sizeof(vnode_fdinfowithpath)` = **1200** = `proc_pidfdinfo` 的返回值；用该结构体解析出的路径与 `fstat` 的 dev/ino **完全一致**。
  - **⚠ `proc_pidfdinfo` 的缓冲区必须 ≥ `PROC_PIDFDVNODEPATHINFO_SIZE`（1200 B）**：实测传 1024 B → `returned=0` 且 `errno=ENOMEM(12)`（**失败**）；传 4096 B → 成功。**传 `sizeof(vnode_info_path)`（1176）会失败**——这是「结构体选错」与「缓冲区不够」两个坑叠在一起的情形。
  - **⚠ 文件身份不做单键编码**：R2 IF-03 原写「`(dev << 32) | ino` 编码成 `UInt64`」——但 `vst_ino` 是 **`uint64`**、`vst_dev` 是 `uint32`，**塞不进 64 bit 会截断 `ino` 高位** → 不同文件可能撞成同一身份 → 倒排表误命中。**实现改为保留二元组**（`FileIdentity`，`Hashable`）。
- **失败判据（v1.0 写错，这条会造成「把看不到当成没有」）**：`proc_pidinfo` / `proc_pidfdinfo` **失败时返回 `0`**（不是 `−1`），且 `errno` 才有意义。**判定必须写 `returned == 0 && errno == EPERM`**，只判 `r < 0` 会**永不降级** → 违反 N5 末句「不把未知判为安全」。
- **`degraded` 的准确含义（v1.0 会恒为 true，导致永远不可点亮）**：
  - **跨 uid 进程恒 `EPERM` 是 APFS/TCC 的正常行为，`FDA` 也不解锁**（实测：173 个非本 uid 进程全部 `EPERM`）→ **跨 uid 进程一律不计入 `degraded`**，只计入 `coverage.statOtherUID`（诊断用，不上界面）。
  - **`degraded = true` 仅当「同 uid 进程中存在返回 0 且 `errno == EPERM`」**——即本进程连自己用户的进程都看不到，这才与 AC-14 的「权限受阻」同义。
- **弃用 `lsof` 的理由（v1.0 的理由 ① 是错的，已换）**：v1.0 写「调用次数是 O(候选数) 量级」——**实测 `lsof` 全量一次 110–120 ms、按候选查表是内存 O(1)，不需要每候选一次调用**，该理由不成立。**保留决策但换理由**：① **`lsof` 会静默丢权**——无权限的进程直接不出现在输出里、无任何标记，导致「看不到」与「没有活引用」**不可区分**，失败不可归因（这正是 N5 禁止的）；② 文本解析在含空格 / 非 UTF-8 字节的路径上会串行（`Application Support`、项目名含空格是常态）；③ 外部命令存在 PATH 劫持面（检查表 S-07）。**性能不作为理由。**
- **自污染防护**：本进程自身 fd 与 cwd 参与归集但**必须从 `P_now` 排除**（`excludePIDs`）——否则「产品自己 `open()` 候选做 lock 探测」会把自己判成活引用。

- **判定域写死 = 同 uid 进程（质量 B-01，v1.2 新增）**：`P_now` 的定义域**只有同 uid 进程**。**跨 uid 进程（含 root）持有的文件，本产品看不到**（`EPERM`，FDA 不解锁）。因此：
  - **举证链 / 报告 / 界面上的 L0 结论文案不得写「全系统无活引用」「无任何进程占用」**，只能写「**本用户进程无引用**」（`M4` 的 `a` 判据不受影响：跨 uid 不可见只会导致「漏保护」，不会「误计」）。
  - **保守化补丁**：若候选所在目录**其他用户可写**（`stat` 的 `mode` 含 group/other write 且非 sticky），则该来源**不进入自动删除候选集**（只进报告）——这类目录在 `~/.cache` 下正常不存在，但**不能靠「正常不存在」来保证安全**。
  - 该限定需在 PRD 的 M4 补一句（**偏差 #7，随 CR-022 一并提**）。
- **约束**：P-L0 / AC-05 / AC-17 / AC-14 / N5 / §8。

### ADR-04 · 扫描：两阶段（`readdir` + `d_type` 遍历 → 命中路径批量 `getattrlistbulk`）

- **决策（v1.0 的 `getdirentries64` 在 arm64 `libSystem` 无符号、按字面实现编不过，已换）**：**阶段 1** 用 `readdir`（`DIR*`，`d_type` 取自 APFS，无需 `stat`）只做目录遍历；**阶段 2** 只对命中来源模式的条目用 `getattrlistbulk` 批量取 `name/size/mtime/birthtime/fileid`。遍历**不跟随符号链接**（`O_NOFOLLOW` 语义 + 遇 `DT_LNK` 只记录不下降）。
- **`getattrlistbulk` 三条解析硬约束**（不写死这三条会读出脏数据）：
  1. 必须以 `ATTR_CMN_RETURNED_ATTRS` 回读**实际返回的属性位图**——批量接口允许「请求了但没返回」，按请求位图解析会错位；
  2. 变长字段（`ATTR_CMN_NAME`）偏移按 `attrreference_t.attr_dataoffset` 相对**该属性起始**计算，不是相对记录起始；
  3. `ATTR_CMN_ERROR` 非 0 的条目**必须单独跳过并计数**，不能当作「属性为 0」。
- **代价**：`d_type == DT_UNKNOWN`（APFS 极少）退回单条 `lstat`，计入 §7.2 的 `M_unknown`。
- **约束**：N1 / AC-20 / AC-01 / AC-07（不跟随 symlink 是 S-03 的第一道闸）。

### ADR-05 · 存储：单文件 `state.residue`（JSON 头 + 分来源二进制段 + CRC），记录用 JSONL；**不用 SQLite**

- **决策**：见 §5.1（**v1.0 的段布局不可解，已重写为「带偏移的段表 + 固定段序 + CRC」**）。记录用 `records/*.jsonl`（`O_APPEND`）。
- **替代**：SQLite（引入必须签名、必须管理 WAL/`-shm` 的依赖面，且 N7 要求「单一本机目录 + jsonl」）/ 全 JSON（`C_done` 百万级解析 1.5–3 s，每次启动都要付）/ 二进制段独立文件（**两文件无法原子同时替换**，崩在中间 → 「位图新、`C_done` 旧」，`a` 直接错）。
- **代价**：自定义格式需版本化与迁移（§10.3）；`state.residue` **不进 N7 计量**（M4 明写），须在代码里**显式断言**而非只靠「放对目录」。
- **约束**：M4 / M6 / N7 / AC-18。

### ADR-06 · 授权探测：**降级为「能力探测 + 失败后指引」**，FDA 不再是前置授权

- **决策（v1.0 的三条 canary 实测全部退化为常量，已废）**：不做「FDA 是否已授予」的判定——macOS 无公开 API，且实测：跨 uid 进程恒 `EPERM`（FDA 也不解锁）、`TCC.db` 受 SIP 保护恒失败、`~/.Trash` 恒可写。**三条都不携带 FDA 信息。**
- **改为能力探测**（只报「能不能干活」，不报「有没有授权」）：
  1. `opendir(来源根)` 是否成功（失败 → `E-101`/`E-501`）；
  2. 同 uid 进程 fd 枚举是否成功（失败 → `E-501`）；
  3. `~/.Trash` 是否可写（失败 → `E-202`）。
- **FDA 的新定位**：**从「前置授权」降为「失败后的补救指引」**——只有当①或②失败时，第 ④ 页提示「可能需要在系统设置 → 隐私与安全性 → 完全磁盘访问权限中允许 Residue」。**产品不再声称「没有 FDA 就不能用」**（实测：L0 判定只读同 uid 进程 fd，`~/.cache` 也不在 TCC 保护范围内，多数机器上无 FDA 也能正常判定）。
- **该变化与 PRD 的冲突已登记为偏差 #4（需 CR-022）**：AC-14 Given 的第三类「`lsof` 因权限受限无法判定别的进程」在「不用 `lsof` + 同 uid 可读」的实现下**触发面显著变窄**。**本方案不擅自改 AC-14**，只登记。
- **约束**：AC-14 / N5 / §8「无权限」。

### ADR-07 · 发布与回滚：GitHub Releases + notarytool；**旧版遇新 schema 走只读，不逼重置**

- **决策**：详见 §10。**v1.0 的「旧版拒绝加载 + 提示重置」在 D2′（无自动更新）下是死胡同**（用户无法「升级」到不存在的通道提示、且「重置」会抹掉 `a` 这个唯一安全凭证）→ 改为**只读降级**：旧版检测到 `schemaVersion` 更高时，**以只读模式加载可识别字段并明确提示「数据由更高版本创建，本版本只读」**，**不写、不清、不迁移**。
- **约束**：N8 / F8–F10 / M4。

### ADR-08 · 可观测性：零遥测下的「本地审计三件套」

`scan.jsonl` / `execution.jsonl` / 诊断快照（导出脱敏）。**它们不是埋点，是审计日志**（不产生跨机聚合）。S1/S3 因此结构性不可测 → 已升级为 PM 裁决项（`Residue-R2-埋点与指标可测性-v1.0.md` D-01/D-02）。

### ADR-09 · 零第三方运行期依赖

不引入 SwiftPM 依赖；测试仅 `XCTest`。理由：签名公证需逐个 Mach-O 签名（F8–F10），每依赖多一个漏洞响应对象；本产品所需能力（文件枚举 / `libproc` / `rename`）系统框架直接提供。

### ADR-10 · 工程结构与打包（**新增 · 客户端评审 B1**）

- **决策**：**SwiftPM 管纯逻辑层与单测，`.app` 由脚本产出**。
  - `ResidueApp/Package.swift`：库 `ResidueCore` + 可执行 `Residue`（仅为编译校验）+ 测试 `ResidueCoreTests`。
  - `ResidueApp/scripts/make_app.sh`：产出 `build/Residue.app/Contents/{MacOS/Residue, Info.plist, Resources/, _CodeSignature/}`，`Info.plist` 至少含 `CFBundleIdentifier = com.residue.app`、`LSMinimumSystemVersion = 14.0`、`CFBundleShortVersionString`、`CFBundleVersion`、`NSHumanReadableCopyright`；`entitlements.plist` 首版**不含任何 `com.apple.security.*`**（非沙盒、非 App Store）。
  - **依赖 `.app` 身份的能力，只在 `.app` 下验收**：`SMAppService`（裸 Mach-O 抛 `kSMErrorInvalidSignature`）、TCC 授权面板（只认 `.app`）、`notarytool`（只吃 `.zip`/`.dmg`，不吃裸 `.app`）。
- **为什么单列一条 ADR**：v1.0 只写了「一个进程」没写「一个 bundle」，导致登录项 / 授权 / 公证三条链在开发期全废——这是**结构性遗漏**，不是细节。
- **约束**：F8–F10 / N8 / AC-11（授权时机）。

---

## 2. 进程模型与授权路径

```
Residue.app（单进程，登录项 SMAppService.mainApp，菜单栏常驻）
├─ AppShell（SwiftUI，7 页）—— 只渲染，禁止算术（§3）
├─ Scheduler（Timer + 电源/电量监听，N2/N3）
├─ ScanEngine（readdir + getattrlistbulk 两阶段 + 断点，ADR-04）
├─ L0Probe（libproc 枚举同 uid 进程，ADR-03）
├─ GateEvaluator / Retention（纯判定，不碰 IO）
├─ TrashExecutor（rename_to_trash，禁 rm）
└─ Store（唯一写者：state.residue / records / journal，§8）
落盘：state/state.residue（不计 N7 计量）+ records/*.jsonl（计入）
```

**授权时机**（不改 AC-11 / AC-14 的交互，只定实现）：
1. 首次启动 → 采集范围明示 + 四档默认值（开/开/关/关）→ **首次扫描前**。
2. 能力探测失败（ADR-06）→ 该来源按 P4「无法判定」处理、不删除、`a`/`b` 不判定。

---

## 3. 模块分层与职责边界

| 层 | 模块 | 只做 | 不做 |
|---|---|---|---|
| L0 指标（纯函数） | `Metrics`：`Threshold.h` / `ObservationClock` / `MissCounter` / `CheckCounter` / `RetentionMath` / `EntrySize` | 七量算法与判据 | 不碰 IO |
| L1 探测 | `ScanEngine` / `L0Probe` / `CapabilityProbe` | 产出观测事实 | 不判门槛、不写载体 |
| L2 判定 | `GateEvaluator` / `RetentionPolicy` | 由事实推结论 | 不执行删除 |
| L3 执行 | `TrashExecutor` / `StateStore` / `RecordWriter` / `Journal` | 原子 rename / 原子写 / 追加写 | 不重判门槛 |
| L4 呈现 | `AppShell` | 只渲染 L2 结论 | **禁止任何算术**（见下） |

**硬规矩**：L4 不得出现 `+ − × ÷` 与 `min/max`。界面要「剩余天数」→ 调 `Metrics.remainingDays`；要「达标」→ 调 `GateEvaluator`。**§12.2 那类分歧全部来自「界面自己算了一遍」。**

---

## 4. 接口契约

### IF-01 · `ScanEngine.scan(mode:breakpoint:) -> ScanResult`
`mode ∈ {full, incremental}`；输出 `ScanResult { startedAt, finishedAt, sources: [SourceScan], entries: [Candidate], unknowns: Int, aborted: AbortReason? }`。
失败：`E-101` 路径不可读 / `E-102` 卷只读 / `E-103` 低电量中断 / `E-104` 用户取消 / `E-105` 超时 / `E-106` 断点不一致 / `E-107` 上游只读定位失败。
**`aborted ≠ 失败`**：`E-103/104/105` 都落断点，**均不计入计数日**（M1）。约束：N1 / AC-20。

### IF-02 · `ScanEngine.resume(from:) -> ScanResult`
判定要求「重启续扫与未中断扫描在文件数 / 字节数 / 候选清单三项一致」（AC-20）→ 断点必须精确，**禁止「重扫整个目录」冒充续扫**（§5.5）。

### IF-03 · `L0Probe.snapshot(excludePIDs:) -> L0Snapshot`
`L0Snapshot { inodes: [FileIdentity: [pid_t]], cwdPaths: Set<String>, capturedAt, degraded: Bool, coverage: Coverage }`（**键 = `(vst_dev, vst_ino)` 二元组**，**不是 `vnodeid`**、**也不做单键编码**——见 ADR-03 的 K2 / A-6 实测更正）。
- `FileIdentity { dev: UInt32, ino: UInt64 }`（`Hashable`）——**`ino` 不得被截断**（`(dev << 32) | ino` 会截）。
- `degraded` 定义见 ADR-03（**仅同 uid 失败才置 true**；跨 uid 恒 `EPERM` 与 FDA 无关）。
- `coverage { sameUIDTotal, sameUIDRead, statOtherUID }` —— 诊断用，不上界面。
- **必须排除 `excludePIDs`（含自身）**。
- 约束：P-L0 / AC-05 / AC-17 / M4 FDA 行。

**〔2026-11-08 · A-6 已实现（`Sources/ResidueCore/L0Probe.swift`，16 个单测）〕** 实现与本契约一致，并新增两条实测约束：
① `PROC_PIDFDVNODEPATHINFO` 必须按 `vnode_fdinfowithpath` 解析（`pvip` 偏移 24）——**误按 `vnode_info_path` 解析会读出 `dev=1, ino=0` 垃圾值**；
② `proc_pidfdinfo` 缓冲区须 ≥ 1200 B（`PROC_PIDFDVNODEPATHINFO_SIZE`），传 1176 会 `ENOMEM` 失败。

### IF-04 · `CapabilityProbe.evaluate() -> CapabilityState`
`{ sourceRootReadable: [Source: Bool], sameUIDEnumeration: Bool, trashWritable: Bool }`（ADR-06 三条能力探测，**不判断「FDA 是否授予」**）。

### IF-05 · `GateEvaluator.unmetItems(...) / canLightUp(...)`
纯函数，入参是**已冻结观测值**（`T/K/J/a/b/计数日/报告是否产出`），出参是集合与五级优先级，**不读系统状态**。约束：AC-08 组 A/组 B / M1 唯一样式串 / AC-09 五级优先级。

### IF-06 · `CandidatePageSource.page(offset:limit:) -> [CandidateRow]`
`limit ≤ 200`（ADR-01）。

### IF-07 · `TrashExecutor.moveToTrash(_:source:now:) -> ExecutionRecord`
- 前置断言：目标存在、**非符号链接**（`lstat` 判 `S_ISLNK`）、**真实路径在该来源允许根内**、**同卷**、**普通文件或目录**。
- **`bytes` 定义（v1.0 用 `st_size`，对目录等于 ~96 B，导致 AC-15 上限判定恒真——已修）**：
  - 普通文件：`st_size`；
  - **目录：「递归逻辑字节」= 子树内所有普通文件 `st_size` 之和**（不计目录自身 `st_size`、不跟随 symlink）；
  - **取数时点必须写死（质量 B-02）**：预检值取「**首检时刻**」（`t1`），**「实际删除量」取 `rename` 完成后对废纸篓条目重新实测的值**（`t2`，`executeBatch` 内立即 `stat` 目标 `trashPath`）——**两者都写进 `execution.jsonl`**（`bytesPreview` / `bytes` / `bytesMeasuredAt`）。**判据 = `Σ bytes`（实测）≤ `capacityCap`**，有唯一取数时点，不是恒真断言。
  - **超出则撤销**：若某条实测 `Σ bytes > capacityCap` → **立即把该条从废纸篓移回原位**、记 `blocked_cap`、**本轮停止后续删除**（宁可少删；AC-15 是硬上限，不是目标值）。
  - 递归量**读不动 / 超时 / 权限不足** → `E-207`，**该候选不入删除候选集**（宁可少删，不可让上限失效）。
- 失败：`E-201` 源不存在 / `E-202` 废纸篓不可写 / `E-203` 跨卷 / `E-204` 符号链接或越界路径 / `E-205` 同名冲突无法消解 / `E-207` 体积不可得。
- 约束：N5 / AC-04 / AC-13 / AC-15。

### IF-08 · `TrashExecutor.executeBatch(_:capacityCap:countCap:) -> ExecutionOutcome`
> **首检与二检的时点（质量 B-04 · 用例可构造性）**：**首检 = 扫描时**（`l0CheckAt.first`，扫描阶段写入）；**二检 = 执行前**（`l0CheckAt.second`，`rename` 前的同一临界区）。两者之间隔着「扫描完成 → 到达定时执行点」的**分钟级自然间隔**，因此 **AC-17 的用例可确定性构造**，不需要撞微秒级竞态：① 完成一次扫描（首检落盘，此时该候选无持有者）；② 在到达执行点之前，用 `tail -f <候选文件>` 打开它并保持；③ 到达执行点 → 二检必命中 → 条目在原位、`blockedReason = 「二次检查阻断」`、`l0CheckAt` 两子值互不相同。**该构造步骤必须写进 R3.5 用例**，不接受「靠竞态碰运气」。


**上限必须在删除前预估**（`deletedBytes + 候选递归字节 ≤ capacityCap` 才执行），不是删完再判（后者会突破 AC-15）。

> **⚠ 预检取值的唯一来源 = `t1` 预览值**（K2 质量组指出 v1.5 未写死导致「预期两读」）：**「删除前预估」用的字节数 = IF-07 的 `t1` 递归字节**（首检时刻算出的值，**随候选一起缓存到执行点**），**不是执行时刻的实时递归值**。这样「预检通过 → `rename` 发生 → `t2` 实测超限 → 移回原位」这条路径**可达**，AC-15 的判据有判别力；若预检用实时值，`rename` 永不发生、该判据成死条文。
> **两种拦截的记录（值域封闭）**：预检阶段拦截（未 `rename`）→ `action = blocked_cap`、`blockedReason = "预检超上限"`；`rename` 后实测超限而**移回原位** → `action = blocked_cap`、`blockedReason = "实测超上限，已移回原位"`。**同一动作值、不同原因串**。

### IF-09 · `StateStore.load() / save(_:) / clearForAppVersionChange()`
- `load()`：`schemaVersion` 高 → **只读模式**（ADR-07，`E-301` 只作提示不作拒绝）；低 → 迁移；损坏 → `E-302`。
- `save()`：原子三连（§8.2），**唯一写者**。
- `clearForAppVersionChange()`：按 M1 写入时刻穷举式逐项对齐（清 `a` 的四项载体 + 计数日归零 + `T` 待重取 + `K`/`J`/`b` 清零 + **轮次不变**）。

### IF-10 · `RecordWriter.append(kind:record:) -> RecordRef`（**v1.0 缺幂等，已修**）
- **幂等键**：`execution` 类记录带 `jobId + candidateId + seq`；重试时若幂等键已存在则**不重复写**（写入侧先查最近 1 MB 尾部的幂等键索引，命中即跳过并返回已有 `RecordRef`）。
- 写入：`O_APPEND` 单行写 + **`fsync`**（v1.0 无 fsync，崩溃会丢已确认的删除记录 → `restorePath` 永久丢失）。
- **读取侧兜底**：任何统计（`可回收字节`、AC-15 对账、恢复列表）**按幂等键去重**——不依赖写入侧「一定只写一次」。
- 写入后立即触发 M6 检查（M6「每次写入后」）。

### IF-11 · `Retention.enforce(now:) -> RetentionOutcome`
`可回收字节 ≥ 200×10⁶` → 按记录时刻升序整行删至 `< 200×10⁶`；90 天 → 整行删；14 日内执行记录**不参与容量减数**（只作用于容量阈值，**不作用于 90 天**）。
**互斥要求（v1.0 缺失）**：`Retention` 与 `RecordWriter`、`Journal` 共用同一串行 actor；**状态机处于 `restoring` 时 `Retention` 不得执行**（否则会把正在回退的记录删掉，回退依据消失）。

### IF-12 · `Redactor.export(report:) -> URL`
替换 `<user>` / `<path>` / `<host>`；**替换后原文串出现次数必须为 0**，自检失败 → `E-401`，**不产出未脱敏文件**。

**报告内容（v1.1 只定义了脱敏、没定义装什么，SRE 第 10 条）**——必须能让维护者回答「为什么 L0 没看见」：

1. 环境段：`appVersion` / `schemaVersion` / macOS 版本 / `arch`（**不含主机名、不含用户名**）；
2. 量段：`round` / `countedDays` / 每来源的 `T` / `K` / `J` / `H` / `a` / `b` / `state`；
3. 取证段：`degraded` / `coverage.{sameUIDTotal, sameUIDRead, statOtherUID}` / 每次扫描的 `pNowCount` / `fSetBits` / `doneCount`（**来自 `scan.jsonl.diagnostics`**）；
4. 证据段：`evidence.jsonl` 与 `execution.jsonl` 的**全量**（逐行脱敏）；
5. 上游段：`upstreamCommands` 全量（`cmd` / `exitCode` / `durationMs`，**不含参数里的项目名**——参数按 `<project>` 脱敏）。

**缺任一段即视为报告不可用**（不是「尽量给」）。

---

## 5. 数据模型

### 5.1 `state.residue`（**重写**：带偏移的段表 + 固定段序 + CRC）

```
[ Magic "RSD1" 4B ][ schemaVersion u32 ][ headerLen u32 ][ headerJSON ][ segCount u32 ]
[ seg i: offset u64, length u64, kind u8, sourceIndex u8, reserved u16, reserved u32 ] × segCount   // 每项固定 24 B，8 字节对齐、无隐式 padding（字段序必须与 §5.1 校验① 完全一致，否则读写各按一处必然字段错位、且 CRC 查不出）
[ payload ... ]
[ CRC32 of (header + segTable + payload) u32 ]
```

`headerJSON`（可读，供审计）：

```json
{
  "schemaVersion": 1, "appVersion": "1.0.0 (1)",
  "round": 2, "roundStartAnchor": "2026-11-08T09:12:00Z",
  "countedDays": 3, "countedDaysCap": 14,
  "sources": [ { "source": "uv.cache", "state": "inDomain",
                 "snapshotTakenAt": null, "T": null, "K": null, "J": null, "H": null,
                 "a": 0, "b": 0, "slotCount": 0, "doneCount": 0,
                 "lastJudgmentAt": "..." } ],
  "settlement": { "producedAt": null, "reportId": null },
  "note": "T / H / K / J 的 null 有明确语义：T=null 表示本轮尚未取快照（M3：T 待重取），H=null 随之；K/J=null 表示本轮报告尚未产出（M3：报告产出前不存在）。写 0 是错值：H=min(30,0)=0 会让门槛恒过，界面也会显示假 0。
  "bytes": { "header": 0, "segTable": 0, "payload": 0 }
}
```

**四条硬约束（v1.0 三条缺陷的修法）**：

1. **段序固定**：`sources` 是**数组**，顺序 = `Source.allCases` 的**声明序**（`uv.cache`, `npm.npx`, `pipx.run`），**不用 `Dictionary`**（Swift 每进程随机哈希种子 → 段序漂移 → 读方串段）。每个来源三段，段表里带 `(kind, sourceIndex)`，**读方按 `(sourceIndex, kind)` 索引，不按位置猜**。
2. **段长恒由 `slotCount` 决定，与置位情况无关**：`F` 段长 `= ceil(slotCount/8)`。**`v1.0` 若按「已置位数」算长度，则 35,500 条「有引用未置位」的候选会让段短 4,436 B，读方会把 `C_done` 的头当位图尾吃掉** → 加载期断言 `bitmapBytes == (slotCount + 7) / 8`，不等即 `E-304`。
3. **加载期校验三连**（尺寸公式必须写全——v1.2 的「`Σ段长 + 头部长 == 文件长 − 8`」漏算了 4 B 的 `segCount` 与段表自身，按字面实现**每份合规文件都会判 `E-304`**）：
   - ① **尺寸恒等式**：`fileLen == 4(magic) + 4(schemaVersion) + 4(headerLen) + headerLen + 4(segCount) + **24×segCount** + Σ(payload 段长) + 4(CRC)`。**段表项固定 24 B**（`offset u64(8) | length u64(8) | kind u8(1) | sourceIndex u8(1) | reserved u16(2) | reserved u32(4)`，全项 8 字节对齐、无隐式 padding），故 `segCount` 一读出来段表多长就确定了；**例：`headerLen=300`、`segCount=9`、`Σpayload=1000` → `4+4+4+300+4+216+1000+4 = 1536 B`**（v1.3 写 `16×segCount` 与同句字段相加 24 B 矛盾，按字面实现每份合规文件仍会判 `E-304`）；
   - ② `offset + length` 不越界、段间不重叠、`offset ≥ 段表末尾`；
   - ③ **CRC32 一致**（CRC 覆盖 `header + segTable + payload`，不含 magic / 长度字段 / CRC 自身）。
   任一失败 → `E-304`，**不猜、不部分加载**。

`payload` 三段编码：

| kind | 内容 | 编码 |
|---|---|---|
| `0x01 F` | 每来源：位图 | `ceil(slotCount/8)` B，bit n（LSB first）= 位槽 n 已置位 |
| `0x02 C_done` | 每来源：已计过误判的槽号 | `count u32` + `count × u32 slot`（升序） |
| `0x03 Slots` | 每来源：位槽占用表 | `count u32` + `count × { slot u32, birthtime f64, pathLen u16, path UTF8 }` |

**为什么位槽表必须落盘**：位槽是 `F` 位图的下标；若按当前候选集重算，候选被手删后重建会落回旧槽并继承旧 `F` 位 → `a` 恒 ≥ 1（PRD 第 17 轮 Q29 已定「位槽不回收」）。

### 5.2 `evidence.jsonl`（举证链，**计入** N7 计量）—— V4 八顶层字段

| # | 字段 | 类型 | 空值规则 |
|---|---|---|---|
| 1 | `source` | enum(`uv.cache`/`npm.npx`/`pipx.run`) | 不允许空 |
| 2 | `birthtime` | ISO8601（毫秒） | 不适用 + 原因 |
| 3 | `l1Conclusion` | enum(`regenerable`/`notRegenerable`/`undetermined`) | 不适用 + 原因 |
| 4 | `l2Signals` | 四组信号各 `value + verdict` | 本期两组无通道 → 「不适用 + 该来源无 L2 观测通道」 |
| 5 | `l0CheckAt` | `{first, second}` 两子值 | `second = "不适用 + 未进入删除流程"` |
| 6 | `ruleHit` | `{ruleId, ruleVersion}` | 不适用 + 原因 |
| 7 | `executionAction` | enum(`rename_to_trash`/`none`) | `none` 是值，非空 |
| 8 | `restorePath` | 绝对路径 | `executionAction = none` → 不适用 + 未执行 |

**AC-18 分母恒为 8**；`l0CheckAt` 两子值**不另计分母**。

### 5.3 `execution.jsonl`（P3，**计入**计量）

`{ jobId, candidateId, seq, at, source, candidatePath, bytes, bytesKind: "file"|"dirRecursive", action, trashPath, restorePath, blockedReason?, appVersion, round }`

- **14 日豁免的减数项只认本文件**（M6）。
- `action ∈ {rename_to_trash, blocked_second_check, blocked_cap, blocked_size_unknown, **blocked_out_of_scope**, failed, **restored_by_user**}`（`blocked_out_of_scope` 对应 `E-204` 的越界 / 符号链接拒绝——**不能复用 `failed`**：`failed` 表示「尝试了但失败」，越界是「按规则拒绝执行」，两者的用例预期不同）——`blocked_*` 也算执行记录（要能解释「为什么没删」）；**`restored_by_user` 是 AC-13 恢复动作的回写**（SRE S1：不回写则「恢复过几次」不可追，也就无法判断「同一误删反复恢复」）。
- `bytesKind` 必填：目录的 `bytes` 是递归量（IF-07），**不标 kind 会让读者把目录的 96 B 当成真实体积**。

### 5.4 `scan.jsonl`（**计入**计量，**不豁免**）

`{ at, mode, sources, filesScanned, bytesScanned, durationMs, aborted?, breakpointSaved, unknownCount,
  upstreamCommands: [ { cmd, args, exitCode, durationMs, invokedAt } ],   // 质量 B-06：AC-19 的可判载体
  diagnostics: { degraded, coverage: { sameUIDTotal, sameUIDRead, statOtherUID }, pNowCount, fSetBits, doneCount, a, b, round, countedDays,
    contentReads: 0 } }`   // contentReads = 内容读取次数（K2 质量组要求）：扫描阶段只读元数据不读内容 → 该值恒为 0；非 0 即说明实现越界读了内容 → AC-07 该判据由恒真变为可判

**`upstreamCommands` 是 AC-19「直接删文件的上游命令出现次数 = 0」的唯一可判载体**（v1.1 没有它 → 该断言恒真、不可证伪）。每次调用上游只读命令必须落一行；**未落盘即视为「无法证明」，验收按不通过处理**。
**`diagnostics` 是「删错了」类事故的唯一支持通道**（SRE 第 10 条）：它全是**既有状态的回显**（`degraded` / `coverage` / `P_now` 规模 / `F` 置位数 / `C_done` 计数 / 七量），**不新增采集、不产生跨机聚合**。

### 5.5 断点与 journal（`state/` 下，**不计入** N7 计量：运行期临时态）

**断点（精确续扫）**：`checkpoints.json`，`{ parentInode, completedNames: [String], seenHash, counts }`——**用「已完成名字集合」而不是「字典序水位」**。

> **⚠ K2 实测更正（v1.5 写错，必读）**：v1.5 写的「已完成子项名字**典序最大值**」作水位，**在真实 APFS 上必然失败**——`readdir` 返回的是 **APFS 哈希序，不是字典序**。决定性实验：200 项目录中断后续扫，合并结果 **36 项 vs 基线 120 项，漏 70%**。
> **现行机制**：每个目录维护**已完成条目的名字集合**（`completedNames`），恢复时同目录 `readdir` 逐个比对集合、跳过已完成的。代价 = 每个目录的已完成名字要落盘（实测该量级可接受，见 §7.2 增量说明）；收益 = **续扫与未中断扫描三项一致**（AC-20 判定要求）。
> **一致性自证**：断点续扫结束时，对「已见条目集合」做哈希比对 + 逐项核对**文件数 / 字节数 / 候选清单三项**；任一不符 → `E-106` 要求全量重扫。每 2000 条或 2 s 落一次（原子写）。续扫结束做一致性校验（文件数 / 字节数 / 候选清单三项），不符 → `E-106` 要求全量重扫。

**journal（执行事务，N4）**：`journal.jsonl`，**每行 `fsync`**（v1.0 无 fsync → 崩溃时 50 个已进废纸篓的文件零记录，直接违反 N4）。行类型：

| 行 | 内容 |
|---|---|
| `begin` | `jobId`, `startedAt`, `plannedCount`, `plannedBytes`, **`appVersion`, `round`, `trigger`（`scheduled` / `manual`）**（SRE S5：没有 `trigger` 就答不出「谁触发的」） |
| `intent` | `candidateId`, `trashPath`, `origPath`（**在 rename 之前写**） |
| `moved` | `candidateId`, `movedAt`（rename 成功后写） |
| `restored` | `candidateId`, `restoredAt`（回退成功后写） |
| `end` | `jobId`, `finishedAt`, `movedCount`, `failedCount` |

**回退协议（v1.0 会漏回退或重复回退，已修）**：启动时若发现 journal 无 `end` → 进入 `restoring` 态：对每个 `moved` 且无 `restored` 的条目，**先校验 `trashPath` 是否仍存在**（存在 → 移回原位并写 `restored`；不存在 = 用户已清空 → 写 `restored` 并标 `restoreFailed`），再写 `end`。**逐条持久标记**使「回退到一半再崩」可继续；`trashPath` 存在性校验使「重复回退」不会把原位文件再移一次。
**torn tail 的自愈（数据评审 #6 —— v1.2 只在 §15 处置表里写了、正文漏了，v1.3 补实）**：三个 `.jsonl` 用 `O_APPEND` 单行写 + `fsync`，但崩溃仍可能留下**半行**（`fsync` 之前断电）。**启动时对每个 `.jsonl` 做尾行校验**：

1. 从文件尾向前找最后一个换行；若末尾无换行 → 末行是半行；
2. 对末行尝试 JSON 解析，失败 → 判定为 torn tail；
3. **修复**：把文件截断到最后一个换行（`ftruncate`），并把丢弃的字节数与偏移**写入 `scan.jsonl` 一条 `recordRepair` 记录**（这条记录本身是新行，不会再次损坏）；
4. **不在原地「补全」半行**——无法知道缺什么，补全等于编造记录；
5. **对统计的影响**：修复发生在**启动期**，而 AC-18 的完整率测量时点是「观察期结束扫描完成时」（N7 · CR-016）→ **修复后不存在 torn tail，完整率判定不受影响**；`可回收字节` 同理（M6 按整行计，半行本来就不成行）；
6. **业务后果如实登记**：若被丢的是 `execution` 行 → 该条删除失去 `restorePath`，**恢复入口不会出现该条**；故第 ⑦ 页恢复列表为空时须有静态说明「若日志损坏，已删除条目仍可在废纸篓中按名称查找」。

---

## 6. 错误码表

| 码 | 场景 | 归类（§8） | 用户可见结果 |
|---|---|---|---|
| `E-101` | 来源路径不存在 / 不可读 | 错误 | 「路径变更」+ 来源名 |
| `E-102` | 卷只读 | 错误 | 「无法写入」 |
| `E-103` | 低电量中断（< 20%，电池） | 加载（暂停） | 「低电量已暂停」 |
| `E-104` | 用户取消 | 加载 | 「已取消」 |
| `E-105` | 扫描超时（N1 600 s） | 超时 | 「已超时，可续扫」 |
| `E-106` | 断点一致性校验失败 | 超时 | 「需重新扫描」 |
| `E-107` | 上游只读定位 / 能力探测失败 | **错误**（非「无权限」、非 AC-14 降级） | P4「无法判定」 |
| `E-201` | 源不存在 | 错误 | 逐条原因 |
| `E-202` | 废纸篓不可写 | **无权限** | 「废纸篓不可写」+ 指引 |
| `E-203` | 跨卷 | 错误 | 拒绝，源仍在原位 |
| `E-204` | 符号链接 / 越界路径 | **错误**（安全拒绝；**不属 §8 封闭的三类 OS 权限受阻，不得归「无权限」**） | 「不在允许范围，已跳过」（判据：该条 `action = blocked_out_of_scope`，`blockedReason` 含「越界」或「符号链接」） |
| `E-205` | 同名冲突无法消解 | 错误 | 跳过该条 |
| `E-206` | 删除前二次检查阻断 | 并发冲突 | 「二次检查阻断」（AC-17 判定原文） |
| `E-207` | 目录递归体积不可得 | 错误 | 「体积不可得，未删除」 |
| `E-301` | schema 更高 | 错误（**只读降级**，不拒绝） | 「数据由更高版本创建，本版本只读」 |
| `E-302` | 状态文件损坏（CRC / 结构失败，且无可用 `.bak`） | 错误 | 「状态文件损坏，已备份为 `.corrupt`；请先导出报告」；**「重置本地状态」为显式二次确认项，且确认框必须写明「会清零 L0 误判记录，等于给自动删除放行」**——**不得作为默认出路**（SRE 第 9 条：原文案与 §10.2「不引导重置」逐字相反） |
| `E-303` | 写短写 / `ENOSPC` / `EDQUOT` | 错误 | 「磁盘空间不足，状态未更新」+ **可执行动作**：给出所需 MB、提示「清理废纸篓或释放磁盘后重试」 |
| `E-304` | 段校验失败（越界 / 重叠 / CRC / 位图长度不符） | 错误 | **保留现场 + 只读**：把文件备份为 `state.residue.corrupt`，**进入只读态**（可看已解析部分、可导出报告），提示「请导出报告」；**不提供「重置」入口、不自动重置**（v1.3 的「同 `E-302`」会继承重置入口，而 `E-304` 自身无自愈路径 → 唯一出口就变成重置，正是 §10.2 禁止的那条） |
| `E-305` | 迁移空间预检不足 | 错误 | 「需要 X MB 空间」（**给出具体数字**）+ 「释放后重启应用即会自动重试」——**不给数字的提示等于没有提示** |
| `E-306` | 迁移恢复失败（从 `.bak` 恢复也失败） | 错误 | 进入**只读**：可看可导出，**不可写、不可清理**；提示「请重装同版本或更高版本；可导出报告」 |
| `E-308` | **已从 `.bak` 恢复成功**（迁移失败但备份可用） | 错误（提示级） | 「本次数据升级未完成，已回退到升级前的数据；观察期进度未受影响」。**这条必须独立存在**：`E-302` 已限定为「无可用 `.bak`」，若恢复成功也报 `E-302`，则「迁移失败但已成功回退」这条**最常见的主路径没有码可用**（终审 N-1） |
| `E-401` | 导出脱敏自检失败 | 错误 | 「导出失败」（不产出文件） |
| `E-501` | 同 uid 进程枚举失败 / 来源不可读 | **无权限** | P4「无法判定」+ 授权指引条目 ID。**对应的未达项文案 = 「L0 未判定（无法枚举本用户进程）」**（K2 质量组指出：ADR-06 已不判 FDA，文案若写「未取得 Full Disk Access」就是**说了一件产品不知道的事**，违反 N5 的对偶要求——不把未知说成已知） |

**`E-107` 与 `E-501` 不可混用**：前者是上游能力问题（§8「错误」/ P4），后者是权限（§8「无权限」/ AC-14）。

---

## 7. 容量与延迟预算

### 7.1 上限（来自 PRD）

| 项 | 上限 | 来源 |
|---|---|---|
| 全量扫描 p95 | ≤ 600 s，可中断/断点续 | N1 |
| 增量扫描 | CPU 均 ≤ 5% / 峰 ≤ 15% / **持续 ≤ 30 s** | N1 |
| 常驻采样（默认关） | 内存增量 ≤ 80 MB / CPU 日均 ≤ 3% | N2 |
| 单次执行 | ≤ 300 s，超时整体回退 | N4 |
| 状态载体 | 见 §12.3（**v1.0 的「约 1 MB」只对位图成立**） | M4 |
| 记录目录 | 可回收字节 < 200×10⁶（14 日内执行记录豁免） | N7 / M6 |

### 7.2 全量扫描预算（`V8 = 328 万` 待确认）

| 阶段 | 量 | 单价（保守） | 预算 |
|---|---|---|---|
| `readdir` 遍历（两阶段之一） | 328 万条目 | **30 k 条/s 是冷缓存下限**（warm 可达 60–80 k） | **109 s** |
| `DT_UNKNOWN` 补 `lstat` | ≈ 1% = 3.3 万 | 15 µs | 0.5 s |
| `getattrlistbulk`（命中路径） | ≤ 30 万 | 3 µs/条 | 0.9 s |
| 逐候选 `lstat`（symlink / 真实路径） | ≤ 30 万 | 12 µs | 3.6 s |
| L0 判定（建倒排 + 查表） | 同 uid 进程 ~600 × fd 120 = 7.2 万 fd | 15 µs/fd | 1.5 s |
| 归因 / 差分 / 落盘 | 30 万候选 | — | 2 s |
| **合计** | | | **≈ 118 s** |

**p95 余量 ≈ 5×**。该推导是**估算**，唯一裁判是 AC-20 的实测用例。

### 7.3 增量扫描（**v1.0 的「目录 mtime 变化则重扫」会造成退化，已改**）

- **v1.0 的缺陷**：`uv` / `npm` 的子树目录**天天变**（每次装包都动 `archive-v0` 与 `_npx` 的 mtime）→ 「mtime 变则重扫该目录」实际退化为「重扫整个子树」，30–120 s，超 N1「持续 ≤ 30 s」5–20 倍。
- **改为**：增量**只做两件事**——① 对**已登记候选**（`slotTable` 内）批量重取属性，判断是否失联 / 是否被持有；② 对**来源根 + 一级子目录**做 `readdir` 计数粗差（`direntCount` 与上次比对，**不用 mtime**）。
- **明确的能力边界（如实登记）**：增量**不负责发现深层新候选**；新候选由每日全量（N3 默认每日 1 次）或每 7 天全量（N3 建议值）发现。**后果**：新装的包可能要到下一次全量才进清单。
- **预算**：30 万候选 × 3 µs ≈ 0.9 s + 根目录 `readdir`（约 10 万 dirent）≈ 3 s → **< 10 s**，满足「持续 ≤ 30 s」。

- **快照必须由 `full` 取（客户端第 2 轮 B1，v1.2 新增）**：**开轮后的第一次扫描强制 `mode = full`**；在该次之前若发生 `incremental`（例：版本变更后调度器先触发了增量），**不取快照、`T` 保持「待重取」**。理由：M3 规定 `T` 的唯一来源是「本轮首次成功扫描」的快照；若该次是增量，`T` 会由**部分候选集**确定 → 系统性偏小且**静默**（IF-02 的一致性断言只比「同一次扫描」，查不出）→ 新候选在 `F` 里可观测天数被截短 1–6 天 → `a` 少记、门槛朝「更易点亮」方向松。
- **与 M1 的边界（不改冻结基线）**：`incremental` 仍是「成功扫描」，**仍正常 +1 计数日**（M1 未区分 full/incremental，本方案不擅自区分）。本节只约束「**哪一类扫描可以产生快照**」，不改变计数日口径。

### 7.4 体量（**v1.0 的 92 B/条偏低，依客户端与数据评审实测改为 112 B/条**）

| 候选规模 | `F` 位图 | `C_done` | 位槽表（112 B/条） | 合计 |
|---|---|---|---|---|
| 30 万 | 37.5 KB | ~0 | 33.6 MB | **≈ 34 MB** |
| 100 万 | 125 KB | ~0 | 112 MB | **≈ 112 MB** |
| 300 万 | 375 KB | ~0 | 336 MB | **≈ 336 MB** |

112 B = 路径均长 98 B + `slot 4` + `birthtime 8` + `pathLen 2`（APFS 上 `~/.cache/uv/archive-v0/<64 位哈希>/<文件名>` 实测 70–110 B）。

### 7.5 记录目录

`evidence.jsonl` 粒度 = **观察期结束扫描时被判「可删」的候选各一行**（N7 · CR-016）→ 量级 = 被判可删条目数级，不随观察期长度放大。单行 400–600 B → 10 万条 ≈ 50 MB，**低于 200 MB → M6 终止条件可达**。

---

## 8. 并发与一致性

### 8.1 单写者（**v1.0 只声明了 `state.residue`，已扩到全部落盘物**）

唯一写者是 `Store`（一个串行 actor），覆盖 `state.residue` + `records/*.jsonl` + `journal.jsonl` + `checkpoints.json`。状态机：`idle → scanning → judging → executing → restoring → idle`。**UI 只读快照，不得写任何落盘物。**

### 8.2 原子写

`write(tmp) → fsync(tmp) → rename(tmp, target) → fsync(dir)`，**rename 前不得 truncate 目标**。
**`E-303` 分支（v1.0 缺失）**：`write` 返回短写 / `errno ∈ {ENOSPC, EDQUOT}` → **删 tmp、不 rename**、状态保持上一代完整版本，报 `E-303`。**不能出现「短写的 tmp 被 rename 成完整一代」。**

### 8.3 并发冲突（§8「并发冲突」状态类）

进程内互斥 + 状态机；第二个请求进入 `blocked` 并在第 ① 页状态条显示「并发冲突」。**不做队列、不做重试**（并发上限转 Backlog，本期只保证不互相踩）。

### 8.4 崩溃恢复（N4）

见 §5.5 的 journal 协议。**三条硬要求**：① 每行 `fsync`；② `intent` 必须在 `rename` **之前**落盘；③ 回退逐条写 `restored`，靠 `trashPath` 存在性校验防重复回退。

---

## 9. 安全设计要点（详表见 `Residue-R2-安全合规检查表-v1.0.md`）

| # | 要点 | 一句话 |
|---|---|---|
| S-03 | 符号链接穿越 | 候选先 `lstat` 判 `S_ISLNK`；真实路径不在允许根内 → **不删**，记 `E-204`（**归 §8「错误」类，不归「无权限」**）。否则 `~/.cache/uv` 里一个指向 `~/Documents` 的 symlink 就能删个人文件，直接违反 AC-07 |
| S-04 | 跨卷 / 硬链接 | `EXDEV` → 拒绝，**绝不退化为 copy+unlink**（等于 `rm`，违反 N5）；`st_nlink > 1` → 标「硬链接，回收量不符预期」，只删该链接 |
| S-05 | 二次检查 | AC-17 的 `second` 检查与 `rename` 在**同一临界区**；产物落 `l0CheckAt.second`；**排除自身 pid** |
| S-06 | 脱敏 | 导出替换 `<user>/<path>/<host>`，替换后原文出现次数 = 0 断言 |
| S-07 | 无外部命令 | 不 `fork/exec`（ADR-03 / ADR-09）；上游 CLI 只做只读定位，`Process` 直接 exec、**不经 `/bin/sh`** |
| S-08 | 路径来源 | 候选路径全部来自目录枚举，**不含用户输入拼接**；上游输出须校验：绝对路径、无 `\0`、长度上限、落在白名单根内 |
| S-09 | **零外发的可验证判据** | **`otool -L` 不作为判据**（`URLSession` 归属 Foundation，`otool -L` 看不到 `CFNetwork` → 假通过）。**三层判据**：① 源码级 `grep -c` 对 `import Network` / `URLSession` / `URLRequest` **命中数 = 0**；② 二进制级 `nm -u` 无 `_OBJC_CLASS_$_NSURLSession` 等符号、`strings` 无 `https://`；③ **在有网机器上**跑完整流程后 `lsof -i -p <pid>` 与本机 `nettop` 对本进程**连接数 = 0**（无网 CI 上第 ③ 层不可判，**必须显式跳过并在报告里标注「在无网环境执行，第 ③ 层未覆盖」**，不得默认为通过） |

---

## 10. 发布、回滚与兼容
## 9.5 测试注入点约定（K2 质量组要求 · **只影响可观测字段，不改判定逻辑**）

> **为什么需要**：观察期已满 = **14 个计数日 = 14 个日历日**（M1：一天最多 +1），macOS 无电量注入点，本期三类来源无 L2 观测通道。**没有注入点，AC-02 / 04 / 08 / 09 / 20 的用例构造前置根本跑不出来**，写出来就是恒真。
> **边界（写死，不可放宽）**：① **只在测试构建生效**（`#if DEBUG` + 测试构建），Release 构建**必须剥离**（§10.1 增发布准入检查）；② **只影响可观测字段的取值**，**不得改变任何判定逻辑**（`a` / `b` / `K` / `J` / `H` / 门槛的算法一字不改）；③ **不得进入任何持久化落盘物**（`state.residue` 与 `.jsonl` 里不得出现注入值本身，只允许出现它影响后的正常读数）。

| 注入点 | 方式 | 影响的可观测量 | 不得影响 |
|---|---|---|---|
| **时钟 / 观察期** | 环境变量 `RESIDUE_TEST_CLOCK`（ISO 时刻）、`RESIDUE_TEST_COUNTED_DAYS`（直接置本轮计数日） | `Metrics.ObservationClock` 的当前时刻与计数日 → 观察期是否已满、剩余天数 | 七量的算法 |
| **电量 / 电源** | 环境变量 `RESIDUE_TEST_POWER`（`normal` / `onBattery` / `lowBattery`） | `Scheduler` 的低电量分支 → 是否 `E-103`、是否暂停定时任务 | 扫描结果本身 |
| **L2 推断值** | 环境变量 `RESIDUE_TEST_L2`（来源名 → 推断值 JSON） | AC-02 判据 3 的读数（「可删除量」随 L2 变化） | 任何门槛（L2 本期不构成门槛） |
| **来源枚举** | 环境变量 `RESIDUE_TEST_SOURCES`（封闭枚举子集） | 判定域成员 → 空域 / 新入域来源 / `pipx` 行 | 候选的发现逻辑 |
| **候选注入** | 环境变量 `RESIDUE_TEST_CANDIDATES`（路径列表 + 期望 `T`/`K`/`J`） | `T` / `K` / `J` 的快照与归因 | `a` 的判据（仍由真实 L0 判定产生） |

**Release 剥离检查（§10.1 第 10 条）**：Release 构建产物中 `RESIDUE_TEST_` 前缀字符串的**出现次数 = 0**（`strings` 扫描）。



### 10.1 发布准入（F8–F10，**v1.0 漏 5 项，已补**）

1. `.app` **先组装完整**（含 `Info.plist` / `Resources`）→ 再对**包内每个 Mach-O**（主二进制、`Frameworks/*`、`PlugIns/*`）逐个 `codesign --force --options runtime --timestamp --entitlements ...`；**不用 `--deep` 代替逐个签**（`--deep` 是验证便利，不是签名替代）。
2. **`get-task-allow` 必须为 `false`**（Debug 配置余留会让公证被拒）。
3. `ditto -c -k --keepParent Residue.app Residue.zip` → `notarytool submit Residue.zip --wait`（**`notarytool` 只吃 zip/dmg，不吃裸 `.app`**）。
4. **`stapler staple` 必须对 `.app` 做**（不是对 zip）；staple 后再重新打 zip 分发。
5. `codesign --verify --deep --strict` + `spctl --assess --type execute` 双验；**`.zip` 本身不可 staple**，票据在 `.app` 内。
6. 产物：`.dmg`（内含 `.app`）或 `.zip`；**不分发裸 Mach-O**（不能 staple）。

**7–9 是本轮 SRE 评审要求补的（此前只有「包是干净的」，没有「装上能用、坏了能退」）：**

7. **端到端装机检查（干净机）**：① 干净 macOS 14 / 15 各一台，**先断网**（证明不需要联网回查也能装）；② 保留下载物的 `com.apple.quarantine` 属性，装入 `/Applications`；③ 首启 → 采集范围明示 → 首扫跑通；④ 登录项状态显示 `.enabled` 且**触发一次定时任务**；⑤ 卸载说明可执行（退出后台项 + 一键清除）。**判据：除系统自身的授权对话框外零人工干预、零崩溃、`scan.jsonl` 有记录。**

   **⚠ 前提：每个分发载体必须各自签名 + 公证 + `staple`**（客户端第 3 轮与质量 N2 独立命中）：票据是**按载体装订**的——`.app` 装了票据**救不了外层容器**。若发 `.dmg`，**`.dmg` 本体也必须 `codesign` + `notarytool submit` + `stapler staple`**；否则断网时 Gatekeeper 对映像本体评估为 `no usable signature` → **挂载即被拦，第 7 条不可达**。**首发建议只发 `.zip`（内含已 staple 的 `.app`）**，少一条要独立公证的链。
8. **SHA-256 对账**：产物计算 SHA-256 → 写入 Release 说明 → **重新下载一次再算**，两值必须一致（防上传损坏）；README 的验证指引同步更新。
10. **测试注入点剥离检查**：`strings` 扫描 Release 产物，`RESIDUE_TEST_` 前缀**出现次数 = 0**（§9.5 的注入点绝不能进发布版）。

9. **保留上一版安装包**：**回滚的唯一可用物**。每次发布归档上一版载体与 SHA-256；**从第二版起，无上一版归档不许发布**（否则 §10.2 的回滚只是纸面条款）。**首发例外（否则自锁）**：首版没有「上一版」，演练对象改为**本版自身**——装 → **卸载（按卸载说明：移除 `/Applications/Residue.app` + 手动删除整个 `~/Library/Application Support/Residue/`）** → 重装，判据 = 重装后为初始态、`scan.jsonl` 重新开始。
   **⚠ 这里必须区分两个不同动作**（质量终审命中）：**「一键清除」是产品内动作，按 S-10 明确不清 `state.residue`**（否则可一键洗掉 `a`）；**「卸载」是用户手动的目录删除**，与 S-10 无关、也不受 M4「`a` 只在应用版本变更时清零」约束（目录都没了）。**首演判据只能挂「卸载」，不能挂「一键清除」**——否则按设计必然失败。

### 10.2 回滚

无自动更新（D2′）→ 回滚 = 用户装回旧版。**旧版遇更高 `schemaVersion` → 只读模式**（ADR-07）：显示可识别字段、**不写、不清、不迁移**，提示「数据由更高版本创建」。**不提供降级迁移**；**不引导「重置本地状态」**（重置会清掉 `a`，那是唯一的安全凭证）。

**只读模式的四条硬要求（SRE 第 3/5 条）：**
- **不认识的字段不得渲染为 `0`**——必须渲染「**—（由更高版本维护）**」。否则旧版把 `a` / `countedDays` 按默认 0 读 → 把「错 1 次永久」显示成「一次都没错」，这是**假值**，比空白更危险。
- **明确告知能力缺失**：页面顶部一条静态说明「数据由更高版本创建，本版本只读；**不能执行清理**」。
- **出路只有一条且要说清**：用户需**装回更高版本**（产品内不提供任何外部地址，D2′）。**回滚是降级、不是等价替代**——这句话必须写进 README 的「已知限制」，不能只写在 PRD 里。
- **回滚演练（SRE 第 4 条）**：每次发布前，用上一版归档在干净机演练「装旧版 → 升级 → 回滚 → 重装新版」。**判据按本版是否变更 `schemaVersion` 分两支**（v1.2 只写「只读提示可见」，在**未跳 schema 的版本上永远不可达**）：
  - **变更了 `schemaVersion`** → 数据无损（字节数一致）、**只读提示可见**、`a` 不被改写（显示「—（由更高版本维护）」）、重装新版后恢复可写；
  - **未变更 `schemaVersion`** → 数据无损、**旧版直接正常加载（不进只读）**、重装后状态与回滚前一致。
  - **未演练不许发布。**
- **只读态不产出 AC-09 报告**（质量第 2 轮补）：只读模式下产品**不写任何落盘物**，故也不产结算报告；第 ⑤ 页在该态显示「只读，不结算」，而不是「本轮未结算」——后者会被读成「等一会儿就有」。

### 10.3 schema 迁移矩阵

| 场景 | 行为 |
|---|---|
| 相同 | 直接加载 |
| 低（旧数据 + 新程序） | ① **空间预检**：需 `≥ 3 × 状态文件 + 64 MB`（峰值 = 原件 + `.bak` + 新件，**v1.1 的 `2×+20%` 少算了新件 → 336 MB 状态下缺口 200+ MB，迁移末段必 `ENOSPC`**），不足 → `E-305` 并给出所需 MB；② 写 `state/migrating.json`（`{step, fromSchema, toSchema, bakPath, startedAt}`，**原子 + fsync**）；③ 写 `state.residue.bak`（原子）；④ 迁移；⑤ **成功后删 `.bak` 与 `migrating.json`**；⑥ 失败 → 从 `.bak` 原子恢复 + **`E-308`**（恢复成功）；**无可用 `.bak`** → `E-302`；**恢复本身失败** → `E-306` + 进入只读 |
| 高（新数据 + 旧程序） | **只读模式**（`E-301` 仅提示） |
| 损坏（CRC/结构失败） | 先备份为 `state.residue.corrupt`，再报 `E-302`；**不静默新建空状态**（那会把 `a` 清零，等于放行） |

**`.bak` / `.corrupt` 的归属（v1.0 漏登记）**
**断电 / 崩溃后的恢复（SRE 第 7 条 + 数据第 2 轮 N1）**——v1.2 用「原件 CRC 是否完好」当判据是**错的**：迁移成功后原件 CRC 同样完好，会把「已成功」判成「未完成」、二次迁移并删掉唯一 `.bak`。

`state/migrating.json` 的 `step` **只在下列时刻被原子写入 + `fsync`**，它本身就是进度游标：

| step | 含义 | 已发生的副作用 |
|---|---|---|
| 1 | 已通过空间预检 | 无 |
| 2 | 已写 `.bak` 并 `fsync` | `.bak` 存在 |
| 3 | 已写完新件临时文件（未 rename） | 临时文件存在、目标仍是旧件 |
| 4 | **即将 `rename`**（新件已写完且已校验可加载，rename 前写入） | 临时文件存在、**目标未动** |
| 5 | `rename` 已完成 | **目标已是新件**、`.bak` 存在 |
| 无 `migrating.json` | 已收口或从未开始 | 只有目标文件 |

**恢复判定（按 `step`，不按 CRC 二分）**：

- **`migrating.json` 不存在** → 正常加载目标（损坏再走 `E-302`）。
- `step ∈ {1, 2}`（**尚未动过目标**）→ **先确认目标文件存在且可加载**：成立则删 `.bak` + 删 `migrating.json`；**目标不可加载**才从 `.bak` 恢复。**「先确认目标存在」必须做**，否则可能把唯一可用副本删掉。
- **任何分支在删 `.bak` 之前，必须先确认「目标文件存在且可加载」**（任一 schema 均可）——这是本节的**前置守卫**，防止「目标恰好不存在时把唯一副本删掉」。
- `step = 3`（**目标未动**）→ 删临时文件 + 删 `.bak` + 删 `migrating.json`，加载旧件（迁移下次重做）。**但须先断言 `目标.schemaVersion == fromSchema`**：若不等于（说明 `rename` 已发生而 `step` 未及时更新），**不得走本分支**，改按 `step = 4` 处置。
- **`step ∈ {4, 5}`（`rename` 可能已发生、也可能没）** → **判「目标是否已是 `toSchema` 且 CRC 通过」**：
  - **是** → 迁移实际已完成 → 删 `.bak` + 删 `migrating.json`，按新 schema 加载；
  - **否**（目标仍是 `fromSchema`）→ 删临时文件 + 删 `.bak` + 删 `migrating.json`，加载旧件（`rename` 没发生，等于回退到 `step=3`）；
  - **目标损坏且 `.bak` 可用** → 从 `.bak` 恢复 + 删 `migrating.json` + **`E-308`**（恢复成功）；**`.bak` 不可用** → `E-302`；**恢复过程本身失败** → `E-306` + 只读。

> **为什么 `step=4` 写在 `rename` 之前**：若写在之后，断电时会出现「`rename` 已成功但 `step` 仍是 3」→ 按 `step=3` 无条件删 `.bak` → 唯一备份消失。把风险窗口改成「`step=4` 已写但 `rename` 未发生」（可安全回退），再用 `目标.schemaVersion` 断言兜住反向情况。

**两条禁止**：禁止「见 `.bak` 即删」（可能毁掉唯一备份）、禁止「见 `.bak` 即回滚」（会把已成功的迁移退回旧 schema）。

：放在 `state/` 下、**不计入 M6 计量**（M6 只算 `records/*.jsonl`）；但它们含用户路径副本，故 **N7 的「一键清除」范围 = `records/*.jsonl` + `state/journal.jsonl` + `state/checkpoints.json` + `state/migrating.json` + `state/*.bak` + `state/*.corrupt` + `state/*.tmp`**，**不含 `state.residue` 本体**（S-10）。**`journal.jsonl` / `checkpoints.json` 含候选路径，漏清即等于「清除后仍留用户路径副本」**（质量 B-07）。迁移成功后 `.bak` 立即删除，正常态下不存在。

---

## 11. 契约 ↔ 实现映射

| PRD 编号 / 量 | 实现落点 | 单测 |
|---|---|---|
| M1 计数日 / 轮次 | `Metrics.ObservationClock` | ✅ |
| M2 `H = min(30,T)` | `Metrics.Threshold.h` | ✅ |
| M3 `K + J = T` / 取快照时点 | `Metrics` + `StateStore` | ✅（含 `pipx` 不套恒等式） |
| M4 `a`（`F ∩ P_now − C_done`） | `Metrics.MissCounter` + `StateStore` | ✅ 8 场景 |
| M5 `b` | `Metrics.CheckCounter` | ✅ |
| M6 可回收字节 | `Metrics.RetentionMath` + `Retention` | ⬜ 算式已测，回收未实现 |
| AC-04 / AC-15 | `TrashExecutor` | ✅（上限预估；**目录递归字节待补**） |
| AC-09 组 A / 五级「否」 | `GateEvaluator` | ✅ 7 组组合 |
| AC-13 恢复 / 脱敏 | `TrashExecutor.restore` + `Redactor` | ⬜ |
| AC-20 断点续扫 | `ScanEngine` | ⬜ |
| ADR-10 `.app` 打包 | `scripts/make_app.sh` | ⬜ |

---

## 12. 与基线的偏差登记 + 已知风险

### 12.1 撰写与评审中发现的「PRD 一句话在实现层会被误读」

| # | PRD 位置 | 会怎么实现 | 后果 | 处置 |
|---|---|---|---|---|
| 1 | M4「位槽分配 = 按身份键稳定哈希」 | 把哈希当位槽号 | 位图 375 KB → 百 MB（实测 10 万候选 134 MB） | **已回流**：CR-021 / S18-03 改为「稠密递增序号」 |
| 2 | N5 二次检查 + AC-17 | 产品 `open()` 候选做 lock 探测 → 自己持有该文件 | 自己把自己判成活引用 → `a`/`b` 失真 | **本方案**：IF-03 `excludePIDs` 强制排除自身 |
| 3 | AC-15「实际删除量不超过上限」 | 删完再判 | 累计突破上限 | **本方案**：IF-08 删除前预估 |
| 4 | AC-14 Given 第三类「`lsof` 因权限受限无法判定别的进程」 | 按字面实现需 `lsof` | 不用 `lsof` + 同 uid fd 可读 → **该 Given 的触发面显著变窄**，且「FDA 是否授予」在 macOS 上无可判 API | **登记为偏差，需 CR-022**（本方案不擅自改 AC-14）。建议改法：Given 第三类改为「**同 uid 进程的 fd 枚举失败**」，并把 FDA 从「前置授权」改为「失败后指引」 |
| 5 | AC-15 / M6 未定义「目录的字节」 | 用 `st_size` | 目录 `st_size` ≈ 96 B → **上限判定恒真**、可回收字节失真 | **本方案约定**（IF-07：目录 = 递归逻辑字节）+ 需 R3 用例覆盖。**建议 PRD 补一句**（变更单同 #4 一并提） |
| 6 | **N7 字面「一键清除全部采集与日志」** vs 已裁决「清除不作用于 `a` 的载体」 | 按 N7 字面实现会清掉 `state.residue` | 清掉即「一键洗掉 L0 误判记录」→「错 1 次永久」可被绕过（恒真路径） | **张力必须在 PRD 层解决，不能在实现层私了**：实现按已裁决口径（不清 `state.residue`），同时把 N7 的「全部采集与日志」限定为「**采集物与日志（`records/` + `state/` 下的运行期态与备份），不含 `a` 的载体与状态本体**」→ **偏差 #6，需 CR-022** |
| 7 | M4 的 `a` 判据未限定「持有」的进程范围 | 实现按「全系统进程」理解 | 跨 uid 进程 `EPERM` 不可见 → 判定域含糊；若声称「全系统」则**违反 N5「不把未知判为安全」** | **本方案**：判定域写死 = 同 uid 进程 + 文案只写「本用户进程无引用」；**M4 需补一句限定** → **偏差 #7，随 CR-022 一并提** |

### 12.2 三处「同一数字」的实现风险

第 ⑤ 页 ⑥ 列、AC-08 组 A 文案、AC-09 ⑦ 达标式都要显示 `a`/`b`。**约束**：三处**必须调用同一个 `Metrics.l0Display(a:b:)`**，禁止各自拼字符串（§3「L4 禁止算术」）。

### 12.3 已知能力边界

1. **位槽表体量**（§7.4）：3M 候选 ≈ **336 MB** 状态文件，与 M4 的「约 1 MB 量级」**不一致**（那个量级只算 `F` 位图）→ **PM 裁决项 D-03**。
2. **`P_now` 的判定域 = 同 uid 进程（按 ADR-03 表述，不另立第二套口径）**：其他用户进程（含 root）持有的文件**本产品看不到**（`EPERM`，FDA 不解锁）。**正确说法是「不可见」，不是「无法判定」**——`a` 与删除判定都不依赖跨 uid 结果：① `a` 只用同 uid 的 `F ∩ P_now`，跨 uid 不可见只会「漏保护」不会「误计」；② 举证链 / 报告 / 界面的 L0 结论**只许写「本用户进程无引用」**；③ 候选所在目录**其他用户可写**时，该来源**不进自动删除候选集**（ADR-03 保守化补丁）。→ 需在 M4 补一句，**偏差 #7（CR-022）**。
3. **增量不发现深层新候选**（§7.3）→ 新装包可能等到下一次全量才进清单。
4. **`a` 在目标机器上可能因真实缓存复用 ≥ 1** → 门槛可能长期不可满足（C2 计数制裁决的直后果，已裁决不重开）；**对外文案不得宣称「一定能点亮」**。

---

## 13. 待回填项（V2–V8）

| 编号 | 待确认 | 用法 | 改动面 |
|---|---|---|---|
| V1 | 观察期 14 天（**已裁决**） | 计数日封顶 | `Threshold.observationDays` |
| V2 | 单次容量上限 | IF-08 `capacityCap` | 配置项 |
| V3 | 单次条目数上限 | IF-08 `countCap` | 配置项 |
| V4 | 8 顶层字段 | §5.2 | **不改** |
| V5 | 废纸篓 rename 目标 | IF-07 | 常量 |
| V6 | 「持有」判据 | ADR-03 | 判据集合 | **〔K2 裁定 · 定稿〕V6 = 「该候选的 `(dev, ino)` 出现在任一同 uid 进程的 fd 集合中，或候选（目录）是任一同 uid 进程 cwd 的祖先路径」** |
| V7 | 增量触发条件 | §7.3 | 调度器 |
| V8 | 328 万规模假设 | §7.2 | 仅影响推导 |

---

## 14. 本方案的自我限制

1. **未做真机实测**：§7.2 的 118 s 是推导值；AC-20 实测用例是唯一裁判。
2. **未覆盖 7 页界面细节**：属设计基线（R1.5），本方案只保证「界面不自己算数」。
3. **V2/V3/V5/V6/V7 不代填**：只留一处常量位。

**签字前提（SRE S4）**：§11 映射表里标 ⬜ 的项**必须在 R3 之前清零**（`Retention` / 恢复 / 脱敏 / 断点续扫 / `.app` 打包 五项）。理由很直接：**这五项没有一项是「知道了就能做」，全是「不做就不知道」**——尤其 `Retention` 与恢复，直接决定「删错了能不能救」。**这五项不清零，R3 的用例写出来也是空转。**

---

## 15. v1.1 逐条处置（评审 20 条阻塞）

### 数据存储评审（11 条，全部采纳）

| # | 问题 | 处置 |
|---|---|---|
| 1 | `blobLayout` 只有 3 个全局计数，两来源 6 段偏移不可解 | §5.1 重写为**带 `(kind, sourceIndex, offset, length)` 的段表** |
| 2 | 段序随 `Dictionary` 遍历漂移 | §5.1 `sources` 改**数组 + 声明序**；读方按 `(sourceIndex, kind)` 索引 |
| 3 | 位图段长按置位数算 → 段短、吃掉 `C_done` 头 | §5.1 段长**恒 = `ceil(slotCount/8)`** + 加载期等值断言 `E-304` |
| 4 | 短写 / `ENOSPC` 的 tmp 照样 rename，无错误码 | §8.2 + **`E-303`**：删 tmp、不 rename |
| 5 | `IF-10` 无幂等键、无 fsync → 重复行污染 AC-15 与 M6 | IF-10 补**幂等键 + fsync + 读取侧去重** |
| 6 | 未定义 torn tail 行 | §5.5 增**启动期自愈**（截断到最后一个换行 + 记 `scan.jsonl`） |
| 7 | journal 无 fsync、第 4 个 jsonl 未登记载体 | §5.5 journal **每行 fsync**；`journal.jsonl`/`checkpoints.json` 登记为 `state/` 下**不计 N7 计量**的运行期态 |
| 8 | 回退中断无逐条持久标记 | §5.5 增 `restored` 行 + `trashPath` 存在性校验 |
| 9 | 单写者只声明 `state.residue`、无 `restoring` 态 | §8.1 扩到全部落盘物 + 状态机加 `restoring`；IF-11 在该态**不执行** |
| 10 | `.bak` 不计 M6 / 不进 N7 登记 / 非原子 / 迁移峰值无上限 | §10.3：空间预检 `E-305`、原子 `.bak`、成功即删、**一键清除含 `.bak`/`.corrupt`** |
| 11 | `bytes` 用目录 `st_size` → AC-15 恒真 | IF-07 **目录 = 递归逻辑字节** + `E-207` + `bytesKind` 必填 |
| — | Q6 位槽表 112 B/条（+21.7%，未触发 30% 线） | §7.4 **采纳 112 B**，三档改 34/112/336 MB |

### 客户端评审（9 条，全部采纳）

| # | 问题 | 处置 |
|---|---|---|
| B1 | 无 `.app` bundle / 签名身份 → 登录项、授权、公证三链开发期全废 | **新增 ADR-10**：`scripts/make_app.sh` + `Info.plist` + entitlements；依赖 `.app` 身份的能力只在 `.app` 下验收 |
| B2 | `degraded` 恒 true（跨 uid 恒 EPERM）；`proc_pidinfo` 返回 0 非 −1 | ADR-03：**只枚举同 uid**、**只按 `returned == 0 && errno == EPERM` 判失败**、跨 uid 计入 `coverage.statOtherUID` 不计 degraded |
| B3 | 三条 canary 全部退化为常量 | **ADR-06 重写**：废弃 canary，改「能力探测三问」；**FDA 从前置授权降为失败后指引** → 偏差 #4（CR-022） |
| B4 | 弃用 `lsof` 的理由 ①（O(候选数) 调用）错 | ADR-03 **换理由**：静默丢权导致失败不可归因 + 文本解析串行 + PATH 面；**明写「性能不作为理由」** |
| B5 | `SMAppService.status` 四态未映射；Translocation 下仍显「已启用」 | ADR-02 补**四态映射表** + 启动校验 `bundlePath` |
| B6 | `getdirentries64` 在 arm64 `libSystem` 无符号、编不过 | ADR-04 改 **`readdir` + `d_type`** |
| B7 | §7.3「目录 mtime 变化则重扫」在 uv/npm 上必触发 → 退化为全量 | §7.3 改「**只重取已登记候选属性 + 根/一级 dirent 计数粗差**」，并登记「增量不发现深层新候选」 |
| B8 | 公证 5 处漏项 | §10.1 补全六步（逐个 Mach-O 签、`get-task-allow=false`、`notarytool` 吃 zip、staple 对 `.app`、`.zip` 不可 staple、双验） |
| B9 | `E-301` 在 D2′ 下是死胡同 | §10.2 改**只读降级**，不逼重置 |

---

## 16. v1.2 逐条处置（R2 第 2 轮 20 条）

### 客户端复核（1 条阻塞）

| # | 问题 | 处置 |
|---|---|---|
| B1 | §7.3「每日全量」与「每 7 天全量」并存，快照未绑定 `full` → 若取 7 天分支，`T` 偏小**且静默**（一致性断言只比同一次扫描）→ 新候选可观测天数被截短 → `a` 少记、门槛朝「更易点亮」松 | §7.3 补两句：**开轮后第一次扫描强制 `full`**；此前若发生 `incremental` **不取快照、`T` 保持待重取**。并明确**不擅自区分计数日口径**（与 M1 的边界写在同段） |

### 质量与安全首评（9 条阻塞）

| # | 问题 | 处置 |
|---|---|---|
| B-01 | `a` 判据对「跨 uid 持有」两读（§12.3 说「无法判定」、M4 二值必判「无引用」）→ 预期不唯一、违反 N5 | ADR-03 补**判定域写死 = 同 uid 进程**；**文案只许写「本用户进程无引用」**；**其他用户可写目录的来源不进自动删除候选集**；需改 M4 → 偏差 #7 |
| B-02 | AC-15 目录递归字节：预检在 `rename` 前、内容可变 → 「实际删除量」无取数时点 → 只剩恒真断言 | IF-07 写死两个时点：**预检值 `t1`（首检）/ 实测值 `t2`（`rename` 后 `stat` 废纸篓条目）**，两者都落 `execution.jsonl`；**判据用实测值**；**超出则移回原位 + `blocked_cap` + 停止本轮** |
| B-03 | `E-204` 归「无权限」= 新状态归类错误（§8 封闭三类） | §6 改归 **「错误」**，并注明「不属三类 OS 权限受阻」；检查表 S-03 同步 |
| B-04 | T-2 TOCTOU 无确定性注入点，只能撞微秒竞态 | IF-08 前补**首检/二检时点与构造步骤**：首检 = 扫描时、二检 = 执行前，间隔分钟级 → 用例可确定性构造（扫描 → `tail -f` 持有 → 到执行点），**不接受靠竞态碰运气** |
| B-05 | T-4 零外发在无网 CI 恒真；`otool -L` 对 `URLSession` 假通过 | §9 增 **S-09 三层判据**：源码 grep = 0 / `nm -u` 无 `NSURLSession` 符号 + `strings` 无 `https://` / **有网机器** `lsof -i` + `nettop` 零连接；**无网环境必须显式标注「第 ③ 层未覆盖」，不得默认通过** |
| B-06 | T-7 无上游命令落盘载体 → 「出现次数 = 0」恒真 | §5.4 `scan.jsonl` 增 **`upstreamCommands`**（每次上游调用一行）；**未落盘即视为「无法证明」，验收按不通过** |
| B-07 | 一键清除范围不满足 N7 字面，且漏 `journal.jsonl` / `checkpoints.json`（含路径） | §10.3 清除范围扩到 **`journal.jsonl` + `checkpoints.json` + `migrating.json` + `*.tmp`**；N7 字面与裁决的张力**登记为偏差 #6 → CR-022**（不在实现层私了） |
| B-08 | D-03 裁决材料三处数字不一致（336 / 276 MB）、引用不存在的 §12.4 | 埋点文件 D-03 统一为 **112 B/条 → 34 / 112 / 336 MB**，引用改 **§7.4 + §12.3** |
| B-09 | 检查表 S-02「AC-14 三条受阻各自可构造」与 ADR-06 矛盾（实际 1/3） | 检查表 S-02 结论改为 **「需验证（仅『来源不可读』可构造；`lsof` 受限一类因不用 `lsof` 已失去触发物）」**，与偏差 #4 同源 |

### 发布与运维首评（10 条阻塞）

| # | 问题 | 处置 |
|---|---|---|
| 1 | 发布准入只验签名链，无端到端装机检查 | §10.1 新增第 7 条：**干净机 + 先断网 + 保留 quarantine + 拖入 `/Applications` + 首扫 + 登录项触发一次 + 卸载可执行** |
| 2 | 无 SHA-256 对账、无上一版归档 → 回滚无包可下 | §10.1 新增第 8/9 条：**重新下载再算一次**；**无上一版归档不许发布** |
| 3 | 回滚后只读、清理能力 0，两条出路被封死 | §10.2 补**只读四条硬要求**：未知字段渲染「—（由更高版本维护）」、顶部说明「不能执行清理」、出路只有「装回更高版本」、**回滚是降级不是等价替代**（须写进 README 已知限制） |
| 4 | 回滚无演练条款 | §10.2 补**回滚演练**：每次发布前用上一版归档在干净机演练「装旧版→升级→回滚→只读→重装新版」，判据四条，**未演练不许发布** |
| 5 | 只读模式把 `a` / `countedDays` 按默认 0 读 → 显示「一次都没错」（假值） | 同上第 1 条硬要求（**不得渲染为 0**） |
| 6 | 预检 `2×+20%` 实际峰值 3×336 = 1008 MB，缺口 200+ MB → 迁移末段必 `ENOSPC` | §10.3 预检改 **`≥ 3 × 状态文件 + 64 MB`**，并写明缺口原因 |
| 7 | 无 `migrating` 标记、状态机无该态，断电三态难辨 | §10.3 增 **`state/migrating.json`（带 `step`）**；补**断电三态判定**；**禁止「见 `.bak` 即删」与「见 `.bak` 即回滚」** |
| 8 | 恢复本身失败无码、无指引、无只读分支 → 每次启动重试迁移 | 新增 **`E-306`**：进入只读（可看可导出、不可写不可清理）+ 指引 |
| 9 | `E-302` 文案「需重置本地状态」与 §10.2「不引导重置」逐字相反 → 一次 CRC 损坏就能洗白安全凭证 | `E-302` 文案改为「已备份为 `.corrupt`，请先导出报告」；**重置改为显式二次确认**，且确认框须写明「会清零 L0 误判记录，等于给自动删除放行」 |
| 10 | 导出报告只定脱敏、未定内容；`degraded` / `coverage` / `P_now` 不落盘 | IF-12 补**报告五段内容**（环境 / 量 / 取证 / 证据 / 上游），**缺任一段即视为报告不可用**；取证段来源 = `scan.jsonl.diagnostics`（既有状态回显，不新增采集） |

**建议项处置**：S1 用户恢复动作回写（`action = restored_by_user`）✅ ｜ S2 一键清除补 `journal` / `checkpoints` / `*.tmp` ✅ ｜ S3 `E-303` / `E-305` 文案给可执行动作与具体数字 ✅ ｜ S4 §11 的 ⬜ 五项（`Retention` / 恢复 / 脱敏 / 断点 / `.app` 打包）**R3 前必须清零**（写入 §14 签字前提）✅ ｜ S5 journal `begin` 补 `appVersion` / `round` / `trigger` ✅

---

## 17. v1.3 逐条处置（闭环轮：5 条未闭环 + 7 条新阻塞）

第 2 轮闭环核验结果：**未闭环 5 条**（数据 #6；质量 B-01 / B-03 / B-08；运维 #7）+ **新阻塞 7 条**（数据 2、客户端 3、质量与运维 2）。全部采纳。

| # | 来源 | 问题 | 处置 |
|---|---|---|---|
| 1 | 数据 #6（未闭环） | §15 声称「§5.5 已加 torn tail 自愈」，**正文却没有**——处置表与正文不符（我自己的老毛病：写了登记、漏了正文） | §5.5 补实**六步自愈协议**（找末换行 → 试解析 → `ftruncate` → 记 `recordRepair` → 不补全 → 业务后果登记） |
| 2 | 数据新 1 | §5.1 校验② `Σ段长 + 头部长 == 文件长 − 8` **恒差 4 B**（漏算 `segCount` 与段表自身）→ 每份合规文件都判 `E-304` → 用户被推向「重置」清 `a` | 改为**完整尺寸恒等式**：`4+4+4+headerLen+4+16×segCount+Σpayload+4`；并写明**段表大小 = 16×segCount 是常量** |
| 3 | 数据新 2 / 运维 #7 / 质量 N1 | 断电三态用「原件 CRC 完好」判「迁移未完成」——**迁移成功后原件 CRC 同样完好** → 二次迁移 + 删掉唯一 `.bak`；`step` 更新时点未定义 | 新增 **`step` 1–5 的写入时点表**；恢复判定**按 `step`**：`{1,2}` 先确认目标可加载再删 `.bak`（防删唯一副本）、`3` 直接回旧件、**`{4,5}` 判「目标是否已是 `toSchema` 且 CRC 通过」** 而不是判原件 |
| 4 | 客户端新 1 / 质量 N2 | §10.1 第 7 条要求断网从 `.dmg` 装，但 **`.dmg` 从未公证** → Gatekeeper 对映像本体拒（`.app` 的票据救不了容器） | §10.1 补**前提条款**：每个分发载体各自签名+公证+`staple`；**首发建议只发 `.zip`**；判据改「**除系统授权对话框外**零人工干预」 |
| 5 | 客户端新 2 | §7.3 新增「`T` 待重取」在 §5.1 无表示（`"T": 0`）→ 写 0 则 `H = min(30,0) = 0` 门槛恒过、界面显示假 0 | §5.1 header 改 **`T/H/K/J` 可为 `null`** 并附 `note` 说明每个 null 的语义（`T=null` = 未取快照、`K/J=null` = 报告未产出） |
| 6 | 客户端新 3 | §10.1 第 9 条 + §10.2 演练互为前提：**首发无「上一版」自锁**；未跳 `schemaVersion` 的版本回滚后根本不进只读 → 演练判据「只读提示可见」不可达 | 第 9 条加**首发例外**（演练对象 = 本版自身：装→卸→重装）；§10.2 演练判据**按是否变更 schema 分两支** |
| 7 | 质量 B-01（部分） | §12.3 第 2 条仍把跨 uid 说成「无法判定」，与 ADR-03 的「不可见」两读 | 改写为**按 ADR-03 单一表述**，并写清「`a` 与删除判定都不依赖跨 uid 结果」 |
| 8 | 质量 B-03（部分） | 技术方案 §9 的 S-03 行仍是旧措辞（只改了 §6 与检查表） | §9 S-03 行同步为「记 `E-204`，归 §8「错误」类」 |
| 9 | 质量 B-08（部分） | D-03 裁决材料数字 | 已在埋点文件统一为 **112 B/条 → 34 / 112 / 336 MB**，引用改 §7.4 / §12.3 |
| 10 | 质量补 | 只读态是否产出 AC-09 报告未写 → 会被读成「等一会儿就有」 | §10.2 补「**只读态不产出 AC-09 报告**，第 ⑤ 页显示「只读，不结算」而非「本轮未结算」」 |

**一条给自己的复盘**：第 1 条（数据 #6）是**同一个毛病第 N 次复发**——「在变更清单/处置表里写了已修，正文没落地」。这与 PRD 阶段第 15 轮 `Q26` 完全同型（当时也是「声称已实删、实际没删」）。**治法已经有的（`verify_claims.py` 那套「声明 → 全文命中数」核验）没有用到 R2 文档上**——这是流程缺口，不是笔误。R2 冻结前必须补一个同等机制的校验脚本。

---

## 18. v1.4 逐条处置（终审轮：2 未闭环 + 3 新阻塞 + 1 未闭环）

| # | 来源 | 问题 | 处置 |
|---|---|---|---|
| 1 | 质量 B-03（第 2 次未闭环） | `E-204` 有**三套判据**：§5.3 的 `action` 枚举里没有越界项、§6 判据写 `action = failed`、检查表 T-1 要求 `blocked_*` → 按 T-1 字面写用例必假失败 | §5.3 枚举加 **`blocked_out_of_scope`**（并写明为何不能复用 `failed`）；§6 判据改指向它；检查表 T-1 同步 |
| 2 | 质量 B-08（第 2 次未闭环） | 检查表 §四第 2 行仍写「3M 候选 ≈ 276 MB」，与 336 MB 并存 | 改 **336 MB（112 B/条）**，并标注旧值作废；`verify_r2.py` 补上「检查表也在校验范围内」 |
| 3 | 质量：`E-304` 后果链；`E-302` 只保留「无可用 `.bak`」一种情形，恢复成功另立 `E-308`（终审 N-1） | `E-304` 文案「同 `E-302`，但不自动重置」**继承了重置入口**，而 `E-304` 自身无自愈路径 → 唯一出口就是重置，正是 §10.2 禁止的；且「不自动重置」半句会让人反读成「`E-302` 会自动重置」 | `E-304` 改为**保留现场 + 只读 + 导出指引**，明确「不提供重置入口、不自动重置」；`E-302` 补「且无可用 `.bak`」，两者不再互相引用 |
| 4 | 数据/质量新阻塞 | §5.1 写 `16×segCount`，但同句字段相加是 **24 B**（1+1+6+8+8）→ 按字面实现**每份合规文件仍判 `E-304`**（修法自己复发） | 统一为 **24 B/段**（`offset u64 | length u64 | kind u8 | sourceIndex u8 | reserved u16 | reserved u32`，8 字节对齐、无隐式 padding），并给出**算例 1536 B** |
| 5 | 数据新阻塞 | `step=4` 写在 `rename` **之后** → 断电落 `step=3` 分支 → 该分支假定「目标仍是旧件」、**无条件删唯一 `.bak`** | `step=4` 改为「**即将 rename**（rename 前写入）」、`step=5` 为「rename 完成」；`step=3` 分支**先断言 `目标.schemaVersion == fromSchema`**，不等则改走 `step=4`；并加**全局前置守卫**：任何删 `.bak` 的分支都先确认「目标存在且可加载」 |
| 6 | 质量新阻塞 | §10.1 第 9 条首发演练要求「数据目录彻底清空 / 装后初始态」，与 **S-10（一键清除不清 `state.residue`）** 和 **M4（`a` 只在版本变更时清零）** 互斥 → 首演按设计必失败 | 明确区分两个动作：**「一键清除」= 产品内动作、不清 `state.residue`**；**「卸载」= 用户手动删除整个数据目录**。**首演判据只挂「卸载」** |

**本轮性质**：这 6 条里有 4 条是「**修法的副作用**」——不是我原来的错，是我改的过程中新造出来的（`16×segCount` 与字段矛盾、`step=4` 写错位置、`E-304` 继承重置入口、首演判据挂错动作）。**这印证了一件事：每轮修订都要按「改动的下游影响」重新过一遍，而不是只看被点名那一处。**

**至此 R2 的机械校验覆盖面已补齐**：`verify_r2.py` 现在校验三份文档（技术方案 + 检查表 + 埋点），共 100+ 项断言，其中「落地」48 项（每条修法必须有正文对应）、「归零」10 项（旧措辞不得留在生效正文）、「跨文档一致」10 项。

---

## 19. v1.5 逐条处置（终审第 2 轮：2 条新阻塞，均为 §18 改动自造）

| # | 编号 | 问题 | 处置 |
|---|---|---|---|
| 1 | N-1 | §18 给 `E-302` 加了「且无可用 `.bak`」，但 §10.3 矩阵 ⑥ 与「目标损坏」分支仍写「从 `.bak` 恢复 + `E-302`」→ **「迁移失败但备份恢复成功」这条最常见主路径没有码可用** | 新增 **`E-308`「已从 `.bak` 恢复成功」**（提示级、非致命），并把 §10.3 两处分支改为：**恢复成功 → `E-308`；无可用 `.bak` → `E-302`；恢复过程失败 → `E-306`** |
| 2 | N-2 | §18 只统一了段表**字节数**（24 B），但 §5.1 的**示意块字段序**仍是 `kind, sourceIndex, offset, length`，与校验① 的 `offset | length | kind | sourceIndex | reserved` 不同 → 总量同为 24 B、算例不受影响，但**读写各按一处必然字段错位**，且 CRC 查不出（错位读到的是合法字节） | 示意块字段序**逐字对齐校验①**，并注明「字段序必须与校验① 完全一致，否则读写各按一处必然字段错位、CRC 查不出」 |

**为什么这两条值得单独记一笔**：它们都是「**同一事实写在两处、只改了一处**」——在 R2 里这是第 6 / 第 7 次复发（前面是 `16×segCount` 与字段相加、`E-204` 的三套判据、276 MB 与 336 MB、`T` 的 0 与 null）。**规律很清楚：凡是「一个数字 / 一个枚举 / 一个字段序」出现在两个地方，就必须在两处同时改，且必须由机器断言两处一致——靠人眼核对，一定会漏掉一处。**

**这也解释了为什么 R2 走了 5 轮**：每一轮的新阻塞都不是「原来漏了什么」，而是「上一轮修法带出来的口径分裂」。**修法本身也是产出，也需要被当作产出评审。**

---

## 20. v1.6 逐条处置（K2 交底 14 条异议的落地）

### 客户端 5 条

| # | 异议 | 处置 |
|---|---|---|
| 1 | A-4 断点水位方案实测失败（漏 70%） | **§5.5 改为「已完成名字集合 + 三项摘要自证」**；契约签名与 AC-20 验收口径不变 → **不重开 R2**；A-4 工时 3 → 3.5（见 K2 裁定） |
| 2 | A-9 视觉输入缺失 | 采 (a)「七页骨架 + 语义位占位」；**另出最小视觉基线**（`Residue-视觉基线-最小集-v1.0.md`）；完整 R1.5 仍缺，**R3.8 前必须补** |
| 3 | A-7 载体归属未定 | **裁定 (i) 改造**：现有 `state.json` 直接改造成 `state.residue`，**老数据可丢弃、不写迁移读路径**（开发期产物，从未发布）；不产生两个真相源 |
| 4 | `DT_UNKNOWN` 在 APFS 上不可构造 | 验收口径改为「**`M_unknown` 计数机制存在且被单测覆盖（注入构造）**」；产品**保留**退回 `lstat` 的兼容路径；§7.2 该行改为「实测 0，保留退回路径」 |
| 5 | `vnodeid` 字段不存在 | **ADR-03 / IF-03 改为 `(dev, ino)`**；连带写死 `PROC_PIDLISTFDS` 的返回值语义（**8 B/项**、fd 号 = 下标）。**〔2026-11-08 · A-6 实测更正〕原写「24 B/项」是错的**（那是段表项尺寸） |

### 质量 9 条

| # | 异议 | 处置 |
|---|---|---|
| 1 | AC-19 命令白名单不封闭 | **给出封闭白名单**（6 条命令 + 参数形态 + 归属来源；`uv cache clean --dry-run` 明确**不纳入**）；白名单外 → `E-107`，不删除不点亮。**白名单本体见 K2 交底裁定 §二·异议 1** |
| 2 | AC-16 与 B-1「逐条覆盖」冲突 | **B-1 验收口径改**（交底单层面）：AC-16 挂「本期不交付」说明行；冻结 PRD 不动 |
| 3 | V2 / V3 / V6 未定稿 | **V6 定稿**（§13）；**V2 / V3 待用户拍板**（业务取舍，非技术事实）——在拍板前，用例按「注入位 + 判据结构」冻结、数值后填 |
| 4 | 缺三类注入点 | **新增 §9.5 测试注入点约定**（5 个注入点 + 三条不可放宽的边界）；§10.1 增第 10 条 Release 剥离检查 |
| 5 | AC-15 预检取值来源两读 | **IF-08 写死两行**：预检取值 = `t1` 预览值（随候选缓存到执行点）；两种拦截的动作值 / 原因串值域封闭 |
| 6 | AC-07「内容读取数为 0」无载体 | **§5.4 `diagnostics` 增 `contentReads` 计数位** |
| 7 | AC-08 ②″/②‴「未取得 FDA」态不可观测 | **Given 改为「该来源同 uid 进程枚举失败（`E-501`）」**（真实可达）；**文案改为「L0 未判定（无法枚举本用户进程）」**（§6 `E-501` 行）；这两条用例**不降级** |
| 8 | AC-10 进程级表述与 ADR-02 冲突 | **ADR-02 统一为任务级**（「无常驻采样任务在运行」）；冻结 PRD 侧走 CR-022（**同一事实两处写，只改一处**） |
| 9 | B-1 工时不足 | **B-1 = 4.5 人日**，B 组合计 9 人日；**B 组交付物 = 用例基线文档（冻结）**，执行期不计入本阶段 |

### 新增的两条偏差（并入 CR-022）

| # | 位置 | 问题 |
|---|---|---|
| 10 | AC-10 | 进程级「无常驻监听进程」→ 改任务级「无常驻采样任务」 |
| 11 | M4 / AC-08 / AC-09 | 未判定态文案「未取得 Full Disk Access」→ 「无法枚举本用户进程」；未判定态的**可观测代理 = `degraded = true` / `E-501`** |
| 12 | AC-07 | 「内容读取记录数为 0」→ 判据载体 = `scan.jsonl.diagnostics.contentReads` |

**CR-022 累计 7 条偏差**（原 4 条 + 本轮 3 条）。

**〔2026-11-08 · 用户拍板「7 条全部采纳」· 已落地 `Residue-PRD-v5.4.md`〕** 本表 7 条**全部已回流 PRD v5.4**（逐条定点改 + 落点穷举表穷举 + 机器校验 `verify_cr022.py` 40 项全绿）。对应关系：

| 本表偏差 | PRD v5.4 落点 | 状态 |
|---|---|---|
| #4（AC-14 第三类 Given） | AC-14 · Given / 判定 | ✅ 已回流 |
| #5（AC-15 / M6 目录字节） | AC-15 判定 + M6 · 读数源 | ✅ 已回流 |
| #6（N7 一键清除范围） | N7 | ✅ 已回流 |
| #7（M4 持有判定域） | P-L0「持有」判据表 | ✅ 已回流 |
| #10（AC-10 进程级→任务级） | AC-10 · Then / 判定 | ✅ 已回流 |
| #11（未判定态文案） | §6 第⑤页 ×2 + AC-08 组 A + ②″/②‴ + P-L0 | ✅ 已回流 |
| #12（AC-07 载体） | AC-07 判定 | ✅ 已回流 |

**落地时的两处口径对齐**（PRD 侧措辞与本方案侧**逐字一致**，由 `verify_cr022.py` B 段机器断言）：
① N7 的清除范围 = 「采集物与日志（`records/` + 应用状态目录下的运行期态与备份：含 `journal.jsonl` / `checkpoints.json` / `migrating.json` / `*.bak` / `*.corrupt` / `*.tmp`），**不含 `a` 的载体与状态本体**」——与本方案 §10.3 一致；
② 「一键清除」（产品内动作，不清 `state.residue`）与「卸载」（用户手动删目录）**两个动作不可混同**——与本方案 §10.1 第 9 条一致。

---

## 21. Phase 3 实现层记录（A-6 · L0 探测）

**〔2026-11-08 · 客户端工程师实现 · 已完成〕** A-6「L0 探测 `L0Probe`」已实现：`Sources/ResidueCore/L0Probe.swift`（16 个单测，`swift test` **108 项全绿**）。

### A-6 验收四问的达成

| K2 验收问 | 达成方式 | 断言位置 |
|---|---|---|
| ① 「本用户进程无引用」判定正确 | 子进程持有文件 → 父进程按 `(dev, ino)` **精确命中**倒排表；且 `dev`/`ino` 与 `stat()` **逐一相等** | `testOpenFileIsDetectedAsHeldByAnotherProcess` / `testTableIdentityMatchesStatExactly` |
| ② 跨 uid 不计入 `degraded` | 跨 uid 进程恒 `EPERM` → 只计入 `coverage.statOtherUID` | `testCrossUIDDoesNotSetDegraded` |
| ③ 自身 fd 不计入 `P_now` | `excludePIDs` 默认并入自身 pid；倒排表的**持有者列表**过滤排除项 | `testExcludeSelfRemovesOwnFds` / `testSelfIsAlwaysExcludedByDefault` |
| ④ `degraded` 只在同 uid 失败时为 true | 同 uid 枚举失败且 `errno == EPERM` → `degraded = true`；跨 uid 不计 | `testDegradedOnlyWhenSameUIDFails` |

### 实现层实测抓到的 4 个契约缺陷（**原方案 v1.6 有 3 处写错**）

| # | 原方案写法 | 实测真相 | 若按字面实现的后果 |
|---|---|---|---|
| 1 | `PROC_PIDLISTFDS` 每项 **24 B** | **8 B**（`struct proc_fdinfo` = `int32 fd` + `uint32 type`）；24 B 是 `state.residue` **段表项**的尺寸，被误套过来 | 读进 **3 倍脏数据** → fd 号全是垃圾 → **L0 恒判「无活引用」→ 误删正在被使用的文件** |
| 2 | `PROC_PIDFDVNODEPATHINFO` 的返回结构未写死 | **`struct vnode_fdinfowithpath`**（= `proc_fileinfo pfi` 24 B + `vnode_info_path pvip`），**`pvip` 偏移 24** | 误按 `vnode_info_path` 解析 → 把 24 字节头当 `vi_stat` 开头 → 读出 **`dev=1, ino=0` 垃圾** → 与 `stat()` 永远对不上 → **L0 恒判无引用 → 误删活文件** |
| 3 | 未写缓冲区大小要求 | 须 ≥ **`PROC_PIDFDVNODEPATHINFO_SIZE` = 1200 B**；传 1024 → `errno=ENOMEM` 失败；传 1176（`sizeof(vnode_info_path)`）**也失败** | fd 枚举全部失败 → 倒排表恒空 → **L0 恒判无引用** |
| 4 | 身份「`(dev << 32) \| ino` 编码成 `UInt64`」 | `vst_ino` 是 **`uint64`**、`vst_dev` 是 `uint32` → **塞不进 64 bit 会截断 `ino` 高位** | 不同文件撞成同一身份 → 倒排表**误命中** → 误判活引用 / 误删活文件。**实现改为保留二元组** `FileIdentity` |

> **这 4 条的共同形态**：**都不是「文字写错」，是「按字面实现会静默产出错误数据」**。
> 与 R2 五轮评审吃过的亏同源（「修法自造」：改一处、另一处的旧假设没跟着改）。
> **教训**：技术方案里的**实现级数字与结构体名**必须由**实现者实测复核**，
> 不能靠评审读文字——评审能看出「自相矛盾」，看不出「24 B 其实不是这个结构的尺寸」。

### 实测方法（可复用）

用 **C 程序 + `fcntl` 地面真值**反推内核 ABI，比读 SDK 头文件可靠：
1. `PROC_PIDLISTFDS` 返回字节数 → 除以候选 stride → 与 `fcntl(fd, F_GETFD)` 扫出的真实 fd 集合**逐一比对**；
2. 未知布局时，在返回缓冲里**搜索 `stat()` 的 `st_ino` 值**（8 B 滑窗）→ 直接得出字段偏移；
3. 再回 SDK 查「哪个结构体的字段序能解释这个偏移」→ 确认是 `vnode_fdinfowithpath` 而非 `vnode_info_path`。

**「打印内部状态 / 找地面真值」比「改一版看结果」快一个数量级**（同 ScanEngine 断点那次诊断）。

---

## 22. Phase 3 实现层记录（A-7 · 状态载体升级）

**〔2026-11-08 · 客户端工程师实现 · 已完成〕** A-7「状态载体 `StateStore` 升级」已实现：
- `Sources/ResidueCore/ResidueStateFile.swift`（二进制编解码器 `StateFileCodec` + `StateHeader` / `SegmentDescriptor` / `SourcePayload` / `CRC32`）
- `Sources/ResidueCore/StateFile.swift`（IO 层：原子写 / 加载 / 错误码映射）
- `Tests/ResidueCoreTests/StateFileTests.swift`（**25 个单测**）

`swift test` **133 项全绿**（92 → 133：+16 A-6、+25 A-7）。

### A-7 验收五问的达成

| K2 验收问 | 达成方式 | 断言位置 |
|---|---|---|
| ① 尺寸恒等式成立 | `fileLen == 4+4+4+headerLen+4+24×segCount+Σpayload+4`，并复算 §5.1 的算例（`headerLen=300, segCount=9, Σpayload=1000` → **1536 B**） | `testSizeIdentityHolds` / `testSectionFivePointOneWorkedExample` |
| ② 段长恒 = `ceil(slotCount/8)` | 位图长度**只由 `slotCount` 决定**（置 1 位与全置位产出**逐字节相同**的文件）；长度不符 → `E-304` | `testBitmapLengthDependsOnlyOnSlotCount` / `testBitmapLengthMismatchTriggersE304` |
| ③ 短写 / ENOSPC 不 rename | 写 `.tmp` → `fsync` → **校验落盘长度 == 预期** → 不符则抛 `E-303` 且**不 rename**；另加空间预检（`E-305`） | `testShortWriteDoesNotReplaceGoodFile` |
| ④ `T/H/K/J` 可为 null | `T/H/K/J` 为**可选**，`nil` 往返保持；**null ≠ 0**（写 0 会让 `H=min(30,0)=0` 门槛恒过） | `testNullableMetricsRoundTrip` / `testNullIsDistinctFromZero` |
| ⑤ 迁移断电按 `step` 恢复、不删唯一 `.bak` | `.bak` **始终存在**（每次写入更新但不被删）；迁移恢复走 `tryRestoreFromBackupForMigration()`，恢复成功 → `E-308`；无可用 `.bak` → `E-306` | `testBackupIsNeverDeleted` / `testRestoreFromBackupReportsE308` / `testMigrationRestoreFailsWithoutBackup` |

### 实现层抓到并修正的 3 个缺陷

| # | 缺陷 | 后果 | 修法 |
|---|---|---|---|
| 1 | **`FileManager.moveItem` 不覆盖已存在的目标** | **第二次写入必然失败**（报「已经存在同名项目」）→ 载体根本写不进第二份数据 | 改用 `replaceItemAt`（**同卷原子替换**） |
| 2 | **`E-304` 被实现成「降级成 `E-302`」** | v1.3 的旧病复发：`E-302` 带「重置本地状态」出口，而 `E-304` **自身无自愈路径** → 唯一出口变成重置（§10.2 禁止的那条） | `E-304` = **保留现场 + 只读**，**不因「无可用 `.bak`」而降级**；`E-308` 归到**迁移路径**，不作为段校验的兜底 |
| 3 | 清零后仍写来源条目 | 解码时「来源有头部条目但无段」→ 校验不一致 | 清零后**不写任何段**（无载荷 = 无数据 = 已清零）；`a` / `slotCount` 归零 |

### 与 §5.1 的一致性

- **段序固定** = `Source.allCases` 声明序，**不用 `Dictionary`**；读方按 `(sourceIndex, kind)` 索引，**不按位置猜**。
  断言「同输入产出**逐字节相同**的文件」——Swift 每进程随机哈希种子，用 Dictionary 会让段序逐进程漂移。
- **加载期校验三连**：尺寸恒等式 / 越界 + 重叠 + `offset ≥ 段表末尾` / CRC32 一致。任一失败 → `E-304`，**不猜、不部分加载**。
- **CRC 覆盖 `header + segTable + payload`**，不含 magic / 长度字段 / CRC 自身。
- **位槽占用表必须落盘**（否则候选被手删后重建会落回旧槽、继承旧 `F` 位 → `a` 恒 ≥ 1）。

---

## 23. Phase 3 实现层记录（A-5 打包 + A-8 上游命令与日志）

`swift test` **148 项全绿**（92 → 148：+16 A-6、+25 A-7、+15 A-8）。

### A-5 · `.app` 打包（ADR-10）

**产出**：`scripts/make_app.sh`（七步）+ `scripts/verify_a5.sh`（可重复验收）+ `Resources/Info.plist.in` + `Resources/entitlements.plist` + `Sources/ResidueApp/ResidueApp.swift`（最小 SwiftUI 菜单栏 app）。

**结构部分 20 项全达成**：bundle 四件套齐 / `Info.plist` 六个必需键齐 / `LSUIElement = true`（菜单栏常驻、无 Dock 图标，与 ADR-02 一致）/ `codesign --verify --deep --strict` 通过 / **Hardened Runtime 已启用** / 逐 Mach-O 已签 / 无 `get-task-allow=true` / **无 `com.apple.security.*`**（非沙盒 + 零外发）/ 无 `RESIDUE_TEST_` 残留 / arm64 + `minos 14.0` / `zip` 解开后签名完好。

**未覆盖 3 项（如实登记，不算通过）**：
- ① 可 `stapler staple` —— 本机 `security find-identity` **0 个身份**，无法公证
- ② `SMAppService` 不抛签名错 —— ad-hoc 下必抛 `kSMErrorInvalidSignature`（**预期行为，不是缺陷**）
- ③ TCC 面板能认到 —— 需 GUI 会话人工确认

**这 3 项与公证 / 钉票 / 端到端装机同属 A-10，必须在有真身份的机器上完成。**

#### 打包时踩到的 2 个坑（都已修进脚本）

| # | 坑 | 现象 | 修法 |
|---|---|---|---|
| 1 | **plist 注释里出现 `--`（双连字符）** | `codesign` 报 `AMFIUnserializeXML: syntax error near line 27` → **签名失败**。XML 规范禁止注释内含 `--`，而注释里写了 `codesign -d --entitlements` | 注释改写为不含 `--` 的表述；脚本内注明该禁忌 |
| 2 | **直接执行 GUI app 做冒烟** | SwiftUI `App` 生命周期进 run loop **永不返回** → 脚本被超时杀掉（`exit 137 = SIGTERM`） | 冒烟改为验 **架构 / `minos` / Hardened Runtime / bundle 结构**，不执行主可执行 |

> **第 2 条是「换入口」带出的连带失效**：入口从 `print` 占位换成 SwiftUI 后，原来能跑的冒烟步骤悄悄变成「挂死」。**换实现要让脚本跟着换判据，不能默认旧判据还成立。**

#### 附带修正：入口从占位换成真 app
原 `main.swift` 是 `print` 占位，**没有 GUI 身份**——而 A-5 验收②③（`SMAppService` / TCC 面板）**都要求真实 GUI app**，用占位入口根本无法验证。现改为 `ResidueApp.swift`（`MenuBarExtra`，`LSUIElement = true`）。实测：`open build/Residue.app` → 进程存活 > 3 s（未崩溃、已入 run loop）；`spctl --assess` 返回 `rejected`（ad-hoc 的预期结果，真身份下应 `accepted`）。

### A-8 · 上游只读命令 + 记录落盘（AC-19 / §5.4）

**产出**：`Sources/ResidueCore/UpstreamCommand.swift`（白名单 + runner）+ `Sources/ResidueCore/RecordWriter.swift`（`scan.jsonl` / `execution.jsonl` / `evidence.jsonl`）+ `Tests/.../UpstreamAndRecordTests.swift`（15 测试）。

#### 白名单是**封闭集合**，不是黑名单
AC-19 要求「直接删文件的上游命令出现次数 = 0」——这是**全称命题**，只有白名单能证。判据 = **可执行名匹配 且 参数从头前缀匹配**：
- 只按可执行名匹配不够——`uv cache dir`（放行）与 `uv cache clean`（必拒）是同一个可执行
- 只按「参数包含」不够——`uv --verbose cache dir` 不该被当成白名单条目

实测拦住的破坏性命令：`uv cache clean` / `uv cache prune` / `npm cache clean --force` / `brew cleanup` / `rm -rf` / `trash-put` / `mv` / `find -delete` / `sh -c "rm -rf"`。
放行的只读命令：`uv cache dir` / `npm cache ls` / `npm config get cache` / `brew --cache` / `pipx list` / `pipx environment`。

#### 两条不可妥协
1. **被白名单拒绝的调用也必须产生一条记录** —— 否则「有人试图跑删除命令」这件事查不出来。
2. **必须真落盘（`fsync`），不接受「攒内存最后统一写」** —— §5.4：未落盘即「无法证明」，验收按不通过；而「最后统一写」的那一次退出可能永远不来。

#### `diagnostics.contentReads` 使 AC-07 由恒真变为可证伪
扫描阶段只读元数据不读内容 → `contentReads` **恒为 0**；**非 0 即说明实现越界读了内容**。测试同时断言「0 可读」与「非 0 也可读」——只断言 0 会让该判据重新变成恒真。

---

## 24. Phase 3 实现层记录（A-9 · 七页 UI 骨架）

`swift test` **171 项全绿**（92 → 171：+16 A-6、+25 A-7、+15 A-8、+21 A-9、+2 补断言）。`verify_a9.sh` **31 项全过**。

**产出**：
- `Sources/ResidueCore/SemanticSlot.swift`（语义位类型化 + `UICopy` 契约文案）
- `Sources/ResidueApp/DesignTokens.swift`（视觉基线 §一/§二 逐条落地）
- `Sources/ResidueApp/Components.swift`（`SemanticSlotView` / 卡片 / 七态标签 / 自建按钮与开关）
- `Sources/ResidueApp/PageModel.swift`、`Pages.swift`（七页）、`RootView.swift`（外壳）
- `Sources/ResidueApp/PageRenderer.swift`（离屏渲染七页，**DEBUG-only**）
- `scripts/verify_a9.sh`（31 项机器校验）
- `design-renders/*.png`（七页实际渲染产物，供 R3.8 逐页对照）

### 把「界面禁止算术」变成机器断言（A-9 的主目标）

`SemanticSlot` 定义在 **ResidueCore**（可被单测约束），且：
- **不含闭包**（闭包 = 允许任意运算，类型约束失效）——`verify_a9.sh` 断言
- **`.ratio(a, b)` 两个值原样保留**，不归一化成比值/百分比——单测断言
- **`.duration(nil)` → 「—」不是 0**——`0` 会被读成「今天到期」
- **`.unavailable` 是正式槽位值**，不是空串
- UI 层**不得出现域内度量运算**（`slotCount` / `countedDays` / `missCount` / `pNowCount` / `fSetBits` 参与算术）——脚本 grep 断言

> **一个刻意的例外要说清**：`.count - 1` 这类是**数组下标边界**（取最后一个元素），属合法布局运算，不是「对域内度量做减法」。判据写太粗会误报——第一版脚本就误报了 `ReportMatrix.columns.count - 1`。

### 实现层抓到的 4 个真缺陷

| # | 缺陷 | 现象 | 根因与修法 |
|---|---|---|---|
| 1 | **`MetricUnit.bytes` 只给了「字节」一档** | 显示 `2400000000B`，完全不可读 | 把「人可读格式化」下沉到 `MetricUnit.formatBytes`（**唯一一处**，仍在 Core 内、界面不参与）。这是把「界面不换算」做成了「换算只有一处」，而不是「没人换算」 |
| 2 | **`ScrollView` 在离屏渲染下内容全空** | ③ 页整页空白、⑤ 页矩阵整块空白 | 7 页内容在 1000×640 下都放得下 → 骨架阶段改用 `VStack` 直排。**已在注释里写明「②/⑦ 列表超一屏时必须加回 ScrollView，届时改用真实 GUI 会话验证」**，不假装已覆盖 |
| 3 | **系统按钮 / 系统开关渲染成黄色「禁止」占位符** | `.bordered` / `.borderedProminent` / `.toggleStyle(.switch)` 全部退化 | 自建 `PrimaryButtonStyle` / `DangerButtonStyle` / `SecondaryButtonStyle` / `TokenSwitch`。**这同时也是设计一致性要求**：系统控件用系统强调色与系统圆角，token 不起作用 |
| 4 | **开关轨道用了 `surface` 色，与卡片背景同色** | 开关只剩一个孤立圆点、轨道不可见 | 「关」态轨道改 `textSecondary.opacity(0.35)`——仍在既定色板内，不引入第三种色 |

### 逐页实际渲染核对（不是只看代码）

本机是**无头会话**（`screencapture` 拿到全黑图），所以加了一个 **DEBUG-only** 的渲染入口：

```
swift run ResidueApp --render-pages <dir>
```

用 `ImageRenderer` 把七页渲染成 2000×1280 PNG，逐张看过并修掉上面 4 个缺陷。产物在 `design-renders/`。

**七页现状（逐页核对结论）**：

| 页 | 状态 | 核对到的要点 |
|---|---|---|
| ① 存储总览 | ✅ | 三区块横排，值为 `2.4 GB` / `860 MB` / `140 MB`（人可读），标签小字 + 数值 17 pt 有层级 |
| ② 环境与候选 | ✅ | 每行「路径 + 参与度徽标 + 字节」；`可参与自动删除` 用信号色、`仅报告` 用次文字色；分页「第 1 / 3 页」 |
| ③ 清理策略 | ✅ | 开关本体可见（关态灰轨道）；未达项 `第 2 轮 · 观察期 5/14 天` 与剩余 `9 天` 同址；两个语义位分两张卡、不重叠 |
| ④ 授权与隐私 | ✅ | 清除范围说明含「不重置观察期进度与 L0 误判记录」；主按钮信号色 |
| ⑤ 观察期报告 | ✅ | 七列三行完整；③ 列两行冻结时点标注（`总量冻结：开轮时` / `样本冻结：报告产出时`）；页级「本轮可点亮：否」+「报告已产出」 |
| ⑥ 确认清理 | ✅ | 危险色不可逆提示 + 两个 `.metric`（`12 条` / `296 MB`）+ 危险色主动作 |
| ⑦ 举证链与日志 | ✅ | 三行三种徽标（可恢复 = 信号色 / 已恢复 / 已阻断）；`恢复` 只在「可恢复」行出现；底部**留存口径两行同址** |

### A-9 遗留（**明确登记，不假装已覆盖**）

| # | 遗留 | 为什么现在不做 | 何时必须做 |
|---|---|---|---|
| 1 | **列表滚动**（② 候选、⑦ 执行记录超一屏） | 离屏渲染验不了 `ScrollView` 内容 | 接真实数据前；届时需真实 GUI 会话验证 |
| 2 | **逐字中文文案** | 视觉基线 §六：不在最小集内 | **R3.8 设计走查前必须补齐完整 R1.5 基线** |
| 3 | 深色/浅色、本地化、动效、空态插画 | 视觉基线 §六 明确不做 | 完整 R1.5 |
| 4 | 页面与真实 `Metrics` / `GateEvaluator` 的接线 | A-9 交付物是「骨架 + 语义位占位」 | Phase 3 收口前（A-9 之后的任务） |

---

## 25. 架构补充裁定（2026-11-08）

> **本节性质**：**只出裁定与结论，不改已签核正文**。凡需要动正文的，我给出**逐字改法**并标注「待 v1.7 落表」——不在 v1.6 里静默改签核过的条文（这条纪律是 R2 五轮评审换来的：改一处、另一处的旧假设没跟上，是全部新阻塞的来源）。
> **本节答复三件事**：① `E-501` 的可构造路径；② R3 契约维度评审（错误码 / 契约字段）；③ 由此带出的 2 条必须回流 PRD 的字面错误（偏差 8 / 偏差 9）。

---

### 25.1 裁定一：`E-501`（同 uid 进程枚举失败）**真机不可确定性构造**，且**不加第 7 个注入点**

#### ① 这个态能不能在真机上确定性构造？—— **不能。三条路我都试过。**

| 构造手段 | 实测结果 | 结论 |
|---|---|---|
| **`chmod 000 <来源根>`** | 只让 `opendir` 失败 → 观测物是 **`E-101`**。**枚举同 uid 进程的 fd 与来源目录权限完全无关**（`proc_pidinfo` 不碰来源目录） | **这条退路是错的**。TC-074 的「若只出 `E-101` 则判阻塞」**判得对**，但不是「实现不够」，是**这个办法根本不通** |
| **找一个同 uid 但有保护属性的进程**（含 `PT_DENY_ATTACH`） | 实测：子进程 `ptrace(PT_DENY_ATTACH)` 后 `proc_pidinfo(PROC_PIDLISTFDS)` **`returned=360`、`errno=0`**（成功） | 不产生 `EPERM` |
| **`sandbox-exec` 拒 `process-info*`** | 实测：`sandbox_apply: Operation not permitted`（本机会话被拒）。**即使可用也不成立**：它给**整个进程**换沙箱，不是「某来源」的态，且无法与产品自身正常扫描态并存 | 不可用，且方向错 |
| **自然发生**（真实机器上的常态） | 实测本机：`same=663`、**失败 1 条**、`errno=ESRCH(3)`（进程刚退出）、`EPERM` 计数 **0** → 按 ADR-03 的判据（`returned == 0 && errno == EPERM`）**不置 `degraded`** | **自然失败形态存在，但不是 `EPERM`** → 说明「判据只认 `EPERM`」是对的，也说明 `EPERM` 这个态在本用户会话里**根本不出场** |

**结论**：`degraded = true` 在**无 root、无 entitlement 的产品进程**里是**不可构造态**。根因不是实现缺陷——**`degraded` 描述的是「本进程连自己用户的进程都看不到」，这是进程自身被降权/被沙箱化的结果，不是产品能对自己的运行环境下的命令。**

#### ② 要不要在 §9.5 加第 7 个注入点（`RESIDUE_TEST_L0_ENUM_FAIL`）？—— **不加。三条理由，任一条都足以否掉。**

| # | 理由 | 说明 |
|---|---|---|
| **a** | **它替换的正是被判定的对象**，不是「影响可观测字段」 | §9.5 的边界写的是「只影响可观测字段取值、**不得改变任何判定逻辑**」。注入 `degraded = true` 会**跳过 `returned == 0 && errno == EPERM` 这条判据本身**——而这条判据正是 A-6 阶段实测抓出 4 个缺陷的那段代码。测完只能证明「下游拿到 `degraded` 之后怎么走」，**上游怎么判出 `degraded` 永远没被执行过**。这不是「影响输入事实」，是**把被测对象换成常量**。CLOCK / POWER 那些注入点不同：它们改的是**环境事实**，判据照跑 |
| **b** | **加了也解决不了 TC-032 / TC-033 的真实需求** | 那两个用例要的是「**该来源**同 uid 进程枚举失败」——**按来源**。而 `degraded` 是**全局单值**：`L0Probe.snapshot()` 一次产出、一个 `Bool`，没有 `sourceIndex`。加注入点后 TC-032 依然构造不出来，除非同时把 `degraded` 改成按来源——那是**改契约 + 改实现**，不是加注入点 |
| **c** | **根本不需要** —— 测试缝已经存在，缺的是接线和一条测试 | `L0Snapshot(degraded: true)` 是**公开可构造的值**；`GateEvaluator` 的入参 `SourceGateInput.undetermined` 本来就是**按来源的 `Bool`**。所以「`degraded` → `a`/`b` 不判定 → 未达项文案 → 页级状态行」这条链**在单测层面 100% 可确定性构造**。`MetricsTests` 已有 `testUnmetFDAUndetermined` / `testUnmetSampleAndFDAUndeterminedTwoRows` 两条，`L0ProbeTests` 却**从未构造过 `degraded = true`**（只断言了 false 分支）→ **缺的是一条正向测试，不是一个注入点** |

#### ③ 验收口径怎么改 —— **拆两层，不降级 AC，不新增注入点**

| 层 | 原口径 | **新口径（以此为准）** | 归属 |
|---|---|---|---|
| **契约层**（可 100% 构造） | 无 | `degraded = true`（或 `undetermined[source] = true`）时：该来源 `a`/`b` **均不判定**、第 ⑤ 页 ⑥ 列 = 「无法判定（无法枚举本用户进程）」（**不填 `0/0`、不填空**）、未达项集合含「L0 未判定（无法枚举本用户进程）」、页级状态行取「否（…未判定）」。**用例 = 单测 + 契约断言** | 查必究（S-13） |
| **真机层**（不可构造） | TC-074「构造第三类受阻 → 只读降级」 | **改判「反向断言」**：正常机器上跑一次快照 → `coverage.sameUIDTotal > 0` 且 **`degraded = false`**；且「同 uid 进程刚退出」的自然失败（`errno = ESRCH`）**不得**置 `degraded`。**这一层最有价值的地方不是「能构造降级」，而是「不误触发降级」**——`degraded` 恒 `true` 会让产品**永不可点亮**（AC-08 组 B 直接死），A-6 阶段已经错过一次同类（`PROC_PIDLISTFDS` 按 24 B 解析 → L0 恒判无引用） | 查必究（S-14） |

**同步落三处（待 v1.7）**：
1. **§9.5 不加注入点**，改为在表下加一句：**「枚举失败态（`degraded`）不进注入点：它不是可观测字段，而是被判定的判据本身；其可测性由 `L0Snapshot` 的构造式与 `SourceGateInput.undetermined` 承担。」**
2. **§12.3 已知能力边界**增第 5 条：**「`E-501` 在真机不可确定性构造（实测三条路均不通）。真机只能验「不误触发」，构造性验证在单测层完成。任何要求「真机复现 E-501」的用例判不可测，不得判不通过。」**
3. **B-1 侧**：TC-074 的阻塞条款从「缺 `E-501` 独立注入点」改为「**该态不可构造是终局结论，不是输入缺口**」，用例改挂反向断言；TC-032 / TC-033 **不需注入点即可全构造**，但 Given 必须按裁定三改写。

---

### 25.2 裁定二：`E-101` 一个码承载两种归类 —— **必须拆，这是阻塞 R3 用例的口径冲突**

**事实**：§6 第 1 行 `E-101` 的「场景」写「来源路径不存在 / 不可读」，归类写「**错误**」，用户可见结果写「路径变更」。而：

- **§8「无权限」类**明写三类，第一类就是「**来源不可读**」；
- **AC-14 Given 第一类** = 「该来源不可读」（三类 OS 级权限受阻之一）→ Then「降级为只读报告、逐条列出受阻来源与**所缺权限**字段」；
- **AC-09 判定 ④ 的页级优先级**「某来源未判定 → 否（因 `<来源>` 未判定）」也只有「来源不可读」这条路可达（见裁定三）。

→ **同一次观测（来源打不开），PRD 要求归「无权限 / 无法判定 / 出授权指引」，§6 要求归「错误 / 路径变更」**。两者对用户说的是两件事：「你没给权限」 vs 「你的路径变了」。按 §6 实现，**授权指引永远不会出现**，AC-14 的 Then 落空。

**裁定**：
- **`E-501` 只保留「同 uid 进程枚举失败」**，删掉「/ 来源不可读」（那半句本来就在 IF-01 里归 `E-101`，两处并存是 §6 抄串了）；
- **`E-101` 按成因二分**，此为 v1.7 的唯一正文改动：

| 成因（`opendir`/`stat` 的 `errno`） | 归类（§8） | 用户可见 | 状态词（P4） |
|---|---|---|---|
| `ENOENT`（不存在） | 错误 | 「路径变更」+ 来源名 | —（该来源不生成候选） |
| **`EACCES` / `EPERM`（存在但无读权限）** | **无权限** | 「**无法判定**」+ 「所缺权限 = 来源不可读」+ 授权指引条目 ID | **无法判定** |

**为什么不改 AC-14**：AC-14 的 Given 本来就要求「来源不可读」属三类权限受阻，**PRD 是对的，错在 §6 一行**。改 R2 一侧即可（与偏差 #4 同源：`lsof` 那类失去触发物，`E-101` 的分类当年跟着抄错了）。

**代价**：`E-101` 从「一个码一个归类」变成「一个码两个归类」——**这违反「一个码一件事」的一般原则，我接受这个代价**，理由是：把它拆成两个码（如 `E-108` 权限不可读）会**新增错误码**，而错误码表属已签核契约、且 §6 的码号段已按「1xx=扫描、2xx=执行、3xx=状态、4xx=导出、5xx=权限」分好，**插一个号比二分归类更容易让下游对不上**。等 v2.0 有别的改动时再合并成独立码。

---

### 25.3 裁定三：`undetermined` 的**定义域写死**（`degraded` 全局 vs 逐来源）—— 契约补写，不改 AC

**问题**：`L0Probe` 只产一个全局 `degraded`（`Bool`）；`GateEvaluator` 的入参 `SourceGateInput.undetermined` 是**按来源**的。AC-08 ②″/②‴、AC-09 ④/③ 都要求「**某来源**未判定」与「**全部来源**未判定」可区分。当前没有任何一处把这个映射写死 → **TC-032 写成「`npm.npx` 一个来源未判定」，实现层无法给出。**

**裁定（写死为唯一定义，随 v1.7 落实到 §4 IF-04 / IF-05 之间）**：

```
undetermined[source] = true
  ⟺ ( sameUIDEnumeration == false )                      // 全局：全部来源都置 true
    ∨ ( sourceRootReadable[source] == false && 成因 == EACCES )   // 逐来源：只置该来源
```

- **全局枚举失败 → 全部来源 `undetermined`** → 页级取「否（**权限不足 · 未判定**）」（AC-09 优先级 ③）；
- **单来源不可读（`EACCES`） → 只有该来源 `undetermined`** → 页级取「否（**因 `<来源>` 未判定**）」（优先级 ④）；
- 两条都成立时按优先级 ③ 取（③ 在 ④ 前，AC-09 已写死顺序）。

**这样一改，②″/②‴/④ 全部可达，且都不需要注入点**：单来源不可读用 `chmod 000` 造（`E-101`）；全局枚举失败用 `L0Snapshot(degraded: true)` 在单测层造。

**同时必须修 PRD 一处字面（偏差 8）**：**AC-08 组 A 判定 ②″ 的括注「（错误码 `E-501`；真实可达——来源目录权限异常时可复现）」是错的**——枚举同 uid 进程 fd 与来源目录权限**没有任何关系**（`proc_pidinfo` 不碰来源目录）。这句括注正是 TC-074「用 `chmod 000` 撞 `E-501`」的来源，**必须删掉**，否则每一轮测试都会重走一遍这条死路。→ **偏差 8：AC-08 ②″ 括注删除「来源目录权限异常时可复现」，改为「真机不可构造，可测性见 R2 §25 裁定一」**（不新增 AC 编号、不改判定集合）。

---

### 25.4 裁定四：R3 契约维度评审（`Tests/ResidueCoreTests/` 173 项）

> **评审范围（严格按分工）**：只评**错误码覆盖**与**契约字段的断言性质**。
> **不评**：测试写得好不好、覆盖率高低（查必究）；设计对不对（颜可读）。

#### ① 错误码覆盖：§6 共 **23 个码**，**14 个无码级断言**

> **先说一个结构性问题**：**`"E-xxx"` 字符串字面量在 `Sources/` 里出现次数 = 0**（全部只存在于注释与 `XCTFail` 消息里）。错误码**没有单一映射点**（没有 `code: String` 属性、没有 `ErrorCode` 枚举）→ **「错误码 ↔ 用例」的逐条核对无法机器化**，只能靠人读。这是 R3 之后回归必然漏项的根因，建议 v1.7 给每个 `Error` 加 `var code: String`（只加属性、不改判定）。**§6 另有一处跳号：`E-307` 不存在**（301→306→308），须确认是「有意空号」还是「丢了一行」。

| 分组 | 码 | 断言状态 | 载体（代码里有没有） |
|---|---|---|---|
| **有枚举 case + 有断言（9）** | `E-101` | ✅ `testMissingRootThrowsPathUnreadable` | `ScanError.pathUnreadable` |
| | `E-104` | ✅ `testAbortSavesBreakpointAndIsNotAnError` | `AbortReason.userCancelled` |
| | `E-105` | ✅ `testTimeoutIsDistinctFromUserCancel` | `AbortReason.timeout` / `ScanError.timeout` |
| | `E-301` | ✅ `testSchemaTooNewIsReadOnlyDegraded` | `StateFileError.schemaTooNew` |
| | `E-302` | ✅ `testCorruptFileIsBackedUpNotSilentlyDropped` / `testE304DoesNotDegradeToE302` | `.corruptNoBackup` |
| | `E-303` | ✅ `testShortWriteDoesNotReplaceGoodFile` | `.writeFailed` |
| | `E-304` | ✅ 4 条（位图长度 / CRC / 截断 / 不降级） | `.segmentValidationFailed` |
| | `E-306` | ✅ `testMigrationRestoreFailsWithoutBackup` | `.migrationRestoreFailed` |
| | `E-308` | ✅ `testRestoreFromBackupReportsE308` | `.restoredFromBackup` |
| **有行为断言、无可判码值（1）** | `E-401` | ⚠️ `testExportDoesNotWriteFileWhenSelfCheckFails` 断言的是 `RedactionError.leakedOriginalText`，**不是码** | `RedactionError`（无码值） |
| **有枚举 case、零断言（3）** | `E-103` | ❌ 无任何用例（`AbortReason.lowBattery` 从未被构造） | 有 `case lowBattery` |
| | `E-106` | ❌ 无任何用例（`checkpointInconsistent` 全文只出现 1 次，即定义处） | 有 `case` |
| | `E-305` | ❌ 无任何用例（`migrationSpaceInsufficient` 0 处测试引用） | 有 `case` |
| **连枚举 case 都没有（10）** | `E-102` `E-107` `E-201` `E-202` `E-203` `E-204` `E-205` `E-206` `E-207` `E-501` | ❌ **码只存在于注释**。其中 `E-204`/`E-206`/`E-207` 连**产出点**都没有（`blocked_out_of_scope` / `blocked_second_check` / `blocked_size_unknown` 三个动作值有定义、**永不产出**）；`E-205` 在实现上**不可能出现**（废纸篓目标名带 `UUID` 后缀，永不冲突 → 该码是死码） | 无 |

**定位给实现侧（不在本评范围内，但契约维度必须报）**：`E-205` 因「随机后缀」而成为**死码** —— 要么删码、要么把「同名冲突无法消解」改成「随机后缀重试 N 次仍失败」，**二者选一，不能留一个永不出现的码在表里**（否则 AC 的「逐条覆盖」永远差一条）。

#### ② 契约字段：**23 个字段只有存在性/往返断言，12 个字段完全没有载体**

| 契约位置 | 字段 | 断言性质 |
|---|---|---|
| `state.residue` **段表**（§5.1，24 B × 6 字段） | `offset` / `length` | ✅ **有逐字节断言**（`testSizeIdentityHolds` 在 `base+8` 读 `length`，把字段序钉死了一半） |
| | `kind` / `sourceIndex` | ⚠️ **只断言取值域**（`testSegmentsCarrySourceIndexAndKind`），**无逐字节位置断言**；且编解码对称 → **定义漂移查不出**（v1.5 的 N-2 就是这个病：`kind, sourceIndex, offset, length` 与 `offset, length, kind, sourceIndex` 两种写法总量同为 24 B、CRC 也查不出、读写各按一处必然错位） |
| | `reservedU16` / `reservedU32` | ❌ 无断言（应断言恒为 0） |
| **`scan.jsonl` 顶层 11 字段** | `mode` / `filesScanned` | ✅ 有值断言（注入值往返） |
| | `at` / `sources` / `bytesScanned` / `durationMs` / `aborted` / `breakpointSaved` / `unknownCount` | ⚠️ **7 个只有存在性/往返，无地面真值对账**（尤其 `unknownCount` —— v1.6 已把验收口径改为「机制存在 + 注入构造」，但**没有任何测试构造非 0 值**，该口径目前也是空的） |
| **`scan.jsonl.upstreamCommands`**（AC-19 唯一可判载体） | `cmd` / `exitCode` | ✅ 有值断言 |
| | `args` / `durationMs` / `invokedAt` | ⚠️ 3 个无断言 |
| | **`"集合外命令数 = 0"` / `"直接删文件命令出现次数 = 0"` 这两条 AC-19 判定** | ❌ **没有任何一条测试读 `scan.jsonl` 做统计** —— 白名单是在 `UpstreamWhitelist.rejectionReason` 层单测的（9 条，覆盖很实），**但 AC-19 的判据是「读日志统计」，这条路径一次都没跑过**。→ 存在「白名单对了、日志漏写了一行」的缺口 |
| **`scan.jsonl.diagnostics`**（10 字段） | `contentReads` | ✅ **0 与非 0 都断言**（`testNonZeroContentReadsIsObservable`）——这是全场唯一「把恒真判据救活」的字段，也是唯一写法正确的范例 |
| | `a` / `b` | ✅ 有值断言（注入值） |
| | `degraded` / `coverage.{sameUIDTotal,sameUIDRead,statOtherUID}` / `pNowCount` / `fSetBits` / `doneCount` / `round` / `countedDays` | ⚠️ **9 个只有存在性/往返，无与真实系统状态的对账**（`pNowCount` 从没和「实际持有文件的进程数」比过；`fSetBits` 从没和「实际 `F` 置位数」比过） |
| **`evidence.jsonl` · V4 八顶层字段**（§5.2，AC-18 分母 = 8） | `source` / `birthtime` / `l1Conclusion` / `l2Signals` / `l0CheckAt` / `ruleHit` / `executionAction` / `restorePath` | ❌ **8 个字段全部无载体**：代码里**没有 V4 的记录类型**（`RecordWriter.Kind.evidence` 只有文件名，没有任何结构可写）→ `evidence.jsonl` 写不出八字段 → **AC-18「8 字段完整率 100%」当前 0 条断言、且不可能有** |
| **`execution.jsonl`**（§5.3 / IF-10） | `jobId` / `seq` | ❌ **无载体**（IF-10 的幂等键 `jobId + candidateId + seq` 在 `ExecutionRecord` 里没有 `jobId`、没有 `seq`）→ 幂等与「读取侧按幂等键去重」**无可断言对象** |
| | `bytesPreview` / `bytesMeasuredAt` | ❌ **无载体**（IF-07 要求的 `t1` 预检值与 `t2` 实测时刻，`ExecutionRecord` 里只有 `bytes` 一个字段）→ **AC-15 的两时点判据（v1.1~v1.6 反复修的那件事）在实现层没有落点** |
| | `l0CheckAt` | ❌ 无载体（见 V4 行，同一件事） |

**统计**（供台账）：
- **只有存在性/往返断言、无地面真值对账的字段 = 23 个**（`scan.jsonl` 7 + `diagnostics` 9 + `upstreamCommands` 3 + 段表 4）
- **契约要求但代码里完全没有这个字段/载体的 = 12 个**（V4 八字段 8 + `jobId` / `seq` / `bytesPreview` / `bytesMeasuredAt` 4）
- **完全没被读取过的判据路径 = 1 条**（AC-19 的「读 `scan.jsonl.upstreamCommands` 统计」）

#### ③ 我认为**最危险的契约缺口**（一句话）

> **`execution.jsonl.bytes` 对目录型候选恒为 `0`，而它正是 AC-15 硬上限与第 ⑥ 页体积的唯一载体 —— 上限对目录候选完全失效，单次执行可无上限删除。**
>
> 证据（我实测的，不是推测）：`TrashExecutor.recursiveLogicalBytes` 用 `for case let item as String in enumerator(at:)`，而 **`FileManager.enumerator` 产出的是 `URL` 不是 `String`** → 循环体一次都不执行。同写法实测 `stringHits=0`（对照组 `urlHits=3`）。另外 `execute()` 的容量预检用的是 `attributesOfItem[.size]`（目录 ≈ 96 B），与 IF-08 要求的「预检取 `t1` 递归字节」不是一回事。
> **为什么它最危险**：AC-15 是**唯一的删除量硬上限**，v1.1~v1.6 五轮里有三轮在修它的「恒真」问题（目录 `st_size`、`t1`/`t2` 时点、预检取值来源），**修到最后判据清楚了、载体却是 0**。而且它**对测试完全隐形**：`TrashExecutorTests` 的 6 条用例**全部只用普通文件**（`makeFile` 只造文件），所以 `bytes` 的存在性断言永远通过。→ 这正是「只有存在性断言、没有地面真值对账」的典型后果，**不是测试写得少，是断言性质不对**。

---

### 25.5 本节带出的两条 PRD 字面偏差（待并入下一张变更单）

| # | 位置 | 现字面 | 问题 | 建议改法 |
|---|---|---|---|---|
| **偏差 8** | AC-08 组 A 判定 ②″ | 「…（错误码 `E-501`；**真实可达——来源目录权限异常时可复现**）」 | **因果错**：枚举同 uid 进程 fd 与来源目录权限无关（`proc_pidinfo` 不碰来源目录）。这句括注正是 TC-074「`chmod 000` 撞 `E-501`」的来源，会**每轮重走一次死路** | 删「真实可达——来源目录权限异常时可复现」，改为「**真机不可构造；可测性见 R2 §25 裁定一**」。**不改判定集合、不新增 AC** |
| **偏差 9** | AC-08 组 A 判定 ②″ / ②‴、AC-09 ④ | 「该来源同 uid 进程枚举失败」 | **粒度错**：PRD 按**来源**写，实现层 `degraded` 是**全局单值** → 「某来源未判定」无映射 | 按 **§25.3 的 `undetermined[source]` 定义域**补齐一句（全局失败 → 全部来源；单来源不可读 → 只该来源）。**不改判定集合** |

---

### 25.6 意见关闭表（本节三条输入缺口的处置）

| # | 提出人 | 位置 | 意见 | 类型 | 我的处置 | 状态 | 提意见者确认 |
|---|---|---|---|---|---|---|---|
| 1 | 查必究（B-1） | 安全类用例 | 未收到安全与合规检查表 + 完整移交清单 → 「建议归属 = 质量」的项可能有无依据编号可挂 | 契约缺口 | 出 `Residue-安全验证移交清单-v1.0.md`：**27 条**、每条挂 PRD 编号；补检查表 4 处修正（M-1~M-4）；无 PRD 编号的 2 条标「新增建议」 | **已关闭（待查必究确认）** | ⬜ 待确认 |
| 2 | 查必究（TC-074） | `E-501` 不可构造 | §9.5 无独立注入项；`chmod 000` 只出 `E-101` → 判阻塞 | 契约缺口 | **裁定：真机不可构造（终局）**；**不加第 7 注入点**；TC-074 改挂反向断言 + 单测层覆盖；偏差 8 删错误括注 | **已关闭（待查必究确认）** | ⬜ 待确认 |
| 3 | 查必究（TC-032 / TC-033） | ②″ / ②‴ | 同一 Given 卡在 `E-501` | 契约缺口 | **不需注入点即可全构造**：`undetermined` 按来源（裁定三）+ `chmod 000` 造单来源不可读（`E-101`） | **已关闭（待查必究确认）** | ⬜ 待确认 |
| 4 | 团队主理人 | R3 契约维度 | 错误码 / 契约字段覆盖 | 评审意见 | **14 个码无码级断言（3 有 case 零测试 + 10 连 case 都没有 + 1 只有行为断言）**；**23 个字段只有存在性断言**；**12 个字段无载体**；**最危险缺口 = `execution.jsonl.bytes` 对目录恒 0 → AC-15 上限失效** | **已交付（阻塞项 1 条：AC-15 载体）** | ⬜ 待确认 |
| 5 | 我自己 | §25.1 ③ / 25.2 | 三处待 v1.7 落表：§9.5 加边界句、§12.3 加第 5 条已知边界、§6 `E-101`/`E-501` 归类二分 | 契约补写 | 已给**逐字改法**，本轮不改已签核正文 | **待 v1.7（未关闭）** | ⬜ |
