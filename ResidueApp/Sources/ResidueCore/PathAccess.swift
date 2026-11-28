import Foundation
import Darwin

// ============================================================
// Residue · 路径可读性的三态分类（fail-closed 的共同前提）
//
// ## 这一层存在的理由
//
// 「读不到」与「不存在」是**两件不同的事**，但在 Foundation 里长得一样：
// `attributesOfItem` 与 `lstat` 失败都只交回一个错误对象。若把它们并成同一个
// `nil` / `.vanished`，调用方就再也分不开，于是会同时踩两个坑：
//
// | 混同 | 后果 | 缺陷 |
// |---|---|---|
// | 权限不足 ⇒ 当成「文件已自行删除」 | 举证链里写下**假事实** | P-028 |
// | 取不到身份 ⇒ 当成「没有活引用」 | **fail-open** ⇒ 可能删掉正在被使用的文件 | P-027 |
//
// 不变量③「不把未知判为安全」在这里落成类型：只有「**确定不存在**」与
// 「**读得到**」是两种可区分的事实，其余一律 `unreadable`
// ⇒ 调用方按「无法判定」处置（fail-closed）。
//
// ## ⚠️ `NSCocoaErrorDomain` 下的 `.code` 不是 `errno`
//
// `FileManager` 抛的是 Cocoa 错误：`code` 是 260 / 257 这类 Cocoa 码，
// 真正的 `errno` 在 `NSUnderlyingErrorKey` 里（CLAUDE.md §七-3 踩过：
// 直接拿 `.code` 比 `EACCES` 永远不相等 ⇒ 错误分类静默失效）。
// ============================================================

/// 路径访问失败的分类。
public enum PathAccess {

    /// 失败的两类**不同事实**（值域封闭）。
    public enum Failure: Equatable, Sendable {
        /// **确定不存在**（`ENOENT` / `ENOTDIR`）—— 那里确实没有东西。
        case absent
        /// **读不到**（权限、I/O 错误等）—— 无法判定那里有没有东西。
        case unreadable(errno: Int32)
    }

    /// 按 POSIX `errno` 分类。
    ///
    /// `ENOENT` / `ENOTDIR` ⇒ 确定不存在；**其它一切**（含 `EACCES` / `EPERM`）
    /// ⇒ 读不到（宁可保守，也不假装知道）。
    ///
    /// - Parameter errno: POSIX 错误码。
    /// - Returns: 失败分类。
    public static func classify(errno: Int32) -> Failure {
        switch errno {
        case ENOENT, ENOTDIR:
            return .absent
        default:
            return .unreadable(errno: errno)
        }
    }

    /// 按 Foundation 抛出的错误分类（`FileManager` 等）。
    ///
    /// - Parameter error: 捕获到的错误。
    /// - Returns: 失败分类。
    public static func classify(error: Error) -> Failure {
        classify(errno: posixErrno(from: error))
    }

    /// 从 `NSError` 里取出 POSIX `errno`。
    ///
    /// 顺序：`NSUnderlyingErrorKey` 里的 POSIX 错误 → 自身就是 POSIX 域 →
    /// Cocoa 码兜底。**不拿 `.code` 直接比 `errno`**（见文件头警告）。
    ///
    /// - Parameter error: 捕获到的错误。
    /// - Returns: POSIX `errno`（取不到时回退成 `EIO` ⇒ 一律按「读不到」处置）。
    public static func posixErrno(from error: Error) -> Int32 {
        let ns = error as NSError
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return Int32(underlying.code)
        }
        if ns.domain == NSPOSIXErrorDomain {
            return Int32(ns.code)
        }
        // 实测 Cocoa 错误都带 underlying；这里是兜底（NSFileReadNoSuchFileError
        // = 260 对应「不存在」，NSFileReadNoPermissionError = 257 对应「权限不足」）。
        switch ns.code {
        case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
            return ENOENT
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
            return EACCES
        default:
            return EIO
        }
    }

    /// `errno` 的可读名字（`EACCES` / `EPERM` …）；不认识就回退成数字。
    ///
    /// 写进举证链的原因串要能让人一眼看出是**权限**还是 **I/O**。
    ///
    /// - Parameter code: POSIX 错误码。
    /// - Returns: 符号名（未知时为 `errno <数字>`）。
    public static func errnoName(_ code: Int32) -> String {
        switch code {
        case EACCES: return "EACCES"
        case EPERM: return "EPERM"
        case ENOENT: return "ENOENT"
        case ENOTDIR: return "ENOTDIR"
        case EIO: return "EIO"
        case ELOOP: return "ELOOP"
        case ENAMETOOLONG: return "ENAMETOOLONG"
        case EMFILE: return "EMFILE"
        case ENFILE: return "ENFILE"
        case ENOMEM: return "ENOMEM"
        case EBUSY: return "EBUSY"
        case ETXTBSY: return "ETXTBSY"
        case EFBIG: return "EFBIG"
        case EOVERFLOW: return "EOVERFLOW"
        case EROFS: return "EROFS"
        case ENOTEMPTY: return "ENOTEMPTY"
        case EXDEV: return "EXDEV"
        case EINVAL: return "EINVAL"
        default: return "errno \(code)"
        }
    }
}
