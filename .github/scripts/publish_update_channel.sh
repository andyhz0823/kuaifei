#!/usr/bin/env bash
# 把已发布的 GitHub Release 投放到客户端更新通道。
#
# 在 CI（ubuntu-latest）中由 .github/workflows/release.yml 的 deploy-channel job 调用。
#
# 必填环境变量：
#   RELEASE_TAG        形如 v4.1.14
#   GITHUB_REPOSITORY  owner/name（Actions 自动注入）
#   GITHUB_TOKEN       Actions 自动注入，用于规避 API 限流
#
# 可选 secrets（未配置 DEPLOY_SSH_KEY 时整个步骤安全跳过）：
#   DEPLOY_SSH_KEY    SSH 私钥（PEM）
#   DEPLOY_HOST       默认 216.18.193.108
#   DEPLOY_USER       默认 root
#   DEPLOY_SSH_PORT   默认 22
#   DEPLOY_PATH       默认 /www/wwwroot/kuaifei.top/Downloads
#   CHANNEL_BASE_URL  默认 https://xz.kuaity.top/Downloads
set -euo pipefail

TAG="${RELEASE_TAG:?RELEASE_TAG is required}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
HOST="${DEPLOY_HOST:-216.18.193.108}"
USER_NAME="${DEPLOY_USER:-root}"
PORT="${DEPLOY_SSH_PORT:-22}"
REMOTE_PATH="${DEPLOY_PATH:-/www/wwwroot/kuaifei.top/Downloads}"
BASE_URL="${CHANNEL_BASE_URL:-https://xz.kuaity.top/Downloads}"

if [[ -z "${DEPLOY_SSH_KEY:-}" ]]; then
  echo "DEPLOY_SSH_KEY 未配置，跳过更新通道投放。"
  echo "如需启用，请添加仓库 secret：DEPLOY_SSH_KEY（以及可选的 DEPLOY_HOST/DEPLOY_USER/DEPLOY_PATH/CHANNEL_BASE_URL）。"
  exit 0
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
mkdir -p "$workdir/manifests" "$workdir/ssh"

key="$workdir/ssh/id_deploy"
printf '%s\n' "$DEPLOY_SSH_KEY" > "$key"
chmod 600 "$key"

SSH_OPTS=(
  -i "$key"
  -p "$PORT"
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$workdir/ssh/known_hosts"
  -o BatchMode=yes
  -o ConnectTimeout=20
)
SCP_OPTS=(-i "$key" -P "$PORT" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$workdir/ssh/known_hosts" -o BatchMode=yes)
REMOTE="$USER_NAME@$HOST"

echo "==> 生成更新清单（$TAG）"
python3 "$script_dir/gen_update_manifests.py" \
  --tag "$TAG" \
  --repo "$REPO" \
  --base-url "$BASE_URL" \
  --out "$workdir/manifests" \
  --require-assets

mapfile -t ASSETS < <(grep -v '^[[:space:]]*$' "$workdir/manifests/channel-assets.txt")
if [[ "${#ASSETS[@]}" -eq 0 ]]; then
  echo "channel-assets.txt 为空，无法投放" >&2
  exit 1
fi
echo "==> 待镜像产物（${#ASSETS[@]} 个）：${ASSETS[*]}"

download_base="https://github.com/$REPO/releases/download/$TAG"

echo "==> 上传远端投放脚本"
scp "${SCP_OPTS[@]}" "$script_dir/remote_mirror_release.sh" "$REMOTE:/tmp/kuaifei-remote-mirror.sh"

printf -v quoted_args '%q ' "$TAG" "$REMOTE_PATH" "$download_base" "${ASSETS[@]}"
echo "==> 远端拉取产物并镜像到 $REMOTE_PATH"
# shellcheck disable=SC2029
ssh "${SSH_OPTS[@]}" "$REMOTE" "bash /tmp/kuaifei-remote-mirror.sh $quoted_args; rc=\$?; rm -f /tmp/kuaifei-remote-mirror.sh; exit \$rc"

echo "==> 上传更新清单"
scp "${SCP_OPTS[@]}" \
  "$workdir/manifests/latest.json" \
  "$workdir/manifests/latest-windows.json" \
  "$workdir/manifests/appcast.xml" \
  "$REMOTE:$REMOTE_PATH/"

# shellcheck disable=SC2029
ssh "${SSH_OPTS[@]}" "$REMOTE" "cd '$REMOTE_PATH' && chown --reference=\"\$(find . -maxdepth 1 -type f -print -quit)\" latest.json latest-windows.json appcast.xml 2>/dev/null || chown 1000:1000 latest.json latest-windows.json appcast.xml; chmod 644 latest.json latest-windows.json appcast.xml; ls -la latest.json latest-windows.json appcast.xml"

echo "==> 公网复验"
for name in latest.json latest-windows.json appcast.xml; do
  remote_file="$workdir/$name"
  curl -fsSL --retry 3 -o "$remote_file" "$BASE_URL/$name"
  if ! cmp -s "$remote_file" "$workdir/manifests/$name"; then
    echo "清单内容与本地不一致：$name" >&2
    exit 1
  fi
  echo "  $name 内容一致"
done

for asset in "${ASSETS[@]}"; do
  code="$(curl -sSL -o /dev/null -w '%{http_code}' --range 0-0 "$BASE_URL/$asset" || true)"
  if [[ "$code" != "200" && "$code" != "206" ]]; then
    echo "产物不可访问：$asset（HTTP $code）" >&2
    exit 1
  fi
  echo "  $asset 可访问（HTTP $code）"
done

echo "==> 更新通道投放完成：$TAG -> $BASE_URL"
