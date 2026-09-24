#!/usr/bin/env bash
set -Eeuo pipefail

# =========================
# 默认值（交互模式的兜底值；可用环境变量覆盖）
# =========================
DEFAULT_TARGET_USER="user"
DEFAULT_SSH_PORT="22"
DEFAULT_SWAP_SIZE_MB="512"

TARGET_USER="${TARGET_USER:-}"
SSH_PUBKEYS="${SSH_PUBKEYS:-}"
SSH_PORT="${SSH_PORT:-}"
SWAP_SIZE_MB="${SWAP_SIZE_MB:-}"

AUTO_TZ="${AUTO_TZ:-0}"
MANUAL_TZ="${MANUAL_TZ:-}"
TIMEZONE_FALLBACK="${TIMEZONE_FALLBACK:-Etc/UTC}"

DOTFILES_REPO="${DOTFILES_REPO:-https://repo.or.cz/dotFiles.git}"
DOTFILES_FALLBACK_REPO="${DOTFILES_FALLBACK_REPO:-https://github.com/vgist/dotfiles.git}"

APT_TUNE_FILE="/etc/apt/apt.conf.d/99speedup"
DNF_CONF_FILE="/etc/dnf/dnf.conf"

DRY_RUN=0

# =========================
# 运行时变量
# =========================
USER_HOME=""
DOTFILES_DIR=""

OS_ID=""
OS_VERSION_ID=""
OS_VERSION_MAJOR=""
OS_FAMILY=""
PKG_MANAGER=""
SSH_SERVICE=""
SUDO_GROUP=""

PKG_DNSUTILS=""
PKG_VIM=""
PKG_SSH=""

HAS_ZRAM_SUPPORT=0
HAS_SWAP_SUPPORT=0
IN_CONTAINER=0
CONTAINER_KIND=""    # 容器类型（lxc/openvz/docker/podman），由 detect_container 设置

ZRAM_PKG=""
ZRAM_CONF_FILE=""
ZRAM_SERVICE=""

# 预声明：这些变量在后续函数中被赋值/引用，此处仅声明以明确初始状态。
INSTALL_PACKAGES=()  # 待安装的基础软件包列表（由 collect_install_packages 填充）
INSTALL_ZRAM=0       # 是否需要安装/配置 zram（1=是，0=否）
DOTFILES_AVAILABLE=0 # dotfiles 是否成功克隆/可用（1=是，0=否）
TZ_MAP_ENTRIES=()    # 时区映射规则数组（由 timezone_from_region 填充）

# =========================
# 日志
# =========================
COLOR_RESET=""
COLOR_INFO=""
COLOR_DRYRUN=""
COLOR_WARN=""
COLOR_ERROR=""

init_colors() {
  if [[ -n "${NO_COLOR:-}" ]]; then
    return 0
  fi
  if [[ -t 1 || -t 2 ]]; then
    COLOR_RESET=$'\033[0m'
    COLOR_INFO=$'\033[32m'
    COLOR_DRYRUN=$'\033[36m'
    COLOR_WARN=$'\033[33m'
    COLOR_ERROR=$'\033[31m'
  fi
}

# 用法: log <level> <message>
# level: info | dryrun | warn | error
log() {
  local level="$1"
  shift
  local msg="$*"
  case "$level" in
    info)   printf '%s[信息]%s %s\n' "$COLOR_INFO" "$COLOR_RESET" "$msg" ;;
    dryrun) printf '%s[试运行]%s %s\n' "$COLOR_DRYRUN" "$COLOR_RESET" "$msg" ;;
    warn)   printf '%s[警告]%s %s\n' "$COLOR_WARN" "$COLOR_RESET" "$msg" >&2 ;;
    error)  printf '%s[错误]%s %s\n' "$COLOR_ERROR" "$COLOR_RESET" "$msg" >&2 ;;
    *)      printf '[LOG:%s] %s\n' "$level" "$msg" ;;
  esac
}

die() {
  log error "$*"
  exit 1
}

# =========================
# dry-run
# =========================
run_cmd() {
  if (( DRY_RUN == 1 )); then
    printf '%s[试运行]%s ' "$COLOR_DRYRUN" "$COLOR_RESET"
    printf '%q ' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

write_file() {
  local target="$1"
  if (( DRY_RUN == 1 )); then
    log dryrun "写入文件：$target"
    cat >/dev/null
    return 0
  fi
  cat > "$target"
}

append_file() {
  local target="$1"
  if (( DRY_RUN == 1 )); then
    log dryrun "追加文件：$target"
    cat >/dev/null
    return 0
  fi
  cat >> "$target"
}

append_line_if_missing() {
  local target="$1"
  local line="$2"
  if (( DRY_RUN == 1 )); then
    log dryrun "确保文件 $target 包含：$line"
    return 0
  fi
  if ! grep -qxF "$line" "$target" 2>/dev/null; then
    printf '%s\n' "$line" >> "$target"
  fi
}

has_systemctl() {
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

has_openrc() {
  command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1
}

# =========================
# 交互采集
# =========================
is_interactive() {
  [[ -t 0 ]]
}

# 校验登录名是否可用于脚本内部操作（sed/awk/路径）：
# 允许字母、数字、下划线、点、连字符（兼容系统既有 UID 1000 用户名如 john.doe），
# 不允许以点/连字符开头，不允许连续两点，长度不超过 32。
is_safe_login_name() {
  local name="$1"
  [[ -n "$name" && ${#name} -le 32 ]] || return 1
  [[ "$name" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || return 1
  [[ "$name" == *".."* ]] && return 1
  return 0
}

find_uid_1000_user() {
  local user=""
  if command -v getent >/dev/null 2>&1; then
    user="$(getent passwd 1000 2>/dev/null | cut -d: -f1 || true)"
  fi
  if [[ -z "$user" && -r /etc/passwd ]]; then
    user="$(awk -F: '$3 == 1000 {print $1; exit}' /etc/passwd 2>/dev/null || true)"
  fi
  printf '%s' "$user"
}

get_user_shell() {
  local user="$1"
  local shell=""
  if command -v getent >/dev/null 2>&1; then
    shell="$(getent passwd "$user" 2>/dev/null | cut -d: -f7 || true)"
  fi
  if [[ -z "$shell" && -r /etc/passwd ]]; then
    shell="$(awk -F: -v u="$user" '$1 == u {print $7; exit}' /etc/passwd 2>/dev/null || true)"
  fi
  printf '%s' "$shell"
}

# 用法: prompt_user
# 循环询问目标用户名直到合法，直接为 TARGET_USER 赋值（与 verify_inputs 规则一致）。
prompt_user() {
  local input=""
  while true; do
    printf '请输入目标用户名 [%s]: ' "$DEFAULT_TARGET_USER"
    IFS= read -r input || true
    [[ -z "$input" ]] && input="$DEFAULT_TARGET_USER"
    if [[ "$input" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
      TARGET_USER="$input"
      break
    fi
    printf '无效用户名：%s（需以字母或下划线开头，仅含小写字母、数字、下划线、连字符，最长 32 位）\n' "$input" >&2
  done
}

# 用法: prompt_port
# 循环询问 SSH 端口直到合法（1-65535 的整数），直接为 SSH_PORT 赋值。
prompt_port() {
  local input=""
  while true; do
    printf '请输入 SSH 端口 [%s]: ' "$DEFAULT_SSH_PORT"
    IFS= read -r input || true
    [[ -z "$input" ]] && input="$DEFAULT_SSH_PORT"
    if [[ "$input" =~ ^[0-9]+$ ]] && (( 10#$input >= 1 && 10#$input <= 65535 )); then
      SSH_PORT="$input"
      break
    fi
    printf '无效端口：%s（需 1-65535 的整数）\n' "$input" >&2
  done
}

# 用法: prompt_swap_size
# 循环询问 swap 大小直到合法（非负整数，0 表示跳过创建），直接为 SWAP_SIZE_MB 赋值。
prompt_swap_size() {
  local input=""
  while true; do
    printf '请输入 swap 大小（MB） [%s]: ' "$DEFAULT_SWAP_SIZE_MB"
    IFS= read -r input || true
    [[ -z "$input" ]] && input="$DEFAULT_SWAP_SIZE_MB"
    if [[ "$input" =~ ^[0-9]+$ ]]; then
      SWAP_SIZE_MB="$input"
      break
    fi
    printf '无效大小：%s（需非负整数，0 表示跳过创建 swap）\n' "$input" >&2
  done
}

# 用法: prompt_pubkeys
# 必填：循环读取多行公钥，空行结束；直接为 SSH_PUBKEYS 赋值。
prompt_pubkeys() {
  local line=""
  local result=""
  local got_input=0
  printf '请输入 SSH 公钥（必填，每行一个，可粘贴多个，空行结束输入，取消可按 Ctrl+C）：\n'
  while true; do
    result=""
    got_input=0
    while IFS= read -r line; do
      got_input=1
      if [[ -z "$line" ]]; then
        break
      fi
      result+="${line}"$'\n'
    done || true
    if [[ -n "$result" ]]; then
      break
    fi
    if (( got_input == 0 )); then
      die "未获取到 SSH 公钥（输入流已结束）。请通过环境变量 SSH_PUBKEYS 提供。"
    fi
    printf '未输入任何公钥，请至少粘贴一个 SSH 公钥（空行结束输入，取消可按 Ctrl+C）：\n'
  done
  SSH_PUBKEYS="${result%$'\n'}"
}

# 按模式采集四个配置项（环境变量已指定时跳过）。
# mode=install：用户名（优先复用已有 UID 1000 用户）/端口/swap 循环询问（带默认值），SSH 公钥必填；
# mode=check：不询问任何交互项，用户名（优先复用已有 UID 1000 用户）/端口/swap 用默认值，公钥不涉及。
collect_inputs() {
  local mode="$1"

  if [[ -z "$TARGET_USER" ]]; then
    local u1000_name
    u1000_name="$(find_uid_1000_user)"
    if [[ -n "$u1000_name" ]]; then
      if ! is_safe_login_name "$u1000_name"; then
        die "检测到 UID 1000 用户名含脚本不支持的字符（$u1000_name）；请通过环境变量 TARGET_USER 显式指定目标用户。"
      fi
      TARGET_USER="$u1000_name"
      local u1000_shell
      u1000_shell="$(get_user_shell "$TARGET_USER")"
      if [[ -n "$u1000_shell" && "$u1000_shell" != "/bin/bash" ]]; then
        log info "检测到已存在 UID 为 1000 的用户（$TARGET_USER，当前 shell: $u1000_shell），后续将确保其默认 shell 修改为 /bin/bash。"
      else
        log info "检测到已存在 UID 为 1000 的用户（$TARGET_USER），直接复用该用户，跳过新用户添加。"
      fi
    elif is_interactive && [[ "$mode" == "install" ]]; then
      prompt_user
    else
      TARGET_USER="$DEFAULT_TARGET_USER"
      log info "未指定 TARGET_USER，使用默认值：${TARGET_USER}。"
    fi
  fi

  if [[ "$mode" == "install" ]]; then
    if [[ -z "$SSH_PUBKEYS" ]]; then
      if is_interactive; then
        prompt_pubkeys
      else
        die "SSH_PUBKEYS 未设置，且无交互终端可输入公钥。请通过环境变量 SSH_PUBKEYS 提供。"
      fi
    fi

    if [[ -z "$SSH_PORT" ]]; then
      if (( IN_CONTAINER == 1 )); then
        SSH_PORT=""
        log info "检测到容器环境，不显式配置 SSH 端口（保持系统默认 22）。"
      elif is_interactive; then
        prompt_port
      else
        SSH_PORT="$DEFAULT_SSH_PORT"
        log info "未指定 SSH_PORT，使用默认值：${SSH_PORT}。"
      fi
    fi

    if [[ -z "$SWAP_SIZE_MB" ]]; then
      if (( IN_CONTAINER == 1 )); then
        SWAP_SIZE_MB=0
        log info "检测到容器环境，跳过 swapfile 配置（SWAP_SIZE_MB 设为 0）。"
      elif is_interactive; then
        prompt_swap_size
      else
        SWAP_SIZE_MB="$DEFAULT_SWAP_SIZE_MB"
        log info "未指定 SWAP_SIZE_MB，使用默认值：${SWAP_SIZE_MB}。"
      fi
    fi
  else
    # check 模式：只需满足 verify_inputs 校验，端口/swap 取默认值，公钥不涉及。
    if [[ -z "$SSH_PORT" ]]; then
      if (( IN_CONTAINER == 1 )); then
        SSH_PORT=""
      else
        SSH_PORT="$DEFAULT_SSH_PORT"
      fi
    fi
    if [[ -z "$SWAP_SIZE_MB" ]]; then
      if (( IN_CONTAINER == 1 )); then
        SWAP_SIZE_MB=0
      else
        SWAP_SIZE_MB="$DEFAULT_SWAP_SIZE_MB"
      fi
    fi
  fi
}

# =========================
# 校验
# =========================
require_root() {
  if (( EUID == 0 )); then
    return 0
  fi
  if (( DRY_RUN == 1 )); then
    log warn "当前不是 root；试运行继续，但真实安装必须使用 root。"
    return 0
  fi
  die "请使用 root 运行。"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少必要命令：$1"
}

verify_inputs() {
  if ! is_safe_login_name "$TARGET_USER"; then
    die "TARGET_USER 不合法：$TARGET_USER（仅允许字母、数字、下划线、点、连字符，最长 32 位，不能以点/连字符开头）。"
  fi
  if [[ -n "$SSH_PORT" ]]; then
    [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "SSH_PORT 必须是数字。"
    SSH_PORT=$((10#$SSH_PORT))
    (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || die "SSH_PORT 超出范围：$SSH_PORT"
  fi
  [[ "$SWAP_SIZE_MB" =~ ^[0-9]+$ ]] || die "SWAP_SIZE_MB 必须是非负整数。"
  SWAP_SIZE_MB=$((10#$SWAP_SIZE_MB))
  [[ "$AUTO_TZ" == "0" || "$AUTO_TZ" == "1" ]] || die "AUTO_TZ 只能是 0 或 1。"

  # 提前校验公钥格式：避免 install 跑到 configure_sshd 才因坏公钥中断，
  # 留下半配置的系统。configure_sshd 仍保留对 authorized_keys 的最终校验。
  if [[ -n "$SSH_PUBKEYS" ]]; then
    local key
    while IFS= read -r key; do
      [[ -z "$key" ]] && continue
      [[ "$key" =~ ^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:space:]] ]] \
        || die "SSH_PUBKEYS 含无效公钥（需以 ssh-ed25519/ssh-rsa/ecdsa-sha2-nistp256 等开头）：${key:0:32}..."
    done <<< "$SSH_PUBKEYS"
  fi
}

# =========================
# 系统检测
# =========================
detect_os() {
  [[ -r /etc/os-release ]] || die "无法检测系统：缺少 /etc/os-release。"
  # shellcheck disable=SC1091
  source /etc/os-release

  OS_ID="${ID:-unknown}"
  OS_VERSION_ID="${VERSION_ID:-unknown}"
  OS_VERSION_MAJOR="${OS_VERSION_ID%%.*}"

  # rolling 发行版（如 Debian sid/unstable）不提供 VERSION_ID，
  # 提前给出明确提示，而不是让后续版本比较报出 "unknown"。
  if [[ "$OS_VERSION_ID" == "unknown" ]]; then
    die "无法识别系统版本：/etc/os-release 缺少 VERSION_ID（rolling 发行版不受支持）。仅支持 Debian 11/12/13、Ubuntu 22.04/24.04/25.04、AlmaLinux/Rocky/CentOS 9/10、Alpine Linux 3.x。"
  fi

  case "$OS_ID" in
    debian|ubuntu)
      OS_FAMILY="debian"
      PKG_MANAGER="apt"
      SSH_SERVICE="ssh"
      SUDO_GROUP="sudo"
      if [[ "$OS_ID" == "ubuntu" ]]; then
        [[ "$OS_VERSION_MAJOR" == "22" || "$OS_VERSION_MAJOR" == "24" || "$OS_VERSION_MAJOR" == "25" ]] || die "不支持的 Ubuntu 版本：$OS_VERSION_ID；仅支持 Ubuntu 22.04/24.04/25.04。"
      else
        [[ "$OS_VERSION_MAJOR" == "11" || "$OS_VERSION_MAJOR" == "12" || "$OS_VERSION_MAJOR" == "13" ]] || die "不支持的 Debian 版本：$OS_VERSION_ID；仅支持 Debian 11/12/13。"
      fi
      PKG_DNSUTILS="dnsutils"
      PKG_VIM="vim-tiny"
      PKG_SSH="openssh-server"
      if [[ "$OS_VERSION_MAJOR" == "11" ]]; then
        ZRAM_PKG="zram-tools"
        ZRAM_CONF_FILE="/etc/default/zramswap"
        ZRAM_SERVICE="zramswap"
      else
        ZRAM_PKG="systemd-zram-generator"
        ZRAM_CONF_FILE="/etc/systemd/zram-generator.conf"
        ZRAM_SERVICE="systemd-zram-setup@zram0"
      fi
      ;;
    centos|rhel|almalinux|rocky)
      OS_FAMILY="rhel"
      PKG_MANAGER="dnf"
      SSH_SERVICE="sshd"
      SUDO_GROUP="wheel"
      [[ "$OS_VERSION_MAJOR" == "9" || "$OS_VERSION_MAJOR" == "10" ]] || die "不支持的 ${OS_ID} 版本：$OS_VERSION_ID；仅支持 AlmaLinux/Rocky/CentOS 9/10。"
      PKG_DNSUTILS="bind-utils"
      PKG_VIM="vim-minimal"
      PKG_SSH="openssh-server"
      ZRAM_PKG="zram-generator"
      ZRAM_CONF_FILE="/etc/systemd/zram-generator.conf"
      ZRAM_SERVICE="systemd-zram-setup@zram0"
      ;;
    alpine)
      OS_FAMILY="alpine"
      PKG_MANAGER="apk"
      SSH_SERVICE="sshd"
      SUDO_GROUP="wheel"
      [[ "$OS_VERSION_MAJOR" == "3" ]] || die "不支持的 Alpine 版本：$OS_VERSION_ID；仅支持 Alpine 3.x。"
      PKG_DNSUTILS="bind-tools"
      PKG_VIM="vim"
      PKG_SSH="openssh"
      ZRAM_PKG="zram-init"
      ZRAM_CONF_FILE="/etc/conf.d/zram-init"
      ZRAM_SERVICE="zram-init"
      ;;
    *) die "不支持的系统：$OS_ID；仅支持 Debian 11/12/13、Ubuntu 22.04/24.04/25.04、AlmaLinux/Rocky/CentOS 9/10、Alpine Linux 3.x。" ;;
  esac

  log info "系统：${OS_ID} ${OS_VERSION_ID}；包管理器：${PKG_MANAGER}。"
}

detect_kernel_features() {
  if (( IN_CONTAINER == 1 )); then
    HAS_ZRAM_SUPPORT=0
    HAS_SWAP_SUPPORT=0
    log info "容器环境，跳过 zram/swap 检测。"
    return 0
  fi
  if grep -qw '^zram' /proc/modules 2>/dev/null || [[ -d /sys/module/zram ]] || modinfo zram >/dev/null 2>&1; then
    HAS_ZRAM_SUPPORT=1
  else
    HAS_ZRAM_SUPPORT=0
  fi
  if [[ -r /proc/swaps ]] && command -v swapon >/dev/null 2>&1; then
    HAS_SWAP_SUPPORT=1
  else
    HAS_SWAP_SUPPORT=0
  fi
  log info "内核能力：zram=${HAS_ZRAM_SUPPORT}，swap=${HAS_SWAP_SUPPORT}。"
}

# 识别容器环境（LXC/OpenVZ、Docker、Podman）。命中返回 0 并设置 CONTAINER_KIND；
# 这些环境下将跳过 zram/swap 等宿主级配置。
detect_container() {
  CONTAINER_KIND=""

  # 1. 检查环境变量 container（LXC/OpenVZ 原生注入；Podman 会注入 container=podman）
  case "${container:-}" in
    lxc|openvz|docker|podman)
      CONTAINER_KIND="${container}"
      return 0
      ;;
  esac

  # 2. systemd-detect-virt 是支持 systemd 的系统中最可靠的容器/虚拟化检测方式
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    local virt
    # --container: 检测容器环境（lxc, openvz, docker, podman, rkt 等）
    if virt="$(systemd-detect-virt --container 2>/dev/null)"; then
      case "$virt" in
        lxc|openvz|docker|podman)
          CONTAINER_KIND="$virt"
          return 0
          ;;
        *) return 1 ;;  # rkt 等其他容器类型不视为目标容器
      esac
    fi
    # 未识别容器：继续尝试后备检测。
  fi

  # 3. 检查 /run/systemd/container 文件
  if [[ -r /run/systemd/container ]]; then
    local run_container
    run_container="$(cat /run/systemd/container 2>/dev/null || true)"
    case "$run_container" in
      lxc|openvz|docker|podman)
        CONTAINER_KIND="$run_container"
        return 0
        ;;
    esac
  fi

  # 4. Docker/Podman 标记文件
  if [[ -f /.dockerenv ]]; then
    CONTAINER_KIND="docker"
    return 0
  fi
  if [[ -f /run/.containerenv ]]; then
    CONTAINER_KIND="podman"
    return 0
  fi

  # 5. OpenVZ 容器有 /proc/vz 但没有 /proc/bc；宿主两者通常都存在。
  if [[ -d /proc/vz && ! -d /proc/bc ]]; then
    CONTAINER_KIND="openvz"
    return 0
  fi

  # 6. cgroup 标识（LXC/Proxmox、Docker、Podman 的 cgroup 路径会含对应标识）
  local cg_file
  for cg_file in /proc/1/cgroup /proc/self/cgroup; do
    [[ -r "$cg_file" ]] || continue
    if grep -Eq '/lxc/|lxc\.payload|lxc\.monitor' "$cg_file" 2>/dev/null; then
      CONTAINER_KIND="lxc"
      return 0
    fi
    if grep -Eq 'docker[/-]' "$cg_file" 2>/dev/null; then
      CONTAINER_KIND="docker"
      return 0
    fi
    if grep -Eq 'libpod' "$cg_file" 2>/dev/null; then
      CONTAINER_KIND="podman"
      return 0
    fi
  done

  # 7. 检查 /proc/1/environ 中的 container 字段（部分容器/特权环境可用）
  if [[ -r /proc/1/environ ]]; then
    local pid1_container=""
    pid1_container="$(tr '\0' '\n' < /proc/1/environ 2>/dev/null | sed -nE 's/^container=([a-z0-9_-]+)$/\1/p' | head -n 1 || true)"
    case "$pid1_container" in
      lxc|openvz|docker|podman)
        CONTAINER_KIND="$pid1_container"
        return 0
        ;;
    esac
  fi

  return 1
}

# =========================
# SELinux
# =========================
disable_selinux() {
  [[ "$OS_FAMILY" == "rhel" ]] || return 0
  (( IN_CONTAINER == 1 )) && return 0

  local selinux_config="/etc/selinux/config"
  local is_enabled=0

  if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
    is_enabled=1
  elif command -v getenforce >/dev/null 2>&1; then
    local mode
    mode="$(getenforce 2>/dev/null || true)"
    [[ "$mode" == "Enforcing" || "$mode" == "Permissive" ]] && is_enabled=1
  elif [[ -f /sys/fs/selinux/enforce ]]; then
    # 兜底：极简镜像未装 libselinux-utils 时直接读内核接口（存在即已加载 SELinux）
    is_enabled=1
  fi

  if (( is_enabled == 1 )); then
    log info "检测到 SELinux 已启用，正在临时关闭并配置为永久关闭。"
    if command -v setenforce >/dev/null 2>&1; then
      run_cmd setenforce 0 || log warn "setenforce 0 临时关闭 SELinux 失败。"
    fi
    if [[ -f "$selinux_config" ]]; then
      if (( DRY_RUN == 1 )); then
        log dryrun "备份并修改 $selinux_config：设置 SELINUX=disabled"
      else
        if [[ ! -e "${selinux_config}.bak.init" ]]; then
          cp -a "$selinux_config" "${selinux_config}.bak.init"
        fi
        if grep -q '^[[:space:]]*SELINUX=' "$selinux_config"; then
          sed -i 's/^[[:space:]]*SELINUX=.*/SELINUX=disabled/' "$selinux_config"
        else
          printf 'SELINUX=disabled\n' >> "$selinux_config"
        fi
      fi
    else
      log warn "未找到 $selinux_config，无法配置 SELinux 永久关闭。"
    fi
  else
    log info "SELinux 未启用或已处于关闭状态。"
  fi
}

# =========================
# 防火墙
# =========================
has_firewalld() {
  rpm -q firewalld >/dev/null 2>&1 || command -v firewall-cmd >/dev/null 2>&1
}

has_ufw() {
  dpkg-query -W -f='${Status}' ufw 2>/dev/null | grep -q 'install ok installed' \
    || command -v ufw >/dev/null 2>&1
}

# 【防断连加固】先显式将默认策略置为 ACCEPT，再清空各表规则，
# 彻底杜绝因系统默认 Policy 为 DROP 导致清空规则瞬间掐断现有 SSH 连接。
flush_firewall_rules() {
  local ipt table
  for ipt in iptables ip6tables; do
    command -v "$ipt" >/dev/null 2>&1 || continue
    run_cmd "$ipt" -P INPUT ACCEPT 2>/dev/null || true
    run_cmd "$ipt" -P FORWARD ACCEPT 2>/dev/null || true
    run_cmd "$ipt" -P OUTPUT ACCEPT 2>/dev/null || true
    for table in nat mangle raw security; do
      run_cmd "$ipt" -t "$table" -F 2>/dev/null || true
      run_cmd "$ipt" -t "$table" -X 2>/dev/null || true
    done
    run_cmd "$ipt" -F 2>/dev/null || true
    run_cmd "$ipt" -X 2>/dev/null || true
  done

  # nftables：flush ruleset 彻底卸载规则表，直通无阻，不会中断已有连接
  if command -v nft >/dev/null 2>&1; then
    run_cmd nft flush ruleset 2>/dev/null || true
  fi
}

cleanup_firewalld() {
  [[ "$OS_FAMILY" == "rhel" ]] || return 0
  has_firewalld || return 0

  log info "检测到 firewalld 已安装，正在清空规则并卸载。"
  if has_systemctl; then
    run_cmd systemctl stop firewalld 2>/dev/null || true
    run_cmd systemctl disable firewalld 2>/dev/null || true
  fi

  flush_firewall_rules

  # 卸载失败不致命：服务已停用、规则已清空，降级为警告继续安装流程
  pkg_mgr remove firewalld || log warn "卸载 firewalld 失败（服务已停用、规则已清空），请稍后手动执行 dnf remove firewalld。"
}

cleanup_ufw() {
  [[ "$OS_FAMILY" == "debian" ]] || return 0
  has_ufw || return 0

  log info "检测到 ufw 已安装，正在清空规则并卸载。"
  # ufw disable 会自行卸载其内核规则并恢复放行，不影响现有连接
  if command -v ufw >/dev/null 2>&1; then
    run_cmd ufw --force disable 2>/dev/null || true
  fi
  if has_systemctl; then
    run_cmd systemctl stop ufw 2>/dev/null || true
    run_cmd systemctl disable ufw 2>/dev/null || true
  fi

  flush_firewall_rules

  # 卸载失败不致命：服务已停用、规则已清空，降级为警告继续安装流程
  pkg_mgr remove ufw || log warn "卸载 ufw 失败（服务已停用、规则已清空），请稍后手动执行 apt-get purge ufw。"
}

# =========================
# 包管理
# =========================
tune_pkg_manager() {
  case "$OS_FAMILY" in
    debian)
      write_file "$APT_TUNE_FILE" <<'EOF'
APT::Acquire::Retries "3";
APT::Acquire::http::Timeout "10";
APT::Acquire::ftp::Timeout "10";
Acquire::Languages "none";
APT::Install-Recommends "false";
APT::Install-Suggests "false";
DPkg::Options::="--force-confdef";
DPkg::Options::="--force-confold";
Dir::Cache::pkgcache "";
Dir::Cache::srcpkgcache "";
EOF
      ;;
    rhel)
      # 该文件由 init.sh 托管；若已有内容且尚未备份，则先备份（仅首次，避免覆盖原始备份）
      if (( DRY_RUN == 1 )); then
        log dryrun "备份 dnf.conf：cp -a $DNF_CONF_FILE ${DNF_CONF_FILE}.bak.init"
      elif [[ -f "$DNF_CONF_FILE" && ! -e "${DNF_CONF_FILE}.bak.init" ]]; then
        cp -a "$DNF_CONF_FILE" "${DNF_CONF_FILE}.bak.init"
      fi
      write_file "$DNF_CONF_FILE" <<'EOF'
[main]
tsflags=nodocs
install_weak_deps=0
fastestmirror=False
gpgcheck=1
installonly_limit=3
clean_requirements_on_remove=True
best=True
skip_if_unavailable=False
exclude=kernel*
EOF
      ;;
    alpine)
      local repo_file="/etc/apk/repositories"
      if [[ -f "$repo_file" ]] && grep -qE '^[[:space:]]*#[^#].*/community([[:space:]]|$)' "$repo_file" 2>/dev/null; then
        if (( DRY_RUN == 1 )); then
          log dryrun "启用 community 仓库：解除 $repo_file 中同版本 community 仓库的注释"
        else
          sed -i -E 's|^[[:space:]]*#([^#].*/community([[:space:]]|$))|\1|' "$repo_file"
          log info "已在 $repo_file 中启用 community 仓库。"
        fi
      fi
      ;;
  esac
}

pkg_mgr() {
  local action="$1"
  shift
  case "$PKG_MANAGER" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      case "$action" in
        update) run_cmd apt-get update -y ;;
        install) run_cmd apt-get install -y --no-install-recommends "$@" ;;
        remove) run_cmd apt-get purge -y "$@" ;;
        *) die "未知包管理动作：$action" ;;
      esac
      ;;
    dnf)
      case "$action" in
        update) run_cmd dnf makecache -y ;;
        install) run_cmd dnf install -y "$@" ;;
        remove) run_cmd dnf remove -y "$@" ;;
        *) die "未知包管理动作：$action" ;;
      esac
      ;;
    apk)
      case "$action" in
        update) run_cmd apk update ;;
        install) run_cmd apk add "$@" ;;
        remove) run_cmd apk del "$@" ;;
        *) die "未知包管理动作：$action" ;;
      esac
      ;;
    *) die "未知包管理器：$PKG_MANAGER" ;;
  esac
}

collect_install_packages() {
  INSTALL_PACKAGES=(
    bash bash-completion ca-certificates curl "$PKG_DNSUTILS" git nftables
    "$PKG_SSH" sudo tmux "$PKG_VIM"
  )
  if [[ "$OS_FAMILY" == "alpine" ]]; then
    INSTALL_PACKAGES+=(tzdata shadow ncurses)
  fi
  INSTALL_ZRAM=0
  if (( IN_CONTAINER == 1 )); then
    :  # 容器环境，跳过 zram（INSTALL_ZRAM 保持 0）
  elif (( HAS_ZRAM_SUPPORT == 1 )); then
    if [[ "$OS_FAMILY" == "debian" || "$OS_FAMILY" == "alpine" ]]; then
      INSTALL_PACKAGES+=("$ZRAM_PKG")
    elif [[ "$OS_FAMILY" == "rhel" ]]; then
      INSTALL_ZRAM=1
    fi
  fi
}

install_common_packages() {
  log info "安装基础软件包。"
  tune_pkg_manager
  pkg_mgr update

  collect_install_packages
  if (( IN_CONTAINER == 1 )); then
    log warn "容器环境，跳过 $ZRAM_PKG 安装。"
  elif (( HAS_ZRAM_SUPPORT != 1 )); then
    log warn "内核未检测到 zram 支持，跳过 $ZRAM_PKG。"
  fi
  pkg_mgr install "${INSTALL_PACKAGES[@]}"

  if (( INSTALL_ZRAM == 1 )); then
    pkg_mgr install "$ZRAM_PKG" \
      || log warn "无法安装可选包 $ZRAM_PKG；其余基础软件包已继续安装，后续仅在检测到已安装时配置 zram。"
  fi
}

# =========================
# 基础系统配置
# =========================
configure_root_bashrc() {
  local target="/root/.bashrc"
  local marker="# init.sh managed aliases"

  if grep -qF "$marker" "$target" 2>/dev/null; then
    log info "root bashrc 已存在托管配置，跳过。"
    return 0
  fi

  local dircolors_line=''
  if command -v dircolors >/dev/null 2>&1; then
    dircolors_line=$'\n''eval "$(dircolors)"'
  else
    log warn "dircolors 未安装，跳过 eval dircolors 配置（其余别名仍会写入）。"
  fi

  append_file "$target" <<EOF

# init.sh managed aliases
export LS_OPTIONS='--color=auto --group-directories-first'${dircolors_line}
alias ls='ls \$LS_OPTIONS'
EOF
}

# =========================
# 时区
# =========================
http_get_quick() {
  local url="$1"
  shift

  # curl 已在 install_common_packages 中安装，且 configure_timezone 在其后调用，
  # 故此处可放心依赖 curl。所有请求统一带连接与总超时。
  command -v curl >/dev/null 2>&1 || return 0
  curl -fsSL --connect-timeout 2 --max-time 4 "$@" "$url" 2>/dev/null || true
}

timezone_from_region() {
  local region_raw="$1"
  local region
  region="$(printf '%s' "$region_raw" | tr '[:upper:]' '[:lower:]')"

  # 时区映射使用普通数组（兼容 Bash 3.x / macOS，不依赖关联数组）。
  TZ_MAP_ENTRIES=(
    "cn-:Asia/Shanghai"
    "china:Asia/Shanghai"
    "hk:Asia/Hong_Kong"
    "hongkong:Asia/Hong_Kong"
    "jp-:Asia/Tokyo"
    "japan:Asia/Tokyo"
    "kr-:Asia/Seoul"
    "korea:Asia/Seoul"
    "sg:Asia/Singapore"
    "singapore:Asia/Singapore"
    "ap-southeast-1:Asia/Singapore"
    "in-:Asia/Kolkata"
    "india:Asia/Kolkata"
    "au-:Australia/Sydney"
    "australia:Australia/Sydney"
    "eu-west-1:Europe/London"
    "uksouth:Europe/London"
    "ukwest:Europe/London"
    "london:Europe/London"
    "uk:Europe/London"
    "eu-west-:Europe/Paris"
    "france:Europe/Paris"
    "germanywestcentral:Europe/Paris"
    "westeurope:Europe/Paris"
    "northeurope:Europe/Paris"
    "eu-central-:Europe/Berlin"
    "germany:Europe/Berlin"
    "switzerland:Europe/Berlin"
    "us-east-:America/New_York"
    "eastus:America/New_York"
    "centralus:America/New_York"
    "northcentralus:America/New_York"
    "southcentralus:America/New_York"
    "us-west-:America/Los_Angeles"
    "westus:America/Los_Angeles"
    "westcentralus:America/Los_Angeles"
    # 无连字符前缀，可同时覆盖 AWS 与 GCP 格式（放在带连字符条目之后，保持更具体优先）
    "us-east:America/New_York"
    "us-west:America/Los_Angeles"
    "us-central:America/Chicago"
    "ca-:America/Toronto"
    "canada:America/Toronto"
    "br-:America/Sao_Paulo"
    "brazil:America/Sao_Paulo"
  )

  local entry key value
  for entry in "${TZ_MAP_ENTRIES[@]}"; do
    key="${entry%%:*}"
    value="${entry#*:}"
    if [[ "$key" == *- ]]; then
      [[ "$region" == "$key"* ]] && { printf '%s\n' "$value"; return 0; }
    else
      [[ "$region" == "$key"* || "$region" == *"$key"* ]] && { printf '%s\n' "$value"; return 0; }
    fi
  done
  return 1
}

timezone_from_cloud_metadata() {
  local zone="" region="" token=""

  # AWS IMDSv2：先申请 token；IMDSv2-only 实例上无 token 的 GET 会返回 401。
  # 非 EC2 环境拿不到 token，退化为无 token 请求（IMDSv1 或非 AWS）。
  if command -v curl >/dev/null 2>&1; then
    token="$(curl -fsS --connect-timeout 2 --max-time 4 -X PUT \
      -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
      "http://169.254.169.254/latest/api/token" 2>/dev/null || true)"
  fi

  local imds_url="http://169.254.169.254/latest/meta-data/placement/availability-zone"
  if [[ -n "$token" ]]; then
    zone="$(http_get_quick "$imds_url" -H "X-aws-ec2-metadata-token: ${token}")"
  else
    zone="$(http_get_quick "$imds_url")"
  fi

  if [[ -n "$zone" ]]; then
    region="${zone%[a-z]}"
    timezone_from_region "$region" && return 0
  fi

  zone="$(http_get_quick "http://metadata.google.internal/computeMetadata/v1/instance/zone" -H "Metadata-Flavor: Google")"
  if [[ -n "$zone" ]]; then
    zone="${zone##*/}"
    region="${zone%-[a-z]}"
    timezone_from_region "$region" && return 0
  fi

  region="$(http_get_quick "http://169.254.169.254/metadata/instance/compute/location?api-version=2021-02-01&format=text" -H "Metadata: true")"
  if [[ -n "$region" ]]; then
    timezone_from_region "$region" && return 0
  fi
  return 1
}

timezone_from_ip_api() {
  local timezone=""
  timezone="$(http_get_quick "https://ipapi.co/timezone")"
  [[ -n "$timezone" ]] && { printf '%s\n' "$timezone"; return 0; }

  timezone="$(http_get_quick "https://ipwho.is/" | sed -nE 's/.*"timezone"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | sed -n '1p')"
  [[ -n "$timezone" ]] && { printf '%s\n' "$timezone"; return 0; }

  timezone="$(http_get_quick "https://ipinfo.io/timezone")"
  [[ -n "$timezone" ]] && { printf '%s\n' "$timezone"; return 0; }

  return 1
}

is_valid_timezone() {
  local tz="$1"
  # 参数安全校验：含 ..、以 / 开头、或含空白字符的时区名直接拒绝
  [[ "$tz" == *".."* || "$tz" == /* || "$tz" == *[[:space:]]* ]] && return 1
  [[ -f "/usr/share/zoneinfo/$tz" ]]
}

detect_timezone() {
  local timezone=""
  [[ -n "$MANUAL_TZ" ]] && { printf '%s\n' "$MANUAL_TZ"; return 0; }
  [[ -n "${TZ:-}" ]] && { printf '%s\n' "$TZ"; return 0; }

  timezone="$(timezone_from_cloud_metadata || true)"
  [[ -n "$timezone" ]] && { printf '%s\n' "$timezone"; return 0; }

  timezone="$(timezone_from_ip_api || true)"
  [[ -n "$timezone" ]] && { printf '%s\n' "$timezone"; return 0; }

  printf '%s\n' "$TIMEZONE_FALLBACK"
}

configure_timezone() {
  [[ "$AUTO_TZ" == "1" ]] || { log info "AUTO_TZ=0，跳过时区设置。"; return 0; }

  local timezone
  timezone="$(detect_timezone)"
  if ! is_valid_timezone "$timezone"; then
    log warn "检测到的时区无效：$timezone；回退到 $TIMEZONE_FALLBACK。"
    timezone="$TIMEZONE_FALLBACK"
  fi
  if ! is_valid_timezone "$timezone"; then
    log warn "回退时区仍然无效：$timezone；跳过时区设置。"
    return 0
  fi

  log info "设置时区：$timezone。"
  if command -v timedatectl >/dev/null 2>&1; then
    run_cmd timedatectl set-timezone "$timezone" || log warn "设置时区失败：$timezone。"
  elif [[ -f "/usr/share/zoneinfo/$timezone" ]]; then
    # /etc/localtime 可能是符号链接，直接 cp -f 会写穿并覆盖 zoneinfo 源文件；先移除再复制。
    run_cmd rm -f /etc/localtime
    run_cmd cp -f "/usr/share/zoneinfo/$timezone" /etc/localtime || log warn "设置 /etc/localtime 失败：$timezone。"
    printf '%s\n' "$timezone" | write_file /etc/timezone
  else
    log warn "未找到 timedatectl 或 zoneinfo 文件，跳过时区设置：$timezone。"
  fi
}

# =========================
# 用户与 SSH
# =========================
# 将字符串转义为可用于 sed -E 正则的安全形式（用户名含 . 等元字符时必需）。
sed_escape_ere() {
  printf '%s' "$1" | sed 's/[][\.*^$()+?{}|]/\\&/g'
}

unlock_user_for_ssh_keys() {
  local user="$1"
  local shadow_file="/etc/shadow"

  [[ -r "$shadow_file" ]] || return 0

  # 获取 shadow 中的密码字段
  local pwd_field
  pwd_field="$(awk -F: -v u="$user" '$1 == u {print $2}' "$shadow_file" 2>/dev/null || true)"

  # 判定"无有效密码的锁定状态"（空、!、!*、!!），这类状态可安全改为 *：
  # 禁用密码认证的同时解除锁定，允许 SSH Key 登录。
  # 注意：形如 "!$6$..." 的"锁定但保留密码哈希"状态不在此处理，避免误删用户既有密码。
  if [[ -z "$pwd_field" || "$pwd_field" == "!" || "$pwd_field" == "!*" || "$pwd_field" == "!!" ]]; then
    log info "用户 $user 处于无密码锁定状态（shadow: '${pwd_field}'），设置密码为 '*' 以允许 SSH Key 登录。"
    if command -v usermod >/dev/null 2>&1; then
      run_cmd usermod -p '*' "$user"
    else
      if (( DRY_RUN == 1 )); then
        log dryrun "修改 $shadow_file 将 $user 密码字段设为 '*'"
      else
        local esc_user
        esc_user="$(sed_escape_ere "$user")"
        sed -i -E "s|^(${esc_user}:)[^:]*(:.*)|\1*\2|" "$shadow_file"
      fi
    fi
  fi
}

group_exists() {
  local g="$1"
  if command -v getent >/dev/null 2>&1 && getent group "$g" >/dev/null 2>&1; then
    return 0
  fi
  awk -F: -v g="$g" '$1 == g { found=1 } END { exit found ? 0 : 1 }' /etc/group 2>/dev/null
}

ensure_user() {
  if id "$TARGET_USER" >/dev/null 2>&1; then
    log info "用户已存在：$TARGET_USER。"
    local current_shell
    current_shell="$(get_user_shell "$TARGET_USER")"
    if [[ "$current_shell" != "/bin/bash" ]]; then
      log info "用户 $TARGET_USER 的默认 shell 为 ${current_shell:-<未知>}，正在修改为 /bin/bash。"
      if command -v chsh >/dev/null 2>&1; then
        run_cmd chsh -s /bin/bash "$TARGET_USER"
      elif command -v usermod >/dev/null 2>&1; then
        run_cmd usermod -s /bin/bash "$TARGET_USER"
      else
        if (( DRY_RUN == 1 )); then
          log dryrun "修改 /etc/passwd 将 $TARGET_USER 默认 shell 设为 /bin/bash"
        else
          local esc_user
          esc_user="$(sed_escape_ere "$TARGET_USER")"
          sed -i -E "s|^(${esc_user}:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:).*|\1/bin/bash|" /etc/passwd
        fi
      fi
    else
      log info "用户 $TARGET_USER 的默认 shell 已为 /bin/bash。"
    fi
  else
    if command -v useradd >/dev/null 2>&1; then
      run_cmd useradd -m -s /bin/bash "$TARGET_USER"
    else
      run_cmd adduser -D -s /bin/bash "$TARGET_USER"
    fi
    log info "创建用户：$TARGET_USER。"
  fi

  # 确保目标用户未被锁定（shadow 密码字段不能为 ! 或 !*）：
  # 初始无密码用户常被系统标为锁定（!），导致即使配置了 SSH 公钥，OpenSSH 也会因账户锁定拒绝登录。
  # 将密码字段设置为 '*'：既彻底禁用密码认证，又解除账户锁定，确保 SSH Key 正常登录。
  unlock_user_for_ssh_keys "$TARGET_USER"

  # 拒绝系统账号（UID < 1000，含 root=0、daemon=1、bin=2 等）：
  # fix_home_permissions 会递归 chown 目标用户的 home，若目标是系统账号，
  # 会把 /usr/sbin 之类的系统目录整体改属主；root 则会被 configure_sshd
  # 写入的 PermitRootLogin no 挡在 SSH 之外。dry-run 下用户可能尚未创建，此时跳过。
  local uid
  uid="$(id -u "$TARGET_USER" 2>/dev/null || true)"
  if [[ -n "$uid" ]] && (( uid < 1000 )); then
    die "TARGET_USER=${TARGET_USER} 是系统账号（UID=${uid}），拒绝继续。"
  fi

  if (( DRY_RUN == 1 )); then
    # dry-run 也先尝试 getent 解析真实 home，失败才回退默认路径
    USER_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || true)"
    [[ -z "$USER_HOME" ]] && USER_HOME="/home/$TARGET_USER"
  else
    USER_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || true)"
    [[ -z "$USER_HOME" ]] && USER_HOME="$(awk -F: -v u="$TARGET_USER" '$1 == u {print $6; exit}' /etc/passwd 2>/dev/null || true)"
    if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
      log warn "无法解析用户 home 目录（解析结果：${USER_HOME:-<空>}）。"
      die "请确认 ${TARGET_USER} 的 home 目录是否正常存在。"
    fi
  fi

  # fix_home_permissions 会递归 chown USER_HOME，因此只接受 /home/ 下的路径。
  # 白名单比枚举系统目录可靠；先规范化末尾斜杠，防止 /home/ 绕过。
  USER_HOME="${USER_HOME%/}"
  if [[ "$USER_HOME" != /home/* ]]; then
    die "USER_HOME 必须位于 /home 下：${USER_HOME:-<空>}，拒绝执行递归 chown。"
  fi

  # Alpine 的 shadow useradd 或复用既有用户时可能没有同名组；
  # 缺少同名组会导致后续 chown user:user / install -g 失败，此处兜底补建。
  if ! group_exists "$TARGET_USER"; then
    if command -v groupadd >/dev/null 2>&1; then
      run_cmd groupadd "$TARGET_USER" || log warn "创建同名组失败：$TARGET_USER，后续 chown 可能失败。"
    elif command -v addgroup >/dev/null 2>&1; then
      run_cmd addgroup "$TARGET_USER" || log warn "创建同名组失败：$TARGET_USER，后续 chown 可能失败。"
    else
      log warn "未找到 groupadd/addgroup，无法为 $TARGET_USER 创建同名组。"
    fi
  fi

  DOTFILES_DIR="$USER_HOME/.dotfiles"
}

add_user_to_group_if_exists() {
  local group="$1"
  if group_exists "$group"; then
    if command -v usermod >/dev/null 2>&1; then
      run_cmd usermod -aG "$group" "$TARGET_USER"
    else
      run_cmd addgroup "$TARGET_USER" "$group"
    fi
  else
    log warn "用户组不存在，跳过：$group。"
  fi
}

configure_user_groups() {
  add_user_to_group_if_exists "$SUDO_GROUP"
  group_exists "systemd-journal" && add_user_to_group_if_exists "systemd-journal"
  [[ "$OS_FAMILY" == "debian" ]] && add_user_to_group_if_exists "users"
  return 0
}

configure_authorized_keys() {
  local ssh_dir="$USER_HOME/.ssh"
  local auth_file="$ssh_dir/authorized_keys"

  run_cmd install -d -m 700 -o "$TARGET_USER" -g "$TARGET_USER" "$ssh_dir"
  # 防符号链接劫持：authorized_keys 若为软链则删除重建，避免跟随链接破坏任意文件
  if (( DRY_RUN == 0 )) && [[ -L "$auth_file" ]]; then
    log warn "$auth_file 是符号链接，已删除后重建为普通文件。"
    rm -f "$auth_file"
  fi
  run_cmd touch "$auth_file"
  run_cmd chown "$TARGET_USER:$TARGET_USER" "$auth_file"
  run_cmd chmod 600 "$auth_file"

  if [[ -z "$SSH_PUBKEYS" ]]; then
    log warn "SSH_PUBKEYS 为空，未写入登录公钥。"
    return 0
  fi

  if (( DRY_RUN == 1 )); then
    log dryrun "确保 $auth_file 包含 SSH 公钥。"
  else
    # 按行拆分 SSH_PUBKEYS，跳过空行，逐条去重后追加
    while IFS= read -r pubkey; do
      [[ -z "$pubkey" ]] && continue
      if ! grep -qxF "$pubkey" "$auth_file"; then
        printf '%s\n' "$pubkey" >> "$auth_file"
      fi
    done <<< "$SSH_PUBKEYS"
  fi
}

configure_sudoers() {
  local file="/etc/sudoers.d/90-${TARGET_USER}"
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$TARGET_USER" | write_file "$file"
  run_cmd chmod 0440 "$file"

  if (( DRY_RUN == 1 )); then
    log dryrun "校验 sudoers：visudo -cf $file"
    return 0
  fi
  require_cmd visudo
  visudo -cf "$file" || die "sudoers 语法校验失败：$file"
}

# 校验目标用户已配置至少一个有效 SSH 公钥；不满足时拒绝重启 sshd 以防锁死。
ensure_authorized_keys_valid() {
  local auth_file="$USER_HOME/.ssh/authorized_keys"
  if (( DRY_RUN == 1 )); then
    log dryrun "校验 $TARGET_USER 的有效 SSH 公钥（authorized_keys）。"
    return 0
  fi
  if [[ ! -f "$auth_file" ]] || [[ ! -s "$auth_file" ]] || \
      ! grep -qE '^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:space:]]' "$auth_file"; then
    die "未找到 $TARGET_USER 的有效 SSH 公钥，拒绝重启 sshd 以防锁死。"
  fi
}

configure_sshd() {
  local dir="/etc/ssh/sshd_config.d"
  local file="$dir/99-${TARGET_USER}.conf"
  local main_sshd_config="/etc/ssh/sshd_config"

  if ! grep -Eq '^[[:space:]]*Include[[:space:]].*sshd_config\.d' "$main_sshd_config" 2>/dev/null; then
    if (( DRY_RUN == 1 )); then
      log dryrun "向 $main_sshd_config 顶部添加：Include /etc/ssh/sshd_config.d/*.conf"
    else
      if [[ -f "$main_sshd_config" && ! -e "${main_sshd_config}.bak.init" ]]; then
        cp -a "$main_sshd_config" "${main_sshd_config}.bak.init"
      fi
      local tmp_conf
      tmp_conf="$(mktemp)" || die "无法创建临时文件。"
      {
        printf 'Include /etc/ssh/sshd_config.d/*.conf\n\n'
        if [[ -f "$main_sshd_config" ]]; then
          cat "$main_sshd_config"
        fi
      } > "$tmp_conf"
      cat "$tmp_conf" > "$main_sshd_config"
      rm -f "$tmp_conf"
      log info "已向 $main_sshd_config 顶部添加 Include drop-in 目录配置。"
    fi
  fi

  run_cmd install -d -m 755 "$dir"
  {
    if [[ -n "$SSH_PORT" ]]; then
      printf 'Port %s\n' "$SSH_PORT"
    fi
    if [[ -f /etc/ssh/ssh_host_ed25519_key ]]; then
      printf 'HostKey /etc/ssh/ssh_host_ed25519_key\n'
    else
      log warn "未找到 ed25519 HostKey，不强制指定 HostKey。"
    fi
    printf '\n'
    printf 'PermitRootLogin no\n'
    printf 'PasswordAuthentication no\n'
    printf 'KbdInteractiveAuthentication no\n'
    printf 'PubkeyAuthentication yes\n'
    printf '\n'
    printf 'ClientAliveInterval 60\n'
    printf 'X11Forwarding no\n'
  } | write_file "$file"

  # 清理已有配置中的密码认证与交互式认证，防止因 OpenSSH 首次匹配原则导致 99 drop-in 被前面的配置覆盖
  local conf_files=("$main_sshd_config")
  local extra_conf
  for extra_conf in "$dir"/*.conf; do
    [[ -f "$extra_conf" && "$extra_conf" != "$file" ]] && conf_files+=("$extra_conf")
  done

  local cf
  for cf in "${conf_files[@]}"; do
    [[ -f "$cf" ]] || continue
    if grep -Eqi '^[[:space:]]*(PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)[[:space:]]+yes' "$cf" 2>/dev/null; then
      if (( DRY_RUN == 1 )); then
        log dryrun "发现 $cf 包含启用的密码/交互式认证配置，将被统一修改为 no。"
      else
        if [[ ! -e "${cf}.bak.init" ]]; then
          cp -a "$cf" "${cf}.bak.init"
        fi
        sed -i -E \
          -e 's|^[[:space:]]*[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd][Aa][Uu][Tt][Hh][Ee][Nn][Tt][Ii][Cc][Aa][Tt][Ii][Oo][Nn][[:space:]]+[Yy][Ee][Ss].*|PasswordAuthentication no|' \
          -e 's|^[[:space:]]*[Kk][Bb][Dd][Ii][Nn][Tt][Ee][Rr][Aa][Cc][Tt][Ii][Vv][Ee][Aa][Uu][Tt][Hh][Ee][Nn][Tt][Ii][Cc][Aa][Tt][Ii][Oo][Nn][[:space:]]+[Yy][Ee][Ss].*|KbdInteractiveAuthentication no|' \
          -e 's|^[[:space:]]*[Cc][Hh][Aa][Ll][Ll][Ee][Nn][Gg][Ee][Rr][Ee][Ss][Pp][Oo][Nn][Ss][Ee][Aa][Uu][Tt][Hh][Ee][Nn][Tt][Ii][Cc][Aa][Tt][Ii][Oo][Nn][[:space:]]+[Yy][Ee][Ss].*|ChallengeResponseAuthentication no|' \
          "$cf"
        log info "已将 $cf 中的密码/交互式认证强制修改为 no。"
      fi
    fi
  done

  if (( DRY_RUN == 1 )); then
    log dryrun "校验 sshd 配置：sshd -t"
  else
    require_cmd sshd
    sshd -t || die "sshd 配置校验失败：$file"
  fi

  if has_systemctl; then
    # Ubuntu 22.10+/24.04 等使用 systemd socket activation 管理 ssh 监听端口，
    # 此时 sshd_config 中的 Port 会被忽略，必须改写 ssh.socket 的 ListenStream 才能真正改端口。
    local use_ssh_socket=0
    if [[ -n "$SSH_PORT" ]] && (systemctl is-enabled ssh.socket >/dev/null 2>&1 || systemctl is-active ssh.socket >/dev/null 2>&1); then
      use_ssh_socket=1
    fi

    if (( use_ssh_socket == 1 )); then
      log info "检测到 ssh.socket（socket activation），改写其监听端口为 $SSH_PORT。"
      local sock_dir="/etc/systemd/system/ssh.socket.d"
      run_cmd install -d -m 755 "$sock_dir"
      {
        printf '[Socket]\n'
        printf 'ListenStream=\n'
        printf 'ListenStream=%s\n' "$SSH_PORT"
      } | write_file "$sock_dir/init.sh-listen.conf"
    fi

    # 重启前校验公钥，避免锁死：ssh 服务将禁用密码登录，若无可登录公钥则危险
    ensure_authorized_keys_valid

    if (( DRY_RUN == 1 )); then
      run_cmd systemctl enable "$SSH_SERVICE"
    else
      systemctl enable "$SSH_SERVICE" >/dev/null 2>&1 || log warn "启用 SSH 服务失败，但继续尝试重启。"
    fi
    run_cmd systemctl daemon-reload
    if (( use_ssh_socket == 1 )); then
      run_cmd systemctl restart ssh.socket
    fi
    run_cmd systemctl restart "$SSH_SERVICE"
  elif has_openrc; then
    # 重启前校验公钥，避免锁死：ssh 服务将禁用密码登录，若无可登录公钥则危险
    ensure_authorized_keys_valid

    # 若找不到 host key，生成 host key（Alpine 初始安装 openssh 时常缺少 host key）
    if ! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
      run_cmd ssh-keygen -A 2>/dev/null || log warn "生成 host key 失败（ssh-keygen -A）。"
    fi

    run_cmd rc-update add "$SSH_SERVICE" default 2>/dev/null || run_cmd rc-update add "$SSH_SERVICE" 2>/dev/null || true
    if rc-service "$SSH_SERVICE" status >/dev/null 2>&1; then
      run_cmd rc-service "$SSH_SERVICE" restart 2>/dev/null || log warn "重启 $SSH_SERVICE 失败。"
    else
      run_cmd rc-service "$SSH_SERVICE" start 2>/dev/null || log warn "启动 $SSH_SERVICE 失败。"
    fi
  else
    log warn "未找到 systemctl 或 OpenRC，跳过 SSH 服务启用与重启。"
    return 0
  fi
}

# =========================
# dotfiles 与编辑器
# =========================
is_ipv6_only_network() {
  local has_v4=0
  local has_v6=0
  command -v ip >/dev/null 2>&1 || return 1

  if ip -4 route show default 2>/dev/null | grep -q '^'; then
    has_v4=1
  fi
  if ip -6 route show default 2>/dev/null | grep -q '^'; then
    has_v6=1
  fi

  (( has_v6 == 1 && has_v4 == 0 ))
}

add_github_hosts_ipv6() {
  local hosts_file="/etc/hosts"
  local lines=(
    "2a01:4f8:c010:d56::2 github.com"
    "2a01:4f8:c010:d56::3 api.github.com"
    "2a01:4f8:c010:d56::4 codeload.github.com"
    "2a01:4f8:c010:d56::6 ghcr.io"
    "2a01:4f8:c010:d56::7 pkg.github.com npm.pkg.github.com maven.pkg.github.com nuget.pkg.github.com rubygems.pkg.github.com"
    "2a01:4f8:c010:d56::8 uploads.github.com"
    "2606:50c0:8000::133 objects.githubusercontent.com www.objects.githubusercontent.com release-assets.githubusercontent.com gist.githubusercontent.com repository-images.githubusercontent.com camo.githubusercontent.com private-user-images.githubusercontent.com avatars0.githubusercontent.com avatars1.githubusercontent.com avatars2.githubusercontent.com avatars3.githubusercontent.com cloud.githubusercontent.com desktop.githubusercontent.com support.github.com"
    "2606:50c0:8000::154 support-assets.githubassets.com github.githubassets.com opengraph.githubassets.com github-registry-files.githubusercontent.com github-cloud.githubusercontent.com"
  )

  log warn "检测到 IPv6 单栈网络，添加 GitHub hosts 回退记录。"
  local line
  for line in "${lines[@]}"; do
    append_line_if_missing "$hosts_file" "$line"
  done
}

remove_github_hosts_ipv6() {
  local hosts_file="/etc/hosts"
  local patterns=(
    '2a01:4f8:c010:d56::2[[:space:]]'
    '2a01:4f8:c010:d56::3[[:space:]]'
    '2a01:4f8:c010:d56::4[[:space:]]'
    '2a01:4f8:c010:d56::6[[:space:]]'
    '2a01:4f8:c010:d56::7[[:space:]]'
    '2a01:4f8:c010:d56::8[[:space:]]'
    '2606:50c0:8000::133[[:space:]]'
    '2606:50c0:8000::154[[:space:]]'
  )

  if (( DRY_RUN == 1 )); then
    log dryrun "清理 /etc/hosts 中的 GitHub IPv6 条目。"
    return 0
  fi

  # /etc/hosts 在容器中常以 bind mount 挂载，sed -i 的 rename 语义会失败
  # （Device or resource busy）；改为写临时文件后原地覆盖，不更换 inode。
  local filter="" pat
  for pat in "${patterns[@]}"; do
    filter+="${filter:+|}${pat}"
  done

  local tmp
  tmp="$(mktemp)" || { log warn "无法创建临时文件，跳过清理 /etc/hosts。"; return 0; }
  if grep -Ev "^[[:space:]]*(${filter})" "$hosts_file" > "$tmp" 2>/dev/null; then
    cat "$tmp" > "$hosts_file" 2>/dev/null || log warn "写回 $hosts_file 失败。"
  else
    log warn "读取 $hosts_file 失败，保持原文件不变。"
  fi
  rm -f "$tmp"
}

# 用法: clone_dotfiles_repo <repo>
# 以目标用户身份浅克隆到 $DOTFILES_DIR；成功则置 DOTFILES_AVAILABLE=1 并修正属主。
clone_dotfiles_repo() {
  local repo="$1"
  sudo -u "$TARGET_USER" -H env GIT_TERMINAL_PROMPT=0 git \
    -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15 \
    clone --depth 1 -- "$repo" "$DOTFILES_DIR" || return 1
  DOTFILES_AVAILABLE=1
  chown -R "$TARGET_USER:$TARGET_USER" "$DOTFILES_DIR" 2>/dev/null || log warn "无法更改 dotfiles 所有权。"
  log info "dotfiles 已克隆：$(sudo -u "$TARGET_USER" -H git -C "$DOTFILES_DIR" rev-parse --short HEAD 2>/dev/null || true)"
}

clone_or_update_dotfiles() {
  DOTFILES_AVAILABLE=0
  if (( DRY_RUN == 1 )); then
    log dryrun "如果 $DOTFILES_DIR 已存在则 git pull，否则 clone $DOTFILES_REPO；失败则 clone $DOTFILES_FALLBACK_REPO。"
    return 0
  fi

  # IPv6 单栈网络：加 hosts 记录。用 EXIT trap 而非 RETURN，
  # 确保 clone 中途 die（exit）时也会清理 /etc/hosts，避免残留。
  if is_ipv6_only_network; then
    add_github_hosts_ipv6
    trap 'remove_github_hosts_ipv6' EXIT
  fi

  if [[ -d "$DOTFILES_DIR/.git" ]]; then
    if sudo -u "$TARGET_USER" -H env GIT_TERMINAL_PROMPT=0 git -C "$DOTFILES_DIR" pull --ff-only; then
      chown -R "$TARGET_USER:$TARGET_USER" "$DOTFILES_DIR"
      DOTFILES_AVAILABLE=1
      return 0
    else
      log warn "dotfiles 目录已存在，但更新失败（保留本地副本）：$DOTFILES_DIR。"
      log warn "后续将跳过 dotfiles 相关配置（sysctl、link、vimrc）。"
      return 0
    fi
  fi

  if [[ -e "$DOTFILES_DIR" ]]; then
    log warn "dotfiles 目标路径已存在但不是 git 仓库：$DOTFILES_DIR；为避免误删，跳过克隆。"
    return 0
  fi

  clone_dotfiles_repo "$DOTFILES_REPO" && return 0
  log warn "主 dotfiles 仓库克隆失败：$DOTFILES_REPO。"
  clone_dotfiles_repo "$DOTFILES_FALLBACK_REPO" && return 0
  die "主仓库和备用仓库均克隆失败，无法继续。"
}

apply_sysctl_custom() {
  [[ "$DOTFILES_AVAILABLE" == 1 ]] || { log warn "dotfiles 不可用，跳过自定义 sysctl 配置。"; return 0; }
  if (( IN_CONTAINER == 1 )); then
    log info "容器环境，跳过自定义 sysctl 配置（不复制 88-custom.conf）。"
    return 0
  fi
  local src="$DOTFILES_DIR/etc/sysctl.d/88-custom.conf"
  local dst="/etc/sysctl.d/88-custom.conf"

  if (( DRY_RUN == 1 )); then
    log dryrun "如果存在则复制 $src 到 $dst，并逐条应用 sysctl 配置。"
    return 0
  fi
  if [[ -f "$src" ]]; then
    if [[ ! -r "$src" ]]; then
      log warn "sysctl 配置文件存在但不可读：$src。"
      return 0
    fi
    if ! cp -f "$src" "$dst"; then
      log warn "复制 sysctl 配置失败：$src -> $dst；跳过临时 sysctl 配置。"
      return 0
    fi
    local line
    local lineno=0
    log warn "以下 sysctl 配置来自远端 dotfiles 仓库（$src），请确认内容可信。"
    # 在独立 FD 上打开文件；打开失败直接 warning + return 0
    exec 3< "$src" 2>/dev/null || { log warn "打开 sysctl 配置文件失败：$src"; return 0; }
    set +e
    while IFS= read -r line <&3; do
      lineno=$(( lineno + 1 ))
      # 去除行内注释
      line="${line%%#*}"
      # 去除首尾空白
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      # 跳过空行
      [[ -z "$line" ]] && continue
      # 只处理包含 = 的行
      [[ "$line" != *=* ]] && continue
      # 提取 key 和 value
      local key value
      IFS='=' read -r key value <<< "$line"
      key="${key#"${key%%[![:space:]]*}"}"
      key="${key%"${key##*[![:space:]]}"}"
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
      [[ -z "$key" ]] && continue
      line="$key=$value"
      sysctl -w "$line" >/dev/null 2>&1 || log warn "sysctl 应用失败（第 ${lineno} 行）：$line"
    done <&3
    set -e
    exec 3<&-
  else
    log warn "未找到 sysctl 配置：$src。"
  fi
  return 0
}

link_dotfiles() {
  [[ "$DOTFILES_AVAILABLE" == 1 ]] || { log warn "dotfiles 不可用，跳过 dotfiles 链接。"; return 0; }
  local files=(
    .bash .bash_aliases .bash_logout .bash_profile
    .bashrc .gitconfig .gitignore_global .inputrc .tmux.conf .toprc
  )
  local file
  for file in "${files[@]}"; do
    if (( DRY_RUN == 1 )); then
      log dryrun "强制链接：$DOTFILES_DIR/$file -> $USER_HOME/$file"
    elif [[ -e "$DOTFILES_DIR/$file" ]]; then
      ln -sfn "$DOTFILES_DIR/$file" "$USER_HOME/$file"
      chown -h "$TARGET_USER:$TARGET_USER" "$USER_HOME/$file" || log warn "无法更改 $file 所有权。"
    fi
  done

  for file in .inputrc .toprc .tmux.conf; do
    if (( DRY_RUN == 1 )); then
      log dryrun "复制：$USER_HOME/$file -> /root/$file"
    elif [[ -e "$USER_HOME/$file" ]]; then
      # 为 root 复制独立文件（属主 root:root），严禁软链接到普通用户可写文件，防止提权
      install -m 644 -o root -g root "$USER_HOME/$file" "/root/$file"
    fi
  done
}

write_vimrc() {
  [[ "$DOTFILES_AVAILABLE" == 1 ]] || { log warn "dotfiles 不可用，跳过写入 vimrc。"; return 0; }
  local target="$USER_HOME/.vimrc"
  # 防符号链接劫持：root 写入前若 target 是软链，先删除，避免跟随链接覆盖任意文件
  if (( DRY_RUN == 0 )) && [[ -L "$target" ]]; then
    log warn "$target 是符号链接，已删除后重建为普通文件。"
    rm -f "$target"
  fi
  write_file "$target" <<'EOF'
set nocompatible
set encoding=utf-8
scriptencoding utf-8
set termencoding=utf-8
set fileencoding=utf-8
set fileencodings=ucs-bom,utf-8,gb18030,big5,euc-jp,euc-kr,latin1
set fileformats=unix,dos,mac

set list!
" 精简版 vim（vim-tiny/vim-minimal）下部分选项可能不支持，使用 silent! 容错。
silent! set listchars=tab:>\ ,trail:.,extends:>,precedes:<
set backspace=eol,start,indent
set visualbell t_vb=
silent! set virtualedit=onemore
silent! set formatoptions-=t formatoptions+=croql

set smarttab
set expandtab
set tabstop=4 softtabstop=4 shiftwidth=4
set autoindent smartindent shiftround

set ignorecase
set smartcase
EOF
  run_cmd chown "$TARGET_USER:$TARGET_USER" "$target"
  # 为 root 复制独立文件（属主 root:root），严禁软链接到普通用户可写文件，防止提权
  run_cmd install -m 644 -o root -g root "$target" /root/.vimrc
}

# =========================
# zram 与 swap
# =========================
has_non_zram_swap() {
  # /proc/swaps 是通用接口（BusyBox 的 swapon 不支持 --show），优先解析该文件。
  if [[ -r /proc/swaps ]] && \
     awk 'NR > 1 && $1 !~ /zram/ { found=1 } END { exit found ? 0 : 1 }' /proc/swaps 2>/dev/null; then
    return 0
  fi
  # util-linux 环境后备：按 TYPE 过滤 zram 设备。
  swapon --show=NAME,TYPE --noheadings 2>/dev/null \
    | awk '$1 !~ /(^|\/)zram[0-9]*$/ && $2 != "zram" { found=1 } END { exit found ? 0 : 1 }'
}

has_fstab_swap() {
  grep -Eq '^[[:space:]]*[^#].+[[:space:]]+swap[[:space:]]+swap([[:space:]]+|$)' /etc/fstab 2>/dev/null
}

is_zram_pkg_installed() {
  case "$ZRAM_PKG" in
    zram-tools)
      dpkg-query -W -f='${Status}' zram-tools 2>/dev/null | grep -q 'install ok installed'
      ;;
    systemd-zram-generator)
      dpkg-query -W -f='${Status}' systemd-zram-generator 2>/dev/null | grep -q 'install ok installed'
      ;;
    zram-generator|"")
      # RHEL：ZRAM_PKG 为空时同样按 zram-generator 检测（rpm 与 generator 文件双重兜底）
      rpm -q zram-generator >/dev/null 2>&1 \
        || [[ -f /usr/lib/systemd/system-generators/zram-generator ]] \
        || [[ -f /lib/systemd/system-generators/zram-generator ]]
      ;;
    zram-init)
      apk info -e zram-init >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

configure_zram() {
  if (( IN_CONTAINER == 1 )); then
    log warn "容器环境，跳过 zram 配置。"
    return 0
  fi
  if (( HAS_ZRAM_SUPPORT == 0 )); then
    log warn "内核不支持 zram，跳过 zram 配置。"
    return 0
  fi

  # 检查对应发行版的 zram 包是否已安装
  if (( DRY_RUN == 0 )) && ! is_zram_pkg_installed; then
    log warn "当前系统未安装 $ZRAM_PKG，跳过 zram 配置。"
    return 0
  fi

  # zram-tools 用 /etc/default/zramswap；zram-init 用 /etc/conf.d/zram-init；zram-generator 系列统一用 $ZRAM_CONF_FILE
  if [[ "$ZRAM_CONF_FILE" == "/etc/default/zramswap" ]]; then
    write_file "$ZRAM_CONF_FILE" <<'EOF'
PERCENT=50
EOF
  elif [[ "$ZRAM_CONF_FILE" == "/etc/conf.d/zram-init" ]]; then
    local total_mem_mb
    total_mem_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 1024)"
    local zram_size=$(( total_mem_mb / 2 ))
    (( zram_size > 1024 )) && zram_size=1024
    (( zram_size < 128 )) && zram_size=128
    write_file "$ZRAM_CONF_FILE" <<EOF
load_on_start=yes
unload_on_stop=yes
num_devices=1
type0=swap
size0=$zram_size
algo0=zstd
EOF
  else
    write_file "$ZRAM_CONF_FILE" <<'EOF'
[zram0]
zram-size = min(ram / 2, 1024)
swap-priority = 32767
EOF
  fi

  if has_systemctl; then
    run_cmd systemctl daemon-reload
    run_cmd systemctl restart "$ZRAM_SERVICE" 2>/dev/null || log warn "zram 服务启动失败；可能未安装 $ZRAM_PKG 或系统不支持。"
  elif has_openrc; then
    run_cmd rc-update add "$ZRAM_SERVICE" default 2>/dev/null || run_cmd rc-update add "$ZRAM_SERVICE" 2>/dev/null || true
    if rc-service "$ZRAM_SERVICE" status >/dev/null 2>&1; then
      run_cmd rc-service "$ZRAM_SERVICE" restart 2>/dev/null || log warn "重启 $ZRAM_SERVICE 服务失败。"
    else
      run_cmd rc-service "$ZRAM_SERVICE" start 2>/dev/null || log warn "启动 $ZRAM_SERVICE 服务失败；可能未安装 $ZRAM_PKG 或系统不支持。"
    fi
  else
    log warn "未找到 systemctl 或 OpenRC，跳过 zram 服务操作。"
    return 0
  fi
}

configure_swapfile() {
  if (( IN_CONTAINER == 1 )); then
    log info "容器环境，跳过 swapfile 配置。"
    return 0
  fi
  if (( HAS_SWAP_SUPPORT == 0 )); then
    log warn "系统不支持 swap 或缺少 swapon，跳过 swapfile。"
    return 0
  fi
  if (( SWAP_SIZE_MB == 0 )); then
    log info "SWAP_SIZE_MB=0，跳过 swapfile。"
    return 0
  fi

  if (( DRY_RUN == 1 )); then
    log dryrun "检查已有 swap 和 /etc/fstab 后，按需创建 /swap（${SWAP_SIZE_MB}M）。"
  else
    if has_non_zram_swap; then
      log info "系统已有启用中的非 zram swap，跳过创建 /swap。"
      return 0
    fi
    if has_fstab_swap; then
      log warn "/etc/fstab 已有 swap 条目，跳过创建 /swap，避免重复配置。"
      return 0
    fi
  fi

  local swap_file="/swap"
  if [[ ! -f "$swap_file" ]]; then
    # 磁盘空间预检：fallocate/dd 写满根分区会留下无效残留，且下次运行会因
    # 不是有效 swap 文件被永久跳过。预留 256MB 给系统本身。
    if (( DRY_RUN == 0 )); then
      local avail_mb
      avail_mb="$(df -Pm / 2>/dev/null | awk 'NR==2 {print $4}' || true)"
      if [[ ! "$avail_mb" =~ ^[0-9]+$ ]]; then
        log warn "无法检测根分区可用空间，跳过创建 swapfile。"
        return 0
      fi
      if (( avail_mb < SWAP_SIZE_MB + 256 )); then
        log warn "根分区可用空间不足（可用 ${avail_mb}MB，需要 $(( SWAP_SIZE_MB + 256 ))MB 含预留），跳过创建 swapfile。"
        return 0
      fi
    fi

    # 检测 /swap 所在根文件系统类型
    local fs_type=""
    fs_type="$(stat -f -c '%T' / 2>/dev/null || true)"

    local create_ok=1
    if [[ "$fs_type" == "btrfs" ]]; then
      # Btrfs：须先创建空文件并禁用 CoW，否则 swapon 报 Invalid argument
      log info "检测到 Btrfs 文件系统，使用 chattr +C 禁用 CoW 后创建 swap 文件。"
      run_cmd touch "$swap_file"
      run_cmd chattr +C "$swap_file" || true
      run_cmd dd if=/dev/zero of="$swap_file" bs=1M count="$SWAP_SIZE_MB" || create_ok=0
    else
      run_cmd fallocate -l "${SWAP_SIZE_MB}M" "$swap_file" \
        || run_cmd dd if=/dev/zero of="$swap_file" bs=1M count="$SWAP_SIZE_MB" \
        || create_ok=0
    fi
    if (( create_ok == 0 )); then
      if (( DRY_RUN == 0 )); then
        rm -f "$swap_file"
      fi
      log warn "创建 swap 文件失败（磁盘空间不足？），已清理残留：$swap_file。"
      return 0
    fi
    run_cmd chmod 600 "$swap_file"
    run_cmd mkswap "$swap_file"
  elif ! command -v file >/dev/null 2>&1; then
    log warn "file 命令不可用，跳过对已存在 $swap_file 的校验。"
    return 0
  elif ! file "$swap_file" 2>/dev/null | grep -qi 'swap file'; then
    log warn "$swap_file 已存在但不是有效 swap 文件，跳过启用，避免破坏现有文件。"
    return 0
  fi

  run_cmd swapon "$swap_file"
  append_line_if_missing /etc/fstab '/swap swap swap sw,pri=0 0 0'
  log info "swapfile 已配置：$swap_file。"
}

fix_home_permissions() {
  # -h: 不解引用符号链接，防止用户预置 symlink 劫持 root 的 chown（如 ln -s /etc/shadow）
  # 只处理常规文件、目录与符号链接本身，跳过 fifo、socket、设备等异常对象
  run_cmd find "$USER_HOME" -xdev -not -path '*/.git/*' \
    \( -type f -o -type d -o -type l \) \
    -exec chown -h "$TARGET_USER:$TARGET_USER" {} +
}

# =========================
# 主流程
# =========================
do_install() {
  require_root
  detect_container && IN_CONTAINER=1 || IN_CONTAINER=0
  detect_os
  detect_kernel_features
  if (( IN_CONTAINER == 1 )); then
    log info "运行环境：容器（${CONTAINER_KIND:-未知}）"
  else
    log info "运行环境：非容器（虚拟机/物理机）"
  fi
  collect_inputs install
  verify_inputs
  disable_selinux
  cleanup_firewalld
  cleanup_ufw

  install_common_packages
  configure_timezone
  configure_root_bashrc

  ensure_user
  configure_user_groups
  configure_authorized_keys
  configure_sudoers
  configure_sshd

  clone_or_update_dotfiles
  apply_sysctl_custom
  link_dotfiles
  write_vimrc

  configure_zram
  configure_swapfile
  fix_home_permissions

  log info "初始化完成。请新开 SSH 会话验证登录后，再关闭当前连接。"
}

print_check_summary() {
  log info "当前系统：${OS_ID} ${OS_VERSION_ID}（包管理器：${PKG_MANAGER}）"
  if (( IN_CONTAINER == 1 )); then
    log info "运行环境：容器（${CONTAINER_KIND:-未知}）"
  else
    log info "运行环境：非容器（虚拟机/物理机）"
  fi
  local display_ssh_port
  if [[ -n "$SSH_PORT" ]]; then
    display_ssh_port="$SSH_PORT"
  else
    display_ssh_port="系统默认(22)"
  fi
  log info "目标用户：${TARGET_USER}，SSH 端口：${display_ssh_port}，SSH 服务：${SSH_SERVICE}，sudo 组：${SUDO_GROUP}"
  log info "zram 支持：${HAS_ZRAM_SUPPORT}，swap 支持：${HAS_SWAP_SUPPORT}"
  if [[ "$OS_FAMILY" == "rhel" ]]; then
    local selinux_status="未安装/未知"
    if command -v getenforce >/dev/null 2>&1; then
      selinux_status="$(getenforce 2>/dev/null || echo "未知")"
    fi
    log info "SELinux 状态：$selinux_status"
    if has_firewalld; then
      log info "防火墙：检测到 firewalld 已安装（安装流程中将被清空并卸载）。"
    else
      log info "防火墙：未检测到 firewalld。"
    fi
  elif [[ "$OS_FAMILY" == "debian" ]]; then
    if has_ufw; then
      log info "防火墙：检测到 ufw 已安装（安装流程中将被清空并卸载）。"
    else
      log info "防火墙：未检测到 ufw。"
    fi
  else
    local fw_info=()
    command -v nft >/dev/null 2>&1 && fw_info+=("nftables")
    command -v iptables >/dev/null 2>&1 && fw_info+=("iptables")
    if (( ${#fw_info[@]} > 0 )); then
      log info "防火墙：检测到 ${fw_info[*]}。"
    else
      log info "防火墙：未检测到专用防火墙前端服务。"
    fi
  fi

  collect_install_packages
  local pkg
  for pkg in "${INSTALL_PACKAGES[@]}"; do
    log info "预装软件包：$pkg"
  done
  if (( INSTALL_ZRAM == 1 )); then
    log info "可选安装：$ZRAM_PKG"
  fi
  if (( IN_CONTAINER == 1 )); then
    log info "容器环境，跳过 zram 安装。"
  fi
}

do_check() {
  # check 为只读诊断，允许普通用户运行（无需 root）；权限不足的项会降级为提示。
  detect_container && IN_CONTAINER=1 || IN_CONTAINER=0
  collect_inputs check
  verify_inputs
  detect_os
  detect_kernel_features
  print_check_summary

  if (( EUID == 0 )); then
    if command -v sshd >/dev/null 2>&1 && [[ -f /etc/ssh/sshd_config ]]; then
      if sshd -t 2>/dev/null; then
        log info "sshd 配置校验通过。"
      else
        log warn "sshd 配置校验失败（sshd -t）。"
      fi
    fi
    if command -v visudo >/dev/null 2>&1; then
      local sudofile="/etc/sudoers.d/90-${TARGET_USER}"
      if [[ -f "$sudofile" ]]; then
        if visudo -cf "$sudofile" 2>/dev/null; then
          log info "sudoers 配置校验通过：$sudofile。"
        else
          log warn "sudoers 配置校验失败：$sudofile。"
        fi
      else
        log warn "sudoers 文件不存在，跳过校验：$sudofile。"
      fi
    fi
  else
    log info "以普通用户运行，跳过 sshd/sudoers 深度校验（需 root）。"
  fi

  log info "检查通过。"
}

usage() {
  cat <<'EOF'
用法：
  ./init.sh [--dry-run|-n] install
  ./init.sh [--dry-run|-n] check
  ./init.sh --help|-h          显示帮助
  ./init.sh --version|-V       显示版本

支持的系统：
  Debian 11/12/13、Ubuntu 22.04/24.04/25.04、
  AlmaLinux/Rocky/CentOS 9/10、Alpine Linux 3.x

交互模式（install）：
  TARGET_USER 未通过环境变量指定时：优先复用系统中已有的 UID 1000 用户；
  否则在终端下询问（默认 user），无 tty 时回退默认值。
  SSH_PUBKEYS 必填：未通过环境变量指定时，交互时须至少粘贴一个公钥，
  无 tty 时直接报错退出。
  SSH_PORT / SWAP_SIZE_MB 未指定时：非容器环境询问（默认 22 / 512MB）；
  LXC/OpenVZ/Docker/Podman 容器环境不显式配置 SSH 端口（保持系统默认 22）并跳过 swap、zram。
  安装过程还会：将目标用户默认 shell 修正为 /bin/bash、解除无密码锁定
  （shadow 密码字段置 *，保障 SSH Key 登录），并禁用 sshd 密码与交互式认证。
交互模式（check）：
  只读诊断，不修改系统；不询问交互项，TARGET_USER 未指定时自动检测或取默认值。

可选环境变量：
  TARGET_USER, SSH_PUBKEYS, SSH_PORT, SWAP_SIZE_MB
  AUTO_TZ(0|1), MANUAL_TZ, TIMEZONE_FALLBACK
  DOTFILES_REPO, DOTFILES_FALLBACK_REPO
EOF
}

parse_args() {
  local action=""
  while (( $# > 0 )); do
    case "$1" in
      --dry-run|-n) DRY_RUN=1 ;;
      install|check)
        if [[ -n "$action" ]]; then
          usage
          die "只能指定一个动作：已指定 $action，又收到 $1。"
        fi
        action="$1"
        ;;
      --help|-h) usage; exit 0 ;;
      --version|-V) printf 'init.sh v1.2.0\n'; exit 0 ;;
      *) usage; die "未知参数：$1。" ;;
    esac
    shift
  done

  [[ -n "$action" ]] || { usage; exit 1; }
  case "$action" in
    install) do_install ;;
    check) do_check ;;
    *) die "未知动作：$action。" ;;
  esac
}

main() {
  init_colors
  # flock 防重入：仅在 root 且系统支持 flock 时启用。
  # 锁文件放在 root-only 目录，避免 /tmp 下符号链接劫持（symlink 诱导 root 截断系统文件）。
  if (( EUID == 0 )) && command -v flock >/dev/null 2>&1; then
    local lockdir=""
    if [[ -d /run ]]; then
      lockdir="/run"
    elif [[ -d /var/lock ]]; then
      lockdir="/var/lock"
    fi
    if [[ -n "$lockdir" ]] && exec 9>"$lockdir/init.sh.lock" 2>/dev/null; then
      if ! flock -n 9 2>/dev/null; then
        exec 9>&- 2>/dev/null || true
        die "已有 init.sh 正在运行（文件锁被占用：$lockdir/init.sh.lock）。"
      fi
    fi
  fi
  # shellcheck disable=SC2154
  trap 'log error "执行失败：行=${LINENO:-?} 命令=${BASH_COMMAND:-?}"' ERR
  parse_args "$@"
}

main "$@"
