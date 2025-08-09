#!/bin/bash
# 1Panel offline builder (v2+ friendly)
# - 从官方 CDN 下载: https://resource.1panel.hk/.pro/<stable|beta>/<version>/release/1panel-<ver>-linux-<arch>.tar.gz
# - 支持多镜像兜底、重试、按需架构
# - 默认同时打在线包与离线包（含 docker/compose，如可用）

set -euo pipefail
set -x

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

# ===== 可配置项 =====
# CDN 渠道：stable | beta
INSTALL_MODE="${INSTALL_MODE:-stable}"

# 镜像列表（按顺序尝试）
BASE_URLS=(
  "https://resource.1panel.hk"
  "https://resource.1panel.pro"
)

# 需要构建的架构（默认全量；你的 CI 已设置为 "aarch64 x86_64"）
ARCH_LIST="${ARCH_LIST:-aarch64 armel armhf loongarch64 ppc64le riscv64 s390x x86_64}"

# 是否生成离线包（包含 docker/compose 二进制）；设为 "false" 可仅打在线包
OFFLINE_BUILD="${OFFLINE_BUILD:-true}"
# ====================

# ---- 小工具 ----
download() {
  local url="$1" out="$2"
  # 先用 curl，失败回退 wget；都启用重试
  if ! curl -fL --retry 5 --retry-delay 2 --retry-connrefused -o "$out" "$url"; then
    wget --tries=5 --waitretry=2 --timeout=30 -O "$out" "$url"
  fi
}

url_exists() {
  local url="$1"
  curl -fsIL --retry 3 --retry-delay 2 --retry-connrefused "$url" >/dev/null 2>&1
}

# ---- 解析参数 ----
app_version=""
docker_version=""
compose_version=""

while [[ $# -gt 0 ]]; do
  lowerI="$(echo "$1" | awk '{print tolower($0)}')"
  case "$lowerI" in
    -h|--help)
      echo "Usage: $0 --app_version vX.Y.Z --docker_version A.B.C --compose_version vM.N.P"
      exit 0
      ;;
    --app_version)     app_version="$2"; shift ;;
    --docker_version)  docker_version="$2"; shift ;;
    --compose_version) compose_version="$2"; shift ;;
    *)
      echo "install: Unknown option $1"
      echo "eg: $0 --app_version v2.0.8 --docker_version 28.3.3 --compose_version v2.39.2"
      exit 1
      ;;
  esac
  shift
done

APP_VERSION="${app_version:-v1.7.4}"
DOCKER_VERSION="${docker_version:-20.10.7}"
COMPOSE_VERSION="${compose_version:-v2.23.0}"

# 清理输出目录
if [ -d "${BASE_DIR}/build" ]; then
  rm -rf "${BASE_DIR}/build"/*
fi

BUILT_ANY=0

for ARCHITECTURE in $ARCH_LIST; do
  cd "${BASE_DIR}"

  case "${ARCHITECTURE}" in
    aarch64)     ARCH="arm64" ;;
    armel)       ARCH="armv6" ;;
    armhf)       ARCH="armv7" ;;
    loongarch64) ARCH="loong64" ;;
    ppc64le)     ARCH="ppc64le" ;;
    riscv64)     ARCH="riscv64" ;;
    s390x)       ARCH="s390x" ;;
    x86_64)      ARCH="amd64" ;;
    *) echo "Unknown ARCHITECTURE: ${ARCHITECTURE}"; exit 1 ;;
  esac

  APP_ASSET_NAME="1panel-${APP_VERSION}-linux-${ARCH}.tar.gz"

  # ---- 从 CDN 多镜像查找可用的下载地址 ----
  APP_BIN_URL=""
  for base in "${BASE_URLS[@]}"; do
    candidate="${base}/${INSTALL_MODE}/${APP_VERSION}/release/${APP_ASSET_NAME}"
    if url_exists "$candidate"; then
      APP_BIN_URL="$candidate"
      break
    fi
  done

  if [ -z "$APP_BIN_URL" ]; then
    echo "Skip ${ARCHITECTURE}: ${APP_ASSET_NAME} not found on CDN mirrors (mode=${INSTALL_MODE})."
    continue
  fi

  # ---- Docker 静态二进制 & Compose 二进制 ----
  DOCKER_BIN_URL="https://download.docker.com/linux/static/stable/${ARCHITECTURE}/docker-${DOCKER_VERSION}.tgz"
  COMPOSE_BIN_URL="https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${ARCHITECTURE}"

  case "${ARCHITECTURE}" in
    armel|armhf)
      # compose 对 armv6/armv7 的发布名不一致，换成按 ARCH 命名的可执行文件
      COMPOSE_BIN_URL="https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${ARCH}"
      ;;
    loongarch64)
      DOCKER_BIN_URL="https://github.com/loong64/docker-ce-packaging/releases/download/v${DOCKER_VERSION}/docker-${DOCKER_VERSION}.tgz"
      COMPOSE_BIN_URL="https://github.com/loong64/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${ARCHITECTURE}"
      ;;
    riscv64|ppc64le|s390x)
      # 这些架构官方未必有静态 docker 包，尝试社区仓库；若不存在则跳过嵌入
      DOCKER_BIN_URL="https://github.com/wojiushixiaobai/docker-ce-binaries-${ARCHITECTURE}/releases/download/v${DOCKER_VERSION}/docker-${DOCKER_VERSION}.tgz"
      ;;
  esac

  BUILD_NAME="1panel-${APP_VERSION}-linux-${ARCH}"
  BUILD_DIR="${BASE_DIR}/build/${APP_VERSION}/${BUILD_NAME}"
  mkdir -p "${BUILD_DIR}"

  BUILD_OFFLINE_NAME="1panel-${APP_VERSION}-offline-linux-${ARCH}"
  BUILD_OFFLINE_DIR="${BASE_DIR}/build/${APP_VERSION}/${BUILD_OFFLINE_NAME}"
  mkdir -p "${BUILD_OFFLINE_DIR}"

  # ---- 下载 1Panel 包并解压到两个目录 ----
  if [ ! -f "${BASE_DIR}/build/${APP_ASSET_NAME}" ]; then
    echo "Downloading app: ${APP_BIN_URL}"
    download "${APP_BIN_URL}" "${BASE_DIR}/build/${APP_ASSET_NAME}"
  fi

  tar -xf "${BASE_DIR}/build/${APP_ASSET_NAME}" -C "${BUILD_DIR}" --strip-components=1
  tar -xf "${BASE_DIR}/build/${APP_ASSET_NAME}" -C "${BUILD_OFFLINE_DIR}" --strip-components=1

  # 移除内置 install.sh，换用仓库自己的
  rm -f "${BUILD_DIR}/install.sh" "${BUILD_OFFLINE_DIR}/install.sh"

  # ---- 离线包里塞 docker 静态二进制（若可用）----
  if [[ "${OFFLINE_BUILD}" != "false" ]] && [ ! -f "${BUILD_OFFLINE_DIR}/docker.tgz" ]; then
    if url_exists "${DOCKER_BIN_URL}"; then
      echo "Downloading docker static: ${DOCKER_BIN_URL}"
      download "${DOCKER_BIN_URL}" "${BUILD_OFFLINE_DIR}/docker.tgz"
    else
      echo "Docker static not found for ${ARCHITECTURE}, skip embedding."
    fi
  fi

  # ---- 下载 compose 到在线包，离线包复用 ----
  if [ ! -f "${BUILD_DIR}/docker-compose" ]; then
    if url_exists "${COMPOSE_BIN_URL}"; then
      echo "Downloading compose: ${COMPOSE_BIN_URL}"
      download "${COMPOSE_BIN_URL}" "${BUILD_DIR}/docker-compose"
    else
      echo "Compose binary not found for ${ARCHITECTURE}, skip."
    fi
  fi
  if [ ! -f "${BUILD_OFFLINE_DIR}/docker-compose" ] && [ -f "${BUILD_DIR}/docker-compose" ]; then
    cp -f "${BUILD_DIR}/docker-compose" "${BUILD_OFFLINE_DIR}/docker-compose"
  fi

  # ---- 附带服务与安装脚本（若存在于仓库）----
  cp -f "${BASE_DIR}/docker.service" "${BUILD_DIR}" 2>/dev/null || true
  cp -f "${BASE_DIR}/docker.service" "${BUILD_OFFLINE_DIR}" 2>/dev/null || true
  cp -f "${BASE_DIR}/install.sh" "${BUILD_DIR}" 2>/dev/null || true
  cp -f "${BASE_DIR}/install.sh" "${BUILD_OFFLINE_DIR}" 2>/dev/null || true

  # 替换 service 中的 1panel 路径（若文件存在）
  [ -f "${BUILD_DIR}/1panel.service" ] && sed -i 's@/usr/bin/1panel@/usr/local/bin/1panel@g' "${BUILD_DIR}/1panel.service" || true
  [ -f "${BUILD_OFFLINE_DIR}/1panel.service" ] && sed -i 's@/usr/bin/1panel@/usr/local/bin/1panel@g' "${BUILD_OFFLINE_DIR}/1panel.service" || true

  # 权限
  [ -f "${BUILD_DIR}/install.sh" ] && chmod +x "${BUILD_DIR}/install.sh" || true
  [ -f "${BUILD_OFFLINE_DIR}/install.sh" ] && chmod +x "${BUILD_OFFLINE_DIR}/install.sh" || true
  [ -f "${BUILD_OFFLINE_DIR}/docker-compose" ] && chmod +x "${BUILD_OFFLINE_DIR}/docker-compose" || true
  chown -R root:root "${BUILD_DIR}" "${BUILD_OFFLINE_DIR}" || true

  # 打包
  cd "${BASE_DIR}/build/${APP_VERSION}"
  tar -zcf "${BUILD_NAME}.tar.gz" "${BUILD_NAME}"
  if [[ "${OFFLINE_BUILD}" != "false" ]]; then
    tar -zcf "${BUILD_OFFLINE_NAME}.tar.gz" "${BUILD_OFFLINE_NAME}"
  fi

  BUILT_ANY=1
done

# 若全部架构均被跳过，则报错退出（便于 CI 立刻发现问题）
if [ "${BUILT_ANY}" -eq 0 ]; then
  echo "No builds produced: all architectures were skipped because CDN assets were not found (mode=${INSTALL_MODE}, version=${APP_VERSION})."
  exit 1
fi

cd "${BASE_DIR}/build/${APP_VERSION}"
sha256sum 1panel-*.tar.gz > checksums.txt
ls -al "${BASE_DIR}/build/${APP_VERSION}"
