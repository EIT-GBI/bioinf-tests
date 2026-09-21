#!/usr/bin/env nextflow

// PacBio HiFi arm: minimap2 (CPU) or pbrun minimap2 (GPU), on one storage tier.
//
//   nextflow run pacbio.nf -profile cluster,hot -params-file params.yaml --pacbio.device gpu
//
// IO character: large sequential reads. The GPU arm is often bound by host
// bandwidth rather than by the GPU, which makes it the more revealing of the
// two for a storage comparison.
//
// No chopper filtering, for the same reason illumina.nf skips fastp: it would
// rewrite the reads into the work dir and hide the source filesystem.
//
// SAMTOOLS_FASTQ is the exception, and only because HiFi reads arrive as uBAM
// and neither aligner takes one. It is genuine IO for this workload (read the
// uBAM, write a gzipped FASTQ), so it stays in the timed pipeline and is
// reported as its own process rather than hidden in a prep step.

include { PREPARE_SAMPLESHEET_PACBIO } from './modules/local/samplesheet/main.nf'
include { SAMTOOLS_FASTQ }      from './modules/samtools/fastq/main.nf'
include { SAMTOOLS_INDEX }      from './modules/samtools/index/main.nf'
include { SAMTOOLS_FLAGSTAT }   from './modules/samtools/flagstat/main.nf'
include { MINIMAP2_ALIGN }      from './modules/minimap2/align/main.nf'
include { PARABRICKS_MINIMAP2 } from './modules/parabricks/minimap2/main.nf'
include { faidxFor }            from './modules/utils/references/references.nf'

workflow {

    if (!params.tier) {
        error "params.tier is unset: run with -profile hot or -profile cold"
    }
    if (!(params.pacbio.device in ['cpu', 'gpu'])) {
        error "Invalid params.pacbio.device: ${params.pacbio.device}. Use 'cpu' (minimap2) or 'gpu' (Parabricks)."
    }
    if (!(params.pacbio.input_type in ['ubam', 'fastq'])) {
        error "Invalid params.pacbio.input_type: ${params.pacbio.input_type}. Use 'ubam' or 'fastq'."
    }

    // The long-read builder globs FASTQ and .bam, which is exactly the two
    // shapes params.pacbio.input_type allows.
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

    reads_ch = samplesheet_ch
        .splitCsv(header: true)
        .filter { row -> row.sample && !row.sample.startsWith('#') }
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
