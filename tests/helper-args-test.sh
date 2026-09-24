#!/bin/bash

# Argument validation for the root helpers, run against a stub `snapper` on
# PATH that records every call. Needs no root, snapper, or polkit.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
READ="$ROOT/helper/snapshots-read"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

export SNAPPER_LOG="$T/snapper.log"
export STUB_DIR="$T"
mkdir -p "$T/bin"
cat >"$T/bin/snapper" <<'STUB'
#!/bin/bash
{ echo "--"; printf '%s\n' "$@"; } >>"$SNAPPER_LOG"
case " $* " in
*" list-configs "*) printf 'config,subvolume\nroot,/\nbig,%s\n' "$STUB_DIR" ;;
*" status "*) printf '%s\n' "c..... /etc/motd" "+..... /etc/with space" "-..... /etc/gone" "c..... $STUB_DIR/big.bin" ;;
*" create "*) echo 42 ;;
*" list "*) echo '{"root":[]}' ;;
esac
STUB
chmod +x "$T/bin/snapper"
export PATH="$T/bin:$PATH"

failures=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; failures=$((failures + 1)); }

# Last recorded snapper call, one argv element per line.
last_call() { awk '/^--$/ { n++; out = ""; next } { out = out $0 "\n" } END { printf "%s", out }' "$SNAPPER_LOG"; }

rejects() {
  local desc=$1
  shift
  : >"$SNAPPER_LOG"
  if "$@" >/dev/null 2>"$T/err"; then
    fail "$desc (accepted)"
  # Validation may read list-configs and status; anything else means the
  # bad argument got through to a real action.
  elif grep -qxE 'list|create|undochange|diff|delete|modify' "$SNAPPER_LOG"; then
    fail "$desc (reached snapper before rejecting)"
  elif [[ ! -s "$T/err" ]]; then
    fail "$desc (no error message)"
  else
    pass "$desc"
  fi
}

accepts() {
  local desc=$1 expected=$2
  shift 2
  : >"$SNAPPER_LOG"
  if ! "$@" >"$T/out" 2>"$T/err"; then
    fail "$desc (exit $?: $(cat "$T/err"))"
  elif [[ "$(last_call)" != "$expected" ]]; then
    fail "$desc (got: $(last_call | tr '\n' ' '))"
  else
    pass "$desc"
  fi
}

# --- snapshots-read list
rejects "list: config with shell metacharacters" "$READ" list 'root;id'
rejects "list: uppercase config" "$READ" list Root
rejects "list: config not in list-configs" "$READ" list home
rejects "list: missing config" "$READ" list
rejects "list: extra argument" "$READ" list root extra
rejects "unknown command" "$READ" rm -rf /
accepts "list: valid config" $'-c\nroot\n--jsonout\nlist' "$READ" list root

echo
if (( failures )); then
  echo "helper-args-test: $failures failed"
  exit 1
fi
echo "helper-args-test: ok"
