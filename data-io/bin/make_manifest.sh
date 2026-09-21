#!/usr/bin/env bash
# Checksum every test input on a tier.
#
#   ./bin/make_manifest.sh hot
#   ./bin/make_manifest.sh cold manifests/cold.run2.csv
#
# Writes rel,size,md5 - `rel` relative to the tier root, so the two tiers'
# manifests join and diff directly.
#
# Run it TWICE on cold and compare the two: the bytes on disk cannot change
# between runs, so a different md5 is read-path corruption. That is the
# cheapest possible test for the bug this repo exists to chase.
set -euo pipefail
cd "$(dirname "$0")/.."
source paths.env

tier="${1:?usage: $0 <hot|cold> [out.csv]}"
root=$(root_for "$tier")
out="${2:-manifests/$tier.csv}"

mkdir -p "$(dirname "$out")"
cd "$root"

# Everything under input/, plus each reference and its sibling index files.
list_files() {
    find "$TEST_DIR/input" -type f
    for ref in $REFERENCES; do
        ls "references/$ref" "references/$ref".* 2>/dev/null || true
    done
}

{
    echo "rel,size,md5"
    list_files | sort | while read -r f; do
        echo "$f,$(stat -Lc %s "$f"),$(md5sum "$f" | cut -d' ' -f1)"
    done
} > "$OLDPWD/$out"

echo "wrote $out ($(($(wc -l < "$OLDPWD/$out") - 1)) files)"
