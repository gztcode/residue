import SwiftUI
import ResidueCore

// ============================================================
// Residue · 应用外壳（视觉基线 v2 · CR-031）
//
// 结构：208 pt 侧栏（品牌 + 三组导航 + 观察期卡）+ 内容区。
// **导航按语义分组**：看清（① ② ⑤）/ 回收（③ ⑥ ⑦）/ 设置（④）。
// 七项平铺没有「先看什么、再做什么」，分组是这一版最重要的信息层级改动。
//
// **只读态**（R2 §10.2）：顶部固定说明条 + 所有写操作禁用 + ⑤ 页「只读，不结算」。
// **未知字段一律「—（由更高版本维护）」，绝不显示 0。**
// ============================================================

struct RootView: View {
    @State private var selection: Page = .overview
    @State private var showConfirmDrawer = false
    /// **真实数据源**：由 App 级持有并传入（关窗不销毁 —— 客户端审查 C4）。
    let app: AppModel

    private var model: PageModel { app.pageModel }

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(selection: selection, model: model, onSelect: { selection = $0 })
                .frame(width: Tokens.Layout.sidebarWidth)

            Rectangle()
                .fill(Tokens.Color.divider)
                .frame(width: 1)

            VStack(spacing: 0) {
                if model.readOnly {
                    ReadOnlyBanner(
                        reason: model.readOnlyReason ?? UICopy.versionDegradedReadOnly
                    )
                    DividerLine()
                }
                if let warn = model.locationWarning {
                    WarningBanner(message: warn)
                    DividerLine()
                }
                if let err = app.errorMessage ?? model.errorMessageForRender {
                    ErrorBanner(message: err)
                    DividerLine()
                }

                pageHeader
                DividerLine()
                content
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .background(Tokens.Color.background)
        .preferredColorScheme(.dark)
        .task {
            app.loadAndProject()
        }
        .sheet(isPresented: $showConfirmDrawer) {
            ConfirmDrawer(
                model: model,
                onConfirm: {
                    showConfirmDrawer = false
                    Task { await app.executeBatch() }
                },
                onCancel: { showConfirmDrawer = false }
            )
        }
    }

    // MARK: - 页头

    private var pageHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(selection.title)
                    .font(Tokens.Typography.pageTitle)
                    .foregroundStyle(Tokens.Color.textPrimary)
                Text(selection.subtitle)
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(Tokens.Color.textTertiary)
            }

            Spacer()

            if app.isScanning, !app.scanProgress.displayText.isEmpty {
                Text(app.scanProgress.displayText)
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(Tokens.Color.textSecondary)
                    .monospacedDigit()
            }

            Button(app.isScanning ? L.pick("扫描中…", "Scanning…") : L.pick("扫描", "Scan")) {
                Task { await app.runScan() }
            }
            .buttonStyle(SecondaryButtonStyle(enabled: !app.isScanning && !model.readOnly))
            .disabled(app.isScanning || model.readOnly)

            if app.isScanning {
                Button(L.pick("取消", "Cancel")) { app.cancelScan() }
                    .buttonStyle(SecondaryButtonStyle(enabled: true))
            }

            if selection == .confirm {
                Button(L.pick("清理…", "Clean up…")) { showConfirmDrawer = true }
                    .buttonStyle(PrimaryButtonStyle(enabled: !model.readOnly))
                    .disabled(model.readOnly)
            }
        }
        .padding(.horizontal, Tokens.Layout.contentPadding)
        .padding(.top, Tokens.Spacing.m)
        .padding(.bottom, Tokens.Spacing.s)
    }

    // MARK: - 内容分发

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .overview:
            OverviewPage(model: model)
        case .environments:
            EnvironmentsPage(model: model)
        case .policy:
            PolicyPage(
                model: model,
                onOpenLoginSettings: { app.openLoginItemSettings() },
                onSetExecutionMode: { app.setExecutionMode($0) },
                onAddWhitelist: { app.addToWhitelist($0) },
                onRemoveWhitelist: { app.removeFromWhitelist($0) }
            )
        case .privacy:
            PrivacyPage(model: model, onClearLogs: { app.clearLogs() })
        case .report:
            ReportPage(model: model)
        case .confirm:
            ConfirmDrawer(
                model: model,
                onConfirm: {
                    showConfirmDrawer = false
                    Task { await app.executeBatch() }
                },
                onCancel: { selection = .overview },
                showsHeader: false
            )
        case .evidence:
            EvidencePage(
                model: model,
                onExport: { app.exportReportInteractive() },
                onRestore: { record in app.restore(record) }
            )
        }
    }
}

// MARK: - 侧栏（`RootView` 与渲染工具共用）

/// 208 pt 侧栏：品牌 + 三组导航 + 底部观察期卡。
///
/// 抽成独立 View 是为了**离屏渲染与真实界面同构** —— 两张图不一致时，
/// 走查结论就不可信（见 `RenderWrapper`）。
struct SidebarView: View {
    let selection: Page
    let model: PageModel
    let onSelect: (Page) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.horizontal, Tokens.Spacing.s)
                .padding(.top, Tokens.Spacing.m)
                .padding(.bottom, Tokens.Spacing.l)

            ForEach(PageGroup.allCases, id: \.rawValue) { group in
                Text(group.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Tokens.Color.textTertiary)
                    .padding(.horizontal, Tokens.Spacing.s)
                    .padding(.top, group == .see ? 0 : Tokens.Spacing.m)
                    .padding(.bottom, 5)

                ForEach(Page.allCases.filter { $0.group == group }) { page in
                    NavRow(
                        page: page,
                        selected: selection == page,
                        action: { onSelect(page) }
                    )
                }
            }

            Spacer(minLength: Tokens.Spacing.s)

            observationCard
                .padding(Tokens.Spacing.xs)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Tokens.Color.background)
    }

    private var brand: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            RoundedRectangle(cornerRadius: Tokens.Radius.control)
                .fill(
                    LinearGradient(
                        colors: [Tokens.Color.signal, SwiftUI.Color(hex: 0x8B6CF0)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 26, height: 26)
                .overlay(
                    Image(systemName: "circle.hexagongrid.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                )

            VStack(alignment: .leading, spacing: 0) {
                Text("Residue")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Tokens.Color.textPrimary)
                Text(L.pick("本机 · 零外发", "On-device · No outbound"))
                    .font(.system(size: 9))
                    .foregroundStyle(Tokens.Color.textTertiary)
            }
        }
    }

    /// 底部常驻卡：观察期进度。
    ///
    /// 菜单栏 App 的「常驻价值」就在这里——用户不用打开报告页也知道
    /// 还要观察几天。数据与 ⑤ 页**同源**（`observationRatio`）。
    private var observationCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(L.pick("观察期", "Observation"))
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(Tokens.Color.textSecondary)
                Spacer(minLength: 0)
                SemanticSlotView(
                    slot: model.observationDaySlot,
                    font: Tokens.Typography.numberSmall
                )
            }
            RatioBarView(slot: model.observationRatio, color: Tokens.Color.textPrimary, height: 3)
            Text(
                model.canLightUp
                    ? L.pick("已达达标条件", "Gate met")
                    : L.pick("影子期内只读", "Read-only during shadow period")
            )
            .font(.system(size: 9))
            .foregroundStyle(Tokens.Color.textTertiary)
        }
        .padding(Tokens.Spacing.s)
        .background(Tokens.Color.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.control))
    }
}

extension Page {
    /// 页头副标题：一句话说明本页回答什么问题。
    var subtitle: String {
        switch self {
        case .overview:
            return L.pick("只读扫描 · 不读取文件内容", "Read-only scan · file contents are never read")
        case .environments:
            return L.pick("候选清单 · 自动删除只作用于判定域", "Candidates · auto-delete applies only to the decision domain")
        case .policy:
            return L.pick("门槛未过不可点亮 · 白名单是唯一的主动保护", "Gate must pass · the allowlist is the only manual protection")
        case .privacy:
            return L.pick("四档独立授权 · 清除不重置观察期", "Four independent tiers · clearing never resets the observation period")
        case .report:
            return L.pick("14 天影子观察期 · 门槛全过才可点亮", "14-day shadow period · every gate check must pass")
        case .confirm:
            return L.pick("自动执行批次的预览 · 执行时逐来源复核", "Preview of the scheduled batch · each source is re-checked at execution")
        case .evidence:
            return L.pick("每条执行都有据可查 · 14 日内可恢复", "Every execution is traceable · restorable within 14 days")
        }
    }
}

/// 一行导航（视觉基线 v2：选中态 = 信号色 + 2 pt 左条）。
///
/// 侧栏选中态是**焦点**，占用信号色预算；内容区因此不再用信号色（CR-031 §1.1）。
struct NavRow: View {
    let page: Page
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: page.symbolName)
                    .font(.system(size: Tokens.Icon.nav, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(selected ? Tokens.Color.signal : Tokens.Color.textTertiary)

                Text(page.navTitle)
                    .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Tokens.Color.textPrimary : Tokens.Color.textSecondary)

                Spacer()
            }
            .padding(.horizontal, Tokens.Spacing.s)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.control)
                    .fill(selected ? Tokens.Color.signal.opacity(0.14) : .clear)
            )
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Tokens.Color.signal)
                        .frame(width: 2, height: 16)
                        .offset(x: 2)
                }
            }
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
    }
}
