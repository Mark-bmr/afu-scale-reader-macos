#!/bin/bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${HOME}/Applications/AFU Scale Reader.app"
APP_CONTENTS="${APP_DIR}/Contents"
APP_EXECUTABLE="${APP_CONTENTS}/MacOS/AFUReader"
CONFIG_DIR="${HOME}/Library/Application Support/AFUScaleReader"
CONFIG_FILE="${CONFIG_DIR}/config.json"
LAUNCH_LABEL="io.github.mark-bmr.afuscalereader"
LAUNCH_AGENT="${HOME}/Library/LaunchAgents/${LAUNCH_LABEL}.plist"
LAUNCH_DOMAIN="gui/$(id -u)"
BUILD_CACHE_ROOT="${TMPDIR:-/tmp}/afu-scale-reader-build-cache"

cd "${PROJECT_DIR}"
SWIFTPM_MODULECACHE_OVERRIDE="${BUILD_CACHE_ROOT}/swift" \
CLANG_MODULE_CACHE_PATH="${BUILD_CACHE_ROOT}/clang" \
swift build --disable-sandbox -c release

BIN_DIR="$(SWIFTPM_MODULECACHE_OVERRIDE="${BUILD_CACHE_ROOT}/swift" \
    CLANG_MODULE_CACHE_PATH="${BUILD_CACHE_ROOT}/clang" \
    swift build --disable-sandbox -c release --show-bin-path)"
BUILT_EXECUTABLE="${BIN_DIR}/AFUReader"

# Configuration and ownership validation happen before the installed app or
# LaunchAgent is replaced.
mkdir -p "${CONFIG_DIR}"
chmod 700 "${CONFIG_DIR}"
if [[ ! -f "${CONFIG_FILE}" ]]; then
    "${BUILT_EXECUTABLE}" --configure --config "${CONFIG_FILE}"
fi
"${BUILT_EXECUTABLE}" --validate-config --config "${CONFIG_FILE}"

INSTALL_STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/afu-scale-reader-install.XXXXXX")"
cleanup_staging() {
    rm -rf "${INSTALL_STAGING_DIR}"
}
trap cleanup_staging EXIT

STAGED_APP="${INSTALL_STAGING_DIR}/AFU Scale Reader.app"
STAGED_CONTENTS="${STAGED_APP}/Contents"
STAGED_AGENT="${INSTALL_STAGING_DIR}/${LAUNCH_LABEL}.plist"
mkdir -p "${STAGED_CONTENTS}/MacOS"
cp "${BUILT_EXECUTABLE}" "${STAGED_CONTENTS}/MacOS/AFUReader"
cp "${PROJECT_DIR}/Resources/Info.plist" "${STAGED_CONTENTS}/Info.plist"
chmod 755 "${STAGED_CONTENTS}/MacOS/AFUReader"
/usr/bin/codesign --force --deep --sign - "${STAGED_APP}"

escape_sed_replacement() {
    /usr/bin/sed 's/[&|\\]/\\&/g' <<< "$1"
}
ESCAPED_EXECUTABLE="$(escape_sed_replacement "${APP_EXECUTABLE}")"
ESCAPED_CONFIG="$(escape_sed_replacement "${CONFIG_FILE}")"
/usr/bin/sed \
    -e "s|__APP_EXECUTABLE__|${ESCAPED_EXECUTABLE}|g" \
    -e "s|__CONFIG_PATH__|${ESCAPED_CONFIG}|g" \
    "${PROJECT_DIR}/Resources/LaunchAgent.plist.template" > "${STAGED_AGENT}"
chmod 600 "${STAGED_AGENT}"
/usr/bin/plutil -lint "${STAGED_AGENT}" >/dev/null

mkdir -p "${HOME}/Applications" "${HOME}/Library/LaunchAgents"
/bin/launchctl bootout "${LAUNCH_DOMAIN}" "${LAUNCH_AGENT}" >/dev/null 2>&1 || true
rm -rf "${APP_DIR}"
mv "${STAGED_APP}" "${APP_DIR}"
mv "${STAGED_AGENT}" "${LAUNCH_AGENT}"

if ! /bin/launchctl bootstrap "${LAUNCH_DOMAIN}" "${LAUNCH_AGENT}"; then
    cat >&2 <<EOF
The application and LaunchAgent files were installed, but launchctl could not
register the background task. If this command was run from a sandboxed app,
open Terminal and run this installer there:

  cd '${PROJECT_DIR}' && ./scripts/install.sh
EOF
    exit 1
fi
/bin/launchctl enable "${LAUNCH_DOMAIN}/${LAUNCH_LABEL}"
/bin/launchctl kickstart -k "${LAUNCH_DOMAIN}/${LAUNCH_LABEL}"

echo "AFU Scale Reader installed."
echo "Application: ${APP_DIR}"
echo "Configuration: ${CONFIG_FILE}"
echo "Private mirror and logs: ${CONFIG_DIR}"
echo "Allow Bluetooth access when macOS asks, then step on the scale."
