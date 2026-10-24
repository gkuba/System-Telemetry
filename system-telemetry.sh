#!/usr/bin/env bash

set -uo pipefail
export LC_ALL=C

DISPLAY_MODE=1
case "${1:-}" in
    '') ;;
    --headless|--no-display) DISPLAY_MODE=0 ;;
    -h|--help)
        printf 'Usage: %s [--headless]\n' "${0##*/}"
        printf 'Run the telemetry logger without drawing the interactive dashboard.\n'
        exit 0
        ;;
    *)
        printf 'Usage: %s [--headless]\n' "${0##*/}" >&2
        exit 2
        ;;
esac
if (( $# > 1 )); then
    printf 'Usage: %s [--headless]\n' "${0##*/}" >&2
    exit 2
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/gpu-telemetry.csv"
EXTENDED_LOG="$LOG_DIR/gpu-telemetry-extended.csv"
PLATFORM_LOG="$LOG_DIR/platform-telemetry.csv"
KERNEL_LOG="$LOG_DIR/kernel-events.log"
STORAGE_LOG="$LOG_DIR/storage-events.log"
ALERT_FILE="$LOG_DIR/.gpu-telemetry-alert"
LOG_MAX_BYTES=$((10 * 1024 * 1024))
LOG_ROTATIONS=3
STORAGE_LOG_MAX_BYTES=$((10 * 1024 * 1024 / 4))
STORAGE_LOG_ROTATIONS=3
HISTORY_LIMIT=10
FRAME_WIDTH=96
LEFT_PADDING=2
SAMPLE_INTERVAL=2
QUERY_TIMEOUT=4
CSV_HEADER='status,timestamp,gpu,pstate,power_w,utilization_pct,temperature_c,graphics_clock_mhz,memory_clock_mhz,pcie_gen,pcie_width,detail'
EXTENDED_HEADER='timestamp,memory_used_mib,memory_total_mib,memory_temperature_c,fan_speed_pct,power_limit_w,pcie_rx_kib_s,pcie_tx_kib_s'
PLATFORM_HEADER='timestamp,board_12v_v,vrm_mos_c,gpu_bdf,gpu_link_speed,gpu_link_width,gpu_aer_correctable,gpu_aer_nonfatal,gpu_aer_fatal,upstream_bdf,upstream_link_speed,upstream_link_width,upstream_aer_correctable,upstream_aer_nonfatal,upstream_aer_fatal'

if [[ -r "$HOME/.shell_colors" ]]; then
    # User color definitions are Bash-compatible ANSI assignments.
    source "$HOME/.shell_colors"
fi

RESET="${ENDCOLOR:-$'\033[0m'}"
PURPLE="${DRACULA_PURPLE:-$'\033[38;5;141m'}"
PINK="${DRACULA_PINK:-$'\033[38;5;212m'}"
CYAN="${DRACULA_CYAN:-$'\033[38;5;87m'}"
GREEN="${DRACULA_GREEN:-$'\033[38;5;84m'}"
YELLOW="${DRACULA_YELLOW:-$'\033[38;5;228m'}"
RED="${DRACULA_RED:-$'\033[38;5;203m'}"
FOREGROUND="${DRACULA_FOREGROUND:-$'\033[38;5;253m'}"
COMMENT="${DRACULA_COMMENT:-$'\033[38;5;60m'}"

if [[ ! -t 1 || -n "${NO_COLOR:-}" ]]; then
    RESET=''
    PURPLE=''
    PINK=''
    CYAN=''
    GREEN=''
    YELLOW=''
    RED=''
    FOREGROUND=''
    COMMENT=''
fi

if ! command -v timeout >/dev/null 2>&1; then
    printf 'Error: timeout (from coreutils) was not found.\n' >&2
    exit 1
fi
if ! command -v stat >/dev/null 2>&1; then
    printf 'Error: stat (from coreutils) was not found.\n' >&2
    exit 1
fi
if ! command -v flock >/dev/null 2>&1; then
    printf 'Error: flock (from util-linux) was not found.\n' >&2
    exit 1
fi

mkdir -p -- "$LOG_DIR" || {
    printf 'Error: could not create log directory: %s\n' "$LOG_DIR" >&2
    exit 1
}

LOCK_FILE="$LOG_DIR/.gpu-telemetry.lock"
exec {LOCK_FD}>>"$LOCK_FILE" || {
    printf 'Error: could not open telemetry lock file: %s\n' "$LOCK_FILE" >&2
    exit 1
}
if flock -n "$LOCK_FD"; then
    LOGGER_OWNER=1
else
    LOGGER_OWNER=0
fi
READ_ONLY_VIEW=0

PAD="$(printf '%*s' "$LEFT_PADDING" '')"
COL_WIDTHS=(8 5 8 4 5 12 5 12 9 7 9)
TABLE_HEADERS=(TIME STATE PWR/LIM GPU TEMP 'VRAM MiB' FAN% GFX/MEM PCIe 12V 'VRM MOS')

GPU_SYSFS=''
GPU_BDF=''
UPSTREAM_SYSFS=''
UPSTREAM_BDF=''
if (( LOGGER_OWNER )); then
    for pci_path in /sys/bus/pci/devices/*; do
        [[ -r "$pci_path/vendor" && -r "$pci_path/class" ]] || continue
        if [[ "$(<"$pci_path/vendor")" == '0x10de' && "$(<"$pci_path/class")" == '0x030000' ]]; then
            GPU_SYSFS="$pci_path"
            break
        fi
    done
    GPU_BDF="${GPU_SYSFS##*/}"
    if [[ -n "$GPU_SYSFS" ]]; then
        resolved_gpu_path="$(readlink -f -- "$GPU_SYSFS" 2>/dev/null || true)"
        if [[ -n "$resolved_gpu_path" ]]; then
            UPSTREAM_SYSFS="$(dirname -- "$resolved_gpu_path")"
        fi
    fi
    UPSTREAM_BDF="${UPSTREAM_SYSFS##*/}"
fi

OPTIONAL_FIELDS=()
optional_candidates=(memory.used memory.total temperature.memory fan.speed power.limit pcie.rx_throughput pcie.tx_throughput)
if (( LOGGER_OWNER )); then
    query_help="$(timeout 2s nvidia-smi --help-query-gpu 2>/dev/null || true)"
    for field in "${optional_candidates[@]}"; do
        escaped_field="${field//./\\.}"
        if [[ "$query_help" =~ (^|[^[:alnum:]_.])${escaped_field}([^[:alnum:]_.]|$) ]]; then
            OPTIONAL_FIELDS+=("$field")
        fi
    done
fi

KERNEL_FD=''
KERNEL_JOURNAL_PID=''
LAST_STORAGE_CAPTURE=0
NVME_CAPTURE_PID=''

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

rotate_file_if_needed() {
    local file="$1" header="$2" row_bytes="$3" max_bytes="${4:-$LOG_MAX_BYTES}"
    local rotations="${5:-$LOG_ROTATIONS}" current_size=0 i
    [[ -f "$file" ]] && current_size="$(stat -c '%s' -- "$file")"

    if (( current_size + row_bytes > max_bytes )); then
        rm -f -- "$file.$rotations"
        for ((i = rotations - 1; i >= 1; i--)); do
            if [[ -f "$file.$i" ]]; then
                mv -- "$file.$i" "$file.$((i + 1))"
            fi
        done
        mv -- "$file" "$file.1"
        printf '%s\n' "$header" > "$file"
    fi
}

append_log_row() {
    local row="$1" row_bytes
    row_bytes="$(printf '%s\n' "$row" | wc -c)"
    row_bytes="${row_bytes//[[:space:]]/}"
    rotate_file_if_needed "$LOG_FILE" "$CSV_HEADER" "$row_bytes"
    printf '%s\n' "$row" >> "$LOG_FILE"
}

append_extended_row() {
    local row="$1" row_bytes
    row_bytes="$(printf '%s\n' "$row" | wc -c)"
    row_bytes="${row_bytes//[[:space:]]/}"
    rotate_file_if_needed "$EXTENDED_LOG" "$EXTENDED_HEADER" "$row_bytes"
    printf '%s\n' "$row" >> "$EXTENDED_LOG"
}

append_platform_row() {
    local row="$1" row_bytes
    row_bytes="$(printf '%s\n' "$row" | wc -c)"
    row_bytes="${row_bytes//[[:space:]]/}"
    rotate_file_if_needed "$PLATFORM_LOG" "$PLATFORM_HEADER" "$row_bytes"
    printf '%s\n' "$row" >> "$PLATFORM_LOG"
}

append_storage_event() {
    local line="$1" row_bytes storage_lock_fd
    exec {storage_lock_fd}>>"$LOG_DIR/.storage-events.lock" || return 1
    flock -x "$storage_lock_fd" || {
        exec {storage_lock_fd}>&-
        return 1
    }
    if [[ ! -e "$STORAGE_LOG" ]]; then
        printf '%s\n' '===== NVME / STORAGE / PCIe EVENTS =====' > "$STORAGE_LOG"
    fi
    row_bytes="$(printf '%s\n' "$line" | wc -c)"
    row_bytes="${row_bytes//[[:space:]]/}"
    rotate_file_if_needed "$STORAGE_LOG" '===== NVME / STORAGE / PCIe EVENTS =====' \
        "$row_bytes" "$STORAGE_LOG_MAX_BYTES" "$STORAGE_LOG_ROTATIONS"
    printf '%s\n' "$line" >> "$STORAGE_LOG"
    flock -u "$storage_lock_fd"
    exec {storage_lock_fd}>&-
}

read_pci_value() {
    local file="$1"
    if [[ -r "$file" ]]; then
        tr '\n' ' ' < "$file" | sed 's/[[:space:]]*$//'
    else
        printf 'N/A'
    fi
}

read_aer_total() {
    local file="$1" key="$2"
    if [[ -r "$file" ]]; then
        awk -v key="$key" '$1 == key { print $2; found=1 } END { if (!found) print "N/A" }' "$file"
    else
        printf 'N/A'
    fi
}

capture_platform_metrics() {
    local timestamp="$1" sensor_values
    local gpu_speed gpu_width gpu_cor gpu_nonfatal gpu_fatal
    local upstream_speed upstream_width upstream_cor upstream_nonfatal upstream_fatal

    BOARD_12V='N/A'
    BOARD_VRM='N/A'
    if command -v sensors >/dev/null 2>&1; then
        sensor_values="$(timeout 2s sensors 2>/dev/null | awk '
            /^[[:space:]]*\+12V:/ { v12=$2; gsub(/[^0-9.]/, "", v12) }
            /^[[:space:]]*VRM MOS:/ { vrm=$3; gsub(/[^0-9.]/, "", vrm) }
            END { printf "%s,%s\n", v12 == "" ? "N/A" : v12, vrm == "" ? "N/A" : vrm }
        ')"
        IFS=, read -r BOARD_12V BOARD_VRM <<< "$sensor_values"
    fi

    gpu_speed="$(read_pci_value "$GPU_SYSFS/current_link_speed")"
    gpu_width="$(read_pci_value "$GPU_SYSFS/current_link_width")"
    gpu_cor="$(read_aer_total "$GPU_SYSFS/aer_dev_correctable" TOTAL_ERR_COR)"
    gpu_nonfatal="$(read_aer_total "$GPU_SYSFS/aer_dev_nonfatal" TOTAL_ERR_NONFATAL)"
    gpu_fatal="$(read_aer_total "$GPU_SYSFS/aer_dev_fatal" TOTAL_ERR_FATAL)"
    upstream_speed="$(read_pci_value "$UPSTREAM_SYSFS/current_link_speed")"
    upstream_width="$(read_pci_value "$UPSTREAM_SYSFS/current_link_width")"
    upstream_cor="$(read_aer_total "$UPSTREAM_SYSFS/aer_rootport_total_err_cor" TOTAL_ERR_COR)"
    upstream_nonfatal="$(read_aer_total "$UPSTREAM_SYSFS/aer_rootport_total_err_nonfatal" TOTAL_ERR_NONFATAL)"
    upstream_fatal="$(read_aer_total "$UPSTREAM_SYSFS/aer_rootport_total_err_fatal" TOTAL_ERR_FATAL)"

    platform_row="$timestamp,$BOARD_12V,$BOARD_VRM,${GPU_BDF:-N/A},$gpu_speed,$gpu_width,$gpu_cor,$gpu_nonfatal,$gpu_fatal,${UPSTREAM_BDF:-N/A},$upstream_speed,$upstream_width,$upstream_cor,$upstream_nonfatal,$upstream_fatal"
    append_platform_row "$platform_row"
}

append_kernel_event() {
    local line="$1" row_bytes
    if [[ ! -e "$KERNEL_LOG" ]]; then
        printf '%s\n' '===== GPU / PCIe KERNEL EVENTS =====' > "$KERNEL_LOG"
    fi
    row_bytes="$(printf '%s\n' "$line" | wc -c)"
    row_bytes="${row_bytes//[[:space:]]/}"
    rotate_file_if_needed "$KERNEL_LOG" '===== GPU / PCIe KERNEL EVENTS =====' "$row_bytes"
    printf '%s\n' "$line" >> "$KERNEL_LOG"
}

is_relevant_kernel_event() {
    local event_text="${1,,}"
    case "$event_text" in
        *xid[[:space:]]*|*nvrm:*error*|*nvrm:*failed*|*nvrm:*failure*|*nvrm:*timeout*|*nvrm:*timed.out*|*nvrm:*fault*|*nvrm:*fallen.off*|*nvrm:*reset*|*nvrm:*lost*|*aer:*uncorrected*|*aer:*fatal*|*aer:*non-fatal*|*pcie.bus.error*uncorrected*|*pcie.bus.error*fatal*|*pcieport*link*down*|*pcieport*link*fail*|*pcieport*dpc*contain*|*gpu*reset*|*gpu*fail*|*gpu*fault*|*gpu*error*|*gpu*lost*|*gpu*disconnect*|*nvidia*xid*|*nvidia*error*|*nvidia*failed*|*nvidia*failure*|*nvidia*timeout*|*nvidia*fault*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_storage_relevant_kernel_event() {
    local event_text="${1,,}"
    case "$event_text" in
        *nvme*|*blk_update_request*|*buffer\ i/o\ error*|*i/o\ error*|*device\ offline*|*resetting\ controller*|*controller\ is\ down*|*timeout*|*timed\ out*|*aer:*|*pcie\ bus\ error*|*pcieport*link*down*|*pcieport*link*fail*|*pcieport*dpc*|*attempted\ to\ kill\ init*|*general\ protection\ fault*|*ext4-fs*error*|*xfs*corruption*|*btrfs*error*|*unable\ to\ mount\ root*|*failed\ to\ mount\ root*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

read_kernel_events() {
    local event='' timestamp scanned=0 logged=0
    [[ -n "$KERNEL_FD" ]] || return 0
    # Bound work per redraw so an NVIDIA error storm cannot freeze the UI.
    while (( scanned < 1000 && logged < 25 )) && IFS= read -r -t 0 -u "$KERNEL_FD" event; do
        ((scanned += 1))
        if is_relevant_kernel_event "$event"; then
            timestamp="$(date --iso-8601=seconds)"
            append_kernel_event "[$timestamp] $event"
            alert_message="GPU/PCIe kernel event at $(date +%H:%M:%S) — details in kernel-events.log"
            alert_color="$RED"
            ((logged += 1))
        fi
        if is_storage_relevant_kernel_event "$event"; then
            timestamp="$(date --iso-8601=seconds)"
            append_storage_event "[$timestamp] [kernel] $event"
        fi
    done
    return 0
}

capture_nvme_health() {
    local timestamp controller controller_path pci_path upstream_path bdf upstream_bdf
    local speed width cor nonfatal fatal upstream_cor upstream_nonfatal upstream_fatal
    local found=0
    timestamp="$(date --iso-8601=seconds)"
    for controller_path in /sys/class/nvme/nvme[0-9]*; do
        [[ -e "$controller_path" ]] || continue
        ((found += 1))
        controller="${controller_path##*/}"
        pci_path="$(readlink -f -- "$controller_path/device" 2>/dev/null || true)"
        while [[ -n "$pci_path" && "$pci_path" != / && ! -r "$pci_path/current_link_speed" ]]; do
            pci_path="$(dirname -- "$pci_path")"
        done
        if [[ -n "$pci_path" && -r "$pci_path/current_link_speed" ]]; then
            bdf="${pci_path##*/}"
            speed="$(read_pci_value "$pci_path/current_link_speed")"
            width="$(read_pci_value "$pci_path/current_link_width")"
            cor="$(read_aer_total "$pci_path/aer_dev_correctable" TOTAL_ERR_COR)"
            nonfatal="$(read_aer_total "$pci_path/aer_dev_nonfatal" TOTAL_ERR_NONFATAL)"
            fatal="$(read_aer_total "$pci_path/aer_dev_fatal" TOTAL_ERR_FATAL)"
            append_storage_event "[$timestamp] [nvme-pcie:$controller] BDF=$bdf speed=$speed width=$width AER(correctable/nonfatal/fatal)=$cor/$nonfatal/$fatal"
            upstream_path="$(dirname -- "$pci_path")"
            while [[ "$upstream_path" != / && ! -r "$upstream_path/aer_rootport_total_err_cor" ]]; do
                upstream_path="$(dirname -- "$upstream_path")"
            done
            if [[ -r "$upstream_path/aer_rootport_total_err_cor" ]]; then
                upstream_bdf="${upstream_path##*/}"
                upstream_cor="$(read_aer_total "$upstream_path/aer_rootport_total_err_cor" TOTAL_ERR_COR)"
                upstream_nonfatal="$(read_aer_total "$upstream_path/aer_rootport_total_err_nonfatal" TOTAL_ERR_NONFATAL)"
                upstream_fatal="$(read_aer_total "$upstream_path/aer_rootport_total_err_fatal" TOTAL_ERR_FATAL)"
                append_storage_event "[$timestamp] [nvme-upstream:$controller] BDF=$upstream_bdf AER(correctable/nonfatal/fatal)=$upstream_cor/$upstream_nonfatal/$upstream_fatal"
            fi
        else
            append_storage_event "[$timestamp] [nvme-pcie:$controller] PCIe link counters unavailable"
        fi
    done
    if (( found == 0 )); then
        append_storage_event "[$timestamp] [nvme] No NVMe controllers found under /sys/class/nvme"
    fi
}

start_nvme_capture() {
    if [[ -n "$NVME_CAPTURE_PID" ]] && kill -0 "$NVME_CAPTURE_PID" 2>/dev/null; then
        return 0
    fi
    capture_nvme_health &
    NVME_CAPTURE_PID=$!
}

capture_system_identity() {
    local timestamp bios_version bios_date board_name
    timestamp="$(date --iso-8601=seconds)"
    bios_version="$(cat /sys/class/dmi/id/bios_version 2>/dev/null || true)"
    bios_date="$(cat /sys/class/dmi/id/bios_date 2>/dev/null || true)"
    board_name="$(cat /sys/class/dmi/id/board_name 2>/dev/null || true)"
    append_storage_event "[$timestamp] [system] board=${board_name:-N/A} BIOS=${bios_version:-N/A} BIOS-date=${bios_date:-N/A} kernel=$(uname -r)"
}

calculate_averages() {
    printf '%s\n' "${history_metrics[@]}" | awk -F, '
        {
            for (i = 1; i <= 5; i++) {
                if ($i ~ /^-?[0-9]+([.][0-9]+)?$/) {
                    sum[i] += $i
                    count[i]++
                }
            }
        }
        END {
            for (i = 1; i <= 5; i++) {
                if (count[i]) printf "%.1f", sum[i] / count[i]
                else printf "N/A"
                if (i < 5) printf ","
            }
            printf "\n"
        }
    '
}

render_display() {
    (( DISPLAY_MODE )) || return 0
    local averages avg_power avg_util avg_temp avg_graphics avg_memory
    local frame_inner=$((FRAME_WIDTH - 2)) row_count i title='GPU CRASH TELEMETRY'
    local title_left title_right outer_rule='' table_top_rule='' table_middle_rule='' table_bottom_rule=''
    local width index alert_line
    if (( READ_ONLY_VIEW )); then
        title='GPU TELEMETRY - READ ONLY'
    fi
    printf '\033[2J\033[H'
    printf -v outer_rule '%*s' "$frame_inner" ''
    outer_rule="${outer_rule// /─}"
    printf '%s%s╭%s╮%s\n' "$PAD" "$PURPLE" "$outer_rule" "$RESET"
    title_left=$(((frame_inner - ${#title}) / 2))
    title_right=$((frame_inner - ${#title} - title_left))
    printf '%s%s│%s%*s%s%*s%s│%s\n' "$PAD" "$PURPLE" "$RESET" \
        "$title_left" '' "$title" "$title_right" '' "$PURPLE" "$RESET"
    printf '%s%s├%s┤%s\n' "$PAD" "$PURPLE" "$outer_rule" "$RESET"
    frame_line "GPU: ${gpu_name:-Waiting for NVIDIA GPU}" "$CYAN"
    frame_line "Rolling view: latest $HISTORY_LIMIT samples (~${SAMPLE_INTERVAL}s apart)" "$COMMENT"
    alert_line="${alert_message:-No GPU/PCIe alerts this run}"
    frame_line "$alert_line" "${alert_color:-$COMMENT}"

    for index in "${COL_WIDTHS[@]}"; do
        if [[ -n "$table_top_rule" ]]; then
            table_top_rule+='┬'
            table_middle_rule+='┼'
            table_bottom_rule+='┴'
        fi
        printf -v width '%*s' "$index" ''
        table_top_rule+="${width// /─}"
        table_middle_rule+="${width// /─}"
        table_bottom_rule+="${width// /─}"
    done
    printf '%s%s├%s┤%s\n' "$PAD" "$PURPLE" "$table_top_rule" "$RESET"
    render_table_row "$PINK" "${TABLE_HEADERS[@]}"
    printf '%s%s├%s┤%s\n' "$PAD" "$PURPLE" "$table_middle_rule" "$RESET"
    row_count=${#history_lines[@]}
    for ((i = 0; i < HISTORY_LIMIT; i++)); do
        if (( i < row_count )); then
            IFS='|' read -r col_time col_state col_power col_gpu col_temp col_vram col_fan col_clocks col_pcie col_12v col_vrm <<< "${history_lines[i]}"
            render_table_row "$FOREGROUND" \
                "$col_time" "$col_state" "$col_power" "$col_gpu" "$col_temp" \
                "$col_vram" "$col_fan" "$col_clocks" "$col_pcie" "$col_12v" "$col_vrm"
        else
            render_table_row "$FOREGROUND" '' '' '' '' '' '' '' '' '' '' ''
        fi
    done

    averages="$(calculate_averages)"
    IFS=, read -r avg_power avg_util avg_temp avg_graphics avg_memory <<< "$averages"
    printf '%s%s├%s┤%s\n' "$PAD" "$PURPLE" "$table_bottom_rule" "$RESET"
    printf -v average_line 'AVG (%2s)  Power %s W  GPU %s%%  Temp %s C  Clocks %s / %s MHz' \
        "$row_count" "$avg_power" "$avg_util" "$avg_temp" "$avg_graphics" "$avg_memory"
    frame_line "$average_line" "$GREEN"
    printf '%s%s╰%s╯%s\n' "$PAD" "$PURPLE" "$outer_rule" "$RESET"
    if (( READ_ONLY_VIEW )); then
        printf '%s%sRead-only view of the active logger logs   %sCtrl+C to close%s\n' \
            "$PAD" "$CYAN" "$COMMENT" "$RESET"
    else
        printf '%s%sLogs:%s ./logs/ (GPU/PCIe/board/NVMe)   %sRetention:%s %s MiB × %s + 10 MiB storage   %sCtrl+C to stop%s\n' \
            "$PAD" \
            "$CYAN" "$RESET" "$CYAN" "$RESET" "$((LOG_MAX_BYTES / 1024 / 1024))" \
            "$((LOG_ROTATIONS + 1))" \
            "$COMMENT" "$RESET"
    fi
}

frame_line() {
    local text="$1" color="$2"
    printf '%s%s│%s %-*.*s %s│%s\n' "$PAD" "$PURPLE" "$color" \
        "$((FRAME_WIDTH - 4))" "$((FRAME_WIDTH - 4))" "$text" "$PURPLE" "$RESET"
}

render_table_row() {
    local cell_color="$1" i value
    local -a values=()
    shift
    values=("$@")
    printf '%s%s│%s' "$PAD" "$PURPLE" "$cell_color"
    for ((i = 0; i < ${#COL_WIDTHS[@]}; i++)); do
        value="${values[i]:-}"
        printf '%-*.*s' "${COL_WIDTHS[i]}" "${COL_WIDTHS[i]}" "$value"
        printf '%s│' "$PURPLE"
        if (( i + 1 < ${#COL_WIDTHS[@]} )); then
            printf '%s' "$cell_color"
        fi
    done
    printf '%s\n' "$RESET"
}

load_log_snapshot() {
    local file line status timestamp gpu state power util temp gfx memclock gen width detail
    local used total fan limit board12 vrm time_short power_display vram_display fan_display
    local display12 display_vrm escaped_detail
    local snapshot_rows=$((HISTORY_LIMIT * 3))
    local -A ext_used=() ext_total=() ext_fan=() ext_limit=() platform_12v=() platform_vrm=()

    history_lines=()
    history_metrics=()
    gpu_name=''

    if [[ -r "$EXTENDED_LOG" ]]; then
        while IFS=, read -r timestamp used total _ fan limit _ _; do
            [[ "$timestamp" == timestamp || -z "$timestamp" ]] && continue
            ext_used["$timestamp"]="$used"
            ext_total["$timestamp"]="$total"
            ext_fan["$timestamp"]="$fan"
            ext_limit["$timestamp"]="$limit"
        done < <(tail -n "$snapshot_rows" -- "$EXTENDED_LOG")
    fi
    if [[ -r "$PLATFORM_LOG" ]]; then
        while IFS=, read -r timestamp board12 vrm _; do
            [[ "$timestamp" == timestamp || -z "$timestamp" ]] && continue
            platform_12v["$timestamp"]="$board12"
            platform_vrm["$timestamp"]="$vrm"
        done < <(tail -n "$snapshot_rows" -- "$PLATFORM_LOG")
    fi

    if [[ -r "$LOG_FILE" ]]; then
        while IFS=, read -r status timestamp gpu state power util temp gfx memclock gen width detail; do
            [[ "$status" == status || -z "$status" || "$status" == RUN_START ]] && continue
            [[ -n "$timestamp" ]] || continue
            time_short="${timestamp##*T}"
            time_short="${time_short##* }"
            time_short="${time_short%%.*}"
            [[ "$time_short" == *+* ]] && time_short="${time_short%%+*}"
            [[ "$time_short" == *-* ]] && time_short="${time_short%%-*}"
            used="${ext_used[$timestamp]:-}"
            total="${ext_total[$timestamp]:-}"
            fan="${ext_fan[$timestamp]:-}"
            limit="${ext_limit[$timestamp]:-}"
            board12="${platform_12v[$timestamp]:-N/A}"
            vrm="${platform_vrm[$timestamp]:-N/A}"
            if [[ "$status" == ERROR ]]; then
                history_lines+=("$time_short|ERROR|N/A|N/A|N/A|N/A|N/A|N/A|N/A|N/A|N/A")
                history_metrics+=',,,,'
                escaped_detail="${detail#\"}"
                escaped_detail="${escaped_detail%\"}"
                alert_message="Logged GPU query error at $time_short: ${escaped_detail:0:55}"
                alert_color="$YELLOW"
                continue
            fi

            gpu_name="$gpu"
            if [[ "$power" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                if [[ "$limit" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                    power_display="${power%%.*}/${limit%%.*}"
                else
                    power_display="${power}W"
                fi
            else
                power_display='N/A'
            fi
            if [[ -n "$used" && -n "$total" && "$used" != N/A && "$total" != N/A ]]; then
                vram_display="$used/$total"
            else
                vram_display='N/A'
            fi
            if [[ "$fan" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                fan_display="${fan%%.*}%"
            else
                fan_display='N/A'
            fi
            if [[ "$board12" =~ ^[0-9]+([.][0-9]+)?$ ]]; then display12="${board12}V"; else display12='N/A'; fi
            if [[ "$vrm" =~ ^[0-9]+([.][0-9]+)?$ ]]; then display_vrm="${vrm}C"; else display_vrm='N/A'; fi
            history_lines+=("$time_short|$state|$power_display|${util}%|${temp}C|$vram_display|$fan_display|${gfx}/${memclock}|Gen${gen} x${width}|$display12|$display_vrm")
            history_metrics+=("$power,$util,$temp,$gfx,$memclock")
        done < <(tail -n "$snapshot_rows" -- "$LOG_FILE")
    fi

    if (( ${#history_lines[@]} > HISTORY_LIMIT )); then
        history_lines=("${history_lines[@]: -HISTORY_LIMIT}")
        history_metrics=("${history_metrics[@]: -HISTORY_LIMIT}")
    fi
    if [[ -z "$alert_message" ]]; then
        alert_message='Read-only view: active logger owns data'
        alert_color="$CYAN"
    fi
}

run_log_viewer() {
    READ_ONLY_VIEW=1
    while :; do
        alert_message=''
        load_log_snapshot
        render_display
        sleep "$SAMPLE_INTERVAL"
    done
}

history_lines=()
history_metrics=()
gpu_name=''
BOARD_12V='N/A'
BOARD_VRM='N/A'
alert_message=''
alert_color="$COMMENT"
query_fields=(timestamp name pstate power.draw utilization.gpu temperature.gpu clocks.current.graphics clocks.current.memory pcie.link.gen.current pcie.link.width.current)
query_fields+=("${OPTIONAL_FIELDS[@]}")
QUERY_LIST="$(IFS=,; printf '%s' "${query_fields[*]}")"

cleanup() {
    if [[ -n "$KERNEL_JOURNAL_PID" ]]; then
        kill "$KERNEL_JOURNAL_PID" 2>/dev/null || true
    fi
    if [[ -n "$NVME_CAPTURE_PID" ]]; then
        kill "$NVME_CAPTURE_PID" 2>/dev/null || true
        wait "$NVME_CAPTURE_PID" 2>/dev/null || true
    fi
    if [[ -n "$KERNEL_FD" ]]; then
        exec {KERNEL_FD}<&-
    fi
    if (( DISPLAY_MODE )); then
        printf '\033[?25h%s\n' "$RESET"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if (( ! LOGGER_OWNER )); then
    if (( DISPLAY_MODE )); then
        run_log_viewer
    else
        printf 'GPU telemetry logger is already running; existing logs were left untouched.\n'
    fi
    exit 0
fi

if ! command -v nvidia-smi >/dev/null 2>&1; then
    printf 'Error: nvidia-smi was not found.\n' >&2
    exit 1
fi

[[ -s "$LOG_FILE" ]] || printf '%s\n' "$CSV_HEADER" > "$LOG_FILE"
[[ -s "$EXTENDED_LOG" ]] || printf '%s\n' "$EXTENDED_HEADER" > "$EXTENDED_LOG"
[[ -s "$PLATFORM_LOG" ]] || printf '%s\n' "$PLATFORM_HEADER" > "$PLATFORM_LOG"

if (( DISPLAY_MODE )); then
    printf '\033[?25l'
fi

run_started_at="$(date --iso-8601=seconds)"
run_marker="RUN_START,$run_started_at,,,,,,,,,,\"===== NEW RUN =====\""
append_log_row "$run_marker"
append_extended_row "$run_started_at,,,,,,,"
append_kernel_event "[$run_started_at] ===== NEW RUN ====="
capture_platform_metrics "$run_started_at"
# Draw immediately so startup history collection never looks like a no-op.
render_display
if command -v journalctl >/dev/null 2>&1; then
    previous_event_count=0
    previous_event_limit=50
    previous_line_count=0
    previous_line_limit=2000
    while IFS= read -r previous_event; do
        ((previous_line_count += 1))
        if is_relevant_kernel_event "$previous_event"; then
            append_kernel_event "[previous boot] $previous_event"
            alert_message="Previous boot GPU/PCIe events found — details in kernel-events.log"
            alert_color="$YELLOW"
            ((previous_event_count += 1))
            if (( previous_event_count >= previous_event_limit )); then
                break
            fi
        fi
        if is_storage_relevant_kernel_event "$previous_event"; then
            append_storage_event "[previous boot] [kernel] $previous_event"
        fi
        if (( previous_line_count >= previous_line_limit )); then
            break
        fi
    done < <(journalctl -k -b -1 -p warning -n 100 -r --no-pager -o short-iso-precise 2>/dev/null || true)

    coproc KERNEL_JOURNAL {
        journalctl -k -f -p warning -n 0 --no-pager -o short-iso-precise 2>/dev/null
    }
    KERNEL_FD="${KERNEL_JOURNAL[0]}"
    KERNEL_JOURNAL_PID="${KERNEL_JOURNAL_PID:-}"
fi
capture_system_identity
start_nvme_capture
LAST_STORAGE_CAPTURE="$(date +%s)"
render_display

while :; do
    if sample="$(timeout "${QUERY_TIMEOUT}s" nvidia-smi \
        --query-gpu="$QUERY_LIST" \
        --format=csv,noheader,nounits 2>&1)"; then
        sample="${sample//$'\r'/ }"
        sample="${sample//$'\n'/ }"
        IFS=, read -r -a sample_fields <<< "$sample"
        sample_time="${sample_fields[0]:-}"
        sample_gpu="${sample_fields[1]:-}"
        sample_state="${sample_fields[2]:-}"
        sample_power="${sample_fields[3]:-}"
        sample_util="${sample_fields[4]:-}"
        sample_temp="${sample_fields[5]:-}"
        sample_graphics="${sample_fields[6]:-}"
        sample_memory="${sample_fields[7]:-}"
        sample_gen="${sample_fields[8]:-}"
        sample_width="${sample_fields[9]:-}"
        sample_time="$(trim "$sample_time")"
        gpu_name="$(trim "$sample_gpu")"
        sample_state="$(trim "$sample_state")"
        sample_power="$(trim "$sample_power")"
        sample_util="$(trim "$sample_util")"
        sample_temp="$(trim "$sample_temp")"
        sample_graphics="$(trim "$sample_graphics")"
        sample_memory="$(trim "$sample_memory")"
        sample_gen="$(trim "$sample_gen")"
        sample_width="$(trim "$sample_width")"

        display_time="${sample_time##* }"
        display_time="${display_time%%.*}"
        log_row="DATA,$sample_time,$gpu_name,$sample_state,$sample_power,$sample_util,$sample_temp,$sample_graphics,$sample_memory,$sample_gen,$sample_width,"
        declare -A optional_values=()
        for ((field_index = 0; field_index < ${#OPTIONAL_FIELDS[@]}; field_index++)); do
            optional_value="$(trim "${sample_fields[10 + field_index]:-}")"
            optional_values["${OPTIONAL_FIELDS[field_index]}"]="$optional_value"
        done
        sample_limit="${optional_values[power.limit]:-}"
        sample_vram_used="${optional_values[memory.used]:-}"
        sample_vram_total="${optional_values[memory.total]:-}"
        sample_fan="${optional_values[fan.speed]:-N/A}"
        if [[ "$sample_power" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            if awk -v value="$sample_power" 'BEGIN { exit !(value >= 100) }'; then
                printf -v power_draw_short '%.0f' "$sample_power"
            else
                printf -v power_draw_short '%.1f' "$sample_power"
            fi
            if [[ "$sample_limit" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                power_display="$power_draw_short/${sample_limit%%.*}"
            else
                power_display="${power_draw_short}W"
            fi
        else
            power_display='N/A'
        fi
        if [[ -n "$sample_vram_used" && "$sample_vram_used" != N/A && -n "$sample_vram_total" && "$sample_vram_total" != N/A ]]; then
            vram_display="$sample_vram_used/$sample_vram_total"
        else
            vram_display='N/A'
        fi
        if [[ "$sample_fan" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            fan_display="${sample_fan%%.*}%"
        else
            fan_display='N/A'
        fi
        capture_platform_metrics "$sample_time"
        if [[ "$BOARD_12V" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            display_12v="${BOARD_12V}V"
        else
            display_12v='N/A'
        fi
        if [[ "$BOARD_VRM" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            display_vrm="${BOARD_VRM}C"
        else
            display_vrm='N/A'
        fi
        history_lines+=("$display_time|$sample_state|$power_display|${sample_util}%|${sample_temp}C|$vram_display|$fan_display|${sample_graphics}/${sample_memory}|Gen${sample_gen} x${sample_width}|$display_12v|$display_vrm")
        history_metrics+=("$sample_power,$sample_util,$sample_temp,$sample_graphics,$sample_memory")
        ext_row="$sample_time"
        for field in memory.used memory.total temperature.memory fan.speed power.limit pcie.rx_throughput pcie.tx_throughput; do
            ext_value="${optional_values[$field]:-}"
            ext_row+=",$ext_value"
        done
        append_extended_row "$ext_row"
        alert_message=''
        alert_color="$COMMENT"
    else
        error_text="${sample//$'\r'/ }"
        error_text="${error_text//$'\n'/ }"
        escaped_error="${error_text//\"/\"\"}"
        sample_time="$(date --iso-8601=seconds)"
        display_time="$(date '+%H:%M:%S')"
        capture_platform_metrics "$sample_time"
        if [[ "$BOARD_12V" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            display_12v="${BOARD_12V}V"
        else
            display_12v='N/A'
        fi
        if [[ "$BOARD_VRM" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            display_vrm="${BOARD_VRM}C"
        else
            display_vrm='N/A'
        fi
        history_lines+=("$display_time|ERROR|N/A|N/A|N/A|N/A|N/A|N/A|N/A|$display_12v|$display_vrm")
        history_metrics+=',,,,'
        log_row="ERROR,$sample_time,,,,,,,,,,\"$escaped_error\""
        alert_message="GPU query failed at $display_time — details in gpu-telemetry.csv"
        alert_color="$YELLOW"
    fi

    read_kernel_events
    current_epoch="$(date +%s)"
    if (( current_epoch - LAST_STORAGE_CAPTURE >= 60 )); then
        start_nvme_capture
        LAST_STORAGE_CAPTURE="$current_epoch"
    fi

    if (( ${#history_lines[@]} > HISTORY_LIMIT )); then
        history_lines=("${history_lines[@]:1}")
        history_metrics=("${history_metrics[@]:1}")
    fi

    append_log_row "$log_row"
    render_display
    sleep "$SAMPLE_INTERVAL"
done
