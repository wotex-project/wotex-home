# ex_maude source snapshot

`vendor/ex_maude` is the tracked source tree from
[`futhr/ex_maude` commit `346143235fcb8f412d4a79642d472681d99465fd`](https://github.com/futhr/ex_maude/tree/346143235fcb8f412d4a79642d472681d99465fd),
copied with `git archive` from that exact local commit. It includes the upstream
MIT [license](../../vendor/ex_maude/LICENSE) and the Maude binaries distributed
in that tree. No uncommitted sibling-checkout files were copied.

The Mix dependency uses this repository path. A Home source checkout no longer
needs a neighboring ex_maude checkout to compile. Changes to this snapshot
require a new explicit upstream commit, a source diff and a Home release smoke
test. The committed source pin does not qualify the binary closure on another
machine or replace a release SBOM and license review.
