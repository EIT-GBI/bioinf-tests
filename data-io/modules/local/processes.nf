// Everything written for this benchmark. The aligners and basecallers all come
// from the nf-mod-* submodules; these are the pieces that have no module.
//
// None of the samplesheet builders defines a `stub:` block, on purpose: Nextflow
// then runs the real script even under -stub-run. Building a samplesheet is
// cheap, and nf-mod-utils' own stubs `touch` an empty file, which makes the next
// operator fail with "Missing 'header' in CSV file".

// --- samplesheet builders --------------------------------------------------
// The parsing comes from nf-mod-utils' python scripts, passed in as an input the
// way nf-dnaseq does it; these are only wrappers.

process SAMPLESHEET_SHORT {          // paired FASTQ: <sample>_R1/_R2
    tag "${dir}"
    input:  path pyscript
            path dir
            val  reference
    output: path 'samplesheet.csv', emit: csv
    script: "python3 ${pyscript} --input_dir ${dir} --reference ${reference} --output samplesheet.csv"
}

process SAMPLESHEET_LONG {           // one file per sample: uBAM or FASTQ
    tag "${dir}"
    input:  path pyscript
            path dir
            val  reference
    output: path 'samplesheet.csv', emit: csv
    script: "python3 ${pyscript} --input_dir ${dir} --reference ${reference} --output samplesheet.csv"
}

// POD5, which neither python script handles: the long-read one globs FASTQ and
// BAM suffixes and only emits files, whereas dorado takes a whole directory of
// POD5s - and ONT runs are usually shaped that way.
//
//   input/ont/sample01/      -> one sample per subdirectory (name = dir name)
//   input/ont/sample01.pod5  -> one sample per file         (name = basename)
process SAMPLESHEET_POD5 {
    tag "${dir}"
    input:  path dir
            val  reference
    output: path 'samplesheet.csv', emit: csv
    script:
    """
    #!/usr/bin/env bash
    set -euo pipefail
    echo "sample,reads,reference" > samplesheet.csv

    # -L follows the symlink Nextflow staged; readlink -f records the real
    # location on the tier rather than the work-dir symlink
    if [ -n "\$(find -L ${dir} -mindepth 1 -maxdepth 1 -type d)" ]; then
        find -L ${dir} -mindepth 1 -maxdepth 1 -type d | sort | while read -r d; do
            echo "\$(basename "\$d"),\$(readlink -f "\$d"),${reference}" >> samplesheet.csv
        done
    else
        find -L ${dir} -mindepth 1 -maxdepth 1 -name '*.pod5' | sort | while read -r f; do
            echo "\$(basename "\$f" .pod5),\$(readlink -f "\$f"),${reference}" >> samplesheet.csv
        done
    fi

    if [ "\$(wc -l < samplesheet.csv)" -le 1 ]; then
        echo "ERROR: no POD5 files or per-sample directories in ${dir}" >&2
        exit 1
    fi
    """
}


// --- READ_FILE -------------------------------------------------------------
// Read one input file end to end and report what came back. No aligner, no
// basecaller, nothing else that could be blamed for a bad result.
//
//   md5      - compared across tiers, and across reps when --reps > 1
//   seconds  - wall clock for the read alone
//   ok       - a format-aware check on top of the checksum: a truncated read
//              and a mangled one both break the md5, only this tells them apart
//
// Nextflow stages inputs as symlinks, so the read goes through the tier under
// test rather than a copy.
process READ_FILE {
    tag "${meta.tier}/${meta.rel}${meta.rep > 1 ? "/rep${meta.rep}" : ''}"

    input:  tuple val(meta), path(f)
    output: path 'row.csv', emit: row

    script:
    """
    #!/usr/bin/env bash
    set -uo pipefail

    # Size comes from the inode: stat() touches no data, so it stays outside
    # the timed window. GNU stat first, BSD stat as a fallback.
    bytes=\$(stat -Lc %s "${f}" 2>/dev/null || stat -Lf %z "${f}" 2>/dev/null || echo 0)

    case "${f}" in
        *.bam|*.cram) check=quickcheck ;;
        *.gz|*.bgz)   check=gzip ;;
        *)            check=none ;;
    esac

    # THE READ. md5sum is the only thing inside the timing window and is what
    # streams the file end to end. Checksumming doubles as the integrity check,
    # so one pass answers both questions.
    #
    # Caveat: md5 runs at ~700-800 MB/s per core, so a single-stream figure near
    # that ceiling is measuring the hash, not the storage.
    start=\$(date +%s.%N)
    md5=\$(md5sum "${f}" | awk '{print \$1}')
    rc=\$?
    end=\$(date +%s.%N)

    # After the timing window: these read the file a second time.
    case "\$check" in
        quickcheck) samtools quickcheck "${f}" && ok=yes || ok=no ;;
        gzip)       gzip -t "${f}"             && ok=yes || ok=no ;;
        none)       ok=na ;;
    esac

    if [ "\$rc" -ne 0 ]; then md5=READ_FAILED; ok=no; fi

    secs=\$(awk -v s="\$start" -v e="\$end" 'BEGIN{printf "%.3f", e-s}')
    mbps=\$(awk -v b="\$bytes" -v s="\$secs" 'BEGIN{ if (s>0) printf "%.2f", (b/1048576)/s; else printf "0" }')

    echo "${meta.tier},${meta.rep},${meta.rel},\$bytes,\$secs,\$mbps,\$md5,\$check,\$ok" > row.csv
    """
}


// --- COMPARE_BAM -----------------------------------------------------------
// Compares the BAM *body*, not the file. A whole-file md5 always differs between
// tiers because the @PG header records the command line, which contains the
// tier-specific paths - expected, and says nothing about integrity.
process COMPARE_BAM {
    tag "${rel}"

    input:  tuple val(rel), path(hot_bam, stageAs: 'hot/*'), path(cold_bam, stageAs: 'cold/*')
    output: path 'row.csv', emit: row

    script:
    """
    #!/usr/bin/env bash
    set -euo pipefail
    hot=\$(samtools view ${hot_bam}  | md5sum | cut -d' ' -f1)
    cold=\$(samtools view ${cold_bam} | md5sum | cut -d' ' -f1)

    if [ "\$hot" = "\$cold" ]; then
        echo "${rel},\$hot,\$cold,yes,," > row.csv
    else
        # How they differ: fewer reads means truncated input, the same count
        # with different mappings means corrupted bases.
        hn=\$(samtools view -c ${hot_bam}  | tr -d '[:space:]')
        cn=\$(samtools view -c ${cold_bam} | tr -d '[:space:]')
        echo "${rel},\$hot,\$cold,no,\$hn,\$cn" > row.csv
    fi
    """
}


// --- reports ---------------------------------------------------------------
// Both keep their logic in a real .py file rather than inline: a `\"\"\"` docstring
// would close the Groovy string, and the script block's indentation stripping is
// easy to break.

process REPORT_VERIFY {
    input:  path pyscript
            path csv
    output: path 'verify-report.txt', emit: report
    script: "python3 ${pyscript} ${csv}"
}

process REPORT_SUMMARY {
    input:  path pyscript
            val  results_dir
            path bams
    output: path 'summary.txt', emit: report
            path 'tasks.csv',   emit: csv
    script: "python3 ${pyscript} ${results_dir} ${bams}"
}
