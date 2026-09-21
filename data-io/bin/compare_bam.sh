#!/usr/bin/env bash
# Did the two tiers produce the same alignments?
#
#   ./bin/compare_bam.sh illumina cpu 1
#   ./bin/compare_bam.sh ont gpu 1
#
# Compares the BAM *body* (`samtools view | md5sum`), not the file. A whole-file
# md5 always differs between tiers because the @PG header records the command
# line, which contains the tier-specific input paths - expected, and says
# nothing about integrity. The body is the part that has to match.
#
# Identical bodies is a stronger statement than verify.nf gives: it covers the
# whole pipeline's read pattern, not one sequential pass.
set -euo pipefail
cd "$(dirname "$0")/.."
source paths.env

workload="${1:?usage: $0 <illumina|pacbio|ont> <cpu|gpu> [rep]}"
device="${2:?usage: $0 <illumina|pacbio|ont> <cpu|gpu> [rep]}"
rep="${3:-1}"

# DORADO_ALIGNER publishes to aligned/; the others to alignment/
case "$workload" in
    ont) subdir=aligned ;;
    *)   subdir=alignment ;;
esac

hot="$HOT_ROOT/$TEST_DIR/output/$workload/$device/rep$rep"
cold="$COLD_ROOT/$TEST_DIR/output/$workload/$device/rep$rep"

echo "hot : $hot/$subdir"
echo "cold: $cold/$subdir"
echo

command -v samtools >/dev/null || {
    echo "samtools not on PATH. Try:" >&2
    echo "  apptainer exec docker://ghcr.io/eit-gbi/nf-mod-samtools:v1.0.0 $0 $*" >&2
    exit 2
}

problems=0
for hot_bam in "$hot/$subdir"/*.bam; do
    name=$(basename "$hot_bam")
    cold_bam="$cold/$subdir/$name"

    if [ ! -f "$cold_bam" ]; then
        echo "MISSING  $name has no cold counterpart"
        problems=$((problems + 1))
        continue
    fi

    hot_md5=$(samtools view "$hot_bam" | md5sum | cut -d' ' -f1)
    cold_md5=$(samtools view "$cold_bam" | md5sum | cut -d' ' -f1)

    if [ "$hot_md5" = "$cold_md5" ]; then
        echo "OK       $name  $hot_md5"
    else
        echo "DIFFER   $name"
        echo "         hot  $hot_md5"
        echo "         cold $cold_md5"
        # How they differ: fewer reads means truncated input, same count with
        # different mappings means corrupted bases.
        echo "         hot  reads: $(samtools view -c "$hot_bam")"
        echo "         cold reads: $(samtools view -c "$cold_bam")"
        problems=$((problems + 1))
    fi
done

echo
if [ "$problems" -eq 0 ]; then
    echo "PASS: the two tiers produced identical alignments."
else
    echo "FAIL: $problems problem(s)."
    exit 1
fi
