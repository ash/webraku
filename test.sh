#!/bin/sh
# Run every test under both engines. RAKUPP and RAKUDO override the binaries.
RAKUPP="${RAKUPP:-rakupp}"
RAKUDO="${RAKUDO:-/opt/homebrew/bin/raku}"
fail=0
for engine in "$RAKUPP" "$RAKUDO"; do
    command -v "$engine" >/dev/null 2>&1 || { echo "== $engine not found, skipped"; continue; }
    echo "== $engine"
    for t in t/*.t; do
        out=$("$engine" "$t" 2>&1)
        rc=$?
        printf '   %-16s %s\n' "$(basename "$t")" "$(printf '%s' "$out" | tail -1)"
        if [ "$rc" != 0 ]; then
            fail=1
            printf '%s\n' "$out" | grep -E '^not ok|^#' | head -20
        fi
    done
done
[ "$fail" = 0 ] && echo "== both engines agree" || echo "== FAILURES"
exit $fail
