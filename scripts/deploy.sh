#!/usr/bin/env bash
#
# 一键把 dshharmony 装到真机：检查设备 → 登录 → 签名 → 构建 → 安装启动。
#
# 用法：
#   bash scripts/deploy.sh                 # 自动选第一台设备
#   bash scripts/deploy.sh <serial>        # 指定设备序列号
#
# 前置：手机已开「开发者选项 → USB 调试」，USB 已连接并授权。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# 开源口径：仓库内 build-profile.json5 不带签名。本脚本注入签名构建后自动还原，
# 崩溃/中断由 trap 兜底，避免签名材料残留在已入库文件里。
STRIPPED_BAK="/tmp/dshharmony-build-profile.stripped.json5"
INJECTED_SIGNING=0
restore_profile() {
  if [ "$INJECTED_SIGNING" = "1" ] && [ -f "$STRIPPED_BAK" ]; then
    mv "$STRIPPED_BAK" build-profile.json5
    echo "已还原无签名的 build-profile.json5（签名保留在 build-profile.signing.json5）"
  fi
}
trap restore_profile EXIT

DEVICE="${1:-}"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# CLI 解析优先级：显式 DEVECO_CLI > 仓库钉死路径 > PATH。
# 本机装过多份 devecocli（homebrew / DevEco Code 自带 / managed node），PATH 顺序会漂，
# 所以钉死一份到 .deveco-cli-path（gitignored，本机专用）。
PINNED_CLI_FILE="$ROOT/.deveco-cli-path"
resolve_deveco_cli() {
  # 所有诊断输出走 stderr：本函数在 $(...) 里执行，stdout 只留最终路径。
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

# 1. 工具检查
command -v "$DEVECO_CLI" >/dev/null 2>&1 || die "找不到 devecocli。先装：
  npm install -g @deveco/deveco-cli@latest
或把一份装的绝对路径写进 .deveco-cli-path（gitignored）：
  echo /path/to/devecocli > .deveco-cli-path"
say "CLI：$DEVECO_CLI ($("$DEVECO_CLI" --version 2>/dev/null | head -1))"

# 2. 设备检查
say "检查已连接设备…"
DEVICES="$("$DEVECO_CLI" device list 2>&1 || true)"
echo "$DEVICES" | sed 's/^/    /'
if echo "$DEVICES" | grep -qi "No active devices"; then
  die "没有可用设备。请确认：
  1) 手机已开 设置 → 系统 → 开发者选项 → USB 调试
  2) USB 线已连接，手机弹窗点了「允许」
  3) 再跑一次 hdc list targets 能看到序列号
也可以用模拟器：devecocli emulator start <name>"
fi

if [ -z "$DEVICE" ]; then
  # 设备名含空格（如 "HUAWEI Mate 90 Pro Max 典藏版"），列位置不可靠：
  # 只认「同一行里既有序列号形态、又有 device 字样」的数据行，表头/提示行一律跳过。
  DEVICE="$(echo "$DEVICES" \
    | grep -vE '^(Name[[:space:]]|-)' \
    | awk '{
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^[0-9A-Za-z]{8,}$/ && ($i ~ /[0-9]/) && ($(i+1) == "device")) {
            print $i; exit
          }
        }
      }')"
  [ -n "$DEVICE" ] || die "无法从设备列表解析序列号，请手动传入：bash scripts/deploy.sh <serial>"
fi
say "目标设备：$DEVICE"

# 3. 登录（签名必需，华为账号）
# 坑：auth status 未登录时退出码仍是 0，且输出 "Not logged in" 本身就含 "logged in" 子串，
# 所以必须先排除 "Not logged in" 再匹配，否则登录分支永远不触发（已实测）。
AUTH_STATUS="$("$DEVECO_CLI" auth status 2>&1 || true)"
if echo "$AUTH_STATUS" | grep -qiE '\bnot logged in\b' \
   || ! echo "$AUTH_STATUS" | grep -qiE '\blogged in\b'; then
  say "尚未登录，开始登录（会打开浏览器或给出设备码）…"
  "$DEVECO_CLI" auth login || die "登录失败。签名需要有效华为账号：devecocli auth status 查状态，devecocli auth team 查团队。"
  AUTH_STATUS="$("$DEVECO_CLI" auth status 2>&1 || true)"
  echo "$AUTH_STATUS" | grep -qiE '\bnot logged in\b' && die "登录后仍未生效，请手动执行 devecocli auth login"
fi
say "账号状态：$(echo "$AUTH_STATUS" | head -1)"

# 4. 签名材料（仅在缺失时检出/生成；构建后由 trap 还原开源口径）
if grep -qE 'signingConfigs:[[:space:]]*\[[[:space:]]*\]' build-profile.json5; then
  if [ -f build-profile.signing.json5 ]; then
    say "检出本地签名备份 → build-profile.json5"
    cp build-profile.json5 "$STRIPPED_BAK"
    cp build-profile.signing.json5 build-profile.json5
    INJECTED_SIGNING=1
  else
    say "生成签名材料（首次需要，会写入 build-profile.json5）…"
    cp build-profile.json5 "$STRIPPED_BAK"
    "$DEVECO_CLI" signature generate || die "签名生成失败。
常见原因：
  · bundleName 在 AppGallery Connect 已被占用 → 改 AppScope/app.json5 的 bundleName 为更独特的名字
  · 账号未实名 / 团队权限不足 → devecocli auth team
  · 设备 UDID 未注册 → 确认手机已连接后再生成"
    cp build-profile.json5 build-profile.signing.json5
    INJECTED_SIGNING=1
  fi
else
  say "已有签名配置，跳过生成（要重建加 --force：devecocli signature generate --force）"
fi

# 5. 构建
say "构建 HAP…（含 ~225MB 载荷，首次较慢）"
"$DEVECO_CLI" build

# 6. 安装并启动
say "安装并启动…"
"$DEVECO_CLI" run --device "$DEVICE" --skip-build

say "完成。若界面停在「等待 Node 主循环就绪」：
  devecocli log            # 看应用日志
  应用内 设置 → 诊断      # 看 stage / node.log / 崩溃记录
首次启动要解包 225MB 载荷，约 60–90 秒，之后冷启约 3 秒。"
