#!/usr/bin/env bash
# 发布一个新版本：改版本号 → 用固定证书构建 → 校验签名身份 → 提交打 tag → 建 GitHub Release
#
# 用法：./release.sh 1.0.1 [发布说明文件]
#
# 为什么必须用这个脚本而不是手工发：如果哪一次忘了用固定证书签名（退回 ad-hoc），
# 所有用户的辅助功能授权都会失效，而且这个错误发出去就收不回来了。脚本会硬性拦截。
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
NOTES_FILE="${2:-}"
SIGN_ID="${SIGN_ID:-Hyper Self-Signed}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "用法：./release.sh <版本号> [发布说明文件]    例如 ./release.sh 1.0.1"
    exit 1
fi

# —— 前置检查 ——————————————————————————————————————————————

if ! security find-identity -v -p codesigning | grep -qF "\"$SIGN_ID\""; then
    echo "找不到签名身份「$SIGN_ID」。"
    echo "先跑 ./make-signing-cert.sh 建一个，否则发出去的版本会让所有用户重新授权。"
    exit 1
fi

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "工作区还有未提交的改动，先处理掉："
    git status --short
    exit 1
fi

if git rev-parse "v$VERSION" >/dev/null 2>&1; then
    echo "标签 v$VERSION 已存在。"
    exit 1
fi

CURRENT="$(sed -n 's/.*static let version = "\(.*\)"/\1/p' Sources/Hyper/Hyper.swift)"
echo "==> $CURRENT  →  $VERSION"

# —— 改版本号 ——————————————————————————————————————————————

sed -i '' "s/^VERSION=\".*\"/VERSION=\"$VERSION\"/" build.sh
sed -i '' "s/static let version = \".*\"/static let version = \"$VERSION\"/" Sources/Hyper/Hyper.swift

# —— 构建 ————————————————————————————————————————————————

SIGN_ID="$SIGN_ID" ./build.sh

# 确认签出来的确实是证书身份，而不是 ad-hoc。ad-hoc 的 DR 是 cdhash，会随每次构建变化。
DR="$(codesign -d -r- Hyper.app 2>&1 | sed -n 's/^designated => //p')"
if [[ "$DR" != *"certificate leaf"* ]]; then
    echo
    echo "构建产物不是用证书签名的，指定要求是："
    echo "  $DR"
    echo "发出去会让所有用户重新授权。已中止。"
    git checkout -- build.sh Sources/Hyper/Hyper.swift
    exit 1
fi
echo "==> 签名身份校验通过：$DR"

# —— 打包 ————————————————————————————————————————————————

ZIP="$(mktemp -d)/Hyper-$VERSION.zip"
ditto -c -k --keepParent Hyper.app "$ZIP"

# —— 提交、打 tag、发布 ——————————————————————————————————————

git add -A
git commit -q -m "v$VERSION"
git tag "v$VERSION"
git push -q && git push -q --tags

if [ -n "$NOTES_FILE" ] && [ -f "$NOTES_FILE" ]; then
    gh release create "v$VERSION" "$ZIP" --title "Hyper $VERSION" --notes-file "$NOTES_FILE"
else
    gh release create "v$VERSION" "$ZIP" --title "Hyper $VERSION" --generate-notes
fi

echo
echo "已发布 v$VERSION"
echo "已安装的旧版本会在下次启动时（或菜单栏「检查更新」）发现它。"
