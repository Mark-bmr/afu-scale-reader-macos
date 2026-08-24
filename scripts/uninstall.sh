#!/bin/bash

set -euo pipefail

APP_DIR="${HOME}/Applications/AFU Scale Reader.app"
CONFIG_DIR="${HOME}/Library/Application Support/AFUScaleReader"
LAUNCH_LABEL="io.github.mark-bmr.afuscalereader"
LAUNCH_AGENT="${HOME}/Library/LaunchAgents/${LAUNCH_LABEL}.plist"
LAUNCH_DOMAIN="gui/$(id -u)"

/bin/launchctl bootout "${LAUNCH_DOMAIN}" "${LAUNCH_AGENT}" >/dev/null 2>&1 || true
rm -f "${LAUNCH_AGENT}"
rm -rf "${APP_DIR}"

echo "AFU Scale Reader application and login agent removed."
echo "Configuration, private mirror, logs, and your chosen output file were preserved."
echo "To delete private application data too, remove: ${CONFIG_DIR}"
