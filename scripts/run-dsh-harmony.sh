#!/usr/bin/env bash
set -euo pipefail

if ! command -v hdc >/dev/null 2>&1; then
  echo "error: hdc is required but was not found in PATH" >&2
  exit 1
fi

HDC_CMD=(hdc)
if [[ -n "${HDC_SERIAL:-}" ]]; then
  HDC_CMD+=( -t "$HDC_SERIAL" )
fi

TARGETS="$("${HDC_CMD[@]}" list targets 2>/dev/null || true)"
if [[ -z "$TARGETS" || "$TARGETS" == "Empty" ]]; then
  echo "error: no HarmonyOS targets detected via hdc" >&2
  exit 1
fi

exec "${HDC_CMD[@]}" shell dsh "$@"
