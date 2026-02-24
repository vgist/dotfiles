#!/usr/bin/env bash
# 兼容 zsh：KSH_ARRAYS 让数组下标从 0 开始，SH_WORD_SPLIT 启用自动分词
if [ -n "${ZSH_VERSION:-}" ]; then
  setopt KSH_ARRAYS SH_WORD_SPLIT
fi
set -euo pipefail

_prog="${0##*/}"
usage() {
  echo "Usage: $_prog [length] [count]"
  echo "  length  Password length (default: 16, min: 1)"
  echo "  count   Number of passwords (default: 1, min: 1)"
  exit 1
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

length="${1:-16}"
count="${2:-1}"

[[ "$#" -le 2 ]] || usage
is_uint "$length" || usage
is_uint "$count" || usage
(( length > 0 )) || usage
(( count > 0 )) || usage

alnum='abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ0123456789'
special='!@#$%^&*'
all="${alnum}${special}"

# ---------------------------------------------------------------------------
# 随机池：一次性从 /dev/urandom 读取，避免重复 fork
# 兼容性：用 od（POSIX 标准）替代 xxd（依赖 vim 包）
# 安全性：rejection sampling 消除取模偏差
# ---------------------------------------------------------------------------
rand_bytes=()
rand_pool_pos=0

fill_rand_pool() {
  local need="$1"
  local fetch=$(( need + need / 2 + 32 ))
  local raw
  raw="$(od -An -tu1 -N "$fetch" /dev/urandom | tr -s ' \n' ' ')"
  # shellcheck disable=SC2086
  rand_bytes+=( $raw )
}

# 返回值通过全局变量 _ret 传递，避免 $() 子 shell 导致池位置丢失
_ret=""

# 从 charset 中无偏差地取 1 个字符 → 结果存入 _ret
pick_one() {
  local charset="$1"
  local clen=${#charset}
  local limit=$(( 256 - 256 % clen ))
  local val

  while true; do
    if (( rand_pool_pos >= ${#rand_bytes[@]} )); then
      fill_rand_pool 128
    fi
    val=${rand_bytes[$rand_pool_pos]}
    (( rand_pool_pos += 1 ))
    (( val < limit )) && break
  done

  _ret="${charset:$(( val % clen )):1}"
}

# 从 charset 里取 n 个字符 → 结果存入 _ret
pick_from_set() {
  local charset="$1"
  local n="$2"
  local i out=""
  for (( i = 0; i < n; i++ )); do
    pick_one "$charset"
    out+="$_ret"
  done
  _ret="$out"
}

# Fisher-Yates 原地洗牌全局数组 _shuf_arr[]
_shuf_arr=()

shuffle_array() {
  local len=${#_shuf_arr[@]}
  local i j tmp
  for (( i = len - 1; i > 0; i-- )); do
    if (( rand_pool_pos >= ${#rand_bytes[@]} )); then
      fill_rand_pool 64
    fi
    j=$(( rand_bytes[rand_pool_pos] % (i + 1) ))
    (( rand_pool_pos += 1 ))
    tmp="${_shuf_arr[$i]}"
    _shuf_arr[$i]="${_shuf_arr[$j]}"
    _shuf_arr[$j]="$tmp"
  done
}

generate_password() {
  local n="$1"

  if (( n == 1 )); then
    pick_one "$alnum"
    printf '%s\n' "$_ret"
    return
  fi

  if (( n == 2 )); then
    pick_one "$alnum"
    local c1="$_ret"
    pick_one "$alnum"
    printf '%s%s\n' "$c1" "$_ret"
    return
  fi

  # 首尾必须是字母数字
  pick_one "$alnum"
  local head="$_ret"

  local mid=""
  if (( n >= 4 )); then
    # 保证中间至少含 1 个特殊字符
    pick_one "$special"
    local sp="$_ret"
    pick_from_set "$all" $(( n - 3 ))
    local mid_str="${sp}${_ret}"

    # 洗牌中间部分，避免特殊字符总在固定位置
    _shuf_arr=()
    local k
    for (( k = 0; k < ${#mid_str}; k++ )); do
      _shuf_arr+=("${mid_str:$k:1}")
    done
    shuffle_array
    mid=""
    for k in "${_shuf_arr[@]}"; do mid+="$k"; done
  else
    # n == 3：中间只有 1 个字符
    pick_one "$all"
    mid="$_ret"
  fi

  pick_one "$alnum"
  local tail="$_ret"

  printf '%s%s%s\n' "$head" "$mid" "$tail"
}

# 预填充随机池
total_bytes=$(( length * count * 2 + 64 ))
fill_rand_pool "$total_bytes"

for (( i = 0; i < count; i++ )); do
  generate_password "$length"
done
