#!/usr/bin/env bash
set -euo pipefail
# Compatible: bash 4.2+ / zsh 5+
PROG=${0##*/}

# Charsets; look-alike groups (1/i/I/l/L and 0/o/O) constrained in gen_pass
ALNUM='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
SPECIAL='!@#$%^&*'
ALL="${ALNUM}${SPECIAL}"

die() { printf '%s\n' "$*" >&2; exit 1; }

usage() {
  printf '%s\n' "Usage: $PROG [length] [count]"       >&2
  printf '%s\n' "  length:  Password length (def:16)" >&2
  printf '%s\n' "  count:   Number of passwords (def:1)" >&2
  printf '%s\n' "  Rules:   alnum head/tail; ≥1 special in middle; ≤1 kind per look-alike group (1/i/I/l/L, 0/o/O)" >&2
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
#   n > 3:  first & last alphanumeric; middle has ≥1 special char;
#           per look-alike group (1/i/I/l/L and 0/o/O), at most one kind
#           of char from that group in the whole password
# at_most_one_kind PASSWORD CHAR... — true if ≤1 kind of CHAR appears
at_most_one_kind() {
  local pw=$1 kinds=0 ch
  shift
  for ch in "$@"; do
    [[ $pw == *"$ch"* ]] && ((++kinds))
  done
  (( kinds <= 1 ))
}

gen_pass() {
  local n=$1 pw body

  ((n <= 3)) && { rand_str "$ALNUM" "$n"; printf '\n'; return; }

  # Retry until constraints met (avg 1–3 attempts for n≥8)
  while :; do
    pw=$(rand_str "$ALL" "$n")
    (( ${#pw} == n )) || die "Short read from urandom"

    body=${pw:1:$((n-2))}

    [[ ${pw:0:1} == ["$ALNUM"]  ]] || continue
    [[ ${pw: -1} == ["$ALNUM"]  ]] || continue
    [[ $body == *["$SPECIAL"]*  ]] || continue

    # Look-alike groups: at most one kind per group present
    at_most_one_kind "$pw" i I l L 1 || continue
    at_most_one_kind "$pw" o O 0    || continue

    printf '%s\n' "$pw"
    return
  done
}

# ── Main ──
for ((i = 0; i < C; i++)); do
  gen_pass "$L"
done
