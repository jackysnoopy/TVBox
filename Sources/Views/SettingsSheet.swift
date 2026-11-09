import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 设置面板：目录刷新、自定义源导入（链接 / 本地文件）、源管理与快捷键说明。
struct SettingsSheet: View {
    @EnvironmentObject private var app: AppCoordinator
    @EnvironmentObject private var store: ChannelStore
    @Environment(\.dismiss) private var dismiss

    @State private var linkText: String = ""
    @State private var feedback: String = ""
    @State private var isBusy: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Palette.stroke)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    catalogSection
                    importSection
                    customSourceSection
                    shortcutSection
                }
                .padding(18)
            }
            Divider().overlay(Palette.stroke)
            footer
        }
        .frame(width: 580, height: 560)
        .background(Palette.background)
        .foregroundColor(Palette.primaryText)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("设置")
                .font(.system(size: 16, weight: .bold))
            Text("TVBox")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Palette.secondaryText)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    // MARK: - 目录

    private var catalogSection: some View {
        sectionBox(title: "频道目录", subtitle: "内置目录随 App 分发，启动后自动后台增量刷新") {
            HStack(spacing: 18) {
                metric(title: "频道", value: "\(store.channels.count)")
                metric(title: "流", value: "\(totalStreams)")
                metric(title: "生成时间", value: String(store.catalogGeneratedAt.prefix(19)))
            }
            HStack(spacing: 10) {
                Button {
                    isBusy = true
                    feedback = "正在刷新…"
                    store.refreshCatalog { message in
                        isBusy = false
                        feedback = message
                    }
                } label: {
                    Label("立即刷新", systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .disabled(store.isRefreshing)

                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            Text("刷新只更新流地址，不改变台号，避免「101 台今天变成别的频道」。")
                .font(.system(size: 10))
                .foregroundColor(Palette.secondaryText)
        }
    }

    private var totalStreams: Int {
        store.channels.reduce(0) { $0 + $1.streams.count }
    }

    // MARK: - 导入

    private var importSection: some View {
        sectionBox(title: "导入自定义源", subtitle: "解析后并入「自定义」分组，台号 900 起，重启后仍在") {
            HStack(spacing: 8) {
                TextField("粘贴 m3u / m3u8 链接", text: $linkText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Palette.stroke, lineWidth: 1)
                    )
                Button {
                    isBusy = true
                    feedback = "正在下载并解析…"
                    store.importRemotePlaylist(urlString: linkText) { message in
                        isBusy = false
                        feedback = message
                    }
                } label: {
                    Text("导入链接")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .disabled(linkText.trimmingCharacters(in: .whitespaces).isEmpty)

                Button {
                    chooseLocalFile()
                } label: {
                    Label("选择本地文件", systemImage: "doc.badge.plus")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
            }
            if isBusy {
                ProgressView().controlSize(.small)
            }
            if !feedback.isEmpty {
                Text(feedback)
                    .font(.system(size: 10.5))
                    .foregroundColor(Palette.warning)
                    .lineLimit(2)
            }
        }
    }

    // MARK: - 已导入的源

    private var customSourceSection: some View {
        sectionBox(title: "已导入的自定义源", subtitle: "删除后对应频道立即从列表移除") {
            if store.customSources.isEmpty {
                Text("还没有自定义源。支持 m3u 链接与本地 .m3u / .m3u8 文件。")
                    .font(.system(size: 10.5))
                    .foregroundColor(Palette.secondaryText)
            } else {
                VStack(spacing: 6) {
                    ForEach(store.customSources) { source in
                        HStack(spacing: 10) {
                            Image(systemName: "square.stack.3d.up")
                                .font(.system(size: 11))
                                .foregroundColor(Palette.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(source.title)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .lineLimit(1)
                                Text("\(source.channels.count) 个频道 / \(source.streamCount) 条流")
                                    .font(.system(size: 9.5))
                                    .foregroundColor(Palette.secondaryText)
                            }
                            Spacer()
                            Button {
                                store.removeCustomSource(source)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 10.5))
                                    .foregroundColor(Palette.danger)
                            }
                            .buttonStyle(.plain)
                            .help("删除该源")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.white.opacity(0.04))
                        )
                    }
                }
            }
        }
    }

    // MARK: - 快捷键

    private var shortcutSection: some View {
        sectionBox(title: "遥控快捷键", subtitle: "无需点界面，像机顶盒一样操作") {
            VStack(alignment: .leading, spacing: 5) {
                shortcut("数字键", "输入台号直选（1.5 秒内累积）")
                shortcut("↑ / ↓", "上一个 / 下一个频道")
                shortcut("空格", "暂停 / 继续")
                shortcut("← / →", "快退 15 秒 / 回到直播")
                shortcut("F / 双击", "全屏切换")
                shortcut("Esc", "退出全屏 / 清空输入")
                shortcut("M", "静音")
                shortcut("Tab / ⌘F", "进入搜索")
            }
        }
    }

    private func shortcut(_ keys: String, _ description: String) -> some View {
        HStack(spacing: 10) {
            Text(keys)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Palette.accent)
                .frame(width: 66, alignment: .leading)
            Text(description)
                .font(.system(size: 10.5))
                .foregroundColor(Palette.secondaryText)
        }
    }

    // MARK: - 组件

    private func sectionBox<Content: View>(title: String,
                                          subtitle: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(Palette.secondaryText)
            }
            content()
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
        )
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9))
                .foregroundColor(Palette.secondaryText)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
    }

    private var footer: some View {
        HStack {
            Text(store.statusMessage)
                .font(.system(size: 10))
                .foregroundColor(Palette.secondaryText)
                .lineLimit(1)
            Spacer()
            Button("完成") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    // MARK: - 本地文件

    private func chooseLocalFile() {
        let panel = NSOpenPanel()
        panel.title = "选择 m3u / m3u8 播放列表"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var types: [UTType] = []
        if let m3u = UTType(filenameExtension: "m3u") { types.append(m3u) }
        if let m3u8 = UTType(filenameExtension: "m3u8") { types.append(m3u8) }
        panel.allowedContentTypes = types.isEmpty ? [UTType.data] : types
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isBusy = true
        store.importPlaylistFile(url) { message in
            isBusy = false
            feedback = message
        }
    }
}
