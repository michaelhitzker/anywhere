# AGENTS.md

## Project Intent

`anywhere` is an open source, local-first companion for using T3 Code from a phone.

The target flow is:

1. A developer has projects, SDKs, simulators, devices, credentials, and T3 Code working on their development machine.
2. They open the Anywhere iOS client from a phone.
3. The phone talks to the local Anywhere Bridge.
4. The local daemon dispatches work to the patched T3 Code runtime on the developer's machine.
5. The phone shows progress, summaries, diffs, and run/review affordances without moving execution to a hosted environment.

The product should feel like:

- install the open source bridge,
- point it at the patched T3 Code checkout once,
- pair the phone,
- use the phone as the control surface,
- keep execution on the developer's own machine.

## Current Architecture

The repo is split into three app surfaces:

- `apps/desktop-agent-service`
  Node.js daemon. This is the portable runtime boundary and phone-facing HTTP API. It owns T3 Code sync, task dispatch, pairing, local settings, iOS run orchestration, and LAN discovery advertisement.
- `apps/desktop-ui/anywhere-bridge`
  Native SwiftUI macOS companion. It is a thin shell for launching, stopping, configuring, and monitoring the daemon. It also creates QR pairing tickets and manages paired phones.
- `apps/anywhere-ios`
  Native SwiftUI phone client. It pairs with the Bridge, discovers it over Bonjour/LAN scanning, lists T3-backed projects and tasks, starts or continues T3 turns, shows messages/diffs/summaries, supports undo, and can start/cancel iOS runs for eligible projects.

Supporting docs live in:

- `README.md`
  User-facing setup, status, commands, API endpoint overview, and roadmap.
- `docs/architecture.md`
  Current system architecture and boundaries.

## T3 Code Integration

Anywhere currently expects the patched T3 Code checkout at:

https://github.com/michaelhitzker/t3code-anywhere

Use that checkout for `T3CODE_COMPANION_PATH` and Bridge configuration. Do not assume an unpatched upstream T3 Code install has the orchestration endpoints and behavior Anywhere needs.

Important runtime notes:

- T3 Code is the source of truth for project and execution state.
- Anywhere should sync projects from T3 Code; it should not maintain its own project registry.
- Do not add general project-management features to Anywhere unless they are a deliberate projection of T3 behavior for phone UX.
- T3 state may live in either `~/.t3/userdata` or `~/.t3/dev`.
- Prefer the active T3 runtime that is already running instead of assuming `userdata`.
- When debugging missing projects, verify which runtime is active and which state directory it uses before changing bridge logic.

## Product Constraints

- Do not automate the T3 desktop app UI.
- Prefer T3 Code's local runtime, auth, and orchestration surfaces instead of rebuilding them here.
- Keep execution local so repos, simulators, SDKs, devices, and credentials stay where they already work.
- Keep the daemon boundary portable and avoid macOS-only dependencies in core daemon logic.
- Keep the Swift macOS app thin and native.
- Optimize for mobile development review: summaries, diffs, logs, previews, and physical-device run feedback matter more than generic dashboard polish.
- Avoid re-implementing T3 features unless the phone-specific UX clearly needs a projection or adapter.

## Current Daemon Behavior

The daemon currently:

- serves a local HTTP API on port `4242` by default,
- binds to `0.0.0.0` by default so paired phones on the LAN can reach it,
- advertises over Bonjour as `_anywhere-bridge._tcp`,
- stores local runtime state under `.anywhere/`,
- exposes health, settings, pairing, project sync, task, diff, summary, undo, and iOS run endpoints,
- requires paired credentials for non-loopback API requests except health and pairing completion,
- keeps pairing controls local to loopback,
- issues short-lived QR pairing tickets,
- stores only hashed pairing secrets/tokens,
- syncs projects and threads from T3 Code snapshots,
- dispatches new T3 turns and follow-up turns through T3 Code orchestration,
- renders task summaries and per-file diffs from T3 checkpoints,
- runs eligible iOS projects on connected physical iPhones through `xcodebuild` and `xcrun devicectl`,
- streams iOS run events over Server-Sent Events.

The daemon should not:

- own a separate project registry,
- add/remove T3 projects as a generic API surface,
- expose raw provider credentials to the phone,
- assume every project is an iOS project,
- assume one universal live-preview strategy for every stack.

## Local State

Runtime files under `.anywhere/` are local machine state and should stay ignored by Git.

Expected examples:

- `.anywhere/settings.json`
- `.anywhere/project-metadata.json`
- `.anywhere/pairing.json`

These files can contain local paths, project metadata overlays, pairing state, and token hashes. Do not commit them.

`project-metadata-store` is a phone-specific projection layer for metadata such as platform and preview modes. Treat it as supplemental metadata keyed by T3 workspace root, not as project ownership.

## Preview And Run Strategy

Preview is a first-class feature, but it is intentionally tiered:

- Universal artifacts: screenshots, short recordings, build/test summaries, and diff summaries.
- Near-universal access: web preview URLs and remote desktop handoff when available.
- Stack-specific adapters: native iOS, Android, Flutter, React Native, Expo, and other workflows as they become explicit integrations.

The current strong run path is native iOS:

- T3 supplies the project/workspace root.
- Anywhere detects Xcode projects/workspaces.
- The daemon picks a runnable non-test scheme.
- The daemon builds, installs, launches, streams logs, and allows cancellation.

Android, Flutter, React Native, and full preview artifact generation remain roadmap items.

## Security Stance

Anywhere is currently for trusted local networks or a user-managed private network such as Tailscale.

- The daemon exposes LAN HTTP, not a public internet API.
- Pairing grants API access but does not create off-LAN reachability.
- Do not expose port `4242` directly to the public internet.
- Do not add hosted auth or relay assumptions unless the feature is explicitly about that transport.
- Phone clients should receive paired bridge credentials only, not provider credentials.

## Development Commands

Use these before handing off daemon changes:

```bash
npm run typecheck
npm test
```

For Swift changes, also build or test the affected Xcode project:

- `apps/desktop-ui/anywhere-bridge/anywhere-bridge.xcodeproj`
- `apps/anywhere-ios/anywhere.xcodeproj`

When editing Xcode projects, avoid committing user state such as `xcuserdata/` and `*.xcuserstate`.

## Working Assumptions For Future Agents

- Treat this repo as a local-first orchestration product, not a generic website.
- Prefer daemon changes for portable bridge behavior.
- Prefer macOS app changes only for desktop wrapper behavior, process control, local setup UI, and pairing UI.
- Prefer iOS app changes only for phone UX, pairing, mobile review, diff/log presentation, and run controls.
- Treat T3 Code as the source of truth for projects, threads, turns, worktrees, checkpoints, and auth.
- Keep project sync read-oriented from T3 unless there is a very explicit reason to project a T3 action into the phone UI.
- Prefer real artifacts and logs over abstract "done" states.
- When debugging daemon startup failures, check whether another daemon is already bound to port `4242` before assuming the launch path is broken.
- When debugging iOS run failures, check device pairing, Developer Mode, signing, scheme selection, and `xcrun devicectl` output.
- When adding new stack adapters, keep them behind daemon-side detection/adapters instead of baking stack-specific assumptions into the phone client.

## Near-Term Product Direction

- Android run support through Gradle and `adb`.
- Richer T3 thread sync and live task event streaming beyond polling snapshots.
- Worktree-aware mobile review state.
- Preview artifact generation for screenshots, videos, build summaries, test summaries, and diff summaries.
- Optional secure off-LAN transport.
- Push notifications through pluggable backends such as `ntfy` or Gotify.
