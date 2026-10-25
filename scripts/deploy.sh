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

DEVECO_CLI="${DEVECO_CLI:-devecocli}"
DEVICE="${1:-}"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# 1. 工具检查
command -v "$DEVECO_CLI" >/dev/null 2>&1 || die "找不到 devecocli。先装：
  npm install -g @deveco/deveco-cli@stable
或把已装的目录加进 PATH：
  export PATH=\"/Users/apple/.workbuddy-ai/binaries/node/versions/22.22.2-6/bin:\$PATH\""

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
  DEVICE="$(echo "$DEVICES" | grep -oE '\b[0-9A-Za-z]{8,}\b' | head -1 || true)"
  [ -n "$DEVICE" ] || die "无法从设备列表解析序列号，请手动传入：bash scripts/deploy.sh <serial>"
fi
say "目标设备：$DEVICE"

# 3. 登录（签名必需，华为账号）
if ! "$DEVECO_CLI" auth status 2>&1 | grep -qi "logged in"; then
  say "尚未登录，开始登录（会打开浏览器或给出设备码）…"
  "$DEVECO_CLI" auth login
fi
say "账号状态：$("$DEVECO_CLI" auth status 2>&1 | head -1)"

# 4. 签名材料（只在缺失时生成）
if grep -q '"signingConfigs": *\[\s*\]' build-profile.json5; then
  say "生成签名材料（首次需要，会写入 build-profile.json5）…"
  "$DEVECO_CLI" signature generate || die "签名生成失败。
常见原因：
  · bundleName 在 AppGallery Connect 已被占用 → 改 AppScope/app.json5 的 bundleName 为更独特的名字
  · 账号未实名 / 团队权限不足 → devecocli auth team
  · 设备 UDID 未注册 → 确认手机已连接后再生成"
else
  say "已有签名配置，跳过生成（要重建加 --force：devecocli signature generate --force）"
fi

# 5. 构建
say "构建 HAP…（含 156MB 载荷，首次较慢）"
"$DEVECO_CLI" build

# 6. 安装并启动
say "安装并启动…"
"$DEVECO_CLI" run --device "$DEVICE" --skip-build

say "完成。若界面停在「等待 Node 主循环就绪」：
  devecocli log            # 看应用日志
  应用内 设置 → 诊断      # 看 stage / node.log / 崩溃记录
首次启动要解包 156MB 载荷，约 60–75 秒，之后冷启约 3 秒。"
