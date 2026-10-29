#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVICES=(system-telemetry.service crash-reboot.service)
CURRENT_USER="$(id -un)"
CURRENT_HOME="${HOME:?HOME is not set}"

escape_sed_replacement() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//&/\\&}"
    value="${value//|/\\|}"
    printf '%s' "$value"
}

for file in system-telemetry.sh crash-reboot.py "${SERVICES[@]/%/.in}"; do
    if [[ ! -r "$SCRIPT_DIR/$file" ]]; then
        printf 'Error: %s is missing from %s\n' "$file" "$SCRIPT_DIR" >&2
        exit 1
    fi
done
if ! python3 -c 'import evdev' 2>/dev/null; then
    printf 'Error: crash-reboot.py needs python-evdev (sudo pacman -S python-evdev)\n' >&2
    exit 1
fi

temporary_service="$(mktemp)"
trap 'rm -f -- "$temporary_service"' EXIT

for service in "${SERVICES[@]}"; do
    sed \
        -e "s|@USER@|$(escape_sed_replacement "$CURRENT_USER")|g" \
        -e "s|@HOME@|$(escape_sed_replacement "$CURRENT_HOME")|g" \
        -e "s|@INSTALL_DIR@|$(escape_sed_replacement "$SCRIPT_DIR")|g" \
        "$SCRIPT_DIR/$service.in" > "$temporary_service"
    sudo install -Dm644 -- "$temporary_service" "/etc/systemd/system/$service"
done

sudo systemctl daemon-reload
for service in "${SERVICES[@]}"; do
    sudo systemctl enable "$service"
    sudo systemctl restart "$service"
    printf 'Installed and started %s from %s\n' "$service" "$SCRIPT_DIR"
done
