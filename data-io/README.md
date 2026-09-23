# data-io — hot vs cold storage IO benchmark

Comparing **hot (Lustre)** against **cold (Alluxio)** for IO-heavy bioinformatics
workloads, and checking whether cold returns intact bytes.

Reading directly from Alluxio once produced corrupted files. That is the first
question; the timing comparison is the second, and it only means something once
the first is answered.

---

## One command

```bash
nextflow run <checkout>/data-io/main.nf --arm <arm> -profile cluster -resume
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

**Reads** come from `--tier` (the storage under test). **Everything written** —
work dir and results — goes to `--out_tier`, which defaults to **cold**.

```
<tier root>/tests/data-io/input/<platform>/     reads you stage
<tier root>/references/                         reference fastas

<out root>/tests/data-io/work/                  nextflow work dir
<out root>/tests/data-io/results/               one folder per run:
    hot-illumina/  cold-illumina/
    hot-pacbio-cpu/  cold-pacbio-gpu/  ...
    verify/  summary/
```

The read tier is in the folder name, so hot and cold runs sit side by side in
one tree. Nothing is written to the directory you launch from.

Each run folder holds exactly:

```
trace.txt  report.html  timeline.html    what the run did
samplesheet.csv                          what it ran on
alignment/  qc/  index/                  what it produced
```

Re-running an arm overwrites its own folder rather than leaving a dated copy, so
the tree stays the size of the matrix.

## Parameters

| Param | Default | Meaning |
|---|---|---|
| `--arm` | — | which arm to run |
| `--tier` | `hot` | storage that is **read** — the thing under test |
| `--out_tier` | `cold` | storage that is **written** — work dir and results |
| `--device` | `cpu` | pacbio only: `gpu` uses Parabricks |
| `--reps` | `1` | verify only: read every file this many times |
| `--hot_root` / `--cold_root` | see config | the two storage roots |
| `--ref_illumina` / `--ref_pacbio` / `--ref_ont` | see config | reference fasta, relative to `<root>/references/` |

All top level on purpose: a nested `--a.b` does not reach values the config
derives from it, so a wrong one would be silently ignored.

---

## Setup

```bash
git clone --recursive git@github.com:EIT-GBI/bioinf-tests.git \
  /mnt/gbi-shared/home/cristian-soitu/code/nf/bioinf-tests
```

`--recursive` matters: the tool modules are git submodules and three are
private. This is the only step that touches GitHub; nothing afterwards needs
credentials. Update with `git pull --recurse-submodules` in that directory.

Stage the reads into `<root>/tests/data-io/input/<platform>/` on both tiers:

| Arm | Layout | Sample name |
|---|---|---|
| Illumina | `<sample>_R1.fastq.gz` + `_R2` | before `_R1` |
| PacBio | one file per sample: `.bam` (HiFi uBAM) or FASTQ | filename minus suffix |
| ONT | a directory of POD5s per sample, `input/ont/<sample>/` | directory name |
| ONT (alt) | flat `input/ont/<sample>.pod5` | basename |

Only the reference **fasta** has to exist. `bwa index` and `samtools faidx` run
automatically when their output is missing, and are reused when it is not.

## Running it

```bash
cd /mnt/lustre/projects/bioinformatics/runs      # anywhere; nothing is written here
PIPELINE=/mnt/gbi-shared/home/cristian-soitu/code/nf/bioinf-tests/data-io/main.nf
NF="nextflow run $PIPELINE -profile cluster -resume"

sbatch -J nf-io -p cpu -t 4-00:00:00 --wrap="
  $NF --arm verify
  for tier in hot cold; do
    $NF --arm illumina --tier \$tier
    $NF --arm pacbio   --tier \$tier --device cpu
    $NF --arm pacbio   --tier \$tier --device gpu
    $NF --arm ont      --tier \$tier
  done
  $NF --arm summary
"
```

Nine runs. ONT dominates the budget — time one before committing to the rest.

To run arms concurrently, give each its own launch directory: Nextflow keeps its
session cache in `.nextflow/` under the launch dir, so concurrent runs sharing
one directory all try to resume the same session and all but one die with
`Unable to acquire lock on session`.

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
- **First touch vs warm.** Alluxio caches on first read, so a `verify` run warms
  everything it touches. A workload arm run afterwards measures a warm cache.
- **Published files are hard links.** Java 21+ copies with `copy_file_range`,
  which Lustre answers with `ENODATA`. The work dir and results are on the same
  tier, so linking works and costs nothing.

## Results

_To be filled in._

| arm | hot | cold | ratio | notes |
|---|---|---|---|---|
| | | | | |
