#!/usr/bin/env python3
"""Hot vs cold, in one file.

Usage: summary.py <results_dir> <bams.csv>

Reads the trace each arm left in its results folder and answers: how much slower
was cold, and did the two tiers produce the same output.

Throughput uses `rchar` - bytes read by syscalls. `read_bytes` counts
block-device IO and reads 0 on Alluxio, which serves over the network, so it
cannot be compared across the two tiers.

CACHED tasks count. A `-resume` run reports an arm it did not re-execute as
CACHED, but Nextflow restores the original task's metrics onto those rows, so
realtime/rchar/%cpu are real measurements and an arm finished in an earlier run
still gets summarised. Their `start`/`complete` stamps are the *original* run's,
so wall clock is only reported for runs that were executed end to end.
"""

import csv
import collections
import glob
import os
import statistics
import sys

# Scaffolding, not workload
SKIP = ("SAMPLESHEET_", "READ_FILE", "COMPARE_BAM", "REPORT_", "BWA_INDEX", "SAMTOOLS_FAIDX")

FIELDS = ["tier", "arm", "process", "sample", "realtime_s", "cpu_pct",
          "read_mb", "write_mb", "read_mb_per_s"]


def num(v):
    # Trace fields read '-' when a metric was not collected
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


results = sys.argv[1]

tasks, runs = [], []
# Folder names are <tier>-<arm>, e.g. hot-illumina, cold-pacbio-gpu
for path in sorted(glob.glob(f"{results}/*/trace.txt")):
    run = os.path.basename(os.path.dirname(path))
    if "-" not in run:
        continue                       # verify/ and summary/ are not workload runs
    tier, arm = run.split("-", 1)
    if tier not in ("hot", "cold"):
        continue
    rows = [r for r in csv.DictReader(open(path), delimiter="\t")
            if r.get("status") in ("COMPLETED", "CACHED")]
    if rows:
        cached = sum(1 for r in rows if r.get("status") == "CACHED")
        # Sum of task time: valid for cached rows too, and it excludes the
        # scheduler queueing that wall clock silently includes.
        task_s = sum(num(r["realtime"]) for r in rows) / 1000
        # Wall clock spans whichever runs these rows came from, so it only
        # means anything when every task actually ran in one of them.
        span = ((max(int(r["complete"]) for r in rows) -
                 min(int(r["start"]) for r in rows)) / 1000
                if not cached else None)
        read = sum(num(r["rchar"]) for r in rows) / 2**30
        runs.append(dict(tier=tier, arm=arm, tasks=len(rows), cached=cached,
                         task_s=task_s, wall_s=span, read_gb=read))

        for r in rows:
            name = r["process"].split(":")[-1]
            if any(name.startswith(s) for s in SKIP):
                continue
            rt = num(r["realtime"]) / 1000
            rmb = num(r["rchar"]) / 2**20
            tasks.append(dict(
                tier=tier, arm=arm, process=name, sample=r["tag"],
                realtime_s=round(rt, 1), cpu_pct=num(r["%cpu"]),
                read_mb=round(rmb, 1), write_mb=round(num(r["wchar"]) / 2**20, 1),
                read_mb_per_s=round(rmb / rt, 2) if rt else None))

with open("tasks.csv", "w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=FIELDS)
    w.writeheader()
    w.writerows(tasks)

out = []
say = out.append
say("=" * 72)
say(" data-io summary - hot (Lustre) vs cold (Alluxio)")
say("=" * 72)

say("")
say("1. RUNS FOUND")
if not runs:
    say("   none. Run a workload arm on each tier first.")
else:
    say("   %-4s %-12s %6s %7s %10s %10s %11s"
        % ("tier", "arm", "tasks", "cached", "task_min", "wall_min", "GiB read"))
for r in sorted(runs, key=lambda x: (x["arm"], x["tier"])):
    say("   %-4s %-12s %6d %7d %10.1f %10s %11.1f"
        % (r["tier"], r["arm"], r["tasks"], r["cached"], r["task_s"] / 60,
           "%.1f" % (r["wall_s"] / 60) if r["wall_s"] is not None else "-",
           r["read_gb"]))
if any(r["cached"] for r in runs):
    say("")
    say("   cached > 0 means -resume reused an earlier run's tasks. Their timings")
    say("   are that run's real measurements, so they are summarised normally;")
    say("   wall_min reads '-' because the stamps belong to the earlier run.")

say("")
# Task time, not wall clock: wall clock includes however long SLURM sat on the
# job, which has nothing to do with the storage under test, and it is unavailable
# for arms that came back cached.
say("2. TIME PER ARM  (sum of task time - excludes queue wait)")
say("   %-14s %10s %10s %8s" % ("arm", "hot_min", "cold_min", "ratio"))
by_arm = collections.defaultdict(dict)
for r in runs:
    by_arm[r["arm"]][r["tier"]] = r["task_s"] / 60
for arm in sorted(by_arm):
    h, c = by_arm[arm].get("hot"), by_arm[arm].get("cold")
    say("   %-14s %10s %10s %8s" % (
        arm,
        "%.1f" % h if h is not None else "-",
        "%.1f" % c if c is not None else "-",
        "%.2fx" % (c / h) if h and c else "-"))
say("   Wall clock is in section 1; it also counts time queued for a node.")

say("")
say("3. PER-PROCESS  (median over samples; rate from rchar)")
say("   %-22s %9s %9s %7s %9s %9s"
    % ("process", "hot_s", "cold_s", "ratio", "hot_MB/s", "cold_MB/s"))
grp = collections.defaultdict(list)
for t in tasks:
    grp[(t["process"], t["tier"])].append(t)
for proc in sorted({p for p, _ in grp}):
    def med(tier, key):
        v = [x[key] for x in grp.get((proc, tier), [])
             if x["realtime_s"] > 0 and x[key] is not None]
        return statistics.median(v) if v else None
    h, c = med("hot", "realtime_s"), med("cold", "realtime_s")
    hr, cr = med("hot", "read_mb_per_s"), med("cold", "read_mb_per_s")
    say("   %-22s %9s %9s %7s %9s %9s" % (
        proc,
        "%.1f" % h if h is not None else "-",
        "%.1f" % c if c is not None else "-",
        "%.2fx" % (c / h) if h and c else "-",
        "%.2f" % hr if hr is not None else "-",
        "%.2f" % cr if cr is not None else "-"))
say("   ratio > 1 means cold is slower.")

say("")
say("4. OUTPUT INTEGRITY  (BAM body checksums, hot vs cold)")
bams = list(csv.DictReader(open(sys.argv[2]))) if len(sys.argv) > 2 else []
if not bams:
    say("   nothing to compare - run the same arm on both tiers first.")
else:
    same = [b for b in bams if b["identical"] == "yes"]
    diff = [b for b in bams if b["identical"] != "yes"]
    say("   %d compared, %d identical, %d differing" % (len(bams), len(same), len(diff)))
    for b in diff[:20]:
        say("   DIFFER %s  hot_reads=%s cold_reads=%s"
            % (b["bam"], b["hot_reads"], b["cold_reads"]))
    if not diff:
        say("   PASS - cold produced byte-identical alignments.")

say("")
say("=" * 72)
say(" tasks.csv holds one row per task for anything more detailed.")
say("=" * 72)

text = "\n".join(out)
print(text)
open("summary.txt", "w").write(text + "\n")
