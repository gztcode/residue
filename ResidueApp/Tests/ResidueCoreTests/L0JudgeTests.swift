import XCTest
@testable import ResidueCore

/// L0 逐候选判定层（CR-031 §3.4 的 `a` 写入路径的上游）。
///
/// ## 这一层的职责
///
/// 把「候选路径 + 一次 L0 快照」翻译成**逐候选**的判定结果
/// （`L0Verdict`），供写回层喂给 `MissCounter.apply`。
///
/// ## 关键纪律
///
/// - **`lstat` 失败 ⇒ `.undetermined`**（不是「无活引用」）——
///   看不见的东西不能说它安全（不变量③）。
/// - **不静默跳过**：每个候选都必须拿到一个判定
///   （跳过 ⇒ `b` 少算一次、`a` 漏判一次，且看不出来）。
/// - **降级快照 ⇒ 全部 `.undetermined`**：降级态下的快照不可信，
///   据它说「没有活引用」等于伪造证据。
final class L0JudgeTests: XCTestCase {

    // MARK: - 夹具

    private func candidate(
        _ path: String,
        isDirectory: Bool = false,
        birthtime: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> ScanEngine.Candidate {
        ScanEngine.Candidate(
            path: path,
            birthtime: birthtime,
            bytes: 0,
            isDirectory: isDirectory,
            source: Source.uvCache.rawValue
        )
    }

    private func id(_ path: String, birthtime: Date = Date(timeIntervalSince1970: 1_000_000)) -> CandidateID {
        CandidateID(path: path, birthtime: birthtime)
    }

    private let identity = FileIdentity(dev: 42, ino: 7)

    // MARK: - 判定

    func testCandidateHeldByFileDescriptorIsJudgedLive() {
        let snapshot = L0Snapshot(inodes: [identity: [1234]])
        let verdicts = L0Judge.judge(
            candidates: [candidate("/cache/a")],
            snapshot: snapshot,
            identityOf: { _ in self.identity }
        )
        XCTAssertEqual(verdicts[id("/cache/a")], .hasLiveReference)
    }

    func testCandidateNotHeldIsJudgedNoLiveReference() {
        let snapshot = L0Snapshot(inodes: [identity: [1234]])
        let verdicts = L0Judge.judge(
            candidates: [candidate("/cache/a")],
            snapshot: snapshot,
            identityOf: { _ in FileIdentity(dev: 99, ino: 99) }
        )
        XCTAssertEqual(verdicts[id("/cache/a")], .noLiveReference)
    }

    /// `lstat` 失败 ⇒ **不判定**（不许说「安全」）。
    func testUnreadablePathIsJudgedUndetermined() {
        let snapshot = L0Snapshot()
        let verdicts = L0Judge.judge(
            candidates: [candidate("/cache/gone")],
            snapshot: snapshot,
            identityOf: { _ in nil }
        )
        XCTAssertEqual(verdicts[id("/cache/gone")], .undetermined)
    }

    /// 目录：候选是某进程 cwd 的**祖先** ⇒ 在用（契约方向）。
    func testDirectoryWhoseDescendantIsProcessCwdIsJudgedLive() {
        let snapshot = L0Snapshot(cwdPaths: ["/cache/a/sub"])
        let verdicts = L0Judge.judge(
            candidates: [candidate("/cache/a", isDirectory: true)],
            snapshot: snapshot,
            identityOf: { _ in self.identity }
        )
        XCTAssertEqual(verdicts[id("/cache/a")], .hasLiveReference)
    }

    /// 方向守卫：cwd 是候选的**兄弟**（`/cache/ab` vs `/cache/a`）⇒ 不算祖先。
    ///
    /// §七坑 5：这个方向写反过，且**原测试按错误方向写断言**，
    /// 于是「测试把 bug 当成了规格」。这里显式钉住**正确**方向。
    func testDirectoryWhoseSiblingIsProcessCwdIsNotJudgedLive() {
        let snapshot = L0Snapshot(cwdPaths: ["/cache/ab"])
        let verdicts = L0Judge.judge(
            candidates: [candidate("/cache/a", isDirectory: true)],
            snapshot: snapshot,
            identityOf: { _ in self.identity }
        )
        XCTAssertEqual(verdicts[id("/cache/a")], .noLiveReference)
    }

    /// 非目录不参与 cwd 祖先判定（cwd 祖先判定只对目录成立）。
    func testFileIsNotJudgedLiveByProcessCwdAncestry() {
        let snapshot = L0Snapshot(cwdPaths: ["/cache/a/sub"])
        let verdicts = L0Judge.judge(
            candidates: [candidate("/cache/a", isDirectory: false)],
            snapshot: snapshot,
            identityOf: { _ in self.identity }
        )
        XCTAssertEqual(verdicts[id("/cache/a")], .noLiveReference)
    }

    /// 降级快照 ⇒ 全部不判定（不据不可信的快照下结论）。
    func testDegradedSnapshotJudgesEverythingUndetermined() {
        let snapshot = L0Snapshot(inodes: [identity: [1234]], degraded: true)
        let verdicts = L0Judge.judge(
            candidates: [candidate("/cache/a")],
            snapshot: snapshot,
            identityOf: { _ in self.identity }
        )
        XCTAssertEqual(verdicts[id("/cache/a")], .undetermined)
    }

    /// 每个候选都拿到判定（**不许静默跳过**）。
    ///
    /// §七坑 1：先断言总数再进循环 —— 不许空循环假绿。
    func testEveryCandidateReceivesAVerdict() {
        let snapshot = L0Snapshot()
        let paths = ["/cache/a", "/cache/b", "/cache/c"]
        let verdicts = L0Judge.judge(
            candidates: paths.map { candidate($0) },
            snapshot: snapshot,
            identityOf: { _ in self.identity }
        )
        XCTAssertEqual(verdicts.count, paths.count)
        for path in paths {
            XCTAssertNotNil(verdicts[id(path)], "候选 \(path) 没有拿到判定")
        }
    }

    // MARK: - 真文件系统

    /// 真 FS：存在的普通文件 ⇒ 拿得到身份 ⇒ 判「无活引用」。
    func testRealExistingFileIsJudgedNoLiveReference() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("residue-l0judge-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("cache.bin")
        FileManager.default.createFile(atPath: file.path, contents: Data([0x01]))

        let snapshot = L0Snapshot()
        let verdicts = L0Judge.judge(
            candidates: [candidate(file.path)],
            snapshot: snapshot
        )
        let key = id(file.path)
        XCTAssertEqual(verdicts.count, 1)
        XCTAssertEqual(verdicts[key], .noLiveReference)
    }

    /// 真 FS：文件已被删掉 ⇒ `lstat` 失败 ⇒ **不判定**。
    func testRealRemovedFileIsJudgedUndetermined() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("residue-l0judge-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("cache.bin")
        FileManager.default.createFile(atPath: file.path, contents: Data([0x01]))
        try? FileManager.default.removeItem(at: file)

        let snapshot = L0Snapshot()
        let verdicts = L0Judge.judge(
            candidates: [candidate(file.path)],
            snapshot: snapshot
        )
        XCTAssertEqual(verdicts[id(file.path)], .undetermined)
    }
}
