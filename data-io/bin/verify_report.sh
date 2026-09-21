#!/usr/bin/env bash
# Read verify.nf's CSV and answer the integrity question.
#
#   ./bin/verify_report.sh <outdir>/verify/verify-cold.csv
#
# Checks, in order of how much they matter:
#   1. Cross-rep disagreement - one file read N times giving more than one md5.
#      The bytes on disk cannot have changed between reps, so the read path
#      returned something it made up. This is the finding that would explain
#      the corrupted files.
#   2. Failed reads and format checks (gzip -t, samtools quickcheck), which
#      tell a truncated read apart from a mangled one.
#   3. Throughput, the probe's secondary purpose.
#
# Comparing against the recorded checksums is bin/compare_manifests.sh's job,
# not this script's.
set -euo pipefail

csv="${1:?usage: $0 <verify-*.csv>}"
rows=$(tail -n +2 "$csv")
problems=0

echo "=== 1. cross-rep checksum disagreement ==="
# Unique (file, md5) pairs; a file listed twice had two different checksums.
mismatched=$(echo "$rows" | cut -d, -f4,8 | sort -u | cut -d, -f1 | uniq -d)
if [ -n "$mismatched" ]; then
    echo "$mismatched" | while read -r f; do
        echo "MISMATCH $f"
        echo "$rows" | grep -F "$f" | awk -F, '{print "    rep" $2 "  " $8}'
    done
    problems=$((problems + $(echo "$mismatched" | wc -l)))
else
    echo "none - every file checksummed identically across all reps."
fi

echo
echo "=== 2. failed reads and format checks ==="
failed=$(echo "$rows" | awk -F, '$8 == "READ_FAILED" || $10 == "no" {print $4 "  (" $9 ")"}')
if [ -n "$failed" ]; then
    echo "$failed"
    problems=$((problems + $(echo "$failed" | wc -l)))
else
    echo "none."
fi

echo
echo "=== 3. throughput ==="
# Rows with mb_per_s of 0 are files too small to time; they skew the average.
echo "$rows" | awk -F, '
    $7 > 0 { n++; sum += $7; if (min == "" || $7 < min) min = $7; if ($7 > max) max = $7 }
    END {
        if (n) printf "  %d timed reads: mean %.1f MB/s, range %.1f - %.1f\n", n, sum/n, min, max
        else   print "  no files large enough to time."
    }'

echo
if [ "$problems" -eq 0 ]; then
    echo "PASS: this tier returned consistent, intact bytes."
else
    echo "FAIL: $problems problem(s). Do not trust timings from this tier yet."
    exit 1
fi
