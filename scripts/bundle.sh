#!/usr/bin/env bash
#
# 把 SwiftPM 可执行文件组装成 .app：
#   - LSUIElement 生效（无 Dock 图标，仅菜单栏）
#   - 稳定的代码签名让 TCC 记住权限授予
#   - 附带 MLX metallib 与 Swift 运行库
#
# 用法：
#   ./scripts/bundle.sh            # debug
#   ./scripts/bundle.sh release    # release
#
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP_NAME="Amai"
APP_DIR=".build/${APP_NAME}.app"

echo "→ swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN_DIR="$(swift build -c "${CONFIG}" --show-bin-path)"
EXEC_PATH="${BIN_DIR}/${APP_NAME}"

if [ ! -f "${EXEC_PATH}" ]; then
    echo "✗ Could not find built executable at ${EXEC_PATH}" >&2
    exit 1
fi

echo "→ assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${EXEC_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP_DIR}/Contents/Info.plist"

if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"
fi

# SwiftPM 为声明了 resources 的 target 生成 *.bundle，必须放在 Contents/Resources
# 下（放在 bundle 根目录会破坏签名）。没有 Info.plist 的 bundle 在 macOS 26 上
# 会被 Bundle(url:) 拒绝，补一个最小 Info.plist。
for bundle in "${BIN_DIR}"/*.bundle; do
    [ -e "${bundle}" ] || continue
    name="$(basename "${bundle}")"
    echo "→ copying resource bundle ${name}"
    cp -R "${bundle}" "${APP_DIR}/Contents/Resources/"
    dest="${APP_DIR}/Contents/Resources/${name}"
    if ! /usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "${dest}/Info.plist" >/dev/null 2>&1; then
        base="${name%.bundle}"
        cat > "${dest}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.amai.resources.${base}</string>
    <key>CFBundleName</key><string>${base}</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
</dict>
</plist>
EOF
        echo "  + injected Info.plist into ${name}"
    fi
done

# MLX Metal kernel：SwiftPM 不编译 .metal，这里单独编译。输出放在二进制旁边，
# 因为 MLX 首先在那里查找（mlx/backend/metal/device.cpp:load_default_library）。
./scripts/build-mlx-metallib.sh "${APP_DIR}/Contents/MacOS/mlx.metallib"

# 嵌入 Swift 运行库的 back-deployment 副本（Span 兼容库等只在 macOS 26+ 的
# /usr/lib/swift 中存在），并去掉指向 Xcode 工具链的 rpath。
mkdir -p "${APP_DIR}/Contents/Frameworks"
xcrun swift-stdlib-tool --copy \
    --scan-executable "${APP_DIR}/Contents/MacOS/${APP_NAME}" \
    --platform macosx \
    --destination "${APP_DIR}/Contents/Frameworks"

install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "${APP_DIR}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
otool -l "${APP_DIR}/Contents/MacOS/${APP_NAME}" \
    | awk '/LC_RPATH/{getline;getline; if ($2 ~ /Xcode|xctoolchain/) print $2}' \
    | while read -r rp; do
        echo "→ removing dev rpath ${rp}"
        install_name_tool -delete_rpath "${rp}" "${APP_DIR}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
    done

SIGN_IDENTITY="Amai Local Dev"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"${SIGN_IDENTITY}\""; then
    echo "→ codesign with '${SIGN_IDENTITY}' (inside-out)"
    SIGN_ARG="${SIGN_IDENTITY}"
else
    echo "→ ad-hoc codesign (inside-out; create a local dev cert named '${SIGN_IDENTITY}' to stabilize TCC)"
    SIGN_ARG="-"
fi
# inside-out 签名：先签最深层的嵌套对象，最后签 app。不用 --deep（已弃用且会漏签嵌套 bundle）。
while IFS= read -r item; do
    codesign --force --sign "${SIGN_ARG}" "${item}"
done < <(find "${APP_DIR}" -depth \
    \( -name "*.bundle" -o -name "*.dylib" -o -name "*.framework" -o -name "*.metallib" \))
codesign --force --sign "${SIGN_ARG}" "${APP_DIR}"

echo "✓ Built ${APP_DIR}"
echo
echo "Run with:  open ${APP_DIR}"
