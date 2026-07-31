#!/bin/sh
# =============================================================
# grok2api 自动更新启动脚本
# 用法：将此文件保存到持久化目录（如 /data/startup.sh）
#      在容器 Startup Command 中填写：sh /data/startup.sh
# =============================================================

set -e

# ── 可自定义变量 ──────────────────────────────────────────────
REPO="ZORfree/grok2api"
BASE_DIR="${BASE_DIR:-/data/grok2api}"          # 持久化目录
CONFIG_FILE="${GROK2API_CONFIG:-$BASE_DIR/config.yaml}"
LISTEN="${GROK2API_LISTEN:-0.0.0.0:8000}"
# ─────────────────────────────────────────────────────────────

BINARY="$BASE_DIR/grok2api"
VERSION_FILE="$BASE_DIR/.version"
FRONTEND_DIR="$BASE_DIR/frontend/dist"

# 工具检测（优先 curl，其次 wget）
if command -v curl >/dev/null 2>&1; then
    http_get() { curl -fsSL "$1"; }
    http_download() { curl -fsSL -o "$2" "$1"; }
else
    http_get() { wget -qO- "$1"; }
    http_download() { wget -q -O "$2" "$1"; }
fi

# 自动检测系统架构
detect_arch() {
    MACHINE=$(uname -m)
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$MACHINE" in
        x86_64)  GOARCH="amd64" ;;
        aarch64|arm64) GOARCH="arm64" ;;
        *) echo "[ERROR] Unsupported architecture: $MACHINE" >&2; exit 1 ;;
    esac
    echo "${OS}-${GOARCH}"
}

PLATFORM=$(detect_arch)
echo "[startup] Platform: $PLATFORM"

# ── 检查最新版本 ──────────────────────────────────────────────
echo "[startup] Fetching latest release info..."
RELEASE_JSON=$(http_get "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null) || true

if [ -z "$RELEASE_JSON" ]; then
    echo "[startup] WARNING: Cannot reach GitHub API. Using existing installation."
    LATEST_VERSION=""
else
    LATEST_VERSION=$(echo "$RELEASE_JSON" \
        | grep '"tag_name"' \
        | sed 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/' \
        | tr -d '[:space:]')
    echo "[startup] Latest version: $LATEST_VERSION"
fi

CURRENT_VERSION=""
[ -f "$VERSION_FILE" ] && CURRENT_VERSION=$(cat "$VERSION_FILE" | tr -d '[:space:]')
echo "[startup] Current version: ${CURRENT_VERSION:-none}"

# ── 下载并安装新版本 ──────────────────────────────────────────
if [ -n "$LATEST_VERSION" ] && { [ "$LATEST_VERSION" != "$CURRENT_VERSION" ] || [ ! -f "$BINARY" ]; }; then
    echo "[startup] Updating ${CURRENT_VERSION:-fresh install} → $LATEST_VERSION ..."

    TARBALL="grok2api-${LATEST_VERSION}-${PLATFORM}.tar.gz"
    DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${LATEST_VERSION}/${TARBALL}"
    echo "[startup] Downloading: $DOWNLOAD_URL"

    mkdir -p "$BASE_DIR"
    http_download "$DOWNLOAD_URL" /tmp/grok2api-release.tar.gz

    # 解压到临时目录（strip 顶层目录 pkg_linux-amd64/）
    rm -rf /tmp/grok2api-extract
    mkdir -p /tmp/grok2api-extract
    tar -xzf /tmp/grok2api-release.tar.gz -C /tmp/grok2api-extract --strip-components=1

    # 安装可执行文件
    cp /tmp/grok2api-extract/grok2api "$BINARY"
    chmod +x "$BINARY"

    # 安装前端（Release 包内目录名为 frontend-dist，映射到 frontend/dist）
    rm -rf "$FRONTEND_DIR"
    mkdir -p "$(dirname "$FRONTEND_DIR")"
    cp -r /tmp/grok2api-extract/frontend-dist "$FRONTEND_DIR"

    # 初次部署时生成默认配置文件
    if [ ! -f "$CONFIG_FILE" ]; then
        cp /tmp/grok2api-extract/config.example.yaml "$CONFIG_FILE"
        echo ""
        echo "╔══════════════════════════════════════════════╗"
        echo "║  首次部署：已生成默认配置文件                    ║"
        echo "║  请编辑: $CONFIG_FILE"
        echo "║  然后重启容器                                  ║"
        echo "╚══════════════════════════════════════════════╝"
        echo ""
    fi

    # 记录已安装版本
    echo "$LATEST_VERSION" > "$VERSION_FILE"

    # 清理临时文件
    rm -rf /tmp/grok2api-release.tar.gz /tmp/grok2api-extract
    echo "[startup] Update complete: $LATEST_VERSION"
else
    echo "[startup] Already up-to-date: $CURRENT_VERSION"
fi

# ── 启动服务 ─────────────────────────────────────────────────
if [ ! -f "$BINARY" ]; then
    echo "[ERROR] Binary not found: $BINARY" >&2
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] Config not found: $CONFIG_FILE" >&2
    echo "        Please create it (see config.example.yaml in the release)." >&2
    exit 1
fi

RUNNING_VERSION=$([ -f "$VERSION_FILE" ] && cat "$VERSION_FILE" || echo "unknown")
echo "[startup] Starting grok2api $RUNNING_VERSION on $LISTEN ..."
cd "$BASE_DIR"
exec "$BINARY" --config "$CONFIG_FILE" --listen "$LISTEN"
