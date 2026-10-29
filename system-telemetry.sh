#!/usr/bin/env bash
#
# System Telemetry: logs NVIDIA GPU state and saves a crash bundle whenever the
# driver loses the GPU, so every black-screen event leaves evidence behind.

set -uo pipefail
shopt -s extglob nullglob
export LC_ALL=C

usage() {
    printf 'Usage: %s [--headless]\n' "${0##*/}"
    printf 'Log GPU telemetry and save a crash bundle when the GPU stops answering.\n'
    printf 'If a logger is already running, this opens a read-only dashboard instead.\n'
}

DISPLAY_MODE=1
case "${1:-}" in
    '') ;;
    --headless|--no-display) DISPLAY_MODE=0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
(( $# <= 1 )) || { usage >&2; exit 2; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${TELEMETRY_LOG_DIR:-$SCRIPT_DIR/logs}"
TELEMETRY_CSV="$LOG_DIR/telemetry.csv"
HEALTH_CSV="$LOG_DIR/health.csv"
EVENTS_LOG="$LOG_DIR/events.log"
CRASH_DIR="$LOG_DIR/crashes"
ALERT_FILE="$LOG_DIR/.alert"
SEEN_BOOTS="$LOG_DIR/.seen-boots"
SEEN_PSTORE="$LOG_DIR/.seen-pstore"
LOCK_FILE="$LOG_DIR/.logger.lock"
PSTORE_DIR=/var/lib/systemd/pstore

SAMPLE_INTERVAL=2
QUERY_TIMEOUT=4
HEALTH_INTERVAL=3600         # remapped rows only change after a GPU reset, so hourly is plenty
LOST_ROW_INTERVAL=60         # while the GPU is gone, log one LOST row a minute instead of every sample
BUNDLE_COOLDOWN=1800         # one crash bundle per failure, not one per error line
BUNDLE_SAMPLES=300           # about 10 minutes of samples before the failure
BUNDLE_KERNEL_LOOKBACK=900   # kernel log from 15 minutes before the failure
FOLLOWUP_DELAY=90            # recapture the kernel log once the error storm has played out
REPEAT_LOG_EVERY=500         # repeated kernel messages are logged once, then every Nth time
TELEMETRY_MAX_BYTES=$((20 * 1024 * 1024))
TELEMETRY_ROTATIONS=2
EVENTS_MAX_BYTES=$((5 * 1024 * 1024))
EVENTS_ROTATIONS=2
HISTORY_LIMIT=10
FRAME_WIDTH=96

# Xids that mean the GPU itself failed (memory, firmware, bus), not an application fault.
TRIGGER_RE='Xid \([^)]*\): (48|61|62|63|64|74|79|92|94|95|119|120|140|154)([^0-9]|$)|fallen off the bus|API_GPU_ATTACHED_SANITY_CHECK|_scrubWaitAndSave: Timed out|RmInitAdapter failed|AER: (Uncorrect|.*[Ff]atal)'
KERNEL_FILTER='NVRM|nvidia|Xid|pcieport|AER|fallen off'

QUERY_FIELDS=(pstate power.draw power.limit utilization.gpu utilization.memory temperature.gpu
    temperature.memory clocks.current.graphics clocks.current.memory pcie.link.gen.current
    pcie.link.width.current memory.used memory.total fan.speed clocks_event_reasons.active)
TELEMETRY_HEADER='timestamp,status,pstate,power_w,power_limit_w,gpu_util_pct,mem_util_pct,temp_c,mem_temp_c,gfx_mhz,mem_mhz,pcie_gen,pcie_width,vram_used_mib,vram_total_mib,fan_pct,clock_reasons,detail'
HEALTH_HEADER='timestamp,boot_id,reason,gpu_name,driver,vbios,ecc_mode,persistence,remap_correctable,remap_uncorrectable,remap_pending,remap_failure,hist_max,hist_high,hist_partial,hist_low,hist_none'

if [[ -r "$HOME/.shell_colors" ]]; then
    # User color definitions are Bash-compatible ANSI assignments.
    source "$HOME/.shell_colors"
fi
RESET="${ENDCOLOR:-$'\e[0m'}"
PURPLE="${DRACULA_PURPLE:-$'\e[38;5;141m'}"
PINK="${DRACULA_PINK:-$'\e[38;5;212m'}"
CYAN="${DRACULA_CYAN:-$'\e[38;5;87m'}"
GREEN="${DRACULA_GREEN:-$'\e[38;5;84m'}"
YELLOW="${DRACULA_YELLOW:-$'\e[38;5;228m'}"
RED="${DRACULA_RED:-$'\e[38;5;203m'}"
FOREGROUND="${DRACULA_FOREGROUND:-$'\e[38;5;253m'}"
COMMENT="${DRACULA_COMMENT:-$'\e[38;5;60m'}"
if [[ ! -t 1 || -n "${NO_COLOR:-}" ]]; then
    RESET='' PURPLE='' PINK='' CYAN='' GREEN='' YELLOW='' RED='' FOREGROUND='' COMMENT=''
fi

for tool in timeout flock stat; do
    command -v "$tool" >/dev/null 2>&1 || { printf 'Error: %s was not found.\n' "$tool" >&2; exit 1; }
done
mkdir -p -- "$CRASH_DIR" || { printf 'Error: could not create %s\n' "$CRASH_DIR" >&2; exit 1; }
exec {LOCK_FD}>>"$LOCK_FILE" || { printf 'Error: could not open %s\n' "$LOCK_FILE" >&2; exit 1; }
LOGGER_OWNER=0
flock -n "$LOCK_FD" && LOGGER_OWNER=1

BOOT_ID="$(</proc/sys/kernel/random/boot_id)"
BOOT_ID="${BOOT_ID//-/}"   # journald writes boot IDs without dashes
NOW=''
GPU_SYSFS=''
UPSTREAM_SYSFS=''
QUERY_LIST=''
FIELD_SUPPORTED=()
KWATCH_FD=''
KWATCH_CHILD=''
KWATCH_RETRY_AT=0
declare -A KERNEL_SEEN=()
GPU_LOST=0
SAMPLE_FAILS=0
LAST_LOST_ROW=0
LAST_BUNDLE_EPOCH=0
BUNDLE_DIR=''
BUNDLE_EPOCH=0
FOLLOWUP_AT=0

# ---------------------------------------------------------------- logging

stamp() { printf -v NOW '%(%FT%T%z)T' -1; }
epoch_now() { printf -v EPOCH '%(%s)T' -1; }

clean_value() { # raw -> CLEAN, trimmed, with nvidia-smi placeholders emptied
    local v="${1##+([[:space:]])}"
    v="${v%%+([[:space:]])}"
    [[ "$v" == ?(\[)@(N/A|Not Supported|Unknown Error)?(\]) ]] && v=''
    CLEAN="$v"
}

rotate_if_needed() { # file max-bytes rotations [header]
    local file="$1" max="$2" rotations="$3" header="${4:-}" size i
    [[ -f "$file" ]] || return 0
    size="$(stat -c %s -- "$file")" || return 0
    (( size >= max )) || return 0
    rm -f -- "$file.$rotations"
    for ((i = rotations - 1; i >= 1; i--)); do
        [[ -f "$file.$i" ]] && mv -- "$file.$i" "$file.$((i + 1))"
    done
    mv -- "$file" "$file.1"
    [[ -z "$header" ]] || printf '%s\n' "$header" > "$file"
}

log_event() { # tag text
    stamp
    printf '[%s] [%s] %s\n' "$NOW" "$1" "$2" >> "$EVENTS_LOG"
}

set_alert() { # level(ok|warn|bad) text; shared with read-only dashboards through ALERT_FILE
    printf '%s|%s\n' "$1" "$2" > "$ALERT_FILE"
}

# ---------------------------------------------------------------- system state

find_gpu() {
    local dev resolved
    for dev in /sys/bus/pci/devices/*; do
        [[ -r "$dev/vendor" && -r "$dev/class" ]] || continue
        if [[ "$(<"$dev/vendor")" == 0x10de && "$(<"$dev/class")" == 0x030000 ]]; then
            GPU_SYSFS="$dev"
            resolved="$(readlink -f -- "$dev")"
            UPSTREAM_SYSFS="${resolved%/*}"
            KERNEL_FILTER+="|${dev##*/}"
            return 0
        fi
    done
}

detect_query_fields() {
    local help field i
    local -a used=()
    help="$(timeout 5s nvidia-smi --help-query-gpu 2>/dev/null)"
    for i in "${!QUERY_FIELDS[@]}"; do
        field="${QUERY_FIELDS[i]}"
        # Older drivers call the clock reasons "throttle" reasons.
        if [[ "$field" == clocks_event_reasons.active && "$help" != *"\"$field\""* ]]; then
            field=clocks_throttle_reasons.active
        fi
        if [[ "$help" == *"\"$field\""* ]]; then
            FIELD_SUPPORTED[i]=1
            used+=("$field")
        else
            FIELD_SUPPORTED[i]=0
        fi
    done
    QUERY_LIST="$(IFS=,; printf '%s' "${used[*]}")"
}

system_identity() {
    local board bios microcode
    board="$(cat /sys/class/dmi/id/board_name 2>/dev/null)"
    bios="$(cat /sys/class/dmi/id/bios_version 2>/dev/null) ($(cat /sys/class/dmi/id/bios_date 2>/dev/null))"
    microcode="$(grep -m1 '^microcode' /proc/cpuinfo 2>/dev/null)"
    printf 'boot=%s kernel=%s board=%s bios=%s microcode=%s' \
        "${BOOT_ID:0:8}" "$(uname -r)" "${board:-?}" "$bios" "${microcode##*: }"
}

write_pci_state() { # file
    local dev f
    {
        for dev in "$GPU_SYSFS" "$UPSTREAM_SYSFS"; do
            [[ -n "$dev" ]] || continue
            printf '== %s\n' "${dev##*/}"
            for f in current_link_speed current_link_width max_link_speed max_link_width power_state \
                aer_dev_correctable aer_dev_nonfatal aer_dev_fatal; do
                [[ -r "$dev/$f" ]] && printf '%s: %s\n' "$f" "$(tr '\n' ' ' < "$dev/$f")"
            done
        done
    } > "$1" 2>&1
}

take_health_snapshot() { # reason
    local reason="$1" info remap row last ru_old rc_old ru rc rp rf
    info="$(timeout 10s nvidia-smi --format=csv,noheader \
        --query-gpu=name,driver_version,vbios_version,ecc.mode.current,persistence_mode 2>/dev/null)" || {
        log_event health "snapshot ($reason) skipped: GPU did not answer"
        return 1
    }
    remap="$(timeout 10s nvidia-smi --format=csv,noheader \
        --query-remapped-rows=remapped_rows.correctable,remapped_rows.uncorrectable,remapped_rows.pending,remapped_rows.failure,remapped_rows.histogram.max,remapped_rows.histogram.high,remapped_rows.histogram.partial,remapped_rows.histogram.low,remapped_rows.histogram.none \
        2>/dev/null)" || remap=',,,,,,,,'
    stamp
    row="$NOW,$BOOT_ID,$reason,${info//, /,},${remap//, /,}"
    [[ -s "$HEALTH_CSV" ]] || printf '%s\n' "$HEALTH_HEADER" > "$HEALTH_CSV"
    last="$(tail -n 1 -- "$HEALTH_CSV")"
    printf '%s\n' "$row" >> "$HEALTH_CSV"

    IFS=, read -r _ _ _ _ _ _ _ _ rc ru rp rf _ <<< "$row"
    IFS=, read -r _ _ _ _ _ _ _ _ rc_old ru_old _ <<< "$last"
    if [[ "$ru_old" =~ ^[0-9]+$ && "$ru" =~ ^[0-9]+$ && "$rc_old" =~ ^[0-9]+$ && "$rc" =~ ^[0-9]+$ ]] &&
        (( ru > ru_old || rc > rc_old )); then
        log_event health "VRAM remapped rows went up: uncorrectable $ru_old -> $ru, correctable $rc_old -> $rc"
        set_alert bad "VRAM remapped rows went up: uncorrectable $ru_old -> $ru (see health.csv)"
    elif [[ "$rf" == Yes ]]; then
        set_alert bad 'VRAM row remapping FAILED: the card is out of spare rows'
    elif [[ "$rp" == Yes ]]; then
        set_alert warn 'VRAM row remap pending: it takes effect after the next GPU reset'
    fi
}

check_pstore() {
    local entry id when count=0
    [[ -d "$PSTORE_DIR" ]] || return 0
    for entry in "$PSTORE_DIR"/*/; do
        id="${entry%/}"
        id="${id##*/}"
        grep -qxF -- "$id" "$SEEN_PSTORE" 2>/dev/null && continue
        printf '%s\n' "$id" >> "$SEEN_PSTORE"
        when=unknown
        [[ "$id" =~ ^[0-9]+$ ]] && printf -v when '%(%F %T)T' "$id"
        log_event panic "kernel panic dump from $when in ${entry%/} (root-only: sudo cat ${entry}*/*)"
        ((count += 1))
    done
    (( count == 0 )) || set_alert warn "$count new kernel panic dump(s) in $PSTORE_DIR - see events.log"
}

# ---------------------------------------------------------------- crash bundles

telemetry_window() { # start-epoch end-epoch -> CSV rows between them
    local from to
    printf -v from '%(%FT%T)T' "$1"
    printf -v to '%(%FT%T)T' "$2"
    printf '%s\n' "$TELEMETRY_HEADER"
    awk -F, -v from="$from" -v to="$to" \
        'FNR > 1 { t = substr($1, 1, 19); if (t >= from && t <= to) print }' \
        "$TELEMETRY_CSV".{2,1} "$TELEMETRY_CSV" 2>/dev/null
}

write_summary() { # dir trigger detail boot-id
    {
        printf 'Trigger:   %s\n' "$2"
        printf 'Detail:    %s\n' "$3"
        printf 'Saved:     %(%F %T %z)T\n' -1
        printf 'Boot ID:   %s\n' "$4"
        printf 'System:    %s\n' "$(system_identity)"
        printf 'GPU:       %s\n' "${GPU_SYSFS##*/}"
        printf 'Cmdline:   %s\n\n' "$(</proc/cmdline)"
        printf 'Latest VRAM health snapshot:\n'
        [[ -s "$HEALTH_CSV" ]] && { head -n 1 -- "$HEALTH_CSV"; tail -n 1 -- "$HEALTH_CSV"; }
    } > "$1/summary.txt" 2>&1
}

capture_bundle_kernel() { # dir since-epoch
    command -v journalctl >/dev/null 2>&1 || return 0
    journalctl -k -b 0 --since "@$2" -o short-iso-precise --no-pager 2>&1 | tail -n 20000 > "$1/kernel.log"
}

trigger_bundle() { # trigger detail
    local dir
    epoch_now
    (( EPOCH - LAST_BUNDLE_EPOCH >= BUNDLE_COOLDOWN )) || return 0
    LAST_BUNDLE_EPOCH="$EPOCH"
    printf -v dir '%s/%(%Y-%m-%d_%H%M%S)T' "$CRASH_DIR" "$EPOCH"
    mkdir -p -- "$dir" || return 0
    printf '%s\n' "$BOOT_ID" > "$dir/boot_id"
    write_summary "$dir" "$1" "$2" "$BOOT_ID"
    {
        printf '%s\n' "$TELEMETRY_HEADER"
        cat -- "$TELEMETRY_CSV.1" "$TELEMETRY_CSV" 2>/dev/null | grep -v '^timestamp,' | tail -n "$BUNDLE_SAMPLES"
    } > "$dir/telemetry.csv"
    write_pci_state "$dir/pci.txt"
    tail -n 200 -- "$EVENTS_LOG" > "$dir/events.txt" 2>/dev/null
    capture_bundle_kernel "$dir" "$((EPOCH - BUNDLE_KERNEL_LOOKBACK))"
    # nvidia-smi can hang on a dead GPU; never let it stall the logger.
    ( timeout 20s nvidia-smi -q > "$dir/nvidia-smi-q.txt" 2>&1 ) &
    BUNDLE_DIR="$dir"
    BUNDLE_EPOCH="$EPOCH"
    FOLLOWUP_AT=$((EPOCH + FOLLOWUP_DELAY))
    log_event crash "crash bundle saved to ${dir#"$LOG_DIR/"} ($1)"
    set_alert bad "GPU failure at $(printf '%(%T)T' "$EPOCH") - bundle ${dir#"$LOG_DIR/"}"
}

check_previous_boot() {
    local previous first first_ts first_epoch dir='' f
    command -v journalctl >/dev/null 2>&1 || return 0
    previous="$(journalctl -b -1 -n 1 -o export --no-pager 2>/dev/null | sed -n 's/^_BOOT_ID=//p')"
    [[ -n "$previous" ]] || return 0
    grep -qxF -- "$previous" "$SEEN_BOOTS" 2>/dev/null && return 0
    printf '%s\n' "$previous" >> "$SEEN_BOOTS"

    first="$(journalctl -k -b -1 -o short-iso-precise --no-pager 2>/dev/null | grep -a -m1 -E "$TRIGGER_RE")"
    if [[ -z "$first" ]]; then
        log_event boot "previous boot ${previous:0:8} shows no GPU failure"
        return 0
    fi
    first_ts="${first%% *}"
    first_epoch="$(date -d "$first_ts" +%s 2>/dev/null)" || first_epoch=0
    log_event boot "previous boot ${previous:0:8} hit a GPU failure at $first_ts: ${first#* kernel: }"

    for f in "$CRASH_DIR"/*/boot_id; do
        [[ "$(<"$f")" == "$previous" ]] && dir="${f%/boot_id}"
    done
    if [[ -z "$dir" ]]; then
        # The logger missed it live (it was not running, or the machine froze), so build the bundle now.
        printf -v dir '%s/%(%Y-%m-%d_%H%M%S)T_previous-boot' "$CRASH_DIR" "$first_epoch"
        mkdir -p -- "$dir" || return 0
        printf '%s\n' "$previous" > "$dir/boot_id"
        write_summary "$dir" 'previous boot (found when the logger started)' "$first" "$previous"
        telemetry_window "$((first_epoch - 600))" "$((first_epoch + 60))" > "$dir/telemetry.csv"
        log_event crash "crash bundle saved to ${dir#"$LOG_DIR/"} (previous boot)"
        set_alert bad "Previous boot ended after a GPU failure - bundle ${dir#"$LOG_DIR/"}"
    fi
    journalctl -k -b -1 --since "@$((first_epoch - 300))" -o short-iso-precise --no-pager 2>&1 |
        head -n 20000 > "$dir/kernel-previous-boot.log"
}

# ---------------------------------------------------------------- kernel watcher

start_kernel_watcher() {
    command -v journalctl >/dev/null 2>&1 || {
        log_event logger 'journalctl not found: kernel messages are not being watched'
        return 0
    }
    coproc KWATCH {
        journalctl -k -f -n 0 -o short-iso-precise --no-pager 2>/dev/null |
            grep --line-buffered -a -E "$KERNEL_FILTER"
    }
    # Bash unsets the coproc variables when it exits, so keep copies.
    KWATCH_FD="${KWATCH[0]}"
    KWATCH_CHILD="$KWATCH_PID"
}

stop_kernel_watcher() {
    if [[ -n "$KWATCH_CHILD" ]]; then
        pkill -P "$KWATCH_CHILD" 2>/dev/null
        kill "$KWATCH_CHILD" 2>/dev/null
    fi
    [[ -z "$KWATCH_FD" ]] || exec {KWATCH_FD}<&-
    KWATCH_FD=''
    KWATCH_CHILD=''
}

handle_kernel_line() { # journal line
    local line="$1" message key count xid
    message="${line#* kernel: }"
    if [[ "$message" =~ Xid\ \([^\)]*\):\ ([0-9]+) ]]; then
        # Every Xid is kept: they are rare, and the code says what failed.
        xid="${BASH_REMATCH[1]}"
        log_event kernel "${line%% *} $message"
        if [[ "$message" =~ $TRIGGER_RE ]]; then
            set_alert bad "Xid $xid (GPU failure) at ${line:11:8} - see crash bundle"
        else
            set_alert warn "Xid $xid at ${line:11:8} - see events.log"
        fi
    else
        key="${message//0x+([[:xdigit:]])/#}"
        key="${key//+([0-9])/#}"
        count=$(( ${KERNEL_SEEN["$key"]:-0} + 1 ))
        KERNEL_SEEN["$key"]="$count"
        if (( count == 1 )); then
            log_event kernel "${line%% *} $message"
        elif (( count % REPEAT_LOG_EVERY == 0 )); then
            log_event kernel "${line%% *} (seen $count times) $message"
        fi
    fi
    [[ "$message" =~ $TRIGGER_RE ]] && trigger_bundle kernel "$message"
}

wait_for_kernel_lines() { # deadline in microseconds; doubles as the sample delay
    local deadline="$1" remaining secs line
    while :; do
        remaining=$(( deadline - ${EPOCHREALTIME/./} ))
        (( remaining > 0 )) || return 0
        printf -v secs '%d.%06d' $((remaining / 1000000)) $((remaining % 1000000))
        if [[ -z "$KWATCH_FD" ]]; then
            sleep "$secs"
            return 0
        fi
        if IFS= read -r -t "$secs" -u "$KWATCH_FD" line; then
            handle_kernel_line "$line"
        elif (( $? <= 128 )); then
            log_event logger 'kernel watcher stopped; retrying in a minute'
            stop_kernel_watcher
            epoch_now
            KWATCH_RETRY_AT=$((EPOCH + 60))
        fi
    done
}

# ---------------------------------------------------------------- sampling

take_sample() {
    local output status i j=0 row detail
    local -a fields=() values=()
    output="$(timeout "${QUERY_TIMEOUT}s" nvidia-smi --query-gpu="$QUERY_LIST" \
        --format=csv,noheader,nounits 2>&1)"
    status=$?
    stamp
    epoch_now
    IFS=, read -r -a fields <<< "$output"
    if (( status == 0 )) && [[ "$output" != *$'\n'* ]] && (( ${#fields[@]} >= ${#QUERY_FIELDS[@]} - 2 )); then
        for i in "${!QUERY_FIELDS[@]}"; do
            CLEAN=''
            if (( FIELD_SUPPORTED[i] )); then
                clean_value "${fields[j]:-}"
                ((j += 1))
            fi
            values+=("$CLEAN")
        done
        row="$NOW,OK,$(IFS=,; printf '%s' "${values[*]}"),"
        printf '%s\n' "$row" >> "$TELEMETRY_CSV"
        SAMPLE_FAILS=0
        if (( GPU_LOST )); then
            GPU_LOST=0
            log_event gpu 'GPU is answering again'
            set_alert warn "GPU answered again at ${NOW:11:8} after a failure - bundle ${BUNDLE_DIR#"$LOG_DIR/"}"
        fi
        return 0
    fi

    detail="${output//[$'\r\n']/ }"
    detail="${detail//\"/\'}"
    ((SAMPLE_FAILS += 1))
    if (( SAMPLE_FAILS >= 2 && ! GPU_LOST )); then
        GPU_LOST=1
        log_event gpu "GPU stopped answering: $detail"
        trigger_bundle nvidia-smi "$detail"
    fi
    if (( SAMPLE_FAILS == 1 || EPOCH - LAST_LOST_ROW >= LOST_ROW_INTERVAL )); then
        printf '%s,LOST%s"%s"\n' "$NOW" ',,,,,,,,,,,,,,,,' "$detail" >> "$TELEMETRY_CSV"
        LAST_LOST_ROW="$EPOCH"
    fi
}

periodic_tasks() {
    epoch_now
    if (( EPOCH >= NEXT_MINUTE )); then
        NEXT_MINUTE=$((EPOCH + 60))
        rotate_if_needed "$TELEMETRY_CSV" "$TELEMETRY_MAX_BYTES" "$TELEMETRY_ROTATIONS" "$TELEMETRY_HEADER"
        rotate_if_needed "$EVENTS_LOG" "$EVENTS_MAX_BYTES" "$EVENTS_ROTATIONS"
        check_pstore
    fi
    if (( ! GPU_LOST && EPOCH >= NEXT_HEALTH )); then
        NEXT_HEALTH=$((EPOCH + HEALTH_INTERVAL))
        take_health_snapshot hourly
    fi
    if (( FOLLOWUP_AT && EPOCH >= FOLLOWUP_AT )); then
        FOLLOWUP_AT=0
        capture_bundle_kernel "$BUNDLE_DIR" "$((BUNDLE_EPOCH - BUNDLE_KERNEL_LOOKBACK))"
        write_pci_state "$BUNDLE_DIR/pci-after.txt"
    fi
    if [[ -z "$KWATCH_FD" ]] && (( KWATCH_RETRY_AT && EPOCH >= KWATCH_RETRY_AT )); then
        KWATCH_RETRY_AT=0
        start_kernel_watcher
    fi
}

# ---------------------------------------------------------------- dashboard

COL_WIDTHS=(8 5 7 4 4 11 4 10 6)
COL_HEADERS=(TIME STATE PWR/LIM GPU% TEMP 'VRAM MiB' FAN% GFX/MEM PCIe LIMITS)
LAST_COL=$((FRAME_WIDTH - 2 - ${#COL_WIDTHS[@]}))
for width in "${COL_WIDTHS[@]}"; do ((LAST_COL -= width)); done
COL_WIDTHS+=("$LAST_COL")
PAD='  '
FRAME=''

or_dash() { printf -v "$1" '%s' "${2:--}"; }

decode_reasons() { # hex bitmask -> REASONS
    local value
    local -a names=()
    REASONS=-
    [[ "$1" =~ ^0x[[:xdigit:]]+$ ]] || return 0
    value=$((16#${1#0x}))
    (( value & 0x1 )) && names+=(idle)
    (( value & 0x2 )) && names+=(app-clocks)
    (( value & 0x4 )) && names+=(sw-power)
    (( value & 0x8 )) && names+=(hw-slowdown)
    (( value & 0x20 )) && names+=(sw-thermal)
    (( value & 0x40 )) && names+=(hw-thermal)
    (( value & 0x80 )) && names+=(power-brake)
    REASONS="${names[*]:-none}"
}

frame_add() { FRAME+="$PAD$1$RESET"$'\e[K\n'; }

frame_text() { # text color
    local line
    printf -v line '%s│%s %-*.*s %s│' "$PURPLE" "$2" $((FRAME_WIDTH - 4)) $((FRAME_WIDTH - 4)) "$1" "$PURPLE"
    frame_add "$line"
}

frame_rule() { # left middle right [joint]
    local rule='' width piece
    for width in "${COL_WIDTHS[@]}"; do
        printf -v piece '%*s' "$width" ''
        [[ -z "$rule" ]] || rule+="${4:-─}"
        rule+="${piece// /─}"
    done
    frame_add "$PURPLE$1$rule$3"
}

frame_cells() { # color cells...
    local color="$1" line i
    local -a cells=("${@:2}")
    line="$PURPLE│$color"
    for i in "${!COL_WIDTHS[@]}"; do
        printf -v line '%s%-*.*s%s│%s' "$line" "${COL_WIDTHS[i]}" "${COL_WIDTHS[i]}" "${cells[i]:-}" "$PURPLE" "$color"
    done
    frame_add "$line"
}

render() {
    (( DISPLAY_MODE )) || return 0
    local inner=$((FRAME_WIDTH - 2)) rule title health_color='' health_text alert_level=ok alert_text=''
    local row ts status pstate pw pl gu _mu t _mt gfx mem gen width vu vt fan reasons detail
    local _hts hboot _hreason hname hdriver hvbios hecc _hpersist hrc hru hrp hrf
    local c_pwr c_gpu c_temp c_vram c_fan c_clk c_pcie i
    local -a rows=() bundles=("$CRASH_DIR"/*/)

    mapfile -t rows < <(tail -n "$HISTORY_LIMIT" -- "$TELEMETRY_CSV" 2>/dev/null | grep -v '^timestamp,')
    IFS=, read -r _hts hboot _hreason hname hdriver hvbios hecc _hpersist hrc hru hrp hrf _ \
        < <(tail -n 1 -- "$HEALTH_CSV" 2>/dev/null | grep -v '^timestamp,')
    [[ -r "$ALERT_FILE" ]] && IFS='|' read -r alert_level alert_text < "$ALERT_FILE"

    FRAME=$'\e[H'
    printf -v rule '%*s' "$inner" ''
    rule="${rule// /─}"
    title='GPU CRASH TELEMETRY'
    (( LOGGER_OWNER )) || title='GPU CRASH TELEMETRY - READ ONLY'
    frame_add "$PURPLE╭$rule╮"
    printf -v row '%*s%s' $(((inner - 2 - ${#title}) / 2)) '' "$title"
    frame_text "$row" "$PINK"
    frame_add "$PURPLE├$rule┤"
    frame_text "GPU: ${hname:-waiting for first health snapshot}  driver ${hdriver:-?}  vbios ${hvbios:-?}  boot ${hboot:0:8}" "$CYAN"

    if [[ "$hru" =~ ^[0-9]+$ ]]; then
        health_text="VRAM remapped rows: $hru uncorrectable, $hrc correctable, pending $hrp, failed $hrf, ECC $hecc"
        health_color="$GREEN"
        (( hru > 0 || hrc > 0 )) && health_color="$YELLOW"
        [[ "$hrp" == Yes || "$hrf" == Yes ]] && health_color="$RED"
    else
        health_text='VRAM remapped rows: not read yet'
        health_color="$COMMENT"
    fi
    frame_text "$health_text" "$health_color"
    case "$alert_level" in
        bad) frame_text "$alert_text" "$RED" ;;
        warn) frame_text "$alert_text" "$YELLOW" ;;
        *) frame_text "${alert_text:-No GPU failures seen by this logger}" "$COMMENT" ;;
    esac

    frame_rule '├' '' '┤' '┬'
    frame_cells "$PINK" "${COL_HEADERS[@]}"
    frame_rule '├' '' '┤' '┼'
    for ((i = 0; i < HISTORY_LIMIT; i++)); do
        row="${rows[i]:-}"
        if [[ -z "$row" ]]; then
            frame_cells "$FOREGROUND"
            continue
        fi
        IFS=, read -r ts status pstate pw pl gu _mu t _mt gfx mem gen width vu vt fan reasons detail <<< "$row"
        if [[ "$status" == LOST ]]; then
            detail="${detail#\"}"
            frame_cells "$RED" "${ts:11:8}" LOST - - - - - - - "${detail%\"}"
            continue
        fi
        or_dash c_pwr "${pw:+${pw%%.*}/${pl%%.*}}"
        or_dash c_gpu "${gu:+$gu%}"
        or_dash c_temp "${t:+${t}C}"
        or_dash c_vram "${vu:+$vu/$vt}"
        or_dash c_fan "${fan:+$fan%}"
        or_dash c_clk "${gfx:+$gfx/$mem}"
        or_dash c_pcie "${gen:+G${gen}x$width}"
        decode_reasons "$reasons"
        frame_cells "$FOREGROUND" "${ts:11:8}" "${pstate:--}" "$c_pwr" "$c_gpu" "$c_temp" \
            "$c_vram" "$c_fan" "$c_clk" "$c_pcie" "$REASONS"
    done
    frame_rule '├' '' '┤' '┴'

    if (( ${#bundles[@]} )); then
        row="${bundles[-1]%/}"
        row="Crash bundles: ${#bundles[@]} (latest ${row##*/})"
    else
        row='Crash bundles: none yet'
    fi
    frame_text "$row   Logs: ${LOG_DIR/#"$HOME"/\~}" "$FOREGROUND"
    frame_add "$PURPLE╰$rule╯"
    if (( LOGGER_OWNER )); then
        frame_add "$COMMENT  Sampling every ${SAMPLE_INTERVAL}s. Ctrl+C to stop logging."
    else
        frame_add "$COMMENT  Showing the running logger's data. Ctrl+C to close."
    fi
    printf '%s\e[J' "$FRAME"
}

# ---------------------------------------------------------------- main

cleanup() {
    stop_kernel_watcher
    (( LOGGER_OWNER )) && log_event logger 'stopped'
    (( DISPLAY_MODE )) && printf '\e[?25h\e[?1049l'
}

if (( ! LOGGER_OWNER )); then
    if (( ! DISPLAY_MODE )); then
        printf 'A telemetry logger is already running; nothing to do.\n'
        exit 0
    fi
    trap 'printf "\e[?25h\e[?1049l"' EXIT
    trap 'exit 130' INT TERM
    printf '\e[?1049h\e[?25l\e[2J'
    while :; do
        render
        sleep "$SAMPLE_INTERVAL"
    done
fi

command -v nvidia-smi >/dev/null 2>&1 || { printf 'Error: nvidia-smi was not found.\n' >&2; exit 1; }
[[ -s "$TELEMETRY_CSV" ]] || printf '%s\n' "$TELEMETRY_HEADER" > "$TELEMETRY_CSV"
trap cleanup EXIT
trap 'exit 130' INT TERM
(( DISPLAY_MODE )) && printf '\e[?1049h\e[?25l\e[2J'

find_gpu
detect_query_fields
log_event logger "started pid=$$ $(system_identity) gpu=${GPU_SYSFS##*/}"
set_alert ok ''
take_health_snapshot startup
check_pstore
check_previous_boot
start_kernel_watcher
render

epoch_now
NEXT_MINUTE=$((EPOCH + 60))
NEXT_HEALTH=$((EPOCH + HEALTH_INTERVAL))
deadline=${EPOCHREALTIME/./}
while :; do
    take_sample
    periodic_tasks
    render
    deadline=$((deadline + SAMPLE_INTERVAL * 1000000))
    # After a long stall (suspend, a hung nvidia-smi), restart the schedule instead of catching up.
    (( deadline > ${EPOCHREALTIME/./} )) || deadline=$(( ${EPOCHREALTIME/./} + SAMPLE_INTERVAL * 1000000 ))
    wait_for_kernel_lines "$deadline"
done
