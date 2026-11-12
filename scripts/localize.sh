#!/usr/bin/env bash
#
# 从源码提取界面文字，同步到 Resources/Localizable.xcstrings（String Catalog，源语言简体中文）。
#
# 编译器在编译时记录 SwiftUI 文本（Text、Button、Label、.help 等）与 String(localized:) 中的字面量，
# 插值会变成 %@ / %lld 等占位符；xcstringstool 再把它们合并进 String Catalog：新键加入、已有翻译保留。
# 使用单独的构建目录，避免改动日常构建的编译参数。
#
# 用法：./scripts/localize.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."

OUT=".build/loc/stringsdata"
CATALOG="Resources/Localizable.xcstrings"
rm -rf "${OUT}"
mkdir -p "${OUT}"

# 增量构建只为改动过的文件输出字符串，sync 会删掉其余文件的键。先让本项目的源文件全部重新编译（依赖包不受影响）。
find Sources -name '*.swift' -exec touch {} +

echo "→ building with localized string extraction"
swift build --scratch-path .build/loc \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$(pwd)/${OUT}" >/dev/null

# 只收集本项目的界面模块（依赖包与开发工具的字符串不进入 String Catalog）。
FILES=()
while IFS= read -r f; do FILES+=("$f"); done < <(
    grep -l -E '"source" *: *"[^"]*/Sources/(Amai|AmaiMemoryUI|AmaiMemory|AmaiCloud|AmaiExtraction|AmaiPerception)/' "${OUT}"/*.stringsdata \
        | grep -v -E 'MemoryEvalCommand|MemoryPreviewTour|PreviewTimeline'
)

if [ ! -f "${CATALOG}" ]; then
    echo '{"sourceLanguage":"zh-Hans","strings":{},"version":"1.0"}' > "${CATALOG}"
fi
xcrun xcstringstool sync "${CATALOG}" --stringsdata "${FILES[@]}"
# xcstringstool 的 JSON 写法（"key" : value）与仓库中的格式不同，统一回仓库格式，避免整份文件出现无关 diff。
python3 - "${CATALOG}" <<'EOF'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
open(path, "w", encoding="utf-8").write(json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
EOF
echo "✓ synced ${#FILES[@]} files into ${CATALOG}"
