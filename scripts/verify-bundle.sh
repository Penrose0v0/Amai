#!/usr/bin/env bash
#
# 检查组装好的 Amai.app 是否完整、可分发（由 release.sh 调用，也可单独运行）：
#   - 可执行文件（Amai、amai-mcp）、MLX metallib、界面翻译、SwiftPM 资源 bundle、Swift 运行库都在；
#   - 架构为 arm64，链接的动态库与 rpath 不指向本机开发路径；
#   - 代码签名完整有效；
#   - amai-mcp 能完成 MCP 握手并列出三个工具，版本号与 App 一致（使用临时的关闭状态配置，不读取任何记忆）。
#
# 用法：
#   ./scripts/verify-bundle.sh <Amai.app> [期望的版本号]
#
set -euo pipefail

APP="${1:?usage: verify-bundle.sh <Amai.app> [version]}"
EXPECTED_VERSION="${2:-}"
MACOS="${APP}/Contents/MacOS"
RES="${APP}/Contents/Resources"
failures=0

ok()   { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; failures=$((failures + 1)); }

echo "→ verifying ${APP}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "${APP}/Contents/Info.plist")"
if [ -n "${EXPECTED_VERSION}" ] && [ "${VERSION}" != "${EXPECTED_VERSION}" ]; then
    fail "version ${VERSION}, expected ${EXPECTED_VERSION}"
else
    ok "version ${VERSION}"
fi

for exe in Amai amai-mcp; do
    if [ -x "${MACOS}/${exe}" ]; then
        archs="$(lipo -archs "${MACOS}/${exe}")"
        [ "${archs}" = "arm64" ] && ok "${exe} (${archs})" || fail "${exe} architectures: ${archs}"
    else
        fail "missing executable ${exe}"
    fi
done

# MLX 在可执行文件旁边查找 metallib（见 bundle.sh）。
if [ -s "${MACOS}/mlx.metallib" ]; then
    ok "mlx.metallib ($(du -h "${MACOS}/mlx.metallib" | awk '{print $1}'))"
else
    fail "missing mlx.metallib"
fi

for lang in zh-Hans en ja; do
    if [ -d "${RES}/${lang}.lproj" ] && [ -f "${RES}/${lang}.lproj/InfoPlist.strings" ]; then
        ok "${lang}.lproj"
    else
        fail "missing ${lang}.lproj"
    fi
done
for lang in en ja; do
    [ -f "${RES}/${lang}.lproj/Localizable.strings" ] && ok "${lang} Localizable.strings" || fail "missing ${lang}.lproj/Localizable.strings"
done

bundles=0
for bundle in "${RES}"/*.bundle; do
    [ -e "${bundle}" ] || continue
    bundles=$((bundles + 1))
    /usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "${bundle}/Info.plist" >/dev/null 2>&1 \
        || fail "$(basename "${bundle}") has no Info.plist"
done
ok "${bundles} resource bundle(s)"

# 动态库：只允许系统路径、@rpath（指向 Contents/Frameworks）与可执行文件相对路径。
for exe in Amai amai-mcp; do
    bad="$(otool -L "${MACOS}/${exe}" | tail -n +2 | awk '{print $1}' \
        | grep -vE '^(/usr/lib/|/System/Library/|@rpath/|@executable_path/)' || true)"
    [ -z "${bad}" ] && ok "${exe} links only system and bundled libraries" || fail "${exe} links outside the bundle: ${bad}"
    rpaths="$(otool -l "${MACOS}/${exe}" | awk '/LC_RPATH/{getline;getline;print $2}')"
    if echo "${rpaths}" | grep -qE 'Xcode|xctoolchain|/Users/'; then
        fail "${exe} has development rpaths: $(echo "${rpaths}" | tr '\n' ' ')"
    else
        ok "${exe} rpaths: $(echo "${rpaths}" | tr '\n' ' ')"
    fi
done
for lib in $(otool -L "${MACOS}/Amai" "${MACOS}/amai-mcp" | awk '/@rpath\//{print $1}' | sort -u); do
    name="${lib#@rpath/}"
    if [ -e "${APP}/Contents/Frameworks/${name}" ] || [ -e "/usr/lib/swift/${name}" ]; then
        :
    else
        fail "${lib} is neither in Contents/Frameworks nor in /usr/lib/swift"
    fi
done
ok "@rpath libraries resolve"

if codesign --verify --strict --deep "${APP}" 2>/dev/null; then
    ok "code signature: $(codesign -dvv "${APP}" 2>&1 | awk -F= '/^Authority=/{print $2; exit}' | sed -E 's/: .*/: …/')"
else
    fail "code signature invalid"
fi
codesign --verify --strict "${MACOS}/amai-mcp" 2>/dev/null && ok "amai-mcp signed" || fail "amai-mcp signature invalid"

# amai-mcp 冒烟测试：临时配置为关闭状态，记忆目录为空的临时目录。
TMP="$(mktemp -d -t amai-verify)"
trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/memory"
printf '{"memory":{"root":"%s"},"mcp":{"enabled":false}}' "${TMP}/memory" > "${TMP}/config.json"
# 逐条请求并等待响应：刚复制到新位置的可执行文件第一次运行时，系统扫描可能让启动慢几秒。
if python3 - "${MACOS}/amai-mcp" "${TMP}/config.json" "${VERSION}" <<'EOF'
import json, selectors, subprocess, sys, time
exe, config, version = sys.argv[1:4]
proc = subprocess.Popen([exe, "--config", config], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL, text=True, bufsize=1)
sel = selectors.DefaultSelector()
sel.register(proc.stdout, selectors.EVENT_READ)

def send(message):
    proc.stdin.write(json.dumps(message) + "\n")
    proc.stdin.flush()

def wait(request_id, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if sel.select(timeout=deadline - time.monotonic()):
            line = proc.stdout.readline()
            if not line:
                break
            message = json.loads(line)
            if message.get("id") == request_id:
                return message["result"]
    raise SystemExit(f"no response to request {request_id}")

try:
    send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "verify", "version": "1"}}})
    info = wait(1)["serverInfo"]
    send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    send({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
    tools = [t["name"] for t in wait(2)["tools"]]
    send({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "search_memory", "arguments": {"query": "x"}}})
    call = wait(3)
finally:
    proc.kill()
assert info["name"] == "amai" and info["version"] == version, info
assert tools == ["search_memory", "get_timeline", "get_memory"], tools
assert call["isError"] and "turned off" in call["content"][0]["text"], call
EOF
then
    ok "amai-mcp handshake, 3 tools, version ${VERSION}, disabled by default"
else
    fail "amai-mcp smoke test failed"
fi

if [ "${failures}" -gt 0 ]; then
    echo "✗ ${failures} check(s) failed"
    exit 1
fi
echo "✓ bundle looks complete"
