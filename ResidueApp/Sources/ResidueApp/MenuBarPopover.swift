import SwiftUI
import AppKit
import ResidueCore

// ============================================================
// Residue · 菜单栏浮层（视觉基线 v2 · CR-031 §四）
//
// `.menu` 只能放系统菜单项，信息密度为零；改成 `.window` 后，
// 用户点开菜单栏就能看到「占了多少 / 能释放多少 / 观察期第几天」，
// 不用先打开主窗口。数据全部来自同一个 `PageModel`，**不在视图里算**。
//
// 尺寸 360 × 404：macOS 菜单栏浮层常见宽度，三段信息刚好一屏。
// ============================================================

struct MenuBarPopover: View {
    let model: PageModel
    var isScanning: Bool = false
    var onOpen: () -> Void = {}
    var onScan: () -> Void = {}
    var onQuit: () -> Void = { NSApplication.shared.terminate(nil) }
    @Environment(\.residueRenderMode) private var renderMode

    var body: some View {
        VStack(spacing: 0) {
            header
            DividerLine()

            // 离屏渲染不渲染 `ScrollView` 内容（见 `Pages.swift` 顶部说明）。
            if renderMode {
                info
            } else {
                ScrollView { info }
            }

            Spacer(minLength: 0)
            DividerLine()
            actions
        }
        // CR-032：来源由 3 个扩到 5 个 → 浮层加两行（每行约 20 pt），
        // 由 404 pt 增至 444 pt；否则底部「打开主界面 / 立即扫描」会被裁掉。
        .frame(width: 360, height: 444)
        .background(Tokens.Color.background)
        .preferredColorScheme(.dark)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            totals
            DividerLine()
            sourceList
            gateNote
        }
        .padding(Tokens.Spacing.m)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            RoundedRectangle(cornerRadius: 5)
                .fill(
                    LinearGradient(
                        colors: [Tokens.Color.signal, SwiftUI.Color(hex: 0x8B6CF0)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 22, height: 22)
                .overlay(
                    Image(systemName: "circle.hexagongrid.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                )

            VStack(alignment: .leading, spacing: 0) {
                Text("Residue")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.Color.textPrimary)
                Text(L.pick("本机 · 零外发", "On-device · No outbound"))
                    .font(.system(size: 9))
                    .foregroundStyle(Tokens.Color.textTertiary)
            }

            Spacer()

            if isScanning {
                Text(L.pick("扫描中…", "Scanning…"))
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(Tokens.Color.textSecondary)
            }

            Button(action: onOpen) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Tokens.Color.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(
                        Tokens.Color.surface,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.control)
                    )
            }
            .buttonStyle(.plain)
            .help(L.pick("打开主界面", "Open main window"))
        }
        .padding(.horizontal, Tokens.Spacing.m)
        .padding(.vertical, Tokens.Spacing.s)
    }

    // MARK: - 总量 / 可释放 / 观察期

    private var totals: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            HStack(alignment: .top, spacing: Tokens.Spacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.pick("本机缓存", "Cache on this Mac"))
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(Tokens.Color.textSecondary)
                    SemanticSlotView(
                        slot: model.totalScannedSlot,
                        font: Tokens.Typography.numberHero
                    )
                    .foregroundStyle(Tokens.Color.textPrimary)

                    HStack(spacing: 6) {
                        Text(L.pick("可释放条目", "Reclaimable"))
                            .font(.system(size: 10))
                            .foregroundStyle(Tokens.Color.textTertiary)
                        SemanticSlotView(slot: model.deletableAmount, font: Tokens.Typography.numberMedium)
                            .foregroundStyle(Tokens.Color.textSecondary)
                        if let share = model.reclaimableShare {
                            Text(L.pick("字节占比", "Byte share"))
                                .font(.system(size: 10))
                                .foregroundStyle(Tokens.Color.textTertiary)
                            SemanticSlotView(slot: share.percentSlot, font: Tokens.Typography.secondary)
                                .foregroundStyle(Tokens.Color.textTertiary)
                        }
                    }
                }

                Spacer(minLength: 0)

                VStack(spacing: 4) {
                    ObservationRing(ratio: model.observationRatio, lineWidth: 5, diameter: 52)
                        .overlay(
                            Image(systemName: "hourglass")
                                .font(.system(size: 11))
                                .foregroundStyle(Tokens.Color.textSecondary)
                        )
                    HStack(spacing: 2) {
                        SemanticSlotView(slot: model.observationDaySlot, font: Tokens.Typography.numberSmall)
                        Text(L.pick("天", "days"))
                            .font(.system(size: 9))
                            .foregroundStyle(Tokens.Color.textTertiary)
                    }
                }
            }
        }
    }

    // MARK: - 来源列表

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.pick("来源构成", "By source"))
                .font(Tokens.Typography.secondary)
                .foregroundStyle(Tokens.Color.textSecondary)

            ForEach(model.sourceShares) { row in
                HStack(spacing: Tokens.Spacing.xs) {
                    SourceDot(sourceKey: row.sourceKey)

                    Text(row.displayName)
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(Tokens.Color.textPrimary)
                        .frame(width: 72, alignment: .leading)

                    RatioBarView(
                        slot: row.share,
                        color: Tokens.Color.source(for: row.sourceKey),
                        height: 4
                    )

                    SemanticSlotView(slot: row.bytes, font: Tokens.Typography.numberSmall)
                        .foregroundStyle(Tokens.Color.textSecondary)
                        .frame(width: 62, alignment: .trailing)
                }
                .frame(height: 20)
            }
        }
    }

    private var gateNote: some View {
        HStack(spacing: Tokens.Spacing.xxs) {
            Image(systemName: model.canLightUp ? "checkmark.shield" : "lock.shield")
                .font(.system(size: 10))
            Text(
                model.canLightUp
                    ? L.pick("已达达标条件，可在主界面执行", "Gate met; runnable in the main window")
                    : L.pick("未达达标条件，不会执行任何删除", "Gate not met; nothing is deleted")
            )
            .font(Tokens.Typography.secondary)
            Spacer(minLength: 0)
        }
        .foregroundStyle(model.canLightUp ? Tokens.Color.success : Tokens.Color.textTertiary)
        .padding(.horizontal, Tokens.Spacing.xs)
        .padding(.vertical, 6)
        .background(
            Tokens.Color.surface,
            in: RoundedRectangle(cornerRadius: Tokens.Radius.control)
        )
    }

    // MARK: - 底部动作

    private var actions: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Button(L.pick("打开主界面", "Open"), action: onOpen)
                .buttonStyle(PrimaryButtonStyle(enabled: true))

            Button(isScanning ? L.pick("扫描中…", "Scanning…") : L.pick("立即扫描", "Scan now")) {
                onScan()
            }
            .buttonStyle(SecondaryButtonStyle(enabled: !isScanning && !model.readOnly))
            .disabled(isScanning || model.readOnly)

            Spacer()

            Button(action: onQuit) {
                Image(systemName: "power")
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.Color.textSecondary)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help(L.pick("退出 Residue", "Quit Residue"))
        }
        .padding(.horizontal, Tokens.Spacing.m)
        .padding(.vertical, Tokens.Spacing.s)
    }
}
