#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/run-dsh-harmony.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "assertion failed: expected output to contain '$needle'" >&2
    echo "got: $haystack" >&2
    exit 1
  fi
}

# Test: fails when no targets are connected.
cat >"$tmp_dir/hdc" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "list" && "$2" == "targets" ]]; then
  echo "Empty"
  exit 0
fi
echo "unexpected invocation: $*" >&2
exit 1
EOF
chmod +x "$tmp_dir/hdc"

set +e
output="$(PATH="$tmp_dir:$PATH" "$SCRIPT" --help 2>&1)"
status=$?
set -e
if [[ $status -eq 0 ]]; then
  echo "expected non-zero exit when no targets are connected" >&2
  exit 1
fi
assert_contains "$output" "no HarmonyOS targets detected via hdc"

# Test: forwards command through hdc shell dsh.
cat >"$tmp_dir/hdc" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "list" && "$2" == "targets" ]]; then
  echo "127.0.0.1:5555"
  exit 0
fi
if [[ "$1" == "shell" ]]; then
  shift
  printf 'shell:%s\n' "$*"
  exit 0
fi
echo "unexpected invocation: $*" >&2
exit 1
EOF
chmod +x "$tmp_dir/hdc"

output="$(PATH="$tmp_dir:$PATH" "$SCRIPT" --version)"
assert_contains "$output" "shell:dsh --version"

echo "ok"
