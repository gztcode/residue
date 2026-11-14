import SwiftUI
import AppKit
import ResidueCore

// ============================================================
// Residue · 七页渲染工具（开发期 / 设计走查用）
//
// **为什么需要它**：本机是无头会话，`screencapture` 拿到的是全黑图，
// 无法用「截屏看界面」来验证七页。改用 `ImageRenderer` 把每页渲染成 PNG——
// 不依赖显示服务，且产出物可以留档给 R3.8 设计走查逐条对照。
//
// **不随发布版分发**：整段包在 `#if DEBUG` 里，Release 产物中不存在。
// 这与 §9.5「测试注入点绝不能进发布版」同一条纪律
// （`verify_a5.sh` 会扫 `RESIDUE_TEST_`，本文件用 DEBUG 宏，release 直接不编译）。
//
// 用法：
//   swift run ResidueApp --render-pages <输出目录>
// ============================================================

#if DEBUG
enum PageRenderer {

    /// 渲染尺寸（与 `RootView` 的 `defaultSize` 一致）。
    static let size = CGSize(width: 1000, height: 640)

    /// ③ 页内容远超一屏（产品里是 `ScrollView`）。离屏渲染不渲染滚动内容，
    /// 又不该只截首屏导致「页头被挤出画布」，故按内容高度加高画布。
    /// **其他页仍是真实窗口高度 640**，只有 ③ 例外且在此注明。
    static func canvasHeight(for page: Page) -> CGFloat {
        page == .policy ? 1180 : size.height
    }

    /// 若命令行带 `--render-pages <dir>`，渲染七页并退出。
    ///
    /// - Returns: 是否已处理（`true` 时调用方应直接退出）。
    ///
    /// `@MainActor`：`ImageRenderer` 的 `cgImage` 是主线程隔离的，
    /// 而 `App.init()` 本就在主线程 → 直接调用即可。
    @MainActor
    @discardableResult
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--render-pages"), idx + 1 < args.count else {
            return false
        }
        let outDir = URL(fileURLWithPath: args[idx + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let model = PageModel.skeleton()
        var okCount = 0

        for page in Page.allCases {
            // 每页包一层「外壳 + 内容」，与真实界面同构
            let view = RenderWrapper(
                page: page,
                model: model,
                height: canvasHeight(for: page)
            )
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2.0       // Retina

            guard let cg = renderer.cgImage else {
                FileHandle.standardError.write(Data("✗ 渲染失败：\(page.title)\n".utf8))
                continue
            }
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write(Data("✗ PNG 编码失败：\(page.title)\n".utf8))
                continue
            }
            let name = String(format: "%02d-%@.png", page.rawValue + 1, page.title)
            let url = outDir.appendingPathComponent(name)
            do {
                try png.write(to: url)
                print("✓ \(name)  (\(cg.width)×\(cg.height))")
                okCount += 1
            } catch {
                FileHandle.standardError.write(Data("✗ 写入失败：\(name) — \(error)\n".utf8))
            }
        }

        // ---- 特殊态补充渲染 ----
        // 设计走查指出：7 张常态图里「只读态」0 张，而只读态是 R2 §10.2 的重点
        //（「只读，不结算」+「—（由更高版本维护）」，绝不显示 0）。
        // 故额外渲两张：⑤ 页只读态、① 页空态。
        var readOnlyModel = model
        readOnlyModel.readOnly = true
        // 设计走查（DAC v2.0 §8.2）指出：9 张图里八态只覆盖了默认态，
        // **5 态无渲染**（错误/无权限/超限/并发冲突/超时），加载态、②⑦ 空态、
        // 权限降级只读态也全无。**无图 = 走查判不了**，只能判「枚举里有没有」。
        //
        // 所以这里把能构造的特殊态都渲出来。**构造方式都是真实状态**，
        // 不是画一个假的 —— 每张都对应产品里真会出现的路径。
        var errorModel = model
        errorModel.statusSlot = .stateLabel(.error)
        errorModel.errorMessageForRender = L.pick("E-303 · 磁盘空间不足，状态未更新。清理废纸篓或释放磁盘后重试", "E-303 · Not enough disk space; state not updated. Empty Trash or free up disk and retry")

        var noPermModel = model
        // 与 `PageModelBuilder` 同一条规则：后两档默认未授权 → 「未采集」；
        // 权限受阻只发生在**已授权**的档位。否则会出现「未授权 + 无法判定」
        // 这种自相矛盾的行（11 号图首版就是这样）。
        noPermModel.collectionTiers = noPermModel.collectionTiers.enumerated().map { idx, tier in
            let blocked: SemanticSlot? = idx < 2
                ? .permissionBlocked(
                    missing: L.pick("本用户进程 fd", "this user's process fds"),
                    guideItemID: DiagnosticCode.e501.rawValue
                )
                : nil
            return CollectionTier(
                name: tier.name,
                authorized: idx < 2,
                state: blocked ?? .text(L.pick("未采集", "Not collected")),
                blockReason: blocked
            )
        }

        var overLimitModel = model
        overLimitModel.deferredCountSlot = .metric(38, unit: .items)
        overLimitModel.statusSlot = .stateLabel(.overLimit)

        var loadingModel = model
        loadingModel.loading = true
        loadingModel.loadingMessage = L.pick("正在扫描 5 个来源 · 已扫描 12,847 条", "Scanning 5 sources · 12,847 items scanned")

        var envEmptyModel = model
        envEmptyModel.candidateRows = []
        envEmptyModel.pageCount = 1

        var evidenceEmptyModel = model
        evidenceEmptyModel.evidenceRows = []
        evidenceEmptyModel.evidenceFields = []

        // 权限降级只读态（**与版本降级只读不同**：成因是 E-501，不是 E-301）
        var permReadOnlyModel = model
        permReadOnlyModel.readOnly = true
        permReadOnlyModel.readOnlyReason = UICopy.permissionDegradedReadOnly

        for (name, page, m) in [
            ("08-观察期报告-只读态-版本降级", Page.report, readOnlyModel),
            ("09-存储总览-空态", Page.overview, {
                // 空态由「从未扫描」驱动（`hasScanned == false`），不是把区块清空：
                // 清空区块只是渲染工具的假态，产品里空态来自扫描新鲜度。
                var e = model
                e.hasScanned = false
                e.restoredFromLastScan = false
                e.totalScannedSlot = .text("—")
                return e
            }()),
            ("10-存储总览-错误态", Page.overview, errorModel),
            ("11-授权与隐私-无权限态", Page.privacy, noPermModel),
            ("12-确认清理-超限态", Page.confirm, overLimitModel),
            ("13-存储总览-加载态", Page.overview, loadingModel),
            ("14-环境与候选-空态", Page.environments, envEmptyModel),
            ("15-举证链与日志-空态", Page.evidence, evidenceEmptyModel),
            ("16-观察期报告-只读态-权限降级", Page.report, permReadOnlyModel),
        ] {
            let view = RenderWrapper(page: page, model: m)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2.0
            guard let cg = renderer.cgImage else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            let url = outDir.appendingPathComponent("\(name).png")
            if (try? png.write(to: url)) != nil {
                print("✓ \(name).png  (\(cg.width)×\(cg.height))")
                okCount += 1
            }
        }

        // 17：菜单栏浮层（`.window` 样式）。它不是七页之一，单独渲一张。
        do {
            let renderer = ImageRenderer(
                content: MenuBarPopover(model: model)
                    .environment(\.residueRenderMode, true)
                    .environment(\.colorScheme, .dark)
            )
            renderer.scale = 2.0
            if let cg = renderer.cgImage,
               let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                let url = outDir.appendingPathComponent("17-菜单栏浮层.png")
                if (try? png.write(to: url)) != nil {
                    print("✓ 17-菜单栏浮层.png  (\(cg.width)×\(cg.height))")
                    okCount += 1
                }
            }
        }

        print("\n共渲染 \(okCount) 张 → \(outDir.path)")
        return true
    }
}

/// 渲染用的外壳（与 `RootView` 同样的侧栏 + 页头 + 只读条，但**无窗口依赖**）。
struct RenderWrapper: View {
    let page: Page
    let model: PageModel
    var height: CGFloat = PageRenderer.size.height

    var body: some View {
        // `.top`：内容超出一屏时 HStack 会变高，默认垂直居中对齐会把
        // 固定 640 pt 的侧栏整体下移 → 底部观察期卡被裁。
        HStack(alignment: .top, spacing: 0) {
            // 侧栏：**与真实界面同一个 View**（`SidebarView`），避免两套皮
            SidebarView(selection: page, model: model, onSelect: { _ in })
                .frame(width: Tokens.Layout.sidebarWidth, height: height)

            Rectangle()
                .fill(Tokens.Color.divider)
                .frame(width: 1)

            // 内容区
            VStack(spacing: 0) {
                if model.readOnly {
                    ReadOnlyBanner(
                        reason: model.readOnlyReason ?? UICopy.versionDegradedReadOnly
                    )
                    Rectangle().fill(Tokens.Color.divider).frame(height: 1)
                }
                // 与 `RootView` 同构：错误态顶部必须有横幅，否则渲染图只看到
                // 一个「出错了」状态标签、看不到错误码与处置建议，设计走查判不了。
                if let err = model.errorMessageForRender {
                    ErrorBanner(message: err)
                    Rectangle().fill(Tokens.Color.divider).frame(height: 1)
                }

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(page.title)
                            .font(Tokens.Typography.pageTitle)
                            .foregroundStyle(Tokens.Color.textPrimary)
                        Text(page.subtitle)
                            .font(Tokens.Typography.secondary)
                            .foregroundStyle(Tokens.Color.textTertiary)
                    }
                    Spacer()
                }
                .padding(.horizontal, Tokens.Layout.contentPadding)
                .padding(.top, Tokens.Spacing.m)
                .padding(.bottom, Tokens.Spacing.s)

                Rectangle().fill(Tokens.Color.divider).frame(height: 1)

                pageContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // `alignment: .topLeading` 很关键：错误态比常态多一条横幅，
        // 内容会超出 640 pt；默认居中对齐会把**页头裁到画布上沿之外**，
        // 看起来像「标题被切了」。顶部对齐 = 裁掉屏幕下方的内容，
        // 与真实窗口「首屏」一致。
        .frame(width: PageRenderer.size.width, height: height, alignment: .topLeading)
        .background(Tokens.Color.background)
        .preferredColorScheme(.dark)
        // ImageRenderer 不做深色推断 → 显式给环境
        .environment(\.colorScheme, .dark)
        // **关键**：告诉页面「当前是离屏渲染」→ 用直排容器代替 ScrollView。
        // 产品路径不受影响（默认 false）。
        .environment(\.residueRenderMode, true)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .overview:    OverviewPage(model: model)
        case .environments: EnvironmentsPage(model: model)
        case .policy:      PolicyPage(model: model)
        case .privacy:     PrivacyPage(model: model)
        case .report:      ReportPage(model: model)
        case .confirm:     ConfirmDrawer(model: model, onConfirm: {}, onCancel: {}, showsHeader: false)
        case .evidence:    EvidencePage(model: model, onExport: {})
        }
    }
}
#endif
