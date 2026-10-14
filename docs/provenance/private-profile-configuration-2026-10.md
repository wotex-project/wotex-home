# Private installed authoring configuration evidence

Recorded: 2026-10-14. Runtime source:
754dc1157bdbd128983052afbb83093ad6c99060 on main.
Owner: [private profile configuration](../specs/private-profile-configuration-v1.md),
WOH.08 startup, WOH.16 local policy/recovery and WOH.18 authoring installation.

Default Host startup now selects one immutable private authoring file when no
explicit native profile_installation option is present. Its checked snapshot
binds raw SHA, descriptor and ancestor witnesses before children start. The new
authoring-only native mode supplies no capture, reader or publisher; it starts
no source/report custody. Manual assessment remains capture-not-supplied, source
attribution remains inert, and complete review refuses missing capture.

## Executed checks

Elixir 1.19.6 / OTP 28.5.0.6; Apple Swift 6.4, Swift 6 mode, arm64 macOS 15
target. Mix checks used WOTEX_HOME_GIT_DEPS=1 MIX_ENV=test.

`mix test test/wotex_home/private_profile_configuration_test.exs` passed eight
substantial cases in 12.4 seconds:

- Both independent draft families reconstruct actual runtime authoring contracts
  with nil capture/reader/publisher. Unknown fields/formats, caller capture/PID/
  producer, malformed binding/limits, float/bool limits, missing fields, invalid
  UTF-8, duplicate names and byte/depth excesses refuse.
- Exact private publication produces 0400 one-link original bytes. Identical
  retry returns the same safe digest/count metadata; a changed limit produces
  different bytes and refuses replacement. Concurrent distinct publications
  retain exactly one original. File and parent-directory synchronization failure
  remove only the attempted publication; no database or host starts.
- Captured snapshots refuse same-size byte changes, inode replacement, file
  appearance after an absent selection, permissive modes, hard/symbolic links
  and changed private parent mode. Snapshot inspection omits configuration.
- Actual default Host file startup exports grammar, imports owned objects,
  produces compatible manual candidates and attributed source-only reviews for
  both families. Complete review refuses authoring_capture_unavailable without
  a new revision. Dispatch stays disabled; no reader/source/report owner exists.
- A changed disk limit does not affect Store-child restart: current basis and
  original candidate history stay pinned. Full Host restart selects the new
  limit and contract identity. Explicit native nil overrides the file and keeps
  authoring unavailable. Bad present files create no Store or socket.
- Fresh ordinary Application processes select the file using only their private
  data-root setting; malformed configuration stops before Store acquisition and
  prints no private canary/descriptor. A fresh native-parent CoreHost processes
  an actual framed identity request with the file installed and terminates on
  EOF. These are real OTP/pipe checks, not signed app installation.
- A fresh Mix installer process with a deliberately invalid startup-trap root
  publishes the valid selected file and starts no Home database/background host.
  Output contains only safe digest/count metadata.

`mix test test/wotex_home/private_profile_native_review_test.exs` passed one
actual-Store/native case in 52.5 seconds, including fresh complete Swift fixture
compilation. Both families prepare a complete review under file-loaded grammar
with no capture, publish the exact original and receive its definitive refusal.
The native coordinator clears the pending original, exposes no successful
receipt and commits no review revision. The added refusal code changes no
unknown/lost-reply recovery behavior.

Twenty existing Host/full-installation/runtime regressions pass in 4.0 seconds,
preserving legacy publisher/capture custody and restart behavior. Application
typecheck, fresh native fixture compile, formatting, warnings-as-errors Home
compilation, 22-contract catalogue and Git whitespace checks passed.

Logs: /tmp/home-private-profile-live.log,
/tmp/home-private-profile-native.log,
/tmp/home-private-profile-regressions.log,
/tmp/home-private-profile-typecheck.log.

The first new fixture run attempted writes to immutable files and assumed the
two families had different installed grammar. Explicit owner-mode/replacement
mutations and a changed limit corrected those oracles before passing. No runtime
immutability rule was relaxed.

This does not establish signed/fresh-account macOS installation, systemd/Nerves
board behavior, storage power-loss survival, qualified protocol publication,
current physical capture or device qualification. Local policy remains outside
profile/Store archives and cannot be restored as current authority. No dependency,
sibling API, remote push or repository visibility change was required. Catalogue
parents keep broader partial/missing axes.
