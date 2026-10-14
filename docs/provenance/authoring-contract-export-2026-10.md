# Authenticated authoring contract export evidence

Recorded: 2026-10-14. Owner: [contract export successor](../specs/authoring-contract-export-v1.md),
WOH.18 authoring and WOH.15 private operator reads.
Runtime source: fa440dd with fixture correction 77290e3 on main.

The public Authority/Store read authenticates current profile:manage before
examining installed configuration and reconstructs AuthoringContract against
actual current producer identities. It returns exact WPF bytes as unpadded
URL-safe Base64, complete summary and current principal/epoch/revision. The
closed private route and CLI authoring-contract command use the same read.
No revision, row, quota reservation, original, import or grant is created.

Toolchain: Elixir 1.19.6 / OTP 28.5.0.6, arm64 macOS;
WOTEX_HOME_GIT_DEPS=1 MIX_ENV=test. The final focused command was mix test
test/wotex_home/authoring_contract_export_test.exs
test/wotex_home/authoring_operator_test.exs
test/wotex_home/host_profile_installation_test.exs.
Nineteen cases passed with zero failures in 5.6 seconds. Its executed result is
retained in /tmp/home-authoring-contract-export-final.log.

The five export cases compare both independent temperature/research WPF
semantic/raw-byte vectors, complete summary and repeated unchanged Store
revision. They cover permission before absent configuration, credential
revocation, forged bytes, changed runtime assertion, real framed socket/CLI
parity, exact field/version/argument refusal, expired read deadline and inert
export during maintenance. Maintenance's own two journal transitions advance
revision 1 to 3; the read itself changes no revision. The first test used the
incorrect expected revision 2; its fixture was corrected to the actual existing
maintenance contract before claiming verification.

Formatting, warnings-as-errors compilation, 22-contract catalogue and Git
whitespace checks passed. Native export decoding/presentation, ergonomic
manual-original construction, installed service delivery and physical
qualification remain separate successors; no full suite or artifact was built
for this inert read. No branch, remote push or visibility change occurred.
