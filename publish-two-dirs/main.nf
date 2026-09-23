#!/usr/bin/env nextflow

// ---------------------------------------------------------------------------
// publish-two-dirs - can one workflow output land on BOTH tiers?
// ---------------------------------------------------------------------------
// Uses workflow outputs (publish: + output {}), not publishDir. The same channel
// is published twice under two output names. Each name gets its own `path`, and
// that path is ABSOLUTE - one under hot_root, one under cold_root. An absolute
// path is not resolved against outputDir, so the two copies can sit on
// different filesystems.
//
//   nextflow run main.nf -profile cluster                       Lustre + Alluxio
//   nextflow run main.nf --hot_root /tmp/h --cold_root /tmp/c   local test
// ---------------------------------------------------------------------------

process MAKE {
    tag "${id}"

    input:
    val id

    output:
    tuple val(id), path("${id}.txt")

    script:
    """
    echo "sample ${id} \$(date +%s)" > ${id}.txt
    """
}

workflow {
    main:
    made = MAKE(channel.of('a', 'b', 'c'))

    // Both copies must exist and hold the same bytes. Captured first: params
    // is not visible inside the onComplete closure.
    def hot  = params.hot_out
    def cold = params.cold_out
    workflow.onComplete {
        def bad = ['a', 'b', 'c'].findAll { id ->
            def h = file("${hot}/${id}/${id}.txt")
            def c = file("${cold}/${id}/${id}.txt")
            !(h.exists() && c.exists() && h.text == c.text)
        }
        log.info(bad ? "FAIL - missing or differing on one tier: ${bad}"
                     : "OK - every file published to both\n  ${hot}\n  ${cold}")
    }

    publish:
    to_hot  = made
    to_cold = made
}

output {
    // Same work file, two destinations. `mode` is per output, so the hot copy
    // can hard-link (work dir is on Lustre) while the cold one has to copy.
    to_hot {
        path { id, _f -> "${params.hot_out}/${id}" }
        mode 'link'
    }
    to_cold {
        path { id, _f -> "${params.cold_out}/${id}" }
        mode 'copy'
    }
}
