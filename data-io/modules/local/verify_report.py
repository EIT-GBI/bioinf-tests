#!/usr/bin/env python3
"""Turn verify.csv into the integrity answer.

Usage: verify_report.py <verify.csv>

Checks, in order of how much they matter:
  1. Same file, same tier, different md5 between reps. The bytes on disk cannot
     have changed, so the read path returned something it made up.
  2. Same file, different md5 between hot and cold. One tier is not holding what
     the other is - corruption at rest, in staging, or on every read.
  3. Failed reads and format checks, which tell a truncated read from a mangled
     one.
Then throughput, the probe's secondary purpose.
"""

import collections
import csv
import statistics
import sys

rows = list(csv.DictReader(open(sys.argv[1])))
out = []
problems = 0


def say(s=""):
    out.append(s)


say("=" * 62)
say(" verify report - %d reads" % len(rows))
say("=" * 62)

# Distinct checksums seen for each (tier, file)
seen = collections.defaultdict(set)
for r in rows:
    seen[(r["tier"], r["rel"])].add(r["md5"])

say()
say("1. CROSS-REP DISAGREEMENT (same file read twice, two different md5s)")
disagreeing = {k: v for k, v in seen.items() if len(v) > 1}
for (tier, rel), md5s in sorted(disagreeing.items()):
    say("   %-5s %s" % (tier, rel))
    say("         %s" % "  ".join(sorted(md5s)))
problems += len(disagreeing)
if not disagreeing:
    say("   none - every file checksummed identically across all reps.")

say()
say("2. HOT vs COLD MISMATCH")
mismatched, unpaired = [], []
for rel in sorted({rel for _, rel in seen}):
    hot, cold = seen.get(("hot", rel)), seen.get(("cold", rel))
    if not hot or not cold:
        unpaired.append((rel, "hot" if hot else "cold"))
    elif hot != cold:
        mismatched.append((rel, sorted(hot), sorted(cold)))
for rel, hot, cold in mismatched:
    say("   MISMATCH %s" % rel)
    say("            hot  %s" % " ".join(hot))
    say("            cold %s" % " ".join(cold))
for rel, where in unpaired:
    say("   ONLY ON %-5s %s" % (where, rel))
problems += len(mismatched) + len(unpaired)
if not mismatched and not unpaired:
    say("   none - both tiers hold the same bytes for every file.")

say()
say("3. FAILED READS AND FORMAT CHECKS")
failed = [r for r in rows if r["md5"] == "READ_FAILED" or r["check_ok"] == "no"]
for r in failed:
    say("   %-5s %s  (%s)" % (r["tier"], r["rel"], r["check_type"]))
problems += len(failed)
if not failed:
    say("   none.")

say()
say("4. THROUGHPUT")
for tier in ("hot", "cold"):
    # Files too small to time report 0 and would drag the median down
    speeds = [float(r["mb_per_s"]) for r in rows
              if r["tier"] == tier and float(r["mb_per_s"]) > 0]
    if speeds:
        say("   %-5s %d timed reads: median %.1f MB/s, range %.1f - %.1f"
            % (tier, len(speeds), statistics.median(speeds), min(speeds), max(speeds)))
    else:
        say("   %-5s no files large enough to time." % tier)
say("   Indicative only: this run reads BOTH tiers at once, so hot and cold")
say("   tasks compete with each other as well as with their own siblings.")
say("   The timing evidence is `--arm report`, where one tier runs at a time.")

say()
say("=" * 62)
say(" PASS: both tiers returned consistent, intact bytes." if problems == 0 else
    " FAIL: %d problem(s). Do not trust timings until this is understood." % problems)
say("=" * 62)

text = "\n".join(out)
print(text)
open("verify-report.txt", "w").write(text + "\n")
