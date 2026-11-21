#!/usr/bin/env bash
# Regression tests for jx: tests/run.sh
# jx runs against fake journalctl, sudo and coredumpctl commands, so the tests
# need neither a journal nor root. The fake journalctl logs its arguments to
# $FAKE/calls and answers from files in $FAKE. Needs bash, jq and script(1).
# The fake commands and the bash -c checks are single-quoted on purpose: their
# $names expand when they run, not here.
# shellcheck disable=SC2016
set -uo pipefail

JX=$(cd -- "$(dirname -- "$0")/.." && pwd)/jx
FAKE=$(mktemp -d) || exit 1
trap 'rm -rf -- "$FAKE"' EXIT
mkdir "$FAKE/bin"
export FAKE TZ=UTC LC_ALL=C.UTF-8 NO_COLOR=1 JX_STYLE=columns
unset JX_NOPAGER JX_PAGER JX_TOP LESSSECURE LESSCHARSET

cat > "$FAKE/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/calls"
if [[ -e $FAKE/fail ]]; then echo "journalctl: simulated failure" >&2; exit 1; fi
case " $* " in
  *" --list-boots "*) echo "-1 b0000000000000000000000000000001 Sat 2026-11-14 12:14:35 UTC Fri 2026-11-20 15:02:52 UTC" ;;
  *" -o export "*)    echo "_BOOT_ID=b0000000000000000000000000000001" ;;
  *" -o cat "*)       cat -- "$FAKE/target" 2>/dev/null || true ;;
  *" -o json "*)      cat -- "$FAKE/entries" ;;
  *)                  echo "short output" ;;
esac
EOF
printf '#!/usr/bin/env bash\n[[ $1 == -v ]] || exec "$@"\n' > "$FAKE/bin/sudo"
printf '#!/bin/sh\necho "No coredumps found." >&2\nexit 1\n' > "$FAKE/bin/coredumpctl"
printf '#!/bin/sh\ncat >/dev/null\necho "less LESSSECURE=${LESSSECURE-unset} LESSSECURE_ALLOW=${LESSSECURE_ALLOW-unset} LESSCHARSET=${LESSCHARSET-unset}"\n' > "$FAKE/bin/less"
chmod +x "$FAKE"/bin/*

pass=0 fail=0 skip=0
ok()   { pass=$((pass + 1)); printf 'ok    %s\n' "$1"; }
skip() { skip=$((skip + 1)); printf 'skip  %s (%s)\n' "$1" "$2"; }
bad()  { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; sed 's/^/      /' "$FAKE/out" "$FAKE/err" | head -20; }
# check NAME CONDITION... - pass when the condition (a command) succeeds
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
jx()   { : > "$FAKE/calls"; PATH="$FAKE/bin:$PATH" "$JX" "$@" > "$FAKE/out" 2> "$FAKE/err"; }
has()  { grep -qF -- "$1" "$FAKE/${2:-out}"; }
hasnt() { ! has "$@"; }
entries() { printf '%s\n' "$@" > "$FAKE/entries"; }
T='"__REALTIME_TIMESTAMP":"1763650000000000","_BOOT_ID":"b1"'

# ---------------------------------------------------------------- columns view

entries "{$T,\"PRIORITY\":\"3\",\"SYSLOG_IDENTIFIER\":\"app\",\"MESSAGE\":[97,27,91,51,49,109,114,101,100,27,91,48,109,32,27,93,48,59,116,105,116,108,101,7,120,32,7,32,1,32,155]}" \
        "{$T,\"SYSLOG_IDENTIFIER\":\"app\",\"MESSAGE\":[104,105,27,91,49,109,33,9,116,97,98]}" \
        "{$T,\"SYSLOG_IDENTIFIER\":\"app\",\"MESSAGE\":\"user=‮root​ ok\"}"
jx --no-pager boot
check "escape sequences are dropped, control characters shown as ^X" has 'ared x ^G ^A �'
check "plain ASCII bytes are decoded directly" has $'hi!\ttab'
check "text-direction and invisible characters are shown as <U+XXXX>" has 'user=<U+202E>root<U+200B> ok'
check "nothing reaches the terminal as ESC" hasnt $'\e'

entries "{$T,\"SYSLOG_IDENTIFIER\":\"kernel\",\"_TRANSPORT\":\"journal\",\"_COMM\":\"python3\",\"MESSAGE\":\"Out of memory\"}" \
        "{$T,\"SYSLOG_IDENTIFIER\":\"kernel\",\"_TRANSPORT\":\"kernel\",\"MESSAGE\":\"Linux version\"}" \
        "{$T,\"SYSLOG_IDENTIFIER\":\"x\n12:00:00  INFO   sshd\",\"MESSAGE\":\"Accepted publickey for root\"}"
jx --no-pager boot
check "a program posing as the kernel is shown with its process name" has 'kernel(python3)      Out of memory'
check "the real kernel is shown as kernel" has 'kernel               Linux version'
check "a newline in a source name cannot start a line" \
  bash -c '! grep -q "^12:00:00" "$1" && grep -qF "x^J12:00:00" "$1"' _ "$FAKE/out"

jq -nc '{__REALTIME_TIMESTAMP: "1763650000000000", SYSLOG_IDENTIFIER: "big",
         MESSAGE: [range(100000) | (27, 91, 109)]}' > "$FAKE/entries"
start=$SECONDS
jx --no-pager boot
check "a huge binary message is cut and formatted in time" \
  bash -c 'grep -qF "… [cut, 300000 bytes]" "$1" && (( $2 < 10 ))' _ "$FAKE/out" $((SECONDS - start))

# ---------------------------------------------------------------- top

entries "{$T,\"PRIORITY\":\"6\",\"SYSLOG_IDENTIFIER\":\"sshd\"}" "{$T,\"PRIORITY\":\"4\",\"SYSLOG_IDENTIFIER\":\"sshd\"}" \
        "{$T,\"PRIORITY\":\"6\",\"SYSLOG_IDENTIFIER\":\"sshd\"}" \
        "{$T,\"PRIORITY\":\"0\",\"SYSLOG_IDENTIFIER\":[27,93,48,59,80,87,78,7,101,118,105,108]}"
jx --no-pager top
check "top counts per source" has '      3  75.0%      0      1  sshd'
check "top cleans source names" bash -c 'grep -qF "      1  25.0%      1      0  evil" "$1" && ! grep -q $'"'\e'"' "$1"' _ "$FAKE/out"
check "top counts every entry once" has '      4 entries from 2 sources'

# ---------------------------------------------------------------- options

for args in "err --vacuum-time=1s" "err --vacuum-t=1s" "boot -b --rotate" "unit nginx -u -- --flush" \
            "top --cursor-file=/tmp/x" "export $FAKE/x.log -1 --setup-keys" "json nginx --sync" \
            "crash -1 --relinquish-var" "failed --update-catalog"; do
  read -ra a <<< "$args"
  jx "${a[@]}"
  check "refused: jx $args" bash -c '(( $1 != 0 )) && grep -q refusing "$2" && [[ ! -s $3 ]]' _ $? "$FAKE/err" "$FAKE/calls"
done
jx --no-pager err --cursor=s=1
check "--cursor (not --cursor-file) is passed on" has '--cursor=s=1' calls
jx --no-pager grep -- --yes
check "-- ends the jx flags" has '--grep --yes' calls
jx --no-pager boot -qo short
check "bundled short options with -o select raw output" hasnt '--output-fields' calls

jx vacuum 2G --vacuum-files=1 --yes
check "vacuum shows the whole command" has 'Command: journalctl --vacuum-size=2G --vacuum-files=1'
jx --no-pager ssh
check "ssh reads the SSH units of the last 24 hours" \
  bash -c 'grep -qF -- "-u ssh.service -u sshd.service -u ssh@* -u sshd@* -u sshd-*@* --since -24h" "$1"' _ "$FAKE/calls"

# ---------------------------------------------------------------- crash, export

: > "$FAKE/target"
entries "{$T,\"SYSLOG_IDENTIFIER\":\"app\",\"MESSAGE\":\"hi\"}"
jx --no-pager crash
check "crash trusts only PID 1 for a clean shutdown" has '_PID=1 _UID=0' calls
check "crash without a shutdown record says so" has 'no clean shutdown recorded'
check "crash: no coredumps is None." has 'None.'
echo reboot.target > "$FAKE/target"
jx --no-pager crash
check "crash with a shutdown record says clean" has 'ended  clean shutdown (reboot.target)'
touch "$FAKE/fail"
jx --no-pager crash
check "crash shows journalctl's error and gives no verdict" \
  bash -c '(( $1 != 0 )) && grep -q "simulated failure" "$2" && ! grep -q ended "$3"' _ $? "$FAKE/err" "$FAKE/out"
rm -f "$FAKE/fail"

(umask 022; jx export "$FAKE/boot.log" -1 --yes)
check "export is readable only by its owner" bash -c '[[ $(stat -c %a "$1") == 600 ]]' _ "$FAKE/boot.log"

# ---------------------------------------------------------------- pager

pty() { : > "$FAKE/calls"; script -qec "$1" /dev/null < /dev/null | tr -d '\r' > "$FAKE/out"; }
if command -v script >/dev/null 2>&1; then
  pty "env PATH='$FAKE/bin:$PATH' '$JX' boot"
  check "the pager gets UTF-8 and normal mode" has 'less LESSSECURE=unset LESSSECURE_ALLOW=unset LESSCHARSET=utf-8'
  pty "env PATH='$FAKE/bin:$PATH' JX_PAGER='echo own pager' '$JX' boot"
  check "JX_PAGER is used" has 'own pager'
  realsudo=$(PATH=/usr/local/bin:/usr/bin:/bin command -v sudo || true)
  if [[ -n $realsudo ]] && "$realsudo" -n true 2>/dev/null; then
    pty "'$realsudo' -n env PATH='$FAKE/bin:$PATH' FAKE='$FAKE' JX_PAGER='echo own pager' LESSSECURE_ALLOW=shell '$JX' boot 2>&1"
    check "as root for another user: secure pager, JX_PAGER ignored" \
      bash -c 'grep -qF "less LESSSECURE=1 LESSSECURE_ALLOW=unset" "$1" && grep -q "JX_PAGER is ignored" "$1" && ! grep -q "own pager" "$1"' _ "$FAKE/out"
  else
    skip "as root for another user: secure pager" "needs passwordless sudo"
  fi
else
  skip "pager tests" "script(1) not installed"
fi

echo
echo "$pass passed, $fail failed, $skip skipped"
(( fail == 0 ))
