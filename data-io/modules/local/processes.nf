// Every process written for this benchmark. The aligners and basecallers all
// come from the nf-mod-* submodules; these are the pieces that have no module.
//
// They replace what used to be a bin/ directory of shell scripts, so there is
// nothing to run before or after a pipeline - `nextflow run main.nf -entry ...`
// is the whole interface.

// ---------------------------------------------------------------------------
// Samplesheet builders
// ---------------------------------------------------------------------------
// The parsing comes from nf-mod-utils' python scripts, passed in as an input
// the way nf-dnaseq does it; these are only the wrappers.
//
// None of them defines a `stub:` block, on purpose: Nextflow then runs the real
// script even under -stub-run. Building a samplesheet is cheap, and
// nf-mod-utils' own stubs `touch` an empty file, which makes the next operator
// fail with "Missing 'header' in CSV file".

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
    python3 ${pyscript} --input_dir ${input_dir} --reference ${reference} --output samplesheet.csv
    """
}

// Long reads, one file per sample: FASTQ or unaligned BAM (PacBio HiFi)
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
    python3 ${pyscript} --input_dir ${input_dir} --reference ${reference} --output samplesheet.csv
    """
}

// POD5, which neither python script handles: the long-read one globs FASTQ and
// BAM suffixes and only ever emits files, whereas `dorado basecaller` takes a
// whole directory of POD5s - and ONT runs are usually shaped that way.
//
//   input/ont/sample01/      -> one sample per subdirectory (name = dir name)
//   input/ont/sample01.pod5  -> one sample per file         (name = basename)
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

    # -L so the symlink Nextflow staged is followed; readlink -f so the CSV
    # records the real location on the tier, not the work-dir symlink
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

// ---------------------------------------------------------------------------
// VERIFY_READ - read one file end to end and report what came back
// ---------------------------------------------------------------------------
// The whole integrity probe: no aligner, no basecaller, nothing that could be
// blamed for a bad result. It answers "does this filesystem hand back the bytes
// it was given, and how fast".
//
//   md5       - compared across reps and across tiers afterwards. The same file
//               yielding two different md5s is the signature of read-path
//               corruption, which is the reason this benchmark exists.
//   seconds   - wall clock for the read alone.
//   check_ok  - a format-aware check on top of the checksum. A truncated read
//               and a mangled one both break the md5; only this tells them apart.
//
// Nextflow stages inputs as symlinks, so the read goes through the tier under
// test rather than a local copy Nextflow made first.
process VERIFY_READ {
    tag "${meta.tier}/${meta.rel}/rep${meta.rep}"

    input:
    tuple val(meta), path(f)

    output:
    path "row.csv", emit: row

    script:
    """
    #!/usr/bin/env bash
    set -uo pipefail

    # Size comes from the inode, not from reading: stat() is two syscalls and
    # touches no data, so it stays outside the timed window below.
    # GNU stat first, BSD stat as a fallback.
    bytes=\$(stat -Lc %s "${f}" 2>/dev/null || stat -Lf %z "${f}" 2>/dev/null || echo 0)

    case "${f}" in
        *.bam|*.cram) check=samtools_quickcheck ;;
        *.gz|*.bgz)   check=gzip_t ;;
        *)            check=none ;;
    esac

    # THE READ. md5sum is the only thing inside the timing window, and it is
    # what streams the file end to end: ${f} is the symlink Nextflow staged
    # into the work dir, so the bytes come off the tier under test rather than
    # a local copy. Checksumming doubles as the integrity check, which is why
    # it is preferred over `dd ... of=/dev/null` - one pass, two answers.
    #
    # Caveat: md5 itself runs at roughly 700-800 MB/s per core, so on a
    # filesystem faster than that this measures the hash, not the storage.
    # Under normal fan-out each task's share is usually well below that
    # ceiling, but treat a single-stream figure near ~750 MB/s with suspicion.
    start=\$(date +%s.%N)
    md5=\$(md5sum "${f}" | awk '{print \$1}')
    rc=\$?
    end=\$(date +%s.%N)

    # Deliberately after the timing window: these read the file a second time,
    # and would otherwise be counted as part of the storage read.
    case "\$check" in
        samtools_quickcheck) samtools quickcheck "${f}" && ok=yes || ok=no ;;
        gzip_t)              gzip -t "${f}"             && ok=yes || ok=no ;;
        none)                ok=na ;;
    esac

    # A read that failed outright has no meaningful checksum; say so rather than
    # recording a hash of nothing.
    if [ "\$rc" -ne 0 ]; then md5=READ_FAILED; ok=no; fi

    secs=\$(awk -v s="\$start" -v e="\$end" 'BEGIN{printf "%.3f", e-s}')
    mbps=\$(awk -v b="\$bytes" -v s="\$secs" 'BEGIN{ if (s>0) printf "%.2f", (b/1048576)/s; else printf "0" }')

    echo "${meta.tier},${meta.rep},${meta.rel},\$bytes,\$secs,\$mbps,\$md5,\$check,\$ok" > row.csv
    """
}

// ---------------------------------------------------------------------------
// VERIFY_REPORT - turn the collected rows into the integrity answer
// ---------------------------------------------------------------------------
// The logic lives in modules/local/verify_report.py, passed in as an input the
// same way the samplesheet builders take theirs. Keeping it in a real .py file
// rather than inline keeps it readable, and sidesteps two ways Groovy mangles
// embedded python: a `"""` docstring closes the script block, and the block's
// indentation stripping is easy to break.
process VERIFY_REPORT {
    publishDir params.results, mode: 'copy'

    input:
    path pyscript
    path csv

    output:
    path "verify-report.txt", emit: report

    script:
    """
    python3 ${pyscript} ${csv}
    """
}


// ---------------------------------------------------------------------------
// COMPARE_BAM - did the two tiers produce the same alignment?
// ---------------------------------------------------------------------------
// Compares the BAM *body*, not the file. A whole-file md5 always differs
// between tiers because the @PG header records the command line, which contains
// the tier-specific input paths - expected, and says nothing about integrity.
//
// Identical bodies is a stronger statement than VERIFY_READ gives: it covers
// the whole pipeline's read pattern, not one sequential pass.
process COMPARE_BAM {
    tag "${rel}"

    input:
    tuple val(rel), path(hot_bam, stageAs: 'hot/*'), path(cold_bam, stageAs: 'cold/*')

    output:
    path "row.csv", emit: row

    script:
    """
    #!/usr/bin/env bash
    set -euo pipefail

    hot=\$(samtools view ${hot_bam}  | md5sum | cut -d' ' -f1)
    cold=\$(samtools view ${cold_bam} | md5sum | cut -d' ' -f1)

    if [ "\$hot" = "\$cold" ]; then
        echo "${rel},\$hot,\$cold,yes,,"> row.csv
    else
        # How they differ: fewer reads means truncated input, the same count with
        # different mappings means corrupted bases.
        hn=\$(samtools view -c ${hot_bam} | tr -d '[:space:]')
        cn=\$(samtools view -c ${cold_bam} | tr -d '[:space:]')
        echo "${rel},\$hot,\$cold,no,\$hn,\$cn" > row.csv
    fi
    """
}

// ---------------------------------------------------------------------------
// TIMING_REPORT - hot vs cold, per process, across every run
// ---------------------------------------------------------------------------
// Reads the trace files staged from params.results. The tier and rep come from
// each filename, so no bookkeeping file is needed to know what a trace was.
process TIMING_REPORT {
    publishDir params.results, mode: 'copy'

    input:
    path pyscript
    path traces

    output:
    path "timing-report.txt", emit: report
    path "all_tasks.csv",     emit: csv

    script:
    """
    python3 ${pyscript}
    """
}
