#!/usr/bin/env bash
#
# 把 mlx-swift 预置的 Metal kernel 编译成 mlx.metallib，供 Amai.app 使用。
#
# 背景：SwiftPM 没有 Metal 编译规则，`swift build` 会忽略 .metal 源文件，
# 运行时 MLX 找不到 metallib 直接崩溃。Xcode 有内置规则，但本项目沿用
# SwiftPM 工作流（ADR-0002），所以自己跑 metal/metallib。mlx-swift 只预置
# 少数 kernel（0.32.3 为 10 个），其余在运行时 JIT 编译。上游 issue：
# https://github.com/ml-explore/mlx-swift/issues/349
#
# 用法：
#   ./scripts/build-mlx-metallib.sh <output-metallib-path> [<mlx-swift-checkout-root>]
#
# 从 .build/checkouts/mlx-swift 读取源码（需先 `swift build` 拉取依赖）。
# 若 mlx-swift 不在依赖图中则以 0 退出且不产出，便于 bundle.sh 无条件调用。

set -euo pipefail

OUT="${1:?usage: $0 <output-metallib-path> [<mlx-swift-checkout-root>]}"
ROOT="$(cd -- "$(dirname "$0")/.." && pwd)"
MLX_SWIFT_ROOT="${2:-${ROOT}/.build/checkouts/mlx-swift}"
MLX_GEN="${MLX_SWIFT_ROOT}/Source/Cmlx/mlx-generated/metal"

if [ ! -d "$MLX_GEN" ]; then
    echo "→ mlx-swift not in .build/checkouts/ — skipping metallib"
    exit 0
fi

if ! xcrun --find metal >/dev/null 2>&1; then
    cat >&2 <<EOF
✗ Metal compiler not available via xcrun.

  xcode-select 可能指向 Command Line Tools（不含 Metal 工具链）。切换到完整 Xcode：

      sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

  Current: $(xcode-select -p)
EOF
    exit 1
fi

if ! "$(xcrun --find metal)" --version >/dev/null 2>&1; then
    cat >&2 <<EOF
✗ Metal toolchain component not installed.

  Xcode 26+ 把 Metal 编译器作为单独组件分发。安装一次（约 1–2 GB）：

      xcodebuild -downloadComponent MetalToolchain

EOF
    exit 1
fi

# kernel 列表直接从所用 mlx-swift 版本的 tools/fix-metal-includes.sh 读取，升级 mlx-swift 时自动跟随
# （0.32 起 gemv.metal 被 dot.metal 取代，并新增 searchsorted.metal）。
FIX_INCLUDES="${MLX_SWIFT_ROOT}/tools/fix-metal-includes.sh"
KERNELS=()
if [ -f "$FIX_INCLUDES" ]; then
    while IFS= read -r k; do KERNELS+=("$k"); done < <(grep -oE '[A-Za-z0-9_/]+\.metal' "$FIX_INCLUDES" | sort -u)
fi
if [ "${#KERNELS[@]}" -eq 0 ]; then
    echo "✗ could not read the kernel list from ${FIX_INCLUDES}" >&2
    exit 1
fi

# 编译参数来自 mlx/mlx/backend/metal/kernels/CMakeLists.txt 的 build_kernel_base。
# -mmacosx-version-min 与 Package.swift 的 platforms（.macOS(.v15)）一致。
FLAGS=(
    -x metal
    -Wall
    -Wextra
    -fno-fast-math
    -Wno-c++17-extensions
    -Wno-c++20-extensions
    -mmacosx-version-min=15.0
    -I "$MLX_GEN"
)

TMP=$(mktemp -d -t amai-metallib.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

AIR_FILES=()
for k in "${KERNELS[@]}"; do
    src="${MLX_GEN}/${k}"
    if [ ! -f "$src" ]; then
        echo "✗ missing kernel source: $src" >&2
        echo "  (mlx-swift layout changed? sync KERNELS list with upstream)" >&2
        exit 1
    fi
    air="${TMP}/$(basename "${k%.metal}").air"
    echo "→ compiling ${k}"
    xcrun -sdk macosx metal "${FLAGS[@]}" -c "$src" -o "$air"
    AIR_FILES+=("$air")
done

echo "→ linking $(basename "$OUT")"
mkdir -p "$(dirname "$OUT")"
xcrun -sdk macosx metallib "${AIR_FILES[@]}" -o "$OUT"

bytes=$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT" 2>/dev/null || echo 0)
mb=$(( bytes / 1024 / 1024 ))
echo "✓ $(basename "$OUT") (${mb} MB) at $OUT"
