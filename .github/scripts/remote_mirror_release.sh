#!/usr/bin/env bash
# 在目标服务器上执行：从 GitHub Release 拉取产物并镜像到更新通道分发目录。
#
# 用法：
#   remote_mirror_release.sh <tag> <dest> <download_base> <asset> [asset...]
#
# 例：
#   remote_mirror_release.sh v4.1.14 /www/wwwroot/kuaifei.top/Downloads \
#     https://github.com/o/r/releases/download/v4.1.14 \
#     Kuaifei-v4.1.14-android-arm64-v8a.apk ... SHA256SUMS.txt
#
# 由 .github/scripts/publish_update_channel.sh 通过 ssh 调用，一般不单独运行。
set -euo pipefail

TAG="${1:?tag required}"
DEST="${2:?dest required}"
DL_BASE="${3:?download base required}"
shift 3

if [[ $# -eq 0 ]]; then
  echo "no assets given" >&2
  exit 1
fi
ASSETS=("$@")

# 只接受形如 v4.1.14 的标签，避免拼进 URL/路径后出现问题
if [[ ! "$TAG" =~ ^v[0-9]+(\.[0-9]+)*$ ]]; then
  echo "refusing to run with unexpected tag: $TAG" >&2
  exit 1
fi
if [[ "$DEST" != /* ]]; then
  echo "dest must be an absolute path: $DEST" >&2
  exit 1
fi
for asset in "${ASSETS[@]}"; do
  # 产物文件名限定在安全字符集内
  if [[ ! "$asset" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "refusing to mirror unexpected asset name: $asset" >&2
    exit 1
  fi
done

for bin in curl sha256sum; do
  command -v "$bin" >/dev/null 2>&1 || { echo "missing required command: $bin" >&2; exit 1; }
done

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

echo "==> 下载产物到 $staging"
for asset in "${ASSETS[@]}"; do
  echo "  downloading $asset"
  curl -fsSL --retry 3 --retry-delay 3 -o "$staging/$asset" "$DL_BASE/$asset"
  echo "    -> $(stat -c%s "$staging/$asset") bytes"
done

echo "==> 暂存区校验 SHA-256"
( cd "$staging" && sha256sum -c SHA256SUMS.txt )

mkdir -p "$DEST"

# 属主对齐：优先复用分发目录内已有文件的属主，否则落到 1000:1000
reference="$(find "$DEST" -maxdepth 1 -type f -print -quit || true)"
echo "==> 镜像到 $DEST"
for asset in "${ASSETS[@]}"; do
  cp -f "$staging/$asset" "$DEST/$asset"
done

if [[ -n "$reference" ]]; then
  chown --reference="$reference" "${ASSETS[@]/#/$DEST/}" 2>/dev/null || chown 1000:1000 "${ASSETS[@]/#/$DEST/}"
else
  chown 1000:1000 "${ASSETS[@]/#/$DEST/}" 2>/dev/null || true
fi
chmod 644 "${ASSETS[@]/#/$DEST/}"

echo "==> 落地后复校 SHA-256"
( cd "$DEST" && sha256sum -c SHA256SUMS.txt )

echo "==> 分发目录当前产物"
ls -la "$DEST"
