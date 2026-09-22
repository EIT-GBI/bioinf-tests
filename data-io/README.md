# data-io — hot vs cold storage IO benchmark

Comparing **hot (Lustre)** against **cold (Alluxio)** for IO-heavy
bioinformatics workloads, and checking whether cold returns intact bytes.

Reading directly from Alluxio has produced corrupted files. That is the first
question here. The timing comparison is the second, and it is not meaningful
until the first is answered.

See [PLAN.md](PLAN.md) for the reasoning behind the design.

---

## Everything is `nextflow run main.nf -entry <arm>`

There are no helper scripts and nothing to run before or after. Each arm builds
its own samplesheet, writes its own trace, and reports its own result.

| `-entry` | What it does | Tier |
|---|---|---|
| `verify` | reads every input on **both** tiers, N times, checksums and times them | both |
| `illumina` | bwa mem → index → flagstat | `--tier` |
| `pacbio` | (uBAM→FASTQ) → minimap2 or pbrun minimap2 → flagstat | `--tier` |
| `ont` | dorado basecaller (sup) → dorado aligner → flagstat | `--tier` |
| `compare` | hot vs cold published BAMs, body checksums | both |
| `report` | timing table across every run so far | — |

```
main.nf                  the six arms above
nextflow.config          all parameters, resources and containers
modules/                 nf-mod-* submodules + modules/local/
results/                 traces, verify.csv, the reports (gitignored)
```

Everything a tier needs is derived from one root, set in `nextflow.config`:

```
READ from the tier under test:
  <tier root>/tests/data-io/input/{illumina,pacbio,ont}/   reads you stage
  <tier root>/references/                                  references + indexes

WRITTEN to Lustre always, whichever tier is being read:
  <lustre>/tests/data-io/work/                             nextflow work dir
  <lustre>/tests/data-io/output/<tier>/                    published results
  <launch dir>/results/                                    traces and reports
```

---

## Setup

**No clone needed.** Nextflow pulls the pipeline straight from GitHub and caches
it under `~/.nextflow/assets/`. The pipeline lives in the repo's `data-io/`
subdirectory, so every command carries `-main-script data-io/main.nf`:

```bash
nextflow run EIT-GBI/bioinf-tests -latest -main-script data-io/main.nf \
  -entry verify -profile cluster -resume
```

`-latest` re-pulls the newest commit on the default branch. Without it Nextflow
silently reuses whatever it cached the first time.

> **Launch from `/mnt/lustre/projects/bioinformatics/runs`**, not from an
> Alluxio path. Nextflow writes `results/` (traces and reports) relative to
> wherever you launch, and `-entry report` reads every trace it finds there —
> so keeping every run in one launch directory is what makes the hot-vs-cold
> table complete. It also needs normal POSIX semantics, which Alluxio may not
> give it.

The only manual step is staging the reads into
`<root>/tests/data-io/input/<platform>/` on both tiers. Samplesheets are built
from those folders.

| Arm | Expected layout | Sample name |
|---|---|---|
| Illumina | `<sample>_R1.fastq.gz` + `<sample>_R2.fastq.gz` | before `_R1` |
| PacBio | one file per sample: `<sample>.bam` (HiFi uBAM), or FASTQ | filename minus suffix |
| ONT | one **directory** of POD5s per sample, `input/ont/<sample>/` | directory name |
| ONT (alt) | flat `input/ont/<sample>.pod5` files | basename |

References must already be indexed **on both tiers** (`.amb .ann .bwt .pac .sa`
for Illumina, `.fai` for all three). Index building is not part of the
measurement and no timed arm does it.

> **The tool modules are git submodules.** `manifest.recurseSubmodules` tells
> Nextflow to fetch them on pull. Confirm that works on the first remote run —
> if an include fails with a missing `modules/...` path, fall back to a
> `git clone --recursive` and run `main.nf` by path.

## Run it on the cluster

Hand the Nextflow driver to SLURM rather than running it in your terminal:

```bash
mkdir -p /mnt/lustre/projects/bioinformatics/runs
cd       /mnt/lustre/projects/bioinformatics/runs   # results/ lands here

sbatch -J nf-io -p cpu -t 2-00:00:00 --wrap="\
  nextflow run EIT-GBI/bioinf-tests -latest -main-script data-io/main.nf \
    -entry illumina -profile cluster --tier hot --rep 1 -resume"
```

Watch it with `squeue -u $USER` and `tail -f slurm-<jobid>.out`.

### What each part does

| Part | What it does |
|---|---|
| `sbatch` | Submits the job to SLURM and returns. It survives you logging out. |
| `-J nf-io` | Job **name**. This job is only the Nextflow *driver* — it submits and babysits the real work; the tools run as their own jobs. |
| `-p cpu` | **Partition** for the driver. The driver is tiny, so `cpu` is right even for the GPU arms — Dorado and Parabricks request the `gpu` partition themselves. |
| `-t 2-00:00:00` | Walltime. The driver lives as long as the whole run, and ONT sup basecalling takes hours. |
| `nextflow run EIT-GBI/bioinf-tests` | Pulls the pipeline from GitHub — no clone. |
| `-latest` | Re-pull the newest commit. Without it, Nextflow reuses its cached copy. |
| `-main-script data-io/main.nf` | The pipeline is in a subdirectory of the repo. |
| `-entry illumina` | Which arm of `main.nf` to run. It takes one name. |
| `-profile cluster` | SLURM executor + Apptainer containers. |
| `--tier hot` | Which storage tier to read. Omit and it defaults to `hot`. |
| `--rep 1` | Repeat number. It only labels the trace file, so `-entry report` can tell reps apart. |
| `-resume` | Reuse cached tasks after a crash instead of redoing hours of work. |

> **What `-resume` does to the numbers.** It is there so a driver that dies six
> hours into an ONT run can pick up where it left off rather than redo
> everything. A resumed task is *not* re-measured: Nextflow records it as
> `CACHED`, and `timing_report.py` counts only `COMPLETED` tasks, so a cache hit
> can never be reported as a fast read. The cost is a thinner sample, not a
> wrong one — if a rep looks short on tasks in `all_tasks.csv`, it was resumed.
> To force a genuine re-measurement, drop `-resume` or change `--rep`.

### The whole matrix in one submission

One `sbatch`, everything sequential in the background:

```bash
cd /mnt/lustre/projects/bioinformatics/runs

# -resume lives in $NF, so every line below runs with it
NF="nextflow run EIT-GBI/bioinf-tests -latest -main-script data-io/main.nf -profile cluster -resume"

sbatch -J nf-io -p cpu -t 7-00:00:00 --wrap="
  $NF -entry verify
  for rep in 1 2 3; do
    for tier in hot cold; do
      $NF -entry illumina --tier \$tier --rep \$rep
      $NF -entry pacbio   --tier \$tier --rep \$rep --pacbio.device cpu
      $NF -entry pacbio   --tier \$tier --rep \$rep --pacbio.device gpu
      $NF -entry ont      --tier \$tier --rep \$rep
    done
  done
  $NF -entry compare
  $NF -entry report
"
```

ONT sup basecalling dominates the budget — time one rep before committing to
three.

---

## The order that matters

**`verify` first.** It runs in minutes and can invalidate everything after it.
It reads every input on both tiers, `--verify.reps` times each, then reports:

1. **Cross-rep disagreement** — one file read twice giving two different md5s.
   The bytes on disk cannot have changed, so the read path returned something
   it made up. This is the finding that would explain the corrupted files.
2. **Hot vs cold mismatch** — the tiers are not holding the same bytes, so no
   timing comparison between them means anything.
3. **Failed reads and format checks** (`gzip -t`, `samtools quickcheck`), which
   tell a truncated read from a mangled one.
4. **Throughput** — indicative only. This arm reads both tiers at once, so hot
   and cold tasks compete with each other. The timing evidence is `-entry
   report`, where one tier runs at a time.

```bash
nextflow run EIT-GBI/bioinf-tests -latest -main-script data-io/main.nf \
  -entry verify -profile cluster -resume

cat results/verify-report.txt
```

Run it on **every partition the workload arms use, the GPU queue included** —
mounts can differ per partition, so a clean CPU-queue result does not cover the
Dorado and Parabricks arms.

Then the workload arms, then `compare` and `report`.

---

## Reading the numbers

- **`ratio > 1` means cold is slower**, in `results/timing-report.txt`.
- **`compare` is the strongest integrity statement.** It compares the BAM
  *body* (`samtools view | md5sum`), not the file: the `@PG` header records the
  command line, which contains tier-specific paths, so whole-file checksums
  always differ and say nothing. Identical bodies means cold survived a real
  workload's read pattern, not just one sequential pass.
- **First touch vs warm are different numbers, and both matter.** Alluxio
  caches on first read, so `--rep 1` is the cache-miss case. Treat that as a
  label to check rather than a fact: dropping caches needs root, and anything
  that touched the files first — including a previous `verify` — warms them.
- **Per-task `read_mb_per_s` is measured under normal fan-out**, with sibling
  tasks reading at the same time. That is the realistic condition and the
  number you want, but it is each task's *share*, not what the tier can serve a
  lone reader. Compare it only against the other tier's equivalent.
- **`results/all_tasks.csv`** is one row per task, for anything more careful
  than the summary table.
- **An empty run is an error, not a pass.** `verify` stops if neither tier has
  any input, `compare` stops if there are no BAMs, and `report` says so rather
  than printing an empty table. A green run with nothing in it would be the
  easiest way to draw a wrong conclusion here.
- **`compare` says INCOMPLETE, not PASS, when a BAM exists on only one tier.**
  That means an arm ran on one tier and not the other, and the BAM was never
  compared.

---

## Things that will bite you

- **One workload arm per run.** The arms could run together — nothing depends
  on anything — but different workloads reading at once would measure "three
  workloads saturating this filesystem" rather than "how fast this filesystem
  serves bwa", and a slowdown could not be attributed to an access pattern.
  **Within** an arm, samples fan out exactly as in a normal run, which is the
  realistic condition and is kept.
- **Only reads vary by tier. Everything written goes to Lustre.** The work dir
  needs POSIX semantics — atomic rename, locking, heavy small-metadata traffic —
  and Alluxio is a cache over object storage, weak at exactly those. A cold run
  with its work dir on Alluxio could fail or crawl for reasons unrelated to read
  performance, and would read as "Alluxio is slow". Writing to Lustre also keeps
  the measurement attributable to the read path, and matches how the tier is
  actually used. The trade-off: this measures reads, not end-to-end cold — if
  writing to Alluxio also matters, test that separately.
- **GPU nodes may mount storage differently from CPU nodes.** A real confound
  for the Parabricks and Dorado arms. Pin the node class with `clusterOptions`
  across a comparison.
- **The tier is a param, not a profile.** Command-line params are applied
  before `nextflow.config`'s derived paths are computed; profile values land
  after, so `-profile cold` would silently leave every derived path pointing at
  hot. Use `--tier cold`.
- **No trimming or filtering** (`fastp`, `chopper`) anywhere, deliberately.
  Those rewrite reads into the work dir, and everything downstream would then
  read Nextflow's local copy instead of the filesystem under test.
  `SAMTOOLS_FASTQ` in the pacbio arm is the one exception, because HiFi uBAM
  needs converting — it stays in the timed pipeline as its own process.
- **PacBio sample names keep the read-type suffix**: `pbA.hifi_reads.bam`
  becomes sample `pbA.hifi_reads`, because the reused nf-mod-utils script
  strips only `.bam`.

---

## Results

_To be filled in once the matrix has run._

| process | device | hot (s) | cold (s) | ratio | notes |
|---|---|---|---|---|---|
| | | | | | |
