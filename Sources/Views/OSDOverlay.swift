import AppKit
import SwiftUI

/// 电视风深色配色（黑底 / 字幕白 / 选中高亮）。
enum Palette {
    static let background = Color(red: 0.035, green: 0.045, blue: 0.065)
    static let sidebar = Color(red: 0.07, green: 0.08, blue: 0.11)
    static let stroke = Color.white.opacity(0.08)
    static let primaryText = Color.white.opacity(0.95)
    static let secondaryText = Color.white.opacity(0.55)
    static let accent = Color(red: 0.26, green: 0.76, blue: 0.96)
    static let live = Color(red: 0.35, green: 0.86, blue: 0.56)
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.26)
    static let danger = Color(red: 0.95, green: 0.36, blue: 0.36)

    static func statusColor(level: Int) -> Color {
        switch level {
        case 2: return live
        case 1: return warning
        default: return danger
        }
    }
}

/// OSD 浮层：台号 / 台名 / 台标 / 清晰度 / 信号状态；切台 3 秒后淡出。
struct OSDOverlay: View {
    @EnvironmentObject private var app: AppCoordinator
    @EnvironmentObject private var engine: PlaybackEngine

    /// 切台 / 换源 / 失败时信息卡保持可见，其余情况 3 秒后淡出。
    private var infoVisible: Bool {
        app.osdVisible || engine.state.status == .switching
    }

    var body: some View {
        ZStack {
            if engine.state.status == .failed {
                failurePanel
            }
            if !app.numberInput.isEmpty {
                numberInputBadge
            }
            VStack {
                Spacer()
                HStack(alignment: .bottom, spacing: 16) {
                    infoCard
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 22)
            }
            .opacity(infoVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.28), value: infoVisible)
        }
        .allowsHitTesting(engine.state.status == .failed || !app.numberInput.isEmpty)
    }

    // MARK: - 底部信息卡

    private var infoCard: some View {
        HStack(alignment: .center, spacing: 14) {
            numberBadge
            logoView
            VStack(alignment: .leading, spacing: 4) {
                Text(engine.state.channel?.name ?? "未选择频道")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(Palette.primaryText)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    statusPill
                    if engine.state.isCuratedStream {
                        Text("精选源")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Palette.live)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Palette.live.opacity(0.16)))
                    }
                    Text(engine.state.detailLine.isEmpty
                         ? engine.state.status.label
                         : engine.state.detailLine)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Palette.secondaryText)
                        .lineLimit(1)
                }
            }
            VStack(alignment: .trailing, spacing: 3) {
                Image(systemName: engine.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(engine.isMuted ? Palette.warning : Palette.secondaryText)
                Text("\(Int((engine.volume * 100).rounded()))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Palette.secondaryText)
            }
            .frame(width: 40)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
    }

    private var numberBadge: some View {
        Text(engine.state.channel?.formattedNumber ?? "---")
            .font(.system(size: 22, weight: .bold, design: .monospaced))
            .foregroundColor(Palette.accent)
            .frame(minWidth: 62, minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Palette.accent.opacity(0.14))
            )
    }

    /// 台标：内置 bundle 文件优先 → 远端兜底 → 文字徽标占位。
    @ViewBuilder
    private var logoView: some View {
        if let channel = engine.state.channel {
            ChannelLogoView(channel: channel, size: 52, cornerRadius: 10)
                .id(channel.id)  // 换台必须换视图，否则 @State 里的旧台标会残留
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .frame(width: 52, height: 52)
                .overlay(
                    Image(systemName: "tv")
                        .font(.system(size: 20))
                        .foregroundColor(Palette.secondaryText)
                )
        }
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Palette.statusColor(level: engine.state.status.level))
                .frame(width: 7, height: 7)
            Text(engine.state.status.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Palette.statusColor(level: engine.state.status.level))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Palette.statusColor(level: engine.state.status.level).opacity(0.14))
        )
    }

    // MARK: - 数字键输入提示

    private var numberInputBadge: some View {
        VStack(spacing: 6) {
            Text(app.numberInput)
                .font(.system(size: 64, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
            Text("输入台号后自动切台")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Palette.secondaryText)
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Palette.accent.opacity(0.55), lineWidth: 1.5)
        )
        .transition(.opacity)
    }

    // MARK: - 无可用源

    private var failurePanel: some View {
        VStack(spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(Palette.danger)
            Text("该频道当前无可用源")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Palette.primaryText)
            Text(engine.state.channel?.name ?? "")
                .font(.system(size: 12))
                .foregroundColor(Palette.secondaryText)
            HStack(spacing: 10) {
                Button {
                    engine.retryCurrentChannel()
                    app.bumpOSD()
                } label: {
                    Text("重试")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Palette.accent))
                }
                .buttonStyle(.plain)

                // 公网确实没有源时，给一个去看官方直播的出口（浏览器打开）。
                if let page = officialPageURL {
                    Button {
                        NSWorkspace.shared.open(page)
                        app.bumpOSD()
                    } label: {
                        Label("打开官方直播页", systemImage: "safari")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Palette.primaryText)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().stroke(Palette.primaryText.opacity(0.35), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("在系统浏览器里打开 \(page.absoluteString)")
                }
            }
            Text("↑/↓ 换台 · 数字键直选")
                .font(.system(size: 11))
                .foregroundColor(Palette.secondaryText)
        }
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Palette.danger.opacity(0.4), lineWidth: 1)
        )
    }

    /// 当前频道的官方直播页（没有就返回 nil，按钮不显示）。
    private var officialPageURL: URL? {
        guard let channel = engine.state.channel else { return nil }
        return ChannelOfficialPage.url(for: channel)
    }
}
