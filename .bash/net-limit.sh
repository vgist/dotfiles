#!/usr/bin/env bash
set -Eeuo pipefail

# CAKE 出站限速脚本
# 用法：
#   sudo ./net-limit.sh set 50       # 限制 eth0 出站为 50 Mbps
#   sudo ./net-limit.sh status       # 查看 qdisc 与统计
#   sudo ./net-limit.sh clear        # 恢复为系统当前默认 qdisc（也可通过 DEFAULT_QDISC 指定）
#   sudo DEFAULT_QDISC=fq ./net-limit.sh clear
#   sudo IFACE=ens3 ./net-limit.sh set 50
#
# 安全策略：仅允许操作 CAKE 或已知的简单根 qdisc，不覆盖未知的复杂规则树。

IFACE="${IFACE:-eth0}"
MAX_SPEED_MBPS=100000

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] 请使用 sudo 或 root 权限执行此脚本。" >&2
    exit 1
fi

if command -v tc >/dev/null 2>&1; then
    TC_BIN="$(command -v tc)"
elif [[ -x /usr/sbin/tc ]]; then
    TC_BIN="/usr/sbin/tc"
elif [[ -x /sbin/tc ]]; then
    TC_BIN="/sbin/tc"
else
    echo "[ERROR] 未找到 tc，请先安装 iproute2。" >&2
    exit 1
fi

if command -v sysctl >/dev/null 2>&1; then
    SYSCTL_BIN="$(command -v sysctl)"
elif [[ -x /usr/sbin/sysctl ]]; then
    SYSCTL_BIN="/usr/sbin/sysctl"
else
    echo "[ERROR] 未找到 sysctl，请先安装 procps。" >&2
    exit 1
fi

# 优先读取系统当前的 net.core.default_qdisc 作为回退默认值，避免 clear 时意外覆盖 BBR 的 fq 配置
SYS_DEFAULT_QDISC="$("$SYSCTL_BIN" -n net.core.default_qdisc 2>/dev/null || true)"
DEFAULT_QDISC="${DEFAULT_QDISC:-${SYS_DEFAULT_QDISC:-fq_codel}}"

if [[ ! -d "/sys/class/net/$IFACE" ]]; then
    echo "[ERROR] 网卡不存在：$IFACE" >&2
    exit 1
fi

usage() {
    cat <<USAGE
用法：sudo $0 {set <Mbps>|status|clear}

命令：
  set <Mbps>   将出站带宽限制为指定 Mbps（1-${MAX_SPEED_MBPS}）
  status       查看当前队列规则与统计
  clear        恢复为 DEFAULT_QDISC（当前默认：${DEFAULT_QDISC}），并同步 net.core.default_qdisc

可选环境变量：
  IFACE         网卡名称，默认 eth0
  DEFAULT_QDISC 默认读取系统 net.core.default_qdisc（回退 fq_codel）；
                可选 fq_codel、fq、codel、sfq、pfifo、pfifo_fast

示例：
  sudo $0 set 50
  sudo $0 status
  sudo $0 clear
  sudo DEFAULT_QDISC=fq $0 clear
  sudo IFACE=ens3 $0 set 50
USAGE
}

# 输出当前根 qdisc 类型；若无法识别则返回空字符串。
get_root_kind() {
    "$TC_BIN" qdisc show dev "$IFACE" 2>/dev/null |
        awk '$1 == "qdisc" { for (i = 2; i <= NF; i++) if ($i == "root") { print $2; exit } }'
}

show_status() {
    echo "=== [$IFACE] 当前 qdisc 与流量统计 ==="
    "$TC_BIN" -s qdisc show dev "$IFACE"
}

# 支持作为恢复目标的简单 qdisc
is_supported_default_qdisc() {
    case "${1:-}" in
        fq_codel|fq|codel|sfq|pfifo|pfifo_fast) return 0 ;;
        *) return 1 ;;
    esac
}

# 允许被脚本接管或替换的当前根 qdisc 类型（包含虚拟网卡常见的 noqueue）
is_safe_current_qdisc() {
    case "${1:-}" in
        cake|noqueue) return 0 ;;
        *) is_supported_default_qdisc "${1:-}" ;;
    esac
}

set_limit() {
    local speed="${1:-}"
    local current_kind
    local tc_action="replace"

    if [[ ! "$speed" =~ ^[1-9][0-9]*$ ]]; then
        echo "[ERROR] 速率必须是正整数 Mbps，例如 50。" >&2
        return 1
    fi
    # 限制位数后再做算术，避免超大输入导致整数溢出。
    if (( ${#speed} > 6 )) || (( speed > MAX_SPEED_MBPS )); then
        echo "[ERROR] 速率超出允许范围：1-${MAX_SPEED_MBPS} Mbps。" >&2
        return 1
    fi

    current_kind="$(get_root_kind)"
    if ! is_safe_current_qdisc "$current_kind"; then
        echo "[ERROR] 当前根 qdisc 类型为 '${current_kind:-未知}'，为避免覆盖现有网络规则，已拒绝修改。" >&2
        echo "        请先检查：sudo tc qdisc show dev '$IFACE'" >&2
        return 1
    fi

    if [[ "$current_kind" == "cake" ]]; then
        # CAKE 已存在时使用 change 原位更新速率，避免 replace 重建队列。
        tc_action="change"
    fi

    echo "[INFO] 网卡：$IFACE；出站限速：${speed} Mbps；原根 qdisc：$current_kind"
    if ! "$TC_BIN" qdisc "$tc_action" dev "$IFACE" root cake bandwidth "${speed}mbit" besteffort; then
        echo "[ERROR] CAKE 配置失败。请检查内核/模块是否支持 sch_cake，以及 tc 版本。" >&2
        return 1
    fi

    echo "[OK] CAKE 出站限速已设置为 ${speed} Mbps。"
    show_status
}

clear_limit() {
    local current_kind

    if ! is_supported_default_qdisc "$DEFAULT_QDISC"; then
        echo "[ERROR] 不支持的 DEFAULT_QDISC='$DEFAULT_QDISC'。" >&2
        echo "        可选：fq_codel、fq、codel、sfq、pfifo、pfifo_fast。" >&2
        return 1
    fi

    current_kind="$(get_root_kind)"
    if ! is_safe_current_qdisc "$current_kind"; then
        echo "[ERROR] 当前根 qdisc 类型为 '${current_kind:-未知}'，为避免误删规则，拒绝执行 clear。" >&2
        echo "        请先检查：sudo tc qdisc show dev '$IFACE'" >&2
        return 1
    fi

    if [[ "$current_kind" != "$DEFAULT_QDISC" ]]; then
        echo "[INFO] 正在将网卡 $IFACE 的根 qdisc 从 $current_kind 切换为 $DEFAULT_QDISC..."
        if ! "$TC_BIN" qdisc replace dev "$IFACE" root "$DEFAULT_QDISC"; then
            echo "[ERROR] 当前网卡切换到 $DEFAULT_QDISC 失败；系统默认值尚未修改。" >&2
            return 1
        fi
    else
        echo "[INFO] 当前网卡已使用 $DEFAULT_QDISC，无需替换根 qdisc。"
    fi

    # 仅在系统支持且需要更新 net.core.default_qdisc 时写入（兼容容器只读/缺失场景）
    if [[ -w /proc/sys/net/core/default_qdisc ]]; then
        if [[ "$SYS_DEFAULT_QDISC" != "$DEFAULT_QDISC" ]]; then
            echo "[INFO] 将系统默认 net.core.default_qdisc 更新为：$DEFAULT_QDISC"
            if "$SYSCTL_BIN" -w "net.core.default_qdisc=$DEFAULT_QDISC" >/dev/null; then
                echo "[INFO] sysctl -w 不会自动持久化，重启后是否保留取决于 sysctl 配置文件。"
            else
                echo "[WARN] 当前网卡 qdisc 已恢复，但更新 net.core.default_qdisc 失败。" >&2
            fi
        fi
    fi

    echo "[OK] 当前网卡已恢复使用 $DEFAULT_QDISC。"
    show_status
}

case "${1:-}" in
    set)
        if [[ $# -ne 2 ]]; then
            usage >&2
            exit 2
        fi
        set_limit "$2"
        ;;
    status)
        if [[ $# -ne 1 ]]; then
            usage >&2
            exit 2
        fi
        show_status
        ;;
    clear)
        if [[ $# -ne 1 ]]; then
            usage >&2
            exit 2
        fi
        clear_limit
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
