#!/usr/bin/env nextflow

// ---------------------------------------------------------------------------
// data-io - hot (Lustre) vs cold (Alluxio) storage IO benchmark
// ---------------------------------------------------------------------------
// Two questions, in order:
//   1. Does Alluxio hand back the bytes it was given?   -> --arm verify
//   2. How much slower is it for real workloads?        -> the workload arms
//
//   --arm verify     read every input on BOTH tiers, checksum and time it
//   --arm illumina   bwa mem
//   --arm pacbio     minimap2, or Parabricks with --device gpu
//   --arm ont        dorado sup basecalling, then dorado aligner
//   --arm summary    hot vs cold: timings, throughput, output checksums
//
// One arm per run. The arms have no dependency on each other, but running
// different workloads at once would measure "three workloads saturating this
// filesystem" rather than how it serves any one of them. Within an arm, samples
// fan out normally - that concurrency is the realistic condition.
//
// Reads come from --tier. Everything written - work dir and results - goes to
// --out_tier (cold by default), so there is one results tree with one folder
// per run: results/hot-illumina/, results/cold-illumina/, results/verify/ ...
// ---------------------------------------------------------------------------

include { SAMPLESHEET_SHORT; SAMPLESHEET_LONG; SAMPLESHEET_POD5 } from './modules/local/processes.nf'
include { READ_FILE; COMPARE_BAM; REPORT_VERIFY; REPORT_SUMMARY } from './modules/local/processes.nf'

include { BWA_INDEX }           from './modules/bwa/index/main.nf'
include { BWA_MEM }             from './modules/bwa/mem/main.nf'
include { MINIMAP2_ALIGN }      from './modules/minimap2/align/main.nf'
include { PARABRICKS_MINIMAP2 } from './modules/parabricks/minimap2/main.nf'
include { DORADO_BASECALLER }   from './modules/dorado/basecaller/main.nf'
include { DORADO_ALIGNER }      from './modules/dorado/aligner/main.nf'
include { SAMTOOLS_FAIDX }      from './modules/samtools/faidx/main.nf'
include { SAMTOOLS_FASTQ }      from './modules/samtools/fastq/main.nf'
include { SAMTOOLS_FLAGSTAT }   from './modules/samtools/flagstat/main.nf'
include { SAMTOOLS_INDEX }      from './modules/samtools/index/main.nf'


// --- small helpers ---------------------------------------------------------

def inputDir(tier){ "${tier == 'cold' ? params.cold_root : params.hot_root}/tests/data-io/input" }
def scriptIn(name){ file("${projectDir}/modules/local/${name}", checkIfExists: true) }

// Rows of a generated samplesheet. '#' rows are dropped because CSV has no
// comment syntax, so such a line would otherwise become a sample.
def sheetRows(ch) {
    ch.splitCsv(header: true).filter { r -> r.sample && !r.sample.startsWith('#') }
}

// The reference fasta for an arm. Its indexes are built on demand below; the
// fasta itself cannot be, so it is the one thing that has to exist.
def fastaFor(String rel) {
    def f = file("${params.reference_dir}/${rel}")
    if (!f.exists()) {
        error "Reference missing on the '${params.tier}' tier:\n  ${f}"
    }
    return f
}

// The bwa index files if they all sit beside the fasta, else null. Pure on
// purpose: a function cannot call a process under Nextflow's strict syntax, so
// each arm does the build itself.
def bwaIndexFiles(fasta) {
    def fs = ['amb', 'ann', 'bwt', 'pac', 'sa'].collect { e -> file("${fasta}.${e}") }
    return fs.every { f -> f.exists() } ? fs : null
}


// --- entry point -----------------------------------------------------------

workflow {
    def arms = ['verify', 'illumina', 'pacbio', 'ont', 'summary']

    if (!(params.arm in arms)) {
        error """
        |${params.arm ? "Unknown --arm '${params.arm}'." : 'No --arm given.'}
        |
        |  --arm verify     integrity + throughput, both tiers   [--reps N]
        |  --arm illumina   bwa mem                              --tier hot|cold
        |  --arm pacbio     minimap2 / Parabricks                --tier, --device cpu|gpu
        |  --arm ont        dorado sup basecalling + aligner     --tier hot|cold
        |  --arm summary    hot vs cold comparison
        |
        |Results land in <tier root>/tests/data-io/results/<arm>/
        """.stripMargin()
    }

    if (params.arm == 'verify')        { verify()   }
    else if (params.arm == 'illumina') { illumina() }
    else if (params.arm == 'pacbio')   { pacbio()   }
    else if (params.arm == 'ont')      { ont()      }
    else if (params.arm == 'summary')  { summary()  }
}


// --- verify ----------------------------------------------------------------
// Reads every input on BOTH tiers, checksums and times it. This is where the
// "Alluxio gave corrupted files" question is answered.
//
// --reps 1 (the default) compares the two tiers against each other. --reps 2 or
// more additionally re-reads each file, so a file that checksums differently on
// two reads of the same tier is caught - the signature of a flaky read path.
workflow verify {

    def reps = params.reps as int
    if (reps < 1) {
        error "--reps must be at least 1, got '${params.reps}'"
    }

    def files = ['hot', 'cold'].collectMany { tier ->
        def dir = inputDir(tier)
        files("${dir}/**", type: 'file').collect { f -> tuple(tier, f.toString() - "${dir}/", f) }
    }
    if (!files) {
        error "No input files under ${inputDir('hot')} or ${inputDir('cold')}"
    }

    READ_FILE(
        channel.fromList(files)
            .combine(channel.of(1..reps))
            .map { tier, rel, f, rep -> tuple([tier: tier, rel: rel, rep: rep], f) }
    )

    csv = READ_FILE.out.row.collectFile(
        name: 'reads.csv', sort: true, storeDir: params.outdir,
        seed: 'tier,rep,rel,bytes,seconds,mb_per_s,md5,check,ok\n')

    REPORT_VERIFY(scriptIn('verify_report.py'), csv)
}


// --- illumina --------------------------------------------------------------
// IO: many small random reads against the bwa index, one large sequential write.
// No fastp: it would rewrite both FASTQs into the work dir, and everything
// downstream would then read that copy instead of the filesystem under test.
workflow illumina {

    SAMPLESHEET_SHORT(scriptIn('../utils/samplesheet/generate_samplesheet_short.py'),
                      file("${params.input_dir}/illumina", checkIfExists: true),
                      params.ref_illumina)

    reads = sheetRows(SAMPLESHEET_SHORT.out.csv).map { r ->
        tuple([id: r.sample], file(r.R1, checkIfExists: true), file(r.R2, checkIfExists: true))
    }

    // Reuse the bwa index beside the fasta, or build it once. Built on demand
    // it lives in the work dir, so its reads come off the output tier either
    // way - negligible here (a few MB of index against multi-GB reads) and the
    // build is its own process, so it never lands inside an alignment's timing.
    def fasta = fastaFor(params.ref_illumina)
    def idx   = bwaIndexFiles(fasta)

    if (idx) {
        index = channel.value(tuple(fasta, idx))
    }
    else {
        log.warn "Building bwa index for ${fasta} (once)."
        BWA_INDEX(channel.value(fasta))
        index = BWA_INDEX.out.index
    }

    BWA_MEM(reads, index)
    SAMTOOLS_INDEX(BWA_MEM.out.bam)
    SAMTOOLS_FLAGSTAT(SAMTOOLS_INDEX.out.bam.map { m, bam, _bai -> tuple(m, bam) })
}


// --- pacbio ----------------------------------------------------------------
// IO: large sequential reads. The GPU arm is often bound by host bandwidth
// rather than the GPU, which makes it the more revealing of the two.
// HiFi reads arrive as uBAM; SAMTOOLS_FASTQ converts them, and is genuine IO
// for this workload so it stays in the timed pipeline as its own process.
workflow pacbio {

    if (!(params.device in ['cpu', 'gpu'])) {
        error "Invalid --device '${params.device}'. Use cpu (minimap2) or gpu (Parabricks)."
    }

    SAMPLESHEET_LONG(scriptIn('../utils/samplesheet/generate_samplesheet_long.py'),
                     file("${params.input_dir}/pacbio", checkIfExists: true),
                     params.ref_pacbio)

    // uBAM or FASTQ, decided per sample by its extension rather than a flag
    branched = sheetRows(SAMPLESHEET_LONG.out.csv)
        .map { r -> tuple([id: r.sample, platform: 'pacbio-hifi', preset: 'map-hifi'],
                          file(r.reads, checkIfExists: true)) }
        .branch { _m, f -> ubam: f.name.endsWith('.bam')
                           fastq: true }

    SAMTOOLS_FASTQ(branched.ubam)
    fastq = SAMTOOLS_FASTQ.out.reads.mix(branched.fastq)

    def fasta = fastaFor(params.ref_pacbio)

    if (file("${fasta}.fai").exists()) {
        ref = channel.value(tuple(fasta, file("${fasta}.fai")))
    }
    else {
        log.warn "Building .fai for ${fasta} (once)."
        SAMTOOLS_FAIDX(channel.value(tuple([id: fasta.name], fasta)))
        ref = SAMTOOLS_FAIDX.out.fai.map { _m, f -> tuple(fasta, f) }
    }

    if (params.device == 'gpu') {
        PARABRICKS_MINIMAP2(fastq, ref)
        bam = PARABRICKS_MINIMAP2.out.bam
    }
    else {
        // MINIMAP2_ALIGN emits tuple(meta, bam): its script indexes the BAM but
        // does not declare the .bai, so index it to match the GPU arm's shape.
        MINIMAP2_ALIGN(fastq, ref)
        SAMTOOLS_INDEX(MINIMAP2_ALIGN.out.bam)
        bam = SAMTOOLS_INDEX.out.bam
    }

    SAMTOOLS_FLAGSTAT(bam.map { m, b, _bai -> tuple(m, b) })
}


// --- ont -------------------------------------------------------------------
// IO: chunked reads over POD5, sustained for hours, with a large uBAM written
// between the two GPU steps. The long pole of the whole benchmark.
workflow ont {

    SAMPLESHEET_POD5(file("${params.input_dir}/ont", checkIfExists: true), params.ref_ont)

    reads = sheetRows(SAMPLESHEET_POD5.out.csv).map { r ->
        tuple([id: r.sample], file(r.reads, checkIfExists: true))
    }

    DORADO_BASECALLER(reads)
    def fasta = fastaFor(params.ref_ont)

    if (file("${fasta}.fai").exists()) {
        ref = channel.value(tuple(fasta, file("${fasta}.fai")))
    }
    else {
        log.warn "Building .fai for ${fasta} (once)."
        SAMTOOLS_FAIDX(channel.value(tuple([id: fasta.name], fasta)))
        ref = SAMTOOLS_FAIDX.out.fai.map { _m, f -> tuple(fasta, f) }
    }

    DORADO_ALIGNER(DORADO_BASECALLER.out.ubam, ref)
    SAMTOOLS_FLAGSTAT(DORADO_ALIGNER.out.bam.map { m, b, _bai -> tuple(m, b) })
}


// --- summary ---------------------------------------------------------------
// Reads what the other arms left on both tiers and answers the whole question
// in one file: were the outputs identical, and how much slower was cold.
workflow summary {

    def results = "${params.out_base}/results"

    // Every run folder is named <tier>-<arm>, so hot-illumina pairs with
    // cold-illumina once the prefix is stripped from the key.
    hot_ch  = channel.fromList(files("${results}/hot-*/alignment/*.bam"))
        .map { f -> tuple(f.toString() - "${results}/hot-", f) }
    cold_ch = channel.fromList(files("${results}/cold-*/alignment/*.bam"))
        .map { f -> tuple(f.toString() - "${results}/cold-", f) }

    pairs = hot_ch.join(cold_ch)

    COMPARE_BAM(pairs)

    bams = COMPARE_BAM.out.row
        .collectFile(name: 'bams.csv', sort: true,
                     seed: 'bam,hot_md5,cold_md5,identical,hot_reads,cold_reads\n')
        .ifEmpty { file("${projectDir}/modules/local/empty.csv") }

    // The traces are read straight from the results tree rather than staged:
    // the folder names carry the tier and arm, which staging would flatten away.
    REPORT_SUMMARY(scriptIn('summary.py'), results, bams)
}
