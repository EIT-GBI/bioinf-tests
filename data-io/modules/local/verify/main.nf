// Read one input file end to end and report what came back.
//
// This is the whole Phase 2 probe: no aligner, no basecaller, nothing that
// could be blamed for a bad result. It answers "does this filesystem hand back
// the bytes it was given, and how fast".
//
// Three things are recorded per task:
//   md5        - compared against manifests/<tier>.csv afterwards, and across
//                reps by bin/verify_report.sh. The same file yielding two
//                different md5s across reps is the signature of read-path
//                corruption, which is the reason this benchmark exists.
//   seconds    - wall clock for the read alone, so throughput is MB/s of real
//                sequential read rather than of a tool's whole runtime.
//   check_ok   - a format-aware integrity check on top of the checksum.
//                A truncated read and a silently-mangled-bytes read both break
//                the md5, but only the format check tells them apart.
//
// Nextflow stages inputs as symlinks, so the read goes through the tier under
// test rather than through a local copy Nextflow made first.

process VERIFY_READ {
    tag "${meta.id}/rep${meta.rep}"

    input:
    tuple val(meta), path(f)

    output:
    path "row.csv", emit: row

    script:
    """
    #!/usr/bin/env bash
    set -uo pipefail

    # GNU stat first, BSD stat as a fallback, so this also runs outside the
    # container on a mac. `wc -c` is not an option: it would read the whole
    # file and double the very thing being timed.
    bytes=\$(stat -Lc %s "${f}" 2>/dev/null || stat -Lf %z "${f}" 2>/dev/null || echo "")
    if [ -z "\$bytes" ]; then
        echo "WARNING: could not stat ${f}; throughput will be reported as NA" >&2
        bytes=0
    fi

    # Format-aware integrity check, picked from the extension. `none` is an
    # honest answer for a plain fasta/pod5 - the md5 still covers those.
    case "${f}" in
        *.bam|*.cram) check_type=samtools_quickcheck ;;
        *.gz|*.bgz)   check_type=gzip_t ;;
        *)            check_type=none ;;
    esac

    start=\$(date +%s.%N)
    md5=\$(md5sum "${f}" | awk '{print \$1}')
    md5_rc=\$?
    end=\$(date +%s.%N)

    case "\$check_type" in
        samtools_quickcheck) samtools quickcheck "${f}" && check_ok=yes || check_ok=no ;;
        gzip_t)              gzip -t "${f}"             && check_ok=yes || check_ok=no ;;
        none)                check_ok=na ;;
    esac

    # A read that failed outright has no meaningful checksum; say so rather
    # than recording a hash of nothing.
    if [ "\$md5_rc" -ne 0 ]; then
        md5="READ_FAILED"
        check_ok=no
    fi

    seconds=\$(awk -v s="\$start" -v e="\$end" 'BEGIN{printf "%.3f", e-s}')
    mbps=\$(awk -v b="\$bytes" -v s="\$seconds" 'BEGIN{ if (s>0) printf "%.2f", (b/1048576)/s; else printf "NA" }')

    printf '%s,%s,%s,"%s",%s,%s,%s,%s,%s,%s\\n' \\
        "${params.tier}" "${meta.rep}" "${meta.id}" "${meta.src}" \\
        "\$bytes" "\$seconds" "\$mbps" "\$md5" "\$check_type" "\$check_ok" \\
        > row.csv
    """

    stub:
    """
    printf '%s,%s,%s,"%s",0,0,NA,stub,none,na\\n' \\
        "${params.tier}" "${meta.rep}" "${meta.id}" "${meta.src}" > row.csv
    """
}
