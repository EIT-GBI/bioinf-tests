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
<root>/tests/data-io/input/{illumina,pacbio,ont}/     reads you stage
<root>/tests/data-io/output/                          published results
<root>/tests/data-io/work/                            nextflow work dir
<root>/references/                                    references + indexes
```

---

## Setup

```bash
git clone --recursive https://github.com/EIT-GBI/bioinf-tests.git
# already cloned?
git submodule update --init --recursive
```

> **Pulling later?** `git pull` moves this repo's *pointer* to each module but
> not the module itself, so you can end up running old module code with no
> error to tell you. Always follow a pull with:
>
> ```bash
> git submodule update --init --recursive
> ```

Then stage the reads into `<root>/tests/data-io/input/<platform>/` on both
tiers. That is the whole setup — samplesheets are built from the folders.

| Arm | Expected layout | Sample name |
|---|---|---|
| Illumina | `<sample>_R1.fastq.gz` + `<sample>_R2.fastq.gz` | before `_R1` |
| PacBio | one file per sample: `<sample>.bam` (HiFi uBAM), or FASTQ | filename minus suffix |
| ONT | one **directory** of POD5s per sample, `input/ont/<sample>/` | directory name |
| ONT (alt) | flat `input/ont/<sample>.pod5` files | basename |

References must already be indexed **on both tiers** (`.amb .ann .bwt .pac .sa`
for Illumina, `.fai` for all three). Index building is not part of the
measurement and no timed arm does it.

---

## Run it on the cluster

Hand the Nextflow driver to SLURM rather than running it in your terminal:

```bash
cd /path/to/bioinf-tests/data-io

sbatch -J nf-io -p cpu -t 2-00:00:00 \
  --wrap="nextflow run main.nf -entry illumina -profile cluster --tier hot --rep 1"
```

Watch it with `squeue -u $USER` and `tail -f slurm-<jobid>.out`.

### What each part does

| Part | What it does |
|---|---|
| `sbatch` | Submits the job to SLURM and returns. It survives you logging out. |
| `-J nf-io` | Job **name**. This job is only the Nextflow *driver* — it submits and babysits the real work; the tools run as their own jobs. |
| `-p cpu` | **Partition** for the driver. The driver is tiny, so `cpu` is right even for the GPU arms — Dorado and Parabricks request the `gpu` partition themselves. |
| `-t 2-00:00:00` | Walltime. The driver lives as long as the whole run, and ONT sup basecalling takes hours. |
| `-entry illumina` | Which arm of `main.nf` to run. It takes one name. |
| `-profile cluster` | SLURM executor + Apptainer containers. |
| `--tier hot` | Which storage tier to read. Omit and it defaults to `hot`. |
| `--rep 1` | Repeat number. It only labels the trace file, so `-entry report` can tell reps apart. |

> **No `-resume`, ever.** Unlike `nf-dnaseq`, a resumed run would reuse cached
> task output and report a cache hit as a fast IO measurement.

### The whole matrix in one submission

One `sbatch`, everything sequential in the background:

```bash
sbatch -J nf-io -p cpu -t 7-00:00:00 --wrap='
  nextflow run main.nf -entry verify -profile cluster
  for rep in 1 2 3; do
    for tier in hot cold; do
      nextflow run main.nf -entry illumina -profile cluster --tier $tier --rep $rep
      nextflow run main.nf -entry pacbio   -profile cluster --tier $tier --rep $rep --pacbio.device cpu
      nextflow run main.nf -entry pacbio   -profile cluster --tier $tier --rep $rep --pacbio.device gpu
      nextflow run main.nf -entry ont      -profile cluster --tier $tier --rep $rep
    done
  done
  nextflow run main.nf -entry compare -profile cluster
  nextflow run main.nf -entry report  -profile cluster
'
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
nextflow run main.nf -entry verify -profile cluster
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
- **The work dir lives on the tier under test**, so reads *and* writes go
  through it and each arm is measured end to end. To isolate read performance
  instead, point `workDir` at Lustre for both tiers in `nextflow.config` and
  report those runs separately.
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
