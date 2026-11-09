import SwiftUI

/// 主界面：左侧频道列表 + 右侧播放区（含 OSD 与顶部控制）。
struct ContentView: View {
    @EnvironmentObject private var app: AppCoordinator
    @EnvironmentObject private var store: ChannelStore
    @EnvironmentObject private var engine: PlaybackEngine

    var body: some View {
        HStack(spacing: 0) {
            // 收起时整块从布局里移除（不是宽度压 0），播放区自然占满全宽。
            if app.isSidebarVisible {
                SidebarView()
                    .frame(width: 320)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            playerArea
        }
        .animation(.easeInOut(duration: 0.2), value: app.isSidebarVisible)
        .frame(minWidth: 900, minHeight: 600)
        .background(Palette.background)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $app.showingSettings) {
            SettingsSheet()
                .environmentObject(app)
                .environmentObject(store)
                .environmentObject(engine)
        }
        .onAppear {
            app.bootstrap()
        }
    }

    // MARK: - 播放区

    private var playerArea: some View {
        ZStack {
            Color.black
            PlayerLayerView(player: engine.player) {
                app.toggleFullScreen()
            }
            OSDOverlay()
            // 全屏（纯画面）时顶栏跟侧栏一起隐藏；全屏中按 S 呼出侧栏时顶栏一并出现。
            if !app.isFullScreen || app.isSidebarVisible {
                VStack {
                    topBar
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if store.isLoading {
                loadingOverlay
            }
        }
        .animation(.easeInOut(duration: 0.2), value: app.isSidebarVisible)
        .animation(.easeInOut(duration: 0.2), value: app.isFullScreen)
        .clipped()
    }

    private var loadingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("正在载入频道目录…")
                .font(.system(size: 12))
                .foregroundColor(Palette.secondaryText)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.6))
        )
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            if let channel = engine.state.channel ?? store.currentChannel {
                Text(channel.formattedNumber)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Palette.accent)
                Text(channel.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Palette.primaryText.opacity(0.9))
                    .lineLimit(1)
            }
            Spacer()
            controlButton(symbol: "sidebar.left",
                          help: app.isSidebarVisible ? "收起侧栏 (S)" : "展开侧栏 (S)") {
                app.toggleSidebar()
            }
            controlButton(symbol: engine.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                          help: "静音 (M)") {
                engine.toggleMute()
                app.bumpOSD()
            }
            if let channel = store.currentChannel {
                controlButton(symbol: store.isFavorite(channel) ? "star.fill" : "star",
                              help: "收藏当前频道") {
                    store.toggleFavorite(channel)
                    app.bumpOSD()
                }
            }
            controlButton(symbol: "slider.horizontal.3", help: "设置 / 导入源") {
                app.showSettings()
            }
            controlButton(symbol: "arrow.up.left.and.arrow.down.right", help: "全屏 (F)") {
                app.toggleFullScreen()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            LinearGradient(colors: [Color.black.opacity(0.55), Color.black.opacity(0.0)],
                           startPoint: .top,
                           endPoint: .bottom)
        )
    }

    private func controlButton(symbol: String,
                               help: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Palette.primaryText.opacity(0.85))
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
