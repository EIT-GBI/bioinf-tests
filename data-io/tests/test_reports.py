#!/usr/bin/env python3
"""Checks verify_report.py and summary.py against fixed inputs.

Usage: test_reports.py <dir holding the two scripts>
"""
import csv, os, subprocess, sys, tempfile

MOD = sys.argv[1]
fails = []


def check(label, cond, detail=""):
    print("  ok   %s" % label if cond else "  FAIL %s\n     %s" % (label, detail))
    if not cond:
        fails.append(label)


def run(script, *args):
    r = subprocess.run([sys.executable, os.path.join(MOD, script), *args],
                       capture_output=True, text=True)
    return r.stdout + r.stderr


def reads_csv(path, rows):
    with open(path, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow("tier,rep,rel,bytes,seconds,mb_per_s,md5,check,ok".split(","))
        w.writerows(rows)


tmp = tempfile.mkdtemp()
os.chdir(tmp)

# --- verify_report --------------------------------------------------------
BIG = 200 * 2**20  # 200 MiB, comfortably over the 1 MiB floor

# Tiny files are dropped from throughput on BOTH tiers even though only cold
# rounds to 0.00 - the bug that made hot show 848 reads and cold 841.
rows = []
for i in range(4):
    rows += [["hot", "1", "big%d.gz" % i, BIG, 1.0, 200.0, "md5%d" % i, "gzip", "yes"],
             ["cold", "1", "big%d.gz" % i, BIG, 2.0, 100.0, "md5%d" % i, "gzip", "yes"]]
rows += [["hot", "1", "meta.txt", 120, 0.02, 0.01, "m", "none", "na"],
         ["cold", "1", "meta.txt", 120, 0.18, 0.00, "m", "none", "na"]]
reads_csv("r1.csv", rows)
out = run("verify_report.py", "r1.csv")
hot = [l for l in out.splitlines() if l.strip().startswith("hot")]
cold = [l for l in out.splitlines() if l.strip().startswith("cold")]
check("verify: hot and cold sample the same files",
      hot and cold and hot[0].split()[2] == cold[0].split()[2],
      "hot=%r cold=%r" % (hot, cold))
check("verify: sub-1 MiB files excluded", "1 of 5 files per tier excluded" in out, out)
check("verify: clean run passes", "PASS - no integrity problem found." in out, out)

# A real mismatch must fail.
rows2 = [["hot", "1", "a.gz", BIG, 1.0, 200.0, "AAA", "gzip", "yes"],
         ["cold", "1", "a.gz", BIG, 2.0, 100.0, "BBB", "gzip", "yes"]]
reads_csv("r2.csv", rows2)
out = run("verify_report.py", "r2.csv")
check("verify: md5 mismatch is caught", "MISMATCH" in out and "FAIL" in out, out)

# Single tier: not 850 missing files.
reads_csv("r3.csv", [r for r in rows if r[0] == "hot"])
out = run("verify_report.py", "r3.csv")
check("verify: single tier skips the comparison",
      "read the 'hot' tier only" in out and "ONLY ON" not in out, out)

# Same file bad on both tiers with one md5 = bad input, not storage.
reads_csv("r4.csv",
          [["hot", "1", "x.bam", BIG, 1.0, 200.0, "SAME", "quickcheck", "no"],
           ["cold", "1", "x.bam", BIG, 2.0, 100.0, "SAME", "quickcheck", "no"]])
out = run("verify_report.py", "r4.csv")
check("verify: file bad on both tiers is not blamed on storage",
      "BAD INPUT" in out and "PASS" in out, out)

# --- summary --------------------------------------------------------------
HDR = ("task_id\tprocess\ttag\tstatus\texit\tstart\tcomplete\trealtime\t%cpu"
       "\tpeak_rss\trchar\twchar\tread_bytes\twrite_bytes")


def trace(run_name, rows):
    d = os.path.join(tmp, "res", run_name)
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "trace.txt"), "w").write(HDR + "\n" + "\n".join(rows) + "\n")


def task(i, proc, status, start, realtime, rchar):
    return ("%d\tx:%s\ts1\t%s\t0\t%d\t%d\t%d\t100.0\t1000\t%d\t0\t0\t0"
            % (i, proc, status, start, start + realtime, realtime, rchar))


# illumina: entirely cached, from an older run. pacbio: freshly run, cold queued.
for tier, rt in (("hot", 10000), ("cold", 11000)):
    trace("%s-illumina" % tier, [task(1, "BWA_MEM", "CACHED", 1_700_000_000_000, rt, 2**30)])
for tier, start in (("hot", 1_800_000_000_000), ("cold", 1_800_000_600_000)):
    trace("%s-pacbio-cpu" % tier, [task(1, "MINIMAP2_ALIGN", "COMPLETED", start, 60000, 2**30)])
trace("hot-ont", [task(1, "DORADO_BASECALLER", "FAILED", 1_800_000_000_000, 10, 1)])

out = run("summary.py", os.path.join(tmp, "res"))
check("summary: a fully cached arm is still summarised",
      "illumina" in out and "BWA_MEM" in out, out)
check("summary: cached arms are flagged", "cached" in out, out)
check("summary: wall clock suppressed for cached arms",
      any(l.split()[1] == "illumina" and l.split()[5] == "-"
          for l in out.splitlines() if l.strip().startswith(("hot ", "cold "))), out)
check("summary: executed arms keep their wall clock",
      any(l.split()[1] == "pacbio-cpu" and l.split()[5] != "-"
          for l in out.splitlines() if l.strip().startswith(("hot ", "cold "))), out)
check("summary: failed-only arm is excluded", "DORADO_BASECALLER" not in out, out)
check("summary: hot/cold ratio computed from cached data",
      "1.10x" in out, out)

print("  %d report check(s) failed" % len(fails) if fails else "  all report checks passed")
sys.exit(1 if fails else 0)
