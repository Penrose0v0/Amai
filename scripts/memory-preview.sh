#!/usr/bin/env bash
#
# 用合成示例数据打开记忆窗口（隔离预览，开发用）。
#
# - 每次把 samples/memory-preview/（记忆）与 samples/timeline-preview/（时间线片段）复制到新的临时目录，
#   预览中的修改不影响样本；
# - 预览版打在 .build/preview/Amai.app，不替换、不退出正在运行的 Amai；
# - 预览模式不读写真实记忆、配置与钥匙串，不启动采集、抽取、同步、整理或任何模型调用。
#
# 用法：
#   ./scripts/memory-preview.sh            # 已有预览版时直接启动
#   ./scripts/memory-preview.sh --rebuild  # 先重新打包预览版
#
set -euo pipefail

cd "$(dirname "$0")/.."

APP=".build/preview/Amai.app"
if [ "${1:-}" = "--rebuild" ] || [ ! -d "${APP}" ]; then
    AMAI_APP_DIR="${APP}" ./scripts/bundle.sh
fi

DIR="$(mktemp -d -t amai-memory-preview)"
mkdir -p "${DIR}/memory"
cp -R samples/memory-preview/. "${DIR}/memory/"
mkdir -p "${DIR}/support/extracted"
cp -R samples/timeline-preview/. "${DIR}/support/extracted/"
echo "→ 示例记忆：${DIR}/memory"

open -n "${APP}" --args --memory-preview "${DIR}"
