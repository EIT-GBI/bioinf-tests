#!/usr/bin/env bash
# Are two manifests holding the same bytes?
#
#   ./bin/compare_manifests.sh                                        # hot vs cold
#   ./bin/compare_manifests.sh manifests/cold.csv manifests/cold.run2.csv
#
# Both manifests are sorted CSVs keyed on the tier-relative path, so `diff` is
# the whole comparison - no parsing needed. Lines starting with `<` are in A
# only, `>` in B only; a changed size or md5 shows up as both.
#
# Nothing downstream is meaningful until this passes. A mismatch means the two
# tiers do not hold the same data, so a timing comparison between them is not a
# timing comparison.
set -euo pipefail
cd "$(dirname "$0")/.."

a="${1:-manifests/hot.csv}"
b="${2:-manifests/cold.csv}"

echo "A: $a"
echo "B: $b"
echo

if diff "$a" "$b"; then
    echo "PASS: identical."
else
    echo
    echo "FAIL: the two sides do not hold the same bytes. Stop here."
    exit 1
fi
