#!/usr/bin/env bash
# Every run under results/ -> one tidy CSV, plus a summary.
#
#   ./bin/collect_traces.sh
#
# Joins each run's run.meta (what the run was) to its trace.txt (what each task
# did), so one row = one task with its tier, device and rep attached.
#
# The trace is written with `raw = true` (see nextflow.config), so durations are
# plain milliseconds and sizes plain bytes. That is the only reason this script
# is short: otherwise it would have to parse "2m 30s" and "1.2 GB" back.
#
# Failed runs are kept and flagged run_ok=no rather than dropped: a run that
# failed on cold and succeeded on hot is a result, not missing data.
set -euo pipefail
cd "$(dirname "$0")/.."

out=results/all_tasks.csv
echo "run_id,workload,tier,device,rep,run_ok,process,sample,status,realtime_s,cpu_pct,read_mb,write_mb,read_mb_per_s" > "$out"

for meta in results/*/run.meta; do
    dir=$(dirname "$meta")
    [ -f "$dir/trace.txt" ] || { echo "skip $(basename "$dir"): no trace.txt" >&2; continue; }

    # run.meta is plain key=value, so it can just be sourced
    # shellcheck disable=SC1090
    source "$meta"
    run_ok=$([ "$exit_code" = 0 ] && echo yes || echo no)

    tail -n +2 "$dir/trace.txt" | awk -F'\t' -v OFS=, \
        -v run="$run_id" -v wl="$workload" -v tier="$tier" \
        -v dev="$device" -v rep="$rep" -v ok="$run_ok" '
        {
            realtime = $6 / 1000            # ms -> s
            read_mb  = $14 / 1048576        # bytes -> MB
            write_mb = $15 / 1048576
            rate     = realtime > 0 ? read_mb / realtime : 0
            printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%.1f,%s,%.1f,%.1f,%.1f\n",
                   run, wl, tier, dev, rep, ok, $2, $3, $4,
                   realtime, $8, read_mb, write_mb, rate
        }' >> "$out"
done

echo "wrote $out ($(($(wc -l < "$out") - 1)) task rows)"
echo

# Mean realtime per process, hot vs cold. Reps are few, so a mean is honest
# enough here; use the CSV above for anything more careful.
echo "mean realtime per process, successful runs only"
echo
awk -F, 'NR > 1 && $6 == "yes" {
    key = $2 "," $7 "," $4                  # workload, process, device
    n[key "," $3]++; sum[key "," $3] += $10
    keys[key] = 1
}
END {
    printf "%-10s %-22s %-5s %9s %9s %7s\n", "workload", "process", "dev", "hot_s", "cold_s", "ratio"
    for (k in keys) {
        split(k, f, ",")
        hot  = n[k ",hot"]  ? sum[k ",hot"]  / n[k ",hot"]  : 0
        cold = n[k ",cold"] ? sum[k ",cold"] / n[k ",cold"] : 0
        printf "%-10s %-22s %-5s %9s %9s %7s\n", f[1], f[2], f[3],
               hot  > 0 ? sprintf("%.1f", hot)  : "-",
               cold > 0 ? sprintf("%.1f", cold) : "-",
               (hot > 0 && cold > 0) ? sprintf("%.2fx", cold / hot) : "-"
    }
}' "$out"

echo
echo "ratio > 1 means cold is slower. Reps are pooled; filter rep==1 in the CSV"
echo "for the first-touch comparison (see README)."
