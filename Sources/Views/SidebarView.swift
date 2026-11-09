import SwiftUI

/// 左侧频道侧栏：收藏（置顶）+ 固定分组 + 搜索。
struct SidebarView: View {
    @EnvironmentObject private var app: AppCoordinator
    @EnvironmentObject private var store: ChannelStore
    @State private var collapsedGroups: Set<String> = []
    @State private var favoritesCollapsed: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            SearchBar(text: searchTextBinding, isFocused: $app.searchFocused)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            Divider().overlay(Palette.stroke)
            content
            Divider().overlay(Palette.stroke)
            footer
        }
        .background(Palette.sidebar)
    }

    // MARK: - 头部

    /// 搜索词存在 ChannelStore 里，这里手工建立双向绑定。
    private var searchTextBinding: Binding<String> {
        Binding(get: { store.searchText },
                set: { store.searchText = $0 })
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "tv.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Palette.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("TVBox")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Palette.primaryText)
                Text("\(store.channels.count) 个频道")
                    .font(.system(size: 10))
                    .foregroundColor(Palette.secondaryText)
            }
            Spacer()
            Button {
                app.showSettings()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Palette.secondaryText)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("设置 / 导入自定义源")
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - 列表

    @ViewBuilder
    private var content: some View {
        if store.isLoading {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在载入频道目录…")
                    .font(.system(size: 11))
                    .foregroundColor(Palette.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        favoritesSection
                        ForEach(store.visibleGroups, id: \.group) { item in
                            section(group: item.group, channels: item.channels)
                        }
                        if store.visibleGroups.isEmpty {
                            Text("没有匹配的频道")
                                .font(.system(size: 11))
                                .foregroundColor(Palette.secondaryText)
                                .padding(16)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: store.currentChannelID) { newValue in
                    guard let identifier = newValue,
                          let channel = store.channels.first(where: { $0.id == identifier }) else {
                        return
                    }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo("\(channel.group.rawValue)|\(channel.id)", anchor: .center)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20))
                .foregroundColor(Palette.warning)
            Text("频道目录为空")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Palette.primaryText)
            Text(store.statusMessage)
                .font(.system(size: 10))
                .foregroundColor(Palette.secondaryText)
                .multilineTextAlignment(.center)
            Text("可先运行 tools/bake_catalog.py 生成目录")
                .font(.system(size: 10))
                .foregroundColor(Palette.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var favoritesSection: some View {
        let items = store.favoriteChannels
        if !items.isEmpty {
            groupHeader(title: "收藏", symbol: "star.fill", count: items.count,
                        collapsed: favoritesCollapsed) {
                favoritesCollapsed.toggle()
            }
            if !favoritesCollapsed {
                ForEach(items) { channel in
                    row(channel, scope: "fav")
                }
            }
        }
    }

    @ViewBuilder
    private func section(group: ChannelGroup, channels: [Channel]) -> some View {
        let collapsed = collapsedGroups.contains(group.id)
        groupHeader(title: group.title, symbol: group.symbolName, count: channels.count,
                    collapsed: collapsed) {
            if collapsed {
                collapsedGroups.remove(group.id)
            } else {
                collapsedGroups.insert(group.id)
            }
        }
        if !collapsed {
            ForEach(channels) { channel in
                row(channel, scope: group.rawValue)
            }
        }
    }

    private func groupHeader(title: String,
                             symbol: String,
                             count: Int,
                             collapsed: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(Palette.secondaryText)
                    .frame(width: 10)
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Palette.accent.opacity(0.85))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Palette.primaryText.opacity(0.9))
                Text("\(count)")
                    .font(.system(size: 10))
                    .foregroundColor(Palette.secondaryText)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    /// 同一频道会同时出现在「收藏」和它自己的分组里，行 id 必须带分组前缀才唯一，
    /// 否则 LazyVStack 会因为重复 id 丢掉其中一行。
    private func row(_ channel: Channel, scope: String) -> some View {
        ChannelRowView(channel: channel,
                       isCurrent: store.currentChannelID == channel.id,
                       isFavorite: store.isFavorite(channel),
                       onSelect: { app.zap(to: channel) },
                       onToggleFavorite: { store.toggleFavorite(channel) })
            .id("\(scope)|\(channel.id)")
    }

    // MARK: - 底部状态

    private var footer: some View {
        HStack(spacing: 6) {
            if store.isRefreshing {
                ProgressView().controlSize(.mini)
            } else {
                Circle()
                    .fill(Palette.live.opacity(0.8))
                    .frame(width: 5, height: 5)
            }
            Text(store.statusMessage)
                .font(.system(size: 9.5))
                .foregroundColor(Palette.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("目录 \(store.catalogGeneratedAt.prefix(10))")
                .font(.system(size: 9))
                .foregroundColor(Palette.secondaryText.opacity(0.7))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

/// 单个频道行。
private struct ChannelRowView: View {
    let channel: Channel
    let isCurrent: Bool
    let isFavorite: Bool
    let onSelect: () -> Void
    let onToggleFavorite: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 9) {
                Text(channel.formattedNumber)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(isCurrent ? Palette.accent : Palette.secondaryText)
                    .frame(width: 30, alignment: .leading)

                logo

                VStack(alignment: .leading, spacing: 1) {
                    Text(channel.name)
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                        .foregroundColor(isCurrent ? Palette.primaryText : Palette.primaryText.opacity(0.82))
                        .lineLimit(1)
                    if !channel.subtitle.isEmpty {
                        Text(channel.subtitle)
                            .font(.system(size: 9.5))
                            .foregroundColor(Palette.secondaryText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.system(size: 10.5))
                        .foregroundColor(isFavorite ? Palette.warning : Palette.secondaryText.opacity(hovering ? 0.9 : 0.35))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isFavorite ? "取消收藏" : "收藏")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isCurrent
                          ? Palette.accent.opacity(0.16)
                          : (hovering ? Color.white.opacity(0.05) : Color.clear))
            )
            .overlay(alignment: .leading) {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Palette.accent)
                        .frame(width: 2.5, height: 18)
                        .padding(.leading, 3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    /// 台标：内置 bundle 文件优先 → 远端兜底 → `tv` 占位。
    private var logo: some View {
        ChannelLogoView(channel: channel, size: 18, cornerRadius: 3)
    }
}
