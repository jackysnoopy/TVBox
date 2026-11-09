#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 iptv-org 的公开索引烘焙成随 App 分发的 Resources/catalog.json。

设计要点：
  * 只访问 https://iptv-org.github.io/api/*（raw.githubusercontent.com 在本机不可达）。
  * 该域名网络不稳定，所有下载都走「Range 分块 + 断点续传 + 重试」。
  * channels.json 约 8MB / 12s，缓存到 tools/.cache/，重复烘焙不必重下。
  * 分组与台号在这里一次性算好写死，App 端不再做排序，保证台号稳定。
  * --probe 会并发探测每条流是否真的能出 m3u8，结果写进 isAlive 用于排序。
  * 台标来自独立的 logos.json；因为很多图床（i.imgur.com）在部分网络不可达，
    烘焙时会把图片字节下到 Resources/logos/ 随包分发（catalog 里记 logoFile 相对路径）。

用法：
  python3 tools/bake_catalog.py                # 用缓存（没有则下载）烘焙
  python3 tools/bake_catalog.py --refresh      # 强制重新下载
  python3 tools/bake_catalog.py --probe        # 额外探测流可用性（推荐）
  python3 tools/bake_catalog.py --probe --limit 400
"""

from __future__ import annotations

import argparse
import concurrent.futures as futures
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API_BASE = "https://iptv-org.github.io/api"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE_DIR = os.path.join(ROOT, "tools", ".cache")
OUT_PATH = os.path.join(ROOT, "Resources", "catalog.json")
LOGOS_DIR = os.path.join(ROOT, "Resources", "logos")
OVERRIDES_PATH = os.path.join(ROOT, "tools", "source-overrides.json")

# 台标：iptv-org 的 channels.json 没有 logo 字段，台标拆在 logos.json 里。
# 其中大量图片托管在 i.imgur.com，本机实测不可达，所以烘焙时把字节抓下来随包分发。
UNREACHABLE_HOSTS = ("i.imgur.com",)
MAX_LOGO_BYTES = 200 * 1024        # 单张超过 200KB 跳过（体积控制）
LOGO_TOTAL_BUDGET = 5 * 1024 * 1024  # 台标目录总体积上限
IMAGE_FORMATS = {"png": "png", "jpeg": "jpg", "jpg": "jpg", "gif": "gif", "webp": "webp"}

# 一级台标源：fanmingming/live 的 tv/ 目录（930 张，央视/卫视/地方台基本齐全）。
# 通过 jsDelivr 的 GitHub 镜像取原始文件；本机实测 gcore 边缘可达，fastly/cdn 作为异地兜底。
# 注意：文件名大小写敏感（`CCTV1.png` 而不是 `cctv1.png`），必须先拿仓库文件树再精确匹配。
FM_LOGO_BASES = (
    "https://gcore.jsdelivr.net/gh/fanmingming/live@main/tv/",
    "https://fastly.jsdelivr.net/gh/fanmingming/live@main/tv/",
    "https://cdn.jsdelivr.net/gh/fanmingming/live@main/tv/",
)
FM_TREE_URL = "https://api.github.com/repos/fanmingming/live/git/trees/main?recursive=1"
FM_LOGO_CACHE = os.path.join(CACHE_DIR, "logos-fm")
FM_TREE_CACHE = os.path.join(CACHE_DIR, "fm-tree.json")
FM_TREE_TTL = 7 * 24 * 3600
FM_LOGO_MAX_BYTES = 200 * 1024
FM_RETRIES = 3
FM_RETRY_GAP = 2.0

CACHE_TTL = 12 * 3600  # 12 小时内复用缓存

# 探测逻辑版本：判定标准变了（#EXTINF + 首分段 >50KB）就升版本，旧缓存自动作废，
# 避免把「只看 #EXTM3U」时代的误判结果沿用下来。
PROBE_VERSION = 2

CJK_RE = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff]")

# 卫视排序：省份/直辖市固定顺序（关键字 -> 次序）
SATELLITE_ORDER = [
    ("北京", 1), ("东方", 2), ("上海", 2), ("天津", 3), ("重庆", 4),
    ("河北", 5), ("山西", 6), ("内蒙古", 7), ("辽宁", 8), ("吉林", 9),
    ("黑龙江", 10), ("江苏", 11), ("浙江", 12), ("安徽", 13), ("福建", 14),
    ("江西", 15), ("山东", 16), ("河南", 17), ("湖北", 18), ("湖南", 19),
    ("广东", 20), ("广西", 21), ("海南", 22), ("四川", 23), ("贵州", 24),
    ("云南", 25), ("西藏", 26), ("陕西", 27), ("甘肃", 28), ("青海", 29),
    ("宁夏", 30), ("新疆", 31), ("深圳", 32), ("延边", 33), ("兵团", 34),
    ("厦门", 35), ("海峡", 36), ("三沙", 37), ("农林", 38), ("城市", 39),
]

# 英文频道名里的省份/城市 → 中文（把 "Guangdong Satellite TV" 变成 "广东卫视"）
PROVINCE_ZH = {
    "Beijing": "北京", "Tianjin": "天津", "Hebei": "河北", "Shanxi": "山西",
    "Inner Mongolia": "内蒙古", "Nei Monggol": "内蒙古", "Liaoning": "辽宁",
    "Jilin": "吉林", "Heilongjiang": "黑龙江", "Shanghai": "上海", "Jiangsu": "江苏",
    "Zhejiang": "浙江", "Anhui": "安徽", "Fujian": "福建", "Jiangxi": "江西",
    "Shandong": "山东", "Henan": "河南", "Hubei": "湖北", "Hunan": "湖南",
    "Guangdong": "广东", "Guangxi": "广西", "Hainan": "海南", "Chongqing": "重庆",
    "Sichuan": "四川", "Guizhou": "贵州", "Yunnan": "云南", "Tibet": "西藏",
    "Xizang": "西藏", "Shaanxi": "陕西", "Gansu": "甘肃", "Qinghai": "青海",
    "Ningxia": "宁夏", "Xinjiang": "新疆", "Shenzhen": "深圳", "Yanbian": "延边",
    "Bingtuan": "兵团", "Kangba": "康巴", "Guangzhou": "广州", "Harbin": "哈尔滨",
    "Xi'an": "西安", "Xuzhou": "徐州", "Changsha": "长沙", "Dongguan": "东莞",
    "Chuzhou": "滁州", "Chaozhou": "潮州", "Chifeng": "赤峰", "Baicheng": "白城",
    "Anshun": "安顺", "Dunhuang": "敦煌", "Jiuquan": "酒泉", "Pingxiang": "萍乡",
    "Hebi": "鹤壁", "Hezheng": "和政", "Siping": "四平", "Tonghua": "通化",
    "Liangshan": "凉山", "Xiamen": "厦门", "Sanya": "三亚",
}

# 英文词 → 中文（用于地方频道的名称本地化）
WORD_ZH = {
    "Comprehensive": "综合", "News": "新闻", "Channel": "频道", "Channels": "频道",
    "Public": "公共", "Economic": "经济", "Life": "生活", "Sports": "体育",
    "Variety": "综艺", "Movie": "影视", "Movies": "影视", "Film": "影视",
    "Children's": "少儿", "Children": "少儿", "Kids": "少儿", "Agriculture": "农业",
    "Agricultural": "农业", "Science": "科教", "Education": "教育", "Educational": "教育",
    "City": "城市", "Metro": "都市", "Fashion": "时尚", "Documentary": "纪实",
    "Travel": "旅游", "Women's": "女性", "Women": "女性", "Law": "政法",
    "Business": "商务", "Finance": "财经", "Culture": "文化", "Music": "音乐",
    "Theater": "剧场", "Theatre": "剧场", "Drama": "电视剧", "Shopping": "购物",
    "International": "国际", "Chinese": "中文", "Cartoon": "卡通", "Animation": "动画",
    "Health": "卫生健康", "Weather": "气象", "Satellite": "卫视", "TV": "电视台",
    "Local": "地方", "General": "综合", "Entertainment": "娱乐", "Sports'": "体育",
    "Info": "资讯", "Information": "资讯", "News'": "新闻", "Traffic": "交通",
    "Radio": "广播", "Movie'": "影视", "Opera": "戏曲", "Cooking": "美食",
    "Golf": "高尔夫", "Tennis": "网球", "Football": "足球", "Basketball": "篮球",
    "Military": "军事", "Defense": "国防", "Tourism": "旅游", "Travel'": "旅游",
    "Qilu": "齐鲁", "and": "和", "Mongolian": "蒙古语", "Mongoli": "蒙古语",
    "High": "高清", "GoldenEagle": "金鹰", "Chinese'": "中文",
}

# 个别机器翻译不通顺的台名，直接写死
NAME_OVERRIDE = {
    "China Travel": "中国旅游",
    "Discovering China": "发现中国",
    "Golden Eagle Cartoon": "金鹰卡通",
    "High Channel TV": "高清频道",
    "You Man Cartoon Channel": "优漫卡通",
    "Ando TV": "安多电视台",
    "BRTV Kaku Childrens Channel": "BRTV 卡酷少儿",
    "Nei Monggol TV 2 Mongolian": "内蒙古电视台 蒙古语",
    "Sichuan TV Women and Children's Channel": "四川电视台 妇女儿童频道",
    "Shandong TV Qilu Channel": "山东电视台 齐鲁频道",
    "VOA美国之音": "VOA 美国之音",
    "TV BRICS Chinese": "TV BRICS 中文",
    "CCTV+ 1": "CCTV+ 1",
    "CCTV+ 2": "CCTV+ 2",
}

# 国际精选（顺序即台号顺序 500 起）。只保留真正有流、且品牌可辨识的频道。
INTERNATIONAL_CURATED = [
    ("CGTN.cn", "CGTN 英语"),
    ("CGTNDocumentary.cn", "CGTN 纪录"),
    ("CGTNSpanish.cn", "CGTN 西语"),
    ("CGTNFrench.cn", "CGTN 法语"),
    ("CGTNRussian.cn", "CGTN 俄语"),
    ("CGTNArabic.cn", "CGTN 阿语"),
    ("BBCNews.uk", "BBC 新闻"),
    ("CNNInternational.us", "CNN 国际"),
    ("AlJazeera.qa", "半岛电视台"),
    ("EuronewsEnglish.fr", "欧洲新闻台"),
    ("GBNews.uk", "GB News"),
    ("FoxNewsChannel.us", "福克斯新闻"),
    ("ABCNews.au", "ABC 新闻(澳)"),
    ("NHKWorldJapan.jp", "NHK 世界"),
    ("ArirangTV.kr", "阿里郎 TV"),
    ("KBSWorld.kr", "KBS World"),
    ("TRTWorld.tr", "TRT World"),
    ("NDTV24x7.in", "NDTV 24x7"),
    ("i24NEWSEnglishWorld.il", "i24NEWS"),
    ("SkyNewsArabia.ae", "Sky News 阿拉伯"),
    ("BloombergTV.us", "彭博财经"),
    ("CNBC.us", "CNBC"),
    ("TV5MondeAsia.fr", "TV5Monde 亚洲"),
    ("DWEnglish.de", "德国之声"),
    ("France24English.fr", "法国 24"),
    ("CNA.sg", "亚洲新闻台"),
]

QUALITY_RANK = {"2160p": 4, "1440p": 3, "1080p": 3, "720p": 2, "576p": 1, "480p": 1, "360p": 0}
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"


# --------------------------------------------------------------------------- #
# 下载
# --------------------------------------------------------------------------- #
def _download(url: str, out_path: str, retries: int = 8) -> None:
    """分块下载（Range + 续传）。该网络下一次性 8MB 请求几乎必断。"""
    part = out_path + ".part"
    pos = os.path.getsize(part) if os.path.exists(part) else 0
    for attempt in range(retries):
        try:
            req = urllib.request.Request(
                url, headers={"Range": "bytes=%d-" % pos, "User-Agent": USER_AGENT}
            )
            with urllib.request.urlopen(req, timeout=60) as resp:
                if resp.status == 200:
                    pos = 0
                    mode = "wb"
                else:
                    mode = "ab"
                with open(part, mode) as fh:
                    while True:
                        block = resp.read(65536)
                        if not block:
                            break
                        fh.write(block)
                        pos += len(block)
            # 用一次探测性 Range 请求判断是否已经到文件末尾
            probe = urllib.request.Request(
                url, headers={"Range": "bytes=%d-" % pos, "User-Agent": USER_AGENT}
            )
            try:
                with urllib.request.urlopen(probe, timeout=60) as resp:
                    tail = resp.read()
                if not tail:
                    break
                with open(part, "ab") as fh:
                    fh.write(tail)
                pos += len(tail)
            except urllib.error.HTTPError as err:
                if err.code == 416:  # Range 不满足 => 已完整
                    break
                raise
        except Exception as exc:  # noqa: BLE001 - 网络问题统一重试
            print("  下载重试 %d/%d: %s" % (attempt + 1, retries, exc), flush=True)
            time.sleep(1.5)
    else:
        raise RuntimeError("下载失败: %s" % url)
    os.replace(part, out_path)


def load_api(name: str, refresh: bool) -> list:
    """读取 API JSON，优先使用 tools/.cache 中的新鲜缓存。"""
    os.makedirs(CACHE_DIR, exist_ok=True)
    cache_path = os.path.join(CACHE_DIR, name)
    fresh = (
        os.path.exists(cache_path)
        and not refresh
        and (time.time() - os.path.getmtime(cache_path)) < CACHE_TTL
    )
    if fresh:
        print("  缓存命中 %s (%.1f MB)" % (name, os.path.getsize(cache_path) / 1e6), flush=True)
    else:
        url = "%s/%s" % (API_BASE, name)
        print("  下载 %s ..." % url, flush=True)
        started = time.time()
        _download(url, cache_path)
        print("  完成 %.1f MB / %.1fs" % (os.path.getsize(cache_path) / 1e6, time.time() - started), flush=True)
    with open(cache_path, "r", encoding="utf-8") as fh:
        return json.load(fh)


# --------------------------------------------------------------------------- #
# 名称与分组
# --------------------------------------------------------------------------- #
def pick_display_name(channel: dict) -> tuple[str, str]:
    """返回 (中文优先的展示名, 原始英文名)。"""
    original = (channel.get("name") or "").strip()
    alts = [a.strip() for a in (channel.get("alt_names") or []) if a and a.strip()]
    if original in NAME_OVERRIDE:
        return NAME_OVERRIDE[original], original
    chinese = [a for a in alts if CJK_RE.search(a)]
    if chinese:
        return normalize_name(chinese[0]), original
    return localize_name(original), original


def localize_name(name: str) -> str:
    """把常见英文台名翻成本地化中文，翻不出来就原样返回。"""
    if not name:
        return name
    if CJK_RE.search(name):
        return normalize_name(name)

    # "Guangdong Satellite TV" → "广东卫视"
    match = re.match(r"^(.+?)\s+Satellite\s+(?:TV|Channel)$", name, re.IGNORECASE)
    if match and match.group(1) in PROVINCE_ZH:
        return PROVINCE_ZH[match.group(1)] + "卫视"

    # "Hunan TV" → "湖南电视台"；"Xinjiang TV 2" → "新疆电视台 2"
    match = re.match(r"^(.+?)\s+TV\s*(\d+)?$", name, re.IGNORECASE)
    if match and match.group(1) in PROVINCE_ZH:
        suffix = match.group(2) or ""
        return normalize_name(PROVINCE_ZH[match.group(1)] + "电视台" + suffix)

    tokens: list[str] = []
    for token in re.split(r"\s+", name):
        cleaned = token.strip("()（）,")
        if cleaned in PROVINCE_ZH:
            tokens.append(PROVINCE_ZH[cleaned])
            continue
        mapped = WORD_ZH.get(cleaned)
        if mapped:
            tokens.append(mapped)
            continue
        # 未收录的词：保留原文（后续与中文相邻时会自动补空格规则）
        tokens.append(cleaned)
    result = "".join(tokens)
    # 纯中文之间去掉多余空格，中英混合时保留一个空格
    result = re.sub(r"(?<=[\u4e00-\u9fff])\s+(?=[\u4e00-\u9fff])", "", result)
    return normalize_name(result or name)



def normalize_name(text: str) -> str:
    text = re.sub(r"\s+", " ", text.replace("\u3000", " ")).strip()
    if len(text) > 22:  # 过长名字截断，OSD 才放得下
        text = text[:21].rstrip() + "…"
    return text


def classify(channel: dict) -> str:
    """返回分组名：央视 / 卫视 / 地方 / 港澳台 / 国际。"""
    cid = channel.get("id") or ""
    country = (channel.get("country") or "").upper()
    name = channel.get("name") or ""
    alts = " ".join(channel.get("alt_names") or [])
    if cid.startswith("CGTN"):
        return "国际"
    if country == "CN":
        if cid.startswith("CCTV"):
            return "央视"
        if "卫视" in alts or "Satellite TV" in name or "Dragon TV" in name:
            return "卫视"
        return "地方"
    if country in ("HK", "MO", "TW"):
        return "港澳台"
    return "国际"


def satellite_order_key(name: str) -> tuple:
    for keyword, order in SATELLITE_ORDER:
        if keyword in name:
            return (order, name)
    return (999, name)


def quality_rank(quality: str | None) -> int:
    if not quality:
        return 0
    return QUALITY_RANK.get(quality.lower(), 0)


# --------------------------------------------------------------------------- #
# 探测
# --------------------------------------------------------------------------- #
def _resolve_url(url: str, headers: dict, timeout: float) -> bytes:
    """跟随后端 302/301 的 GET，返回 m3u8 正文（最多 64KB）。

    urllib 的 default opener 本身会跟随重定向，但某些 302 会先返回 3xx + 空 body，
    这里显式再取一次 Location，避免「只取一次响应就误判死源」。
    """
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read(65536)
        if body:
            return body
        location = resp.headers.get("Location")
        final = resp.geturl()
    target = location or final
    if not target or target == url:
        return b""
    req = urllib.request.Request(target, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read(65536)


def first_segment_url(playlist: str, base_url: str) -> str:
    """从 m3u8 里取第一个真正的媒体分片地址（跳过 #EXT-X-STREAM-INF 的主列表）。"""
    lines = [line.strip() for line in playlist.splitlines()]
    if any(line.startswith("#EXT-X-STREAM-INF") for line in lines):
        # 主播放列表：取第一条变体地址，再递归不了就返回它本身让上层判死
        for index, line in enumerate(lines):
            if line.startswith("#EXT-X-STREAM-INF"):
                for follow in lines[index + 1:]:
                    if follow and not follow.startswith("#"):
                        return urllib.parse.urljoin(base_url, follow)
        return ""
    for line in lines:
        if line and not line.startswith("#"):
            return urllib.parse.urljoin(base_url, line)
    return ""


def probe_stream(stream: dict, min_segment_bytes: int = 50 * 1024) -> bool:
    """判定流是否真的能播：跟 302 → m3u8 里有 #EXTINF → 首分段能取到 >50KB 字节。

    只看 `#EXTM3U` 会把「空列表」（只有 #EXTM3U 没有分段）和 302 空响应误判成活源，
    CCTV-6 那批 GITV 源就是这样：`G_CCTV-6` 是空列表，只有 `-AVS-4K264` 有分段。
    """
    url = stream.get("url") or ""
    if not url.lower().startswith(("http://", "https://")):
        return False
    headers = {"User-Agent": stream.get("user_agent") or USER_AGENT}
    if stream.get("referrer"):
        headers["Referer"] = stream["referrer"]
    try:
        playlist = _resolve_url(url, headers, 10).decode("utf-8", "ignore")
    except Exception:  # noqa: BLE001 - 探测失败即视为不可用
        return False
    if "#EXTINF" not in playlist:
        return False
    segment = first_segment_url(playlist, url)
    if not segment:
        return False
    try:
        req = urllib.request.Request(segment, headers=headers)
        with urllib.request.urlopen(req, timeout=10) as resp:
            got = 0
            while got < min_segment_bytes:
                block = resp.read(64 * 1024)
                if not block:
                    break
                got += len(block)
        return got >= min_segment_bytes
    except Exception:  # noqa: BLE001
        return False


# --------------------------------------------------------------------------- #
# 台标 · 一级源 fanmingming/live（jsDelivr）
# --------------------------------------------------------------------------- #
def _fm_normalize(text: str) -> str:
    """归一化频道名用于匹配：去空格/连字符/间隔号/引号/与号/点，转大写。

    注意 **保留 `+`**：仓库里同时有 `CCTV5.png` 和 `CCTV5+.png`，
    如果把 `+` 也去掉，两者会撞成同一个键，CCTV-5 可能套上 CCTV-5+ 的台标。
    """
    drop = set(" -_·'’&.()（）/")
    return "".join(character for character in text.upper() if character not in drop)


def load_fm_logo_names(refresh: bool = False) -> list[str]:
    """仓库 tv/ 目录下的图片文件名（含扩展名，大小写原样）。取不到就返回空。"""
    os.makedirs(CACHE_DIR, exist_ok=True)
    fresh = (
        os.path.exists(FM_TREE_CACHE)
        and not refresh
        and (time.time() - os.path.getmtime(FM_TREE_CACHE)) < FM_TREE_TTL
    )
    payload = None
    if fresh:
        try:
            with open(FM_TREE_CACHE, "r", encoding="utf-8") as handle:
                payload = json.load(handle)
        except (OSError, ValueError):
            payload = None
    if payload is None:
        # 本机网络常在读大 JSON 时被掐断（IncompleteRead），这里分块读 + 重试 3 次
        for attempt in range(3):
            try:
                request = urllib.request.Request(FM_TREE_URL, headers={"User-Agent": USER_AGENT})
                with urllib.request.urlopen(request, timeout=30) as response:
                    raw = _read_with_deadline(response, 16 * 1024 * 1024, time.time() + 45)
                if raw:
                    payload = json.loads(raw.decode("utf-8", "ignore"))
                    break
            except Exception as exc:  # noqa: BLE001
                if attempt == 2:
                    print("  !! 台标源文件树获取失败（降级到 iptv-org 台标）：%s" % exc, flush=True)
                else:
                    time.sleep(2)
        if payload is None:
            return []
        try:
            with open(FM_TREE_CACHE, "w", encoding="utf-8") as handle:
                json.dump(payload, handle)
        except OSError:
            pass

    names = []
    for entry in payload.get("tree") or []:
        path = entry.get("path") or ""
        if not path.startswith("tv/"):
            continue
        if not path.lower().endswith((".png", ".jpg", ".jpeg")):
            continue
        names.append(path[3:])
    return names


def build_fm_index(names: list[str]) -> dict[str, str]:
    """归一化名 -> 真实文件名（大小写敏感地保留原名）。

    只收可解码的图片扩展名：仓库里还有 `README.md` 之类的非图片文件，
    混进来会被拼成台标 URL 再 404。
    """
    index: dict[str, str] = {}
    for filename in names:
        stem, _, extension = filename.rpartition(".")
        if not stem or extension.lower() not in IMAGE_FORMATS:
            continue
        key = _fm_normalize(stem)
        if key and key not in index:
            index[key] = filename
    return index


def fm_candidate_names(item: dict, index: dict[str, str]) -> list[str]:
    """给一个频道列出候选台标文件名（按优先级，只返回仓库里真实存在的）。"""
    display = (item.get("name") or "").strip()
    subname = (item.get("subname") or "").strip()
    keys: list[str] = []

    def push(key: str) -> None:
        if key and key not in keys:
            keys.append(key)

    upper_sub = subname.upper()
    upper_name = display.upper()
    cctv_source = None
    if upper_sub.startswith("CCTV"):
        cctv_source = subname
    elif upper_name.startswith("CCTV"):
        cctv_source = display
    if cctv_source:
        compact = _fm_normalize(cctv_source)
        # CCTV-4 有亚洲/欧洲/美洲分版，仓库文件名用中文后缀
        regional = {
            "CCTV4ASIA": "CCTV4",
            "CCTV4EUROPE": "CCTV4欧洲",
            "CCTV4AMERICA": "CCTV4美洲",
            "CCTV4AMERICAS": "CCTV4美洲",
        }
        if compact in regional:
            push(regional[compact])
        push(compact)
        match = re.match(r"CCTV(\d+)", compact)
        if match:
            push("CCTV%d" % int(match.group(1)))
        for token in ("4K", "8K", "3D"):
            if token in compact:
                push("CCTV" + token)
        # CCTV-世界地理 这类付费频道在仓库里不带 CCTV 前缀（用中文名去推，英文原名推不出来）
        for source in (display, subname):
            compact_source = _fm_normalize(source)
            if not compact_source.startswith("CCTV"):
                continue
            tail = compact_source[4:].lstrip("0123456789")
            if len(tail) >= 2:
                push(tail)
                if tail.startswith("央视"):
                    push(tail[2:])

    for base in (display, subname):
        if base:
            push(_fm_normalize(base))

    # 名称是「XX卫视」缺失或用了「XX卫视频道」写法时，用英文原名里的省份兜底
    province = _province_from_text(display + " " + subname)
    if province:
        push(_fm_normalize(province + "卫视"))

    resolved: list[str] = []
    for key in keys:
        filename = index.get(key)
        if filename and filename not in resolved:
            resolved.append(filename)
    return resolved


def _province_from_text(text: str) -> str:
    """「Ningxia Satellite Channel」→「宁夏」。"""
    for english, chinese in PROVINCE_ZH.items():
        if english.lower() in text.lower():
            return chinese
    return ""


def download_fm_logo(filename: str, dest: str) -> bool:
    """按 jsDelivr 镜像顺序下载一张台标；跟随 301/302，失败重试 3 次间隔 2s。

    本地 `tools/.cache/logos-fm/` 有缓存就直接用缓存（避免反复重烘焙时重复抓）。
    """
    cache_path = os.path.join(FM_LOGO_CACHE, filename)
    data = None
    if os.path.exists(cache_path) and os.path.getsize(cache_path) > 0:
        try:
            with open(cache_path, "rb") as handle:
                cached = handle.read()
            if _looks_like_image(cached):
                data = cached
        except OSError:
            data = None

    if data is None:
        os.makedirs(FM_LOGO_CACHE, exist_ok=True)
        for base in FM_LOGO_BASES:
            url = base + urllib.parse.quote(filename)
            for attempt in range(FM_RETRIES):
                try:
                    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
                    # urllib 默认跟随 301/302；jsDelivr 首次请求常给 301
                    with urllib.request.urlopen(request, timeout=8) as response:
                        body = response.read(FM_LOGO_MAX_BYTES + 1)
                    if _looks_like_image(body) and len(body) <= FM_LOGO_MAX_BYTES:
                        data = body
                        break
                except Exception:  # noqa: BLE001 - 单张失败不影响整体
                    pass
                if attempt + 1 < FM_RETRIES:
                    time.sleep(FM_RETRY_GAP)
            if data is not None:
                break
        if data is None:
            return False
        try:
            with open(cache_path, "wb") as handle:
                handle.write(data)
        except OSError:
            pass

    try:
        with open(dest, "wb") as handle:
            handle.write(data)
    except OSError:
        return False
    return True


def attach_fm_logos(items: list, index: dict[str, str], download: bool) -> dict:
    """一级台标：fanmingming/live。成功则记 logoFile + logoSource=fm。"""
    if not download or not index:
        return {"local": 0, "matched": 0, "planned": 0}

    plan = []
    for item in items:
        candidates = fm_candidate_names(item, index)
        if candidates:
            item["_fm_choice"] = candidates[0]
            plan.append((item, candidates[0]))
    if not plan:
        return {"local": 0, "matched": 0, "planned": 0}

    local = 0
    total = 0
    with futures.ThreadPoolExecutor(max_workers=4) as pool:
        pending = {}
        for item, filename in plan:
            extension = filename.rsplit(".", 1)[-1].lower()
            extension = IMAGE_FORMATS.get(extension, "png")
            dest = os.path.join(LOGOS_DIR, "%s.%s" % (item["id"], extension))
            pending[pool.submit(download_fm_logo, filename, dest)] = (item, filename, dest)
        for future in futures.as_completed(pending):
            item, filename, dest = pending[future]
            try:
                ok = future.result()
            except Exception:  # noqa: BLE001
                ok = False
            if not ok:
                continue
            try:
                size = os.path.getsize(dest)
            except OSError:
                continue
            if total + size > LOGO_TOTAL_BUDGET:
                continue
            total += size
            local += 1
            item["logoFile"] = os.path.relpath(dest, os.path.join(ROOT, "Resources"))
            item["logoSource"] = "fm"
            item["_fm_matched"] = filename
    return {"local": local, "matched": len(plan), "planned": len(plan)}


# --------------------------------------------------------------------------- #
# 台标 · 二级源 iptv-org logos.json
# --------------------------------------------------------------------------- #
def load_logo_index(logos: list) -> dict:
    """channel id -> [logo...]。"""
    index: dict = {}
    for logo in logos:
        channel_id = logo.get("channel")
        url = logo.get("url")
        if not channel_id or not url:
            continue
        index.setdefault(channel_id, []).append(logo)
    return index


def _logo_score(logo: dict) -> tuple:
    """排序键（越小越优）：in_use → 图床可达 → 可解码格式 → 分辨率面积大。"""
    host = urllib.parse.urlparse(logo.get("url") or "").hostname or ""
    image_format = (logo.get("format") or "").lower()
    area = int(logo.get("width") or 0) * int(logo.get("height") or 0)
    return (
        0 if logo.get("in_use") else 1,
        1 if host in UNREACHABLE_HOSTS else 0,
        1 if image_format not in IMAGE_FORMATS else 0,
        -area,
    )


def pick_logo(candidates: list) -> dict | None:
    """挑一个最佳台标。

    排序优先级：in_use=true → 图床可达（排除 i.imgur.com）→ 可解码格式（非 SVG）
    → 分辨率面积大。只接受 feed 为空的通用台标（区分地域 feed 的台标不通用）。
    """
    usable = [logo for logo in candidates if not logo.get("feed")]
    if not usable:
        return None
    return sorted(usable, key=_logo_score)[0]


def _logo_extension(logo: dict) -> str:
    image_format = (logo.get("format") or "").lower()
    if image_format in IMAGE_FORMATS:
        return IMAGE_FORMATS[image_format]
    path = urllib.parse.urlparse(logo.get("url") or "").path.lower()
    for extension in ("png", "jpg", "jpeg", "gif", "webp"):
        if path.endswith("." + extension):
            return IMAGE_FORMATS.get(extension, "png")
    return ""


def _looks_like_image(data: bytes) -> bool:
    """按魔数判断是不是真图片。

    必须校验：很多站点（如 www.tvchinese.net）对任意路径都返回 200 + HTML 兜底页，
    只看状态码会把 HTML 存成 .png，App 里则变成「有台标文件但解码不出来」。
    """
    if not data or len(data) < 64:
        return False
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return True
    if data.startswith(b"\xff\xd8\xff"):
        return True
    if data[:6] in (b"GIF87a", b"GIF89a"):
        return True
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return True
    return False


def _read_with_deadline(response, limit: int, deadline: float) -> bytes | None:
    """读满 limit 字节或超时；返回 None 表示超时。"""
    buffer = bytearray()
    while len(buffer) <= limit:
        if time.time() > deadline:
            return None
        block = response.read(16384)
        if not block:
            break
        buffer.extend(block)
    return bytes(buffer)


def download_logo(url: str, dest: str, deadline_seconds: float = 8.0) -> bool:
    """下载单张台标：整体耗时上限 deadline_seconds、超过 200KB 丢弃、非图片丢弃。

    失败返回 False，不抛错（台标只是锦上添花，不能影响烘焙主流程）。
    已存在且非空的 dest 直接视为成功，方便中断后续跑。
    """
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        try:
            with open(dest, "rb") as handle:
                if _looks_like_image(handle.read(64)):
                    return True
        except OSError:
            pass
        try:
            os.remove(dest)
        except OSError:
            pass

    deadline = time.time() + deadline_seconds
    try:
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(request, timeout=min(8.0, deadline_seconds)) as response:
            data = _read_with_deadline(response, MAX_LOGO_BYTES, deadline)
    except Exception:  # noqa: BLE001 - 台标缺失不影响可用性
        return False
    if data is None or not _looks_like_image(data):
        return False
    try:
        with open(dest, "wb") as handle:
            handle.write(data)
    except OSError:
        return False
    return True


def logo_candidates(candidates: list, limit: int = 4) -> list:
    """按 pick_logo 的排序返回前 limit 个可下载候选（用于逐个兜底尝试）。"""
    usable = [logo for logo in candidates if not logo.get("feed")]
    if not usable:
        return []
    ordered = sorted(usable, key=_logo_score)
    return [logo for logo in ordered if _logo_extension(logo)][:limit]


def attach_logos(items: list, logo_index: dict, download: bool,
                 fm_index: dict[str, str] | None = None) -> dict:
    """给每个频道挑台标，三级优先级：

      1. fanmingming/live（`logoSource = "fm"`）
      2. iptv-org logos.json 里**可下载**的候选（`logoSource = "iptv-org"`）
      3. 都没有：只记 `logoURL`（imgur 等不可达图床仅记录，供别的网络兜底），
         App 端落到文字徽标

    下载时并发抓字节到 `Resources/logos/<id>.<ext>`，一个频道的多个候选逐个试。
    """
    if download:
        os.makedirs(LOGOS_DIR, exist_ok=True)

    # 一级：fanmingming/live
    fm_stats = attach_fm_logos(items, fm_index or {}, download)

    # 二级：iptv-org
    plan = []
    for item in items:
        ordered = logo_candidates(logo_index.get(item["id"], []))
        item["logoURL"] = (ordered[0].get("url") or "") if ordered else ""
        item.setdefault("logoFile", None)
        item.setdefault("logoSource", None)
        if item["logoFile"] or not download or not ordered:
            continue
        plan.append((item, ordered))

    local = 0
    total = 0
    attempts = 0
    keep: set[str] = set()
    for item in items:
        if item.get("logoFile"):
            keep.add(os.path.basename(item["logoFile"]))
    if plan:
        with futures.ThreadPoolExecutor(max_workers=8) as pool:
            # 每个频道先试首选，失败再试下一个候选；用 futures.wait 逐个推进。
            pending = {}
            for item, ordered in plan:
                attempts += 1
                extension = _logo_extension(ordered[0])
                dest = os.path.join(LOGOS_DIR, "%s.%s" % (item["id"], extension))
                pending[pool.submit(download_logo, ordered[0]["url"], dest)] = (item, ordered, 0, dest, extension)

            while pending:
                done, _ = futures.wait(list(pending), return_when=futures.FIRST_COMPLETED)
                for future in done:
                    item, ordered, index, dest, extension = pending.pop(future)
                    try:
                        ok = future.result()
                    except Exception:  # noqa: BLE001
                        ok = False
                    if ok:
                        size = os.path.getsize(dest)
                        if total + size > LOGO_TOTAL_BUDGET:
                            os.remove(dest)
                            continue
                        total += size
                        local += 1
                        item["logoFile"] = "logos/%s.%s" % (item["id"], extension)
                        item["logoSource"] = "iptv-org"
                        item["logoURL"] = ordered[index]["url"]
                        keep.add("%s.%s" % (item["id"], extension))
                        continue
                    next_index = index + 1
                    if next_index >= len(ordered):
                        continue
                    attempts += 1
                    extension = _logo_extension(ordered[next_index])
                    dest = os.path.join(LOGOS_DIR, "%s.%s" % (item["id"], extension))
                    pending[pool.submit(download_logo, ordered[next_index]["url"], dest)] = (
                        item, ordered, next_index, dest, extension
                    )

    stale = 0
    if download:
        # 本轮没引用到的旧台标（比如换了图床、扩展名从 .jpg 变 .png）。
        # 注意：宿主对「单轮批量删除」有配额保护（>50 个文件会被整体拒绝），
        # 这里只在残留很少时顺手清理，否则原样留着——不被 catalog 引用的文件
        # 对 App 没有影响，只是多占一点包体积。
        orphans = [name for name in os.listdir(LOGOS_DIR) if name not in keep]
        stale = len(orphans)
        if stale <= 10:
            for name in orphans:
                try:
                    os.remove(os.path.join(LOGOS_DIR, name))
                except OSError:
                    pass
            stale = 0

    return {
        "local": sum(1 for item in items if item.get("logoFile")),
        "fm": fm_stats["local"],
        "iptvOrg": local,
        "remote": sum(1 for item in items if item["logoURL"]),
        "none": sum(1 for item in items if not item["logoURL"]),
        "bytes": total,
        "planned": len(plan),
        "attempts": attempts,
        "fmMatched": fm_stats["matched"],
        "stale": stale,
    }


# --------------------------------------------------------------------------- #
# 人工补源（tools/source-overrides.json）
# --------------------------------------------------------------------------- #
def load_overrides(path: str | None = None) -> dict[str, list[dict]]:
    """读取人工补源表：channel id -> [stream...]。

    文件缺失/损坏都只是「没有补源」，绝不能让烘焙失败。
    """
    target = path or OVERRIDES_PATH
    if not os.path.exists(target):
        return {}
    try:
        with open(target, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, ValueError) as exc:
        print("  !! 补源文件读取失败（忽略）：%s" % exc, flush=True)
        return {}

    result: dict[str, list[dict]] = {}
    for channel_id, entries in (payload.get("channels") or {}).items():
        if not channel_id or not isinstance(entries, list):
            continue
        normalized = []
        for entry in entries:
            url = (entry or {}).get("url") or ""
            if not url.lower().startswith(("http://", "https://")):
                continue
            normalized.append(
                {
                    "url": url,
                    "quality": entry.get("quality") or "",
                    "userAgent": entry.get("userAgent") or entry.get("user_agent") or "",
                    "referrer": entry.get("referrer") or "",
                    "isAlive": False,
                    "origin": "curated",
                }
            )
        if normalized:
            result[channel_id] = normalized
    return result


def merge_stream_order(builtin: list[dict], curated: list[dict]) -> list[dict]:
    """合并内置源与人工补源。

    规则：内置存活流优先，补源插在其后；只有内置一条活的都没有时，补源才提到最前。
    这样 CCTV-6（内置源全死）立刻能看，而 CCTV-1/2/3 这类本来能播的台不会被
    18~24Mbps 的 4K 源顶到前面去（4K 源在弱网下更容易卡）。
    """
    alive_builtin = [s for s in builtin if s.get("isAlive")]
    dead_builtin = [s for s in builtin if not s.get("isAlive")]
    alive_curated = [s for s in curated if s.get("isAlive")]
    dead_curated = [s for s in curated if not s.get("isAlive")]
    if alive_builtin:
        return alive_builtin + alive_curated + dead_builtin + dead_curated
    return alive_curated + dead_builtin + dead_curated


# --------------------------------------------------------------------------- #
# 主流程
# --------------------------------------------------------------------------- #
def build(refresh: bool, probe: bool, region_filter: list[str], with_logos: bool = True) -> dict:
    print("[1/5] 拉取 iptv-org 索引", flush=True)
    streams = load_api("streams.json", refresh)
    channels = load_api("channels.json", refresh)
    logos = load_api("logos.json", refresh) if with_logos else []
    overrides = load_overrides()
    print("  streams=%d channels=%d logos=%d 补源频道=%d"
          % (len(streams), len(channels), len(logos), len(overrides)), flush=True)
    logo_index = load_logo_index(logos) if logos else {}

    channel_by_id = {c["id"]: c for c in channels if c.get("id")}

    # 按频道聚合流
    grouped: dict[str, list[dict]] = {}
    for stream in streams:
        cid = stream.get("channel")
        if not cid or cid not in channel_by_id:
            continue
        url = stream.get("url") or ""
        if not url.lower().startswith(("http://", "https://")):
            continue
        grouped.setdefault(cid, []).append(stream)

    print("[2/5] 归类分组", flush=True)
    wanted_regions = {r.upper() for r in region_filter}
    curated_order = {cid: idx for idx, (cid, _) in enumerate(INTERNATIONAL_CURATED)}
    curated_names = dict(INTERNATIONAL_CURATED)

    buckets: dict[str, list[dict]] = {"央视": [], "卫视": [], "地方": [], "港澳台": [], "国际": []}
    # 内置源与补源都要处理：某频道可能只有补源（内置全死/缺失），也必须在目录里出现。
    candidate_ids = set(grouped) | set(overrides)
    for cid in candidate_ids:
        channel = channel_by_id.get(cid)
        if not channel:
            continue
        entries = grouped.get(cid, [])
        country = (channel.get("country") or "").upper()
        if country in ("CN", "HK", "MO", "TW"):
            pass  # 中文区全收
        elif cid not in curated_order:
            # 其它国家只在显式指定时才收录
            if country not in wanted_regions:
                continue
        display, original = pick_display_name(channel)
        group = classify(channel)
        if group == "国际" and cid in curated_names:
            display = curated_names[cid]
        entries_sorted = sorted(
            entries, key=lambda s: (-quality_rank(s.get("quality")), (s.get("url") or ""))
        )
        buckets[group].append(
            {
                "id": cid,
                "name": display,
                "subname": original,
                "group": group,
                "number": 0,
                "logoURL": channel.get("logo") or "",
                "website": channel.get("website") or "",
                "country": country,
                "categories": channel.get("categories") or [],
                "streams": [
                    {
                        "url": s.get("url"),
                        "quality": s.get("quality") or "",
                        "userAgent": s.get("user_agent") or "",
                        "referrer": s.get("referrer") or "",
                        "isAlive": False,
                        "origin": "iptv-org",
                    }
                    for s in entries_sorted
                ],
                "_curated_streams": overrides.get(cid, []),
                "_curated": curated_order.get(cid, 9999),
            }
        )

    print("[3/5] 分配台号", flush=True)
    # 同名频道（不同信号源）只保留流最多的一条，避免台名重复无法分辨
    for group_name in ("地方", "港澳台"):
        best: dict[str, dict] = {}
        for item in buckets[group_name]:
            kept = best.get(item["name"])
            if kept is None or len(item["streams"]) > len(kept["streams"]):
                best[item["name"]] = item
        buckets[group_name] = list(best.values())

    # 央视 1-99：先给 CCTV-N 精确匹配分配台号，衍生频道按 base 号顺序填空号
    def cctv_key(item: dict) -> tuple:
        text = (item["subname"] or item["name"]).replace(" ", "")
        match = re.match(r"^CCTV-?(\d+)", text)
        base = int(match.group(1)) if match else 999
        exact = 0 if re.match(r"^CCTV-?\d+$", text) else 1
        return (base, exact, item["name"])

    used: set[int] = set()
    deferred: list[dict] = []
    for item in sorted(buckets["央视"], key=cctv_key):
        base, exact, _ = cctv_key(item)
        if base < 999 and exact == 0 and base not in used:
            item["number"] = base
            used.add(base)
        else:
            deferred.append(item)
    cursor = 1
    for item in deferred:
        while cursor in used:
            cursor += 1
        if cursor > 99:
            break
        item["number"] = cursor
        used.add(cursor)

    assign_range(buckets["卫视"], 100, 199,
                 key=lambda item: (satellite_order_key(item["name"]), item["name"]))
    assign_range(buckets["地方"], 200, 399, key=lambda item: item["name"])
    # 港澳台：香港 400-、澳门 430-、台湾 450-
    region_base = {"HK": 400, "MO": 430, "TW": 450}
    for region in ("HK", "MO", "TW"):
        subset = [item for item in buckets["港澳台"] if item["country"] == region]
        assign_range(subset, region_base[region], region_base[region] + 29,
                     key=lambda item: item["name"])
    buckets["国际"].sort(key=lambda item: (item["_curated"], item["name"]))
    assign_range(buckets["国际"], 500, 599, key=lambda item: (item["_curated"], item["name"]))

    ordered = []
    for group in ("央视", "卫视", "地方", "港澳台", "国际"):
        items = buckets[group]
        items.sort(key=lambda item: item["number"] or 999)
        ordered.extend(item for item in items if item["number"])

    # 补源流也参与探测（跟随 302 + 首分段校验），结果写进同一个缓存
    curated_streams = [stream for item in ordered for stream in item.get("_curated_streams", [])]

    if probe:
        print("[4/5] 探测流存活（并发 32）...", flush=True)
        cache_path = os.path.join(CACHE_DIR, "probe.json")
        cached: dict = {}
        if os.path.exists(cache_path):
            try:
                with open(cache_path, "r", encoding="utf-8") as fh:
                    payload = json.load(fh)
                if (time.time() - float(payload.get("generated_at", 0)) < 24 * 3600
                        and payload.get("version") == PROBE_VERSION):
                    cached = payload.get("alive", {})
                    print("  复用探测缓存 %d 条" % len(cached), flush=True)
            except Exception:  # noqa: BLE001 - 缓存损坏就当没有
                cached = {}

        all_streams = [stream for item in ordered for stream in item["streams"]]
        todo = [stream for stream in all_streams + curated_streams if stream["url"] not in cached]
        fresh: dict = {}
        if todo:
            with futures.ThreadPoolExecutor(max_workers=32) as pool:
                for stream, ok in zip(todo, pool.map(probe_stream, todo)):
                    fresh[stream["url"]] = bool(ok)
        for stream in all_streams + curated_streams:
            stream["isAlive"] = bool(fresh.get(stream["url"], cached.get(stream["url"], False)))

        merged = dict(cached)
        merged.update(fresh)
        with open(cache_path, "w", encoding="utf-8") as fh:
            json.dump({"generated_at": time.time(), "version": PROBE_VERSION, "alive": merged}, fh)

        alive = sum(1 for stream in all_streams if stream["isAlive"])
        curated_alive = sum(1 for stream in curated_streams if stream["isAlive"])
        print("  存活 %d/%d（新探测 %d 条）｜补源存活 %d/%d"
              % (alive, len(all_streams), len(todo), curated_alive, len(curated_streams)), flush=True)
    else:
        print("[4/5] 跳过探测（加 --probe 可标记存活）", flush=True)

    # 合并排序：内置存活优先，补源兜底；内置全死时补源提上来
    for item in ordered:
        builtin = sorted(item["streams"],
                         key=lambda s: (not s["isAlive"], -quality_rank(s["quality"]), s["url"]))
        curated = sorted(item.get("_curated_streams", []),
                         key=lambda s: (not s["isAlive"], -quality_rank(s["quality"]), s["url"]))
        if not builtin and not curated:
            item["streams"] = []
            continue
        item["streams"] = merge_stream_order(builtin, curated)

    print("[5/5] 处理台标", flush=True)
    fm_names = load_fm_logo_names(refresh)
    fm_index = build_fm_index(fm_names) if fm_names else {}
    if fm_names:
        print("  fanmingming/live 台标库 %d 张" % len(fm_names), flush=True)
    logo_stats = attach_logos(ordered, logo_index, download=with_logos, fm_index=fm_index)
    print("  内置 %d（fm %d / iptv-org %d，fm 命中候选 %d）/ 有远端兜底 %d / 完全没有 %d，台标目录 %.1f MB"
          % (logo_stats["local"], logo_stats["fm"], logo_stats["iptvOrg"], logo_stats["fmMatched"],
             logo_stats["remote"], logo_stats["none"], logo_stats["bytes"] / 1e6), flush=True)

    for item in ordered:
        item.pop("_curated", None)
        item.pop("_curated_streams", None)
        item.pop("_fm_choice", None)
        item.pop("_fm_matched", None)

    curated_total = sum(1 for item in ordered for stream in item["streams"]
                        if stream.get("origin") == "curated")
    fm_total = sum(1 for item in ordered if item.get("logoSource") == "fm")

    return {
        "version": 1,
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "source": API_BASE,
        "channelCount": len(ordered),
        "logoCount": logo_stats["local"],
        "logoSourceCounts": {
            "fm": fm_total,
            "iptvOrg": sum(1 for item in ordered if item.get("logoSource") == "iptv-org"),
            "none": sum(1 for item in ordered if not item.get("logoSource")),
        },
        "curatedStreamCount": curated_total,
        "channels": ordered,
    }


def assign_range(items: list[dict], low: int, high: int, key) -> None:
    items.sort(key=key)
    number = low
    for item in items:
        if number > high:
            break
        item["number"] = number
        number += 1


def main() -> int:
    parser = argparse.ArgumentParser(description="烘焙 TVBox 频道目录")
    parser.add_argument("--refresh", action="store_true", help="忽略缓存重新下载 API")
    parser.add_argument("--probe", action="store_true", help="并发探测流可用性")
    parser.add_argument("--region", default="", help="额外收录的国家码，逗号分隔，如 US,UK,JP")
    parser.add_argument("--skip-logos", action="store_true", help="不抓台标（只保留远端 URL）")
    parser.add_argument("--out", default=OUT_PATH, help="输出路径")
    args = parser.parse_args()

    regions = [r.strip() for r in args.region.split(",") if r.strip()]
    catalog = build(args.refresh, args.probe, regions, with_logos=not args.skip_logos)

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(catalog, fh, ensure_ascii=False, separators=(",", ":"))

    per_group: dict[str, int] = {}
    per_group_streams: dict[str, int] = {}
    for item in catalog["channels"]:
        per_group[item["group"]] = per_group.get(item["group"], 0) + 1
        per_group_streams[item["group"]] = per_group_streams.get(item["group"], 0) + len(item["streams"])
    print("\n输出 %s" % args.out)
    print("  大小 %.1f KB，频道 %d，内置台标 %d" % (os.path.getsize(args.out) / 1024,
                                                catalog["channelCount"], catalog.get("logoCount", 0)))
    for group, count in per_group.items():
        print("  %-4s %3d 个频道 / %4d 条流" % (group, count, per_group_streams[group]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
