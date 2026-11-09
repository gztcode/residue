import SwiftUI
import ResidueCore

// ============================================================
// Residue · 应用外壳（七页导航 + 只读条 + 抽屉）
//
// **窗口形态**：产品是菜单栏常驻（ADR-02），主界面从菜单栏打开。
// 本外壳只管「七页怎么排」，不含业务逻辑。
//
// **只读态**（视觉基线 §三 / R2 §10.2）：
// 顶部固定说明条 + 所有写操作禁用 + ⑤ 页显示「只读，不结算」。
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

            // ---- 侧边导航 ----
            sidebar
                .frame(width: 168)

            DividerLine()
                .frame(width: 1)
                .frame(maxHeight: .infinity)

            // ---- 内容区 ----
            VStack(spacing: 0) {
                if model.readOnly {
                    ReadOnlyBanner(
                        reason: model.readOnlyReason ?? UICopy.versionDegradedReadOnly
                    )
                    DividerLine()
                }
                if let warn = model.locationWarning {
                    // Translocation / 不在「应用程序」——**不是错误，是安装位置提示**，
                    // 用中性色而不是危险色（危险色只给不可逆与错误）
                    WarningBanner(message: warn)
                    DividerLine()
                }
                if let err = app.errorMessage ?? model.errorMessageForRender {
                    // 错误态必须给**可执行动作**（视觉基线 §三）——文案由 AppModel 给全
                    ErrorBanner(message: err)
                    DividerLine()
                }

                header
                DividerLine()
                content
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .background(Tokens.Color.background)
        // 深色（视觉基线 §六：本期只有深色）
        .preferredColorScheme(.dark)
        .task {
            // 首次出现时重投影（AppModel.init 已加载过一次，这里兜住「窗口重建」）
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

    // MARK: - 侧边导航

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Residue")
                .font(Tokens.Typography.pageTitle)
                .foregroundStyle(Tokens.Color.textPrimary)
                .padding(.horizontal, Tokens.Spacing.s)
                .padding(.vertical, Tokens.Spacing.m)

            ForEach(Page.allCases) { page in
                NavRow(
                    page: page,
                    selected: selection == page,
                    action: { selection = page }
                )
            }

            Spacer()

            // 底部状态（不占信号色——信号色留给主行动）
            Text("本机 · 零外发")
                .font(Tokens.Typography.secondary)
                .foregroundStyle(Tokens.Color.textSecondary)
                .padding(Tokens.Spacing.s)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Tokens.Color.surface)
    }

    // MARK: - 页头

    private var header: some View {
        HStack {
            Text(selection.title)
                .font(Tokens.Typography.pageTitle)
                .foregroundStyle(Tokens.Color.textPrimary)

            Spacer()

            // ---- 扫描进度（**扫描期间必须有反馈**）----
            //
            // ## 为什么必须有这一行
            //
            // 扫描是重 I/O（实测本机：`~/.cache/uv` 115,875 项 ≈ 6.44 s，
            // `~/.npm/_npx` 106,983 项 ≈ 6.79 s —— 合计约 13 秒）。
            //
            // 即便把扫描搬到后台线程，**没有这一行的话用户看到的就是「按了没反应」**
            // —— 界面能动，但没有任何反馈。那和卡死的差别只是「能拖动了」，
            // 用户仍然不知道它在干什么、多久能好、要不要继续等。
            //
            // 所以「搬走」与「汇报」是**两件都必须做的事**。
            if app.isScanning, !app.scanProgress.displayText.isEmpty {
                Text(app.scanProgress.displayText)
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(Tokens.Color.textSecondary)
                    .monospacedDigit()
            }

            // 扫描（真实触发 ScanEngine；只读态禁用）
            Button(app.isScanning ? "扫描中…" : "扫描") {
                Task { await app.runScan() }
            }
            .buttonStyle(SecondaryButtonStyle(enabled: !app.isScanning && !model.readOnly))
            .disabled(app.isScanning || model.readOnly)

            // ---- 取消（**13 秒不能反悔**）----
            //
            // 契约：`E-104`「用户取消」—— **取消不是失败**，
            // 它落断点、且**不计入计数日**（M1）。
            if app.isScanning {
                Button("取消") { app.cancelScan() }
                    .buttonStyle(SecondaryButtonStyle(enabled: true))
            }

            if selection == .confirm {
                // ⚠️ 不用 `.borderedProminent`：系统样式自带配色与圆角，
                // token 不起作用；且它在离屏渲染下会退化成占位符（申必过 C5 也提过）。
                Button("清理…") { showConfirmDrawer = true }
                    .buttonStyle(PrimaryButtonStyle(enabled: !model.readOnly))
                    .disabled(model.readOnly)
            }
        }
        .padding(.horizontal, Tokens.Spacing.m)
        .padding(.vertical, Tokens.Spacing.s)
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
                // **真的执行**，不是只关抽屉。
                // 原先 `onConfirm` 只写 `showConfirmDrawer = false` ——
                // 那是「点了确认，界面关了，什么都没删，也不报错」，
                // 比不做更糟：它让用户以为清理过了。
                onConfirm: {
                    showConfirmDrawer = false
                    Task { await app.executeBatch() }
                },
                onCancel: { selection = .overview }
            )
        case .evidence:
            // AC-13 G-5：导出脱敏报告（**原先是空实现**，等于 AC-13 有一条要求没落点）
            EvidencePage(
                model: model,
                onExport: { app.exportReportInteractive() },
                onRestore: { record in app.restore(record) }
            )
        }
    }
}

/// 一行导航。
struct NavRow: View {
    let page: Page
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Spacing.xs) {
                Image(systemName: page.symbolName)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(page.title)
                    .font(Tokens.Typography.body)
                Spacer()
            }
            .foregroundStyle(selected ? Tokens.Color.textPrimary : Tokens.Color.textSecondary)
            .padding(.horizontal, Tokens.Spacing.s)
            .frame(height: 30)
            // ⚠️ 选中态**不能用信号色**：视觉基线 §二 规定「一个界面上信号色最多出现一次」，
            //    而它要留给主行动（按钮 / 焦点）。侧栏选中态占用这个名额后，
            //    ② 页会变成 3 次、④ 页 2 次、⑦ 页 2 次 —— DAC-25/26 判不通过。
            //    改用主文字色的低透明度：视觉上仍是「选中」，但不消耗信号色预算。
            .background(selected ? Tokens.Color.textPrimary.opacity(0.08) : .clear)
        }
        .buttonStyle(.plain)
    }
}
