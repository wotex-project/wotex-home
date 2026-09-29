# ex_maude dependency source

Home pins [`futhr/ex_maude` commit `dc41e3331c025ce77ddcaf87883425c997d69af8`](https://github.com/futhr/ex_maude/tree/dc41e3331c025ce77ddcaf87883425c997d69af8)
in `mix.exs` and `mix.lock`. A clean checkout fetches that commit. A neighboring
`../ex_maude` Mix project is used for local development; set
`WOTEX_HOME_GIT_DEPS=1` to build against the pinned Git commit even when that
checkout exists. CI always uses the Git source. A local override may contain
uncommitted or newer work and is not evidence for a release at the pin.

The previous copied source came from `82037e0f3b6494789cc7e634102e23dab53b7fe2`.
That object exists in the local upstream checkout but is no longer reachable
from its advertised branches, so a fresh Git dependency clone cannot check it
out. The selected commit is the current `origin/main` revision in that checkout.
Its changes from the copied source were reviewed before updating Home's pin.

The pinned source includes isolated bounded-search evidence, explicit depth
truncation outcomes and worker retirement on caller loss. Home still uses only
its narrow negative IoT conflict receipt. A completed depth-bounded search is
not a positive Home proof.

The upstream [MIT license](https://github.com/futhr/ex_maude/blob/dc41e3331c025ce77ddcaf87883425c997d69af8/LICENSE)
and third-party notice have byte-identical, hash-checked copies in
[`license-inputs/`](license-inputs/README.md) for release packaging. Those small
legal inputs do not replace native binary qualification, a release SBOM or a
license review. Changing the Git ref requires source review, fresh legal hashes
and an isolated release smoke run.
