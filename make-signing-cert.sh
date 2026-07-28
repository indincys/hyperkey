#!/usr/bin/env bash
# 创建一个自签名的代码签名证书，用于稳定 Hyper 的签名身份。
#
# 为什么需要：macOS 把「辅助功能」授权绑定在 app 的代码签名上。ad-hoc 签名
# （codesign -s -）每次重新构建都会产生新身份，于是每次都要重新授权一次。
# 用一个固定的证书签名后，重建不再改变身份，授权一次就一直有效。
#
# 这不能替代 Apple 公证：自签名证书在别人的电脑上不受信任，分发时对方仍需
# 绕过 Gatekeeper（见 README 的「分享给别人」一节）。
#
# 用法：./make-signing-cert.sh ["证书名称"]
set -euo pipefail

NAME="${1:-Hyper Self-Signed}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$NAME\""; then
    echo "已存在签名身份：$NAME"
    echo "直接构建：SIGN_ID=\"$NAME\" ./build.sh"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = v3

[ dn ]
CN = $NAME

[ v3 ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

echo "==> 生成密钥与自签名证书（有效期 10 年）"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/openssl.cnf" 2>/dev/null

# OpenSSL 3 默认用 AES-256 加密 PKCS#12 并用 SHA-256 做 MAC，macOS 的 security
# 两样都读不了，会报 "MAC verification failed"。必须退回到 SHA-1 + 3DES。
# 系统自带的 LibreSSL 不认识 -legacy，所以两种参数组合都试一遍。
# 口令只在本脚本内部用于中转，证书导入钥匙串后即失效。
echo "==> 打包为 PKCS#12"
P12PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -legacy -macalg sha1 \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES \
    -out "$TMP/bundle.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -passout "pass:$P12PASS" 2>/dev/null \
  || openssl pkcs12 -export -macalg sha1 \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES \
    -out "$TMP/bundle.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -passout "pass:$P12PASS" 2>/dev/null

echo "==> 导入钥匙串"
security import "$TMP/bundle.p12" -k "$KEYCHAIN" -P "$P12PASS" -T /usr/bin/codesign

# 没有这一步 codesign 找不到这个身份（find-identity 只列出受信任的）。
# 只写入当前用户的信任设置，不碰系统域，所以不需要 sudo —— 但会弹一次密码框。
echo "==> 标记为受信任的代码签名证书（会弹窗要求输入登录密码）"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo
if security find-identity -v -p codesigning | grep -qF "\"$NAME\""; then
    echo "完成。以后这样构建："
    echo "  SIGN_ID=\"$NAME\" ./build.sh"
    echo
    echo "首次用它签名时钥匙串可能会问一次权限，选「始终允许」。"
else
    echo "证书已创建但还没被识别为有效签名身份。"
    echo "打开「钥匙串访问」找到「$NAME」，双击 → 信任 → 代码签名 改为「始终信任」。"
    exit 1
fi
