#!/usr/bin/env bash
#
# Build a RELEASE HAP signed with a publishing certificate.
#
# This is the "ship it to anyone" path: a release certificate from AGC is not
# bound to a device whitelist, so the resulting HAP installs on any HarmonyOS
# device at or above compatibleSdkVersion.
#
# Usage:
#   bash scripts/build-release.sh
#
# Prerequisites (one-time, all done in AppGallery Connect):
#   1. A real-name-verified Huawei developer account.
#   2. An app created in AGC whose bundleName matches AppScope/app.json5
#      (currently com.qtepp.taharness) — AGC refuses duplicates.
#   3. A release certificate (.cer) + release provisioning profile (.p7b)
#      downloaded from AGC, plus the matching keystore (.p12).
#
# Put the signing material in build-profile.release.json5 (gitignored) — copy
# build-profile.signing.json5 and swap the paths. Never commit it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RELEASE_PROFILE="build-profile.release.json5"
STRIPPED_BAK="/tmp/dshharmony-build-profile.release-stripped.json5"
INJECTED=0

restore_profile() {
  if [ "$INJECTED" = "1" ] && [ -f "$STRIPPED_BAK" ]; then
    mv "$STRIPPED_BAK" build-profile.json5
    echo "已还原无签名的 build-profile.json5"
  fi
}
trap restore_profile EXIT

die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

[ -f "$RELEASE_PROFILE" ] || die "缺少 ${RELEASE_PROFILE}。
发布签名与调试签名不同：AGC 签发的发布证书不绑定设备白名单。
请从 AGC 下载 .cer / .p7b 并准备好 .p12，然后：
  cp build-profile.signing.json5 ${RELEASE_PROFILE}
  # 把里面四个路径换成发布材料，signingConfigs 的 name 保持 default"

BUNDLE="$(grep -oE '"bundleName"[[:space:]]*:[[:space:]]*"[^"]+"' AppScope/app.json5 | grep -oE '"[^"]+"$' | tr -d '"')"
[ -n "$BUNDLE" ] || die "读不到 AppScope/app.json5 的 bundleName"
say "bundleName: $BUNDLE"

# The provisioning profile embeds its own bundleName; a mismatch fails at
# SignHap with 00303074. Catch it here with a readable message instead.
P7B="$(grep -oE "profile:[[:space:]]*'[^']+'" "$RELEASE_PROFILE" | head -1 | sed "s/.*'\(.*\)'/\1/")"
if [ -f "$P7B" ]; then
  if ! strings "$P7B" | grep -q "$BUNDLE"; then
    die "签名 profile 里的 bundleName 与 $BUNDLE 不一致。
profile: $P7B
请在 AGC 用该 bundleName 重新生成 profile，否则 SignHap 会报 00303074。"
  fi
  say "profile bundleName 校验通过"
else
  printf '\033[1;33m[!]\033[0m 找不到 profile 文件：%s（跳过预检）\n' "$P7B"
fi

say "注入发布签名"
cp build-profile.json5 "$STRIPPED_BAK"
cp "$RELEASE_PROFILE" build-profile.json5
INJECTED=1

say "构建 release HAP…（含 ~225MB 载荷，较慢）"
devecocli build --build-mode release

OUT="entry/build/default/outputs/default"
HAP="$OUT/entry-default-signed.hap"
[ -f "$HAP" ] || die "构建结束但没有签名产物：$HAP"

say "产物：$HAP ($(du -h "$HAP" | cut -f1))"
say "完成。这个 HAP 不绑定设备白名单，可安装到任意 HarmonyOS ${BUNDLE} 兼容设备。"
echo
echo "提醒："
echo "  · 接收方需要自己填 DeepSeek API Key（密钥不能随包分发）"
echo "  · compatibleSdkVersion 决定了最低系统版本，见 build-profile.json5"
echo "  · 上架 AppGallery 还需在 AGC 提交审核，本脚本只产出可安装的包"
