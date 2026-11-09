import Foundation

/// 解析结果中的一条播放项（一个 #EXTINF 对应一条流）。
struct M3UEntry: Equatable {
    var name: String = ""
    var tvgID: String = ""
    var logo: String = ""
    var groupTitle: String = ""
    var url: String = ""
    var userAgent: String = ""
    var referrer: String = ""
}

/// M3U / M3U8 播放列表解析器。
///
/// 支持：
///   * `#EXTINF:-1 tvg-id="..." tvg-name="..." tvg-logo="..." group-title="...",显示名`
///   * `#EXTGRP:分组`
///   * `#EXTVLCOPT:http-user-agent=...` / `#EXTVLCOPT:http-referrer=...`
///   * `#KODIPROP:inputstream.adaptive.manifest_type=...`（忽略但不断行）
///   * URL 行支持 http/https 与本地绝对路径
enum M3UParser {
    /// 解析文本形式的播放列表。
    static func parse(text: String) -> [M3UEntry] {
        var entries: [M3UEntry] = []
        var pending: M3UEntry? = nil
        var pendingAgent = ""
        var pendingReferrer = ""
        var pendingGroup = ""

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXTM3U") { continue }

            if line.hasPrefix("#EXTINF:") {
                var entry = M3UEntry()
                entry.userAgent = pendingAgent
                entry.referrer = pendingReferrer
                entry.groupTitle = pendingGroup
                let body = String(line.dropFirst("#EXTINF:".count))
                // 引号感知切分：group-title="新闻,体育" 里的逗号不能当分隔符。
                let parts = M3UAttributeScanner.split(body)
                let attributePart = parts.attributes
                entry.name = parts.name
                entry.tvgID = attributeValue(in: attributePart, key: "tvg-id")
                entry.logo = attributeValue(in: attributePart, key: "tvg-logo")
                let group = attributeValue(in: attributePart, key: "group-title")
                if !group.isEmpty { entry.groupTitle = group }
                let tvgName = attributeValue(in: attributePart, key: "tvg-name")
                if entry.name.isEmpty { entry.name = tvgName }
                pending = entry
                continue
            }

            if line.hasPrefix("#EXTGRP:") {
                pendingGroup = String(line.dropFirst("#EXTGRP:".count)).trimmingCharacters(in: .whitespaces)
                continue
            }

            if line.hasPrefix("#EXTVLCOPT:") || line.hasPrefix("#KODIPROP:") {
                let payload = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard payload.count > 1 else { continue }
                let kv = String(payload[1])
                let pair = kv.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { continue }
                let key = String(pair[0]).lowercased()
                let value = String(pair[1])
                switch key {
                case "http-user-agent", "http-useragent":
                    pendingAgent = value
                case "http-referrer", "http-referer":
                    pendingReferrer = value
                default:
                    break
                }
                continue
            }

            if line.hasPrefix("#") { continue }

            // 到这里是 URL 行（或本地路径）
            guard isPlayableLocation(line) else { continue }
            var entry = pending ?? M3UEntry()
            entry.url = line
            entry.userAgent = entry.userAgent.isEmpty ? pendingAgent : entry.userAgent
            entry.referrer = entry.referrer.isEmpty ? pendingReferrer : entry.referrer
            if entry.name.isEmpty {
                entry.name = defaultName(for: line)
            }
            if entry.groupTitle.isEmpty { entry.groupTitle = pendingGroup }
            entries.append(entry)
            pending = nil
            pendingAgent = ""
            pendingReferrer = ""
        }
        return entries
    }

    /// 读取本地 .m3u 文件。自动尝试 UTF-8 / GB18030。
    static func load(fileURL: URL) throws -> [M3UEntry] {
        let data = try Data(contentsOf: fileURL)
        let text = decode(data: data)
        return parse(text: text)
    }

    /// 下载远端 m3u。回调在主线程。
    static func loadRemote(urlString: String,
                           completion: @escaping (Result<[M3UEntry], Error>) -> Void) {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            completion(.failure(M3UError.invalidURL))
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("VLC/3.0.20 LibVLC/3.0.20", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration)
        session.dataTask(with: request) { data, response, error in
            let result: Result<[M3UEntry], Error>
            if let error = error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                result = .failure(M3UError.httpStatus(http.statusCode))
            } else if let data = data, !data.isEmpty {
                let entries = parse(text: decode(data: data))
                result = entries.isEmpty ? .failure(M3UError.emptyPlaylist) : .success(entries)
            } else {
                result = .failure(M3UError.emptyPlaylist)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    /// 把播放项按频道归并（同名/同 tvg-id 的多条流合并成一个频道）。
    static func channels(from entries: [M3UEntry]) -> [Channel] {
        var order: [String] = []
        var buckets: [String: [M3UEntry]] = [:]
        for entry in entries {
            let key = !entry.tvgID.isEmpty ? "id:\(entry.tvgID)" : "name:\(entry.name)"
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(entry)
        }

        var channels: [Channel] = []
        for key in order {
            guard let group = buckets[key], let first = group.first else { continue }
            var seen = Set<String>()
            var streams: [StreamEndpoint] = []
            for entry in group where !entry.url.isEmpty {
                if seen.contains(entry.url) { continue }
                seen.insert(entry.url)
                streams.append(StreamEndpoint(url: entry.url,
                                              quality: "",
                                              userAgent: entry.userAgent,
                                              referrer: entry.referrer,
                                              isAlive: false))
            }
            guard !streams.isEmpty else { continue }
            let displayName = first.name.isEmpty ? "未命名频道" : first.name
            // id 必须跨进程稳定（重复导入才能去重、收藏不会变孤儿），
            // 所以不能用 String.hashValue（每进程随机播种），改用 FNV-1a。
            let identityKey = first.tvgID.isEmpty
                ? "\(displayName)|\(first.groupTitle)"
                : first.tvgID
            let identifier = "custom-\(DeterministicHash.fnv1a64Hex(identityKey))"
            channels.append(Channel(id: identifier,
                                    name: displayName,
                                    subname: first.groupTitle,
                                    group: .custom,
                                    number: 0,
                                    logoURL: first.logo,
                                    website: "",
                                    country: "",
                                    categories: ["custom"],
                                    streams: streams,
                                    isCustom: true))
        }
        return channels
    }

    // MARK: - 内部工具

    private static func attributeValue(in text: String, key: String) -> String {
        // 形如 tvg-id="CCTV1.cn" / tvg-id='CCTV1.cn'，值内允许 \" 转义
        for quote in ["\"", "'"] {
            let pattern = key + "=" + quote
            guard let start = text.range(of: pattern) else { continue }
            var value = ""
            var escaped = false
            var index = start.upperBound
            while index < text.endIndex {
                let character = text[index]
                if escaped {
                    value.append(character)
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == Character(quote) {
                    return value.trimmingCharacters(in: .whitespaces)
                } else {
                    value.append(character)
                }
                index = text.index(after: index)
            }
            return value.trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    private static func isPlayableLocation(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("rtmp://") {
            return true
        }
        if lower.hasPrefix("file://") { return true }
        return line.hasPrefix("/")
    }

    private static func defaultName(for location: String) -> String {
        if let url = URL(string: location), !url.lastPathComponent.isEmpty {
            return url.deletingPathExtension().lastPathComponent
        }
        return (location as NSString).lastPathComponent
    }

    private static func decode(data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        let gb18030 = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let text = String(data: data, encoding: String.Encoding(rawValue: gb18030)) {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }
}

enum M3UError: LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case emptyPlaylist

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "链接格式不正确（需 http/https）"
        case .httpStatus(let code): return "服务器返回 HTTP \(code)"
        case .emptyPlaylist: return "没有解析到任何频道"
        }
    }
}
