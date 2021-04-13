#! /usr/bin/env bash
#
# genpassword.sh
#
# Distributed under terms of the GPLv3 license.
#

_help () {
    echo "genpasswd.sh: A Password Generator\n
    Usage: genpasswd.sh [length] [count]\n
    e.g.
    genpasswd.sh 16 5"
    exit 0
}

[[ "$1" -gt 0 ]] && _length=$1 || _help
[[ "$2" -gt 0 ]] && _count=$2 || _count="1"

_genpasswd () {
    local _strings="[:alnum:]!@#$%^&*(){}"
    LC_ALL=C tr -dc $_strings < /dev/urandom | head -c $_length | xargs
}

for ((counts = 1; counts <= "$_count"; counts++))
do
    _genpasswd
done
