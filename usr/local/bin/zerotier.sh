#!/usr/bin/env bash
#
# Route between ZeroTier and Physical Networks
# Save this file to "/usr/local/bin/zerotier.sh"
# and assigned execution "chmod +x /usr/local/bin/zerotier.sh"
#

_nft=/usr/sbin/nft
_ztiface=ztqxxxxxxx
_interfaces="{ wlp1s0, enp0s2 }"

__zerotier_clear() {
    if $_nft list table inet zerotier >> /dev/null 2>&1; then
        # https://wiki.nftables.org/wiki-nftables/index.php/List_of_updates_since_Linux_kernel_3.13#6.3
        # when kernel < 6.3
        # $_nft table inet zerotier; $_nft flush table inet zerotier; $_nft delete table inet zerotier
        $_nft destroy table inet zerotier
    fi
}

__zerotier_add() {
    __zerotier_clear
    $_nft table inet zerotier

    $_nft create chain inet zerotier zerotier_postrouting \{ type nat hook postrouting priority srcnat\; policy accept\; \}
    $_nft create chain inet zerotier zerotier_forward \{ type filter hook forward priority filter\; policy accept\; \}

    $_nft add rule inet zerotier zerotier_postrouting oifname $_interfaces counter masquerade
    $_nft add rule inet zerotier zerotier_forward iifname $_interfaces oifname $_ztiface ct state related,established counter accept
    $_nft add rule inet zerotier zerotier_forward iifname $_ztiface oifname $_interfaces counter accept
}

case $1 in
    add)    __zerotier_add      ;;
    clear)  __zerotier_clear    ;;
esac
