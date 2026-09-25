#!/usr/bin/env bash
# data-io test suite. Needs only nextflow + python3; runs nothing on a cluster.
#
#   bash data-io/tests/run_tests.sh
#
# Three layers:
#   1. path derivation - the params every run depends on, over a matrix of flags
#   2. DAG construction - every arm builds, and every guard rejects bad input
#   3. the two report scripts, against fixed CSV/trace inputs
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DATAIO=$(dirname "$HERE")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0

ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected '$3', got '$2'"; }

# --- fixture ---------------------------------------------------------------
tree() {  # $1 root, $2 input dir name
  mkdir -p "$1/tests/data-io/$2"/{illumina,pacbio,ont/bc01} \
           "$1/references"/{ecoli/syn57/syn57_evo,plasmids,other/simon_methylation}
  for s in sampA sampB; do
    for r in R1 R2; do : | gzip > "$1/tests/data-io/$2/illumina/${s}_${r}_001.fastq.gz"; done
  done
  echo x > "$1/tests/data-io/$2/pacbio/movie1.hifi_reads.bam"
  echo x > "$1/tests/data-io/$2/ont/bc01/reads_0.pod5"
  echo ">a" > "$1/references/ecoli/syn57/syn57_evo/Syn57_evo2.fa"
  echo ">b" > "$1/references/plasmids/pFR494_pRT300_rham_wt.fa"
  echo ">c" > "$1/references/other/simon_methylation/wt-0248-tdk_kan.fa"
}
tree "$TMP/hot" input; tree "$TMP/cold" input; tree "$TMP/cold" input_uncached1
ROOTS="--hot_root $TMP/hot --cold_root $TMP/cold"

cat > "$TMP/probe.nf" <<'EOF'
workflow { println groovy.json.JsonOutput.toJson(params) }
EOF

# Print one derived param for a given set of flags.
derive() {  # $1 key, rest: flags
  local key=$1; shift
  nextflow -q run "$TMP/probe.nf" -c "$DATAIO/nextflow.config" $ROOTS "$@" 2>/dev/null \
    | tail -1 | python3 -c "import json,sys;print(json.load(sys.stdin)['$key'])" 2>/dev/null
}

echo "1. PATH DERIVATION"
is "cold tier reads the cold root" \
   "$(derive input_dir --arm illumina --tier cold)" "$TMP/cold/tests/data-io/input"
is "--cold_input redirects the cold dataset" \
   "$(derive input_dir --arm illumina --tier cold --cold_input input_uncached1)" \
   "$TMP/cold/tests/data-io/input_uncached1"
is "--cold_input does NOT affect the hot tier" \
   "$(derive input_dir --arm illumina --tier hot --cold_input input_uncached1)" \
   "$TMP/hot/tests/data-io/input"
is "--results names the results set" \
   "$(derive results_base --arm illumina --results run7)" \
   "$TMP/hot/tests/data-io/results/run7"
is "past results are kept apart" \
   "$(derive results_base --arm illumina --results run8)" \
   "$TMP/hot/tests/data-io/results/run8"
is "data and reports are separate trees" \
   "$(derive reportdir --arm illumina --tier cold --results r)/|$(derive outdir --arm illumina --tier cold --results r)" \
   "$TMP/hot/tests/data-io/results/r/reports/cold-illumina/|$TMP/hot/tests/data-io/results/r/data/cold-illumina"
is "pacbio run name carries the device" \
   "$(derive run --arm pacbio --tier cold --device gpu)" "cold-pacbio-gpu"
is "work dir stays on lustre for a cold run" \
   "$(derive work_dir --arm illumina --tier cold)" "$TMP/hot/tests/data-io/work"
is "publishing to the other tier copies" \
   "$(derive publish_mode --arm illumina --out_tier cold)" "copy"

echo "2. DAG CONSTRUCTION"
preview() { nextflow run "$DATAIO/main.nf" -preview $ROOTS "$@" 2>&1; }
for arm in verify illumina pacbio ont summary; do
  if preview --arm "$arm" --tier cold --cold_input input_uncached1 >/dev/null 2>&1
    then ok "--arm $arm builds"; else bad "--arm $arm builds" "$(preview --arm $arm --tier cold | tail -3)"; fi
done

echo "3. GUARDS  (these must be rejected)"
rejects() {  # $1 label, $2 expected text, rest flags
  local label=$1 want=$2; shift 2
  local out; out=$(preview "$@" 2>&1)
  echo "$out" | grep -qF -- "$want" && ok "$label" || bad "$label" "no '$want' in: $(echo "$out" | tail -2)"
}
no_arm=$(nextflow run "$DATAIO/main.nf" -preview $ROOTS 2>&1)
echo "$no_arm" | grep -qF -- "No --arm given" \
  && ok "no --arm" || bad "no --arm" "$(echo "$no_arm" | tail -2)"
rejects "unknown --arm"       "Unknown --arm"         --arm nope
rejects "bad --device"        "Invalid --device"      --arm pacbio --device tpu
rejects "bad --verify_tiers"  "--verify_tiers must be" --arm verify --verify_tiers warm
rejects "--reps 0"            "--reps must be at least 1" --arm verify --reps 0
rejects "missing reference"   "Reference missing"     --arm illumina --tier hot --ref_illumina nosuch.fa
rejects "missing input dir"   "Check --hot_input"        --arm illumina --tier hot --hot_input nosuchdir

echo "4. VERIFY SCOPE"
out=$(preview --arm verify --verify_tiers hot 2>&1)
echo "$out" | grep -q "WARM the Alluxio cache" \
  && bad "--verify_tiers hot stays off the cold tier" "it warned about caching cold" \
  || ok "--verify_tiers hot stays off the cold tier"
out=$(preview --arm verify --verify_tiers hot,cold 2>&1)
echo "$out" | grep -q "WARM the Alluxio cache" \
  && ok "reading cold warns about the cache" \
  || bad "reading cold warns about the cache" "no warning printed"

echo "5. REPORT SCRIPTS"
cd "$TMP"
python3 "$HERE/test_reports.py" "$DATAIO/modules/local" && pass=$((pass+1)) || fail=$((fail+1))

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
