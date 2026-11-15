#!/usr/bin/env bash
set -euo pipefail

TOOLS_INSTALL_TEMP=''
cleanup() { if [[ -n "$TOOLS_INSTALL_TEMP" ]]; then rm -rf -- "$TOOLS_INSTALL_TEMP"; fi; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
flags=(DOCKER_CLI DOCKER_COMPOSE PYTHON GO RUST JAVA MAKE CMAKE BUILD_ESSENTIAL GH_CLI POSTGRES MONGODB REDIS PNPM BUN UV SSH_CLIENT RSYNC JQ YQ WGET)
for slug in "${flags[@]}"; do
  flag="TOOL_$slug"
  value=${!flag:-0}
  [[ "$value" == 0 || "$value" == 1 ]] || { printf 'Tools: invalid flag %s.\n' "$flag" >&2; exit 2; }
done
while IFS= read -r flag; do
  known=0
  for slug in "${flags[@]}"; do [[ "$flag" != "TOOL_$slug" ]] || known=1; done
  if [[ "$known" == 0 && "${!flag}" != 0 ]]; then printf 'Tools: unknown enabled recipe %s.\n' "$flag" >&2; exit 2; fi
done < <(compgen -A variable TOOL_ || true)
arch=${TARGETARCH:-}
[[ -n "$arch" ]] || arch=$(dpkg --print-architecture)
case "$arch" in amd64|arm64) ;; *) printf 'Tools: unsupported architecture %s.\n' "$arch" >&2; exit 2 ;; esac
if [[ "${TOOL_UV:-0}" == 1 && "${TOOL_PYTHON:-0}" != 1 ]]; then printf 'Tools: uv requires Python.\n' >&2; exit 2; fi
export DEBIAN_FRONTEND=noninteractive
packages=()
[[ "${TOOL_PYTHON:-0}" == 0 ]] || packages+=(python3 python3-pip python3-venv)
[[ "${TOOL_GO:-0}" == 0 ]] || packages+=(golang-go)
[[ "${TOOL_RUST:-0}" == 0 ]] || packages+=(rustc cargo)
[[ "${TOOL_JAVA:-0}" == 0 ]] || packages+=(default-jdk)
[[ "${TOOL_MAKE:-0}" == 0 ]] || packages+=(make)
[[ "${TOOL_CMAKE:-0}" == 0 ]] || packages+=(cmake)
[[ "${TOOL_BUILD_ESSENTIAL:-0}" == 0 ]] || packages+=(build-essential clang)
[[ "${TOOL_GH_CLI:-0}" == 0 ]] || packages+=(gh)
[[ "${TOOL_POSTGRES:-0}" == 0 ]] || packages+=(postgresql-client)
[[ "${TOOL_REDIS:-0}" == 0 ]] || packages+=(redis-tools)
[[ "${TOOL_SSH_CLIENT:-0}" == 0 ]] || packages+=(openssh-client)
[[ "${TOOL_RSYNC:-0}" == 0 ]] || packages+=(rsync)
[[ "${TOOL_JQ:-0}" == 0 ]] || packages+=(jq)
[[ "${TOOL_WGET:-0}" == 0 ]] || packages+=(wget)
if ((${#packages[@]} > 0)); then apt-get update; apt-get install -y --no-install-recommends "${packages[@]}"; fi
fetch() { curl --disable --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 180 --retry 2 --output "$2" "$1"; }
TOOLS_INSTALL_TEMP=$(mktemp -d)
if [[ "${TOOL_DOCKER_CLI:-0}" == 1 || "${TOOL_DOCKER_COMPOSE:-0}" == 1 || "${TOOL_MONGODB:-0}" == 1 ]]; then
  apt-get update
  apt-get install -y --no-install-recommends gnupg
  install -d -m 0755 /etc/apt/keyrings
fi
if [[ "${TOOL_DOCKER_CLI:-0}" == 1 || "${TOOL_DOCKER_COMPOSE:-0}" == 1 ]]; then
  fetch https://download.docker.com/linux/debian/gpg "$TOOLS_INSTALL_TEMP/docker.asc"
  gpg --batch --yes --dearmor --output /etc/apt/keyrings/docker.gpg "$TOOLS_INSTALL_TEMP/docker.asc"
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable\n' "$arch" > /etc/apt/sources.list.d/docker.list
  apt-get update
  packages=(docker-ce-cli)
  [[ "${TOOL_DOCKER_COMPOSE:-0}" == 0 ]] || packages+=(docker-compose-plugin)
  apt-get install -y --no-install-recommends "${packages[@]}"
fi
if [[ "${TOOL_MONGODB:-0}" == 1 ]]; then
  fetch https://pgp.mongodb.com/server-8.0.asc "$TOOLS_INSTALL_TEMP/mongodb.asc"
  gpg --batch --yes --dearmor --output /etc/apt/keyrings/mongodb.gpg "$TOOLS_INSTALL_TEMP/mongodb.asc"
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/mongodb.gpg] https://repo.mongodb.org/apt/debian bookworm/mongodb-org/8.0 main\n' "$arch" > /etc/apt/sources.list.d/mongodb.list
  apt-get update
  apt-get install -y --no-install-recommends mongodb-mongosh
fi
if [[ "${TOOL_PNPM:-0}" == 1 ]]; then npm install --global pnpm@10.32.1; fi
# SHA-256 digests were checked against official GitHub release asset metadata and downloaded bytes.
if [[ "${TOOL_BUN:-0}" == 1 ]]; then
  apt-get update
  apt-get install -y --no-install-recommends unzip
  if [[ "$arch" == amd64 ]]; then
    asset=bun-linux-x64-baseline; digest=e0446eb55995772eb9894bebae9a6be368d985a8b9271ee124486f9946eedd76
  else
    asset=bun-linux-aarch64; digest=baa6bb36f51d6e58561e02bbea825038a9df454f673d6d776e8bbf86f8c7850e
  fi
  fetch "https://github.com/oven-sh/bun/releases/download/bun-v1.4.4/$asset.zip" "$TOOLS_INSTALL_TEMP/bun.zip"
  printf '%s  %s\n' "$digest" "$TOOLS_INSTALL_TEMP/bun.zip" | sha256sum --check --status
  unzip -q "$TOOLS_INSTALL_TEMP/bun.zip" -d "$TOOLS_INSTALL_TEMP/bun"
  install -m 0755 "$TOOLS_INSTALL_TEMP/bun/$asset/bun" /usr/local/bin/bun
  ln -s /usr/local/bin/bun /usr/local/bin/bunx
fi
if [[ "${TOOL_UV:-0}" == 1 ]]; then
  if [[ "$arch" == amd64 ]]; then
    asset=uv-x86_64-unknown-linux-gnu; digest=5acfd9177cfecf0bf87578f059728215ccc884388988f55f7a65041b57387d91
  else
    asset=uv-aarch64-unknown-linux-gnu; digest=74f2f5c6024d397481db228db8fc25eed420db192243f88438c118e7e013e585
  fi
  fetch "https://github.com/astral-sh/uv/releases/download/0.13.8/$asset.tar.gz" "$TOOLS_INSTALL_TEMP/uv.tar.gz"
  printf '%s  %s\n' "$digest" "$TOOLS_INSTALL_TEMP/uv.tar.gz" | sha256sum --check --status
  tar -xzf "$TOOLS_INSTALL_TEMP/uv.tar.gz" -C "$TOOLS_INSTALL_TEMP"
  install -m 0755 "$TOOLS_INSTALL_TEMP/$asset/uv" "$TOOLS_INSTALL_TEMP/$asset/uvx" /usr/local/bin/
fi
if [[ "${TOOL_YQ:-0}" == 1 ]]; then
  if [[ "$arch" == amd64 ]]; then digest=129534601871538efe0ba4c5e62a34fb1d5f469bcb975c4fddeb467d82974973
  else digest=89f69310b61b68d1245065a1241d1fc843f7a36cd6103ffd77ad987613bd1b67; fi
  fetch "https://github.com/mikefarah/yq/releases/download/v4.54.3/yq_linux_$arch" "$TOOLS_INSTALL_TEMP/yq"
  printf '%s  %s\n' "$digest" "$TOOLS_INSTALL_TEMP/yq" | sha256sum --check --status
  install -m 0755 "$TOOLS_INSTALL_TEMP/yq" /usr/local/bin/yq
fi
rm -rf /var/lib/apt/lists/*
