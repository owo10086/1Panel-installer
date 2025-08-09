#!/bin/bash
set -euo pipefail
set -x

BASE_DIR=$(cd "$(dirname "$0")" || exit 1; pwd)

# 可配置：1Panel release 仓库，默认官方
APP_REPO="${APP_REPO:-1Panel-dev/1Panel}"

# 小工具：带重试的下载（优先 curl，失败再回退 wget）
download() {
  local url="$1" out="$2"
  if ! curl -fL --retry 5 --retry-delay 2 --retry-connrefused -o "$out" "$url"; then
    wget --tries=5 --waitretry=2 --timeout=30 -O "$out" "$url"
  fi
}

# HEAD 检查 url 是否存在（200/3xx 才算存在）
url_exists() {
  local url="$1"
  curl -fsIL --retry 3 --retry-delay 2 --retry-connrefused "$url" >/dev/null 2>&1
}

# 解析参数 —— 用整数比较
while [[ $# -gt 0 ]]; do
  lowerI="$(echo "$1" | awk '{print tolower($0)}')"
  case $lowerI in
    -h|--help)
      echo "Usage: $0 --app_version vX.Y.Z --docker_version A.B.C --compose_version vM.N.P"
      exit 0
      ;;
    --app_version)
      app_version="$2"; shift ;;
    --docker_version)
      docker_version="$2"; shift ;;
    --compose_version)
      compose_version="$2"; shift ;;
    *)
      echo "install: Unknown option $1"
      echo "eg: $0 --app_version v1.7.4 --docker_version 24.0.7 --compose_version v2.23.0"
      exit 1
      ;;
  esac
  shift
done

APP_VERSION=${app_version:-v1.7.4}
DOCKER_VERSION=${docker_version:-20.10.7}
COMPOSE_VERSION=${compose_version:-v2.23.0}

# 允许通过 ARCH_LIST 限定要构建的架构，默认跑全量
ARCH_LIST="${ARCH_LIST:-aarch64 armel armhf loongarch64 ppc64le riscv64 s390x x86_64}"

if [ -d "build" ]; then
  rm -rf build/*
fi

for ARCHITECTURE in $ARCH_LIST; do
  cd "${BASE_DIR}" || exit 1

  case "${ARCHITECTURE}" in
    aarch64)     ARCH="arm64" ;;
    armel)       ARCH="armv6" ;;   # 注意：很多项目并不提供 armv6 资产
    armhf)       ARCH="armv7" ;;
    loongarch64) ARCH="loong64" ;;
    ppc64le)     ARCH="ppc64le" ;;
    riscv64)     ARCH="riscv64" ;;
    s390x)       ARCH="s390x" ;;
    x86_64)      ARCH="amd64" ;;
    *) echo "Unknown ARCHITECTURE: $ARCHITECTURE"; exit 1 ;;
  esac

  # —— 1Panel 应用包（改为可配置仓库）——
  APP_ASSET_NAME="1panel-${APP_VERSION}-linux-${ARCH}.tar.gz"
  APP_BIN_URL="https://github.com/${APP_REPO}/releases/download/${APP_VERSION}/${APP_ASSET_NAME}"

  # 如果该架构的应用包不存在，直接跳过这个架构（而不是让整个脚本失败）
  if ! url_exists "$APP_BIN_URL"; then
    echo "Skip ${ARCHITECTURE}: ${APP_ASSET_NAME} not found at ${APP_REPO}"
    continue
  fi

  # —— Docker 静态包 / Compose 二进制 ——（保持你原来的映射，少量补强）
  DOCKER_BIN_URL="https://download.docker.com/linux/static/stable/${ARCHITECTURE}/docker-${DOCKER_VERSION}.tgz"
  COMPOSE_BIN_URL="https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${ARCHITECTURE}"

  OFFLINE_BUILD=""

  case "${ARCHITECTURE}" in
    armel|armhf)
      # compose 对 armv6/armv7 的可用性不稳定；armv6 往往无官方资产
      COMPOSE_BIN_URL="https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${ARCH}"
      ;;
    loongarch64)
      DOCKER_BIN_URL="https://github.com/loong64/docker-ce-packaging/releases/download/v${DOCKER_VERSION}/docker-${DOCKER_VERSION}.tgz"
      COMPOSE_BIN_URL="https://github.com/loong64/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${ARCHITECTURE}"
      ;;
    riscv64|ppc64le|s390x)
      # 这些仓库不一定有你指定的 DOCKER_VERSION 标签；如果 404 就不打离线包
      DOCKER_BIN_URL="https://github.com/wojiushixiaobai/docker-ce-binaries-${ARCHITECTURE}/releases/download/v${DOCKER_VERSION}/docker-${DOCKER_VERSION}.tgz"
      ;;
  esac

  BUILD_NAME="1panel-${APP_VERSION}-linux-${ARCH}"
  BUILD_DIR="build/${APP_VERSION}/${BUILD_NAME}"
  mkdir -p "${BUILD_DIR}"

  BUILD_OFFLINE_NAME="1panel-${APP_VERSION}-offline-linux-${ARCH}"
  BUILD_OFFLINE_DIR="build/${APP_VERSION}/${BUILD_OFFLINE_NAME}"
  mkdir -p "${BUILD_OFFLINE_DIR}"

  # 下载应用包（带重试 & 报错）
  if [ ! -f "build/${APP_ASSET_NAME}" ]; then
    echo "Downloading ${APP_BIN_URL}"
    download "${APP_BIN_URL}" "build/${APP_ASSET_NAME}"
  fi

  tar -xf "build/${APP_ASSET_NAME}" -C "${BUILD_DIR}" --strip-components=1
  tar -xf "build/${APP_ASSET_NAME}" -C "${BUILD_OFFLINE_DIR}" --strip-components=1
  rm -f "${BUILD_DIR}/install.sh" "${BUILD_OFFLINE_DIR}/install.sh"

  # 离线包里附带 docker 静态二进制（如果该 URL 存在才拉）
  if [ "${OFFLINE_BUILD}" != "false" ] && [ ! -f "${BUILD_OFFLINE_DIR}/docker.tgz" ]; then
    if url_exists "${DOCKER_BIN_URL}"; then
      echo "Downloading docker static: ${DOCKER_BIN_URL}"
      download "${DOCKER_BIN_URL}" "${BUILD_OFFLINE_DIR}/docker.tgz"
    else
      echo "Docker static not found for ${ARCHITECTURE}, skip embedding into offline package."
    fi
  fi

  # compose（在线和离线目录放同一份）
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

  cp -f docker.service "${BUILD_DIR}"
  cp -f docker.service "${BUILD_OFFLINE_DIR}"
  cp -f install.sh "${BUILD_DIR}"
  cp -f install.sh "${BUILD_OFFLINE_DIR}"

  # 如果 1panel.service 存在再替换路径（避免 sed 找不到文件失败）
  [ -f "${BUILD_DIR}/1panel.service" ] && sed -i 's@/usr/bin/1panel@/usr/local/bin/1panel@g' "${BUILD_DIR}/1panel.service" || true
  [ -f "${BUILD_OFFLINE_DIR}/1panel.service" ] && sed -i 's@/usr/bin/1panel@/usr/local/bin/1panel@g' "${BUILD_OFFLINE_DIR}/1panel.service" || true

  [ -f "${BUILD_OFFLINE_DIR}/docker-compose" ] && chmod +x "${BUILD_OFFLINE_D
