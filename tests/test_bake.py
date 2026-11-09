#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""烘焙脚本（tools/bake_catalog.py）纯函数的单测。

重点覆盖台标挑选顺序：
  in_use=true → 图床可达（i.imgur.com 排最后）→ 可解码格式（非 SVG）→ 面积大
以及：候选逐个兜底、图片魔数校验（防止把 HTML 兜底页当台标存下来）、
文件扩展名推断、attach_logos 在不下载时的字段行为。
"""

import importlib.util
import json
import os
import shutil
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "tools", "bake_catalog.py")

spec = importlib.util.spec_from_file_location("bake_catalog", SCRIPT)
assert spec is not None and spec.loader is not None
bake = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bake)


def logo(url, image_format="png", width=100, height=100, in_use=True, feed=None, channel="X.cn"):
    return {
        "channel": channel,
        "url": url,
        "format": image_format,
        "width": width,
        "height": height,
        "in_use": in_use,
        "feed": feed,
    }


PNG_HEADER = b"\x89PNG\r\n\x1a\n" + b"\x00" * 128
JPEG_HEADER = b"\xff\xd8\xff\xe0" + b"\x00" * 128
GIF_HEADER = b"GIF89a" + b"\x00" * 128
WEBP_HEADER = b"RIFF\x00\x00\x00\x00WEBPVP8 " + b"\x00" * 128
HTML_PAGE = b"<!Doctype html><html><head><title>tvchinese</title></head></html>" + b"\x00" * 32


class PickLogoTest(unittest.TestCase):
    def test_prefers_in_use(self):
        candidates = [
            logo("https://a.example/1.png", in_use=False),
            logo("https://b.example/2.png", in_use=True),
        ]
        self.assertEqual(bake.pick_logo(candidates)["url"], "https://b.example/2.png")

    def test_imgur_sorted_last(self):
        candidates = [
            logo("https://i.imgur.com/big.png", width=2000, height=2000),
            logo("https://www.tvchinese.net/small.png", width=32, height=32),
        ]
        # 可达性优先于分辨率
        self.assertEqual(bake.pick_logo(candidates)["url"], "https://www.tvchinese.net/small.png")

    def test_imgur_still_returns_when_only_option(self):
        candidates = [logo("https://i.imgur.com/only.png")]
        picked = bake.pick_logo(candidates)
        self.assertIsNotNone(picked, "只有不可达图床时仍要记录兜底 URL")
        self.assertEqual(picked["url"], "https://i.imgur.com/only.png")

    def test_feed_specific_logos_are_ignored(self):
        candidates = [logo("https://a.example/hd.png", feed="HD")]
        self.assertIsNone(bake.pick_logo(candidates), "带 feed 的地域台标不通用，应跳过")

    def test_prefers_decodable_format(self):
        candidates = [
            logo("https://a.example/vec.svg", image_format="SVG", width=1000, height=1000),
            logo("https://a.example/tiny.png", image_format="PNG", width=16, height=16),
        ]
        self.assertEqual(bake.pick_logo(candidates)["url"], "https://a.example/tiny.png")

    def test_area_tie_break(self):
        candidates = [
            logo("https://a.example/small.png", width=64, height=64),
            logo("https://a.example/big.png", width=512, height=512),
        ]
        self.assertEqual(bake.pick_logo(candidates)["url"], "https://a.example/big.png")

    def test_empty_candidates(self):
        self.assertIsNone(bake.pick_logo([]))


class LogoExtensionTest(unittest.TestCase):
    def test_from_format_field(self):
        self.assertEqual(bake._logo_extension({"format": "PNG", "url": "https://a/x"}), "png")
        self.assertEqual(bake._logo_extension({"format": "jpeg", "url": "https://a/x"}), "jpg")
        self.assertEqual(bake._logo_extension({"format": "webp", "url": "https://a/x"}), "webp")

    def test_from_url_suffix(self):
        self.assertEqual(bake._logo_extension({"format": None, "url": "https://a/x.jpeg"}), "jpg")
        self.assertEqual(bake._logo_extension({"format": "", "url": "https://a/x.gif"}), "gif")

    def test_unknown(self):
        self.assertEqual(bake._logo_extension({"format": "SVG", "url": "https://a/x.svg"}), "")


class AttachLogosTest(unittest.TestCase):
    def test_sets_url_and_keeps_file_without_download(self):
        items = [{"id": "A.cn", "logoURL": ""}]
        index = {"A.cn": [logo("https://a.example/x.png")]}
        stats = bake.attach_logos(items, index, download=False)
        self.assertEqual(items[0]["logoURL"], "https://a.example/x.png")
        # download=False（--skip-logos）表示「只更新 URL，不动已抓好的本地台标」，
        # 否则每次跳过下载都会把上一轮抓好的 logoFile 清掉。
        self.assertIsNone(items[0].get("logoFile"), "没有本地台标时保持 None")
        self.assertEqual(stats["local"], 0)
        self.assertEqual(stats["remote"], 1)

    def test_keeps_existing_logo_file_without_download(self):
        items = [{"id": "A.cn", "logoURL": "", "logoFile": "logos/A.cn.png"}]
        index = {"A.cn": [logo("https://a.example/x.png")]}
        bake.attach_logos(items, index, download=False)
        self.assertEqual(items[0]["logoFile"], "logos/A.cn.png",
                         "跳下载时必须保留上一轮的本地台标")

    def test_missing_logo(self):
        items = [{"id": "B.cn", "logoURL": "old", "logoFile": None}]
        stats = bake.attach_logos(items, {}, download=False)
        self.assertEqual(items[0]["logoURL"], "")
        self.assertIsNone(items[0]["logoFile"])
        self.assertEqual(stats["none"], 1)

    def test_logo_index_groups_by_channel(self):
        index = bake.load_logo_index([
            logo("https://a/1.png", channel="A.cn"),
            logo("https://a/2.png", channel="A.cn"),
            logo("https://a/3.png", channel="B.cn"),
            {"channel": None, "url": "https://a/4.png"},
            {"channel": "C.cn", "url": None},
        ])
        self.assertEqual(len(index["A.cn"]), 2)
        self.assertEqual(len(index["B.cn"]), 1)
        self.assertNotIn("C.cn", index)


class OverridesTest(unittest.TestCase):
    """人工补源：读取、origin 标记、合并排序（不许把能播的内置源顶掉）。"""

    def setUp(self):
        self.directory = tempfile.mkdtemp(prefix="tvbox-overrides-")

    def tearDown(self):
        shutil.rmtree(self.directory, ignore_errors=True)

    def _write(self, payload):
        path = os.path.join(self.directory, "source-overrides.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(payload, handle)
        return path

    def test_loads_and_marks_origin(self):
        path = self._write({"version": 1, "channels": {
            "CCTV6.cn": [{"url": "http://h/live.m3u8", "quality": "2160p"}],
            "BROKEN.cn": [{"url": "ftp://x/y"}],
        }})
        overrides = bake.load_overrides(path)
        self.assertIn("CCTV6.cn", overrides)
        self.assertEqual(overrides["CCTV6.cn"][0]["origin"], "curated", "补源要标 origin=curated")
        self.assertEqual(overrides["CCTV6.cn"][0]["quality"], "2160p")
        self.assertNotIn("BROKEN.cn", overrides, "非 http(s) 的补源要被丢掉")

    def test_missing_file_is_empty(self):
        self.assertEqual(bake.load_overrides(os.path.join(self.directory, "nope.json")), {},
                         "补源文件缺失不能让烘焙失败")

    def test_broken_json_is_empty(self):
        path = os.path.join(self.directory, "bad.json")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("{不是 json")
        self.assertEqual(bake.load_overrides(path), {}, "补源文件损坏也不能让烘焙失败")

    def test_builtin_alive_keeps_priority(self):
        builtin = [{"url": "builtin-alive", "isAlive": True},
                   {"url": "builtin-dead", "isAlive": False}]
        curated = [{"url": "curated-alive", "isAlive": True}]
        merged = [stream["url"] for stream in bake.merge_stream_order(builtin, curated)]
        self.assertEqual(merged[0], "builtin-alive", "内置有活源时补源不能顶到第一位")
        self.assertEqual(merged, ["builtin-alive", "curated-alive", "builtin-dead"])

    def test_curated_first_when_builtin_all_dead(self):
        builtin = [{"url": "builtin-dead-1", "isAlive": False},
                   {"url": "builtin-dead-2", "isAlive": False}]
        curated = [{"url": "curated-alive", "isAlive": True}]
        merged = [stream["url"] for stream in bake.merge_stream_order(builtin, curated)]
        self.assertEqual(merged[0], "curated-alive", "内置源全死时补源必须排第一（CCTV-6 场景）")

    def test_only_curated(self):
        merged = bake.merge_stream_order([], [{"url": "curated", "isAlive": True}])
        self.assertEqual([stream["url"] for stream in merged], ["curated"])


class ProbeStreamTest(unittest.TestCase):
    """探测：必须跟随 302、必须真的取到分段字节，空列表要判死。"""

    def setUp(self):
        self.original_resolve = bake._resolve_url
        self.original_urlopen = bake.urllib.request.urlopen

    def tearDown(self):
        bake._resolve_url = self.original_resolve
        bake.urllib.request.urlopen = self.original_urlopen

    def test_empty_playlist_is_dead(self):
        bake._resolve_url = lambda url, headers, timeout: b"#EXTM3U\n"
        self.assertFalse(bake.probe_stream({"url": "http://h/a/index.m3u8"}),
                         "只有 #EXTM3U 没有分段 = 空列表，必须判死")

    def test_playlist_without_extinf_is_dead(self):
        bake._resolve_url = lambda url, headers, timeout: b"#EXTM3U\n#EXT-X-VERSION:3\n"
        self.assertFalse(bake.probe_stream({"url": "http://h/a/index.m3u8"}))

    def test_segment_too_small_is_dead(self):
        bake._resolve_url = lambda url, headers, timeout: b"#EXTM3U\n#EXTINF:10,\nseg.ts\n"
        bake.urllib.request.urlopen = lambda request, timeout=None: FakeResponse(b"x" * 1024)
        self.assertFalse(bake.probe_stream({"url": "http://h/a/index.m3u8"}),
                         "首分段不到 50KB 视为不可播")

    def test_segment_big_enough_is_alive(self):
        bake._resolve_url = lambda url, headers, timeout: b"#EXTM3U\n#EXTINF:10,\nseg.ts\n"
        bake.urllib.request.urlopen = lambda request, timeout=None: FakeResponse(b"x" * (60 * 1024))
        self.assertTrue(bake.probe_stream({"url": "http://h/a/index.m3u8"}))

    def test_follows_302_redirect(self):
        """第一次响应 302 空 body + Location，必须跟到最终地址才算数。"""
        calls = []

        class RedirectResponse:
            def __init__(self):
                self.headers = {"Location": "http://final/index.m3u8"}
                self.status = 302

            def read(self, size=-1):
                return b""

            def geturl(self):
                return "http://first/index.m3u8"

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

        def fake_urlopen(request, timeout=None):
            calls.append(request.full_url)
            if request.full_url == "http://first/index.m3u8":
                return RedirectResponse()
            return FakeResponse(b"#EXTM3U\n#EXTINF:10,\nseg.ts\n")

        bake.urllib.request.urlopen = fake_urlopen
        playlist = bake._resolve_url("http://first/index.m3u8", {}, 5)
        self.assertIn(b"#EXTINF", playlist, "302 之后要跟到最终 m3u8 正文")
        self.assertEqual(calls, ["http://first/index.m3u8", "http://final/index.m3u8"])

    def test_main_playlist_picks_variant(self):
        playlist = ("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\n"
                    "chunklist_b800000.m3u8\n")
        self.assertEqual(bake.first_segment_url(playlist, "http://h/a/index.m3u8"),
                         "http://h/a/chunklist_b800000.m3u8")


class NumberingHelperTest(unittest.TestCase):
    def test_assign_range_is_stable(self):
        items = [{"name": "B"}, {"name": "A"}, {"name": "C"}]
        bake.assign_range(items, 100, 199, key=lambda item: item["name"])
        self.assertEqual([item["number"] for item in items], [100, 101, 102])

    def test_assign_range_respects_upper_bound(self):
        items = [{"name": "A"}, {"name": "B"}]
        bake.assign_range(items, 900, 900, key=lambda item: item["name"])
        self.assertEqual(items[0]["number"], 900)
        self.assertNotIn("number", items[1], "超出区间不分配台号")


class ImageMagicTest(unittest.TestCase):
    """真实图片才收：tvchinese 之类站点对任意路径都返回 200 + HTML 兜底页。"""

    def test_accepts_real_images(self):
        self.assertTrue(bake._looks_like_image(PNG_HEADER), "PNG")
        self.assertTrue(bake._looks_like_image(JPEG_HEADER), "JPEG")
        self.assertTrue(bake._looks_like_image(GIF_HEADER), "GIF")
        self.assertTrue(bake._looks_like_image(WEBP_HEADER), "WEBP")

    def test_rejects_html_and_empty(self):
        self.assertFalse(bake._looks_like_image(HTML_PAGE), "HTML 兜底页不是图片")
        self.assertFalse(bake._looks_like_image(b""), "空响应不是图片")
        self.assertFalse(bake._looks_like_image(b"\x89PNG"), "过短视为无效")


class FakeResponse:
    """最小 urlopen 替身：按 body 返回，支持 with 语句与 read(n)。"""

    def __init__(self, body):
        self.body = body
        self.offset = 0

    def read(self, size=-1):
        if size is None or size < 0:
            size = len(self.body) - self.offset
        chunk = self.body[self.offset:self.offset + size]
        self.offset += len(chunk)
        return chunk

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


class DownloadLogoTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.mkdtemp(prefix="tvbox-logo-")
        self.original_urlopen = bake.urllib.request.urlopen

    def tearDown(self):
        bake.urllib.request.urlopen = self.original_urlopen
        shutil.rmtree(self.directory, ignore_errors=True)

    def _serve(self, body):
        def fake_urlopen(request, timeout=None):  # noqa: ARG001
            return FakeResponse(body)
        bake.urllib.request.urlopen = fake_urlopen

    def test_writes_real_image(self):
        self._serve(PNG_HEADER)
        dest = os.path.join(self.directory, "A.cn.png")
        self.assertTrue(bake.download_logo("https://a.example/x.png", dest))
        self.assertEqual(os.path.getsize(dest), len(PNG_HEADER))

    def test_rejects_html_disguised_as_png(self):
        self._serve(HTML_PAGE)
        dest = os.path.join(self.directory, "B.cn.png")
        self.assertFalse(bake.download_logo("https://www.tvchinese.net/uploads/tv/b.png", dest),
                         "HTML 兜底页必须被判为失败")
        self.assertFalse(os.path.exists(dest), "失败时不留下垃圾文件")

    def test_reuses_existing_valid_file(self):
        dest = os.path.join(self.directory, "C.cn.png")
        with open(dest, "wb") as handle:
            handle.write(JPEG_HEADER)

        def explode(request, timeout=None):  # noqa: ARG001
            raise AssertionError("已有有效文件时不应再发请求")

        bake.urllib.request.urlopen = explode
        self.assertTrue(bake.download_logo("https://a.example/x.png", dest), "断点续跑复用本地文件")

    def test_existing_garbage_is_removed_and_refetched(self):
        dest = os.path.join(self.directory, "D.cn.png")
        with open(dest, "wb") as handle:
            handle.write(HTML_PAGE)
        self._serve(PNG_HEADER)
        self.assertTrue(bake.download_logo("https://a.example/x.png", dest))
        with open(dest, "rb") as handle:
            self.assertTrue(bake._looks_like_image(handle.read(64)), "垃圾文件被真图片覆盖")


class LogoCandidatesTest(unittest.TestCase):
    def test_order_matches_pick_logo(self):
        candidates = [
            logo("https://i.imgur.com/a.png", width=2000, height=2000, in_use=False),
            logo("https://www.tvchinese.net/b.png", width=100, height=100, in_use=True),
        ]
        ordered = bake.logo_candidates(candidates)
        self.assertEqual(ordered[0]["url"], "https://www.tvchinese.net/b.png",
                         "首选与 pick_logo 一致")

    def test_fallback_includes_unreachable_host(self):
        candidates = [
            logo("https://i.imgur.com/a.png", in_use=False),
            logo("https://www.tvchinese.net/b.png", in_use=False),
        ]
        ordered = bake.logo_candidates(candidates)
        self.assertEqual(ordered[0]["url"], "https://www.tvchinese.net/b.png",
                         "可达图床优先")
        self.assertEqual(ordered[1]["url"], "https://i.imgur.com/a.png",
                         "首选失败后还要能试不可达图床")
        self.assertEqual(len(ordered), 2)

    def test_skips_svg_only(self):
        self.assertEqual(bake.logo_candidates([logo("https://a.example/x.svg", image_format="SVG")]), [],
                         "SVG 无法用 NSImage 解码，不作为候选")

    def test_limit(self):
        candidates = [logo("https://h%d.example/%d.png" % (i, i)) for i in range(10)]
        self.assertEqual(len(bake.logo_candidates(candidates, limit=3)), 3)


class AttachLogosFallbackTest(unittest.TestCase):
    """首选图床返回 HTML 时要自动换下一个候选，而不是整台没台标。"""

    def setUp(self):
        self.directory = tempfile.mkdtemp(prefix="tvbox-attach-")
        self.original_dir = bake.LOGOS_DIR
        self.original_download = bake.download_logo
        bake.LOGOS_DIR = self.directory

    def tearDown(self):
        bake.LOGOS_DIR = self.original_dir
        bake.download_logo = self.original_download
        shutil.rmtree(self.directory, ignore_errors=True)

    def test_second_candidate_wins(self):
        bad = "https://www.tvchinese.net/bad.png"
        good = "https://i.imgur.com/good.png"

        def fake_download(url, dest, deadline_seconds=8.0):  # noqa: ARG001
            if url != good:
                return False
            with open(dest, "wb") as handle:
                handle.write(PNG_HEADER)
            return True

        bake.download_logo = fake_download
        items = [{"id": "A.cn", "logoURL": "", "logoFile": None}]
        index = {"A.cn": [logo(bad, width=200, height=200), logo(good, width=50, height=50)]}
        stats = bake.attach_logos(items, index, download=True)
        self.assertEqual(stats["local"], 1, "整台只成功 1 张")
        self.assertEqual(items[0]["logoFile"], "logos/A.cn.png")
        self.assertEqual(items[0]["logoURL"], good, "logoURL 跟随真正成功的候选")

    def test_all_candidates_fail_keeps_url_only(self):
        bake.download_logo = lambda url, dest, deadline_seconds=8.0: False  # noqa: ARG005
        items = [{"id": "B.cn", "logoURL": "", "logoFile": None}]
        stats = bake.attach_logos(items, {"B.cn": [logo("https://i.imgur.com/b.png")]}, download=True)
        self.assertEqual(stats["local"], 0)
        self.assertIsNone(items[0]["logoFile"])
        self.assertEqual(items[0]["logoURL"], "https://i.imgur.com/b.png", "远端 URL 仍保留作兜底")

    def test_stale_files_are_cleaned(self):
        stale = os.path.join(self.directory, "Stale.cn.png")
        with open(stale, "wb") as handle:
            handle.write(PNG_HEADER)

        def fake_download(url, dest, deadline_seconds=8.0):  # noqa: ARG001
            with open(dest, "wb") as handle:
                handle.write(PNG_HEADER)
            return True

        bake.download_logo = fake_download
        items = [{"id": "C.cn", "logoURL": "", "logoFile": None}]
        bake.attach_logos(items, {"C.cn": [logo("https://a.example/c.png")]}, download=True)
        self.assertFalse(os.path.exists(stale), "本轮未引用的旧台标要被清掉")
        self.assertTrue(os.path.exists(os.path.join(self.directory, "C.cn.png")))


class FmLogoTest(unittest.TestCase):
    """一级台标源 fanmingming/live 的匹配规则。

    仓库文件名大小写敏感（`CCTV1.png` 存在、`cctv1.png` 不存在），
    所以匹配只能「归一化后查表、再取表里的真实文件名」，绝不能自己拼 URL。
    """

    def setUp(self):
        self.names = [
            "CCTV1.png",
            "CCTV5.png",
            "CCTV5+.png",
            "CCTV4k.png",
            "湖南卫视.png",
            "浙江卫视.png",
            "CCTV世界地理.png",
            "README.md",
        ]
        self.index = bake.build_fm_index(self.names)

    def test_index_keeps_real_filename(self):
        self.assertEqual(self.index["CCTV1"], "CCTV1.png")
        self.assertEqual(self.index["湖南卫视"], "湖南卫视.png")

    def test_non_image_files_ignored(self):
        self.assertNotIn("README", self.index, "只收图片文件")

    def test_cctv_dash_and_case_insensitive_key(self):
        item = {"id": "CCTV1.cn", "name": "CCTV-1 综合", "subname": "CCTV-1"}
        candidates = bake.fm_candidate_names(item, self.index)
        self.assertEqual(candidates[0], "CCTV1.png")

    def test_cctv_plus_not_confused_with_plain(self):
        item = {"id": "CCTV5Plus.cn", "name": "CCTV-5+ 体育赛事", "subname": "CCTV-5+"}
        candidates = bake.fm_candidate_names(item, self.index)
        self.assertEqual(candidates[0], "CCTV5+.png", "`+` 不能被归一化掉，否则会套错台标")
        plain = bake.fm_candidate_names({"name": "CCTV-5 体育", "subname": "CCTV-5"}, self.index)
        self.assertEqual(plain[0], "CCTV5.png")

    def test_satellite_matches_chinese_display_name(self):
        item = {"id": "HunanTV.cn", "name": "湖南卫视", "subname": "Hunan TV"}
        self.assertEqual(bake.fm_candidate_names(item, self.index)[0], "湖南卫视.png")

    def test_unknown_channel_returns_empty(self):
        item = {"id": "XXX.cn", "name": "不存在的台", "subname": "Nonexistent TV"}
        self.assertEqual(bake.fm_candidate_names(item, self.index), [],
                         "仓库里没有的台不能凭空返回文件名")

    def test_paid_channel_without_cctv_prefix(self):
        item = {"id": "CCTVWorldGeography.cn", "name": "CCTV-世界地理", "subname": "CCTV-World Geography"}
        self.assertEqual(bake.fm_candidate_names(item, self.index)[0], "CCTV世界地理.png")


if __name__ == "__main__":
    unittest.main(verbosity=2)
