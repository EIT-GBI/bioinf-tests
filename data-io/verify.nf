#!/usr/bin/env nextflow

// Phase 2: read integrity and raw throughput for one storage tier.
//
//   nextflow run verify.nf -profile cluster,cold -params-file params.yaml
//
// No aligner, no basecaller. Every input file is read end to end, checksummed
// and timed, params.verify.reps times over, as that many separate tasks. This
// is where the "Alluxio gave corrupted files" question gets answered, and it
// runs in minutes rather than hours.
//
// Output: <outdir>/verify-<tier>.csv, one row per (file, rep).
// Feed it to bin/verify_report.sh.
//
// Run this on every partition the real pipelines use, the GPU one included:
// mounts and network paths can differ per partition, so a clean result on the
// CPU queue does not cover the Dorado and Parabricks arms.

include { VERIFY_READ } from './modules/local/verify/main.nf'

workflow {

    if (!params.tier) {
        error "params.tier is unset: run with -profile hot or -profile cold, so the results are labelled with the tier they came from"
    }

    // One task per (file, rep). `rep` rides in meta, which is a val input, so
    // each rep hashes differently and genuinely re-reads the file rather than
    // being collapsed into one task.
    reads_ch = channel.fromPath("${params.input_dir}/**", type: 'file', checkIfExists: true)
        .combine(channel.of(1..params.verify.reps))
        .map { f, rep -> tuple([id: f.name, src: f.toString(), rep: rep], f) }

    VERIFY_READ(reads_ch)

    // Sorted so the two tiers' CSVs line up row for row and diff cleanly.
    VERIFY_READ.out.row
        .collectFile(
            name:     "verify-${params.tier}.csv",
            storeDir: params.outdir,
            seed:     'tier,rep,file,src,bytes,seconds,mb_per_s,md5,check_type,check_ok\n',
            sort:     true,
        )
        .view { csv -> "verify results: ${csv}" }
}
