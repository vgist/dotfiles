#!/usr/bin/env bash
set -euo pipefail
# Compatible: bash 4.2+ / zsh (fallback pipefail)
[[ -n "${ZSH_VERSION:-}" ]] && setopt PIPE_FAIL

# Charsets; ambiguous chars: at most one from i/I/l/L/1, at most one from o/O/0
ALNUM='abcdefghijkmnpqrstuvwxyzACDEFGHJKLMNPQRSTUVWXY0123456789'
SPECIAL='!@#$%^&*'
ALL="${ALNUM}${SPECIAL}"

die() { printf '%s\n' "$*" >&2; exit 1; }

usage() {
  local p="${0##*/}"
  printf '%s\n' "Usage: $p [length] [count]"       >&2
  printf '%s\n' "  length:  Password length (def:16)" >&2
  printf '%s\n' "  count:   Number of passwords (def:1)" >&2
  printf '%s\n' "  Rules:   alnum head/tail; ≥1 special in middle; max 1 variant per ambiguous group" >&2
  exit "${1:-1}"
}

# --- Args ---
[[ "${1:-}" =~ ^(-h|--help)$ ]] && usage 0
(($# <= 2)) || usage
L=${1:-16} C=${2:-1}
[[ $L =~ ^[1-9][0-9]*$ ]] || usage
[[ $C =~ ^[1-9][0-9]*$ ]] || usage

# ── Core: generate N random chars from a charset ──
# tr -dc keeps only bytes matching charset chars from /dev/urandom.
# Each byte value 0–255 has equal probability → uniform selection,
# zero modulo bias. No rejection sampling needed.
rand_str() {
  # head closes pipe after N bytes → tr gets SIGPIPE (141); ignore that only
  local out
  out=$(LC_ALL=C tr -dc "${1:?}" < /dev/urandom 2>/dev/null | head -c "${2:?}") || {
    (($? == 141)) || die "Failed: /dev/urandom"
  }
  printf '%s' "$out"
}

# ── Generate one password ──
# Rules:
#   n ≤ 3:  all alphanumeric
#   n > 3:  first & last alphanumeric, middle ≥1 special char
#            ambiguous groups (i/I/l/L/1, o/O/0) at most one variant each
gen_pass() {
  local n=$1 pw head body tail

  ((n <= 3)) && { rand_str "$ALNUM" "$n"; return; }

  # Retry until constraints met (avg 1–3 attempts for n≥8)
  while :; do
    pw=$(rand_str "$ALL" "$n")
    (( ${#pw} >= n ))      || die "Short read from urandom"

    head=${pw:0:1}
    tail=${pw: -1}
    body=${pw:1:$((n-2))}

    [[ $head == [$ALNUM]    ]] || continue
    [[ $tail == [$ALNUM]    ]] || continue
    [[ $body == *[$SPECIAL]* ]] || continue

    # Ambiguous-char groups: at most one variant per group
    grp1=$(printf '%s' "$pw" | awk 'BEGIN{pat="[iIlL1]"} {for(i=1;i<=length;i++) if(substr($0,i,1)~pat) c[substr($0,i,1)]=1} END{print length(c)}')
    (( grp1 <= 1 )) || continue
    grp2=$(printf '%s' "$pw" | awk 'BEGIN{pat="[oO0]"}   {for(i=1;i<=length;i++) if(substr($0,i,1)~pat) c[substr($0,i,1)]=1} END{print length(c)}')
    (( grp2 <= 1 )) || continue

    printf '%s\n' "$pw"
    return
  done
}

# ── Main ──
for ((i = 0; i < C; i++)); do
  gen_pass "$L"
done
