# data-io — hot vs cold storage IO benchmark

Comparing **hot (Lustre)** against **cold (Alluxio)** for IO-heavy
bioinformatics workloads, and checking whether cold returns intact bytes.

Reading directly from Alluxio has produced corrupted files. That is the first
question here. The timing comparison is the second, and it is not meaningful
until the first is answered.

See [PLAN.md](PLAN.md) for the reasoning behind the design.

---

## Everything is `nextflow run main.nf --arm <arm>`

There are no helper scripts and nothing to run before or after. Each arm builds
its own samplesheet, writes its own trace, and reports its own result.

| `--arm` | What it does | Tier |
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

The pipeline is run from a **checkout on shared storage**, not pulled from
GitHub on every run. Clone it once:

```bash
git clone --recursive git@github.com:EIT-GBI/bioinf-tests.git \
  /mnt/gbi-shared/home/cristian-soitu/code/nf/bioinf-tests
```

The SSH URL avoids tokens entirely, for the clone and for the private
submodules. Check you have a key registered with `ssh -T git@github.com` first;
if not, use the HTTPS URL and give a personal access token (with `repo` scope)
at the password prompt — GitHub has not accepted account passwords over HTTPS
since 2021.

`--recursive` matters: the tool modules are git submodules, and three of them
are private. This clone is the only step that touches GitHub at all — nothing
afterwards needs credentials or network.

Run it by pointing at `data-io/main.nf` inside the clone:

```bash
nextflow run /mnt/gbi-shared/home/cristian-soitu/code/nf/bioinf-tests/data-io/main.nf \
  --arm verify -profile cluster -resume
```

To update, `git pull` in that one directory:

```bash
cd /mnt/gbi-shared/home/cristian-soitu/code/nf/bioinf-tests && git pull --recurse-submodules
```

> **Why not `nextflow run EIT-GBI/bioinf-tests -latest`?** That form works, but
> on a private repo it needs GitHub credentials on every node and in every
> shell, and it keeps its own copy under `~/.nextflow/assets`. That copy can go
> stale silently — a `nextflow pull` that fails on auth leaves the old code in
> place and the next run uses it without complaint — and concurrent runs racing
> to update it produce `Repository may be corrupted`. A shared checkout has
> none of those failure modes, and `git pull` is a change you can see. If you
> do use the GitHub form, add `-main-script data-io/main.nf`, since the
> pipeline lives in a subdirectory, and check the `revision:` line in the
> launch banner is the commit you expect.

> **Launch from `/mnt/lustre/projects/bioinformatics/runs`**, not from an
> Alluxio path and not from inside the clone. Nextflow writes `results/`
> (traces and reports) relative to wherever you launch, and `--arm report`
> reads every trace it finds there — so keeping every run in one launch
> directory is what makes the hot-vs-cold table complete. It also needs normal
> POSIX semantics, which Alluxio may not give it.

The only other manual step is staging the reads into
`<root>/tests/data-io/input/<platform>/` on both tiers. Samplesheets are built
from those folders.

| Arm | Expected layout | Sample name |
|---|---|---|
| Illumina | `<sample>_R1.fastq.gz` + `<sample>_R2.fastq.gz` | before `_R1` |
| PacBio | one file per sample: `<sample>.bam` (HiFi uBAM), or FASTQ | filename minus suffix |
| ONT | one **directory** of POD5s per sample, `input/ont/<sample>/` | directory name |
| ONT (alt) | flat `input/ont/<sample>.pod5` files | basename |

Only the reference **fasta** has to be in place on each tier. Indexes are built
automatically when missing — `bwa index` for the Illumina arm, `samtools faidx`
for PacBio and ONT — and reused whenever they already sit beside the fasta.

An index built on demand lives in the work dir rather than on the tier, so its
reads come off Lustre either way. That is negligible for these references (a
few MB of index against multi-GB read files) and the build is its own process,
so it never lands inside an alignment's timing. If you ever point this at a
genome large enough for index reads to matter, pre-build on both tiers with
`bwa index` / `samtools faidx` so those reads come off the tier under test.

## Run it on the cluster

Hand the Nextflow driver to SLURM rather than running it in your terminal:

```bash
mkdir -p /mnt/lustre/projects/bioinformatics/runs
cd       /mnt/lustre/projects/bioinformatics/runs   # results/ lands here

PIPELINE=/mnt/gbi-shared/home/cristian-soitu/code/nf/bioinf-tests/data-io/main.nf

sbatch -J nf-io -p cpu -t 2-00:00:00 --wrap="\
  nextflow run $PIPELINE --arm illumina -profile cluster --tier hot --rep 1 -resume"
```

Watch it with `squeue -u $USER` and `tail -f slurm-<jobid>.out`.

### What each part does

| Part | What it does |
|---|---|
| `sbatch` | Submits the job to SLURM and returns. It survives you logging out. |
| `-J nf-io` | Job **name**. This job is only the Nextflow *driver* — it submits and babysits the real work; the tools run as their own jobs. |
| `-p cpu` | **Partition** for the driver. The driver is tiny, so `cpu` is right even for the GPU arms — Dorado and Parabricks request the `gpu` partition themselves. |
| `-t 2-00:00:00` | Walltime. The driver lives as long as the whole run, and ONT sup basecalling takes hours. |
| `nextflow run $PIPELINE` | The shared checkout on Lustre — no credentials, no cached copy to go stale. |
| `--arm illumina` | Which arm of `main.nf` to run. One per run. |
| `-profile cluster` | SLURM executor + Apptainer containers. |
| `--tier hot` | Which storage tier to read. Omit and it defaults to `hot`. |
| `--rep 1` | Repeat number. It only labels the trace file, so `--arm report` can tell reps apart. |
| `--device gpu` | pacbio only: Parabricks instead of minimap2. Top-level, not `--pacbio.device` — see below. |
| `-resume` | Reuse cached tasks after a crash instead of redoing hours of work. |

> **Params are top level on purpose.** A nested `--pacbio.device gpu` does not
> reach values `nextflow.config` derives from it (a top-level `--tier` does),
> so the run label would silently keep saying `cpu` and the GPU run would
> overwrite the CPU run's outputs and trace. Hence `--device`, `--input_type`
> and `--reps` rather than `--pacbio.*` and `--verify.*`.

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

PIPELINE=/mnt/gbi-shared/home/cristian-soitu/code/nf/bioinf-tests/data-io/main.nf
# -resume lives in $NF, so every line below runs with it
NF="nextflow run $PIPELINE -profile cluster -resume"

sbatch -J nf-io -p cpu -t 4-00:00:00 --wrap="
  $NF --arm verify
  for rep in 1 2 3; do
    for tier in hot cold; do
      $NF --arm illumina --tier \$tier --rep \$rep
      $NF --arm pacbio   --tier \$tier --rep \$rep --device cpu
      $NF --arm pacbio   --tier \$tier --rep \$rep --device gpu
      $NF --arm ont      --tier \$tier --rep \$rep
    done
  done
  $NF --arm compare
  $NF --arm report
"
```

### Running the four arms in parallel

One thing has to be right, or parallel runs collide: **each run needs its own
launch directory.** Nextflow keeps its session cache in `.nextflow/` under the
launch dir, and `-resume` resumes *the last session in that directory* — so
four concurrent runs sharing one directory all try to resume the same session
and three die with `Unable to acquire lock on session with ID ...`.

`--results` is therefore an absolute path, so the traces still collect in one
place for `--arm report` despite the separate launch directories.

```bash
cd /mnt/lustre/projects/bioinformatics/runs
RESULTS=$PWD/results

PIPELINE=/mnt/gbi-shared/home/cristian-soitu/code/nf/bioinf-tests/data-io/main.nf
NF="nextflow run $PIPELINE -profile cluster -resume --results $RESULTS"

sbatch -J nf-io -p cpu -t 3-00:00:00 --mem=16G --wrap="
  $NF --arm verify
  for rep in 1 2 3; do
    for tier in hot cold; do
      (mkdir -p par/illumina   && cd par/illumina   && $NF --arm illumina --tier \$tier --rep \$rep) &
      (mkdir -p par/pacbio-cpu && cd par/pacbio-cpu && $NF --arm pacbio --device cpu --tier \$tier --rep \$rep) &
      (mkdir -p par/pacbio-gpu && cd par/pacbio-gpu && $NF --arm pacbio --device gpu --tier \$tier --rep \$rep) &
      (mkdir -p par/ont        && cd par/ont        && $NF --arm ont --tier \$tier --rep \$rep) &
      wait
    done
  done
  $NF --arm compare
  $NF --arm report
"
```

`--mem=16G` because the driver job now runs four JVMs rather than one.

**What it costs you.** Tiers stay serial, so hot and cold still see the same
*set* of workloads — but not the same *timing*, because the arms finish at
different points and the overlap window differs between the two tiers. Two
consequences:

- A slowdown can no longer be attributed to an access pattern. If cold is
  slower with bwa, minimap2 and dorado all reading at once, you cannot tell
  which pattern suffered.
- If the four together saturate the link, every number becomes a share of a
  saturated link rather than a measurement of that workload.

In practice the GPU arms often serialise anyway, since `pacbio --device gpu`
and `ont` both queue for GPUs. The wall-clock saving is large and ONT dominates
the budget, so this is a reasonable trade — but if a ratio comes out marginal,
re-run that cell serially before believing it.

ONT sup basecalling dominates the budget — time one rep before committing to
three.

---

## The order that matters

**`verify` first.** It runs in minutes and can invalidate everything after it.
It reads every input on both tiers, `--reps` times each, then reports:

1. **Cross-rep disagreement** — one file read twice giving two different md5s.
   The bytes on disk cannot have changed, so the read path returned something
   it made up. This is the finding that would explain the corrupted files.
2. **Hot vs cold mismatch** — the tiers are not holding the same bytes, so no
   timing comparison between them means anything.
3. **Failed reads and format checks** (`gzip -t`, `samtools quickcheck`), which
   tell a truncated read from a mangled one.
4. **Throughput** — indicative only. This arm reads both tiers at once, so hot
   and cold tasks compete with each other. The timing evidence is `--arm
   report`, where one tier runs at a time.

```bash
nextflow run $PIPELINE --arm verify -profile cluster -resume

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
- **Published files are hard links, not copies** (`--publish_mode`). Java 21+
  copies with `copy_file_range`, which Lustre answers with `ENODATA` — the task
  succeeds and then the run dies with `Failed to publish file ... No data
  available`. A hard link avoids the syscall, but requires the work dir and the
  destination on the same filesystem. Both are on Lustre by default. If you
  ever publish across filesystems, pass `--publish_mode copy`.
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
