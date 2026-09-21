// Samplesheet builders: scan a platform's input folder, emit a samplesheet.
//
// Following nf-dnaseq, which keeps its builder as a local module and passes the
// python script in as an input. The two python scripts here come from
// nf-mod-utils, so the parsing logic is reused rather than rewritten - these
// processes are only the wrappers.
//
// Why local wrappers rather than nf-mod-utils' PREPARE_SAMPLESHEET_SHORT and
// _LONG directly: those define `stub: touch samplesheet.csv`, and an empty file
// makes the very next operator fail with "Missing 'header' in CSV file", so
// -stub-run cannot get past the first step. None of the processes here define a
// stub at all, which means Nextflow runs the real script even under -stub-run.
// That is what we want: building a samplesheet is cheap, and a -stub-run that
// skipped it would be testing nothing.
//
// All three resolve paths to the real location on the tier under test, not to
// the symlink Nextflow staged into the work dir.

// Paired-end FASTQ: <sample>_R1.fastq.gz / <sample>_R2.fastq.gz
process PREPARE_SAMPLESHEET_ILLUMINA {
    tag "${input_dir}"

    publishDir "${params.outdir}/samplesheet", mode: 'copy'

    input:
    path pyscript
    path input_dir
    val reference

    output:
    path "samplesheet.csv", emit: csv

    script:
    """
    python3 ${pyscript} \\
        --input_dir ${input_dir} \\
        --reference ${reference} \\
        --output samplesheet.csv
    """
}

// Long reads, one file per sample: FASTQ or unaligned BAM. PacBio HiFi arrives
// as uBAM, which is what params.pacbio.input_type = 'ubam' expects.
process PREPARE_SAMPLESHEET_PACBIO {
    tag "${input_dir}"

    publishDir "${params.outdir}/samplesheet", mode: 'copy'

    input:
    path pyscript
    path input_dir
    val reference

    output:
    path "samplesheet.csv", emit: csv

    script:
    """
    python3 ${pyscript} \\
        --input_dir ${input_dir} \\
        --reference ${reference} \\
        --output samplesheet.csv
    """
}

// POD5, which neither python script handles: the long-read one globs FASTQ and
// BAM suffixes and only ever emits files, whereas `dorado basecaller` takes a
// whole directory of POD5s too - and ONT runs are usually shaped that way.
//
// Two layouts are accepted, because both are in use:
//
//   input/ont/sample01/       -> one sample per subdirectory,
//   input/ont/sample02/          sample name = directory name
//
//   input/ont/sample01.pod5   -> one sample per file,
//   input/ont/sample02.pod5      sample name = basename
//
// Subdirectories win when both are present.
process PREPARE_SAMPLESHEET_ONT {
    tag "${input_dir}"

    publishDir "${params.outdir}/samplesheet", mode: 'copy'

    input:
    path input_dir
    val reference

    output:
    path "samplesheet.csv", emit: csv

    script:
    """
    #!/usr/bin/env bash
    set -euo pipefail

    echo "sample,reads,reference" > samplesheet.csv

    # -L throughout, so the symlink Nextflow staged is followed
    if [ -n "\$(find -L ${input_dir} -mindepth 1 -maxdepth 1 -type d)" ]; then
        find -L ${input_dir} -mindepth 1 -maxdepth 1 -type d | sort | while read -r d; do
            echo "\$(basename "\$d"),\$(readlink -f "\$d"),${reference}" >> samplesheet.csv
        done
    else
        find -L ${input_dir} -mindepth 1 -maxdepth 1 -name '*.pod5' | sort | while read -r f; do
            echo "\$(basename "\$f" .pod5),\$(readlink -f "\$f"),${reference}" >> samplesheet.csv
        done
    fi

    if [ "\$(wc -l < samplesheet.csv)" -le 1 ]; then
        echo "ERROR: no POD5 files or per-sample directories in ${input_dir}" >&2
        exit 1
    fi
    """
}
