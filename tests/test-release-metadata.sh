#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)

fail_test() {
    echo "Release metadata test failed: $1" >&2
    exit 1
}

version=$(sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$REPO_DIR/vps.sh")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    fail_test "vps.sh VERSION is missing or is not semantic versioning"
[[ "$(grep -c '^VERSION=' "$REPO_DIR/vps.sh")" == "1" ]] || \
    fail_test "vps.sh must define VERSION exactly once"
grep -Fq "当前版本为 **$version**" "$REPO_DIR/README.md" || \
    fail_test "README current version does not match vps.sh $version"
[[ -s "$REPO_DIR/.github/releases/$version.md" ]] || \
    fail_test "release notes are missing for $version"
if grep -Eqi '^#{1,6}[[:space:]]*(更新日志|changelog|release notes)[[:space:]]*$' \
    "$REPO_DIR/README.md"; then
    fail_test "README must not contain a release-history section"
fi

echo "Release metadata tests passed."
