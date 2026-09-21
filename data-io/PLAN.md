# data-io: hot vs cold storage IO benchmark — plan

## Goal

Two questions, in priority order:

1. **Integrity.** Reading directly from Alluxio (cold) produced corrupted files. Is that
   reproducible, is it file-size / read-pattern dependent, and is it intermittent?
2. **Performance.** How much slower is cold (Alluxio) than hot (Lustre) for IO-heavy
   bioinformatics workloads, first-touch vs. repeat read?

Integrity comes first: if reads corrupt nondeterministically, every timing number from
the cold arm is suspect anyway.

## Workloads

| Platform | Tool(s) under test | IO character |
|---|---|---|
| Illumina | `bwa mem` + `samtools sort` (CPU) | many small random reads, large sequential write |
| PacBio HiFi | `minimap2` (CPU) and `pbrun minimap2` (GPU) | large sequential read, GPU host-bandwidth bound |
| ONT | `dorado basecaller` (sup) + `dorado aligner` (GPU) | POD5 chunked read, long-running, heaviest |

## Recommended structure — one project, not two pipelines

You asked whether to write one pipeline per tier. **Recommendation: don't.** Storage tier
is a path difference, so it belongs in a params file, not in a second copy of the code. Two
codebases would drift and any drift confounds the timing comparison — the whole point is
that the two arms run *identical* code.

Instead: **one Nextflow project with four entry scripts and two params files per platform.**

```
data-io/
  PLAN.md
  README.md                  # setup, run commands, how to read results
  paths.txt                  # human-readable notes (existing)
  paths.env                  # the two storage roots, for the bin/ scripts
  nextflow.config            # containers, resources, and the hot/cold profiles
  params.yaml                # ONE params file, one block per entry script
  modules/                   # git submodules, shared by all entries
    bwa/ samtools/ minimap2/ parabricks/ dorado/ utils/
    local/verify/            # the read-integrity probe
    local/samplesheet/       # samplesheet builders (wrap the nf-mod-utils scripts)
  verify.nf                  # Phase 2: pure read-integrity + throughput probe
  illumina.nf                # bwa mem -> index -> flagstat
  pacbio.nf                  # (ubam->fastq) -> minimap2 | pbrun minimap2
  ont.nf                     # dorado basecaller (sup) -> dorado aligner
  bin/
    setup_dirs.sh            # make the test tree on a tier
    make_manifest.sh         # md5 every input on a tier -> manifest CSV
    compare_manifests.sh     # byte-identity gate (just `diff`)
    run.sh                   # run one matrix cell, named and instrumented
    verify_report.sh         # read verify.nf's CSV, answer the integrity question
    compare_bam.sh           # BAM body md5, hot vs cold
    collect_traces.sh        # all traces -> one tidy CSV + summary
  manifests/                 # committed: md5 of every test input, per tier
  results/                   # one directory per run (gitignored)
```

Run shape: `nextflow run illumina.nf -profile cluster,hot -params-file params.yaml`.
The tier is one word on the command line; the pipeline code and the params are
shared. Every path on a tier derives from that tier's single root, set in the
`hot`/`cold` profile, so there is one place to change and nothing to keep in
sync. Samplesheets are generated from each tier's input folders, as `nf-dnaseq`
does from `fastq_dir`, so they cannot drift apart either.

Per-platform entry scripts (rather than one script branching on platform) keeps each main
bare-bones — the three tool chains have nothing in common, so a shared main would be all
`if`.

## Module reuse

All modules already exist as `nf-mod-*` repos. Add them once under `data-io/modules/` as
git submodules; all four entry scripts include from there with relative paths. No new
module code.

| Need | Reuse from |
|---|---|
| `BWA_MEM` | `nf-mod-bwa/mem` (as used by `nf-dnaseq`) |
| `SAMTOOLS_INDEX`, `SAMTOOLS_FLAGSTAT`, `SAMTOOLS_FASTQ` | `nf-mod-samtools` |
| `MINIMAP2_ALIGN` | `nf-mod-minimap2/align` (as used by `nf-dnaseq-long`) |
| `PARABRICKS_MINIMAP2` | `nf-mod-parabricks/minimap2` |
| `DORADO_BASECALLER`, `DORADO_ALIGNER` | `nf-mod-dorado` (as used by `nf-dnaseq-ont`) |
| `refFasta`, `faidxFor`, `bwaIndexFor` | `nf-mod-utils/references` |
| samplesheet parsing (`generate_samplesheet_{short,long}.py`) | `nf-mod-utils/samplesheet`, called from local wrappers |

Two things to know before wiring these up:

- **Two versions of `references.nf` are in circulation.** `nf-dnaseq` has a local copy
  taking `(reference_dir, reference)` explicitly; `nf-dnaseq-ont` and `nf-dnaseq-long` use
  the `nf-mod-utils` one taking `(meta)` and reading `params.reference_dir`. Use the
  `nf-mod-utils` flavour throughout here — it's the submodule, so it needs no copied code.
- **Some modules read params directly**, which fixes those param names. The dorado
  basecaller reads `params.basecalling.model` and `.modified_bases`, and every module's
  `publishDir` reads `params.outdir`. That is why the ONT block in `params.yaml` is called
  `basecalling` rather than `ont`.
- **`minimap2`/`parabricks`/`dorado` have no `conf/module.config`** in the repos that use
  them; those pipelines pin the image inline in `nextflow.config`. Do the same here rather
  than inventing module configs.

Only new code: four short `main`s, the configs, and the `bin/` shell helpers. New
processes: `VERIFY_READ`, and three thin samplesheet wrappers - two of which just run the
`nf-mod-utils` python scripts, while the ONT one handles POD5 directories that neither
script covers.

## Phase 0 — make paths.txt machine-readable

`data-io/paths.txt` isn't valid shell: `HOT-STORAGE-DIR` can't be a shell variable, and
`${HOT-STORAGE-DIR}` actually parses as `${HOT}` with a `-STORAGE-DIR` default, so it
expands to the wrong thing silently. Convert to `paths.env` with underscore names
(`HOT_STORAGE_DIR`, `INPUT_ONT_DIR_HOT`, ...), keep `paths.txt` as the human-readable
notes, and let the params YAMLs carry the same paths for Nextflow. The `mkdir -p` lines
move into a `bin/setup_dirs.sh`.

## Phase 1 — data staging and byte-identity gate

The comparison is only meaningful if both tiers hold the same bytes.

1. `bin/make_manifest.sh hot` and `... cold` — walk each platform's input dir plus the
   reference and its index files, emit `manifests/{tier}.csv` with `path,size,md5`.
2. `bin/compare_manifests.sh` — join on path-relative-to-tier-root, fail loudly on any
   size or md5 mismatch.
3. Samplesheets need no attention: each entry script builds its own from that tier's
   input folder. Only the folder layout matters (see README).
4. Confirm the references are pre-indexed **on both tiers** (`.fai` for all three; `.amb
   .ann .bwt .pac .sa` for the Illumina reference). Index building is not part of the test
   and must not run inside a timed pipeline.

If step 2 already fails, the corruption is at rest / in staging, not in the read path, and
the investigation changes shape — that's a useful early answer either way. Run the cold
manifest twice: **same file, two different md5s across runs is the smoking gun** for
read-path corruption.

## Phase 2 — `verify.nf`: integrity and raw throughput, no tools

A single-process pipeline that isolates the filesystem from every tool confound.

- One `CHECKSUM` task per input file: `md5sum` the file, record elapsed time and bytes,
  so throughput comes out as MB/s.
- `--reps N` re-reads each file N times as separate tasks, so intermittent corruption
  shows up as a checksum that disagrees between reps.
- Checksums are compared against `manifests/{tier}.csv`, so any mismatch names the file.
- Emits one CSV: `file,tier,rep,bytes,seconds,md5,md5_matches_manifest`.

This is cheap, runs in minutes, and is where the Alluxio corruption question actually gets
answered. Run it on the same node types the real pipelines use (including the GPU
partition) — mounts and network can differ per partition.

Also worth adding here, because it distinguishes the likely failure modes cheaply:
`gzip -t` on every `fastq.gz` and `samtools quickcheck` on every uBAM. A truncated-read bug
and a silently-mangled-bytes bug look different under those.

## Phase 3 — the three workload pipelines

Deliberately minimal: no trimming, no QC beyond `flagstat`, no variant calling, no
coverage tracks. Every extra process adds noise to the IO measurement.

**`illumina.nf`** — samplesheet (`sample,R1,R2,reference`) → `BWA_MEM` → `SAMTOOLS_INDEX`
→ `SAMTOOLS_FLAGSTAT`. Reads go straight to `bwa` untrimmed; `fastp` would rewrite the
FASTQs into the work dir and hide the source filesystem behind a local copy.

**`pacbio.nf`** — samplesheet (`sample,reads,reference`). Input is HiFi uBAM, so
`SAMTOOLS_FASTQ` first (gate behind `--input_type ubam|fastq`, as `nf-dnaseq-long` does),
then `--device cpu` → `MINIMAP2_ALIGN` or `--device gpu` → `PARABRICKS_MINIMAP2`, then
`SAMTOOLS_FLAGSTAT`. No `chopper`, for the same reason `fastp` is skipped above. `meta`
needs `platform: 'pacbio-hifi'` and `preset: 'map-hifi'` — both modules read them.

**`ont.nf`** — samplesheet (`sample,reads,reference`) where `reads` is a POD5 file or dir
→ `DORADO_BASECALLER` (sup model, `--modified_bases ''` to keep it to one variable) →
`DORADO_ALIGNER` → `SAMTOOLS_FLAGSTAT`. This is the long pole; expect hours per rep, so
size the ONT sample set with that in mind.

Publishing: the existing modules already carry `publishDir "${params.outdir}/..."`, so
just set `params.outdir` per tier. No `output {}` block needed — keeps these mains shorter
than `nf-dnaseq`'s.

## Phase 4 — running the matrix fairly

This is where an IO benchmark usually goes wrong. Controls:

- **Work dir on the tier under test.** Derived from the tier's root in
  `nextflow.config`. Nextflow symlinks inputs into the work dir rather than copying, so
  the tool reads through the source filesystem either way — but *outputs* are written to
  the work dir, and write performance is half of what you're measuring. Keep read and
  write on the same tier so each arm is a true end-to-end test of that tier.
  *(If you'd rather isolate read performance alone, point `workDir` at Lustre for both
  arms and run that as a separate, clearly-labelled sweep. Don't mix the two in one
  table. Not implemented — it is open decision 1 below.)*
- **Bind mounts.** `nf-dnaseq-ont` binds `/mnt/instrument-data`; here the `cluster`
  profile binds both `/mnt/lustre` and `/mnt/user-data` in both tiers. Binding only the
  input tier is enough for the end-to-end runs but breaks the moment the work dir sits on
  the other tier, and it fails in a way that looks like an IO error.
- **Page cache and Alluxio cache.** Alluxio caches on first read, so first-touch and
  repeat-read are genuinely different numbers and both matter. Report them separately:
  rep 1 = first touch, reps 2–3 = warm. Drop caches between first-touch reps if you can,
  or use a distinct file set per first-touch measurement.
- **Alternate tier order** (hot, cold, cold, hot, ...) so cluster load drifts don't land
  entirely on one arm.
- **Pin the node type.** Same partition and, if possible, `clusterOptions` constraining to
  one node class for every run in a comparison. GPU-partition nodes may mount storage
  differently from CPU nodes — a real confound for the Parabricks and Dorado arms.
- **No `-resume`**, fresh work dir per run, unique `-name` per run.
- 3 reps per cell. Matrix: `3 platforms × 2 tiers × {cpu,gpu where applicable} × 3 reps`
  = 24 pipeline runs (Illumina CPU-only, PacBio both devices, ONT GPU-only), plus the
  `verify.nf` sweeps.

Instrumentation is handled by `bin/run.sh`, which passes `-with-trace`, `-with-report`
and `-with-timeline` into that run's own results directory and records total wall clock
(Nextflow's startup and staging are part of the user experience and are not in the trace).
The trace gives per-task `realtime`, `%cpu`, `rchar`/`wchar`, `read_bytes`/`write_bytes`,
`syscr`/`syscw` — enough to compute effective MB/s per process and to tell "slow because
IO" from "slow because it waited". It is written with `raw = true`, so durations are plain
milliseconds and sizes plain bytes; that is what keeps `collect_traces.sh` short instead
of parsing `"2m 30s"` and `"1.2 GB"` back into numbers.

## Phase 5 — output integrity and reporting

- `bin/compare_bam.sh` — for each sample, compare the hot and cold BAM by **body**
  (`samtools view <bam> | md5sum`), not by file md5: the `@PG` header records the command
  line, which contains tier-specific paths and will always differ. Plus a `flagstat` diff
  as a human-readable cross-check. Identical bodies across tiers is the strong statement
  that cold reads are trustworthy under real load.
- `bin/collect_traces.sh` — all trace files → one tidy CSV
  (`run_id,workload,tier,device,rep,run_ok,process,sample,realtime_s,cpu_pct,read_mb,write_mb,read_mb_per_s`),
  joined to each run's `run.meta` so one row is one task with its tier and rep attached.
- `README.md` — the run matrix as copy-pasteable commands, and a results table:
  per platform/process, hot vs cold median realtime, ratio, and effective MB/s, with
  first-touch and warm split out.

## Open decisions

1. **Work dir placement** — currently end-to-end: the work dir follows the tier, so reads
   and writes are both measured. The alternative is read-only isolation (work dir always on
   Lustre). Changing it is a one-line edit in `nextflow.config`, but those runs need their
   own results table.
2. **Sample sizes** — ONT sup basecalling dominates the runtime budget. If a rep is over
   ~4h, drop to 1–2 reps for ONT and keep 3 for the others.
3. **Illumina GPU arm** — you specified `bwa` only, so `parabricks fq2bam` is out. It'd be
   a cheap addition (`--device gpu`, module already in `nf-dnaseq`) and would make the
   Illumina row comparable to PacBio's CPU/GPU pair. Say if you want it.
4. **Whether `verify.nf` should also run as a plain sbatch array** rather than Nextflow,
   to remove Nextflow's own staging from the integrity probe entirely. Nextflow stages
   inputs as symlinks, so the read already goes through the tier under test rather than a
   local copy — but an sbatch array would remove the question altogether.

## Suggested order of work

Phase 0 → 1 → 2 (stop and look: the corruption question may be answered here) → 3 → 4 → 5.
