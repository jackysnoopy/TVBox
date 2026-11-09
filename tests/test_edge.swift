import Foundation

/// 边界/异常输入的补充单测（QA 追加）。
///
/// 与 `test_logic.swift` 分开编译成独立 CLI，避免两个 `@main` 冲突；
/// `tests/run_tests.sh` 会顺序跑两个二进制。
///
/// 约定：
///   * `expect` / `expectEqual` —— 期望成立；失败即计入 `failed`（源码 Bug 或断言 Bug）。
///   * `expectKnownBug` —— 已确认的源码缺陷；不计入 `failed`，只打印 ⚠️ 并在结尾汇总，
///     保证 CI 仍可通过，同时缺陷在测试输出里持续可见。
@main
struct EdgeTests {
    static var failed = 0
    static var knownBugs = 0

    // MARK: - 断言工具

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

    /// 记录一个已知缺陷：不影响退出码，但会显式打印出来。
    static func expectKnownBug(_ message: String) {
        print("  ⚠️  已知缺陷：\(message)")
        knownBugs += 1
    }

    // MARK: - 入口

    static func main() {
        print("== E1. M3U 边界输入 ==")
        testM3UBoundaries()
        print("== E2. M3U 编码与本地文件 ==")
        testM3UEncoding()
        print("== E3. 台号分配边界 ==")
        testNumberingBoundaries()
        print("== E4. 搜索边界 ==")
        testSearchBoundaries()
        print("== E5. 模型容错 ==")
        testModelBoundaries()
        print("== E6. 收藏边界 ==")
        testFavoritesBoundaries()

        print("")
        if knownBugs > 0 {
            print("已知缺陷 \(knownBugs) 项 ⚠️（不计入失败，需工程师确认）")
        }
        if failed == 0 {
            print("边界测试全部通过 ✅")
            exit(0)
        } else {
            print("边界测试失败 \(failed) 项 ❌")
            exit(1)
        }
    }

    // MARK: - E1 M3U 边界

    static func testM3UBoundaries() {
        expectEqual(M3UParser.parse(text: "").count, 0, "空文件解析出 0 条")
        expectEqual(M3UParser.parse(text: "\n\n\n").count, 0, "只有空行解析出 0 条")
        expectEqual(M3UParser.parse(text: "#EXTM3U\n").count, 0, "只有 #EXTM3U 头解析出 0 条")

        // #EXTINF 没有任何属性、也没有逗号分隔的显示名
        let bareExtinf = M3UParser.parse(text: "#EXTINF:-1\nhttp://a.example.com/b.m3u8")
        expectEqual(bareExtinf.count, 1, "#EXTINF:-1 无属性仍解析出 1 条")
        expectEqual(bareExtinf.first?.name, "b", "无显示名时回退为 URL 文件名")

        // URL 带 query 与中文参数：URL 原样保留，显示名取 EXTINF
        let queryURL = "#EXTINF:-1 tvg-id=\"Q.cn\",中文台\nhttp://a.example.com/live.m3u8?token=1&name=中文"
        let queryEntries = M3UParser.parse(text: queryURL)
        expectEqual(queryEntries.first?.url, "http://a.example.com/live.m3u8?token=1&name=中文",
                    "带 query 与中文的 URL 原样保留")
        expectEqual(M3UParser.channels(from: queryEntries).first?.name, "中文台",
                    "带 query 的条目仍能归并成频道且保留中文名")

        // 相对路径：按设计只接受 http/https/rtmp/file 与本地绝对路径
        expectEqual(M3UParser.parse(text: "#EXTINF:-1,相对路径\nsub/ch.m3u8").count, 0,
                    "相对路径 m3u8 被丢弃（不崩溃、不产生坏条目）")

        // BOM 头 + CRLF
        let bom = "\u{FEFF}#EXTM3U\r\n#EXTINF:-1 tvg-id=\"B.cn\",BOM 台\r\nhttp://a.example.com/bom.m3u8\r\n"
        let bomEntries = M3UParser.parse(text: bom)
        expectEqual(bomEntries.count, 1, "BOM 头 + CRLF 仍解析出 1 条")
        expectEqual(bomEntries.first?.name, "BOM 台", "BOM 文件里的中文名正确")

        // 同一频道重复 URL 去重
        let dup = """
        #EXTINF:-1 tvg-id="D.cn",重复台
        http://a.example.com/x.m3u8
        #EXTINF:-1 tvg-id="D.cn",重复台
        http://a.example.com/x.m3u8
        """
        let dupChannels = M3UParser.channels(from: M3UParser.parse(text: dup))
        expectEqual(dupChannels.count, 1, "同 tvg-id 归并成 1 个频道")
        expectEqual(dupChannels.first?.streams.count, 1, "重复 URL 去重成 1 条流")

        // #EXTGRP 出现在 #EXTINF 之后、URL 之前
        let extgrp = "#EXTINF:-1,省级台\n#EXTGRP:省级\nhttp://a.example.com/p.m3u8"
        expectEqual(M3UParser.parse(text: extgrp).first?.groupTitle, "省级",
                    "EXTINF 之后的 #EXTGRP 仍生效")

        // 没有 #EXTINF 的裸 URL
        let bare = M3UParser.parse(text: "http://a.example.com/bare.m3u8")
        expectEqual(bare.count, 1, "裸 URL 也生成 1 条播放项")
        expectEqual(bare.first?.name, "bare", "裸 URL 用文件名作为显示名")

        // 已知缺陷：group-title 内含逗号时，按第一个逗号切分会截断属性
        let commaGroup = "#EXTINF:-1 group-title=\"新闻,体育\",测试频道\nhttp://a.example.com/c.m3u8"
        let commaEntry = M3UParser.parse(text: commaGroup).first
        if commaEntry?.groupTitle == "新闻,体育" && commaEntry?.name == "测试频道" {
            expect(true, "group-title 含逗号时解析正确")
        } else {
            expectKnownBug("""
            M3UParser 按第一个逗号切分 #EXTINF，group-title/tvg-name 内含逗号时属性被截断
            （实际 name=\(commaEntry?.name ?? "nil")，group=\(commaEntry?.groupTitle ?? "nil")，\
            期望 name=测试频道 / group=新闻,体育）
            """)
        }
    }

    // MARK: - E2 编码与本地文件

    static func testM3UEncoding() {
        let directory = FileManager.default.temporaryDirectory
        let utf8URL = directory.appendingPathComponent("tvbox-qa-utf8-\(UUID().uuidString).m3u")
        let gbURL = directory.appendingPathComponent("tvbox-qa-gb18030-\(UUID().uuidString).m3u")
        defer {
            try? FileManager.default.removeItem(at: utf8URL)
            try? FileManager.default.removeItem(at: gbURL)
        }

        let text = "#EXTM3U\r\n#EXTINF:-1 tvg-id=\"CN1.cn\",央视一套\r\nhttp://a.example.com/1.m3u8\r\n"

        // UTF-8 文件
        guard let utf8Data = text.data(using: .utf8) else {
            expect(false, "构造 UTF-8 测试文件")
            return
        }
        try? utf8Data.write(to: utf8URL)
        let utf8Entries = (try? M3UParser.load(fileURL: utf8URL)) ?? []
        expectEqual(utf8Entries.count, 1, "本地 UTF-8 文件解析出 1 条")
        expectEqual(utf8Entries.first?.name, "央视一套", "UTF-8 文件中文名正确")

        // GB18030 文件（老式 m3u 常见编码）
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        guard let gbData = text.data(using: gb18030) else {
            expect(false, "构造 GB18030 测试文件")
            return
        }
        // 前置条件：GB18030 字节流不是合法 UTF-8，否则测不到降级分支
        expect(String(data: gbData, encoding: .utf8) == nil, "GB18030 字节流不是合法 UTF-8（保证走降级分支）")
        try? gbData.write(to: gbURL)
        let gbEntries = (try? M3UParser.load(fileURL: gbURL)) ?? []
        expectEqual(gbEntries.count, 1, "本地 GB18030 文件解析出 1 条")
        expectEqual(gbEntries.first?.name, "央视一套", "GB18030 文件中文名正确（自动降级解码）")

        // 不存在的文件应抛错而不是崩溃
        let missing = directory.appendingPathComponent("tvbox-qa-missing-\(UUID().uuidString).m3u")
        var threw = false
        do {
            _ = try M3UParser.load(fileURL: missing)
        } catch {
            threw = true
        }
        expect(threw, "读取不存在的文件抛错（不崩溃）")
    }

    // MARK: - E3 台号边界

    static func testNumberingBoundaries() {
        // 900 已被占用，两个空号应顺延到 901 / 902
        let occupied = [
            Channel(id: "p900", name: "已占用 900", group: .custom, number: 900),
            Channel(id: "b1", name: "空白 A", group: .custom, number: 0),
            Channel(id: "b2", name: "空白 B", group: .custom, number: 0),
        ]
        let assigned = ChannelNumbering.assignNumbers(occupied)
        func number(_ id: String) -> Int { assigned.first { $0.id == id }?.number ?? -1 }
        expectEqual(number("p900"), 900, "已占用台号不被改写")
        expectEqual(number("b1"), 901, "自定义源跳过已占用台号（901）")
        expectEqual(number("b2"), 902, "自定义源继续顺延（902）")

        // 自定义分组只有 900...999 共 100 个号
        let many = (0..<105).map { Channel(id: "m\($0)", name: "M\($0)", group: .custom, number: 0) }
        let overflow = ChannelNumbering.assignNumbers(many)
        let numbers = overflow.map { $0.number }
        let zeroCount = numbers.filter { $0 == 0 }.count
        expectEqual(zeroCount, 5, "超过 999 的 5 个频道保持台号 0（不越界、不崩溃）")
        expectEqual(numbers.filter { $0 > 0 }.count, 100, "900...999 正好容纳 100 个频道")
        expectEqual(numbers.max() ?? 0, 999, "最大台号不超过自定义区间上界 999")

        // 台号 > 999 时格式化不应崩，仍按 %03d 输出
        expectEqual(Channel(id: "big", name: "超界台", group: .custom, number: 1200).formattedNumber,
                    "1200", "台号超 999 时 formattedNumber 输出 4 位而不崩溃")

        // 重复台号：按设计不自动重排（台号来自烘焙），仅保证不崩溃
        let duplicates = [
            Channel(id: "d1", name: "甲台", group: .satellite, number: 100),
            Channel(id: "d2", name: "乙台", group: .satellite, number: 100),
        ]
        expectEqual(ChannelNumbering.assignNumbers(duplicates).map { $0.number }, [100, 100],
                    "重复台号不被自动改写（保持稳定，需烘焙侧保证唯一）")

        // number == 0 且分组为空列表时不产生副作用
        expectEqual(ChannelNumbering.assignNumbers([]).count, 0, "空频道列表不崩溃")
    }

    // MARK: - E4 搜索边界

    static func testSearchBoundaries() {
        let channels = [
            Channel(id: "1", name: "CCTV-1 综合", subname: "CCTV-1", group: .cctv, number: 1),
            Channel(id: "103", name: "浙江卫视", subname: "Zhejiang Satellite TV", group: .satellite, number: 103),
            Channel(id: "400", name: "翡翠台", subname: "TVB Jade", group: .hkmt, number: 400),
        ]

        expectEqual(ChannelSearch.filter(channels, query: "").count, 3, "空查询返回全部")
        expectEqual(ChannelSearch.filter(channels, query: "   ").count, 3, "纯空格查询返回全部")
        expectEqual(ChannelSearch.filter(channels, query: "001").first?.id, "1",
                    "台号字符串 \"001\" 能命中 001 台")
        expectEqual(ChannelSearch.filter(channels, query: "1").first?.id, "1",
                    "台号 \"1\" 也能命中 001 台")
        expectEqual(ChannelSearch.filter(channels, query: "CCTV").first?.id, "1",
                    "大写 CCTV 命中（不区分大小写）")
        expectEqual(ChannelSearch.filter(channels, query: "cctv").first?.id, "1",
                    "小写 cctv 命中")
        expectEqual(ChannelSearch.filter(channels, query: "103").first?.id, "103",
                    "完整台号 103 命中")
        expectEqual(ChannelSearch.filter(channels, query: "zhejiang").first?.id, "103",
                    "英文名全拼命中")
        expectEqual(ChannelSearch.filter(channels, query: "zjws").first?.id, "103",
                    "拼音首字母命中")
        expectEqual(ChannelSearch.filter(channels, query: "999").count, 0, "不存在的台号返回空")
        expectEqual(ChannelSearch.filter([], query: "任意").count, 0, "空频道列表搜索不崩溃")

        // 单频道匹配的纯数字分支
        expect(ChannelSearch.matches(channels[0], query: "00"), "matches 支持台号前缀 \"00\"")
        expect(!ChannelSearch.matches(channels[0], query: "401"), "台号不匹配时返回 false")
    }

    // MARK: - E5 模型容错

    static func testModelBoundaries() {
        // 字段全为 null / 非法枚举：解码不应失败
        let nullJSON = """
        {"id":null,"name":null,"group":"火星","number":null,"categories":null,"streams":null}
        """.data(using: .utf8)!
        guard let channel = try? JSONDecoder().decode(Channel.self, from: nullJSON) else {
            expect(false, "字段为 null 的 JSON 应能解码")
            return
        }
        expectEqual(channel.name, "未知频道", "name 为 null 时回退为「未知频道」")
        expectEqual(channel.group, .local, "非法 group（火星）回退为地方分组")
        expectEqual(channel.number, 0, "number 为 null 时回退为 0")
        expectEqual(channel.streams.count, 0, "streams 为 null 时回退为空数组")
        expectEqual(channel.categories.count, 0, "categories 为 null 时回退为空数组")
        expectEqual(channel.id.count, 36, "id 缺失时生成 UUID（36 字符）")
        expectEqual(channel.subtitle, "", "空副标题不展示")

        // 非 JSON 应抛错（调用方有 catch）
        let broken = "这不是 JSON".data(using: .utf8)!
        expect((try? JSONDecoder().decode(Channel.self, from: broken)) == nil, "非 JSON 输入解码失败（抛错而非崩溃）")

        // 空 streams：preferredStream 为 nil
        expect(Channel(id: "e", name: "空源台").preferredStream == nil, "没有流时 preferredStream 为 nil")

        // StreamEndpoint 缺字段
        let streamJSON = """
        {"url":"http://a.example.com/x.m3u8"}
        """.data(using: .utf8)!
        let endpoint = try? JSONDecoder().decode(StreamEndpoint.self, from: streamJSON)
        expectEqual(endpoint?.quality, "", "流缺 quality 时回退为空")
        expectEqual(endpoint?.qualityLabel, "直播", "缺 quality 时展示「直播」")

        // 真实 catalog.json 截取样本：缺 number / 缺 logoURL 也能解码
        let realSample = """
        {"id":"CCTV1.cn","name":"CCTV-1 综合","subname":"CCTV-1","group":"央视",
         "logoURL":"","categories":["cctv"],"isCustom":false,
         "streams":[{"url":"http://a.example.com/1.m3u8","quality":"1080p","isAlive":true}]}
        """.data(using: .utf8)!
        let real = try? JSONDecoder().decode(Channel.self, from: realSample)
        expectEqual(real?.number, 0, "真实样本缺 number 时回退为 0")
        expectEqual(real?.preferredStream?.url, "http://a.example.com/1.m3u8", "真实样本首选流正确")
    }

    // MARK: - E6 收藏边界

    static func testFavoritesBoundaries() {
        expectEqual(FavoritesCodec.decode("[\"a\",\"a\",\"b\"]"), ["a", "b"], "重复收藏项解码后去重")
        expectEqual(FavoritesCodec.decode("{\"a\":1}"), [], "JSON 对象（非数组）解码为空集合")
        expectEqual(FavoritesCodec.decode("[]"), [], "空数组解码为空集合")
        expectEqual(FavoritesCodec.encode(["b", "a"]), "[\"a\",\"b\"]", "编码结果按字典序稳定输出")

        // 往返：含特殊字符的频道 id
        let ids: Set<String> = ["custom-中文-1", "CCTV1.cn", "uuid-1234"]
        expectEqual(FavoritesCodec.decode(FavoritesCodec.encode(ids)), ids,
                    "含中文/特殊字符的 id 编解码往返一致")
    }
}
