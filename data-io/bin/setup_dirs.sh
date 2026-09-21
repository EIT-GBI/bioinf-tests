#!/usr/bin/env bash
# Create the data-io test tree on a tier.
#
#   ./bin/setup_dirs.sh hot
#
# Directories only. Staging the reads into input/ is manual: how they get there
# is part of what is being investigated.
set -euo pipefail
cd "$(dirname "$0")/.."
source paths.env

root=$(root_for "${1:?usage: $0 <hot|cold>}")

for platform in illumina pacbio ont; do
    mkdir -p "$root/$TEST_DIR/input/$platform"
done
mkdir -p "$root/$TEST_DIR/output" "$root/$TEST_DIR/work"

echo "created $root/$TEST_DIR/{input/{illumina,pacbio,ont},output,work}"
