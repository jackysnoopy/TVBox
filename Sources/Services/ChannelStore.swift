import Combine
import Foundation

/// 频道数据仓库：目录载入、分组归并、收藏、自定义源、搜索。
/// 只依赖 Foundation / Combine，方便用 CLI 单测直接编译。
final class ChannelStore: ObservableObject {

    // MARK: - 输出状态

    @Published private(set) var channels: [Channel] = []
    @Published private(set) var customSources: [CustomSource] = []
    @Published private(set) var favorites: Set<String> = []
    @Published private(set) var currentChannelID: String?
    @Published private(set) var isLoading: Bool = true
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var statusMessage: String = ""
    @Published private(set) var catalogGeneratedAt: String = "内置目录"

    /// 搜索词由 UI 双向绑定。
    @Published var searchText: String = ""

    // MARK: - 内部状态

    private let catalog: CatalogService
    private let defaults: UserDefaults
    private var builtinChannels: [Channel] = []
    private static let favoritesKey = "tvbox.favorites.v1"
    private static let lastChannelKey = "tvbox.lastChannel.v1"

    init(catalog: CatalogService = CatalogService(), defaults: UserDefaults = .standard) {
        self.catalog = catalog
        self.defaults = defaults
        self.favorites = FavoritesCodec.decode(defaults.string(forKey: Self.favoritesKey) ?? "")
    }

    // MARK: - 载入

    /// 冷启动：优先内置目录（秒开），缓存更新则用缓存。
    func load() {
        isLoading = true
        do {
            let bundled = try catalog.loadBundled()
            var list = bundled.channels
            var stamp = bundled.generatedAt ?? "内置目录"
            if let cached = catalog.loadCached(),
               let bundledStamp = bundled.generatedAt,
               let cachedStamp = cached.generatedAt,
               cachedStamp > bundledStamp,
               !cached.channels.isEmpty {
                list = cached.channels
                stamp = cachedStamp
            }
            builtinChannels = list
            catalogGeneratedAt = stamp
            customSources = catalog.loadCustomSources()
            rebuild()
            statusMessage = "已载入 \(channels.count) 个频道"
            if let saved = defaults.string(forKey: Self.lastChannelKey) {
                currentChannelID = channels.contains(where: { $0.id == saved }) ? saved : nil
            }
        } catch {
            builtinChannels = []
            customSources = []
            rebuild()
            statusMessage = (error as? LocalizedError)?.errorDescription ?? "频道目录载入失败"
        }
        isLoading = false
    }

    /// 后台增量刷新流地址（不重排台号）。
    func refreshCatalog(completion: ((String) -> Void)? = nil) {
        guard !isRefreshing, !builtinChannels.isEmpty else {
            completion?("暂无可刷新的目录")
            return
        }
        isRefreshing = true
        statusMessage = "正在后台刷新频道目录…"
        catalog.refresh(existing: builtinChannels) { [weak self] outcome in
            guard let self = self else { return }
            self.isRefreshing = false
            if let error = outcome.errorMessage {
                // 静默降级：继续用现有目录，不打断播放。
                self.statusMessage = "刷新未完成，继续使用本地目录"
                completion?(error)
                return
            }
            self.builtinChannels = outcome.channels
            self.catalogGeneratedAt = CatalogService.timestamp()
            self.rebuild()
            let summary = "目录已刷新：\(outcome.updatedChannels) 个频道 / \(outcome.totalStreams) 条流"
            self.statusMessage = summary
            completion?(summary)
        }
    }

    private func rebuild() {
        let custom = customSources.flatMap { $0.channels }
        let numbered = ChannelNumbering.assignNumbers(builtinChannels + custom)
        channels = numbered.sorted { lhs, rhs in
            if lhs.number != rhs.number { return lhs.number < rhs.number }
            return lhs.name < rhs.name
        }

        // 把分配到的台号写回自定义源，保证下次启动/再导入时台号不漂移。
        var numberByID: [String: Int] = [:]
        numberByID.reserveCapacity(numbered.count)
        for channel in numbered {
            numberByID[channel.id] = channel.number
        }
        var updatedSources = customSources
        var changed = false
        for sourceIndex in updatedSources.indices {
            for channelIndex in updatedSources[sourceIndex].channels.indices {
                let identifier = updatedSources[sourceIndex].channels[channelIndex].id
                guard let number = numberByID[identifier] else { continue }
                if updatedSources[sourceIndex].channels[channelIndex].number != number {
                    updatedSources[sourceIndex].channels[channelIndex].number = number
                    changed = true
                }
            }
        }
        if changed {
            customSources = updatedSources
            catalog.saveCustomSources(updatedSources)
        }
    }

    // MARK: - 查询

    var isEmpty: Bool { channels.isEmpty }

    /// 上下键切换用的列表：有搜索词时只在搜索结果里切。
    var zapList: [Channel] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if keyword.isEmpty { return channels }
        let filtered = ChannelSearch.filter(channels, query: keyword)
        return filtered.isEmpty ? channels : filtered
    }

    var currentChannel: Channel? {
        guard let identifier = currentChannelID else { return nil }
        return channels.first { $0.id == identifier }
    }

    func channels(in group: ChannelGroup) -> [Channel] {
        ChannelSearch.filter(channels.filter { $0.group == group }, query: searchText)
    }

    var favoriteChannels: [Channel] {
        ChannelSearch.filter(channels.filter { favorites.contains($0.id) }, query: searchText)
    }

    /// 分组列表：收藏置顶，空分组不展示。
    var visibleGroups: [(group: ChannelGroup, channels: [Channel])] {
        ChannelGroup.allCases.compactMap { group in
            let items = channels(in: group)
            return items.isEmpty ? nil : (group, items)
        }
    }

    /// 按台号查找（数字键直选）。
    func channel(number: Int) -> Channel? {
        channels.first { $0.number == number }
    }

    /// 按输入串查找：优先精确台号，其次台号前缀（"05" → 005）。
    func channel(matching digits: String) -> Channel? {
        let trimmed = digits.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let exact = Int(trimmed), let hit = channel(number: exact) {
            return hit
        }
        return channels.first { $0.formattedNumber.hasPrefix(trimmed) }
    }

    /// 相对当前频道上下切换（循环）。
    func channel(offsetFrom current: String?, step: Int) -> Channel? {
        let list = zapList
        guard !list.isEmpty else { return nil }
        guard let identifier = current,
              let index = list.firstIndex(where: { $0.id == identifier }) else {
            return list.first
        }
        let count = list.count
        let next = ((index + step) % count + count) % count
        return list[next]
    }

    func setCurrent(_ channel: Channel?) {
        currentChannelID = channel?.id
        defaults.set(channel?.id, forKey: Self.lastChannelKey)
    }

    /// 首次启动的默认频道：上次看的 → 收藏第一个 → 央视 1 台 → 第一个频道。
    func startupChannel() -> Channel? {
        if let current = currentChannel { return current }
        if let favorite = channels.first(where: { favorites.contains($0.id) }) { return favorite }
        if let cctv1 = channel(number: 1) { return cctv1 }
        return channels.first
    }

    // MARK: - 收藏

    func isFavorite(_ channel: Channel) -> Bool {
        favorites.contains(channel.id)
    }

    func toggleFavorite(_ channel: Channel) {
        if favorites.contains(channel.id) {
            favorites.remove(channel.id)
        } else {
            favorites.insert(channel.id)
        }
        defaults.set(FavoritesCodec.encode(favorites), forKey: Self.favoritesKey)
    }

    // MARK: - 自定义源

    @discardableResult
    func importRemotePlaylist(urlString: String, completion: @escaping (String) -> Void) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion("请先填写 m3u 链接")
            return false
        }
        statusMessage = "正在下载播放列表…"
        M3UParser.loadRemote(urlString: trimmed) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let entries):
                let message = self.addCustomSource(title: Self.title(for: trimmed),
                                                   origin: trimmed,
                                                   entries: entries)
                completion(message)
            case .failure(let error):
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                self.statusMessage = "导入失败：\(message)"
                completion("导入失败：\(message)")
            }
        }
        return true
    }

    @discardableResult
    func importPlaylistFile(_ fileURL: URL, completion: @escaping (String) -> Void) -> Bool {
        do {
            let entries = try M3UParser.load(fileURL: fileURL)
            let message = addCustomSource(title: fileURL.lastPathComponent,
                                          origin: fileURL.path,
                                          entries: entries)
            completion(message)
            return true
        } catch {
            let message = "读取失败：\(error.localizedDescription)"
            statusMessage = message
            completion(message)
            return false
        }
    }

    private func addCustomSource(title: String, origin: String, entries: [M3UEntry]) -> String {
        let parsed = M3UParser.channels(from: entries)
        guard !parsed.isEmpty else {
            let message = "没有解析到可用频道"
            statusMessage = message
            return message
        }
        let sourceID = UUID().uuidString
        var channels = parsed
        for index in channels.indices {
            // 加前缀避免不同源之间 id 冲突（收藏按 id 记录）。
            channels[index].id = "\(sourceID)-\(channels[index].id)"
            channels[index].number = 0
        }
        customSources.append(CustomSource(id: sourceID,
                                          title: title,
                                          origin: origin,
                                          channels: channels))
        catalog.saveCustomSources(customSources)
        rebuild()
        let message = "已导入 \(channels.count) 个频道 / \(entries.count) 条流"
        statusMessage = message
        return message
    }

    func removeCustomSource(_ source: CustomSource) {
        customSources.removeAll { $0.id == source.id }
        catalog.saveCustomSources(customSources)
        rebuild()
        if let identifier = currentChannelID, !channels.contains(where: { $0.id == identifier }) {
            currentChannelID = nil
        }
        statusMessage = "已删除自定义源「\(source.title)」"
    }

    private static func title(for urlString: String) -> String {
        if let url = URL(string: urlString), !url.lastPathComponent.isEmpty {
            return url.lastPathComponent
        }
        return urlString
    }
}
