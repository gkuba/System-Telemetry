#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_TEMPLATE="$SCRIPT_DIR/system-telemetry.service.in"
SERVICE_NAME='system-telemetry.service'
SERVICE_DESTINATION="/etc/systemd/system/$SERVICE_NAME"
CURRENT_USER="$(id -un)"
CURRENT_HOME="${HOME:?HOME is not set}"

escape_sed_replacement() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//&/\\&}"
    value="${value//|/\\|}"
    printf '%s' "$value"
}

if [[ ! -r "$SERVICE_TEMPLATE" || ! -x "$SCRIPT_DIR/system-telemetry.sh" ]]; then
    printf 'Error: service template or telemetry script is missing from %s\n' "$SCRIPT_DIR" >&2
    exit 1
fi

temporary_service="$(mktemp)"
trap 'rm -f -- "$temporary_service"' EXIT

sed \
    -e "s|@USER@|$(escape_sed_replacement "$CURRENT_USER")|g" \
    -e "s|@HOME@|$(escape_sed_replacement "$CURRENT_HOME")|g" \
    -e "s|@INSTALL_DIR@|$(escape_sed_replacement "$SCRIPT_DIR")|g" \
    "$SERVICE_TEMPLATE" > "$temporary_service"

sudo install -Dm644 -- "$temporary_service" "$SERVICE_DESTINATION"
sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
if sudo systemctl is-active --quiet "$SERVICE_NAME"; then
    sudo systemctl restart "$SERVICE_NAME"
else
    sudo systemctl start "$SERVICE_NAME"
fi

printf 'Installed and started %s for user %s from %s\n' \
    "$SERVICE_NAME" "$CURRENT_USER" "$SCRIPT_DIR"
