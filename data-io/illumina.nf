#!/usr/bin/env nextflow

// Illumina arm: bwa mem, on one storage tier.
//
//   nextflow run illumina.nf -profile cluster,hot -params-file params.yaml
//
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

include { PREPARE_SAMPLESHEET_ILLUMINA } from './modules/local/samplesheet/main.nf'
include { BWA_MEM }           from './modules/bwa/mem/main.nf'
include { SAMTOOLS_INDEX }    from './modules/samtools/index/main.nf'
include { SAMTOOLS_FLAGSTAT } from './modules/samtools/flagstat/main.nf'
include { bwaIndexFor }       from './modules/utils/references/references.nf'

workflow {

    if (!params.tier) {
        error "params.tier is unset: run with -profile hot or -profile cold"
    }

    // Built from the tier's own input folder, so the two arms cannot drift
    // apart and there is nothing to maintain by hand.
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

    reads_ch = samplesheet_ch
        .splitCsv(header: true)
        .filter { row -> row.sample && !row.sample.startsWith('#') }
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
