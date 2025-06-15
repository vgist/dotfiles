#!/usr/bin/env bash
#
# genpassword.sh
#
# Distributed under terms of the GPLv3 license.
#

set -euo pipefail

usage() {
    cat << EOF
genpasswd.sh: A secure password generator
Usage: genpasswd.sh [length] [count]
Examples:
    genpasswd           # 1 password with 16 characters
    genpasswd.sh 20     # 1 password with 20 characters
    genpasswd.sh 20 5   # 5 passwords with 20 characters
EOF
    exit 0
}

[[ "$#" -gt 2 ]] && usage
[[ -n "${1-}" && "$1" -le 0 ]] && usage
[[ -n "${2-}" && "$2" -lt 0 ]] && usage

length=${1:-16}
count=${2:-1}

chars="abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#\$%^&*<>{}[]"

generate_password() {
    local length="$1"
    LC_ALL=C tr -dc "$chars" < /dev/urandom | head -c "$length"
    echo
}

for ((i = 1; i <= count; i++)); do
    while true; do
        password=$(generate_password "$length")
        first_char="${password:0:1}"
        last_char="${password: -1}"
        if [[ "$first_char" =~ [^a-zA-Z0-9] || "$last_char" =~ [^a-zA-Z0-9] ]]; then
            continue  # regenerate
        fi
        echo "$password"
        break
    done
done
