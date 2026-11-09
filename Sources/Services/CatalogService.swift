import Foundation

/// 用户导入的自定义源（一个 m3u 链接 / 一个本地文件 = 一条记录）。
struct CustomSource: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    /// 来源描述：远端链接或本地文件路径。
    var origin: String
    var importedAt: Date
    var channels: [Channel]

    init(id: String = UUID().uuidString,
         title: String,
         origin: String,
         importedAt: Date = Date(),
         channels: [Channel]) {
        self.id = id
        self.title = title
        self.origin = origin
        self.importedAt = importedAt
        self.channels = channels
    }

    var streamCount: Int {
        channels.reduce(0) { $0 + $1.streams.count }
    }
}

/// 频道目录服务。
///
/// 冷启动只读内置 `catalog.json`（随 .app 分发，0 网络依赖）；
/// 随后在后台用 URLSession 拉 `streams.json` 增量刷新流地址（不重排台号、不改名字，
/// 因此不会出现「昨天 101 是江苏卫视，今天变成别的」）。
final class CatalogService {

    struct CatalogFile: Codable {
        var version: Int?
        var generatedAt: String?
        var source: String?
        var channelCount: Int?
        var channels: [Channel]
    }

    /// 刷新结果。
    struct RefreshOutcome {
        var channels: [Channel]
        var updatedChannels: Int
        var totalStreams: Int
        var errorMessage: String?
    }

    enum CatalogError: LocalizedError {
        case bundledMissing
        case decodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .bundledMissing: return "内置频道目录缺失（catalog.json 未打包）"
            case .decodeFailed(let reason): return "频道目录解析失败：\(reason)"
            }
        }
    }

    private static let streamsAPI = "https://iptv-org.github.io/api/streams.json"
    private let fileManager = FileManager.default

    init() {}

    // MARK: - 路径

    /// ~/Library/Application Support/TVBox
    var supportDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let directory = base.appendingPathComponent("TVBox", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    var cacheURL: URL {
        supportDirectory.appendingPathComponent("catalog-cache.json")
    }

    var customSourcesURL: URL {
        supportDirectory.appendingPathComponent("custom-sources.json")
    }

    // MARK: - 内置目录

    /// 读取随包分发的 catalog.json。
    func loadBundled() throws -> CatalogFile {
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json") else {
            throw CatalogError.bundledMissing
        }
        return try decodeCatalog(at: url)
    }

    /// 读取上次刷新写入的缓存；不存在返回 nil。
    func loadCached() -> CatalogFile? {
        guard fileManager.fileExists(atPath: cacheURL.path) else { return nil }
        return try? decodeCatalog(at: cacheURL)
    }

    func saveCache(channels: [Channel], generatedAt: String) {
        let file = CatalogFile(version: 1,
                               generatedAt: generatedAt,
                               source: Self.streamsAPI,
                               channelCount: channels.count,
                               channels: channels)
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        do {
            let data = try encoder.encode(file)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            // 缓存写失败不应影响播放，静默降级。
        }
    }

    private func decodeCatalog(at url: URL) throws -> CatalogFile {
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(CatalogFile.self, from: data)
        } catch {
            throw CatalogError.decodeFailed(error.localizedDescription)
        }
    }

    // MARK: - 自定义源

    func loadCustomSources() -> [CustomSource] {
        guard fileManager.fileExists(atPath: customSourcesURL.path) else { return [] }
        guard let data = try? Data(contentsOf: customSourcesURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([CustomSource].self, from: data)) ?? []
    }

    func saveCustomSources(_ sources: [CustomSource]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(sources) else { return }
        try? data.write(to: customSourcesURL, options: .atomic)
    }

    // MARK: - 后台刷新

    /// 只拉 `streams.json`（3.7MB），按 channel id 覆盖流列表。
    /// - Parameter existing: 当前频道（含已分配台号）
    func refresh(existing: [Channel], completion: @escaping (RefreshOutcome) -> Void) {
        guard let url = URL(string: Self.streamsAPI) else {
            completion(RefreshOutcome(channels: existing, updatedChannels: 0, totalStreams: 0,
                                      errorMessage: "刷新地址无效"))
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        // 该 API 在本机实测经常 100KB/s 左右，给足时间，避免误判失败。
        configuration.timeoutIntervalForResource = 900
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: url)
        request.setValue("TVBox/1.0 (macOS)", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            let outcome = self.handleRefresh(data: data, response: response, error: error, existing: existing)
            DispatchQueue.main.async { completion(outcome) }
        }.resume()
    }

    private struct RemoteStream: Decodable {
        var channel: String?
        var url: String?
        var quality: String?
        var user_agent: String?
        var referrer: String?
    }

    private func handleRefresh(data: Data?,
                               response: URLResponse?,
                               error: Error?,
                               existing: [Channel]) -> RefreshOutcome {
        if let error = error {
            return RefreshOutcome(channels: existing, updatedChannels: 0, totalStreams: 0,
                                  errorMessage: "刷新失败：\(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            return RefreshOutcome(channels: existing, updatedChannels: 0, totalStreams: 0,
                                  errorMessage: "刷新失败：HTTP \(http.statusCode)")
        }
        guard let data = data, !data.isEmpty else {
            return RefreshOutcome(channels: existing, updatedChannels: 0, totalStreams: 0,
                                  errorMessage: "刷新失败：没有数据")
        }
        guard let remotes = try? JSONDecoder().decode([RemoteStream].self, from: data) else {
            return RefreshOutcome(channels: existing, updatedChannels: 0, totalStreams: 0,
                                  errorMessage: "刷新失败：数据格式变化")
        }

        var byChannel: [String: [StreamEndpoint]] = [:]
        for remote in remotes {
            guard let channelID = remote.channel, !channelID.isEmpty,
                  let url = remote.url, !url.isEmpty else { continue }
            let endpoint = StreamEndpoint(url: url,
                                          quality: remote.quality ?? "",
                                          userAgent: remote.user_agent ?? "",
                                          referrer: remote.referrer ?? "")
            byChannel[channelID, default: []].append(endpoint)
        }

        var updated: [Channel] = []
        updated.reserveCapacity(existing.count)
        var updatedCount = 0
        var totalStreams = 0
        for channel in existing {
            var copy = channel
            if let fresh = byChannel[channel.id], !fresh.isEmpty {
                // 内置流按清晰度去重；人工补源（origin=curated）远端索引里没有，必须原样保留。
                let builtin = StreamOrdering.deduplicated(
                    fresh.sorted { $0.qualityRank > $1.qualityRank }
                )
                // 保留原有「已探测存活」标记，避免刷新后丢失排序信息。
                let aliveURLs = Set(channel.streams.filter { $0.isAlive }.map { $0.url })
                var marked = builtin
                if !aliveURLs.isEmpty {
                    for index in marked.indices where aliveURLs.contains(marked[index].url) {
                        marked[index].isAlive = true
                    }
                }
                let curated = channel.streams.filter { $0.isCurated }
                copy.streams = StreamOrdering.merge(builtin: marked, curated: curated)
                updatedCount += 1
            }
            totalStreams += copy.streams.count
            updated.append(copy)
        }

        self.saveCache(channels: updated, generatedAt: Self.timestamp())
        return RefreshOutcome(channels: updated, updatedChannels: updatedCount,
                             totalStreams: totalStreams, errorMessage: nil)
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: Date())
    }
}
