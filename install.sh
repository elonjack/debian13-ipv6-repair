#!/usr/bin/env bash

# One-line launcher for debian13-ipv6-repair.

set -euo pipefail

readonly RELEASE_BASE="https://github.com/elonjack/debian13-ipv6-repair/releases/latest/download"

die() {
    printf '[错误] %s\n' "$*" >&2
    exit 1
}

for command_name in curl sha256sum mktemp; do
    command -v "$command_name" >/dev/null 2>&1 || die "缺少必要命令：$command_name"
done

[[ -t 0 ]] || die "请在交互式终端中运行本命令。"

temporary_directory=$(mktemp -d)
cleanup() {
    rm -rf -- "$temporary_directory"
}
trap cleanup EXIT HUP INT TERM

curl -fL --retry 2 --connect-timeout 10 \
    -o "$temporary_directory/debian13-ipv6-repair.sh" \
    "$RELEASE_BASE/debian13-ipv6-repair.sh"
curl -fL --retry 2 --connect-timeout 10 \
    -o "$temporary_directory/SHA256SUMS" \
    "$RELEASE_BASE/SHA256SUMS"

(
    cd "$temporary_directory"
    sha256sum --check SHA256SUMS
) || die "主脚本 SHA256 校验失败，拒绝执行。"

chmod 700 "$temporary_directory/debian13-ipv6-repair.sh"

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    "$temporary_directory/debian13-ipv6-repair.sh"
elif command -v sudo >/dev/null 2>&1; then
    sudo "$temporary_directory/debian13-ipv6-repair.sh"
else
    die "当前不是 root 且未安装 sudo；请切换到 root 后重试。"
fi
