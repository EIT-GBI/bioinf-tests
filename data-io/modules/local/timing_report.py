#!/usr/bin/env python3
"""Hot vs cold timings, per process, across every run so far.

Usage: timing_report.py          (reads trace-*.txt in the working directory)

The arm, tier and rep come from each trace's filename, which is why no
bookkeeping file is needed to know what a trace was.
"""

import collections
import csv
import glob
import os
import re
import statistics

# Processes that are scaffolding rather than workload
SKIP = re.compile(r"PREPARE_SAMPLESHEET|VERIFY_|COMPARE_|TIMING_")

FIELDS = ["arm", "tier", "rep", "process", "sample", "realtime_s", "cpu_pct",
          "read_mb", "write_mb", "read_mb_per_s"]


def num(v):
    """Trace fields read '-' whenever a metric was not collected: short tasks,
    and anything not running on Linux with a container engine."""
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


traces = sorted(glob.glob("trace-*.txt"))
tasks = []
for path in traces:
    m = re.match(r"trace-([\w-]+?)-(hot|cold)-rep(\d+)-", os.path.basename(path))
    if not m:
        continue
    arm, tier, rep = m.group(1), m.group(2), m.group(3)
    for r in csv.DictReader(open(path), delimiter="\t"):
        name = r["process"].split(":")[-1]   # named workflows prefix the process
        if SKIP.search(name) or r.get("status") != "COMPLETED":
            continue
        realtime = num(r["realtime"]) / 1000.0        # raw trace: ms
        read_mb = num(r["read_bytes"]) / 1048576.0    # raw trace: bytes
        write_mb = num(r["write_bytes"]) / 1048576.0
        tasks.append(dict(
            arm=arm, tier=tier, rep=rep, process=name, sample=r["tag"],
            realtime_s=round(realtime, 1), cpu_pct=num(r["%cpu"]),
            read_mb=round(read_mb, 1), write_mb=round(write_mb, 1),
            read_mb_per_s=round(read_mb / realtime, 1) if realtime else 0))

with open("all_tasks.csv", "w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=FIELDS)
    w.writeheader()
    w.writerows(tasks)

# Every run writes a trace, including this one, so "some traces exist" does not
# mean "a workload has run". Say which it is rather than printing an empty table
# that looks like a result.
if not tasks:
    msg = ("No workload tasks found in %d trace file(s).\n"
           "Run an arm (illumina / pacbio / ont) on each tier first." % len(traces))
    print(msg)
    open("timing-report.txt", "w").write(msg + "\n")
    raise SystemExit(0)

by = collections.defaultdict(list)
for t in tasks:
    by[(t["process"], t["tier"])].append(t["realtime_s"])

out = ["median realtime per process, hot vs cold", "",
       "%-24s %10s %10s %8s" % ("process", "hot_s", "cold_s", "ratio")]
for proc in sorted({p for p, _ in by}):
    hot, cold = by.get((proc, "hot")), by.get((proc, "cold"))
    # `is not None` rather than a truth test: a real median of 0.0 is data,
    # not a missing value.
    hm = statistics.median(hot) if hot else None
    cm = statistics.median(cold) if cold else None
    out.append("%-24s %10s %10s %8s" % (
        proc,
        "%.1f" % hm if hm is not None else "-",
        "%.1f" % cm if cm is not None else "-",
        "%.2fx" % (cm / hm) if hm and cm is not None else "-"))

out += ["", "ratio > 1 means cold is slower. %d tasks from %d trace file(s)."
        % (len(tasks), len(traces)),
        "Per-task rates are measured under normal fan-out; see README."]

text = "\n".join(out)
print(text)
open("timing-report.txt", "w").write(text + "\n")
