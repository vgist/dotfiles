#!/usr/bin/env bash
#
# Optimized System Monitor
# Logic: CPU -> Fans -> Storage (Sysfs + Smartctl Deduplicated) -> Others
# Compatible: bash 4+, zsh
#

# --- Shell Compatibility ---
if [ -n "${ZSH_VERSION:-}" ]; then
    setopt pipefail nonomatch 2>/dev/null || true
else
    set -o pipefail
fi
set -eu

# --- Helper Functions ---
trim() {
    # Trim leading and trailing whitespace via printf -v (safe, bash/zsh compatible)
    local val="$1"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    printf -v "$1" '%s' "$val"
}

is_valid_temp() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "${1:-0}" -ge 0 ] 2>/dev/null
}

# --- Configuration ---
GREEN="\033[32m"
CYAN="\033[36m"
YELLOW="\033[33m"
RESET="\033[0m"

# Ensure /usr/sbin is in PATH for smartctl
export PATH="$PATH:/usr/sbin:/sbin"

# --- Smartctl Resolver ---
SMART_CMD=""
if command -v smartctl >/dev/null 2>&1; then
    SMART_CMD=$(command -v smartctl)
fi

# --- Initialize Output Buffers ---
FAN_OUTPUT=""
DRIVE_OUTPUT=""
OTHER_OUTPUT=""

# Associative array for drive deduplication
if [ -n "${ZSH_VERSION:-}" ]; then
    typeset -A SEEN_DRIVES
else
    declare -A SEEN_DRIVES
fi


# =========================================================
# Section 1: CPU / SoC Temperature
# =========================================================
printf "  ${CYAN}[CPU / SoC]${RESET}\n"
found_cpu=0

for zone in /sys/class/thermal/thermal_zone*; do
    [ -r "$zone/type" ] && [ -r "$zone/temp" ] || continue

    type=$(cat "$zone/type")
    temp_raw=$(cat "$zone/temp")

    if is_valid_temp "$temp_raw"; then
        temp_c=$((temp_raw / 1000))
        if [ -n "$type" ]; then
            # shellcheck disable=SC2059
            printf "  %-22s : ${GREEN}%s°C${RESET}\n" "${type}" "${temp_c}"
            found_cpu=1
        fi
    fi
done

[ $found_cpu -eq 0 ] && printf "  No CPU sensors detected.\n"


# =========================================================
# Single pass over hwmon for Fans + Storage(Sysfs) + Others
# =========================================================
for hwmon in /sys/class/hwmon/hwmon*; do
    [ -d "$hwmon" ] || continue
    [ -r "$hwmon/name" ] || continue
    name=$(cat "$hwmon/name")

    # --- Branch: drivetemp (Storage via Sysfs) ---
    if [ "$name" = "drivetemp" ]; then
        if [ -r "$hwmon/device/model" ] && [ -r "$hwmon/temp1_input" ]; then
            model=$(cat "$hwmon/device/model")
            trim model
            temp_raw=$(cat "$hwmon/temp1_input")
            [[ "$temp_raw" =~ ^[0-9]+$ ]] || continue
            temp_c=$((temp_raw / 1000))

            # shellcheck disable=SC2059
            line=$(printf "  %-22s : ${GREEN}%s°C${RESET} (Sysfs)" "${model}" "${temp_c}")
            DRIVE_OUTPUT="${DRIVE_OUTPUT}${line}\n"
            SEEN_DRIVES["${model}"]=1
        fi
        continue
    fi
    # --- Branch: Other temp sensors (PMIC / Board) ---
    # Skip CPU/GPU/thermal zones (handled in Section 1)
    case "$name" in *cpu*|*soc*|*ddr*|*gpu*|*thermal*) continue ;; esac
    for input in "$hwmon"/temp*_input; do
        [ -r "$input" ] || continue
        temp_raw=$(cat "$input")
        if [[ "$temp_raw" =~ ^[0-9]+$ ]] && is_valid_temp "$temp_raw"; then
            temp_c=$((temp_raw / 1000))
            label_file="${input%_input}_label"
            if [ -r "$label_file" ]; then
                label="$name ($(cat "$label_file"))"
            else
                label="$name"
            fi
            # shellcheck disable=SC2059
            line=$(printf "  %-22s : ${GREEN}%s°C${RESET}" "${label}" "${temp_c}")
            OTHER_OUTPUT="${OTHER_OUTPUT}${line}\n"
        fi
    done

    # --- Branch: Fans ---
    for input in "$hwmon"/fan*_input; do
        [ -r "$input" ] || continue
        rpm=$(cat "$input")
        if [ -n "${rpm:-}" ]; then
            label=""
            label_file="${input%_input}_label"
            if [ -r "$label_file" ]; then
                read -r label < "$label_file"
            elif [ -r "$hwmon/name" ]; then
                read -r label < "$hwmon/name"
            else
                label="Fan Device"
            fi
            # shellcheck disable=SC2059
            line=$(printf "  %-22s : ${GREEN}%s RPM${RESET}" "${label}" "${rpm}")
            FAN_OUTPUT="${FAN_OUTPUT}${line}\n"
        fi
    done
done


# =========================================================
# Section 2: Fans / Cooling (collected above)
# =========================================================
if [ -n "$FAN_OUTPUT" ]; then
    printf "\n  ${CYAN}[Fans / Cooling]${RESET}\n"
    printf "%b" "$FAN_OUTPUT"
fi


# =========================================================
# Section 3: Storage — Smartctl (Fallback / Additional)
# =========================================================
if [ -n "$SMART_CMD" ]; then
    for disk in /dev/sd? /dev/nvme[0-9]*n[0-9]*; do
        [ -e "$disk" ] || continue

        # Single smartctl call for both model and temp
        smart_data=$(sudo -n "$SMART_CMD" -a "$disk" 2>/dev/null) || {
            printf "  ${YELLOW}Warning: smartctl failed for %s (sudo or device issue)${RESET}\n" "$disk" >&2
            continue
        }

        # Parse Model (single awk pass)
        model_raw=$(echo "$smart_data" | awk -F': ' '/Device Model/{print $2; exit} /Model Number/{print $2; exit}')
        [ -z "$model_raw" ] && model_raw=$(basename "$disk")
        trim model_raw

        # Deduplication Check
        if [ -n "${SEEN_DRIVES["${model_raw}"]:-}" ]; then
            continue
        fi

        # Get Temp (SATA: attr 194/190; NVMe: Temperature line)
        temp=$(echo "$smart_data" | grep -E "^194|^190" | sort -r 2>/dev/null | head -n 1 | awk '{print $10}')
        if [ -z "$temp" ]; then
            temp=$(echo "$smart_data" | grep -m1 -iE "^Temperature" | awk '{for(i=1;i<=NF;i++) if($i~/^[0-9]+$/) {print $i; exit}}')
        fi
        if [ -z "$temp" ]; then
            temp=$(echo "$smart_data" | grep -iE "Current Drive Temperature" | grep -oE '[0-9]+' | head -n 1)
        fi

        if [ -n "$temp" ] && [ "$temp" -ge 0 ] 2>/dev/null; then
            # shellcheck disable=SC2059
            line=$(printf "  %-22s : ${YELLOW}%s°C${RESET} (Smartctl)" "${model_raw}" "${temp}")
            DRIVE_OUTPUT="${DRIVE_OUTPUT}${line}\n"
        fi
    done
fi

if [ -n "$DRIVE_OUTPUT" ]; then
    printf "\n  ${CYAN}[Storage / Drives]${RESET}\n"
    printf "%b" "$DRIVE_OUTPUT"
fi


# =========================================================
# Section 4: Other Sensors (collected above)
# =========================================================
if [ -n "$OTHER_OUTPUT" ]; then
    printf "\n  ${CYAN}[Other Sensors]${RESET}\n"
    printf "%b" "$OTHER_OUTPUT"
fi
