#!/usr/bin/env bash
set -euo pipefail

# =========================
# 配置项（可用环境变量覆盖）
# =========================
TARGET_USER="${TARGET_USER:-test}"
SSH_PUBKEYS="${SSH_PUBKEYS:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILUYSwBPFzPpsm0bmKK4VMkTte52OpzYD4d+lcdJjAwx register}"
SSH_PORT="${SSH_PORT:-28480}"
SWAP_SIZE_MB="${SWAP_SIZE_MB:-512}"

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
        [[ "$OS_VERSION_MAJOR" == "12" || "$OS_VERSION_MAJOR" == "13" ]] || die "不支持的 Debian 版本：$OS_VERSION_ID；仅支持 Debian 12/13。"
      fi
      PKG_DNSUTILS="dnsutils"
      PKG_VIM="vim"
      ;;
    centos|rhel|almalinux|rocky)
      OS_FAMILY="rhel"
      PKG_MANAGER="dnf"
      SSH_SERVICE="sshd"
      SUDO_GROUP="wheel"
      [[ "$OS_VERSION_MAJOR" == "9" || "$OS_VERSION_MAJOR" == "10" ]] || die "不支持的 ${OS_ID} 版本：$OS_VERSION_ID；仅支持 AlmaLinux/Rocky Linux 9/10。"
      PKG_DNSUTILS="bind-utils"
      PKG_VIM="vim-enhanced"
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
  if [[ "$OS_FAMILY" == "debian" && "$HAS_ZRAM_SUPPORT" == "1" ]]; then
    packages+=(systemd-zram-generator)
  elif [[ "$OS_FAMILY" == "debian" ]]; then
    log warn "内核未检测到 zram 支持，跳过 systemd-zram-generator。"
  elif [[ "$OS_FAMILY" == "rhel" && "$HAS_ZRAM_SUPPORT" == "1" ]]; then
    packages+=(zram-generator)
  elif [[ "$OS_FAMILY" == "rhel" ]]; then
    log warn "内核未检测到 zram 支持，跳过 zram-generator。"
  fi
  pkg_mgr install "${packages[@]}"
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

  # HTTPS 依赖 curl（带连接与总超时）
  if [[ "$url" == https://* ]]; then
    command -v curl >/dev/null 2>&1 || return 0
    curl -fsSL --connect-timeout 2 --max-time 4 "$@" "$url" 2>/dev/null || true
    return 0
  fi

  # HTTP 使用 /dev/tcp，避免额外依赖
  local host path rest port
  rest="${url#http://}"
  host="${rest%%/*}"
  if [[ "$rest" == "$host" ]]; then
    path='/'
  else
    path="/${rest#*/}"
  fi
  port=80

  exec 3<>/dev/tcp/"$host"/"$port" 2>/dev/null || return 0
  {
    printf 'GET %s HTTP/1.0\r\n' "$path"
    printf 'Host: %s\r\n' "$host"
    printf 'Connection: close\r\n'
    printf 'User-Agent: init.sh\r\n'
    local h
    for h in "$@"; do printf '%s\r\n' "${h#-H }"; done
    printf '\r\n'
  } >&3

  # Strip headers: find first empty line, print everything after
  # 注意: 某些 HTTP/1.0 响应可能没有 body
  sed -n '1,/^[[:space:]]*$/!p' <&3 2>/dev/null
  exec 3>&-
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
  [[ -f "/usr/share/zoneinfo/$1" ]]
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
    USER_HOME="/home/$TARGET_USER"
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
  elif ! grep -qxF "$SSH_PUBKEYS" "$auth_file"; then
    printf '%s\n' "$SSH_PUBKEYS" >> "$auth_file"
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

  local pat
  for pat in "${patterns[@]}"; do
    sed -i.bak "/^[[:space:]]*${pat}/d" "$hosts_file" 2>/dev/null || true
  done
  rm -f "${hosts_file}.bak"
}

clone_or_update_dotfiles() {
  DOTFILES_AVAILABLE=0
  if (( DRY_RUN == 1 )); then
    log dryrun "如果 $DOTFILES_DIR 已存在则 git pull，否则 clone $DOTFILES_REPO；失败则 clone $DOTFILES_FALLBACK_REPO。"
    return 0
  fi

  # IPv6 单栈网络：加 hosts，函数返回时自动清理
  if is_ipv6_only_network; then
    add_github_hosts_ipv6
    trap 'remove_github_hosts_ipv6; trap - RETURN' RETURN
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

  if sudo -u "$TARGET_USER" -H env GIT_TERMINAL_PROMPT=0 git clone -- "$DOTFILES_REPO" "$DOTFILES_DIR"; then
    DOTFILES_AVAILABLE=1
    chown -R "$TARGET_USER:$TARGET_USER" "$DOTFILES_DIR" 2>/dev/null || log warn "无法更改 dotfiles 所有权。"
    return 0
  fi

  log warn "主 dotfiles 仓库克隆失败：$DOTFILES_REPO。"
  if sudo -u "$TARGET_USER" -H env GIT_TERMINAL_PROMPT=0 git clone -- "$DOTFILES_FALLBACK_REPO" "$DOTFILES_DIR"; then
    DOTFILES_AVAILABLE=1
    chown -R "$TARGET_USER:$TARGET_USER" "$DOTFILES_DIR" 2>/dev/null || log warn "无法更改 dotfiles 所有权。"
    return 0
  fi

  die "主仓库和备用仓库均克隆失败，无法继续。"
}

apply_sysctl_custom() {
  [[ "$DOTFILES_AVAILABLE" == 1 ]] || { log warn "dotfiles not available, skipping sysctl custom"; return 0; }
  local src="$DOTFILES_DIR/etc/sysctl.d/88-custom.conf"
  local dst="/etc/sysctl.d/88-custom.conf"

  if (( DRY_RUN == 1 )); then
    log dryrun "如果存在则复制 $src 到 $dst，并执行 sysctl --system。"
    return 0
  fi
  if [[ -f "$src" ]]; then
    cp -f "$src" "$dst"
    sysctl --system >/dev/null
  else
    log warn "未找到 sysctl 配置：$src。"
  fi
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
      log dryrun "如果存在则链接：$DOTFILES_DIR/$file -> $USER_HOME/$file"
    elif [[ -e "$DOTFILES_DIR/$file" ]]; then
      ln -sfn "$DOTFILES_DIR/$file" "$USER_HOME/$file"
      chown -h "$TARGET_USER:$TARGET_USER" "$USER_HOME/$file" || log warn "无法更改 $file 所有权。"
    fi
  done

  for file in .inputrc .toprc .tmux.conf; do
    if (( DRY_RUN == 1 )); then
      log dryrun "如果存在则链接：$USER_HOME/$file -> /root/$file"
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
  run_cmd ln -sfn "$target" /root/.vimrc
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

is_zram_generator_installed() {
  dpkg-query -W -f='${Status}' systemd-zram-generator 2>/dev/null | grep -q 'install ok installed' \
    || rpm -q zram-generator >/dev/null 2>&1 \
    || [[ -f /usr/lib/systemd/system-generators/zram-generator ]] \
    || [[ -f /lib/systemd/system-generators/zram-generator ]]
}

configure_zram() {
  if (( HAS_ZRAM_SUPPORT == 0 )); then
    log warn "内核不支持 zram，跳过 zram 配置。"
    return 0
  fi

  # 检查对应发行版的 zram-generator 是否已安装
  if (( DRY_RUN == 0 )) && ! is_zram_generator_installed; then
    log warn "当前系统未安装 zram-generator，跳过 zram 配置。"
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
  run_cmd systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || log warn "zram 服务启动失败；可能未安装 systemd-zram-generator 或系统不支持。"
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
  elif ! file "$swap_file" 2>/dev/null | grep -qi 'swap file'; then
    log warn "$swap_file 已存在但不是有效 swap 文件，跳过启用，避免破坏现有文件。"
    return 0
  fi

  run_cmd swapon "$swap_file"
  append_line_if_missing /etc/fstab '/swap swap swap sw,pri=0 0 0'
  log info "swapfile 已配置：$swap_file。"
}

fix_home_permissions() {
  run_cmd find "$USER_HOME" -not -path '*/.git/*' -exec chown "$TARGET_USER:$TARGET_USER" {} +
}

# =========================
# 主流程
# =========================
do_install() {
  require_root
  verify_inputs
  detect_os
  detect_kernel_features

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
  verify_inputs
  detect_os
  detect_kernel_features
  log info "检查通过。"
}

usage() {
  cat <<'EOF'
用法：
  ./init.sh [--dry-run|-n] install
  ./init.sh [--dry-run|-n] check
  ./init.sh --help|-h          显示帮助
  ./init.sh --version|-V       显示版本

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
  # shellcheck disable=SC2154
  trap 'log error "执行失败：行=${LINENO:-?} 命令=${BASH_COMMAND:-?}"' ERR
  parse_args "$@"
}

main "$@"
