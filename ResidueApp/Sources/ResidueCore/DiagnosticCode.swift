import Foundation

// ============================================================
// Residue · 诊断码表（R2 §6 的唯一代码化表达）
//
// ## 为什么必须是一个枚举，而不是散落的字符串
//
// 契约评审（梁承重 · R3 契约维度）指出一个结构性问题：
// **`"E-xxx"` 字面量在 Sources 里出现 0 次，23 个码全部只活在注释里。**
//
// 后果有三条，每条都是真的：
// 1. **「码 ↔ 用例」逐条核对无法机器化** —— 没有可枚举的码集合，
//    只能靠人肉读注释比对，而注释会腐坏。
// 2. **改了码不会被发现** —— 注释里改成 E-108，代码里没有任何一处要改，
//    于是「文档说 E-108、程序报 E-101」这种不一致可以长期存在。
// 3. **归类（§8）无法被断言** —— 「E-204 不得归无权限」这条约束，
//    在没有类型的地方只能写在文档里，无法被测试钉住。
//
// ## 设计约束（不是风格偏好，是判据）
//
// - **`rawValue` 必须等于 §6 表里的码字面量**：这是「码 ↔ 用例」能对齐的唯一锚点。
// - **`category` 只能取 §8 的封闭四类 + P4 的 `undetermined`**：
//   多一个值就意味着 §8 封闭分类被打破。
// - **一个码只有一种归类**：这是它比字符串强的地方。
//   `E-101` 原来既是「路径不存在」又是「不可读」，两种成因归两类 →
//   已按成因二分（见下面的 `e108`），不保留「同码两归类」。
// ============================================================

/// 诊断码（R2 §6 的 24 个码，`E-108` 为 v5.6 新增的二分成因）。
///
/// **`rawValue` 就是用户与用例里看到的那个码**，不允许在别处再拼字符串。
public enum DiagnosticCode: String, CaseIterable, Sendable, Equatable {

    // MARK: - 一、扫描与来源（1xx）

    /// 来源路径不存在（`ENOENT`）。归类：**错误**。
    ///
    /// 「路径变更」——用户升级了 uv/npm，缓存目录换了地方。
    /// 这不是权限问题，给授权指引只会误导。
    case e101 = "E-101"

    /// 卷只读。归类：**错误**。
    case e102 = "E-102"

    /// 低电量中断（< 20%，电池供电）。归类：**加载（暂停）**。
    case e103 = "E-103"

    /// 用户取消。归类：**加载**。
    case e104 = "E-104"

    /// 扫描超时（N1 的 600 s）。归类：**超时**。
    case e105 = "E-105"

    /// 断点一致性校验失败。归类：**超时**（须整体重扫）。
    case e106 = "E-106"

    /// 上游只读定位 / 能力探测失败。归类：**错误**。
    ///
    /// **与 `E-501` 不可混用**：这条是上游能力问题，不是权限。
    case e107 = "E-107"

    /// 来源不可读（`EACCES` / `EPERM`）。归类：**无权限**。**v5.6 新增**。
    ///
    /// ## 为什么要与 `E-101` 分开（这条是契约裁定，不是实现偏好）
    ///
    /// 原来 `E-101` 的语义是「来源路径不存在 / 不可读」，把两种成因塞进一个码：
    /// - **`ENOENT`**（路径不存在）→ 用户该做的是**升级后重新定位来源**
    /// - **`EACCES`**（存在但读不到）→ 用户该做的是**去授权**
    ///
    /// 归成一类时，`E-101` 只能归「错误」→ **AC-14 第一类（来源不可读）
    /// 的「所缺权限 + 授权指引条目 ID」永远不出现**。
    /// 这不是文案瑕疵：AC-14 的判定要求三类受阻各自给出指引，
    /// 而第一类在第一道映射上就被归错了类，后面怎么改文案都补不回来。
    ///
    /// 二分的代价是码表多一行；不二分的代价是**一条 AC 永远无法通过**。
    case e108 = "E-108"

    // MARK: - 二、执行（2xx）

    /// 源不存在（执行时刻已消失）。归类：**错误**。
    case e201 = "E-201"

    /// 废纸篓不可写。归类：**无权限**。
    case e202 = "E-202"

    /// 跨卷。归类：**错误**（源仍在原位）。
    case e203 = "E-203"

    /// 符号链接 / 越界路径。归类：**错误**。
    ///
    /// **不属 §8 封闭的三类 OS 权限受阻，不得归「无权限」**（安全拒绝，不是权限问题）。
    case e204 = "E-204"

    /// 同名冲突无法消解。归类：**错误**（跳过该条，源仍在原位）。
    ///
    /// ## 一条自我纠正要留痕
    /// 本码表第一版把 `E-205` 判成**死码并删除**，理由是「同名冲突由
    /// 路径 + birthtime 身份键在扫描期消解，执行期不存在这个分支」。
    /// **这个判断是错的。**
    ///
    /// 它在**恢复**路径上是活的、而且是用户必然撞到的一条：
    /// 条目被移入废纸篓后，用户在原位置又装了新版，此时点「恢复」
    /// → 原路径已被占用。产品**不得覆盖**（覆盖等于用旧文件打掉用户新装的东西），
    /// 只能报错交用户处理。这正是「同名冲突无法消解」。
    ///
    /// 教训：**判断一个码是不是死码，要连「反向操作」一起看**。
    /// 只顺着「删除」找，永远看不到「恢复」。
    case e205 = "E-205"

    /// 删除前二次检查阻断（AC-17）。归类：**并发冲突**。
    case e206 = "E-206"

    /// 目录递归体积不可得。归类：**错误**（体积不可得 → 未删除）。
    case e207 = "E-207"

    // MARK: - 三、状态载体（3xx）

    /// schema 更高。归类：**错误（只读降级，不拒绝）**。
    case e301 = "E-301"

    /// 状态文件损坏（CRC / 结构失败，且**无可用 `.bak`**）。归类：**错误**。
    case e302 = "E-302"

    /// 写短写 / `ENOSPC` / `EDQUOT`。归类：**错误**。
    case e303 = "E-303"

    /// 段校验失败（越界 / 重叠 / CRC / 位图长度不符）。归类：**错误**（保留现场 + 只读）。
    case e304 = "E-304"

    /// 迁移空间预检不足。归类：**错误**（必须给出具体 MB 数）。
    case e305 = "E-305"

    /// 迁移恢复失败（从 `.bak` 恢复也失败）。归类：**错误**（只读）。
    case e306 = "E-306"

    /// **已从 `.bak` 恢复成功**（迁移失败但备份可用）。归类：**错误（提示级）**。
    ///
    /// **必须独立存在**：`E-302` 已限定为「无可用 `.bak`」；
    /// 若恢复成功也报 `E-302`，则「迁移失败但已成功回退」这条
    /// **最常见的主路径没有码可用**。
    case e308 = "E-308"

    // MARK: - 四、导出与权限（4xx / 5xx）

    /// 导出脱敏自检失败。归类：**错误**（不产出文件）。
    case e401 = "E-401"

    /// 同 uid 进程枚举失败。归类：**无权限**。
    ///
    /// 未达项文案 = 「L0 未判定（无法枚举本用户进程）」。
    /// **不得写「未取得 Full Disk Access」** —— 那是说一件产品不知道的事。
    case e501 = "E-501"

    // MARK: - 呈现

    /// §8 的封闭分类 + P4 的 `undetermined`。
    ///
    /// **值域封闭**：多一个值就意味着 §8 的分类被打破，
    /// 而 §8 是「不把未知判为安全」这条承诺的实现处。
    public enum Category: String, Sendable, CaseIterable {
        /// 错误（用户可理解的具体失败）。
        case error = "错误"
        /// 无权限（须给「所缺权限 + 授权指引条目 ID」三要素）。
        case noPermission = "无权限"
        /// 加载（含暂停）。
        case loading = "加载"
        /// 超时（可续扫 / 需重扫）。
        case timeout = "超时"
        /// 并发冲突。
        case concurrency = "并发冲突"
        /// 无法判定（P4；**不把未知判为安全**）。
        case undetermined = "无法判定"

        /// 是否属「OS 权限受阻」三类之一（AC-14 的判定域）。
        ///
        /// **只有 `noPermission`**——`E-204`（越界/符号链接）是安全拒绝，
        /// 不在此域内，尽管它读起来也像「不让做」。
        public var isOSPermissionBlock: Bool {
            self == .noPermission
        }
    }

    /// §8 归类。
    ///
    /// **一个码只有一种归类**：这是码表比字符串强的地方。
    /// 若某个码看起来有两种归类，正确做法是二分出一个新码，
    /// 而不是让 `category` 变成按入参返回不同值的函数。
    public var category: Category {
        switch self {
        // 1xx 扫描与来源
        case .e101: return .error            // ENOENT：路径变更
        case .e102: return .error
        case .e103: return .loading          // 暂停
        case .e104: return .loading
        case .e105: return .timeout
        case .e106: return .timeout
        case .e107: return .error            // 上游能力问题，非权限
        case .e108: return .noPermission     // EACCES：真权限受阻

        // 2xx 执行
        case .e201: return .error
        case .e202: return .noPermission
        case .e203: return .error
        case .e204: return .error            // **安全拒绝，不归无权限**
        case .e205: return .error            // 恢复时原路径被占，不覆盖
        case .e206: return .concurrency
        case .e207: return .error

        // 3xx 载体
        case .e301: return .error            // 只读降级，不拒绝
        case .e302: return .error
        case .e303: return .error
        case .e304: return .error
        case .e305: return .error
        case .e306: return .error
        case .e308: return .error            // 提示级

        // 4xx / 5xx
        case .e401: return .error
        case .e501: return .noPermission
        }
    }

    /// 用户可见的一句话（**界面不得自行拼**）。
    ///
    /// 这些是 §6 表的「用户可见结果」列，逐字。
    /// 放到这里而不是界面层，是因为同一码可能在多处出现，
    /// 而「同一事实两处写」是这项目反复复发的病根。
    public var summary: String {
        switch self {
        case .e101: return L.pick("路径变更", "Path changed")                 // + 来源名（由调用方补）
        case .e102: return L.pick("无法写入", "Can’t write")
        case .e103: return L.pick("低电量已暂停", "Paused: low battery")
        case .e104: return L.pick("已取消", "Cancelled")
        case .e105: return L.pick("已超时，可续扫", "Timed out; can resume")
        case .e106: return L.pick("需重新扫描", "Full rescan required")
        case .e107: return L.pick("无法判定", "Can’t determine")
        case .e108: return L.pick("来源无法读取", "Source can’t be read")
        case .e201: return L.pick("源已不存在", "Source no longer exists")
        case .e202: return L.pick("废纸篓不可写", "Trash is not writable")
        case .e203: return L.pick("跨卷，源仍在原位", "Cross-volume; source left in place")
        case .e204: return L.pick("不在允许范围，已跳过", "Out of allowed scope; skipped")
        case .e205: return L.pick("原位置已有同名项，未覆盖", "Same-name item exists at original path; not overwritten")
        case .e206: return L.pick("二次检查阻断", "Blocked by second check")
        case .e207: return L.pick("体积不可得，未删除", "Size unavailable; not deleted")
        case .e301: return L.pick("数据由更高版本创建，本版本只读", "Data created by a newer version; this version is read-only")
        case .e302: return L.pick(
            "状态文件损坏，已备份为 .corrupt；请先导出报告",
            "State file is corrupt; backed up as .corrupt. Export a report first"
        )
        case .e303: return L.pick("磁盘空间不足，状态未更新", "Not enough disk space; state not updated")
        case .e304: return L.pick("数据校验失败；请导出报告", "Data verification failed; export a report")
        case .e305: return L.pick("迁移空间不足", "Not enough space for migration")
        case .e306: return L.pick("数据升级失败，仅可查看与导出", "Data upgrade failed; view and export only")
        case .e308: return L.pick(
            "本次数据升级未完成，已回退到升级前的数据；观察期进度未受影响",
            "Data upgrade did not complete; rolled back to pre-upgrade data. Observation progress is unaffected"
        )
        case .e401: return L.pick("导出失败", "Export failed")
        case .e501: return L.pick("无法判定（无法枚举本用户进程）", "Can’t tell (can’t enumerate this user’s processes)")
        }
    }

    /// 建议的可执行动作（视觉基线 §三：**错误态必须给可执行动作**，不能只报码）。
    ///
    /// ## 为什么放码表里而不是界面层
    /// 「同一个码在两个地方给出不同建议」是这项目反复复发的病。
    /// 但动作**不能硬编码进界面**，因为它必须与码的语义严格对应：
    /// 「磁盘满 → 释放空间」「权限不足 → 去授权」「路径变更 → 重新定位来源」
    /// 这三条一旦错配，用户会照着做但问题解决不了——**给错指引比不给更糟**。
    ///
    /// 返回 `nil` 表示「本码不需要用户额外动作」（如「已取消」「已超时」）。
    public var suggestedAction: String? {
        switch self {
        case .e101: return L.pick(
            "请检查来源路径是否仍存在（应用升级后缓存目录可能已变更）",
            "Check whether the source path still exists (cache directories may move after an app upgrade)"
        )
        case .e102: return L.pick("该卷为只读，请换到可写位置后重试", "This volume is read-only; switch to a writable location and retry")
        case .e103: return L.pick("接上电源后会自动继续", "It will resume automatically once power is connected")
        case .e104: return nil
        case .e105: return L.pick("可续扫，无需从头开始", "You can resume; no need to start over")
        case .e106: return L.pick("请重新完整扫描", "Run a full scan again")
        case .e107: return L.pick("可在 ⑦ 页查看上游命令记录", "See the upstream command log on page ⑦")
        case .e108: return L.pick("请在系统设置中授予该来源的读取权限", "Grant read access to this source in System Settings")
        case .e201: return nil
        case .e202: return L.pick("请检查废纸篓是否可写", "Check whether Trash is writable")
        case .e203: return nil
        case .e204: return nil
        case .e205: return L.pick("请先移走原位置的同名项，再重试恢复", "Move the same-name item at the original path away, then retry the restore")
        case .e206: return L.pick("该项已变化，将在下次扫描时重新判定", "The item changed; it will be re-evaluated on the next scan")
        case .e207: return nil
        case .e301: return L.pick("装回更高版本才能执行清理", "Reinstall the newer version to run cleanup")
        case .e302: return L.pick("请先导出报告", "Export a report first")
        case .e303: return L.pick("清理废纸篓或释放磁盘后重试", "Empty Trash or free up disk space, then retry")
        case .e304: return L.pick("请导出报告", "Export a report")
        case .e305: return L.pick("释放空间后重启应用会自动重试", "Free up space, then restart the app to retry automatically")
        case .e306: return L.pick("请重装同版本或更高版本；可导出报告", "Reinstall the same or a newer version; you can export a report")
        case .e308: return nil
        case .e401: return L.pick("请先导出报告以便排查", "Export a report so the issue can be investigated")
        case .e501: return L.pick("请在系统设置中允许本应用访问", "Allow this app access in System Settings")
        }
    }

    /// 是否需要「所缺权限 + 授权指引条目 ID」三要素（AC-14）。
    ///
    /// 只有 `noPermission` 类需要。**`E-204` 不需要**——它是安全拒绝，
    /// 给授权指引等于让用户去授权一件产品本就不该做的事。
    public var requiresAuthorizationGuide: Bool {
        category.isOSPermissionBlock
    }
}
