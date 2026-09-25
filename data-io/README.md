# data-io — hot vs cold storage IO benchmark

Comparing **hot (Lustre)** against **cold (Alluxio)** for IO-heavy bioinformatics
workloads, and checking whether cold returns intact bytes.

Reading directly from Alluxio once produced corrupted files. That is the first
question; the timing comparison is the second, and it only means something once
the first is answered.

---

## One command

```bash
nextflow run EIT-GBI/bioinf-tests -latest -main-script data-io/main.nf \
  --arm <arm> -profile cluster -resume
```

| `--arm` | What it does | Options |
|---|---|---|
| `verify` | reads every input on **both** tiers, checksums and times it | `--reps N` |
| `illumina` | bwa mem → index → flagstat | `--tier` |
| `pacbio` | (uBAM→FASTQ) → minimap2, or Parabricks | `--tier --device cpu\|gpu` |
| `ont` | dorado sup basecalling → dorado aligner | `--tier` |
| `summary` | hot vs cold: timings, throughput, output checksums | — |

One arm per run. They could run together, but different workloads reading at
once would measure "three workloads saturating this filesystem" rather than how
it serves any one of them. Within an arm, samples fan out normally — that
concurrency is the realistic condition.

## Where everything lives

**Only reads vary by tier.** Everything written — the work dir and the results —
goes to Lustre by default, for both arms, so Alluxio is measured as a data
source rather than used as a working filesystem.

`--out_tier cold` publishes the results to Alluxio instead, if you want to
exercise writing to it. The work dir stays on Lustre either way — that one is
not optional (see below).

```
<hot>/tests/data-io/<--hot_input>/<platform>/     reads you stage
<cold>/tests/data-io/<--cold_input>/<platform>/
<tier root>/references/                           reference fastas

<lustre>/tests/data-io/work/                      nextflow work dir
<lustre>/tests/data-io/results/<--results>/       one results set:

    reports/            <- grab this one folder and you have everything
        hot-illumina/     trace.txt  report.html  timeline.html  samplesheet.csv
        cold-illumina/    ...
        verify/           verify-report.txt  reads.csv
        summary/          summary.txt  tasks.csv
    data/
        hot-illumina/     alignment/  qc/  index/
        cold-illumina/    ...
```

Reports and data are separate trees, so `reports/` can be downloaded on its own
without dragging multi-GB BAMs with it.

`--results NAME` names the whole set. A new name starts a clean set and leaves
the previous one untouched, which is how past results are kept — within one set,
re-running an arm overwrites its own folder rather than leaving a dated copy.

The read tier is in each run folder's name, so hot and cold sit side by side.
Nothing is written to the directory you launch from.

## Parameters

| Param | Default | Meaning |
|---|---|---|
| `--arm` | — | which arm to run |
| `--tier` | `hot` | storage that is **read** — the thing under test |
| `--out_tier` | `hot` | storage the **results** are published to; `cold` to write to Alluxio |
| `--work_dir` | `<hot>/tests/data-io/work` | Nextflow work dir — leave it on Lustre |
| `--device` | `cpu` | pacbio only: `gpu` uses Parabricks |
| `--reps` | `1` | verify only: read every file this many times |
| `--results` | `default` | name of the results set — change it to keep a past set |
| `--cold_input` | `input` | cold dataset dir under `<cold>/tests/data-io/`; point at an unread copy for a first-touch run |
| `--hot_input` | `input` | same for the hot tier |
| `--verify_tiers` | `hot,cold` | tiers `--arm verify` reads; `hot` leaves the cold dataset unread |
| `--hot_root` / `--cold_root` | see config | the two storage roots |
| `--ref_illumina` / `--ref_pacbio` / `--ref_ont` | see config | reference fasta, relative to `<root>/references/` |

All top level on purpose: a nested `--a.b` does not reach values the config
derives from it, so a wrong one would be silently ignored.

---

## Setup

Nothing to clone. Nextflow pulls the pipeline from GitHub and caches it under
`~/.nextflow/assets/`:

```bash
nextflow run EIT-GBI/bioinf-tests -latest -main-script data-io/main.nf \
  --arm verify -profile cluster -resume
```

- `-main-script data-io/main.nf` — the pipeline lives in a subdirectory of the
  repo, so Nextflow has to be told which script to run.
- `-latest` — re-pull the newest commit. **Without it Nextflow silently runs
  whatever it cached the first time.** The launch banner prints
  `revision: <sha> [main]`; if that is not the commit you expect, the pull did
  not happen.

The tool modules are git submodules, fetched automatically because the repo-root
`nextflow.config` sets `manifest.recurseSubmodules = true`. All seven repos are
public, so no credentials are needed anywhere.

`-latest` is what makes each run fetch from GitHub itself, so there is no
`nextflow pull` step to remember and no way to run a stale commit by accident.
The runs below are sequential, so nothing races.

> **The one exception: concurrent runs.** Several `nextflow run` commands racing
> to update the same cached clone produce
> `Unknown error accessing project ... Repository may be corrupted`. If you run
> arms in parallel, either give each its own assets dir
> (`NXF_HOME=$PWD/.nxf-<arm> nextflow run ...`) or pull once up front and leave
> `-latest` off. If it does break, delete
> `~/.nextflow/assets/EIT-GBI/bioinf-tests` and run again.

> **When a tool module changes, `-latest` is not enough.** The `nf-mod-*`
> submodules are resolved when the asset is first cloned, so a pull that moves
> `main` forward will not reliably move them. After a module release, run
> `nextflow drop EIT-GBI/bioinf-tests` once to force a fresh recursive clone.

Stage the reads into `<root>/tests/data-io/<input name>/<platform>/` on both tiers
(`input` by default; `--cold_input` names a different copy for the cold tier):

| Arm | Layout | Sample name |
|---|---|---|
| Illumina | `<sample>_R1.fastq.gz` + `_R2` | before `_R1` |
| PacBio | one file per sample: `.bam` (HiFi uBAM) or FASTQ | filename minus suffix |
| ONT | a directory of POD5s per sample, `input/ont/<sample>/` | directory name |
| ONT (alt) | flat `input/ont/<sample>.pod5` | basename |

Only the reference **fasta** has to exist. `bwa index` and `samtools faidx` run
automatically when their output is missing, and are reused when it is not.

## Running it

Reading a file through Alluxio **caches it**. Every cold number is therefore a
first-touch number exactly once per copy of the data, and anything that touches
the cold dataset first — including `--arm verify` — spends it. So the order is:

```bash
cd /mnt/lustre/projects/bioinformatics/runs      # anywhere; nothing is written here

NF="nextflow run EIT-GBI/bioinf-tests -latest -main-script data-io/main.nf -profile cluster -resume"
SET="--results 2026-09-25"

sbatch -J nf-io -p cpu -t 4-00:00:00 --wrap="
  # 1. hot first. Same code, same references, no cold bytes touched - so a
  #    broken container or a bad path fails here, not against the one pristine
  #    copy of the cold data.
  $NF $SET --arm illumina --tier hot
  $NF $SET --arm pacbio   --tier hot --device cpu
  $NF $SET --arm pacbio   --tier hot --device gpu
  $NF $SET --arm ont      --tier hot

  # 2. cold, on the unread copy. One arm at a time: parallel arms would be
  #    measuring how the filesystem splits its bandwidth, not how it serves one.
  COLD=\"$SET --tier cold --cold_input input_uncached1\"
  $NF \$COLD --arm illumina
  $NF \$COLD --arm pacbio --device cpu
  $NF \$COLD --arm ont

  # 3. verify LAST. It reads every file on both tiers, so running it earlier
  #    would warm the cache for everything above.
  $NF $SET --arm verify
  $NF $SET --arm summary
"
```

### One first touch per copy

`--cold_input` exists because a cold measurement cannot be repeated. The second
run to read a file gets it from cache, whatever the arm. In particular
`--device cpu` and `--device gpu` read the *same* pacbio input, so only the
first of the two is a first touch — give the second its own copy:

```bash
$NF $SET --tier cold --cold_input input_uncached2 --arm pacbio --device gpu
```

To re-measure anything cold, stage another copy and point `--cold_input` at it.
`--verify_tiers hot` is there for the same reason: it checksums the hot tier
without touching cold, if you want an integrity check before the cold arms run.

### Running arms in parallel

Arms are independent, so they can run at once — but they then compete for the
same filesystem, and the timings stop meaning "how it serves this workload".
Parallelise the hot validation pass, keep the cold pass sequential.

Give each concurrent run its own launch directory and its own Nextflow home:

```bash
for arm in illumina pacbio ont; do
  mkdir -p runs/$arm
  ( cd runs/$arm && NXF_HOME=$PWD/.nxf sbatch -J nf-$arm -p cpu -t 1-00:00:00 \
      --wrap="$NF $SET --arm $arm --tier hot" ) &
done; wait
```

Both parts matter. Nextflow keeps its session cache in `.nextflow/` under the
launch dir, so runs sharing one directory all try to resume the same session and
all but one die with `Unable to acquire lock on session`. And `-latest` makes
each run update the same cached clone, which races into
`Unknown error accessing project ... Repository may be corrupted` — a separate
`NXF_HOME` gives each its own copy.

They still share one work dir and one results set, which is intended: that is
what lets `--arm summary` see all of them.

## Reading the results

Start with `results/summary/summary.txt`. It answers, in one file: which runs
exist, wall clock per arm hot vs cold, per-process timings and throughput, and
whether the two tiers produced byte-identical BAMs. `tasks.csv` beside it has one
row per task for anything more detailed.

`results/verify/verify-report.txt` is the integrity answer:

1. **Hot vs cold** — do the tiers hold the same bytes.
2. **Repeated reads** — only with `--reps 2` or more: the same file read twice
   giving two different checksums means the read path invented something.
3. **Format checks** — `gzip -t`, `samtools quickcheck`. A file that fails
   identically on *both* tiers with the *same* checksum is a bad input file, not
   a storage fault, and is reported as such.
4. **Throughput** — indicative only; both tiers are read in the same run, so
   they compete with each other.

### Things worth knowing

- **Throughput uses `rchar`, not `read_bytes`.** `read_bytes` counts
  block-device IO and reads 0 on Alluxio, which serves over the network, so it
  cannot be compared across tiers.
- **Only some processes read from the tier under test.** `BWA_MEM`,
  `SAMTOOLS_FASTQ` and `DORADO_BASECALLER` read the staged inputs; everything
  downstream reads intermediates from the work dir, which is on `--out_tier` for
  both arms. Their hot-vs-cold rows are structurally identical and mean nothing.
- **Compute-bound arms hide storage differences.** If `BWA_MEM` runs at 1200%
  CPU, four-times-slower storage can vanish into the alignment work. The wall
  clock per arm is the number that answers "should we use Alluxio".
- **First touch vs warm — the biggest caveat in the whole benchmark.** Alluxio
  caches on first read, so every number here is a *warm* number unless the cache
  was cleared first. That matters because a production pipeline usually pulls
  each file once: the first touch is both slower and the case most likely to
  fail. `verify` reports rep 1 separately from later reps so the gap is visible,
  but a small gap only proves the cache was already warm.

  To measure a genuine first touch, one of:

  ```bash
  alluxio fs free /path/to/tests/data-io/input    # evict from cache, keep in UFS
  ```

  ...or point the run at data that has never been read. Then `--reps 2` gives
  you first-touch and warm side by side in one run.

  **Order matters:** `verify` reads every input on both tiers, so running it
  first warms everything and the workload arms that follow measure a warm cache.
  Free the cache between them, or run the workload arm you care about first.
- **The work dir must stay on Lustre.** Nextflow polls each task's work
  directory for its `.exitcode` file, and Alluxio — a cache over object storage
  — does not give that the immediate metadata visibility it needs. Tasks then
  come back as *"terminated for an unknown reason -- Likely it has been
  terminated by the external system"* with no exit status, even though they ran
  fine. Results are safe on Alluxio; the work dir is not. `--work_tier` exists
  only so you can test that claim.
- **Publishing adapts.** When the work dir and results share a filesystem the
  files are hard-linked (free); otherwise they are copied. That matters on
  Lustre, where Java 21+ `copy_file_range` returns `ENODATA` — linking avoids
  the syscall entirely.

## Results

_To be filled in._

| arm | hot | cold | ratio | notes |
|---|---|---|---|---|
| | | | | |
