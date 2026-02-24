#!/usr/bin/env bash
#
# Optimized System Monitor
# Logic: CPU -> Fans -> Storage (Sysfs + Smartctl Deduplicated) -> Others
#

# --- Configuration ---
BOLD="\033[1m"
GREEN="\033[32m"
CYAN="\033[36m"
YELLOW="\033[33m"
RESET="\033[0m"

# Ensure /usr/sbin is in PATH for smartctl
export PATH=$PATH:/usr/sbin:/sbin:/usr/bin:/bin

# --- 1. Smartctl Resolver ---
SMART_CMD=""
if command -v smartctl >/dev/null 2>&1; then
    SMART_CMD=$(command -v smartctl)
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

    if [ -n "$temp_raw" ] && [ "$temp_raw" -gt 0 ] 2>/dev/null; then
        temp_c=$(echo "$temp_raw" | awk '{printf "%.1f", $1/1000}')
        # Filter out obvious non-CPU thermal zones if needed, usually unnecessary
        if [ -n "$type" ]; then
            printf "  %-22s : ${GREEN}%s°C${RESET}\n" "$type" "$temp_c"
            found_cpu=1
        fi
    fi
done

[ $found_cpu -eq 0 ] && printf "  No CPU sensors detected.\n"


# =========================================================
# Section 2: Fans / Cooling
# =========================================================
FAN_OUTPUT=""

if ls /sys/class/hwmon/hwmon* >/dev/null 2>&1; then
    for hwmon in /sys/class/hwmon/hwmon*; do
        for input in "$hwmon"/fan*_input; do
            [ -r "$input" ] || continue

            rpm=$(cat "$input")
            # Show if we get a number (even 0 is valid for stopped fans)
            if [ -n "$rpm" ] 2>/dev/null; then
                 # Get Label
                 label=""
                 label_file="${input%_input}_label"
                 if [ -r "$label_file" ]; then
                    label=$(cat "$label_file")
                 elif [ -r "$hwmon/name" ]; then
                    label=$(cat "$hwmon/name")
                 else
                    label="Fan Device"
                 fi

                 # Buffer output (Append \n explicitly)
                 line=$(printf "  %-22s : ${GREEN}%s RPM${RESET}" "$label" "$rpm")
                 FAN_OUTPUT="${FAN_OUTPUT}${line}\n"
            fi
        done
    done
fi

if [ -n "$FAN_OUTPUT" ]; then
    printf "\n  ${CYAN}[Fans / Cooling]${RESET}\n"
    printf "%b" "$FAN_OUTPUT"
fi


# =========================================================
# Section 3: Storage (Deduplicated & Optimized)
# =========================================================
DRIVE_OUTPUT=""
SEEN_DRIVES="" # String to track models we've already found via Sysfs

# --- Method A: Sysfs (Fastest, Preferred) ---
if ls /sys/class/hwmon/hwmon* >/dev/null 2>&1; then
    for hwmon in /sys/class/hwmon/hwmon*; do
        if [ -r "$hwmon/name" ] && [ "$(cat "$hwmon/name")" = "drivetemp" ]; then
            if [ -r "$hwmon/device/model" ]; then
                model=$(cat "$hwmon/device/model" | xargs)
                temp_raw=$(cat "$hwmon/temp1_input")
                temp_c=$((temp_raw / 1000))

                line=$(printf "  %-22s : ${GREEN}%s°C${RESET} (Sysfs)" "$model" "$temp_c")
                DRIVE_OUTPUT="${DRIVE_OUTPUT}${line}\n"

                # Record this model as "Seen"
                SEEN_DRIVES="${SEEN_DRIVES}|${model}"
            fi
        fi
    done
fi

# --- Method B: Smartctl (Fallback / Additional) ---
if [ -n "$SMART_CMD" ]; then
    for disk in /dev/sd? /dev/nvme?n?; do
        [ -e "$disk" ] || continue

        # Performance: Get Model First
        # Use sudo -n to avoid hanging if password is required (safety check)
        model_info=$(sudo -n "$SMART_CMD" -i "$disk" 2>/dev/null)

        # Parse Model
        model_raw=$(echo "$model_info" | grep "Device Model" | awk -F: '{print $2}' | xargs)
        [ -z "$model_raw" ] && model_raw=$(echo "$model_info" | grep "Model Number" | awk -F: '{print $2}' | xargs)
        [ -z "$model_raw" ] && model_raw=$(basename "$disk")

        # Deduplication Check: If model is in SEEN_DRIVES, skip Smartctl query
        if [[ "$SEEN_DRIVES" == *"$model_raw"* ]] && [ -n "$model_raw" ]; then
            continue
        fi

        # Get Temp (Only if not seen)
        smart_data=$(sudo -n "$SMART_CMD" -A "$disk" 2>/dev/null)
        temp=$(echo "$smart_data" | grep -E "^194|^190" | sort -r | head -n 1 | awk '{print $10}')

        # NVMe fallback
        if [ -z "$temp" ]; then
            temp=$(echo "$smart_data" | grep "Temperature" | head -n 1 | grep -oE "[0-9]{2,3}" | head -n 1)
        fi

        if [ -n "$temp" ] && [ "$temp" -gt 0 ] 2>/dev/null; then
             line=$(printf "  %-22s : ${YELLOW}%s°C${RESET} (Smartctl)" "$model_raw" "$temp")
             DRIVE_OUTPUT="${DRIVE_OUTPUT}${line}\n"
        fi
    done
fi

if [ -n "$DRIVE_OUTPUT" ]; then
    printf "\n  ${CYAN}[Storage / Drives]${RESET}\n"
    printf "%b" "$DRIVE_OUTPUT"
fi


# =========================================================
# Section 4: Other Sensors (PMIC / Board)
# =========================================================
OTHER_OUTPUT=""

if ls /sys/class/hwmon/hwmon* >/dev/null 2>&1; then
    for hwmon in /sys/class/hwmon/hwmon*; do
        [ -r "$hwmon/name" ] || continue
        name=$(cat "$hwmon/name")

        # Exclude Storage (handled above) and CPU (handled in Sec 1)
        [ "$name" = "drivetemp" ] && continue
        if echo "$name" | grep -qiE "cpu|soc|ddr|gpu|thermal"; then continue; fi

        for input in "$hwmon"/temp*_input; do
            [ -r "$input" ] || continue
            temp_raw=$(cat "$input")

            if [ -n "$temp_raw" ] && [ "$temp_raw" -gt 0 ] 2>/dev/null; then
                 temp_c=$((temp_raw / 1000))

                 label_file="${input%_input}_label"
                 if [ -r "$label_file" ]; then
                    label="$name ($(cat "$label_file"))"
                 else
                    label="$name"
                 fi

                 line=$(printf "  %-22s : ${GREEN}%s°C${RESET}" "$label" "$temp_c")
                 OTHER_OUTPUT="${OTHER_OUTPUT}${line}\n"
            fi
        done
    done
fi

if [ -n "$OTHER_OUTPUT" ]; then
    printf "\n  ${CYAN}[Other Sensors]${RESET}\n"
    printf "%b" "$OTHER_OUTPUT"
fi
