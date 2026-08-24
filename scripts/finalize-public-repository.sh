#!/bin/bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER_TOKEN='__GITHUB_''OWNER__'
OWNER_LOWER_TOKEN='__GITHUB_''OWNER_LOWER__'

fail() {
    echo "Error: $1" >&2
    exit 1
}

validate_identity() {
    local owner="$1"
    local email="$2"
    local owner_lower
    local email_lower
    local suffix="@users.noreply.github.com"
    local email_local
    local email_owner
    local numeric_id

    [[ "${owner}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]] \
        || fail "GitHub owner login is invalid."
    owner_lower="$(printf '%s' "${owner}" | tr '[:upper:]' '[:lower:]')"
    email_lower="$(printf '%s' "${email}" | tr '[:upper:]' '[:lower:]')"
    [[ "${email_lower}" == *"${suffix}" ]] \
        || fail "Email must be the complete GitHub users.noreply.github.com address."

    email_local="${email_lower%${suffix}}"
    if [[ "${email_local}" == *+* ]]; then
        numeric_id="${email_local%%+*}"
        email_owner="${email_local#*+}"
        [[ "${numeric_id}" =~ ^[0-9]+$ ]] \
            || fail "The noreply email numeric prefix is invalid."
    else
        email_owner="${email_local}"
    fi
    [[ "${email_owner}" == "${owner_lower}" ]] \
        || fail "The noreply email does not belong to the supplied GitHub owner."

    printf '%s\n' "${owner_lower}"
}

if [[ "${1:-}" == "--validate-identity" ]]; then
    [[ "$#" -eq 3 ]] || fail "Usage: $0 --validate-identity OWNER NOREPLY_EMAIL"
    validate_identity "$2" "$3" >/dev/null
    echo "Identity is valid."
    exit 0
fi

cd "${PROJECT_DIR}"
[[ -d .git ]] || fail "Run this script from the public release Git repository."
[[ -x scripts/check-public-repo.sh ]] || fail "Public repository checks are missing or not executable."
[[ -z "$(git remote)" ]] || fail "Remove remotes before creating the clean public root commit."
if git show-ref --verify --quiet refs/heads/main; then
    fail "A main branch already exists; refusing to replace it."
fi

read -r -p "GitHub owner login: " GITHUB_OWNER
read -r -p "Exact GitHub noreply email: " GITHUB_NOREPLY
GITHUB_OWNER_LOWER="$(validate_identity "${GITHUB_OWNER}" "${GITHUB_NOREPLY}")"

# Run the complete release gates before mutating identifiers or Git history.
bash scripts/check-public-repo.sh
PUBLIC_SWIFT_CACHE="${TMPDIR:-/tmp}/afu-public-finalize-swift-cache"
SWIFTPM_MODULECACHE_OVERRIDE="${PUBLIC_SWIFT_CACHE}/swift" \
CLANG_MODULE_CACHE_PATH="${PUBLIC_SWIFT_CACHE}/clang" \
swift test --disable-sandbox
SWIFTPM_MODULECACHE_OVERRIDE="${PUBLIC_SWIFT_CACHE}/swift" \
CLANG_MODULE_CACHE_PATH="${PUBLIC_SWIFT_CACHE}/clang" \
swift build --disable-sandbox -c release

IDENTITY_FILES=(
    Resources/Info.plist
    Resources/LaunchAgent.plist.template
    scripts/install.sh
    scripts/uninstall.sh
    README.md
    PRIVACY.md
    SECURITY.md
)
for file in "${IDENTITY_FILES[@]}"; do
    [[ -f "${file}" ]] || continue
    /usr/bin/sed -i '' \
        -e "s/${OWNER_LOWER_TOKEN}/${GITHUB_OWNER_LOWER}/g" \
        -e "s/${OWNER_TOKEN}/${GITHUB_OWNER}/g" \
        "${file}"
done

bash scripts/check-public-repo.sh
USER_PATH_PATTERN='/''Users/[^/]+/'
if rg -n "${OWNER_TOKEN}|${OWNER_LOWER_TOKEN}|com[.]local|${USER_PATH_PATTERN}" . \
    -g '!.git/**' -g '!.build/**'; then
    fail "An identity placeholder, legacy identifier, or personal path remains."
fi

git add -A
PUBLIC_TREE="$(git write-tree)"
PUBLIC_COMMIT="$(git -c user.name="${GITHUB_OWNER}" -c user.email="${GITHUB_NOREPLY}" \
    commit-tree "${PUBLIC_TREE}" -m "Initial public release")"
git update-ref refs/heads/main "${PUBLIC_COMMIT}"
git symbolic-ref HEAD refs/heads/main

while IFS= read -r ref; do
    [[ "${ref}" == "refs/heads/main" ]] || git update-ref -d "${ref}"
done < <(git for-each-ref --format='%(refname)')
git reflog expire --expire=now --all
git gc --prune=now --quiet

[[ "$(git branch --show-current)" == "main" ]] || fail "Final branch is not main."
[[ "$(git rev-list --count main)" == "1" ]] || fail "main does not contain exactly one commit."
[[ "$(git rev-list --max-parents=0 --count main)" == "1" ]] || fail "main does not have exactly one root commit."
[[ "$(git log --all --format='%ae%n%ce' | sort -u)" == "${GITHUB_NOREPLY}" ]] \
    || fail "Commit author or committer email does not match the validated noreply address."
[[ "$(git for-each-ref --format='%(refname)')" == "refs/heads/main" ]] \
    || fail "Unexpected Git references remain."

echo "Clean public main created for ${GITHUB_OWNER}."
echo "Next: create a private GitHub repository named afu-scale-reader-macos and push only main."
