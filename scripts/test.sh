#!/usr/bin/env bash
#
# One entry point for every check this repo has.
#
# Why this exists: `devecocli` has no `test` command, and the three test paths
# this project needs live in three unrelated places (node --test inside the
# payload tree, hvigor for LocalUnit, `aa test` on the device). Each has its own
# output format and its own trap. Those traps are written down below, next to
# the code that works around them.
#
# Usage:
#   bash scripts/test.sh              # everything
#   bash scripts/test.sh unit         # payload plugins (node --test)
#   bash scripts/test.sh arkts        # ArkTS static check
#   bash scripts/test.sh local        # LocalUnit tests (host-side, hvigor)
#   bash scripts/test.sh device       # on-device Hypium tests (ohosTest)
#   bash scripts/test.sh ui "计划"    # AI visual verification (devecocli verify)
#
# Options:
#   --device <serial>   target device (default: first connected)
#   --no-jitless        skip the extra --jitless pass on the payload suites
#   --no-signing        assume build-profile.json5 already carries signing

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
DEVECO_HOME=/Applications/DevEco-Studio.app/Contents
export DEVECO_SDK_HOME="$DEVECO_HOME/sdk"
export NODE_HOME="$DEVECO_HOME/tools/node"
export JAVA_HOME="$DEVECO_HOME/jbr/Contents/Home"
HVIGORW="$DEVECO_HOME/tools/hvigor/bin/hvigorw"

PAYLOAD="$ROOT/.build/payload/profile-ohos/profiles/ohos/node_modules/@ohos"

DEVICE_SERIAL=""
RUN_JITLESS=1
NEED_SIGNING=1

# ---------------------------------------------------------------- reporting

FAILED_SUITES=()
PASSED_SUITES=()
SKIPPED_SUITES=()

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; PASSED_SUITES+=("$*"); }
bad()  { printf '\033[1;31m  ✗\033[0m %s\n' "$*"; FAILED_SUITES+=("$*"); }
skip() { printf '\033[1;33m  –\033[0m %s\n' "$*"; SKIPPED_SUITES+=("$*"); }

summary() {
  echo
  echo "──────────────────────────────────────────"
  if [ ${#FAILED_SUITES[@]} -eq 0 ]; then
    printf '\033[1;32m全部通过\033[0m'
  else
    printf '\033[1;31m%d 项失败\033[0m' "${#FAILED_SUITES[@]}"
  fi
  printf '（通过 %d' "${#PASSED_SUITES[@]}"
  [ ${#SKIPPED_SUITES[@]} -gt 0 ] && printf '，跳过 %d' "${#SKIPPED_SUITES[@]}"
  printf '）\n'
  if [ ${#FAILED_SUITES[@]} -gt 0 ]; then
    for s in "${FAILED_SUITES[@]}"; do echo "  ✗ $s"; done
  fi
  if [ ${#SKIPPED_SUITES[@]} -gt 0 ]; then
    for s in "${SKIPPED_SUITES[@]}"; do echo "  – $s"; done
  fi
  echo "──────────────────────────────────────────"
  [ ${#FAILED_SUITES[@]} -eq 0 ] || exit 1
}

# ---------------------------------------------------------------- signing
#
# TRAP: never restore build-profile.json5 from a file backup. An earlier
# attempt copied the *signed* file aside and copied it back, which wrote the
# real store/key passwords into a tracked file. git is the only trustworthy
# baseline for "no signing configured".

restore_signing() {
  if [ "$NEED_SIGNING" = "1" ]; then
    git checkout -- build-profile.json5 2>/dev/null || true
  fi
}

inject_signing() {
  [ "$NEED_SIGNING" = "1" ] || return 0
  local src="build-profile.signing.json5"
  if [ ! -f "$src" ]; then
    return 1
  fi
  python3 - "$src" <<'PY'
import re, sys
sig = open(sys.argv[1]).read()
m = re.search(r'signingConfigs:\s*\[(.*?)\n\s*\],', sig, re.S)
if not m:
    sys.exit("cannot find signingConfigs block in " + sys.argv[1])
p = 'build-profile.json5'
s = open(p).read()
if 'signingConfigs: [],' not in s:
    sys.exit("build-profile.json5 is not in the stripped state; run git checkout first")
open(p, 'w').write(s.replace('signingConfigs: [],', m.group(0)))
PY
}

trap restore_signing EXIT

# ---------------------------------------------------------------- suites

suite_unit() {
  say "payload 插件单测（node --test）"
  if [ ! -d "$PAYLOAD" ]; then
    skip "payload 树不存在，先跑 node scripts/assemble-payload.mjs"
    return
  fi
  local suites="dsh-tool-fs-search-js dsh-ptc-runtime-vm dsh-credentials-live"
  for name in $suites; do
    local dir="$PAYLOAD/$name"
    if [ ! -d "$dir/test" ]; then
      skip "${name}（无 test 目录）"
      continue
    fi
    # node --test reports pass/fail properly and exits non-zero, so the exit
    # code is the signal here — unlike hvigor below.
    local out
    out=$( cd "$dir" && node --test test/*.test.mjs 2>&1 )
    if [ $? -eq 0 ]; then
      # node --test prints "ℹ pass N" on newer builds and "# pass N" on older
      # ones; accept either rather than pinning to one formatter.
      local n; n=$(printf '%s\n' "$out" | grep -E '(^ℹ|^#) pass [0-9]+' | grep -oE '[0-9]+' | tail -1)
      ok "$name ${n:+($n 通过)}"
    else
      bad "$name"
      printf '%s\n' "$out" | grep -E '^not ok|^✖|(^ℹ|^#) fail' | head -8
    fi
    if [ "$RUN_JITLESS" = "1" ] && [ "$name" = "dsh-ptc-runtime-vm" ]; then
      # --jitless proves the engine has no WASM path, which is the device's
      # only execution mode. A suite that passes only with JIT is a suite that
      # will fail on the phone.
      local jout
      jout=$( cd "$dir" && node --jitless --test test/*.test.mjs 2>&1 )
      if [ $? -eq 0 ]; then
        ok "$name --jitless"
      else
        bad "$name --jitless"
        printf '%s\n' "$jout" | grep -E '^not ok|^✖' | head -5
      fi
    fi
  done
}

suite_arkts() {
  say "ArkTS 静态检查"
  local files
  files=$(git ls-files '*.ets' | tr '\n' ' ')
  if [ -z "$files" ]; then
    skip "没有 .ets 文件"
    return
  fi
  local out
  out=$(devecocli check arkts $files 2>&1)
  if printf '%s' "$out" | grep -qE 'No errors found'; then
    ok "arkts（$(printf '%s' "$out" | grep -oE 'in [0-9]+ file' | grep -oE '[0-9]+' | head -1) 个文件）"
  else
    bad "arkts"
    printf '%s\n' "$out" | grep -E 'error:' | head -10
  fi
}

suite_local() {
  say "本地单测 LocalUnit（hvigor test）"
  if [ ! -x "$HVIGORW" ]; then
    skip "找不到 hvigorw"
    return
  fi
  local log; log=$(mktemp)
  "$HVIGORW" --mode module -p module=entry@default -p product=default test \
      --no-daemon > "$log" 2>&1
  local rc=$?
  # TRAP: hvigor exits 0 even when assertions fail — a failing case is only an
  # "ERROR: Error in <case>" line in the log. Verified by planting a failing
  # assertion: exit stayed 0. So the exit code must not be trusted here.
  local fails
  fails=$(grep -cE 'ERROR: Error in ' "$log" 2>/dev/null || true)
  fails=${fails:-0}
  if [ "$rc" -ne 0 ] && [ "$fails" -eq 0 ]; then
    bad "local（构建失败）"
    grep -E 'ERROR' "$log" | grep -v 'ArkTS:WARN' | head -8
  elif [ "$fails" -gt 0 ]; then
    bad "local（$fails 个断言失败）"
    grep -E 'ERROR: Error in ' "$log" | head -10
  else
    local cov=""
    local rep="entry/.test/default/outputs/test/reports/coverageReport.json"
    if [ -f "$rep" ]; then
      cov=$(python3 -c "
import json,sys
try:
    d=json.load(open('$rep'))
    s=d.get('summary') or d
    for k in ('lines','statements'):
        v=s.get(k) if isinstance(s,dict) else None
        if isinstance(v,dict) and 'pct' in v:
            print(f\"{v['pct']:.1f}% 行覆盖\"); break
except Exception:
    pass
" 2>/dev/null)
    fi
    ok "local${cov:+（${cov}）}"
  fi
  rm -f "$log"
}

detect_device() {
  [ -n "$DEVICE_SERIAL" ] && { echo "$DEVICE_SERIAL"; return; }
  local out
  out=$("$HDC" list targets 2>/dev/null | grep -vE '^\s*$|Empty' | head -1 | tr -d '\r')
  echo "$out"
}

bundle_name() {
  grep -oE '"bundleName"[[:space:]]*:[[:space:]]*"[^"]+"' AppScope/app.json5 \
    | grep -oE '"[^"]+"$' | tr -d '"'
}

suite_device() {
  say "设备端 Hypium 测试（ohosTest）"
  local sn; sn=$(detect_device)
  if [ -z "$sn" ]; then
    skip "device（无设备连接）"
    return
  fi
  echo "  设备: $sn"

  if [ ! -f build-profile.signing.json5 ]; then
    skip "device（缺 build-profile.signing.json5，无法构建测试包）"
    return
  fi
  if ! inject_signing; then
    bad "device（注入签名失败）"
    return
  fi

  local log; log=$(mktemp)
  say "  构建 ohosTest HAP…"
  devecocli build --modules entry@ohosTest > "$log" 2>&1
  local rc=$?
  restore_signing
  if [ "$rc" -ne 0 ]; then
    bad "device（ohosTest 构建失败）"
    grep -E 'ERROR|error:' "$log" | head -10
    rm -f "$log"; return
  fi
  rm -f "$log"

  local hap="entry/build/default/outputs/ohosTest/entry-ohosTest-signed.hap"
  local app="entry/build/default/outputs/default/entry-default-signed.hap"
  if [ ! -f "$hap" ]; then
    bad "device（找不到 ${hap}）"
    return
  fi

  # The test module only exists once the test HAP is installed; the app HAP has
  # to be there too or `aa test` has no bundle to attach to.
  if [ -f "$app" ]; then
    "$HDC" -t "$sn" install -r "$app" > /dev/null 2>&1
  fi
  if ! "$HDC" -t "$sn" install -r "$hap" > /dev/null 2>&1; then
    bad "device（测试 HAP 安装失败）"
    return
  fi

  local bundle module
  bundle=$(bundle_name)
  module="entry_test"

  # Installing a 350MB app pack leaves the bundle briefly unavailable; `aa test`
  # right after it intermittently answers "[Fail][E001005] Device not found or
  # connected" instead of a report. Settle, then retry once if the report is
  # missing — a real assertion failure still reports, so this cannot mask one.
  sleep 2
  local out attempt
  for attempt in 1 2 3; do
    out=$("$HDC" -t "$sn" shell "aa test -b $bundle -m $module -s unittest OpenHarmonyTestRunner -s timeout 60000" 2>&1)
    printf '%s' "$out" | grep -q 'OHOS_REPORT_RESULT' && break
    printf '%s' "$out" | grep -q 'E001005' || break
    echo "  设备未就绪，重试 $attempt/3…"
    sleep 3
  done

  local line
  line=$(printf '%s\n' "$out" | grep -E 'OHOS_REPORT_RESULT' | tail -1)
  local code
  code=$(printf '%s\n' "$out" | grep -E 'TestFinished-ResultCode' | tail -1 | grep -oE '\-?[0-9]+')
  if [ -n "$line" ]; then
    local runs fails errs pass
    runs=$(printf '%s' "$line" | grep -oE 'Tests run: [0-9]+' | grep -oE '[0-9]+')
    fails=$(printf '%s' "$line" | grep -oE 'Failure: [0-9]+' | grep -oE '[0-9]+')
    errs=$(printf '%s' "$line" | grep -oE 'Error: [0-9]+' | grep -oE '[0-9]+')
    pass=$(printf '%s' "$line" | grep -oE 'Pass: [0-9]+' | grep -oE '[0-9]+')
    if [ "${fails:-0}" -eq 0 ] && [ "${errs:-0}" -eq 0 ] && [ "${code:-1}" = "0" ]; then
      ok "device（$runs 个用例，$pass 通过）"
    else
      bad "device（运行 ${runs}，失败 ${fails:-?}，错误 ${errs:-?}）"
      printf '%s\n' "$out" | grep -E 'OHOS_REPORT_STATUS: test=' | head -10
    fi
  else
    bad "device（没有拿到测试结果）"
    printf '%s\n' "$out" | tail -8
  fi
}

suite_ui() {
  local plan="${1:-}"
  if [ -z "$plan" ]; then
    skip "ui（需要传入自然语言测试计划）"
    return
  fi
  say "AI 视觉验证（devecocli verify）"
  local sn; sn=$(detect_device)
  if [ -z "$sn" ]; then
    skip "ui（无设备连接）"
    return
  fi
  local out
  out=$(devecocli verify --test-plan "$plan" --bundle-name "$(bundle_name)" --device "$sn" 2>&1)
  if [ $? -eq 0 ]; then
    ok "ui"
    printf '%s\n' "$out" | tail -8
  else
    bad "ui"
    printf '%s\n' "$out" | tail -12
  fi
}

# ---------------------------------------------------------------- main

TARGETS=()
UI_PLAN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --device) DEVICE_SERIAL="$2"; shift 2 ;;
    --no-jitless) RUN_JITLESS=0; shift ;;
    --no-signing) NEED_SIGNING=0; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)
      # `ui` is the only target that takes an argument; consume the next word
      # as the plan rather than as a second target name.
      if [ "$1" = "ui" ] && [ $# -gt 1 ]; then
        UI_PLAN="$2"; TARGETS+=("ui"); shift 2
      else
        TARGETS+=("$1"); shift
      fi
      ;;
  esac
done

[ ${#TARGETS[@]} -gt 0 ] || TARGETS=(all)

for t in "${TARGETS[@]}"; do
  case "$t" in
    all)    suite_unit; suite_arkts; suite_local; suite_device ;;
    unit)   suite_unit ;;
    arkts)  suite_arkts ;;
    local)  suite_local ;;
    device) suite_device ;;
    ui)     suite_ui "$UI_PLAN" ;;
    *)      printf 'unknown target: %s\n' "$t" >&2; exit 2 ;;
  esac
done

summary
