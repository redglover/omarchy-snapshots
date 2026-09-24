#!/bin/bash

# Argument validation for the root helpers, run against a stub `snapper` on
# PATH that records every call. Needs no root, snapper, or polkit.

# Literal $(…) and backticks below are the point: they must reach snapper unexpanded.
# shellcheck disable=SC2016

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
READ="$ROOT/helper/snapshots-read"
ADMIN="$ROOT/helper/snapshots-admin"
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
printf '#!/bin/bash\necho limine-snapper-restore "$@" >>"$SNAPPER_LOG"\n' >"$T/bin/limine-snapper-restore"
chmod +x "$T/bin/limine-snapper-restore"
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
# --- snapshots-read status
rejects "status: non-integer id" "$READ" status root 1a 0
rejects "status: negative id" "$READ" status root -1 0
rejects "status: id with range syntax" "$READ" status root 1..2 0
rejects "status: bad config" "$READ" status '../root' 1 0
rejects "status: missing id" "$READ" status root 1
accepts "status: valid call" $'-c\nroot\nstatus\n5..0' "$READ" status root 5 0
accepts "list: valid config" $'-c\nroot\n--jsonout\nlist' "$READ" list root

# --- snapshots-admin diff
rejects "diff: '..' path" "$ADMIN" diff root 5 0 /etc/../etc/shadow
rejects "diff: relative path" "$ADMIN" diff root 5 0 etc/motd
rejects "diff: path absent from status" "$ADMIN" diff root 5 0 /etc/shadow
rejects "diff: prefix of a changed path" "$ADMIN" diff root 5 0 /etc/mot
rejects "diff: non-integer id" "$ADMIN" diff root five 0 /etc/motd
rejects "diff: bad config" "$ADMIN" diff 'root$(id)' 5 0 /etc/motd
rejects "diff: two paths" "$ADMIN" diff root 5 0 /etc/motd /etc/gone
accepts "diff: valid call" $'-c\nroot\ndiff\n5..0\n/etc/motd' "$ADMIN" diff root 5 0 /etc/motd
accepts "diff: path with a space stays one argument" $'-c\nroot\ndiff\n5..0\n/etc/with space' "$ADMIN" diff root 5 0 "/etc/with space"

mkdir -p "$T/.snapshots/5/snapshot"
head -c 300000 /dev/zero >"$T/.snapshots/5/snapshot/big.bin"
: >"$SNAPPER_LOG"
set +e
"$ADMIN" diff big 5 0 "$T/big.bin" >"$T/out" 2>&1
code=$?
set -e
if (( code == 3 )) && ! grep -qx diff "$SNAPPER_LOG"; then
  pass "diff: file over 256 KiB exits 3 without diffing"
else
  fail "diff: file over 256 KiB (exit $code)"
fi

# --- snapshots-admin undo
rejects "undo: '..' path" "$ADMIN" undo root 5 /etc/motd /etc/../etc/shadow
rejects "undo: relative path" "$ADMIN" undo root 5 etc/motd
rejects "undo: one path absent from status" "$ADMIN" undo root 5 /etc/motd /etc/shadow
rejects "undo: no paths" "$ADMIN" undo root 5
rejects "undo: snapshot 0" "$ADMIN" undo root 0 /etc/motd
rejects "undo: non-integer id" "$ADMIN" undo root 5x /etc/motd
accepts "undo: undochange gets every path as its own argument" $'-c\nroot\nundochange\n5..0\n/etc/motd\n/etc/with space\n/etc/gone' \
  "$ADMIN" undo root 5 /etc/motd "/etc/with space" /etc/gone
create_line=$(grep -nx create "$SNAPPER_LOG" | cut -d: -f1)
undo_line=$(grep -nx undochange "$SNAPPER_LOG" | cut -d: -f1)
if [[ -n $create_line && -n $undo_line ]] && (( create_line < undo_line )) \
  && grep -Fxq "before restore from #5" "$SNAPPER_LOG" && [[ $(cat "$T/out") == 42 ]]; then
  pass "undo: creates a 'before restore' snapshot first and prints its number"
else
  fail "undo: 'before restore' snapshot"
fi

# --- snapshots-admin create / delete / important
rejects "create: empty description" "$ADMIN" create root ""
rejects "create: newline in description" "$ADMIN" create root $'two\nlines'
rejects "create: description over 200 characters" "$ADMIN" create root "$(printf 'x%.0s' {1..201})"
rejects "create: bad config" "$ADMIN" create 'ROOT' "ok"
accepts "create: description with shell metacharacters stays literal" $'-c\nroot\ncreate\n-c\nnumber\n-p\n-d\n$(reboot); `id` & "x"' \
  "$ADMIN" create root '$(reboot); `id` & "x"'
rejects "delete: snapshot 0" "$ADMIN" delete root 0
rejects "delete: non-integer id" "$ADMIN" delete root 3 '4;rm'
rejects "delete: no ids" "$ADMIN" delete root
accepts "delete: pre/post pair" $'-c\nroot\ndelete\n2\n3' "$ADMIN" delete root 2 3
rejects "important: bad value" "$ADMIN" important root maybe 4
rejects "important: non-integer id" "$ADMIN" important root yes 4.5
accepts "important: sets userdata" $'-c\nroot\nmodify\n-u\nimportant=yes\n4' "$ADMIN" important root yes 4

# --- booted / promote (read the real /proc/cmdline)
rejects "booted: extra argument" "$READ" booted 5
rejects "promote: extra argument" "$ADMIN" promote 5
if [[ $("$READ" booted) =~ ^(none|snapshot\ [0-9]+)$ ]]; then
  pass "booted: prints 'none' or 'snapshot N'"
else
  fail "booted: unexpected output"
fi
if [[ $("$READ" booted) == none ]]; then
  : >"$SNAPPER_LOG"
  if ! "$ADMIN" promote >/dev/null 2>&1 && ! grep -q limine "$SNAPPER_LOG"; then
    pass "promote: refused when not booted into a snapshot"
  else
    fail "promote: ran outside a snapshot"
  fi
fi

echo
if (( failures )); then
  echo "helper-args-test: $failures failed"
  exit 1
fi
echo "helper-args-test: ok"
