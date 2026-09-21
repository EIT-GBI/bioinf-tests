#!/usr/bin/env bash
# Run one cell of the benchmark matrix, named and instrumented.
#
#   ./bin/run.sh <verify|illumina|pacbio|ont> <hot|cold> [rep] [cpu|gpu]
#
#   ./bin/run.sh verify   cold
#   ./bin/run.sh illumina hot  1
#   ./bin/run.sh pacbio   cold 2 gpu
#
# Set DRY_RUN=1 to print the command without running it.
#
# Why a wrapper rather than a bare `nextflow run`:
#   * each run gets a unique id, so results/ is self-describing;
#   * trace/report/timeline land in that run's own directory;
#   * a fresh work dir per run, so no run reads a file another left warm in the
#     page cache;
#   * total wall clock is recorded - it includes Nextflow startup and staging,
#     which the trace does not;
#   * -resume is never passed: a cache hit would be recorded as a fast read.
set -euo pipefail
cd "$(dirname "$0")/.."
source paths.env

workload="${1:?usage: $0 <verify|illumina|pacbio|ont> <hot|cold> [rep] [cpu|gpu]}"
tier="${2:?usage: $0 <verify|illumina|pacbio|ont> <hot|cold> [rep] [cpu|gpu]}"
rep="${3:-1}"

# illumina is bwa/CPU by design, ont is dorado/GPU only, pacbio runs both
case "$workload" in
    verify) device="${4:-na}" ;;
    ont)    device="${4:-gpu}" ;;
    *)      device="${4:-cpu}" ;;
esac

root=$(root_for "$tier")

# verify has no device, so it is left out of both names rather than carried
# around as "na". Outputs are split per workload/device/rep so the CPU and GPU
# arms do not overwrite each other's BAMs.
if [ "$device" = na ]; then
    label="$workload-$tier-rep$rep"
    outdir="$root/$TEST_DIR/output/$workload/rep$rep"
else
    label="$workload-$tier-$device-rep$rep"
    outdir="$root/$TEST_DIR/output/$workload/$device/rep$rep"
fi

run_id="$label-$(date +%Y%m%d-%H%M%S)"
results="results/$run_id"
mkdir -p "$results"

cmd=(nextflow -log "$results/nextflow.log"
     run "$workload.nf"
     -profile "cluster,$tier"
     -params-file params.yaml
     -name "$run_id"
     -work-dir "$root/$TEST_DIR/work/$run_id"
     --outdir "$outdir"
     -with-trace    "$results/trace.txt"
     -with-report   "$results/report.html"
     -with-timeline "$results/timeline.html")

# pacbio.nf is the only entry that reads a device
if [ "$workload" = pacbio ]; then
    cmd+=(--pacbio.device "$device")
fi

echo "--- $run_id ---"
printf '%s ' "${cmd[@]}"; echo
if [ "${DRY_RUN:-0}" = 1 ]; then
    exit 0
fi

start=$(date +%s)
"${cmd[@]}" 2>&1 | tee "$results/console.log" && exit_code=0 || exit_code=$?
wall=$(($(date +%s) - start))

cat > "$results/run.meta" <<META
run_id=$run_id
workload=$workload
tier=$tier
device=$device
rep=$rep
wall_seconds=$wall
exit_code=$exit_code
git_sha=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
META

echo
echo "results: $results   wall: ${wall}s   exit: $exit_code"
if [ "$exit_code" -ne 0 ]; then
    echo "run FAILED - collect_traces.sh will flag it run_ok=no" >&2
fi
exit "$exit_code"
