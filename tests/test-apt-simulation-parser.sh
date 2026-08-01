#!/bin/bash

set -euo pipefail

REPOSITORY_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$REPOSITORY_ROOT/vps.sh"

actual=$(
    printf '%s\n' \
        'Remv unused-package [1.0]' \
        'Purg old-kernel [6.12]' \
        'Inst unrelated-package (2.0 stable [amd64])' |
        parse_apt_simulated_removals
)
expected=$'unused-package\nold-kernel'

if [[ "$actual" != "$expected" ]]; then
    printf 'unexpected parser output:\n%s\n' "$actual" >&2
    exit 1
fi

echo "APT simulation parser test passed."
