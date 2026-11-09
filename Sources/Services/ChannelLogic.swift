import Foundation

/// 台号分配。规则与 tools/bake_catalog.py 完全一致，用于：
///   * 自定义源（900-999）
///   * 烘焙目录里漏填台号的频道（number == 0）
/// 已分配台号的频道不会被改动，保证台号稳定。
enum ChannelNumbering {

    /// 从名称里解析 CCTV 序号（"CCTV-1" / "CCTV1" → 1）。
    static func parsedCCTVNumber(_ channel: Channel) -> Int? {
        let source = channel.subname.isEmpty ? channel.name : channel.subname
        let compact = source.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
        guard compact.uppercased().hasPrefix("CCTV") else { return nil }
        var rest = compact.dropFirst(4)
        while rest.first == "-" { rest = rest.dropFirst() }
        let digits = rest.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    /// 给 number == 0 的频道补号；返回新数组。
    static func assignNumbers(_ channels: [Channel]) -> [Channel] {
        var result = channels
        var occupied: [ChannelGroup: Set<Int>] = [:]
        for channel in result where channel.number > 0 {
            occupied[channel.group, default: []].insert(channel.number)
        }

        var pendingIndexes: [ChannelGroup: [Int]] = [:]
        for (index, channel) in result.enumerated() where channel.number == 0 {
            pendingIndexes[channel.group, default: []].append(index)
        }

        for group in ChannelGroup.allCases {
            guard var indexes = pendingIndexes[group], !indexes.isEmpty else { continue }
            if group == .cctv {
                indexes.sort { lhs, rhs in
                    let left = parsedCCTVNumber(result[lhs]) ?? 999
                    let right = parsedCCTVNumber(result[rhs]) ?? 999
                    if left != right { return left < right }
                    return result[lhs].name < result[rhs].name
                }
            } else {
                indexes.sort { result[$0].name < result[$1].name }
            }
            var used = occupied[group] ?? []
            var cursor = group.numberRange.lowerBound
            for index in indexes {
                while used.contains(cursor) { cursor += 1 }
                guard cursor <= group.numberRange.upperBound else { break }
                result[index].number = cursor
                used.insert(cursor)
                cursor += 1
            }
            occupied[group] = used
        }
        return result
    }
}

/// 搜索匹配：台号前缀 / 台名 / 拼音首字母 / 全拼。
/// 拼音由 CoreFoundation 的 `kCFStringTransformToLatin` 生成，零第三方依赖。
enum ChannelSearch {

    private static var initialsCache: [String: String] = [:]
    private static let cacheLock = NSLock()

    /// 汉字转拉丁（"央视" → "yang shi"）。
    static func latinized(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let mutable = NSMutableString(string: text) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
        return (mutable as String).lowercased()
    }

    /// 拼音首字母（"中央电视台" → "zydst"）。
    static func initials(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        cacheLock.lock()
        if let cached = initialsCache[text] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let latin = latinized(text)
        var result = ""
        for token in latin.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "'" || $0 == "·" }) {
            if let first = token.first, first.isLetter { result.append(first) }
        }
        cacheLock.lock()
        initialsCache[text] = result
        cacheLock.unlock()
        return result
    }

    /// 单个频道是否命中查询词。
    static func matches(_ channel: Channel, query: String) -> Bool {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if keyword.isEmpty { return true }
        if keyword.allSatisfy({ $0.isNumber }) {
            return String(channel.number).hasPrefix(keyword)
                || channel.formattedNumber.hasPrefix(keyword)
        }
        if channel.name.lowercased().contains(keyword) { return true }
        if !channel.subname.isEmpty, channel.subname.lowercased().contains(keyword) { return true }
        let haystack = initials(channel.name) + "|" + initials(channel.subname)
        if haystack.contains(keyword) { return true }
        let latinFull = latinized(channel.name).replacingOccurrences(of: " ", with: "")
        let compactKeyword = keyword.replacingOccurrences(of: " ", with: "")
        return !compactKeyword.isEmpty && latinFull.contains(compactKeyword)
    }

    /// 过滤频道列表（保持原有顺序）。
    static func filter(_ channels: [Channel], query: String) -> [Channel] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if keyword.isEmpty { return channels }
        return channels.filter { matches($0, query: keyword) }
    }
}

/// 收藏序列化：UserDefaults 里存一段 JSON 字符串（便于单测与迁移）。
enum FavoritesCodec {
    static func encode(_ identifiers: Set<String>) -> String {
        let sorted = Array(identifiers).sorted()
        guard let data = try? JSONEncoder().encode(sorted),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    static func decode(_ raw: String) -> Set<String> {
        guard let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(list)
    }
}

/// `#EXTINF` 行的「属性区 / 显示名」分界扫描。
///
/// 不能简单按第一个逗号切分：`group-title="新闻,体育"` 里的逗号在引号内，
/// 属于属性值而不是分隔符。这里做引号感知扫描，支持双引号、单引号与 `\"` / `\'` 转义。
enum M3UAttributeScanner {

    /// 第一个「不在引号内」的逗号下标；没有则返回 nil。
    static func firstUnquotedCommaIndex(in text: String) -> String.Index? {
        var quote: Character?
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "," {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// 把 `#EXTINF:` 之后的正文切成 (属性区, 显示名)。
    static func split(_ body: String) -> (attributes: String, name: String) {
        guard let commaIndex = firstUnquotedCommaIndex(in: body) else {
            return (body, "")
        }
        let attributes = String(body[body.startIndex..<commaIndex])
        let remainder = String(body[body.index(after: commaIndex)...])
        return (attributes, remainder.trimmingCharacters(in: .whitespaces))
    }
}

/// 跨进程稳定的哈希（Swift 的 `String.hashValue` 每个进程随机播种，不能用于持久化 id）。
/// 这里用 FNV-1a 64 位，输出 16 位小写十六进制。
enum DeterministicHash {

    static let fnvOffsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    static let fnvPrime: UInt64 = 0x0000_0100_0000_01b3

    static func fnv1a64(_ text: String) -> UInt64 {
        var hash = fnvOffsetBasis
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* fnvPrime
        }
        return hash
    }

    static func fnv1a64Hex(_ text: String) -> String {
        return String(format: "%016llx", fnv1a64(text))
    }
}

/// 候选流的合并顺序（与 tools/bake_catalog.py 的 `merge_stream_order` 保持一致）。
///
/// 运行期后台刷新只拿到 iptv-org 的流列表，人工补源（origin=curated）必须原样保留，
/// 否则 CCTV-6 这类「只有补源能用」的频道会在启动几秒后刷新一次就失效。
enum StreamOrdering {

    /// 内置存活流优先，补源插在其后；内置一条活的都没有时补源提到最前。
    static func merge(builtin: [StreamEndpoint], curated: [StreamEndpoint]) -> [StreamEndpoint] {
        let aliveBuiltin = builtin.filter { $0.isAlive }
        let deadBuiltin = builtin.filter { !$0.isAlive }
        let aliveCurated = curated.filter { $0.isAlive }
        let deadCurated = curated.filter { !$0.isAlive }
        if !aliveBuiltin.isEmpty {
            return aliveBuiltin + aliveCurated + deadBuiltin + deadCurated
        }
        return aliveCurated + deadBuiltin + deadCurated
    }

    /// 按 url 去重（保留先出现的那条）。
    static func deduplicated(_ streams: [StreamEndpoint]) -> [StreamEndpoint] {
        var seen = Set<String>()
        var result: [StreamEndpoint] = []
        result.reserveCapacity(streams.count)
        for stream in streams where !stream.url.isEmpty {
            if seen.contains(stream.url) { continue }
            seen.insert(stream.url)
            result.append(stream)
        }
        return result
    }

    /// 真正参与故障切换的候选：有烘焙时验证过的存活源时，只在这些源之间切。
    ///
    /// `isAlive` 是烘焙时刻的快照，标记为死的源大概率还是死的（502/超时），
    /// 挨个去试只会让屏幕黑十几秒；标记为活的源即使断流也通常是瞬时抖动，
    /// 重新拉一次就能接上。只有「一条活的都没有」时才退回去试死源。
    static func playable(_ streams: [StreamEndpoint]) -> [StreamEndpoint] {
        let ordered = deduplicated(streams)
        let alive = ordered.filter { $0.isAlive }
        return alive.isEmpty ? ordered : alive
    }

    /// 单条源的超时预算（秒）。
    ///
    /// 实测：普通 1080p 直播源冷启动要 8~20 秒（跨地域 CDN 首次拉流更慢），
    /// 4K 补源（18~24Mbps、6 秒一个分片）首帧要 ~30 秒。原来的 15 秒会把
    /// 还能用的源判死、直接切到更差的源。这里按「宁可多等、别误杀」取值。
    static func timeoutBudget(for endpoint: StreamEndpoint) -> (open: Double, stall: Double) {
        if endpoint.qualityRank >= 5 || endpoint.isCurated {
            return (45, 12)
        }
        return (25, 8)
    }
}

/// 官方直播页地址：无可用源时给用户一个「自己去官网看」的出口。
/// 规则：`CCTV6.cn` 这类 id → `https://tv.cctv.com/live/cctv6/`；
/// 其它频道退回 catalog 里的 `website`（为空则不给按钮）。
enum ChannelOfficialPage {

    /// 从 `CCTV10.cn` 里取出台号字符串（"10"）；不是央视 id 返回 nil。
    static func cctvNumber(from identifier: String) -> String? {
        let upper = identifier.uppercased()
        guard upper.hasPrefix("CCTV") else { return nil }
        let digits = upper.dropFirst(4).prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return String(digits)
    }

    /// 官方直播页 URL；没有可用地址时返回 nil（UI 据此决定是否显示按钮）。
    static func url(for channel: Channel) -> URL? {
        if let number = cctvNumber(from: channel.id) {
            return URL(string: "https://tv.cctv.com/live/cctv\(number)/")
        }
        let website = channel.website.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !website.isEmpty,
              let url = URL(string: website),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }
}

/// 台标缺失时的文字徽标（不是通用 `tv` 图标，避免整列看起来「全空」）。
/// 网络环境决定了相当一部分台标图床（i.imgur.com / upload.wikimedia.org）不可达，
/// 这些台只能用离线方案兜底。徽标要能区分频道，所以按顺序取：
///   1. 名称首个词尾部的数字（`CCTV-1` → `1`、`CCTV-10` → `10`，央视各台一眼可分）
///   2. 中文名首字（`湖南卫视` → `湖`）
///   3. 拉丁字母前两位（`BBC 新闻` → `BB`）
/// 底色由 id 的稳定哈希决定，保证同一频道每次、每台机器颜色一致。
enum ChannelBadge {

    static func initials(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }

        let token = trimmed.prefix { !$0.isWhitespace }
        let digits = trailingDigits(of: token)
        if !digits.isEmpty { return String(digits.suffix(2)) }

        guard first.isASCII, first.isLetter || first.isNumber else {
            return String(first)
        }
        return String(trimmed.prefix { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(2)).uppercased()
    }

    /// 首个词里最后一个字母/数字串末尾的数字（`CCTV-5+` 不算数字，返回空）。
    private static func trailingDigits(of token: Substring) -> [Character] {
        var alphanumerics: [Character] = []
        for character in token {
            if character.isASCII, character.isLetter || character.isNumber {
                alphanumerics.append(character)
            }
        }
        guard let last = token.last, last.isASCII, last.isNumber else { return [] }
        var digits: [Character] = []
        for character in alphanumerics.reversed() {
            guard character.isNumber else { break }
            digits.insert(character, at: 0)
        }
        return digits
    }

    /// 稳定调色板下标（同一 id 恒定）。
    static func paletteIndex(for identifier: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return Int(DeterministicHash.fnv1a64(identifier) % UInt64(count))
    }
}
