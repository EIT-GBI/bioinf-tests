# data-io — hot vs cold storage IO benchmark

Comparing **hot (Lustre)** against **cold (Alluxio)** for IO-heavy
bioinformatics workloads, and checking whether cold returns intact bytes.

Reading directly from Alluxio has produced corrupted files. That is the first
question here. The timing comparison is the second, and it is not meaningful
until the first is answered.

See [PLAN.md](PLAN.md) for the reasoning behind the design.

---

## What's here

```
verify.nf      read integrity + raw throughput, no tools       Phase 2
illumina.nf    bwa mem -> index -> flagstat                    Phase 3
pacbio.nf      (ubam->fastq) -> minimap2 | pbrun minimap2      Phase 3
ont.nf         dorado basecaller (sup) -> dorado aligner       Phase 3

nextflow.config   one config; the storage tier is a profile
params.yaml       one params file, one block per entry script
paths.env         the same two storage roots, for the bin/ scripts
modules/          nf-mod-* submodules + modules/local/{verify,samplesheet}
bin/              setup, manifests, the run driver, the collectors
manifests/        md5 of every test input, per tier (committed)
results/          one directory per run (gitignored)
```

**One project, not one pipeline per tier.** The tier is a profile, so both arms
run byte-identical code. Two copies would drift, and drift confounds the
comparison. Every path on a tier derives from that tier's single root in
`nextflow.config`.

All tool code is reused from the existing `nf-mod-*` repos as submodules — the
same `bwa`, `samtools`, `minimap2`, `parabricks` and `dorado` modules that
`nf-dnaseq`, `nf-dnaseq-long` and `nf-dnaseq-ont` use. The only new process is
`VERIFY_READ`.

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

Then stage the data:

```bash
cd data-io
./bin/setup_dirs.sh hot
./bin/setup_dirs.sh cold
# ... copy reads into <root>/tests/data-io/input/{illumina,pacbio,ont}/ ...
```

That is the whole setup. **Samplesheets are built from the folders**, so there
is nothing to write by hand.

References must already be indexed **on both tiers** (`.amb .ann .bwt .pac .sa`
for Illumina, `.fai` for all three). Index building is not part of the
measurement and no timed pipeline does it.

## Samplesheets are generated

Each entry script scans its platform's input folder and writes the samplesheet
to `<outdir>/samplesheet/samplesheet.csv`, the way `nf-dnaseq` builds one from
`fastq_dir`. Neither tier's sheet is maintained by hand, so the two arms cannot
drift apart — each derives its paths from its own input folder.

| Arm | Expected layout | Sample name |
|---|---|---|
| Illumina | `<sample>_R1.fastq.gz` + `<sample>_R2.fastq.gz` (also `.fq.gz`, `.fastq`, `.fq`, optional `_001`) | before `_R1` |
| PacBio | one file per sample: `<sample>.bam` (HiFi uBAM), or FASTQ | filename minus the suffix |
| ONT | one **directory** of POD5s per sample, `input/ont/<sample>/` | directory name |
| ONT (alt) | flat `input/ont/<sample>.pod5` files | basename |

For ONT, per-sample directories win when both layouts are present.

The parsing comes from `nf-mod-utils`' `generate_samplesheet_short.py` and
`generate_samplesheet_long.py`, passed into thin local wrappers in
`modules/local/samplesheet/`. POD5 gets its own builder there, since the
long-read script globs FASTQ/BAM suffixes and only ever emits files, while
`dorado basecaller` takes a whole directory.

Each platform's reference is set once in `params.yaml` under `references:`, and
lands in the generated sheet's `reference` column.

To use a sheet you wrote yourself instead:

```bash
./bin/run.sh illumina hot 1 -- --samplesheet /path/to/sheet.csv
```

---

## TLDR: run it on the cluster

Everything goes through `bin/run.sh`, which names the run, gives it a fresh work
dir, and puts the trace, report and timeline in `results/<run-id>/`.

```bash
./bin/run.sh <verify|illumina|pacbio|ont> <hot|cold> [rep] [cpu|gpu]
```

Hand the Nextflow driver to SLURM rather than running it in your terminal:

```bash
cd /path/to/bioinf-tests/data-io

sbatch -J nf-io -p cpu -t 2-00:00:00 \
  --wrap="./bin/run.sh illumina hot 1"
```

Watch it with `squeue -u $USER`, and read the driver's log with
`tail -f slurm-<jobid>.out`.

### What each part does

| Part | What it does |
|---|---|
| `sbatch` | Submits the job to SLURM and returns. The job survives you logging out. |
| `-J nf-io` | Job **name**. This job is only the Nextflow *driver* — it submits and babysits the real work; the tools run as their own jobs. |
| `-p cpu` | **Partition** for the driver. The driver is tiny, so `cpu` is right even for the GPU arms — the Dorado and Parabricks steps request the `gpu` partition themselves. |
| `-t 2-00:00:00` | Walltime. The driver lives as long as the whole run, and ONT sup basecalling takes hours. |
| `--wrap="..."` | Runs this command instead of writing a `#SBATCH` script file. |
| `./bin/run.sh illumina hot 1` | Workload, tier, rep. The wrapper builds the `nextflow run` command — set `DRY_RUN=1` to see it without running. |

Anything after `--` is passed through to Nextflow, so `-- --samplesheet <file>`
overrides the generated one.

> **No `-resume`, ever.** Unlike `nf-dnaseq`, a resumed run here would reuse
> cached task output and report a cache hit as a fast IO measurement. `run.sh`
> never passes it, and every run gets a fresh work dir for the same reason.

### Alternative: a tmux session

For the quick Phase 2 probe, where you want to watch it live:

```bash
tmux new -s io
./bin/run.sh verify cold
```

Detach with `Ctrl-b` then `d`, come back with `tmux attach -t io`.

### Running Nextflow directly

`run.sh` is a convenience, not a requirement:

```bash
nextflow run illumina.nf -profile cluster,hot -params-file params.yaml
```

You then lose the run naming, the fresh work dir and the per-run output
directory, so the CPU and GPU arms will overwrite each other's BAMs.

---

## Order of work

Do not skip ahead — Phase 2 can invalidate everything after it.

### Phase 1 — prove both tiers hold the same bytes

```bash
./bin/make_manifest.sh hot
./bin/make_manifest.sh cold
./bin/compare_manifests.sh          # must PASS before anything is timed
```

**Then run the cold manifest twice and compare it against itself:**

```bash
./bin/make_manifest.sh cold manifests/cold.run2.csv
./bin/compare_manifests.sh manifests/cold.csv manifests/cold.run2.csv
```

The bytes on disk cannot change between those two runs. If the checksums
differ, the read path is inventing data — that is the answer, and the timings
can wait.

### Phase 2 — read integrity and raw throughput

```bash
./bin/run.sh verify hot
./bin/run.sh verify cold

./bin/verify_report.sh <root>/tests/data-io/output/verify/rep1/verify-cold.csv
```

Each file is read `verify.reps` times as separate tasks. The report gives
cross-rep checksum disagreement first (read-path corruption), then failed reads
and format checks, then throughput.

Run it on **every partition the workloads use, the GPU queue included** —
mounts can differ per partition, so a clean CPU-queue result does not cover the
Dorado and Parabricks arms.

### Phase 3/4 — the workload matrix

24 runs. Alternate the tier order between reps so cluster load drift does not
land on one arm:

```bash
for rep in 1 2 3; do
  for tier in hot cold; do
    ./bin/run.sh illumina $tier $rep
    ./bin/run.sh pacbio   $tier $rep cpu
    ./bin/run.sh pacbio   $tier $rep gpu
    ./bin/run.sh ont      $tier $rep
  done
done
```

ONT sup basecalling dominates the budget. Time one rep before launching the
loop, and drop ONT to 1–2 reps if a rep runs over ~4h.

### Phase 5 — results

```bash
./bin/compare_bam.sh illumina cpu 1
./bin/compare_bam.sh pacbio gpu 1
./bin/collect_traces.sh              # -> results/all_tasks.csv + summary
```

`compare_bam.sh` compares the BAM **body** (`samtools view | md5sum`), not the
file: the `@PG` header records the command line, which contains tier-specific
paths, so whole-file checksums always differ and say nothing. If samtools is not
on your PATH, the script prints the `apptainer exec` line to use.

---

## Reading the numbers

- **`ratio > 1` means cold is slower.**
- **First touch vs warm are different numbers, and both matter.** Alluxio caches
  on first read, so rep 1 is the cache-miss case. Treat that as a label to
  check rather than a fact: dropping caches needs root, and anything that
  touched the files first — `make_manifest.sh` included — warms them. For a
  genuine first-touch number, use a file set nothing has read yet.
- **`read_mb_per_s`** comes from the trace's `read_bytes` over `realtime`.
  Together with `cpu_pct` it separates "slow because IO" from "slow because it
  waited".
- **Failed runs are kept** and flagged `run_ok=no`, excluded from the summary. A
  run that fails on cold and succeeds on hot is a result, not missing data.
- The summary prints **means** over few reps. Use `results/all_tasks.csv` for
  anything more careful.

---

## Things that will bite you

- **The work dir lives on the tier under test**, so reads *and writes* go
  through it — each arm is measured end to end. To isolate read performance
  instead, point `workDir` at Lustre for both tiers in `nextflow.config` and
  report those runs in their own table. (PLAN.md open decision 1.)
- **GPU nodes may mount storage differently from CPU nodes.** A real confound
  for the Parabricks and Dorado arms. Pin the node class with `clusterOptions`
  across a comparison.
- **`WARN: There's no process matching config selector: ...`** on every run is
  expected: one config serves four entry scripts.
- **The samplesheet builders have no `stub:` block on purpose**, so they run for
  real even under `-stub-run`. Building a samplesheet is cheap, and a stub run
  that skipped it would fail at the next operator with `Missing 'header' in CSV
  file` — which is exactly what `nf-mod-utils`' own `PREPARE_SAMPLESHEET_*`
  stubs do, and why this repo wraps them locally instead of calling them.
- **PacBio sample names keep the read-type suffix**: `pbA.hifi_reads.bam`
  becomes sample `pbA.hifi_reads`, because the reused long-read script strips
  only `.bam`. Harmless, but it is what appears in the BAM names and the
  results table.
- **No trimming or filtering** (`fastp`, `chopper`) anywhere, deliberately.
  Those rewrite reads into the work dir, and everything downstream would then
  read Nextflow's local copy instead of the filesystem under test.
  `SAMTOOLS_FASTQ` in `pacbio.nf` is the one exception, because HiFi uBAM needs
  converting — it stays in the timed pipeline and is reported as its own
  process.

---

## Results

_To be filled in once the matrix has run._

| workload | process | device | hot (s) | cold (s) | ratio | notes |
|---|---|---|---|---|---|---|
| | | | | | | |
