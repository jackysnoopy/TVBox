import Foundation

/// 频道分组。侧栏顺序与此处声明顺序一致。
/// 「收藏」是虚拟分组（由 ChannelStore 动态生成），不作为真实分组存盘。
enum ChannelGroup: String, Codable, CaseIterable, Identifiable {
    case cctv = "央视"
    case satellite = "卫视"
    case local = "地方"
    case hkmt = "港澳台"
    case international = "国际"
    case custom = "自定义"

    var id: String { rawValue }

    var title: String { rawValue }

    /// 台号区间：央视 1-99、卫视 100-199、地方 200-399、港澳台 400-499、
    /// 国际 500-599、自定义 900-999。台号一旦分配就保持稳定，便于数字键直选。
    var numberRange: ClosedRange<Int> {
        switch self {
        case .cctv: return 1...99
        case .satellite: return 100...199
        case .local: return 200...399
        case .hkmt: return 400...499
        case .international: return 500...599
        case .custom: return 900...999
        }
    }

    /// 分组图标（SF Symbols）。
    var symbolName: String {
        switch self {
        case .cctv: return "tv"
        case .satellite: return "antenna.radiowaves.left.and.right"
        case .local: return "building.2"
        case .hkmt: return "globe.asia.australia"
        case .international: return "globe"
        case .custom: return "square.and.arrow.down"
        }
    }
}

/// 一条可播放的流地址。同一频道有多条流（不同清晰度/不同提供方）用于故障切换。
struct StreamEndpoint: Codable, Hashable, Identifiable {
    var url: String
    var quality: String
    var userAgent: String
    var referrer: String
    /// 烘焙时探测到的存活标记；仅用于排序，不参与失败判定。
    var isAlive: Bool
    /// 来源：`iptv-org`（内置索引）或 `curated`（tools/source-overrides.json 人工补源）。
    var origin: String

    var id: String { url }

    init(url: String,
         quality: String = "",
         userAgent: String = "",
         referrer: String = "",
         isAlive: Bool = false,
         origin: String = "iptv-org") {
        self.url = url
        self.quality = quality
        self.userAgent = userAgent
        self.referrer = referrer
        self.isAlive = isAlive
        self.origin = origin
    }

    /// 是否人工补源（OSD 上标「精选源」，排查时也能一眼区分）。
    var isCurated: Bool { origin == "curated" }

    /// 清晰度排序权重：数字越大越清晰。
    var qualityRank: Int {
        switch quality.lowercased() {
        case "2160p", "4k": return 5
        case "1440p", "2k": return 4
        case "1080p", "fhd": return 3
        case "720p", "hd": return 2
        case "576p", "480p": return 1
        default: return 0
        }
    }

    /// OSD 上展示的清晰度文案。
    var qualityLabel: String {
        quality.isEmpty ? "直播" : quality
    }

    private enum CodingKeys: String, CodingKey {
        case url, quality, userAgent, referrer, isAlive, origin
    }

    /// 容忍字段缺失：catalog.json 由脚本生成，字段可能为空或省略。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = (try? container.decodeIfPresent(String.self, forKey: .url)) ?? ""
        quality = (try? container.decodeIfPresent(String.self, forKey: .quality)) ?? ""
        userAgent = (try? container.decodeIfPresent(String.self, forKey: .userAgent)) ?? ""
        referrer = (try? container.decodeIfPresent(String.self, forKey: .referrer)) ?? ""
        isAlive = (try? container.decodeIfPresent(Bool.self, forKey: .isAlive)) ?? false
        let rawOrigin = (try? container.decodeIfPresent(String.self, forKey: .origin)) ?? ""
        origin = rawOrigin.isEmpty ? "iptv-org" : rawOrigin
    }
}

/// 一个电视频道。
struct Channel: Codable, Identifiable, Hashable {
    var id: String
    /// 展示名（优先中文）。
    var name: String
    /// 原始英文名，用于副标题与搜索。
    var subname: String
    var group: ChannelGroup
    /// 台号：稳定不变，数字键直选依据。
    var number: Int
    /// 远端台标 URL（兜底；部分图床在本机不可达）。
    var logoURL: String
    /// 内置台标相对路径（如 `logos/CCTV1.cn.png`），由烘焙脚本下载并随包分发；没有则为 nil。
    var logoFile: String?
    /// 台标来源：`fm`（fanmingming/live 台标库）/ `iptv-org` / nil，排查与灰阶展示用。
    var logoSource: String?
    var website: String
    var country: String
    var categories: [String]
    var streams: [StreamEndpoint]
    var isCustom: Bool

    init(id: String,
         name: String,
         subname: String = "",
         group: ChannelGroup = .local,
         number: Int = 0,
         logoURL: String = "",
         logoFile: String? = nil,
         logoSource: String? = nil,
         website: String = "",
         country: String = "CN",
         categories: [String] = [],
         streams: [StreamEndpoint] = [],
         isCustom: Bool = false) {
        self.id = id
        self.name = name
        self.subname = subname
        self.group = group
        self.number = number
        self.logoURL = logoURL
        self.logoFile = logoFile
        self.logoSource = logoSource
        self.website = website
        self.country = country
        self.categories = categories
        self.streams = streams
        self.isCustom = isCustom
    }

    /// 三位台号，UI 上按电视习惯展示（001 / 101 / 501）。
    var formattedNumber: String {
        String(format: "%03d", number)
    }

    /// 副标题：与主标题不同才展示，避免「CCTV-1 / CCTV-1」重复。
    var subtitle: String {
        let trimmed = subname.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == name { return "" }
        return trimmed
    }

    /// 首选流：存活优先，其次清晰度高。
    var preferredStream: StreamEndpoint? {
        streams.sorted { lhs, rhs in
            if lhs.isAlive != rhs.isAlive { return lhs.isAlive }
            return lhs.qualityRank > rhs.qualityRank
        }.first
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, subname, group, number, logoURL, logoFile, logoSource, website, country,
             categories, streams, isCustom
    }

    /// 容忍字段缺失，保证旧版 catalog.json 也能读。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? "未知频道"
        subname = (try? container.decodeIfPresent(String.self, forKey: .subname)) ?? ""
        let rawGroup = (try? container.decodeIfPresent(String.self, forKey: .group)) ?? ""
        group = ChannelGroup(rawValue: rawGroup) ?? .local
        number = (try? container.decodeIfPresent(Int.self, forKey: .number)) ?? 0
        logoURL = (try? container.decodeIfPresent(String.self, forKey: .logoURL)) ?? ""
        let rawLogoFile = (try? container.decodeIfPresent(String.self, forKey: .logoFile)) ?? nil
        logoFile = (rawLogoFile?.isEmpty ?? true) ? nil : rawLogoFile
        let rawLogoSource = (try? container.decodeIfPresent(String.self, forKey: .logoSource)) ?? nil
        logoSource = (rawLogoSource?.isEmpty ?? true) ? nil : rawLogoSource
        website = (try? container.decodeIfPresent(String.self, forKey: .website)) ?? ""
        country = (try? container.decodeIfPresent(String.self, forKey: .country)) ?? ""
        categories = (try? container.decodeIfPresent([String].self, forKey: .categories)) ?? []
        streams = (try? container.decodeIfPresent([StreamEndpoint].self, forKey: .streams)) ?? []
        isCustom = (try? container.decodeIfPresent(Bool.self, forKey: .isCustom)) ?? false
    }
}

/// 播放器状态。OSD 与侧栏高亮都从这里取值。
enum PlaybackStatus: String {
    case idle          // 还没开始
    case preparing     // 正在打开第一条流
    case playing       // 正常播放
    case buffering     // 缓冲中
    case switching     // 正在切换备用源
    case paused        // 用户暂停
    case failed        // 所有源都失败

    /// OSD 文案。
    var label: String {
        switch self {
        case .idle: return "待机"
        case .preparing: return "正在打开"
        case .playing: return "播放中"
        case .buffering: return "缓冲中"
        case .switching: return "切换备用源"
        case .paused: return "已暂停"
        case .failed: return "无信号"
        }
    }

    /// 信号灯颜色语义（0 红 / 1 黄 / 2 绿）。
    var level: Int {
        switch self {
        case .playing: return 2
        case .buffering, .switching, .preparing, .paused: return 1
        case .idle, .failed: return 0
        }
    }
}

/// 播放状态的快照（值类型，便于 SwiftUI 观察）。
struct PlaybackState: Equatable {
    var status: PlaybackStatus = .idle
    var channel: Channel?
    /// 当前正在尝试第几条候选流（0 基）与候选流总数。
    var streamIndex: Int = 0
    var streamCount: Int = 0
    /// 附加提示，例如「正在切换备用源 (2/3)」。
    var message: String = ""
    /// 实际分辨率，例如「1920x1080」；未知时为空。
    var resolution: String = ""
    /// 目录标注的清晰度（「2160p」/「1080p」），与实际分辨率可能不同。
    var qualityLabel: String = ""
    /// 当前流地址，调试用。
    var streamURL: String = ""

    init(status: PlaybackStatus = .idle,
         channel: Channel? = nil,
         streamIndex: Int = 0,
         streamCount: Int = 0,
         message: String = "",
         resolution: String = "",
         qualityLabel: String = "",
         streamURL: String = "") {
        self.status = status
        self.channel = channel
        self.streamIndex = streamIndex
        self.streamCount = streamCount
        self.message = message
        self.resolution = resolution
        self.qualityLabel = qualityLabel
        self.streamURL = streamURL
    }

    /// 供 OSD 展示的状态后缀。
    var detailLine: String {
        var parts: [String] = []
        if !qualityLabel.isEmpty { parts.append(qualityLabel) }
        if !resolution.isEmpty, resolution != qualityLabel { parts.append(resolution) }
        if streamCount > 1 { parts.append("源 \(min(streamIndex + 1, streamCount))/\(streamCount)") }
        if !message.isEmpty { parts.append(message) }
        return parts.joined(separator: " · ")
    }

    /// 当前播放的是否人工补源（tools/source-overrides.json），OSD 上标「精选源」。
    var isCuratedStream: Bool {
        guard let channel = channel, !channel.streams.isEmpty else { return false }
        if !streamURL.isEmpty, let matched = channel.streams.first(where: { $0.url == streamURL }) {
            return matched.isCurated
        }
        let index = min(max(streamIndex, 0), channel.streams.count - 1)
        return channel.streams[index].isCurated
    }
}
