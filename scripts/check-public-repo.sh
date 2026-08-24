#!/bin/bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_DIR}"

fail() {
    echo "Public repository check failed: $1" >&2
    exit 1
}

REQUIRED_FILES=(
    Package.swift
    README.md
    LICENSE
    NOTICE
    PRIVACY.md
    SECURITY.md
    config.example.json
    Resources/Info.plist
    Resources/LaunchAgent.plist.template
    .github/workflows/ci.yml
)
for file in "${REQUIRED_FILES[@]}"; do
    [[ -f "${file}" ]] || fail "missing ${file}"
done

REQUIRED_EXECUTABLES=(
    scripts/install.sh
    scripts/uninstall.sh
    scripts/check-public-repo.sh
    scripts/finalize-public-repository.sh
)
for file in "${REQUIRED_EXECUTABLES[@]}"; do
    [[ -x "${file}" ]] || fail "${file} is not executable"
done

rg -q '"synthetic_example"[[:space:]]*:[[:space:]]*true' config.example.json \
    || fail "config.example.json is not marked synthetic"

for term in macOS Swift Markdown JSON 隐私 删除 非医疗 非官方 兼容型号 AFU-WL-TZ-A1; do
    rg -q "${term}" README.md || fail "README is missing required topic: ${term}"
done

while IFS= read -r test_file; do
    rg -qi 'synthetic|合成' "${test_file}" \
        || fail "test fixture is not explicitly marked synthetic: ${test_file}"
done < <(rg --files Tests -g '*Tests.swift')

SCAN_GLOBS=(-g '!.git/**' -g '!.build/**' -g '!.swiftpm/**')
USER_PATH_PATTERN='/''Users/[A-Za-z0-9._-]+/'
REAL_SAMPLE_PATTERN='Mobile Documents/.*iCloud|User''Reference|captured''Weights'
if rg -n "${USER_PATH_PATTERN}|${REAL_SAMPLE_PATTERN}" \
    . "${SCAN_GLOBS[@]}" -g '!scripts/check-public-repo.sh'; then
    fail "personal path or real-sample terminology found"
fi

if rg -n 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}' \
    . "${SCAN_GLOBS[@]}" -g '!scripts/check-public-repo.sh'; then
    fail "credential-like material found"
fi

if rg -n '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}' \
    . "${SCAN_GLOBS[@]}" -g '!scripts/check-public-repo.sh'; then
    fail "an email address is embedded in public repository content"
fi

OWNER_LOWER_TOKEN='__GITHUB_''OWNER_LOWER__'
PLACEHOLDER_ID="io.github.${OWNER_LOWER_TOKEN}.afuscalereader"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)"
AGENT_ID="$(/usr/libexec/PlistBuddy -c 'Print :Label' Resources/LaunchAgent.plist.template)"
if [[ "${BUNDLE_ID}" != "${PLACEHOLDER_ID}" \
      && ! "${BUNDLE_ID}" =~ ^io[.]github[.][a-z0-9]([a-z0-9-]{0,37}[a-z0-9])?[.]afuscalereader$ ]]; then
    fail "bundle identifier is not a stable io.github.<owner>.afuscalereader value"
fi
[[ "${AGENT_ID}" == "${BUNDLE_ID}" ]] \
    || fail "App and LaunchAgent identifiers differ"
for file in scripts/install.sh scripts/uninstall.sh; do
    rg -q -F "LAUNCH_LABEL=\"${BUNDLE_ID}\"" "${file}" \
        || fail "${file} does not use the shared application identifier"
done

if rg -n 'com[.]local|StandardOutPath|StandardErrorPath' Resources scripts \
    -g '!scripts/check-public-repo.sh' -g '!scripts/finalize-public-repository.sh'; then
    fail "legacy application identity or launchd health-log redirection found"
fi

if rg -n 'output=|uuidString|Measurement packet:|Saved stable measurement:|unsupported notification .*hex|print[(]' \
    Sources/AFUReader; then
    fail "runtime source contains a default sensitive logging pattern"
fi

if rg -n 'measurement[.](rawHex|deviceName)' Sources/AFUCore/MarkdownStore.swift Sources/AFUCore/JSONStore.swift; then
    fail "persistent stores access raw frames or device names"
fi

if rg -n 'URLSession|NWConnection|import Network' Sources; then
    fail "unexpected network client code found"
fi

for command in \
    'bash scripts/check-public-repo.sh' \
    'swift test --disable-sandbox' \
    'swift build --disable-sandbox -c release'; do
    rg -q -F "${command}" .github/workflows/ci.yml \
        || fail "GitHub Actions is missing: ${command}"
done

TRACKED_FILES="$(git ls-files)"
if printf '%s\n' "${TRACKED_FILES}" | rg -n '(^|/)(config[.]json|measurements[.](md|json)|[^/]+[.]log([.][0-9]+)?)$'; then
    fail "runtime configuration, measurement data, or logs are tracked"
fi
if rg --files | rg -q '(^|/)阿福体脂记录[.]md$'; then
    fail "a personal measurement export is present"
fi

for ignored in config.json measurements.md measurements.json '*.log'; do
    rg -q -F "${ignored}" .gitignore || fail ".gitignore is missing ${ignored}"
done

bash -n scripts/install.sh scripts/uninstall.sh scripts/check-public-repo.sh scripts/finalize-public-repository.sh
plutil -lint Resources/Info.plist Resources/LaunchAgent.plist.template >/dev/null

echo "Public repository checks passed."
