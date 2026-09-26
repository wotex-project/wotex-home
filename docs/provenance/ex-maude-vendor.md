# ex_maude source snapshot

`vendor/ex_maude` is the tracked source tree from
[`futhr/ex_maude` commit `82037e0f3b6494789cc7e634102e23dab53b7fe2`](https://github.com/futhr/ex_maude/tree/82037e0f3b6494789cc7e634102e23dab53b7fe2),
copied with `git archive` from that exact local commit. It includes the upstream
MIT [license](../../vendor/ex_maude/LICENSE) and the Maude binaries distributed
in that tree. No uncommitted sibling-checkout files were copied.

The Mix dependency uses this repository path. A Home source checkout no longer
needs a neighboring ex_maude checkout to compile. Changes to this snapshot
require a new explicit upstream commit, a source diff and a Home release smoke
test. The committed source pin does not qualify the binary closure on another
machine or replace a release SBOM and license review.

This update adds the isolated bounded-search evidence API, distinct depth
truncation outcomes, worker retirement on caller loss, and upstream dependency
and review fixes. Home's rule review still uses only the narrow negative IoT
conflict receipt. A completed depth-bounded search is not a positive Home proof.
