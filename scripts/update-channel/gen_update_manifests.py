#!/usr/bin/env python3
"""从 GitHub Release 生成 Tkya 更新通道清单。

产出（写入 --out 目录）：
  latest.json          Android 端 AppUpdateRepositoryImpl.getLatestVersion() 读取
  latest-windows.json  Windows 端同方法按平台切换读取
  appcast.xml          全平台 upgrader(UpgraderAppcastStore) 读取，Sparkle RSS 格式
  channel-assets.txt   需要在分发目录中镜像的产物文件名（每行一个），供部署脚本使用

字段与客户端解析位置的对应关系：
  version / build_number / release_tag / published_at / pre_release / downloads.<platform>
  -> lib/features/app_update/data/app_update_repository.dart (getLatestVersion)
  downloads.<platform> 的 platform 取值 android | windows | macos | linux
  -> 同文件 platformKey 的 switch

注意：flutter 的 version 包比较版本时忽略 build 元数据
（version-3.0.2/lib/version.dart:200-217 只比 major/minor/patch/preRelease），
因此 appcast.xml 的 sparkle:version 必须写成 "1.0.4+10004" 形式，
对已装更早版本（例如 1.0.1）的用户才判定为有更新。
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

API = "https://api.github.com"
# 除产物外一并镜像的元数据文件
EXTRA_ASSETS = ("SHA256SUMS.txt", "SIGSTORE-VERIFICATION.txt")


def http_get(url: str) -> bytes:
    headers = {"User-Agent": "tkya-update-channel"}
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        # 命中 GitHub API 时才带鉴权，避免把 token 发给 release 资产域名
        headers["Authorization"] = f"Bearer {token}"
        headers["Accept"] = "application/vnd.github+json"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read()


def fetch_release(repo: str, tag: str) -> dict:
    return json.loads(http_get(f"{API}/repos/{repo}/releases/tags/{tag}"))


def fetch_pubspec_version(repo: str, tag: str) -> str:
    raw = http_get(f"{API}/repos/{repo}/contents/pubspec.yaml?ref={tag}")
    pubspec = base64.b64decode(json.loads(raw)["content"]).decode("utf-8")
    for line in pubspec.splitlines():
        if line.startswith("version:"):
            return line.split(":", 1)[1].strip()
    raise SystemExit("pubspec.yaml 中找不到 version 字段")


def fetch_sha256sums(assets: list[dict]) -> dict[str, dict]:
    """解析 SHA256SUMS.txt -> {文件名: {sha256, size}}。"""
    entry = next((a for a in assets if a["name"] == "SHA256SUMS.txt"), None)
    if entry is None:
        raise SystemExit("Release 中找不到 SHA256SUMS.txt，无法生成 files 校验块")
    text = http_get(entry["browser_download_url"]).decode("utf-8")
    out: dict[str, dict] = {}
    for line in text.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            continue
        digest, name = parts[0], parts[1].lstrip("*").strip()
        out[name] = {"sha256": digest}
    size_by_name = {a["name"]: a["size"] for a in assets}
    for name, info in out.items():
        if name in size_by_name:
            info["size"] = size_by_name[name]
    return out


def pick_assets(assets: list[dict]) -> dict[str, str | None]:
    """按命名约定挑出各平台产物文件名（与 release.yml 的产出命名保持一致）。"""
    names = [a["name"] for a in assets]

    def find(*preds) -> str | None:
        for n in names:
            low = n.lower()
            if all(p(low) for p in preds):
                return n
        return None

    picked = {
        "android_arm64": find(lambda s: "android-arm64" in s, lambda s: s.endswith(".apk")),
        "android_arm32": find(lambda s: ("armeabi" in s or "arm32" in s), lambda s: s.endswith(".apk")),
        "windows": find(lambda s: s.endswith(".exe")),
        "windows_portable": find(lambda s: s.endswith(".zip")),
    }
    missing = [k for k, v in picked.items() if v is None]
    if missing:
        print(f"[warn] 未匹配到的产物：{', '.join(missing)}", file=sys.stderr)
    return picked


def rfc822(iso: str) -> str:
    """2026-09-16T13:53:25Z -> Wed, 16 Sep 2026 13:53:25 GMT"""
    dt = datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone(timezone.utc)
    return dt.strftime("%a, %d %b %Y %H:%M:%S GMT")


def files_block(picked: dict[str, str | None], sums: dict[str, dict]) -> dict:
    """组装既有 latest.json 约定的 files 块（android 与 android_arm64 同值，android 排首位）。"""
    raw: dict[str, dict] = {}
    for key, name in picked.items():
        if not name or name not in sums:
            continue
        raw[key] = dict(sums[name])
    if "android_arm64" in raw and "android" not in raw:
        raw["android"] = dict(raw["android_arm64"])
    order = ["android", "android_arm64", "android_arm32", "windows", "windows_portable"]
    return {k: raw[k] for k in order if k in raw}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True, help="Release 标签，例如 v1.0.4")
    ap.add_argument("--repo", required=True, help="owner/name")
    ap.add_argument("--base-url", required=True, help="分发基址，例如 https://xz.tkya.cc.cd/Downloads")
    ap.add_argument("--out", required=True, help="清单输出目录")
    ap.add_argument(
        "--require-assets",
        action="store_true",
        help="任何平台产物缺失即失败（发布通道用），默认仅告警",
    )
    args = ap.parse_args()

    rel = fetch_release(args.repo, args.tag)
    tag = rel["tag_name"]
    version = tag.lstrip("v")
    published_at = rel["published_at"]

    pub_version = fetch_pubspec_version(args.repo, tag)
    if "+" in pub_version:
        pub_name, build_number = pub_version.split("+", 1)
    else:
        pub_name, build_number = pub_version, "0"
    if pub_name != version:
        print(f"[warn] 标签 {tag} 与 pubspec 版本 {pub_name} 不一致", file=sys.stderr)

    picked = pick_assets(rel["assets"])
    missing = [k for k, v in picked.items() if not v]
    if missing and args.require_assets:
        raise SystemExit(f"发布通道要求四类产物齐备，缺失：{', '.join(missing)}")

    sums = fetch_sha256sums(rel["assets"])
    base = args.base_url.rstrip("/")
    release_page = f"https://github.com/{args.repo}/releases/tag/{tag}"

    url = {k: (f"{base}/{v}" if v else release_page) for k, v in picked.items()}
    downloads = {
        "android": url["android_arm64"],
        "android_arm64": url["android_arm64"],
        "android_arm32": url["android_arm32"],
        "windows": url["windows"],
        "windows_portable": url["windows_portable"],
        # 本仓库不产出 macOS/Linux 包；留空会让客户端回退到 url（Windows exe），
        # 对非 Windows 用户是错误引导，故指向可导航的 Release 页面。
        "macos": release_page,
        "linux": release_page,
    }

    manifest = {
        "version": version,
        "build_number": build_number,
        "release_tag": tag,
        "pre_release": bool(rel.get("prerelease")),
        "published_at": published_at,
        "url": url["windows"],
        "downloads": downloads,
        "files": files_block(picked, sums),
    }

    os.makedirs(args.out, exist_ok=True)
    body = json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"
    for name in ("latest.json", "latest-windows.json"):
        with open(os.path.join(args.out, name), "w", encoding="utf-8", newline="\n") as fh:
            fh.write(body)

    def item(platform: str, file_url: str, size: int) -> str:
        return (
            "    <item>\n"
            f"      <title>Version {version}+{build_number}</title>\n"
            f"      <pubDate>{rfc822(published_at)}</pubDate>\n"
            "      <enclosure\n"
            f'        url="{file_url}"\n'
            f'        sparkle:version="{version}+{build_number}" '
            f'sparkle:shortVersionString="{version}" sparkle:os="{platform}"\n'
            f'        sparkle:length="{size}" />\n'
            "    </item>\n"
        )

    items = ""
    for platform, key in (("android", "android_arm64"), ("windows", "windows")):
        name = picked[key]
        if not name:
            continue
        items += item(platform, f"{base}/{name}", sums.get(name, {}).get("size", 0))

    appcast = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
        "  <channel>\n"
        "    <title>Tkya Release</title>\n"
        f"{items}"
        "  </channel>\n"
        "</rss>\n"
    )
    with open(os.path.join(args.out, "appcast.xml"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(appcast)

    # 需要在分发目录中镜像的产物文件清单
    mirror = [n for n in (picked["android_arm64"], picked["android_arm32"],
                          picked["windows"], picked["windows_portable"]) if n]
    mirror += [n for n in EXTRA_ASSETS if any(a["name"] == n for a in rel["assets"])]
    with open(os.path.join(args.out, "channel-assets.txt"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(mirror) + "\n")

    print(f"tag={tag} version={version} build_number={build_number} pre_release={manifest['pre_release']}")
    print(f"published_at={published_at}")
    for k, v in picked.items():
        print(f"  {k:18s} {v}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
