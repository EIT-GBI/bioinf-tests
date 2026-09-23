#!/usr/bin/env python3
"""Turn reads.csv into the integrity answer.

Usage: verify_report.py <reads.csv>

Checks, in order of how much they matter:
  1. Hot vs cold mismatch - the tiers are not holding the same bytes.
  2. Cross-rep disagreement (only meaningful with --reps 2 or more) - the same
     file read twice giving two different md5s. The bytes on disk cannot have
     changed, so the read path returned something it made up.
  3. Failed reads and format checks, which tell a truncated read from a mangled
     one. A file that fails identically on BOTH tiers with the SAME md5 is a bad
     input file, not a storage fault - the report says so rather than blaming
     the filesystem.
"""

import collections
import csv
import statistics
import sys

rows = list(csv.DictReader(open(sys.argv[1])))
out, problems = [], 0
say = out.append

reps = sorted({r["rep"] for r in rows})
size = sum(int(r["bytes"]) for r in rows if r["tier"] == "hot" and r["rep"] == reps[0])

say("=" * 64)
say(" verify - %d reads, %d files per tier, %.1f GB, %d rep(s)"
    % (len(rows), len(rows) // (2 * len(reps)), size / 2**30, len(reps)))
say("=" * 64)

# md5s seen per (tier, file)
seen = collections.defaultdict(set)
for r in rows:
    seen[(r["tier"], r["rel"])].add(r["md5"])

say("")
say("1. HOT vs COLD")
mismatch, only_one = [], []
for rel in sorted({rel for _, rel in seen}):
    hot, cold = seen.get(("hot", rel)), seen.get(("cold", rel))
    if not hot or not cold:
        only_one.append((rel, "hot" if hot else "cold"))
    elif hot != cold:
        mismatch.append((rel, sorted(hot), sorted(cold)))
for rel, h, c in mismatch:
    say("   MISMATCH %s" % rel)
    say("            hot  %s" % " ".join(h))
    say("            cold %s" % " ".join(c))
for rel, where in only_one:
    say("   ONLY ON %-4s %s" % (where, rel))
problems += len(mismatch) + len(only_one)
if not mismatch and not only_one:
    say("   PASS - both tiers hold identical bytes for every file.")

say("")
say("2. REPEATED READS")
if len(reps) < 2:
    say("   skipped (one rep). Use --reps 2 to re-read every file and catch a")
    say("   read path that returns different bytes on different reads.")
else:
    flaky = {k: v for k, v in seen.items() if len(v) > 1}
    for (tier, rel), md5s in sorted(flaky.items()):
        say("   UNSTABLE %-4s %s" % (tier, rel))
        say("            %s" % "  ".join(sorted(md5s)))
    problems += len(flaky)
    if not flaky:
        say("   PASS - every file checksummed identically on every read.")

say("")
say("3. FORMAT CHECKS")
bad = [r for r in rows if r["md5"] == "READ_FAILED" or r["ok"] == "no"]
# A file bad on both tiers with one md5 is a bad file, not a storage problem
by_file = collections.defaultdict(list)
for r in bad:
    by_file[r["rel"]].append(r)
for rel, rs in sorted(by_file.items()):
    tiers = {r["tier"] for r in rs}
    md5s = {r["md5"] for r in rs}
    if tiers == {"hot", "cold"} and len(md5s) == 1:
        say("   BAD INPUT  %s" % rel)
        say("              fails on both tiers with the same checksum - the file")
        say("              itself is malformed, not the storage. Not counted below.")
    else:
        say("   FAILED     %-4s %s (%s)" % (rs[0]["tier"], rel, rs[0]["check"]))
        problems += len(rs)
if not bad:
    say("   PASS - nothing failed gzip -t or samtools quickcheck.")

say("")
say("4. READ THROUGHPUT")
say("   %-5s %-5s %6s %10s %9s %9s" % ("tier", "rep", "reads", "median", "p10", "p90"))
med = {}
for tier in ("hot", "cold"):
    for rep in reps:
        s = sorted(float(r["mb_per_s"]) for r in rows
                   if r["tier"] == tier and r["rep"] == rep and float(r["mb_per_s"]) > 0)
        if not s:
            continue
        med[(tier, rep)] = statistics.median(s)
        say("   %-5s %-5s %6d %9.1f %9.1f %9.1f MB/s"
            % (tier, rep, len(s), statistics.median(s), s[len(s) // 10], s[9 * len(s) // 10]))

if ("hot", reps[0]) in med and ("cold", reps[0]) in med:
    say("   rep %s: hot is %.1fx faster than cold." %
        (reps[0], med[("hot", reps[0])] / med[("cold", reps[0])]))

# rep 1 is only a first-touch measurement if the cache was cold beforehand
if len(reps) > 1:
    say("")
    say("   CACHE EFFECT (rep 1 vs later reps)")
    for tier in ("hot", "cold"):
        first = med.get((tier, reps[0]))
        later = [med[(tier, r)] for r in reps[1:] if (tier, r) in med]
        if first and later:
            say("      %-5s rep1 %6.1f -> warm %6.1f MB/s  (%.1fx)"
                % (tier, first, statistics.mean(later), statistics.mean(later) / first))
    say("      A large gap on cold means rep 1 was a genuine cache miss. No gap")
    say("      means the cache was already warm and rep 1 is NOT a first touch.")

say("")
say("   Caveats: both tiers are read in the same run, so they compete with each")
say("   other; and Alluxio caches on first read, so any file read by an earlier")
say("   run is warm. Free the cache first for a true first-touch number.")

say("")
say("=" * 64)
say(" PASS - no integrity problem found." if problems == 0 else
    " FAIL - %d problem(s)." % problems)
say("=" * 64)

text = "\n".join(out)
print(text)
open("verify-report.txt", "w").write(text + "\n")
