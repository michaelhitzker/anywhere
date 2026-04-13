# Architecture

## Goal

Anywhere is a local-first bridge for controlling T3 Code from a phone while keeping execution on the developer's own machine.

The system lets a user:

1. Run the Anywhere Bridge on the development machine.
2. Point it at the patched T3 Code checkout and active T3 state directory.
3. Pair the iOS client with the Bridge.
4. Start or continue T3 Code work from the phone.
5. Review progress, summaries, diffs, and eligible native iOS runs from the phone.

The required patched T3 Code checkout is:

https://github.com/michaelhitzker/t3code-anywhere

## Core Principles

- T3 Code is the source of truth for projects, threads, turns, checkpoints, worktrees, and provider auth.
- Anywhere does not own project management. It syncs and projects T3 Code state into a mobile-friendly API.
- Execution stays local to the developer's machine.
- The daemon owns portable orchestration behavior.
- Native apps should stay thin clients around the daemon API.
- Preview and run feedback should be concrete: logs, diffs, summaries, screenshots, recordings, build output, and device runs.

## Component Overview

```text
iOS app
  |
  | QR pairing, Bearer token, local HTTP API, SSE for iOS runs
  v
Anywhere Bridge for macOS
  |
  | launches, stops, configures, monitors
  v
desktop-agent-service
  |
  | owner token + orchestration snapshot/dispatch
  v
patched T3 Code runtime
  |
  | local repos, worktrees, SDKs, devices, credentials
  v
developer machine
```

The daemon listens on port `4242` by default and advertises itself over Bonjour as `_anywhere-bridge._tcp`. Local loopback requests are allowed for the macOS app and development tools. Non-loopback API requests require a paired phone credential except for health checks and pairing completion.

## Desktop Agent Service

Path: `apps/desktop-agent-service`

The daemon is a Node.js service and the portable runtime boundary. It should remain usable outside the macOS wrapper.

Current responsibilities:

- Store local daemon settings under `.anywhere/`.
- Configure the patched T3 companion checkout and T3 state base directory.
- Discover the active T3 runtime origin, including `userdata` and `dev` state.
- Start the patched T3 Code server when configured to auto-start it.
- Issue short-lived owner tokens through the T3 companion CLI.
- Fetch T3 orchestration snapshots.
- Dispatch new turns, follow-up turns, and undo commands through T3 orchestration.
- Map T3 projects and threads into a phone-facing project/task model.
- Render task summaries and per-file diffs from T3 checkpoint state.
- Manage QR pairing tickets and paired phone credentials.
- Require paired credentials for phone-originated API calls.
- Advertise the Bridge on the LAN through Bonjour.
- Build, install, launch, cancel, and stream logs for eligible native iOS projects on connected physical iPhones.

Important boundaries:

- The daemon should not maintain a separate project registry.
- The daemon should not provide generic add/remove project endpoints.
- Supplemental project metadata may exist only as a projection keyed by T3 workspace root, for example platform and preview modes.
- Stack-specific run and preview logic should live behind daemon adapters rather than inside the phone UI.

Key daemon modules:

- `src/index.ts`
  HTTP server, endpoint routing, pairing enforcement, SSE response handling, daemon startup/shutdown.
- `src/t3-bridge.ts`
  T3 runtime discovery, owner-token issuing, orchestration snapshot fetches, dispatch commands, task mapping, summary/diff rendering.
- `src/pairing-store.ts`
  QR pairing tickets, hashed pairing secrets, hashed client tokens, expiry, revocation.
- `src/settings-store.ts`
  Local T3 companion path, T3 state path, host, port, and auto-start settings.
- `src/project-metadata-store.ts`
  Supplemental phone-specific metadata keyed by workspace root.
- `src/project-capabilities.ts`
  Shared project shape and capability detection, currently including iOS/Xcode support checks.
- `src/ios-run-manager.ts`
  Native iOS run orchestration using `xcodebuild` and `xcrun devicectl`.
- `src/bonjour-advertiser.ts`
  LAN service advertisement.

## HTTP API Shape

Current useful endpoints:

```text
GET  /api/health
GET  /api/settings
POST /api/settings
GET  /api/pairing/status
POST /api/pairing/tickets
POST /api/pairing/complete
DELETE /api/pairing/clients/:id
GET  /api/projects
GET  /api/tasks
POST /api/tasks
GET  /api/tasks/:id/summary.txt
GET  /api/tasks/:id/diff.txt?path=<file>
POST /api/tasks/:id/turns
POST /api/tasks/:id/undo
POST /api/projects/:id/runs
GET  /api/runs/:id
GET  /api/runs/:id/events
POST /api/runs/:id/cancel
```

`GET /api/projects` is a T3 Code sync projection. There is intentionally no general Anywhere-owned project registry endpoint.

## T3 Runtime Integration

The daemon talks to the patched T3 Code runtime in two ways:

- CLI calls through the configured `t3code-companion` checkout for server startup and short-lived owner tokens.
- HTTP calls to the T3 orchestration API for snapshots and dispatch commands.

Runtime selection matters:

- T3 state may live in `~/.t3/userdata` or `~/.t3/dev`.
- The active runtime can differ from the default configured host/port.
- The daemon should prefer the active runtime origin when it can detect one.
- Missing projects are often a runtime/state mismatch, not an Anywhere project-sync bug.

## macOS Bridge

Path: `apps/desktop-ui/anywhere-bridge`

The macOS app is a native SwiftUI wrapper around the daemon.

Current responsibilities:

- Discover or choose the Anywhere repo root.
- Configure the Node binary path.
- Configure the patched T3 companion checkout and T3 state directory.
- Launch and stop the Node daemon.
- Detect another process already bound to port `4242`.
- Poll daemon health and settings.
- Show daemon output, local URL, and mobile LAN URL.
- Create short-lived QR pairing tickets.
- List and revoke paired phones.

The app should stay thin. It may handle process management, local setup UI, macOS-specific affordances, and pairing UI, but it should not absorb core orchestration logic from the daemon.

App Sandbox is disabled because the app needs to launch Node and interact with arbitrary local repositories and developer tooling.

## iOS Client

Path: `apps/anywhere-ios`

The iOS app is the phone control surface.

Current responsibilities:

- Scan or paste QR pairing payloads.
- Store the paired bridge credential locally.
- Discover nearby Bridges through Bonjour and LAN scanning.
- Connect to a manual LAN, loopback, Tailscale, or MagicDNS URL.
- List T3-synced projects and threads.
- Start a new T3 task for a selected project.
- Continue an existing T3 thread.
- Choose interaction mode and reasoning effort.
- Show task messages, summaries, changed files, and inline diffs.
- Request undo for the latest T3 turn when available.
- Start and cancel native iOS runs for eligible projects.
- Consume Server-Sent Events for iOS run logs and state changes.

The iOS app should not duplicate T3's project model or provider auth. It should present a mobile projection of daemon state.

## Pairing And Security

Pairing is local and bridge-specific:

- The macOS app requests a pairing ticket from the loopback-only pairing control API.
- The daemon creates a short-lived ticket and QR payload.
- The phone sends the ticket ID and secret to `/api/pairing/complete`.
- The daemon returns a 30-day client token.
- The phone sends that token as `Authorization: Bearer <token>` for subsequent non-loopback API calls.
- Pairing secrets and client tokens are stored hashed on disk.
- Pairing controls are restricted to loopback, including status, ticket creation, and revocation.

Current transport:

- LAN HTTP.
- Bonjour discovery.
- Optional user-managed VPN/tunnel such as Tailscale.

Not currently included:

- hosted relay,
- custom hosted sign-in,
- public internet exposure,
- mTLS.

## Task Lifecycle

1. The iOS app submits a prompt for a selected T3 project or selected thread.
2. The daemon validates the paired phone credential.
3. The daemon ensures a usable T3 runtime origin.
4. The daemon issues a short-lived T3 owner token.
5. The daemon dispatches the new turn or follow-up turn through the T3 orchestration API.
6. The daemon reloads the T3 snapshot and maps threads into task objects.
7. The phone polls tasks and can fetch summaries or diffs.
8. Undo requests are dispatched back through T3 when a checkpoint is available.

Current task updates are mostly snapshot/polling based. iOS run logs use SSE. Rich live T3 task streaming remains future work.

## Native iOS Run Lifecycle

1. The phone asks the daemon to start a run for a project.
2. The daemon looks up the project from the T3-synced project list.
3. The daemon checks whether the project is iOS-capable by platform metadata or nearby Xcode containers.
4. The daemon discovers `.xcodeproj` or `.xcworkspace` containers.
5. The daemon chooses a runnable non-test scheme.
6. The daemon picks a connected physical iPhone via `xcrun devicectl`.
7. The daemon builds with `xcodebuild`.
8. The daemon finds the built `.app`, reads its bundle identifier, installs it, and launches it.
9. The daemon streams run state and log lines over `/api/runs/:id/events`.
10. The phone can cancel the active run.

Derived data for runs is cleaned up unless `ANYWHERE_KEEP_RUN_DERIVED_DATA` is set.

## Local State

`.anywhere/` is local runtime state and is ignored by Git.

Expected files include:

- `settings.json`
  Local T3 companion path, T3 state base directory, host, port, and auto-start preference.
- `project-metadata.json`
  Supplemental phone-facing metadata keyed by T3 workspace root.
- `pairing.json`
  Pairing tickets and paired clients with hashed secrets/tokens.

Do not use `.anywhere/` for portable project definitions. T3 Code owns project membership.

## Roadmap Boundaries

Near-term architecture work should focus on:

- Android run support through Gradle and `adb`.
- Richer T3 task streaming beyond snapshot polling.
- Worktree-aware mobile review state surfaced from T3.
- Preview artifact generation.
- Optional secure off-LAN transport.
- Push notification adapters.

Deferred or out of scope:

- generic project management inside Anywhere,
- hosted T3 execution,
- parallel provider auth in the phone client,
- broad CI/CD automation,
- multi-user organization features.
