#!/usr/bin/env bash
#
# 构建可分发的 Amai.app，打包成 zip，生成 Homebrew cask，并打印发布命令（参考 Eira 的 release.sh）。
#
# 不会发布或推送任何东西：只在本地产出 dist/ 下的文件，并打印接下来要执行的命令。
#
#   - 版本号以 Resources/Info.plist 的 CFBundleShortVersionString 为准；升级版本用 ./scripts/set-version.sh；
#   - App 组装在 .build/dist/Amai.app：不退出、不替换正在运行的 Amai，不读写任何用户数据；
#   - zip 发布到 Amai 仓库自己的 GitHub Releases（仓库公开，brew 可直接下载）；
#     cask 放在公开的 Penrose0v0/homebrew-tap（与 Eira 共用）。
#
# 用法：
#   ./scripts/release.sh                # 要求工作区干净
#   ./scripts/release.sh --allow-dirty  # 本地试打包
#
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Amai"
RELEASE_REPO="Penrose0v0/Amai"
TAP_REPO="Penrose0v0/homebrew-tap"
APP_DIR=".build/dist/${APP_NAME}.app"
DIST="dist"

ALLOW_DIRTY=0
[ "${1:-}" = "--allow-dirty" ] && ALLOW_DIRTY=1

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
if ! [[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "✗ CFBundleShortVersionString \"${VERSION}\" is not X.Y.Z" >&2
    exit 1
fi
TAG="v${VERSION}"
ZIP="${DIST}/${APP_NAME}-${VERSION}.zip"

if [ -n "$(git status --porcelain)" ]; then
    if [ "${ALLOW_DIRTY}" = 1 ]; then
        echo "⚠︎ working tree has uncommitted changes (--allow-dirty): do not publish this build"
    else
        echo "✗ working tree has uncommitted changes; commit first, or pass --allow-dirty for a local test build" >&2
        exit 1
    fi
fi
if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    echo "⚠︎ tag ${TAG} already exists locally; bump the version with ./scripts/set-version.sh before publishing"
fi

echo "→ release build + bundle ${APP_DIR}"
AMAI_APP_DIR="${APP_DIR}" ./scripts/bundle.sh release

./scripts/verify-bundle.sh "${APP_DIR}" "${VERSION}"

echo "→ zipping → ${ZIP}"
mkdir -p "${DIST}"
rm -f "${ZIP}"
# ditto 保留代码签名与扩展属性；普通 zip 会破坏签名。
ditto -c -k --keepParent "${APP_DIR}" "${ZIP}"

SHA="$(shasum -a 256 "${ZIP}" | awk '{print $1}')"
SIZE="$(du -h "${ZIP}" | awk '{print $1}')"

CASK="${DIST}/amai.rb"
sed -e "s/__VERSION__/${VERSION}/" -e "s/__SHA256__/${SHA}/" packaging/homebrew/amai.rb.template > "${CASK}"

NOTES="${DIST}/RELEASE_NOTES-${VERSION}.md"
PREVIOUS_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
{
    echo "## Amai ${TAG}"
    echo
    if [ -n "${PREVIOUS_TAG}" ] && [ "${PREVIOUS_TAG}" != "${TAG}" ]; then
        git log --pretty='- %s' "${PREVIOUS_TAG}..HEAD"
    else
        echo "First release."
    fi
    echo
    echo "### Install"
    echo
    echo '```bash'
    echo "brew install --cask ${TAP_REPO%/*}/tap/amai"
    echo '```'
    echo
    echo "Requires an Apple Silicon Mac with macOS 15 or newer. The app is signed but not notarized; the Homebrew cask removes the quarantine flag after install. If you download the zip manually, run \`xattr -dr com.apple.quarantine /Applications/Amai.app\` before the first launch."
} > "${NOTES}"

cat <<EOF

────────────────────────────────────────────────────────────
✓ ${ZIP}  (${SIZE})
  sha256 ${SHA}
✓ ${CASK}
✓ ${NOTES}

Nothing has been published. To release ${TAG}:

  1. Tag and push the source:
       git tag ${TAG} && git push origin ${TAG}

  2. Create the GitHub release with the zip:
       gh release create ${TAG} "${ZIP}" --repo ${RELEASE_REPO} \\
         --title "Amai ${TAG}" --notes-file "${NOTES}"

  3. Copy ${CASK} to ${TAP_REPO} as Casks/amai.rb, commit and push.

Users then install with:
  brew install --cask ${TAP_REPO%/*}/tap/amai
────────────────────────────────────────────────────────────
EOF
