#!/usr/bin/env bash
#
# Build a RELEASE HAP signed with a publishing certificate.
#
# This is the "ship it to anyone" path: a release certificate from AGC is not
# bound to a device whitelist, so the resulting HAP installs on any HarmonyOS
# device at or above compatibleSdkVersion.
#
# Flow (three steps, signing deliberately outside hvigor's SignHap):
#   1. hvigor builds the UNSIGNED hap AND the unsigned App Pack (.app) with
#      the repo build-profile.json5 as-is (signingConfigs stays empty —
#      nothing is injected or restored).
#   2. The SDK's hap-sign-tool signs the hap locally with the publishing
#      material.
#   3. hap-sign-tool signs the .app CONTAINER (-inForm zip) — the CLI
#      equivalent of hvigor's SignApp task. AGC (testing track included)
#      validates the CONTAINER signature: an unsigned .app is rejected as
#      991 非法软件包 (learned the hard way, 2026-10-31). The HAP inside
#      stays UNSIGNED by design (hvigor PackageApp always packs unsigned
#      haps — verified in hvigor-ohos-plugin source; AppGallery unpacks and
#      re-signs on distribution). hdc installs keep using the signed .hap
#      from step 2.
# Why not hvigor SignHap: it only accepts DevEco-ENCRYPTED passwords
# (>= 32 chars, "000000..." format); plain passwords fail with 00303116
# "The length of the storePassword or keyPassword field ... is less than 32".
# hap-sign-tool takes plain passwords, so the signing happens there.
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
# Signing material lives in build-profile.release.json5 (gitignored): the
# eight material fields (certpath / profile / storeFile / keyAlias / signAlg /
# storePassword / keyPassword) with PLAIN passwords. Never commit it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RELEASE_PROFILE="build-profile.release.json5"

die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }

[ -f "$RELEASE_PROFILE" ] || die "缺少 ${RELEASE_PROFILE}。
发布签名与调试签名不同：AGC 签发的发布证书不绑定设备白名单。
请从 AGC 下载 .cer / .p7b 并准备好 .p12，按 docs/BUILD.md 建 ${RELEASE_PROFILE}。"

# CLI 解析优先级（同 deploy.sh）：显式 DEVECO_CLI > 仓库钉死路径 > PATH。
PINNED_CLI_FILE="$ROOT/.deveco-cli-path"
resolve_deveco_cli() {
  # 诊断输出走 stderr：本函数在 $(...) 里执行，stdout 只留最终路径。
  if [ -n "${DEVECO_CLI:-}" ]; then
    if [ -x "$DEVECO_CLI" ] || command -v "$DEVECO_CLI" >/dev/null 2>&1; then
      echo "$DEVECO_CLI"
    else
      die "DEVECO_CLI 指向的 devecocli 不存在：$DEVECO_CLI"
    fi
    return
  fi
  if [ -f "$PINNED_CLI_FILE" ]; then
    local pinned; pinned="$(head -1 "$PINNED_CLI_FILE" | tr -d '[:space:]')"
    if [ -n "$pinned" ] && [ -x "$pinned" ]; then echo "$pinned"; return; fi
    warn "钉死的 devecocli 不可用（${pinned:-空文件}），回落到 PATH 查找" >&2
  fi
  echo "devecocli"
}
DEVECO_CLI="$(resolve_deveco_cli)"
command -v "$DEVECO_CLI" >/dev/null 2>&1 || die "找不到 devecocli（安装/钉路径方法见 scripts/deploy.sh）"
say "CLI：$DEVECO_CLI ($("$DEVECO_CLI" --version 2>/dev/null | head -1))"

# —— 签名材料：从 build-profile.release.json5 提取 material 字段（明文密码） ——
field() {
  grep -oE "$1:[[:space:]]*'[^']+'" "$RELEASE_PROFILE" | head -1 | sed "s/.*'\(.*\)'/\1/"
}
CERT="$(field certpath)"
P7B="$(field profile)"
KEYSTORE="$(field storeFile)"
ALIAS="$(field keyAlias)"
SIGN_ALG="$(field signAlg)"
STORE_PWD="$(field storePassword)"
KEY_PWD="$(field keyPassword)"
[ -n "$CERT" ] && [ -f "$CERT" ] || die "certpath 无效：${CERT:-未填}"
[ -n "$P7B" ] && [ -f "$P7B" ] || die "profile 无效：${P7B:-未填}"
[ -n "$KEYSTORE" ] && [ -f "$KEYSTORE" ] || die "storeFile 无效：${KEYSTORE:-未填}"
[ -n "$ALIAS" ] || die "keyAlias 未填"
[ -n "$SIGN_ALG" ] || die "signAlg 未填"
[ -n "$STORE_PWD" ] || die "storePassword 未填"
[ -n "$KEY_PWD" ] || die "keyPassword 未填"
say "材料：cert=$CERT"

# —— bundleName 双向校验（app.json5 vs profile p7b）——
# The provisioning profile embeds its own bundleName; a mismatch fails at
# install time. Catch it here with a readable message instead.
BUNDLE="$(grep -oE '"bundleName"[[:space:]]*:[[:space:]]*"[^"]+"' AppScope/app.json5 | grep -oE '"[^"]+"$' | tr -d '"')"
[ -n "$BUNDLE" ] || die "读不到 AppScope/app.json5 的 bundleName"
say "bundleName: $BUNDLE"
if strings "$P7B" | grep -q "$BUNDLE"; then
  say "profile bundleName 校验通过"
else
  die "签名 profile 里的 bundleName 与 $BUNDLE 不一致。
profile: $P7B
请在 AGC 用该 bundleName 重新生成 profile，否则安装时会校验失败。"
fi

# —— 工具链（DevEco Studio 自带；可用环境变量覆盖） ——
JAVA_BIN="${JAVA_BIN:-/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home/bin/java}"
SIGN_TOOL="${SIGN_TOOL:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar}"
[ -x "$JAVA_BIN" ] || die "找不到 java（可用 JAVA_BIN 环境变量指定）：$JAVA_BIN"
[ -f "$SIGN_TOOL" ] || die "找不到 hap-sign-tool（可用 SIGN_TOOL 环境变量指定）：$SIGN_TOOL"

# compatibleVersion = compatibleSdkVersion 的主版本号
COMPAT="$(grep -oE "compatibleSdkVersion:[[:space:]]*'[0-9]+" build-profile.json5 | head -1 | grep -oE '[0-9]+$')"
[ -n "$COMPAT" ] || die "读不到 build-profile.json5 的 compatibleSdkVersion"
say "compatibleVersion: API $COMPAT"

# —— 构建（未签名）：仓库口径的 build-profile.json5 原样使用，无注入无还原 ——
say "构建未签名 release 包（HAP + App Pack）…（含 ~225MB 载荷，较慢）"
"$DEVECO_CLI" build --build-mode release --assemble-type assembleApp

UNSIGNED="entry/build/default/outputs/default/entry-default-unsigned.hap"
SIGNED="entry/build/default/outputs/default/entry-default-signed.hap"
UNSIGNED_APP="build/outputs/default/dshharmony-default-unsigned.app"
SIGNED_APP="build/outputs/default/dshharmony-default-signed.app"
[ -f "$UNSIGNED" ] || die "构建结束但没有未签名产物：$UNSIGNED"
[ -f "$UNSIGNED_APP" ] || die "构建结束但没有未签名 App Pack：$UNSIGNED_APP"

# —— 签名（hap-sign-tool，明文密码，绕开 hvigor SignHap 的密文要求） ——
say "hap-sign-tool 本地签名…"
"$JAVA_BIN" -jar "$SIGN_TOOL" sign-app \
  -mode localSign \
  -keyAlias "$ALIAS" -keyPwd "$KEY_PWD" \
  -appCertFile "$CERT" -profileFile "$P7B" \
  -inFile "$UNSIGNED" -signAlg "$SIGN_ALG" \
  -keystoreFile "$KEYSTORE" -keystorePwd "$STORE_PWD" \
  -outFile "$SIGNED" \
  -compatibleVersion "$COMPAT" -signCode 1

# —— 给 .app 容器签名：AGC（含测试轨道）校验的是容器签名，未签报 991 非法软件包 ——
# 这是 hvigor SignApp 任务的 CLI 等价（-inForm zip）。包内 HAP 保持未签名是官方设计：
# hvigor PackageApp 装的永远是未签名 HAP，AGC 分发时才拆包重签。
say "hap-sign-tool 给 .app 容器签名…"
"$JAVA_BIN" -jar "$SIGN_TOOL" sign-app \
  -mode localSign \
  -keyAlias "$ALIAS" -keyPwd "$KEY_PWD" \
  -appCertFile "$CERT" -profileFile "$P7B" \
  -inFile "$UNSIGNED_APP" -inForm zip \
  -signAlg "$SIGN_ALG" \
  -keystoreFile "$KEYSTORE" -keystorePwd "$STORE_PWD" \
  -outFile "$SIGNED_APP"
[ -f "$SIGNED_APP" ] || die "容器签名失败：$SIGNED_APP"

# —— 校验：独立 HAP 与 .app 容器各验一次 ——
say "verify-app 校验签名（独立 HAP + .app 容器）…"
"$JAVA_BIN" -jar "$SIGN_TOOL" verify-app \
  -inFile "$SIGNED" \
  -outCertChain /tmp/dshharmony-release-verify-cert.cer \
  -outProfile /tmp/dshharmony-release-verify-profile.p7b
"$JAVA_BIN" -jar "$SIGN_TOOL" verify-app \
  -inFile "$SIGNED_APP" \
  -outCertChain /tmp/dshharmony-release-verify-app-cert.cer \
  -outProfile /tmp/dshharmony-release-verify-app-profile.p7b

say "产物（AGC 上传用 .app）：$SIGNED_APP ($(du -h "$SIGNED_APP" | cut -f1))"
say "产物（hdc 直装用 .hap）：$SIGNED ($(du -h "$SIGNED" | cut -f1))"
say "完成。发布证书不绑设备白名单，可分发到任意 HarmonyOS API ${COMPAT}+ 设备。"
echo
echo "提醒："
echo "  · AGC 提交（含测试轨道）只收 .app：上传 ${SIGNED_APP}（容器已签名，包内 HAP 按官方设计保持未签名）"
echo "  · hdc 直连安装用 .hap：$SIGNED"
echo "  · 接收方需要自己填 DeepSeek API Key（密钥不能随包分发）"
echo "  · compatibleSdkVersion 决定了最低系统版本，见 build-profile.json5"
