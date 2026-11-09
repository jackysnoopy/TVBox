# TVBox · macOS 电视直播播放器

像机顶盒一样用的原生 macOS 直播播放器：打开就是直播画面，左侧频道分组，切台浮出 OSD，
数字键直选台号，源挂了自动切备用源。**纯系统框架（SwiftUI + AVFoundation + AppKit），零第三方依赖。**

数据来自 [iptv-org](https://github.com/iptv-org/iptv) 的公开索引（`https://iptv-org.github.io/api/*`），
烘焙成随 App 分发的 `Resources/catalog.json`，冷启动不联网、秒开。

---

## 1. 环境要求

| 项 | 要求 |
| --- | --- |
| 系统 | macOS 13.0 或更高（实测 macOS 15.7.2 / Apple Silicon） |
| 编译 | 只需 **CommandLineTools**（有 `swiftc` 即可，**不需要完整 Xcode**、不需要 SPM 联网拉依赖） |
| 烘焙脚本 | Python 3.9+（可选，只有想更新频道目录时才需要） |

## 2. 一键运行

```bash
bash run.sh          # 编译 + 启动
```

只编译不启动：

```bash
bash build.sh        # 产物：build/TVBox.app
open build/TVBox.app
```

编译细节：`swiftc -O -swift-version 5 -parse-as-library -target <arch>-apple-macos13.0`，
手写 `Info.plist`（含 `NSAppTransportSecurity → NSAllowsArbitraryLoads`，IPTV 源大量是 http 明文），
最后 `codesign -s - --force --deep` 做 ad-hoc 签名。

## 3. 目录结构

```
TV/
├── build.sh                     # swiftc 编译 + 组装 .app + ad-hoc 签名
├── run.sh                       # build.sh 后 open
├── Resources/
│   ├── catalog.json             # 预烘焙频道目录（220 个频道 / 519 条流）
│   ├── logos/                   # 随包分发的台标（44 张，烘焙时下载，断网也能显示）
│   └── Info.plist.in            # 模板，build.sh 替换版本号/架构
├── Sources/
│   ├── App/TVBoxApp.swift       # @main / AppDelegate / AppCoordinator / 键盘遥控
│   ├── Models/Channel.swift     # Channel / StreamEndpoint / ChannelGroup / PlaybackState
│   ├── Services/
│   │   ├── CatalogService.swift # 内置目录读取、后台增量刷新、自定义源持久化
│   │   ├── M3UParser.swift      # #EXTINF / #EXTVLCOPT / #EXTGRP 解析
│   │   ├── ChannelLogic.swift   # 台号分配、拼音搜索、收藏序列化（纯函数，可单测）
│   │   ├── ChannelStore.swift   # 分组归并、收藏、自定义源、搜索
│   │   └── PlaybackEngine.swift # AVPlayer 封装：多源故障切换、卡流检测、退避重试
│   └── Views/                   # ContentView / SidebarView / PlayerLayerView / OSDOverlay / SettingsSheet / SearchBar
├── tools/bake_catalog.py        # 抓 iptv-org API → 烘焙 catalog.json（可探测存活）
├── tests/                       # 逻辑层单测（CLI，无需 UI）
└── build/                       # 构建产物
```

## 4. 遥控快捷键

| 按键 | 作用 |
| --- | --- |
| `数字键` | 输入台号直选（1.5 秒内累积，OSD 实时显示；不可能再有后续时立即切台） |
| `↑` / `↓` | 上一个 / 下一个频道 |
| `空格` | 暂停 / 继续 |
| `←` / `→` | 快退 15 秒 / 回到直播边缘 |
| `F` 或双击画面 | 全屏切换（进入全屏自动收起侧栏和顶栏 = 纯画面，退出恢复原状态） |
| `S` 或工具栏侧栏按钮 | 收起 / 展开侧栏（收起状态重启后仍记住；全屏中只临时切换） |
| `Esc` | 退出全屏 / 清空台号输入 |
| `M` | 静音 |
| `Tab` / `⌘F` | 光标进入搜索框（`Esc` 退出，输入框内不抢按键） |

搜索支持：**台名 / 英文名 / 拼音首字母 / 全拼 / 台号**，例如 `hnws` → 湖南卫视、`103` → 浙江卫视。

## 5. 台号规则（稳定不变）

| 分组 | 台号 |
| --- | --- |
| 央视 | 1–99（CCTV-1…17 按序号，衍生频道续排） |
| 卫视 | 100–199（按省份固定顺序） |
| 地方 | 200–399 |
| 港澳台 | 400–499（港 400- / 澳 430- / 台 450-） |
| 国际 | 500–599（精选新闻 + CGTN 多语种） |
| 自定义 | 900–999 |

台号在烘焙时一次性算好写进 `catalog.json`，App 端不再重排，所以「101 台」永远指同一个频道。

## 6. 换源 / 导入自定义源

界面右上角齿轮 → 设置面板：

1. **粘贴 m3u / m3u8 链接** → 「导入链接」（支持 `#EXTINF` 的 tvg-id / tvg-name / tvg-logo / group-title，
   以及 `#EXTVLCOPT:http-user-agent=…` / `http-referrer=…`）。
2. **选择本地文件** → `NSOpenPanel` 选 `.m3u` / `.m3u8`（自动尝试 UTF-8 / GB18030 解码）。

导入后并入「自定义」分组（台号 900 起），持久化在
`~/Library/Application Support/TVBox/custom-sources.json`，重启仍在，可在设置里删除。

设置面板里还有「立即刷新」：只更新流地址，不改名、不改台号。

## 7. 重新烘焙频道目录

```bash
python3 tools/bake_catalog.py --probe      # 推荐：并发探测每条流是否存活（结果缓存 24h）
python3 tools/bake_catalog.py --refresh    # 强制重新下载 API（channels.json 约 8MB，较慢）
python3 tools/bake_catalog.py --region US,UK,JP   # 额外收录其它国家的全部频道
```

烘焙耗时主要在网络（`streams.json` 3.7MB / `channels.json` 8MB / `logos.json` 5.8MB），脚本对 API 做了
**Range 分块 + 断点续传 + 重试**，并把 API 与探测结果缓存在 `tools/.cache/`，重复烘焙不必重下。

台标也在这里处理：`logos.json` 里挑出每个频道最合适的台标（`in_use` 优先 → 图床可达性 →
可解码格式 → 分辨率），把**图片字节下载到 `Resources/logos/<频道id>.<ext>`** 随包分发（单张 8 秒上限、
>200KB 跳过、目录总量 ≤5MB、并发 8）。下载会校验图片魔数，防止把「200 + HTML 兜底页」当成台标存下来；
首选图床失败会自动换下一个候选。只想更新频道、不碰台标用 `--skip-logos`。

烘焙完重新 `bash build.sh` 即可打进 App（会自动把 `Resources/logos/` 拷进 bundle）。

## 8. 播放与故障切换

* `AVPlayer` + `AVPlayerLayer`（`NSViewRepresentable`），`videoGravity = .resizeAspect`。
* 需要 `user_agent` / `referrer` 的源通过 `AVURLAsset(url:options:)` 注入请求头。
* **失败判定**：`AVPlayerItem.status == .failed`、`AVPlayerItemFailedToPlayToEndTime` 通知、
  首帧超过 15 秒未出画面、或播放中 `currentTime` 连续 20 秒没有变化。
  `AVPlayerItemPlaybackStalled` **不算失败**，只把 OSD 切到「缓冲中」——中高码率直播
  每跨分片都会发它，当成致命错误会把能自愈的流误杀成黑屏。
* **切换策略**：按「内置存活源 → 补源 → 内置死源」合并顺序取候选，失败后切下一条，
  退避 1s / 2s / 4s（上限 5s）；一轮用完隔 5 秒重新开始，共 3 轮，仍失败则显示
  「该频道当前无可用源」+ 重试按钮。**只要有画面出来过，重试轮数就清零**，
  避免「每分钟重连一次」的补源看几分钟就被判死。
* OSD 实时显示「正在切换备用源 (2/3)」与当前源清晰度（`2160p` / `1080p` …），
  补源还会多一个绿色「精选源」标签。

## 9. 自测

```bash
bash tests/run_tests.sh
```

覆盖 M3U 解析（含 CRLF / 脏数据 / `group-title="新闻,体育"` 这种**引号内含逗号**的属性）、
台号分配与幂等、拼音/台号/名称搜索、收藏序列化、模型容错与首选流排序、
自定义源 id 的**跨进程稳定性**（FNV-1a 64，不用 `String.hashValue`）、台标徽标规则；
另有 `tests/test_bake.py` 覆盖烘焙脚本的台标挑选/魔数校验/候选兜底/台号区间。

## 10. 已知限制

* 台标分三级加载：**内置 `Resources/logos/` → 远端 URL（5 秒） → 文字徽标**。
  目前 221 台里有 **140 台**带内置真台标（121 张来自 fanmingming/live、19 张来自 iptv-org），
  其余 81 台走**文字徽标**（如 `CCTV-1 → 「1」`、`湖南卫视 → 「湖」`），
  底色由频道 id 稳定哈希决定，不会出现「整列空白」。

### 10.1 人工补源（`tools/source-overrides.json`）

iptv-org 里有一部分频道**服务端已经全死**（例如 CCTV-6：原来 3 条源分别返回 502 / 301 超时 / 500），
这类情况靠「换网络」救不回来。为此加了人工补源表：

```json
{
  "version": 1,
  "updatedAt": "2026-10-26",
  "channels": {
    "CCTV6.cn": [
      { "url": "http://223.110.241.204:6610/gitv/live1/G_CCTV-6-AVS-4K264/G_CCTV-6-AVS-4K264/index.m3u8",
        "quality": "2160p", "note": "江苏移动 GITV CDN，302 跳转，2026-10-26 实测可播" }
    ]
  }
}
```

* **加源方式**：在 `channels` 下按 channel id（catalog 里的 `id`，如 `CCTV6.cn`）追加数组项，
  不需要改 `bake_catalog.py`，重跑烘焙即可。
* **origin 字段**：内置流标 `origin: "iptv-org"`，补源流标 `origin: "curated"`；
  App 在 OSD 上用绿色「精选源」标签标出来，排查时也能一眼分辨。
* **合并顺序**：内置存活流永远排在补源前面；**只有内置一条活的都没有时**，补源才会被提到第一位。
  这样 CCTV-6 立刻能看，而 CCTV-1/2/3 这类本来能播的台不会被 18~24Mbps 的 4K 源顶到前面
  （4K 源在弱网下更容易卡）。运行期还有一条：**只要存在烘焙时验证过的存活源，
  故障切换就只在存活源之间进行**——`isAlive=false` 的源大概率真死，挨个试只会黑屏十几秒。
* **依赖限制**：当前这批补源来自**江苏移动 GITV CDN**，实测首次请求会 302 跳转，
  播放器与烘焙探测都会跟随重定向。**外省宽带、海外网络不一定通**（同一运营商不同省也可能不通），
  不通时 App 会照常回落到「该频道当前无可用源」面板，并给出「打开官方直播页」按钮。
* **稳定性**（2026-10-26 实测）：这条 CDN 的会话大约 **60 秒**就会失效
  （`CoreMediaError -12312` / 会话过期断流），重新构建 `AVPlayerItem` 就能拿到新会话继续播。
  所以超时按流分级放宽：普通源首帧 25 秒 / 卡流 8 秒；**4K 补源首帧 45 秒 / 卡流 12 秒**
  （实测 4K 冷启动首帧要 ~30 秒，15 秒会把它当死源误杀）；有烘焙时验证过的存活源时
  失败后自动重拉（不再去挨个试死源），表现是「能一直看，但每分钟会顿一下」。
* 实测解析分辨率：CCTV-6 补源实际下发 **1920×1080**（OSD 里的 `2160p` 是源标注清晰度），
  CCTV-1 补源是真 **3840×2160**，后者对带宽更敏感，弱网会更容易看到缓冲。
* 已知同族里的 `G_CCTV-6`、`G_CCTV-6-HD`、`G_CCTV-6-CQ`、`-H265`、`-4K` 都是**空列表**
  （只有 `#EXTM3U` 没有分段），不要加；CCTV-4/7/10~17 同族同样是空列表。

### 10.2 无源频道的官方兜底

目录里仍有约 40% 的频道公网确实找不到可用源。这类频道失败时，
「该频道当前无可用源」面板除「重试」外会多一个 **「打开官方直播页」**：
`CCTVx.cn` → `https://tv.cctv.com/live/cctvx/`，其它频道用 catalog 里的 `website`，
两者都没有就不显示该按钮。

### 10.3 其它

* 部分源是 http 明文或被墙/失效，`catalog.json` 里的 `isAlive` 只是**烘焙时刻**的探测结果，
  会随时间漂移；每次启动后的后台刷新会更新 URL 列表，但不会重新探测存活。
* 烘焙探测的判定标准是「跟 302 后 m3u8 里有 `#EXTINF`，且首分段能取到 >50KB 字节」。
  判定逻辑一变就要升 `PROBE_VERSION`，否则会沿用旧口径的缓存（这次就从 1 升到了 2）。
* 运行期刷新只拉 `streams.json`（3.7MB），因此**不会发现全新频道**（新频道名称需要 `channels.json`）。
  需要新频道时请重新烘焙。
* 直播时移能力取决于源站是否保留 TS 分片；不支持时 `←` 无效、`→` 直接回边缘。
* 频道内容版权归各电视台/源站所有，本工具仅做播放器，请自行确认来源合法性。
