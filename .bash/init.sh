#!/usr/bin/env bash
set -euo pipefail

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

HAS_ZRAM_SUPPORT=0
HAS_SWAP_SUPPORT=0
IN_CONTAINER=0

ZRAM_PKG=""
ZRAM_CONF_FILE=""
ZRAM_SERVICE=""

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

# =========================
# 交互采集
# =========================
is_interactive() {
  [[ -t 0 ]]
}

# 用法: prompt_line <提示> <默认值>
# 提示输出到 stderr，读取一行，空输入则用默认值，最终值输出到 stdout。
prompt_line() {
  local prompt="$1"
  local default="$2"
  local input=""
  printf '%s' "$prompt" >&2
  IFS= read -r input || true
  [[ -z "$input" ]] && input="$default"
  printf '%s\n' "$input"
}

# 用法: prompt_user
# 循环询问目标用户名直到合法（与 verify_inputs 规则一致）。
prompt_user() {
  local input=""
  while true; do
    input="$(prompt_line "请输入目标用户名 [${DEFAULT_TARGET_USER}]: " "$DEFAULT_TARGET_USER")"
    if [[ "$input" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
      break
    fi
    printf '无效用户名：%s（需以字母或下划线开头，仅含小写字母、数字、下划线、连字符，最长 32 位）\n' "$input" >&2
  done
  printf '%s\n' "$input"
}

# 用法: prompt_port
# 循环询问 SSH 端口直到合法（1-65535 的整数）。
prompt_port() {
  local input=""
  while true; do
    input="$(prompt_line "请输入 SSH 端口 [${DEFAULT_SSH_PORT}]: " "$DEFAULT_SSH_PORT")"
    if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= 65535 )); then
      break
    fi
    printf '无效端口：%s（需 1-65535 的整数）\n' "$input" >&2
  done
  printf '%s\n' "$input"
}

# 用法: prompt_swap_size
# 循环询问 swap 大小直到合法（非负整数，0 表示跳过创建）。
prompt_swap_size() {
  local input=""
  while true; do
    input="$(prompt_line "请输入 swap 大小（MB） [${DEFAULT_SWAP_SIZE_MB}]: " "$DEFAULT_SWAP_SIZE_MB")"
    if [[ "$input" =~ ^[0-9]+$ ]]; then
      break
    fi
    printf '无效大小：%s（需非负整数，0 表示跳过创建 swap）\n' "$input" >&2
  done
  printf '%s\n' "$input"
}

# 用法: prompt_pubkeys
# 必填：循环读取多行公钥，空行结束；未输入任何公钥则重新提示，EOF 则报错退出。结果输出到 stdout。
prompt_pubkeys() {
  local line=""
  local result=""
  local got_input=0
  printf '请输入 SSH 公钥（必填，每行一个，可粘贴多个，空行结束）\n' >&2
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
    printf '未输入任何公钥，请至少粘贴一个 SSH 公钥（空行结束）：\n' >&2
  done
  result="${result%$'\n'}"
  printf '%s\n' "$result"
}

# 按模式采集四个配置项（环境变量已指定时跳过）。
# mode=install：用户名/端口/swap 循环询问（带默认值），SSH 公钥必填；
# mode=check：仅询问用户名，端口/swap 用默认值，公钥不采集（check 不使用）。
collect_inputs() {
  local mode="$1"

  if [[ -z "$TARGET_USER" ]]; then
    if is_interactive; then
      TARGET_USER="$(prompt_user)"
    else
      TARGET_USER="$DEFAULT_TARGET_USER"
      log info "未指定 TARGET_USER，使用默认值：$TARGET_USER。"
    fi
  fi

  if [[ "$mode" == "install" ]]; then
    if [[ -z "$SSH_PUBKEYS" ]]; then
      if is_interactive; then
        SSH_PUBKEYS="$(prompt_pubkeys)"
      else
        die "SSH_PUBKEYS 未设置，且无交互终端可输入公钥。请通过环境变量 SSH_PUBKEYS 提供。"
      fi
    fi

    if [[ -z "$SSH_PORT" ]]; then
      if is_interactive; then
        SSH_PORT="$(prompt_port)"
      else
        SSH_PORT="$DEFAULT_SSH_PORT"
        log info "未指定 SSH_PORT，使用默认值：$SSH_PORT。"
      fi
    fi

    if [[ -z "$SWAP_SIZE_MB" ]]; then
      if is_interactive; then
        SWAP_SIZE_MB="$(prompt_swap_size)"
      else
        SWAP_SIZE_MB="$DEFAULT_SWAP_SIZE_MB"
        log info "未指定 SWAP_SIZE_MB，使用默认值：$SWAP_SIZE_MB。"
      fi
    fi
  else
    # check 模式：只需满足 verify_inputs 校验，端口/swap 取默认值，公钥不涉及。
    [[ -z "$SSH_PORT" ]] && SSH_PORT="$DEFAULT_SSH_PORT"
    [[ -z "$SWAP_SIZE_MB" ]] && SWAP_SIZE_MB="$DEFAULT_SWAP_SIZE_MB"
  fi
}

# =========================
# 校验
# =========================
require_root() {
  if [[ "${EUID}" -eq 0 ]]; then
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
  [[ "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "TARGET_USER 不合法：$TARGET_USER"
  [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "SSH_PORT 必须是数字。"
  (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || die "SSH_PORT 超出范围：$SSH_PORT"
  [[ "$SWAP_SIZE_MB" =~ ^[0-9]+$ ]] || die "SWAP_SIZE_MB 必须是数字。"
  (( SWAP_SIZE_MB >= 0 )) || die "SWAP_SIZE_MB 必须大于等于 0。"
  [[ "$AUTO_TZ" == "0" || "$AUTO_TZ" == "1" ]] || die "AUTO_TZ 只能是 0 或 1。"
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
      PKG_VIM="vim"
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
      PKG_VIM="vim-enhanced"
      ZRAM_PKG="zram-generator"
      ZRAM_CONF_FILE="/etc/systemd/zram-generator.conf"
      ZRAM_SERVICE="systemd-zram-setup@zram0"
      ;;
    *) die "不支持的系统：$OS_ID。" ;;
  esac

  log info "系统：${OS_ID} ${OS_VERSION_ID}；包管理器：${PKG_MANAGER}。"
}

detect_kernel_features() {
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

detect_container() {
  # systemd-detect-virt 是最可靠的容器/虚拟化检测方式
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    local virt
    # --container: 检测容器环境（lxc, openvz, docker, podman, rkt 等）
    if virt="$(systemd-detect-virt --container 2>/dev/null)"; then
      case "$virt" in
        lxc|openvz) return 0 ;;
        *) return 1 ;;  # docker, podman, rkt 等明确容器类型立即返回失败
      esac
    fi
    # 未识别容器：继续尝试 LXC/OpenVZ 后备检测。
  fi

  # OpenVZ 容器有 /proc/vz 但没有 /proc/bc；宿主两者通常都存在。
  [[ -d /proc/vz && ! -d /proc/bc ]] && return 0

  # LXC 特有标记：检查 /proc/1/environ 中的 container 字段
  if [[ -r /proc/1/environ ]]; then
    if tr '\0' '\n' < /proc/1/environ 2>/dev/null | grep -qiE '^container=(lxc|openvz)'; then
      return 0
    fi
  fi

  return 1
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
      # 该文件由 init.sh 托管，若已有内容先备份
      if (( DRY_RUN == 1 )); then
        log dryrun "备份 dnf.conf：cp -a $DNF_CONF_FILE ${DNF_CONF_FILE}.bak.init"
      elif [[ -f "$DNF_CONF_FILE" ]]; then
        cp -a "$DNF_CONF_FILE" "${DNF_CONF_FILE}.bak.init"
      fi
      write_file "$DNF_CONF_FILE" <<'EOF'
[main]
tsflags=nodocs
install_weak_deps=0
fastestmirror=False
metadata_expire=never
gpgcheck=1
installonly_limit=3
clean_requirements_on_remove=True
best=True
skip_if_unavailable=False
exclude=kernel*
EOF
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
        *) die "未知包管理动作：$action" ;;
      esac
      ;;
    dnf)
      case "$action" in
        update) run_cmd dnf makecache -y ;;
        install) run_cmd dnf install -y "$@" ;;
        *) die "未知包管理动作：$action" ;;
      esac
      ;;
    *) die "未知包管理器：$PKG_MANAGER" ;;
  esac
}

install_common_packages() {
  log info "安装基础软件包。"
  tune_pkg_manager
  pkg_mgr update

  local packages=(
    bash-completion ca-certificates curl "$PKG_DNSUTILS" git nftables
    openssh-server sudo tmux "$PKG_VIM"
  )
  # 汇总"该装 zram"的判定；RHEL 的 zram 单独在下方可选安装分支处理
  local install_zram=0
  if [[ "$HAS_ZRAM_SUPPORT" == "1" ]]; then
    if (( IN_CONTAINER == 1 )); then
      log warn "容器环境（LXC/OpenVZ），跳过 $ZRAM_PKG 安装。"
    elif [[ "$OS_FAMILY" == "debian" ]]; then
      packages+=("$ZRAM_PKG")
    elif [[ "$OS_FAMILY" == "rhel" ]]; then
      install_zram=1
    fi
  else
    log warn "内核未检测到 zram 支持，跳过 $ZRAM_PKG。"
  fi
  pkg_mgr install "${packages[@]}"

  if (( install_zram == 1 )); then
    if pkg_mgr install "$ZRAM_PKG"; then
      :
    else
      log warn "无法安装可选包 $ZRAM_PKG；其余基础软件包已继续安装，后续仅在检测到已安装时配置 zram。"
    fi
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

has_systemctl() {
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

timezone_from_region() {
  local region_raw="$1"
  local region
  region="$(printf '%s' "$region_raw" | tr '[:upper:]' '[:lower:]')"

  # TZ_MAP migrated to plain array for Bash 3.x (MacOS) compat.
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
  local zone="" region=""

  zone="$(http_get_quick "http://169.254.169.254/latest/meta-data/placement/availability-zone")"
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
  command -v timedatectl >/dev/null 2>&1 || { log warn "未找到 timedatectl，跳过时区设置。"; return 0; }

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
  run_cmd timedatectl set-timezone "$timezone" || log warn "设置时区失败：$timezone。"
}

# =========================
# 用户与 SSH
# =========================
ensure_user() {
  if id "$TARGET_USER" >/dev/null 2>&1; then
    log info "用户已存在：$TARGET_USER。"
  else
    run_cmd useradd -m -s /bin/bash "$TARGET_USER"
    log info "创建用户：$TARGET_USER。"
  fi

  if (( DRY_RUN == 1 )); then
    # dry-run 也先尝试 getent 解析真实 home，失败才回退默认路径
    USER_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)"
    [[ -z "$USER_HOME" ]] && USER_HOME="/home/$TARGET_USER"
  else
    USER_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)"
    [[ -z "$USER_HOME" ]] && USER_HOME="$(grep "^${TARGET_USER}:" /etc/passwd | cut -d: -f6)"
    if [[ -n "$USER_HOME" && -d "$USER_HOME" ]]; then
      :
    else
      log warn "无法解析用户 home 目录（解析结果：${USER_HOME:-<空>}）。"
      die "请确认 ${TARGET_USER} 的 home 目录是否正常存在。"
    fi
  fi
  DOTFILES_DIR="$USER_HOME/.dotfiles"
}

add_user_to_group_if_exists() {
  local group="$1"
  if getent group "$group" >/dev/null 2>&1; then
    run_cmd usermod -aG "$group" "$TARGET_USER"
  else
    log warn "用户组不存在，跳过：$group。"
  fi
}

configure_user_groups() {
  add_user_to_group_if_exists "$SUDO_GROUP"
  add_user_to_group_if_exists "systemd-journal"
  [[ "$OS_FAMILY" == "debian" ]] && add_user_to_group_if_exists "users"
  return 0
}

configure_authorized_keys() {
  local ssh_dir="$USER_HOME/.ssh"
  local auth_file="$ssh_dir/authorized_keys"

  run_cmd install -d -m 700 -o "$TARGET_USER" -g "$TARGET_USER" "$ssh_dir"
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

configure_sshd() {
  local dir="/etc/ssh/sshd_config.d"
  local file="$dir/99-${TARGET_USER}.conf"

  if ! grep -Eq '^[[:space:]]*Include[[:space:]].*sshd_config\.d' /etc/ssh/sshd_config 2>/dev/null; then
    log warn "主 sshd_config 可能不包含 drop-in 目录，配置可能不会生效。"
  fi

  run_cmd install -d -m 755 "$dir"
  {
    printf 'Port %s\n' "$SSH_PORT"
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

  if (( DRY_RUN == 1 )); then
    log dryrun "校验 sshd 配置：sshd -t"
  else
    require_cmd sshd
    sshd -t || die "sshd 配置校验失败：$file"
  fi

  if ! has_systemctl; then
    log warn "未找到 systemctl，跳过 SSH 服务启用与重启。"
    return 0
  fi

  # 重启前校验公钥，避免锁死：ssh 服务将禁用密码登录，若无可登录公钥则危险
  local auth_file="$USER_HOME/.ssh/authorized_keys"
  if (( DRY_RUN == 1 )); then
    log dryrun "校验 $TARGET_USER 的有效 SSH 公钥（authorized_keys）。"
  else
    if [[ ! -f "$auth_file" ]] || [[ ! -s "$auth_file" ]] || \
        ! grep -qE '^ssh-(ed25519|rsa|ecdsa|dss) ' "$auth_file"; then
      die "未找到 $TARGET_USER 的有效 SSH 公钥，拒绝重启 sshd 以防锁死。"
    fi
  fi

  if (( DRY_RUN == 1 )); then
    run_cmd systemctl enable "$SSH_SERVICE"
  else
    systemctl enable "$SSH_SERVICE" >/dev/null 2>&1 || log warn "启用 SSH 服务失败，但继续尝试重启。"
  fi
  run_cmd systemctl restart "$SSH_SERVICE"
}

# =========================
# dotfiles 与编辑器
has_ip_command() {
  command -v ip >/dev/null 2>&1
}

is_ipv6_only_network() {
  local has_v4=0
  local has_v6=0
  has_ip_command || return 1

  if ip -4 route show default 2>/dev/null | grep -q '^'; then
    has_v4=1
  fi
  if ip -6 route show default 2>/dev/null | grep -q '^'; then
    has_v6=1
  fi

  [[ "$has_v6" == "1" && "$has_v4" == "0" ]]
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

  local suffix=".init-sh.bak"
  local pat
  for pat in "${patterns[@]}"; do
    sed -i"$suffix" "/^[[:space:]]*${pat}/d" "$hosts_file" 2>/dev/null || true
  done
  rm -f "${hosts_file}${suffix}"
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

  if sudo -u "$TARGET_USER" -H env GIT_TERMINAL_PROMPT=0 git clone --depth 1 -- "$DOTFILES_REPO" "$DOTFILES_DIR"; then
    DOTFILES_AVAILABLE=1
    chown -R "$TARGET_USER:$TARGET_USER" "$DOTFILES_DIR" 2>/dev/null || log warn "无法更改 dotfiles 所有权。"
    log info "dotfiles 已克隆：$(sudo -u "$TARGET_USER" -H git -C "$DOTFILES_DIR" rev-parse --short HEAD 2>/dev/null || true)"
    return 0
  fi

  log warn "主 dotfiles 仓库克隆失败：$DOTFILES_REPO。"
  if sudo -u "$TARGET_USER" -H env GIT_TERMINAL_PROMPT=0 git clone --depth 1 -- "$DOTFILES_FALLBACK_REPO" "$DOTFILES_DIR"; then
    DOTFILES_AVAILABLE=1
    chown -R "$TARGET_USER:$TARGET_USER" "$DOTFILES_DIR" 2>/dev/null || log warn "无法更改 dotfiles 所有权。"
    log info "dotfiles 已克隆：$(sudo -u "$TARGET_USER" -H git -C "$DOTFILES_DIR" rev-parse --short HEAD 2>/dev/null || true)"
    return 0
  fi

  die "主仓库和备用仓库均克隆失败，无法继续。"
}

apply_sysctl_custom() {
  [[ "$DOTFILES_AVAILABLE" == 1 ]] || { log warn "dotfiles not available, skipping sysctl custom"; return 0; }
  if (( IN_CONTAINER == 1 )); then
    log info "容器环境（LXC/OpenVZ），跳过自定义 sysctl 配置（不复制 88-custom.conf）。"
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
      if sysctl -w "$line" >/dev/null 2>&1; then
        :
      else
        log warn "sysctl 应用失败（第 ${lineno} 行）：$line"
      fi
    done <&3
    set -e
    exec 3<&-
  else
    log warn "未找到 sysctl 配置：$src。"
  fi
  return 0
}

link_dotfiles() {
  [[ "$DOTFILES_AVAILABLE" == 1 ]] || { log warn "dotfiles not available, skipping link_dotfiles"; return 0; }
  local files=(
    .bash .bash_aliases .bash_color .bash_logout .bash_profile
    .bashrc .dir_colors .gitconfig .gitignore_global .inputrc .tmux.conf .toprc
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
      log dryrun "强制链接：$USER_HOME/$file -> /root/$file"
    elif [[ -e "$USER_HOME/$file" ]]; then
      ln -sfn "$USER_HOME/$file" "/root/$file"
    fi
  done
}

write_vimrc() {
  [[ "$DOTFILES_AVAILABLE" == 1 ]] || { log warn "dotfiles not available, skipping write_vimrc"; return 0; }
  local target="$USER_HOME/.vimrc"
  write_file "$target" <<'EOF'
set nocompatible
set encoding=utf-8
scriptencoding utf-8
set termencoding=utf-8
set fileencoding=utf-8
set fileencodings=ucs-bom,utf-8,gb18030,big5,euc-jp,euc-kr,latin1
set fileformats=unix,dos,mac

set list!
set listchars=tab:>\ ,trail:.,extends:>,precedes:<
set backspace=eol,start,indent
set visualbell t_vb=
set virtualedit=onemore
set formatoptions-=t formatoptions+=croql

set smarttab
set expandtab
set tabstop=4 softtabstop=4 shiftwidth=4
set autoindent smartindent shiftround

set ignorecase
set smartcase
EOF
  run_cmd chown "$TARGET_USER:$TARGET_USER" "$target"
  if (( DRY_RUN == 1 )); then
    log dryrun "强制链接：$target -> /root/.vimrc"
  else
    run_cmd ln -sfn "$target" /root/.vimrc
  fi
}

# =========================
# zram 与 swap
# =========================
has_non_zram_swap() {
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
    zram-generator)
      rpm -q zram-generator >/dev/null 2>&1 \
        || [[ -f /usr/lib/systemd/system-generators/zram-generator ]] \
        || [[ -f /lib/systemd/system-generators/zram-generator ]]
      ;;
    "")
      # RHEL fallback: ZRAM_PKG not set, check rpm and generator files
      rpm -q zram-generator >/dev/null 2>&1 \
        || [[ -f /usr/lib/systemd/system-generators/zram-generator ]] \
        || [[ -f /lib/systemd/system-generators/zram-generator ]]
      ;;
    *)
      return 1
      ;;
  esac
}

configure_zram() {
  if (( IN_CONTAINER == 1 )); then
    log warn "容器环境（LXC/OpenVZ），跳过 zram 配置。"
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

  if [[ "$ZRAM_CONF_FILE" == "/etc/default/zramswap" ]]; then
    write_file "$ZRAM_CONF_FILE" <<'EOF'
PERCENT=50
EOF
    if ! has_systemctl; then
      log warn "未找到 systemctl 或 systemd 未运行，跳过 zram 服务操作。"
      return 0
    fi
    run_cmd systemctl daemon-reload
    run_cmd systemctl restart "$ZRAM_SERVICE" 2>/dev/null || log warn "zram 服务启动失败；可能未安装 $ZRAM_PKG 或系统不支持。"
    return 0
  fi

  write_file "/etc/systemd/zram-generator.conf" <<'EOF'
[zram0]
zram-size = min(ram / 2, 1024)
swap-priority = 32767
EOF

  if ! has_systemctl; then
    log warn "未找到 systemctl 或 systemd 未运行，跳过 zram 服务操作。"
    return 0
  fi
  run_cmd systemctl daemon-reload
  run_cmd systemctl restart "$ZRAM_SERVICE" 2>/dev/null || log warn "zram 服务启动失败；可能未安装 $ZRAM_PKG 或系统不支持。"
}

configure_swapfile() {
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
    run_cmd fallocate -l "${SWAP_SIZE_MB}M" "$swap_file" || run_cmd dd if=/dev/zero of="$swap_file" bs=1M count="$SWAP_SIZE_MB"
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
  run_cmd find "$USER_HOME" -xdev -not -path '*/.git/*' -exec chown "$TARGET_USER:$TARGET_USER" {} +
}

# =========================
# 主流程
# =========================
do_install() {
  require_root
  collect_inputs install
  verify_inputs
  detect_os
  detect_kernel_features
  detect_container && IN_CONTAINER=1 || IN_CONTAINER=0

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

do_check() {
  require_root
  collect_inputs check
  verify_inputs
  detect_os
  detect_kernel_features
  detect_container && IN_CONTAINER=1 || IN_CONTAINER=0

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

  log info "检查通过。"
}

usage() {
  cat <<'EOF'
用法：
  ./init.sh [--dry-run|-n] install
  ./init.sh [--dry-run|-n] check
  ./init.sh --help|-h          显示帮助
  ./init.sh --version|-V       显示版本

交互模式（install）：
  TARGET_USER、SSH_PORT、SWAP_SIZE_MB 未通过环境变量指定时，
  若标准输入为终端（tty），将逐项询问（直接回车使用默认值：
  用户名 user、端口 22、swap 512MB），非法输入会重新询问；
  无 tty 时静默回退默认值。
  SSH_PUBKEYS 必填：若未通过环境变量指定，交互时须至少粘贴一个公钥，
  无 tty 时直接报错退出。
交互模式（check）：
  仅询问目标用户名，端口/swap 取默认值，公钥不询问。

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
      --version|-V) printf 'init.sh v1.1.0\n'; exit 0 ;;
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
  # flock 防重入（若系统支持 flock）；缺失时静默跳过，不影响功能
  if command -v flock >/dev/null 2>&1; then
    exec 9>/tmp/init.sh.lock
    flock -n 9 || die "已有 init.sh 正在运行。"
  fi
  # shellcheck disable=SC2154
  trap 'log error "执行失败：行=${LINENO:-?} 命令=${BASH_COMMAND:-?}"' ERR
  parse_args "$@"
}

main "$@"
