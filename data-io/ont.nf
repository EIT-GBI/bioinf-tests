#!/usr/bin/env nextflow

// ONT arm: dorado sup basecalling then dorado aligner, on one storage tier.
//
//   nextflow run ont.nf -profile cluster,hot -params-file params.yaml
//
// IO character: chunked reads over POD5, sustained for hours, with a large
// uBAM written between the two GPU steps. This is the long pole of the whole
// benchmark - size the ONT sample set accordingly, and see README.md on using
// fewer reps here than on the other arms.
//
// The reference needs a samtools .fai beside it on both tiers. faidxFor()
// checks for it up front, so a missing index fails in seconds rather than
// after hours of basecalling.

include { PREPARE_SAMPLESHEET_ONT } from './modules/local/samplesheet/main.nf'
include { DORADO_BASECALLER } from './modules/dorado/basecaller/main.nf'
include { DORADO_ALIGNER }    from './modules/dorado/aligner/main.nf'
include { SAMTOOLS_FLAGSTAT } from './modules/samtools/flagstat/main.nf'
include { faidxFor }          from './modules/utils/references/references.nf'

workflow {

    if (!params.tier) {
        error "params.tier is unset: run with -profile hot or -profile cold"
    }
    if (!params.basecalling.model) {
        error "params.basecalling.model is required"
    }

    // POD5 needs its own builder: nf-mod-utils' long-read one globs FASTQ/BAM
    // suffixes and only emits files, but dorado takes a POD5 directory too.
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

    reads_ch = samplesheet_ch
        .splitCsv(header: true)
        .filter { row -> row.sample && !row.sample.startsWith('#') }
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
