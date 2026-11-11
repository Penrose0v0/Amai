#!/usr/bin/env bash
#
# 设置发布版本号：CFBundleShortVersionString 设为给定值，CFBundleVersion（构建号）加 1。
# 只改 Resources/Info.plist 的这两行，不重排文件。
#
# 用法：
#   ./scripts/set-version.sh 0.2.0
#
set -euo pipefail

cd "$(dirname "$0")/.."

NEW="${1:?usage: set-version.sh X.Y.Z}"
if ! [[ "${NEW}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "✗ version must be X.Y.Z" >&2
    exit 1
fi

PLIST="Resources/Info.plist"
OLD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "${PLIST}")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "${PLIST}")"
NEXT_BUILD=$((BUILD + 1))

python3 - "${PLIST}" "${NEW}" "${NEXT_BUILD}" <<'EOF'
import re, sys
path, version, build = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
for key, value in (("CFBundleShortVersionString", version), ("CFBundleVersion", build)):
    text, n = re.subn(rf"(<key>{key}</key>\s*<string>)[^<]*(</string>)", rf"\g<1>{value}\g<2>", text)
    assert n == 1, key
open(path, "w").write(text)
EOF

plutil -lint "${PLIST}" >/dev/null
echo "✓ ${OLD} (${BUILD}) → ${NEW} (${NEXT_BUILD})"
