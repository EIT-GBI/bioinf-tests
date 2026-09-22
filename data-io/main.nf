#!/usr/bin/env nextflow

// ---------------------------------------------------------------------------
// data-io - hot (Lustre) vs cold (Alluxio) storage IO benchmark
// ---------------------------------------------------------------------------
//   nextflow run main.nf -entry verify                  # both tiers, integrity
//   nextflow run main.nf -entry illumina --tier hot
//   nextflow run main.nf -entry pacbio   --tier cold --pacbio.device gpu
//   nextflow run main.nf -entry ont      --tier hot
//   nextflow run main.nf -entry compare                 # hot vs cold outputs
//   nextflow run main.nf -entry report                  # timing table
//
// Nothing to run before or after: stage the reads into
// <root>/tests/data-io/input/<platform>/ and each arm builds its own
// samplesheet, writes its own trace, and reports its own result.
//
// ONE WORKLOAD ARM PER RUN, deliberately. The arms have no dependency on each
// other and could run together, but different workloads reading at once would
// measure "three workloads saturating this filesystem" rather than "how fast
// this filesystem serves bwa", and a slowdown could not be attributed to an
// access pattern. Within an arm, samples fan out exactly as in a normal run -
// tens of tasks at once, as many as SLURM grants - because that concurrency is
// the realistic condition.
//
// The tier is a parameter, never a second copy of the code: both arms must run
// byte-identical code or code drift confounds the comparison.
// ---------------------------------------------------------------------------

include { PREPARE_SAMPLESHEET_ILLUMINA } from './modules/local/processes.nf'
include { PREPARE_SAMPLESHEET_PACBIO }   from './modules/local/processes.nf'
include { PREPARE_SAMPLESHEET_ONT }      from './modules/local/processes.nf'
include { VERIFY_READ; VERIFY_REPORT }   from './modules/local/processes.nf'
include { COMPARE_BAM; TIMING_REPORT }   from './modules/local/processes.nf'

include { BWA_MEM }             from './modules/bwa/mem/main.nf'
include { MINIMAP2_ALIGN }      from './modules/minimap2/align/main.nf'
include { PARABRICKS_MINIMAP2 } from './modules/parabricks/minimap2/main.nf'
include { DORADO_BASECALLER }   from './modules/dorado/basecaller/main.nf'
include { DORADO_ALIGNER }      from './modules/dorado/aligner/main.nf'
include { SAMTOOLS_FASTQ }      from './modules/samtools/fastq/main.nf'
include { SAMTOOLS_INDEX }      from './modules/samtools/index/main.nf'
include { SAMTOOLS_FLAGSTAT }   from './modules/samtools/flagstat/main.nf'

include { bwaIndexFor; faidxFor } from './modules/utils/references/references.nf'


// Rows shared by all three workload samplesheets. A '#' row is dropped because
// CSV has no comment syntax, so such a line would become a sample named "# ...".
def readSamplesheet(samplesheet_ch) {
    samplesheet_ch
        .splitCsv(header: true)
        .filter { row -> row.sample && !row.sample.startsWith('#') }
}

// Where a tier keeps its inputs and its published results
def inputDir(tier)  { "${tier == 'cold' ? params.cold_root : params.hot_root}/${params.test_subdir}/input"  }
def outputDir(tier) { "${tier == 'cold' ? params.cold_root : params.hot_root}/${params.test_subdir}/output" }


// ---------------------------------------------------------------------------
// No -entry given
// ---------------------------------------------------------------------------
// Nextflow's own message here is just "No entry workflow specified", which does
// not say what the choices are.
workflow {
    error """
    Pick an arm with -entry:

      nextflow run main.nf -entry verify   -profile cluster                  both tiers, integrity
      nextflow run main.nf -entry illumina -profile cluster --tier hot       bwa mem
      nextflow run main.nf -entry pacbio   -profile cluster --tier hot       minimap2 (--pacbio.device gpu for Parabricks)
      nextflow run main.nf -entry ont      -profile cluster --tier hot       dorado sup
      nextflow run main.nf -entry compare  -profile cluster                  hot vs cold BAM bodies
      nextflow run main.nf -entry report   -profile cluster                  timing table

    One arm per run, on purpose - see the header of this file and README.md.
    To submit the whole matrix as a single job, see "The whole matrix in one
    submission" in README.md.
    """.stripIndent()
}


// ---------------------------------------------------------------------------
// verify - read integrity and raw throughput, both tiers, no tools
// ---------------------------------------------------------------------------
// This is where the "Alluxio gave corrupted files" question gets answered, and
// it runs in minutes rather than hours. Every input file on BOTH tiers is read
// end to end, checksummed and timed, params.verify.reps times over.
//
// Reading both tiers in one run is what removes the old manifest dance: the
// cross-rep and hot-vs-cold comparisons both happen in VERIFY_REPORT, with no
// intermediate files to build, name or keep in step.
//
// Run it on every partition the workload arms use, the GPU one included:
// mounts can differ per partition, so a clean CPU-queue result does not cover
// the Dorado and Parabricks arms.
workflow verify {

    // Resolved eagerly rather than inside a channel operator, so an empty or
    // mistyped tier root fails here instead of producing a run that succeeds
    // with nothing in it. A benchmark that silently measures zero files is
    // worse than one that stops.
    def files = ['hot', 'cold'].collectMany { tier ->
        def base = inputDir(tier)
        files("${base}/**", type: 'file').collect { f ->
            tuple(tier, f.toString() - "${base}/", f)
        }
    }

    if (!files) {
        error """No input files found on either tier.
        |  hot : ${inputDir('hot')}
        |  cold: ${inputDir('cold')}
        |Stage the reads there first, or correct --hot_root / --cold_root.""".stripMargin()
    }

    // tuple(tier, path relative to that tier's input dir, file)
    files_ch = channel.fromList(files)

    // One task per (tier, file, rep). `rep` rides in meta, which is a val
    // input, so each rep hashes differently and genuinely re-reads the file
    // rather than being collapsed into one task.
    VERIFY_READ(
        files_ch
            .combine(channel.of(1..params.verify.reps))
            .map { tier, rel, f, rep -> tuple([tier: tier, rel: rel, rep: rep], f) }
    )

    // Sorted so the two tiers' rows sit next to each other in the CSV
    csv_ch = VERIFY_READ.out.row.collectFile(
        name:     'verify.csv',
        storeDir: params.results,
        seed:     'tier,rep,rel,bytes,seconds,mb_per_s,md5,check_type,check_ok\n',
        sort:     true,
    )

    VERIFY_REPORT(
        file("${projectDir}/modules/local/verify_report.py", checkIfExists: true),
        csv_ch
    )
}


// ---------------------------------------------------------------------------
// illumina - bwa mem
// ---------------------------------------------------------------------------
// IO character: many small random reads against the bwa index, one large
// sequential write for the sorted BAM.
//
// Deliberately minimal. No fastp, no fastqc, no variant calling: fastp would
// rewrite both FASTQs into the work dir, and everything downstream would then
// read Nextflow's local copy rather than the filesystem under test - exactly
// the thing being measured.
//
// The reference must already be bwa-indexed on both tiers. bwaIndexFor() uses
// checkIfExists, so a missing index fails in seconds rather than after an hour
// of alignment - and index building is not part of the measurement.
workflow illumina {

    if (params.samplesheet) {
        samplesheet_ch = channel.fromPath(params.samplesheet, checkIfExists: true)
    }
    else {
        PREPARE_SAMPLESHEET_ILLUMINA(
            file("${projectDir}/modules/utils/samplesheet/generate_samplesheet_short.py", checkIfExists: true),
            file("${params.input_dir}/illumina", checkIfExists: true),
            params.references.illumina
        )
        samplesheet_ch = PREPARE_SAMPLESHEET_ILLUMINA.out.csv
    }

    reads_ch = readSamplesheet(samplesheet_ch)
        .map { row ->
            def meta = [id: row.sample, reference: row.reference]
            tuple(meta, file(row.R1, checkIfExists: true), file(row.R2, checkIfExists: true))
        }

    aln_in = reads_ch.multiMap { meta, r1, r2 ->
        reads: tuple(meta, r1, r2)
        index: bwaIndexFor(meta)
    }

    // BWA_MEM emits tuple(meta, bam) only, so index it to get a .bai. That
    // index step is also a second, smaller read of the BAM just written, which
    // is a realistic part of the IO profile.
    BWA_MEM(aln_in.reads, aln_in.index)
    SAMTOOLS_INDEX(BWA_MEM.out.bam)

    // The only QC kept: cheap, and read counts are how the hot and cold
    // outputs get compared afterwards.
    SAMTOOLS_FLAGSTAT(SAMTOOLS_INDEX.out.bam.map { meta, bam, _bai -> tuple(meta, bam) })
}


// ---------------------------------------------------------------------------
// pacbio - minimap2 (CPU) or pbrun minimap2 (GPU)
// ---------------------------------------------------------------------------
// IO character: large sequential reads. The GPU arm is often bound by host
// bandwidth rather than by the GPU, which makes it the more revealing of the
// two for a storage comparison.
//
// No chopper filtering, for the same reason the illumina arm skips fastp.
// SAMTOOLS_FASTQ is the exception, and only because HiFi reads arrive as uBAM
// and neither aligner takes one. It is genuine IO for this workload, so it
// stays in the timed pipeline as its own process rather than a prep step.
workflow pacbio {

    if (!(params.pacbio.device in ['cpu', 'gpu'])) {
        error "Invalid params.pacbio.device: ${params.pacbio.device}. Use 'cpu' (minimap2) or 'gpu' (Parabricks)."
    }
    if (!(params.pacbio.input_type in ['ubam', 'fastq'])) {
        error "Invalid params.pacbio.input_type: ${params.pacbio.input_type}. Use 'ubam' or 'fastq'."
    }

    if (params.samplesheet) {
        samplesheet_ch = channel.fromPath(params.samplesheet, checkIfExists: true)
    }
    else {
        PREPARE_SAMPLESHEET_PACBIO(
            file("${projectDir}/modules/utils/samplesheet/generate_samplesheet_long.py", checkIfExists: true),
            file("${params.input_dir}/pacbio", checkIfExists: true),
            params.references.pacbio
        )
        samplesheet_ch = PREPARE_SAMPLESHEET_PACBIO.out.csv
    }

    reads_ch = readSamplesheet(samplesheet_ch)
        .map { row ->
            // platform and preset are read by both aligner modules: minimap2
            // for -x and the @RG PL tag, Parabricks for --preset.
            def meta = [
                id:        row.sample,
                reference: row.reference,
                platform:  'pacbio-hifi',
                preset:    'map-hifi',
            ]
            tuple(meta, file(row.reads, checkIfExists: true))
        }

    if (params.pacbio.input_type == 'ubam') {
        SAMTOOLS_FASTQ(reads_ch)
        fastq_ch = SAMTOOLS_FASTQ.out.reads
    }
    else {
        fastq_ch = reads_ch
    }

    aln_in = fastq_ch.multiMap { meta, reads ->
        reads: tuple(meta, reads)
        fasta: faidxFor(meta)
    }

    if (params.pacbio.device == 'gpu') {
        PARABRICKS_MINIMAP2(aln_in.reads, aln_in.fasta)
        bam_ch = PARABRICKS_MINIMAP2.out.bam     // tuple(meta, bam, bai)
    }
    else {
        // MINIMAP2_ALIGN emits tuple(meta, bam): its script indexes the BAM but
        // its output block does not declare the .bai, so index it here to reach
        // the same tuple shape as the GPU arm.
        MINIMAP2_ALIGN(aln_in.reads, aln_in.fasta)
        SAMTOOLS_INDEX(MINIMAP2_ALIGN.out.bam)
        bam_ch = SAMTOOLS_INDEX.out.bam          // tuple(meta, bam, bai)
    }

    SAMTOOLS_FLAGSTAT(bam_ch.map { meta, bam, _bai -> tuple(meta, bam) })
}


// ---------------------------------------------------------------------------
// ont - dorado sup basecalling, then dorado aligner
// ---------------------------------------------------------------------------
// IO character: chunked reads over POD5, sustained for hours, with a large
// uBAM written between the two GPU steps. This is the long pole of the whole
// benchmark - size the ONT sample set accordingly.
//
// The reference needs a samtools .fai beside it on both tiers. faidxFor()
// checks for it up front, so a missing index fails in seconds rather than
// after hours of basecalling.
workflow ont {

    if (!params.basecalling.model) {
        error "params.basecalling.model is required"
    }

    if (params.samplesheet) {
        samplesheet_ch = channel.fromPath(params.samplesheet, checkIfExists: true)
    }
    else {
        PREPARE_SAMPLESHEET_ONT(
            file("${params.input_dir}/ont", checkIfExists: true),
            params.references.ont
        )
        samplesheet_ch = PREPARE_SAMPLESHEET_ONT.out.csv
    }

    reads_ch = readSamplesheet(samplesheet_ch)
        .map { row ->
            def meta = [id: row.sample, reference: row.reference]
            // Resolve the reference and its .fai now, before anything has run
            faidxFor(meta)
            // `reads` is a POD5 file or a directory of them
            tuple(meta, file(row.reads, checkIfExists: true))
        }

    DORADO_BASECALLER(reads_ch)

    aln_in = DORADO_BASECALLER.out.ubam.multiMap { meta, ubam ->
        reads: tuple(meta, ubam)
        fasta: faidxFor(meta)
    }
    DORADO_ALIGNER(aln_in.reads, aln_in.fasta)

    SAMTOOLS_FLAGSTAT(DORADO_ALIGNER.out.bam.map { meta, bam, _bai -> tuple(meta, bam) })
}


// ---------------------------------------------------------------------------
// compare - did the two tiers produce the same alignments?
// ---------------------------------------------------------------------------
// Run after the same workload arm has run on both tiers. Pairs every published
// BAM with its counterpart on the other tier by relative path.
workflow compare {

    def hot_out  = outputDir('hot')
    def cold_out = outputDir('cold')

    // Every arm publishes its BAM to alignment/ (see nextflow.config), so one
    // glob covers all three without knowing which arm ran.
    def hot_bams  = files("${hot_out}/alignment/*.bam")
    def cold_bams = files("${cold_out}/alignment/*.bam")

    if (!hot_bams && !cold_bams) {
        error """No BAMs to compare.
        |  hot : ${hot_out}/alignment/
        |  cold: ${cold_out}/alignment/
        |Run a workload arm on both tiers first.""".stripMargin()
    }

    // join silently drops a BAM that exists on only one tier, so say so here.
    // That case means an arm ran on one tier and not the other, which would
    // otherwise look like a clean comparison of however many were left.
    def unpaired = ((hot_bams*.name as Set) - (cold_bams*.name as Set)) +
                   ((cold_bams*.name as Set) - (hot_bams*.name as Set))
    if (unpaired) {
        log.warn "not compared, present on only one tier: ${unpaired.sort().join(', ')}"
    }

    hot_ch  = channel.fromList(hot_bams).map  { f -> tuple(f.name, f) }
    cold_ch = channel.fromList(cold_bams).map { f -> tuple(f.name, f) }

    COMPARE_BAM(hot_ch.join(cold_ch))

    COMPARE_BAM.out.row
        .collectFile(
            name:     'compare-bam.csv',
            storeDir: params.results,
            seed:     'bam,hot_md5,cold_md5,identical,hot_reads,cold_reads\n',
            sort:     true,
        )
        .view { csv ->
            def rows = csv.readLines().drop(1).findAll { it.trim() }
            def bad  = rows.count { it.split(',')[3] == 'no' }
            // An unpaired BAM is not a pass: it was never compared. Saying
            // "identical" while something went unchecked would be the one
            // misleading sentence this whole arm exists to avoid.
            "compare: ${rows.size()} compared, ${bad} differing, ${unpaired.size()} unpaired -> ${csv}\n" +
            (bad == 0 && !unpaired
                ? "PASS: the two tiers produced identical alignments."
                : bad > 0
                    ? "FAIL: the cold tier did not reproduce the hot tier's output."
                    : "INCOMPLETE: everything compared matched, but ${unpaired.size()} BAM(s) exist on only one tier.")
        }
}


// ---------------------------------------------------------------------------
// report - hot vs cold timings, across every run so far
// ---------------------------------------------------------------------------
// Reads the trace files every other run leaves in params.results. The tier and
// rep come from each filename, so nothing has to be recorded alongside them.
workflow report {

    traces_ch = channel.fromPath("${params.results}/trace-*.txt", checkIfExists: true).collect()

    TIMING_REPORT(
        file("${projectDir}/modules/local/timing_report.py", checkIfExists: true),
        traces_ch
    )
}
