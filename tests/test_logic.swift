import Foundation

/// 逻辑层自测（不启动 UI、不联网）。
/// 编译方式见 tests/run_tests.sh：与 Sources 中的模型/服务一起编成 CLI。
@main
struct LogicTests {
    static var failed = 0

    static func expect(_ condition: Bool, _ message: String) {
        if condition {
            print("  ✅ \(message)")
        } else {
            print("  ❌ \(message)")
            failed += 1
        }
    }

    static func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) {
        expect(lhs == rhs, "\(message)（期望 \(rhs)，实际 \(lhs)）")
    }

    static func main() {
        print("== 1. M3U 解析 ==")
        testM3UParsing()
        print("== 2. 台号分配 ==")
        testNumbering()
        print("== 3. 搜索过滤 ==")
        testSearch()
        print("== 4. 收藏序列化 ==")
        testFavorites()
        print("== 5. 模型容错与首选流 ==")
        testModel()
        print("== 6. #EXTINF 引号感知切分 ==")
        testQuotedSplit()
        print("== 7. 确定性哈希（自定义源 id） ==")
        testDeterministicHash()
        print("== 8. 台标徽标兜底 ==")
        testBadge()
        print("== 9. 官方直播页兜底 ==")
        testOfficialPage()
        print("== 10. 精选源标记 ==")
        testStreamOrigin()
        print("== 11. 候选流合并顺序 ==")
        testStreamOrdering()
        print("== 12. 存活源筛选与超时预算 ==")
        testPlayableAndTimeouts()

        print("")
        if failed == 0 {
            print("全部通过 ✅")
            exit(0)
        } else {
            print("失败 \(failed) 项 ❌")
            exit(1)
        }
    }

    // MARK: - M3U

    static let sampleM3U = """
    #EXTM3U
    #EXTINF:-1 tvg-id="CCTV1.cn" tvg-name="CCTV-1" tvg-logo="http://logo/1.png" group-title="央视",CCTV-1 综合
    #EXTVLCOPT:http-user-agent=Mozilla/5.0 Test
    #EXTVLCOPT:http-referrer=http://ref.example/
    http://example.com/1.m3u8
    #EXTINF:-1 tvg-id="CCTV1.cn" tvg-name="CCTV-1" group-title="央视",CCTV-1 综合
    http://example.com/2.m3u8
    #EXTGRP:卫视
    #EXTINF:-1,湖南卫视
    http://example.com/hunan.m3u8
    """

    static func testM3UParsing() {
        let entries = M3UParser.parse(text: sampleM3U)
        expectEqual(entries.count, 3, "解析出 3 条播放项")
        expectEqual(entries[0].name, "CCTV-1 综合", "解析显示名")
        expectEqual(entries[0].tvgID, "CCTV1.cn", "解析 tvg-id")
        expectEqual(entries[0].logo, "http://logo/1.png", "解析 tvg-logo")
        expectEqual(entries[0].groupTitle, "央视", "解析 group-title")
        expectEqual(entries[0].userAgent, "Mozilla/5.0 Test", "继承 #EXTVLCOPT user-agent")
        expectEqual(entries[0].referrer, "http://ref.example/", "继承 #EXTVLCOPT referrer")
        expectEqual(entries[1].url, "http://example.com/2.m3u8", "第二条 URL")
        expectEqual(entries[2].name, "湖南卫视", "EXTINF 行内显示名")
        expectEqual(entries[2].groupTitle, "卫视", "继承 #EXTGRP 分组")

        let channels = M3UParser.channels(from: entries)
        expectEqual(channels.count, 2, "同 tvg-id 归并成 1 个频道（共 2 个频道）")
        expectEqual(channels[0].streams.count, 2, "CCTV-1 合并出 2 条备源")
        expect(channels[0].group == .custom, "自定义源归入「自定义」分组")
        expect(channels[0].isCustom, "标记为自定义频道")
        expectEqual(channels[1].name, "湖南卫视", "第二个频道名称正确")

        // CRLF + 空行 + 注释行
        let crlf = "#EXTM3U\r\n\r\n#EXTVLCOPT:http-user-agent=VLC\r\n#EXTINF:-1,测试台\r\nhttp://example.com/3.m3u8\r\n"
        let crlfEntries = M3UParser.parse(text: crlf)
        expectEqual(crlfEntries.count, 1, "CRLF 换行与空行不影响解析")
        expectEqual(crlfEntries[0].userAgent, "VLC", "CRLF 场景下仍继承 UA")

        // 非法行不应崩溃
        let garbage = "这不是播放列表\n\n#EXTINF:-1\n"
        expectEqual(M3UParser.parse(text: garbage).count, 0, "无效内容解析出 0 条且不崩溃")
    }

    // MARK: - 台号

    static func testNumbering() {
        let channels = [
            Channel(id: "c2", name: "CCTV-2 财经", subname: "CCTV-2", group: .cctv, number: 0),
            Channel(id: "c1", name: "CCTV-1 综合", subname: "CCTV-1", group: .cctv, number: 0),
            Channel(id: "s1", name: "北京卫视", group: .satellite, number: 0),
            Channel(id: "s2", name: "安徽卫视", group: .satellite, number: 0),
            Channel(id: "l2", name: "湖南经视", group: .local, number: 0),
            Channel(id: "l1", name: "东莞广播电视台", group: .local, number: 0),
            Channel(id: "h1", name: "翡翠台", group: .hkmt, number: 0),
            Channel(id: "i1", name: "BBC 新闻", group: .international, number: 0),
            Channel(id: "x1", name: "我的测试台", group: .custom, number: 0),
            Channel(id: "k1", name: "已固定台", group: .local, number: 260),
        ]
        let assigned = ChannelNumbering.assignNumbers(channels)
        func number(_ id: String) -> Int {
            assigned.first { $0.id == id }?.number ?? -1
        }
        expectEqual(number("c1"), 1, "CCTV-1 → 1 台")
        expectEqual(number("c2"), 2, "CCTV-2 → 2 台")
        expectEqual(number("s1"), 100, "卫视首台 → 100")
        expectEqual(number("s2"), 101, "卫视第二台 → 101")
        expectEqual(number("h1"), 400, "港澳台首台 → 400")
        expectEqual(number("i1"), 500, "国际首台 → 500")
        expectEqual(number("x1"), 900, "自定义台号从 900 起")
        expectEqual(number("k1"), 260, "已有台号不被改写")
        let locals = assigned.filter { $0.group == .local && $0.number != 260 }.map { $0.number }
        expectEqual(Set(locals), Set([200, 201]), "地方台占用 200/201")
        expect(assigned.filter { $0.number == 0 }.isEmpty, "所有频道都分到了台号")

        // 幂等：再分配一次不应改变任何台号
        let twice = ChannelNumbering.assignNumbers(assigned)
        expect(twice.map { $0.number } == assigned.map { $0.number }, "重复分配台号保持幂等")

        // CCTV 序号解析
        expectEqual(ChannelNumbering.parsedCCTVNumber(
            Channel(id: "a", name: "CCTV-13 新闻", subname: "CCTV-13")), 13, "解析 CCTV-13")
        expectEqual(ChannelNumbering.parsedCCTVNumber(
            Channel(id: "b", name: "CCTV5+ 体育", subname: "CCTV5+")), 5, "解析 CCTV5+")
        expect(ChannelNumbering.parsedCCTVNumber(
            Channel(id: "c", name: "湖南卫视")) == nil, "非 CCTV 频道返回 nil")
    }

    // MARK: - 搜索

    static func testSearch() {
        let channels = [
            Channel(id: "1", name: "湖南卫视", group: .satellite, number: 112),
            Channel(id: "2", name: "浙江卫视", group: .satellite, number: 103),
            Channel(id: "3", name: "CCTV-1 综合", subname: "CCTV-1", group: .cctv, number: 1),
            Channel(id: "4", name: "翡翠台", subname: "TVB Jade", group: .hkmt, number: 406),
        ]
        expectEqual(ChannelSearch.filter(channels, query: "").count, 4, "空搜索返回全部")
        expectEqual(ChannelSearch.filter(channels, query: "卫视").count, 2, "按台名过滤")
        expectEqual(ChannelSearch.filter(channels, query: "hnws").first?.id, "1", "拼音首字母 hnws → 湖南卫视")
        expectEqual(ChannelSearch.filter(channels, query: "zjws").first?.id, "2", "拼音首字母 zjws → 浙江卫视")
        expectEqual(ChannelSearch.filter(channels, query: "hunan").first?.id, "1", "全拼 hunan → 湖南卫视")
        expectEqual(ChannelSearch.filter(channels, query: "10").first?.id, "2", "台号前缀 10 → 103（浙江卫视）")
        expectEqual(ChannelSearch.filter(channels, query: "406").first?.id, "4", "完整台号 406 → 翡翠台")
        expectEqual(ChannelSearch.filter(channels, query: "cctv").first?.id, "3", "英文名 cctv 命中")
        expectEqual(ChannelSearch.filter(channels, query: "不存在的台").count, 0, "无匹配返回空")
    }

    // MARK: - 收藏

    static func testFavorites() {
        let source: Set<String> = ["CCTV1.cn", "custom-1", "tvb"]
        let encoded = FavoritesCodec.encode(source)
        let decoded = FavoritesCodec.decode(encoded)
        expectEqual(decoded, source, "收藏集合编解码往返一致")
        expectEqual(FavoritesCodec.decode(""), [], "空字符串解码为空集合")
        expectEqual(FavoritesCodec.decode("not json"), [], "脏数据解码为空集合")
        expectEqual(FavoritesCodec.encode([]), "[]", "空集合编码为 []")
    }

    // MARK: - 模型

    static func testModel() {
        let partial = """
        {"id":"t1","name":"测试台","streams":[{"url":"http://a/1.m3u8"}]}
        """.data(using: .utf8)!
        guard let channel = try? JSONDecoder().decode(Channel.self, from: partial) else {
            expect(false, "缺字段的 JSON 应能解码")
            return
        }
        expectEqual(channel.subname, "", "缺失 subname 默认为空")
        expectEqual(channel.group, .local, "缺失 group 默认为地方")
        expectEqual(channel.streams.count, 1, "解析出 1 条流")
        expectEqual(channel.streams[0].quality, "", "缺失 quality 默认为空")
        expectEqual(channel.streams[0].qualityLabel, "直播", "无清晰度时展示「直播」")
        expectEqual(channel.formattedNumber, "000", "台号三位补零")

        let withLogo = """
        {"id":"t2","name":"台标台","logoFile":"logos/t2.png","logoSource":"fm","streams":[]}
        """.data(using: .utf8)!
        if let decoded = try? JSONDecoder().decode(Channel.self, from: withLogo) {
            expectEqual(decoded.logoFile ?? "", "logos/t2.png", "logoFile 正常解码")
            expectEqual(decoded.logoSource ?? "", "fm", "logoSource 正常解码")
        } else {
            expect(false, "带 logoSource 的 JSON 应能解码")
        }

        let emptyLogo = """
        {"id":"t3","name":"无台标台","logoFile":"","logoSource":"","streams":[]}
        """.data(using: .utf8)!
        if let decoded = try? JSONDecoder().decode(Channel.self, from: emptyLogo) {
            expect(decoded.logoFile == nil, "空字符串 logoFile 归一为 nil")
            expect(decoded.logoSource == nil, "空字符串 logoSource 归一为 nil")
        } else {
            expect(false, "空 logo 字段的 JSON 应能解码")
        }

        let streams = [
            StreamEndpoint(url: "http://a/720", quality: "720p", isAlive: false),
            StreamEndpoint(url: "http://a/dead", quality: "1080p", isAlive: false),
            StreamEndpoint(url: "http://a/alive", quality: "576p", isAlive: true),
        ]
        let withStreams = Channel(id: "z", name: "测试", streams: streams)
        expectEqual(withStreams.preferredStream?.url, "http://a/alive", "首选流优先存活")
        let noAlive = Channel(id: "y", name: "测试2", streams: Array(streams.prefix(2)))
        expectEqual(noAlive.preferredStream?.url, "http://a/dead", "无存活流时按清晰度选")
        expectEqual(StreamEndpoint(url: "u", quality: "1080p").qualityRank, 3, "1080p 权重 3")

        var state = PlaybackState()
        state.status = .switching
        state.streamIndex = 1
        state.streamCount = 3
        state.resolution = "1280x720"
        state.message = "正在切换备用源 (2/3)"
        expectEqual(state.status.label, "切换备用源", "状态文案")
        expect(state.detailLine.contains("1280x720"), "详情包含分辨率")
        expect(state.detailLine.contains("源 2/3"), "详情包含源序号")
        expectEqual(state.status.level, 1, "切换中信号灯为黄")
    }

    // MARK: - #EXTINF 引号感知切分

    static func testQuotedSplit() {
        // 属性值内含逗号：必须在引号外找分隔符
        let quoted = M3UAttributeScanner.split("-1 group-title=\"新闻,体育\",测试频道")
        expectEqual(quoted.attributes, "-1 group-title=\"新闻,体育\"", "引号内的逗号不被当分隔符")
        expectEqual(quoted.name, "测试频道", "显示名取引号外第一个逗号之后")

        let plain = M3UAttributeScanner.split("-1,无属性台")
        expectEqual(plain.attributes, "-1", "普通行属性区正确")
        expectEqual(plain.name, "无属性台", "普通行显示名正确")

        let noName = M3UAttributeScanner.split("-1 tvg-name=\"A,B\"")
        expectEqual(noName.name, "", "没有分隔逗号时显示名为空")
        expectEqual(noName.attributes, "-1 tvg-name=\"A,B\"", "没有分隔逗号时整行都算属性区")

        let single = M3UAttributeScanner.split("-1 group-title='新闻,体育',单引号台")
        expectEqual(single.name, "单引号台", "单引号属性里的逗号也不切断")
        expectEqual(single.attributes, "-1 group-title='新闻,体育'", "单引号属性区完整")

        let escaped = M3UAttributeScanner.split("-1 tvg-name=\"A\\\",B\",转义台")
        expectEqual(escaped.name, "转义台", "转义的双引号不结束引号状态")

        // 端到端：解析 + 后续属性仍可读
        let line = "#EXTINF:-1 group-title=\"新闻,体育\" tvg-id=\"X.cn\",测试频道\nhttp://a.example.com/1.m3u8"
        let entry = M3UParser.parse(text: line).first
        expectEqual(entry?.groupTitle, "新闻,体育", "端到端：group-title 保留内部逗号")
        expectEqual(entry?.name, "测试频道", "端到端：频道名干净未被污染")
        expectEqual(entry?.tvgID, "X.cn", "端到端：逗号之后的属性仍能解析")

        // 多个逗号、引号成对出现
        let multi = M3UAttributeScanner.split("-1 tvg-name=\"A,B\" group-title=\"C,D\",台名,带逗号")
        expectEqual(multi.name, "台名,带逗号", "显示名自身含逗号时完整保留")
        expectEqual(multi.attributes, "-1 tvg-name=\"A,B\" group-title=\"C,D\"", "多个引号属性都正确跳过")
    }

    // MARK: - 确定性哈希

    static func testDeterministicHash() {
        let first = DeterministicHash.fnv1a64Hex("CCTV1.cn")
        let second = DeterministicHash.fnv1a64Hex("CCTV1.cn")
        let third = DeterministicHash.fnv1a64Hex("CCTV1.cn")
        expectEqual(first, second, "同一输入第一次/第二次结果一致")
        expectEqual(second, third, "同一输入第三次结果仍一致（跨进程稳定）")
        expectEqual(first.count, 16, "输出 16 位十六进制")
        expect(first != DeterministicHash.fnv1a64Hex("CCTV2.cn"), "不同输入结果不同")
        expectEqual(DeterministicHash.fnv1a64Hex("a"), "af63dc4c8601ec8c", "FNV-1a 64 标准测试向量")
        expectEqual(DeterministicHash.fnv1a64Hex(""), "cbf29ce484222325", "空串等于 offset basis")

        // 自定义源 id 必须可复现（重复导入才能去重、收藏才不变孤儿）
        let text = "#EXTM3U\n#EXTINF:-1 group-title=\"我的组\",无名台\nhttp://a.example.com/1.m3u8"
        let idA = M3UParser.channels(from: M3UParser.parse(text: text)).first?.id ?? ""
        let idB = M3UParser.channels(from: M3UParser.parse(text: text)).first?.id ?? ""
        expectEqual(idA, idB, "同样输入两次生成的频道 id 相同")
        expect(idA.hasPrefix("custom-"), "自定义源 id 带 custom- 前缀")
        expectEqual(idA.count, "custom-".count + 16, "id = custom- + 16 位十六进制")
        expect(!idA.contains("-1-"), "id 里不再拼接会变化的序号")

        // 名称相同但分组不同 → id 不同
        let textOtherGroup = "#EXTM3U\n#EXTINF:-1 group-title=\"别的组\",无名台\nhttp://a.example.com/1.m3u8"
        let idC = M3UParser.channels(from: M3UParser.parse(text: textOtherGroup)).first?.id ?? ""
        expect(idA != idC, "名称相同但分组不同时 id 不同")
    }

    // MARK: - 台标徽标兜底

    static func testBadge() {
        expectEqual(ChannelBadge.initials("CCTV-1 综合"), "1", "央视取台号，各台可区分")
        expectEqual(ChannelBadge.initials("CCTV-10 科教"), "10", "两位数台号完整保留")
        expectEqual(ChannelBadge.initials("CCTV16"), "16", "无分隔符也能取到尾部数字")
        expectEqual(ChannelBadge.initials("CCTV-5+ 体育赛事"), "CC", "以 + 结尾不算数字")
        expectEqual(ChannelBadge.initials("BBC 新闻"), "BB", "纯拉丁取前两位")
        expectEqual(ChannelBadge.initials("cctv5"), "5", "小写同样命中数字")
        expectEqual(ChannelBadge.initials("湖南卫视"), "湖", "中文取首字")
        expectEqual(ChannelBadge.initials("  CCTV 1"), "CC", "忽略前导空格，数字不在首个词里")
        expectEqual(ChannelBadge.initials(""), "?", "空名用问号兜底")
        expectEqual(ChannelBadge.initials("北京卫视"), "北", "中文不会取到标点")

        let a = ChannelBadge.paletteIndex(for: "CCTV1.cn", count: 8)
        let b = ChannelBadge.paletteIndex(for: "CCTV1.cn", count: 8)
        expectEqual(a, b, "同一 id 底色下标稳定")
        expect(a >= 0 && a < 8, "底色下标在调色板范围内")
        expectEqual(ChannelBadge.paletteIndex(for: "X", count: 0), 0, "调色板为空时退化为 0")
    }

    // MARK: - 官方直播页兜底

    static func testOfficialPage() {
        let cctv6 = Channel(id: "CCTV6.cn", name: "CCTV-6 电影", group: .cctv, number: 6)
        expectEqual(ChannelOfficialPage.url(for: cctv6)?.absoluteString,
                    "https://tv.cctv.com/live/cctv6/", "CCTV 用官方直播页模板")
        let cctv10 = Channel(id: "CCTV10.cn", name: "CCTV-10 科教", group: .cctv, number: 10)
        expectEqual(ChannelOfficialPage.url(for: cctv10)?.absoluteString,
                    "https://tv.cctv.com/live/cctv10/", "两位数台号也正确")
        let local = Channel(id: "HunanTV.cn", name: "湖南卫视", group: .satellite,
                            number: 100, website: "https://www.mgtv.com/")
        expectEqual(ChannelOfficialPage.url(for: local)?.absoluteString,
                    "https://www.mgtv.com/", "非央视回退到 website")
        let noSite = Channel(id: "HunanTV.cn", name: "湖南卫视", group: .satellite, number: 100)
        expectEqual(ChannelOfficialPage.url(for: noSite), nil, "没有 website 就不给按钮")
        let ftp = Channel(id: "X.cn", name: "X", group: .local, number: 200, website: "ftp://a/b")
        expectEqual(ChannelOfficialPage.url(for: ftp), nil, "非 http(s) 的 website 不采用")
    }

    // MARK: - 精选源标记

    static func testStreamOrigin() {
        let plain = StreamEndpoint(url: "http://a/1.m3u8")
        expectEqual(plain.origin, "iptv-org", "默认来源是内置索引")
        expect(plain.isCurated == false, "内置源不算精选源")
        let curated = StreamEndpoint(url: "http://b/1.m3u8", quality: "2160p", origin: "curated")
        expect(curated.isCurated, "curated 来源被识别")
        expectEqual(curated.qualityRank, 5, "2160p 权重最高")

        let json = """
        {"channels":[{"id":"CCTV6.cn","name":"CCTV-6","group":"央视","number":6,
          "streams":[{"url":"http://g/1.m3u8","quality":"2160p","origin":"curated"}]}]}
        """
        let data = Data(json.utf8)
        guard let file = try? JSONDecoder().decode(TestCatalogFile.self, from: data),
              let decoded = file.channels.first else {
            expect(false, "catalog 解码失败")
            return
        }
        expect(decoded.streams.first?.isCurated == true, "catalog 里的 origin 能被解出来")
    }

    /// 只为这条用例存在的最小 catalog 结构。
    struct TestCatalogFile: Decodable {
        var channels: [Channel]
    }

    // MARK: - 候选流合并顺序（与烘焙脚本同规则）

    static func testStreamOrdering() {
        let builtinAlive = StreamEndpoint(url: "http://b/alive.m3u8", isAlive: true)
        let builtinDead = StreamEndpoint(url: "http://b/dead.m3u8", isAlive: false)
        let curatedAlive = StreamEndpoint(url: "http://c/4k.m3u8", quality: "2160p",
                                          isAlive: true, origin: "curated")

        let withBuiltin = StreamOrdering.merge(builtin: [builtinAlive, builtinDead],
                                              curated: [curatedAlive])
        expectEqual(withBuiltin.map { $0.url },
                    ["http://b/alive.m3u8", "http://c/4k.m3u8", "http://b/dead.m3u8"],
                    "内置有活源时补源不能顶位")

        let allDead = StreamOrdering.merge(builtin: [builtinDead], curated: [curatedAlive])
        expectEqual(allDead.first?.url, "http://c/4k.m3u8", "内置全死时补源排第一")

        let onlyCurated = StreamOrdering.merge(builtin: [], curated: [curatedAlive])
        expectEqual(onlyCurated.map { $0.url }, ["http://c/4k.m3u8"], "只有补源时也能播")

        let duplicated = StreamOrdering.deduplicated([
            StreamEndpoint(url: "http://a/1.m3u8"),
            StreamEndpoint(url: "http://a/1.m3u8", quality: "1080p"),
            StreamEndpoint(url: ""),
        ])
        expectEqual(duplicated.count, 1, "按 url 去重并丢掉空地址")
    }

    // MARK: - 只有存活源参与切换 / 4K 放宽超时

    static func testPlayableAndTimeouts() {
        let alive = StreamEndpoint(url: "http://b/alive.m3u8", isAlive: true)
        let dead1 = StreamEndpoint(url: "http://b/dead1.m3u8", isAlive: false)
        let dead2 = StreamEndpoint(url: "http://b/dead2.m3u8", quality: "1080p", isAlive: false)

        let mixed = StreamOrdering.playable([dead1, alive, dead2])
        expectEqual(mixed.map { $0.url }, ["http://b/alive.m3u8"],
                    "有存活源时不再去试死源（否则屏幕会黑十几秒）")

        let allDead = StreamOrdering.playable([dead1, dead2])
        expectEqual(allDead.count, 2, "全是死源时仍逐个尝试（isAlive 只是烘焙时刻快照）")

        expectEqual(StreamOrdering.playable([]).count, 0, "空列表不崩")

        let hd = StreamOrdering.timeoutBudget(for: StreamEndpoint(url: "u", quality: "1080p"))
        expectEqual(hd.open, 25, "普通源首帧超时 25 秒（实测冷启动要 8~20 秒）")
        expectEqual(hd.stall, 8, "普通源卡流判定 8 秒")

        let fourK = StreamOrdering.timeoutBudget(for: StreamEndpoint(url: "u", quality: "2160p"))
        expectEqual(fourK.open, 45, "4K 源首帧超时放宽到 45 秒（实测首帧 ~30 秒）")
        expectEqual(fourK.stall, 12, "4K 源卡流判定放宽到 12 秒")

        let curated = StreamEndpoint(url: "u", quality: "", origin: "curated")
        expectEqual(StreamOrdering.timeoutBudget(for: curated).open, 45, "补源同样按重流处理")
    }
}
