#!/usr/bin/env bash
# test-install-sd-free.sh - regression tests for install-sd-free.sh
#
# Covers the failure modes found while reviewing the installer:
#   1. ask() must take the answer from the terminal, not from stdin
#      (stdin IS the script itself in the documented `curl ... | sudo bash -s -- --install`)
#   2. the prebuilt checksum check must actually verify the file inside bin/
#   3. the "already contains this image" check must ignore the board-local NORPARAM block
#
# Run:  bash test-install-sd-free.sh            (tests install-sd-free.sh next to it)
#        bash test-install-sd-free.sh /path/to/install-sd-free.sh
#
# NOTE: this test never executes the installer. It extracts the single ask()
# function by brace matching, refuses to run anything that looks like a
# side-effecting command, and exercises it in isolation.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="${1:-$HERE/install-sd-free.sh}"
PASS=0; FAIL=0

ok()  { printf '  PASS %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# ---------------------------------------------------------------------------
# Extract ask() by brace matching and refuse to execute anything unsafe.
# ---------------------------------------------------------------------------
extract_ask() {
    python3 - "$1" <<'PY'
import re, sys
src = open(sys.argv[1], encoding='utf-8', errors='replace').read()
m = re.search(r'^ask\(\)\s*\{', src, re.M)
if not m:
    sys.exit(2)
i, depth = m.start(), 0
while i < len(src):
    if src[i] == '{': depth += 1
    elif src[i] == '}':
        depth -= 1
        if depth == 0:
            print(src[m.start():i+1])
            sys.exit(0)
    i += 1
sys.exit(3)
PY
}

echo "test 1: ask() takes the answer from the terminal, not from stdin"
ASK=$(extract_ask "$SCRIPT")
RC=$?
if [ $RC -ne 0 ]; then
    bad "could not extract ask() from $SCRIPT (rc=$RC)"
else
    ok "extracted ask() ($(printf '%s' "$ASK" | wc -l) lines)"
    # Safety net: the extracted snippet must not be able to act on the system.
    # Only command POSITION counts - "install" as a MODE value is harmless, "install -m" is not.
    DANGER='^[[:space:]]*(dd|rm|mv|cp|curl|wget|install|umount|mount|flash|tee|sudo|chmod|chown|mkdir|tar|apt-get|apt|python3?)([[:space:]]|$)'
    if printf '%s\n' "$ASK" | grep -nE "$DANGER" >/dev/null; then
        bad "extracted ask() contains a side-effecting command - refusing to run it"
    elif printf '%s' "$ASK" | grep -nE '/dev/(mtd|mmcblk|disk|sda|nvme|mmc)' >/dev/null; then
        bad "extracted ask() touches a block device - refusing to run it"
    else
        ok "extracted ask() contains no side-effecting commands"
        if printf '%s' "$ASK" | grep -q '/dev/tty'; then
            ok "ask() reads the answer from /dev/tty"
        else
            bad "ask() does not read from /dev/tty"
        fi

        # Behavioural check. The answer comes from a stand-in for the terminal;
        # the script's own stdin must come out untouched. A plain `read` eats one
        # line of stdin - and in the documented piped invocation that line is the
        # next line of the script itself (the `dd` that writes the SPI NOR).
        printf 'y\n' > "$T/tty"
        cat > "$T/harness.sh" <<EOS
MODE=install
$(printf '%s' "$ASK" | sed "s#/dev/tty#$T/tty#g")
ask "confirm?" || { echo "ABORTED"; exit 1; }
echo "REACHED_FLASH"
cat
EOS
        OUT=$(printf 'NOT_THE_ANSWER\nSENTINEL_LINE\n' | bash "$T/harness.sh" 2>/dev/null)
        if printf '%s' "$OUT" | grep -q 'SENTINEL_LINE' && printf '%s' "$OUT" | grep -q 'NOT_THE_ANSWER'; then
            ok "stdin survives the prompt (no line of the script is swallowed)"
        else
            bad "stdin was consumed - remaining: '$(printf '%s' "$OUT" | tr '\n' '|')'"
        fi
        if printf '%s' "$OUT" | grep -q 'REACHED_FLASH'; then
            ok "the flash step is reached after the prompt"
        else
            bad "the flash step was never reached: '$(printf '%s' "$OUT" | tr '\n' '|')'"
        fi
    fi
fi

echo "test 2: the prebuilt checksum is verified from inside bin/"
if grep -q 'cd bin && sha256sum -c' "$SCRIPT"; then
    ok "installer runs sha256sum from bin/"
else
    bad "installer still runs sha256sum from the repo root - the check can never pass"
fi
if ( cd "$HERE/bin" && sha256sum -c --ignore-missing <(grep spi-image-16m-prp SHA256SUMS.txt) ) >/dev/null 2>&1; then
    ok "bin/spi-image-16m-prp-1.0.4.bin matches bin/SHA256SUMS.txt"
else
    bad "shipped prebuilt image does not match bin/SHA256SUMS.txt"
fi

echo "test 3: the idempotency check ignores the board-local NORPARAM block"
if grep -q 'SPI_CUR_NORPARAM' "$SCRIPT"; then
    ok "installer compares a NORPARAM-masked hash"
else
    bad "installer compares the raw hash only - never matches once boot0 wrote bootpara"
fi
MASKED=$(python3 - "$HERE/bin/spi-image-16m-prp-1.0.4.bin" <<'EOF'
import hashlib, sys
d = bytearray(open(sys.argv[1], 'rb').read())
d[0xf800:0x10000] = b'\xff' * 0x800
print(hashlib.sha256(bytes(d)).hexdigest())
EOF
)
if [ "$MASKED" = "31ec3781a5a9986560ef983fdb8f0b693e0f2222a0af6d3a6239f2421da30983" ]; then
    ok "NORPARAM-masked hash of the shipped image == the published sha"
else
    bad "masked hash mismatch: $MASKED"
fi

echo
printf 'passed: %d, failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
