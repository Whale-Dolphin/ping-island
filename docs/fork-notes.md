# Session-monitor fork

This branch preserves the locally developed Ping Island changes on top of upstream **v0.27.0**, commit `b4d6f1a`. It is a source-development branch named `personal/session-monitor-fixes`, not a new official Ping Island release or a merge of newer upstream changes. The original Apache-2.0 license and attribution remain in place.

## Behavior changes

| Area | Changes in this branch |
| --- | --- |
| Session state | Distinguish disconnected remote sessions from connected execution; completed turns waiting for another message do not automatically request human attention. Local process liveness checks exclude remote PIDs. |
| Codex responsiveness | Watch rollout lifecycle/tool events, request immediate parsing, and retain a deferred refresh when parsing is already in progress. Avoid treating a previous turn's final response as completion of a newly started task. |
| Codex Approve for Me | Forward the active approval-reviewer mode from hooks/rollouts, defer automatic-review hook requests back to Codex, and clear resolved app-server requests. This does not implement unconditional approval of every command. |
| OpenCode | Handle both `session.status(idle)` and `session.idle`, deduplicate adjacent idle events, and retain final assistant text as a completed reply. Older bare OpenCode `Stop` events map to idle. |
| Hermes | Generated plugins honor the supplied bridge arguments and environment, including remote socket paths. |
| Remote transport | Persist a bounded outbox, acknowledge processed events, replay unacknowledged events after reconnect/service restart, and handle partial socket writes. Retry eligible remote connections with backoff. |
| Remote installation | Compare bridge checksums before reusing an installation and support a locally supplied Linux bridge binary. |
| Session identity | Deduplicate proven duplicate local Claude process identities instead of every session sharing a project directory. Preserve the original Claude project label when tool working directories move into a nested folder. |
| Notifications | Queue completions while other sessions are active or the panel is open. Identify queued notifications by event kind, session, and activity timestamp; preserve the queued snapshot when later session activity arrives. |
| Floating UI | Show all selected active/attention sessions instead of truncating to three. Use compact rows when regular rows exceed the screen-height budget, then scroll if necessary. Keep the pet's execution animation and light/dark count color aligned with session state and appearance. |

## Build the macOS app

Use the full Xcode app, not only Command Line Tools. On the development machine the installed toolchain is selected per command:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project PingIsland.xcodeproj -scheme PingIsland \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/fork-release CODE_SIGN_IDENTITY=- build
```

If Xcode is installed elsewhere, change `DEVELOPER_DIR` accordingly. The built app is `build/fork-release/Build/Products/Release/Ping Island.app`. For a locally shareable ad-hoc-signed ZIP/DMG, the existing `scripts/package-unsigned.sh` builds and packages the app; it recreates its `build/unsigned` staging directory and package outputs. Local packages are not notarized.

The app version and upstream download/update configuration have not been changed for this source publication. An upstream download or update does not necessarily include this branch's fixes. No signing keys, local configuration, session transcripts, installed hook files, or generated packages are committed here.

## Linux remote bridge

The remote machine runs a compiled bridge as well as harness hooks. For the patched remote behavior, use a Linux bridge compiled from the same source revision as the Mac app. A Swift runtime is not required on the remote host when using the static musl build.

`RemoteBridgeAssetResolver` checks these **Mac-side** override paths before its existing cache/upstream download flow:

```text
~/.ping-island/custom-bridges/PingIslandBridge-linux-musl-x86_64
~/.ping-island/custom-bridges/PingIslandBridge-linux-musl-aarch64
```

The override must be a readable, executable Linux binary for the target architecture. The Mac's connection/bootstrap path compares its checksum with the installed remote bridge and updates mismatched installations. Without an override, the existing cache/download flow can select the upstream v0.27.0 bridge, which does not contain all of this branch's changes. See `.github/workflows/release-packages.yml` for the existing pinned Swift/static-SDK build recipe. Creating this fork does not run that release workflow or publish Linux artifacts.

## Verification record

Source-publication checks on **2026-09-06**, using Xcode 27.0 (`27A5228h`):

- `git diff --check`: passed.
- `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path Prototype`: **147 tests passed**, including process/socket integration tests for remote replay, approval metadata forwarding, and completed Codex rollout status.
- Xcode app unit tests: blocked during compilation by actor-isolation errors in `NativeRuntimeSessionStoreTests.StubRuntime`, `SessionMonitorNativeRuntimeTests.StubRuntimeCoordinator`, and `RecordingTelemetrySink`. Their definitions and corresponding protocols are unchanged from the base commit. App-level tests, including the added layout tests, were not executed in this run.
- Universal Release build: passed with `-configuration Release -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO`. This verifies compilation, not signing, notarization, installation, or live UI behavior.

Reproduce the app test check with:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project PingIsland.xcodeproj -scheme PingIsland \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/fork-tests CODE_SIGNING_ALLOWED=NO \
  test -only-testing:PingIslandTests
```

## Remaining limits

- This branch does not guarantee an exactly-once notification for every turn. Completion keys use activity timestamps; the notification registry and UI queues are in memory. Event ordering, rediscovery, and missed lifecycle events still require further work.
- The remote outbox is capped at 4,096 messages or 16 MiB and drops oldest events at the limit. Persistence failure is logged; this is not an unbounded durable event service.
- The remote service currently has one active control client. Multiple Macs attaching to the same remote installation can replace one another; this is not broadcast delivery.
- The Air compact-layout build was installed previously, but the expanded-window visual acceptance check was not completed. Geometry estimates and automatic compact rows do not guarantee that any number of rows fits without scrolling.
- Updating generated plugin files does not hot-reload every running harness. Restart the affected OpenCode/Hermes process when its plugin needs to be reloaded.
- The source-publication checks do not reinstall applications, update remote hooks, rerun live agent sessions, or resolve all previously reported state/connection issues.
