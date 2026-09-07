# Integrated fork notes

This branch integrates the local session-monitor work from
`personal/session-monitor-fixes` into the public `main` architecture. It is a
source-development branch, not an official Ping Island release.

## Provenance

- Integration base: `4f087b88c0e313c147e57daee42b9b9c328def4f` (public `main`, source version 0.30.0).
- Original local implementation: `838d84f7da4fa168479d8261f5340141fbea8044`.
- Original local documentation tip: `e62c95ea07e3bfaefb7d2832e180d808f4328f5f`.
- Common ancestor: `b4d6f1ab678b1fbd5ddb1816b666f0ab641dfc23` (v0.27.0).

The integration preserves the newer `main` implementations for transcript
incremental parsing, actor-reentrancy protection, bounded liveness evidence,
completion identity, themes, client integrations, and Codex task boundaries.
Local behavior was reapplied at those current extension points rather than by
replacing whole files with their v0.27-era versions.

## Integrated behavior

| Area | Behavior retained or added |
| --- | --- |
| Session lifecycle | Connected execution, completed waiting, disconnected remote sessions, and genuine manual attention are distinct. A remote PID is never evaluated in the Mac process namespace. Late assistant transcript writes after `Stop` cannot restart a completed turn; a genuinely newer user message can. |
| Session identity | Only proven duplicate local Claude process identities are collapsed. Independent agents in one workspace remain separate, and the original transcript project label survives tool working-directory changes. |
| Codex Approve for Me | The active `approvals_reviewer` is carried through app-server, rollout, local hook, and remote paths. `auto_review` remains Codex-owned automatic review: Ping Island acknowledges and defers it without returning an unconditional allow/deny decision or weakening the workspace sandbox. |
| Codex lifecycle | Rollout lifecycle/tool records request immediate parsing, and a refresh arriving during an incremental parse is retained for a follow-up read. Old final content cannot complete a newly started task. Resolved app-server requests are cleared only when request IDs match. |
| Remote transport | State events use processed acknowledgements, complete socket writes, bounded persisted replay, reconnect backoff, bridge checksum replacement, and optional same-revision Linux bridge overrides. Responsive requests fail open when their live client disconnects instead of replaying stale approvals. |
| Completion UI | Blocked completion notifications remain queued by `SessionCompletionKey` with an immutable snapshot. Switching between docked and detached surfaces does not consume or overwrite the pending turn. |
| Floating UI | Every selected executing or manually blocked session remains available. Rows become constrained before the panel scrolls instead of truncating the list to three. |
| Notification audio | Each cue is pinned to the output device already alive and selected on the Mac. AirPods already connected to the Mac remain valid, while playback startup cannot request an automatic handoff from another device. If that device is unavailable, only a built-in speaker fallback is allowed; otherwise the cue is skipped. Disabled or zero-volume playback does not start an audio stream. |

The original Apache-2.0 license and upstream attribution remain unchanged.

## Remote bridge compatibility

The remote acknowledgement/replay protocol spans the macOS app and
`PingIslandBridge`; build and deploy them from the same source revision. The
outbox is deliberately bounded to 4,096 messages or 16 MiB and drops its oldest
eligible state events at the limit. It is not an unbounded exactly-once event
service.

Mac-side Linux bridge overrides remain available at:

```text
~/.ping-island/custom-bridges/PingIslandBridge-linux-musl-x86_64
~/.ping-island/custom-bridges/PingIslandBridge-linux-musl-aarch64
```

No remote bridge or hook is deployed merely by building or testing this branch.

## Verification record

Checks run locally on 2026-09-07 with Xcode 26.6 (`17F113`), Apple Swift 6.3.3,
and the macOS 26.5 SDK. Unit and logic builds used isolated HOME/TMPDIR/DerivedData
directories. UI tests used an ad-hoc-signed test app; live smoke tests launched the
candidate from its build directory rather than installing it first.

- Public-main baseline: 146 Prototype tests passed; unsigned Release compilation passed.
- Public-main app unit-test baseline: three existing failures were recorded in detached-window hover behavior and Codex rollout fallback-path selection.
- Integrated candidate: 158 Prototype tests passed; the final unsigned Release build passed and produced a universal 0.30.0 build 79 app.
- Integrated app unit tests: 1,095 passed and 1 was intentionally skipped because the installed Node runtime cannot strip TypeScript for the generated OMP hook test.
- UI tests: the public baseline and first candidate run both exposed three pre-existing language/hit-testing failures. After replacing localized assertions with identifiers and explicitly scrolling the sidebar, all 4 candidate UI tests passed.
- A real Claude Code CLI session completed `SessionStart → UserPromptSubmit → Stop → SessionEnd`; the final transcript append stayed ended and the row was reaped normally.
- A real Codex `--approve-for-me` network action emitted `PermissionRequest` with `approvals_reviewer=auto_review`; Ping Island returned no approval decision or manual intervention, Codex's automatic reviewer permitted the retry, and the turn completed.
- The split-JSON hook regression passed 10 consecutive repetitions.
- `git diff --check` and plist validation passed after the final test run.

The first Prototype candidate run exposed a missing remote-control decoder and a
10 ms partial-JSON timing race. Both were fixed before the first complete candidate
pass; after protocol-review regressions were added, the final suite reached 158
passing tests.

## Local installation record

`package-unsigned.sh` now builds both its main and fallback paths for generic macOS
with `ONLY_ACTIVE_ARCH=NO`. The resulting app and embedded bridge are universal
`arm64 + x86_64`, version 0.30.0 build 79, and pass deep ad-hoc signature validation.
The ZIP and DMG were generated; Finder styling timed out and the packaging helper
correctly fell back to a plain DMG layout.

The verified app was installed at `/Applications/Ping Island.app` and launched with
its hook socket healthy. The managed `~/.ping-island/bin/PingIslandBridge` checksum
matches the embedded bridge. The prior 0.27.0 build 68 remains available at:

```text
/Applications/Ping Island.app.backup-before-integrated-20260907-231327
```

## Remaining validation boundary

Per the requested acceptance boundary, no notification sound was played: read-only
CoreAudio probes observed the resolver choose the built-in speaker when AirPods were
absent from the Mac device list and choose the AirPods UID when they were the Mac's
live default. Unit tests verify that playback always receives that explicit, alive
UID and never falls back to an automatic nil/default route. CoreAudio discovery and
playback are not one atomic OS operation, so this is an app-side no-handoff guarantee
rather than a claim about every concurrent system route change. No remote bridge was
deployed, no package was notarized, and manual multi-session/detached-window visual
acceptance beyond the UI suite was not run.
