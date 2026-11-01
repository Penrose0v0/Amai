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

# 先退出正在运行的 Amai：替换 bundle 后旧进程的磁盘代码与签名不再一致，
# 它下一次截图时系统会按"未授权程序"弹出屏幕录制授权框。
if pgrep -x "${APP_NAME}" >/dev/null; then
    echo "→ quitting running ${APP_NAME}"
    osascript -e "quit app \"${APP_NAME}\"" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x "${APP_NAME}" >/dev/null || break
        sleep 0.5
    done
    pkill -x "${APP_NAME}" 2>/dev/null || true
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

# 签名身份，按优先级：
#   1. 环境变量 AMAI_SIGN_IDENTITY；
#   2. 本机任意一张有效的 "Apple Development" 证书（Xcode 登录 Apple ID 即可获得，免费账号也可）；
#   3. 自签名 "Amai Local Dev"（scripts/setup-dev-cert.sh）；
#   4. ad-hoc。
# 为什么优先 Apple Development：钥匙串条目的分区列表（partition_id）对没有团队 ID 的签名只能记录
# cdhash，而 cdhash 每次重新打包都会变，导致每次构建后都弹出钥匙串授权框，"始终允许"也只对当次构建有效。
# 带团队 ID 的签名记录为 teamid:<ID>，跨构建稳定。
DEV_CERT_NAME="Amai Local Dev"
if [ -n "${AMAI_SIGN_IDENTITY:-}" ]; then
    SIGN_ARG="${AMAI_SIGN_IDENTITY}"
    echo "→ codesign with AMAI_SIGN_IDENTITY (inside-out)"
elif APPLE_DEV=$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/"Apple Development: /{print $2; exit}') && [ -n "${APPLE_DEV}" ]; then
    SIGN_ARG="${APPLE_DEV}"
    echo "→ codesign with Apple Development identity (inside-out; stable keychain & TCC identity)"
elif security find-identity -p codesigning 2>/dev/null | grep -q "\"${DEV_CERT_NAME}\""; then
    SIGN_ARG="${DEV_CERT_NAME}"
    echo "→ codesign with '${DEV_CERT_NAME}' (inside-out; keychain will re-prompt after each rebuild)"
else
    SIGN_ARG="-"
    echo "→ ad-hoc codesign (inside-out; run ./scripts/setup-dev-cert.sh or sign in to Xcode for a stable identity)"
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
