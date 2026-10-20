#!/usr/bin/env bash
#
# 一次性设置：为 Amai 开发创建自签名代码签名证书。
# macOS TCC 按 cdhash 记住 ad-hoc 签名应用的授权，每次重新打包 cdhash 都变，
# 屏幕录制等权限授予不会保留。稳定的签名身份解决这个问题，直到项目换用真正的
# Apple Developer 账户。（移植自 Eira 的同名脚本。）
#
# 用法：./scripts/setup-dev-cert.sh
#
set -euo pipefail

CERT_NAME="Amai Local Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
BUNDLE_ID="com.amai.app"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$CERT_NAME\""; then
    echo "✓ Code-signing identity '$CERT_NAME' already installed."
    echo "  To recreate, first delete it from Keychain Access."
    exit 0
fi

echo "→ Generating self-signed code-signing certificate: $CERT_NAME"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = req_dn
prompt = no
x509_extensions = v3_codesign

[req_dn]
CN = $CERT_NAME

[v3_codesign]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" \
    -out "$TMP/cert.pem" \
    -days 3650 \
    -config "$TMP/cert.cnf" >/dev/null 2>&1

openssl pkcs12 -export -legacy \
    -inkey "$TMP/key.pem" \
    -in "$TMP/cert.pem" \
    -out "$TMP/cert.p12" \
    -password pass:amai >/dev/null 2>&1 \
|| openssl pkcs12 -export \
    -inkey "$TMP/key.pem" \
    -in "$TMP/cert.pem" \
    -out "$TMP/cert.p12" \
    -password pass:amai >/dev/null 2>&1

echo "→ Importing into login keychain"
security import "$TMP/cert.p12" \
    -P amai \
    -k "$KEYCHAIN" \
    -T /usr/bin/codesign \
    -T /usr/bin/security

echo "→ Allowing codesign to use the private key without per-build prompts"
security set-key-partition-list \
    -S "apple-tool:,apple:,codesign:" \
    -s \
    "$KEYCHAIN" >/dev/null 2>&1 || {
    echo "  ! set-key-partition-list failed — codesign may prompt once; click '始终允许'."
}

echo "→ Clearing stale TCC entries for $BUNDLE_ID"
tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null || true
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null || true

echo
echo "✓ Done. Next: ./scripts/bundle.sh && open .build/Amai.app"
echo "  First launch will prompt for Screen Recording once; it sticks across rebuilds."
