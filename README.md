# Anywhere

Anywhere is a local-first, open source companion for running T3 Code from your phone.

The goal is simple: keep the real work on the development machine that already has your repos, SDKs, simulators, devices, and T3 Code setup, while turning the phone into a clean control surface for dispatching work, following progress, and reviewing results.

## Status

Anywhere is early and moving fast. The current repo includes a working local daemon, a native macOS Bridge app, and a SwiftUI iOS client. It can pair a phone with the desktop bridge, discover the bridge on a LAN, sync T3-backed projects and tasks, start or continue T3 Code threads from the phone, show summaries and diffs, undo the latest T3 turn, and run eligible iOS projects on a connected iPhone through Xcode command-line tools.

Not yet implemented: off-LAN relay transport, Android project runs, full preview artifact generation, push notifications, and stack-specific Flutter / React Native adapters.

## Why Anywhere

Remote coding tools usually pull execution into somebody else's environment or rebuild a second coding UI. Anywhere takes a narrower path:

- T3 Code remains the source of truth for local auth, project state, and execution.
- The daemon exposes a phone-friendly bridge API.
- The macOS app stays a thin native shell around that daemon.
- The iOS app focuses on mobile task dispatch, progress, diffs, and device-oriented review.
- The Anywhere iOS app can directly start a run for eligible iOS projects: the Mac builds the app, installs it onto the paired phone, and launches it there.
- Repos and credentials stay on the developer's own machine.

## How It Works

```text
iPhone
  |
  | QR pairing + local HTTP API
  v
Anywhere Bridge for macOS
  |
  | launches and supervises
  v
desktop-agent-service
  |
  | syncs projects, threads, diffs, runs
  v
T3 Code + local repos + local toolchains
```

The daemon listens on port `4242` by default and advertises itself over Bonjour as `_anywhere-bridge._tcp`. Phone requests from the LAN require a paired credential. Local loopback requests are allowed so the macOS app and local development tools can configure the daemon.

## Components

### Desktop Agent Service

Path: `apps/desktop-agent-service`

The portable runtime boundary for Anywhere. It is a Node.js service that:

- exposes `GET /api/health`, settings, pairing, project, task, diff, summary, and run endpoints;
- stores local bridge settings under `.anywhere/`;
- syncs projects and tasks from the configured T3 Code runtime;
- submits new T3 Code turns from the phone-facing API;
- continues existing threads and can request an undo of the latest T3 turn;
- streams iOS run events over Server-Sent Events;
- advertises the bridge on the LAN through Bonjour.

### Anywhere Bridge for macOS

Path: `apps/desktop-ui/anywhere-bridge`

The native SwiftUI desktop companion. It:

- finds or lets you choose the Anywhere repo root;
- launches and stops the Node daemon;
- detects when another daemon is already using port `4242`;
- configures the T3 companion repo path and T3 state directory;
- shows daemon health, recent output, T3 status, and the LAN URL for phones;
- creates short-lived QR pairing tickets;
- lists and revokes paired phones.

This app is intentionally thin. Core orchestration belongs in the daemon so the runtime can stay portable.

### iOS App

Path: `apps/anywhere-ios`

The SwiftUI phone client. It:

- scans the Bridge pairing QR, with paste fallback for simulator or denied camera access;
- discovers nearby Bridges through Bonjour and LAN scanning;
- connects with a 30-day paired-device credential;
- lists synced projects and T3-backed threads;
- starts new T3 Code tasks or continues existing threads;
- chooses interaction mode and reasoning effort;
- shows summaries, messages, changed files, and inline diffs;
- can ask T3 Code to undo the latest turn;
- can start, monitor, and cancel iOS project runs on a connected physical iPhone when a project supports it.

## Requirements

- macOS for the native Bridge app and current iOS development workflow
- Node.js `22` or newer
- npm
- Xcode with iOS command-line tools
- A local T3 Code / `t3code-companion` checkout from [`michaelhitzker/t3code-anywhere`](https://github.com/michaelhitzker/t3code-anywhere), which includes the patches Anywhere needs
- A phone and Mac on the same network, or connected through the same Tailscale tailnet, for the current local-only transport

For iOS project runs from the phone, the Mac also needs:

- a connected or wirelessly paired physical iPhone;
- Developer Mode enabled on that iPhone;
- a local project with a shared Xcode workspace or project and a runnable scheme;
- signing configured well enough for `xcodebuild` and `xcrun devicectl` to build, install, and launch the app.

## Installation

Clone the repo and install the JavaScript dependencies:

```bash
git clone <repo-url> anywhere
cd anywhere
npm install
```

Check that the daemon compiles and tests pass:

```bash
npm run typecheck
npm test
```

Start the daemon directly:

```bash
npm run dev
```

Verify it locally:

```bash
curl http://127.0.0.1:4242/api/health
```

The daemon binds to `0.0.0.0:4242` by default so the phone can reach it from the LAN. You can override the bind address and port:

```bash
HOST=127.0.0.1 PORT=4242 npm run dev
```

## Configure T3 Code

Anywhere currently expects the patched T3 Code checkout at [`michaelhitzker/t3code-anywhere`](https://github.com/michaelhitzker/t3code-anywhere). Point the Bridge at that checkout rather than an unpatched upstream T3 Code install.

The recommended path is to configure this through the macOS Bridge app. For manual development, you can also set environment variables before starting the daemon:

```bash
T3CODE_COMPANION_PATH=/path/to/t3code-companion \
T3CODE_HOME="$HOME/.t3" \
npm run dev
```

Or configure the running daemon over loopback:

```bash
curl -X POST http://127.0.0.1:4242/api/settings \
  -H "Content-Type: application/json" \
  -d '{
    "t3": {
      "companionRepoPath": "/path/to/t3code-companion",
      "baseDir": "/Users/you/.t3",
      "host": "127.0.0.1",
      "port": 3773,
      "autoStartServer": true
    }
  }'
```

T3 state may live in either `~/.t3/userdata` or `~/.t3/dev`. Prefer the active runtime that is already running on the machine, especially when visible projects are in `dev` and `userdata` is empty.

## Run the macOS Bridge

Open the Xcode project:

```bash
open apps/desktop-ui/anywhere-bridge/anywhere-bridge.xcodeproj
```

Then run the `anywhere-bridge` scheme in Xcode.

In the app:

1. Choose the Anywhere repo root if it was not detected.
2. Confirm the Node binary path.
3. Choose the local `t3code-companion` checkout.
4. Choose the active T3 state directory.
5. Launch the daemon.
6. Create a QR pairing ticket.

The app will show both the local API URL and the mobile LAN URL. If another process is already bound to port `4242`, the Bridge will identify it and offer a stop action.

## Run the iOS App

Open the Xcode project:

```bash
open apps/anywhere-ios/anywhere.xcodeproj
```

Run the `anywhere` scheme on a physical iPhone or simulator.

On first launch:

1. Open Anywhere Bridge on the Mac.
2. Launch the daemon.
3. Create a QR pairing ticket.
4. Scan the QR code from the iOS app, or paste the pairing payload.
5. Select a synced project.
6. Send a message to start a T3 Code thread from the phone.

The current transport is local-network only. Pairing grants API access, but it does not make the Mac reachable from outside the LAN.

To make Anywhere truly anywhere today, connect the phone and Mac through Tailscale, then use the Mac's Tailscale IP or MagicDNS name as the Bridge address. Start with the [Tailscale quickstart](https://tailscale.com/docs/how-to/quickstart), then install Tailscale on [macOS](https://tailscale.com/docs/install/mac) and [iOS](https://tailscale.com/docs/install/ios). A built-in relay transport is still planned, but Tailscale is the recommended path for secure off-LAN access right now.

## Working With Tasks

Once paired, the iOS app can:

- start a new thread for the selected project;
- continue an existing thread;
- switch between Chat and Plan interaction modes;
- choose automatic, low, medium, or high reasoning effort;
- show synced thread messages and summaries;
- open changed files as rendered diffs;
- undo the latest T3 Code turn when the daemon reports that undo is available.

For iOS-capable projects, the play button starts a run from the phone. The daemon discovers the Xcode workspace or project, picks a non-test scheme, builds with `xcodebuild`, installs with `xcrun devicectl`, launches the app on a paired iPhone, and streams logs back to the phone.

## Development Commands

```bash
npm run dev        # start the desktop agent service
npm run start      # same entry point as dev
npm run typecheck  # TypeScript type check
npm test           # Node test runner for daemon tests
```

Useful local endpoints:

```text
GET  /api/health
GET  /api/settings
POST /api/settings
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

## Roadmap

### Next: Android Development Support

Android is the next major platform target. The bridge should detect Gradle and Android projects, run builds locally, install and launch on a connected device or emulator through `adb`, stream logs, capture screenshots, and surface run state in the phone app with the same clarity as iOS runs.

### Core Runtime

- Richer T3 thread sync beyond coarse snapshots.
- Worktree-aware task isolation for phone-started work.
- Persistent task and artifact metadata.
- Live task streaming for T3 output, approvals, and status transitions.
- Preview artifact generation for screenshots, short videos, build summaries, test summaries, and diff summaries.
- Optional relay transport for off-LAN access.
- Push notification adapters such as `ntfy` or Gotify.

### Later: Flutter And React Native

Flutter and React Native should become first-class adapters after the Android foundation is in place. Expected work includes project detection, `flutter` and Expo / React Native command integration, emulator or device launch flows, web preview URLs when available, screenshot/video capture, and stack-specific troubleshooting output that reads well on a phone.

## Repo Structure

```text
apps/
  desktop-agent-service/        Local daemon and bridge API
  desktop-ui/anywhere-bridge/   Native macOS Bridge app
  anywhere-ios/                 SwiftUI iOS phone client
docs/
  architecture.md               Product and system architecture
```

## Privacy And Security

Anywhere is designed to keep execution local. Your repositories, build tools, simulator/device access, T3 state, and provider credentials stay on the development machine.

Current security model:

- Phone access requires QR pairing for non-loopback API requests.
- Pairing tickets are short-lived.
- Paired phone credentials expire after 30 days.
- The macOS Bridge can revoke paired phones.
- No hosted relay is included yet.

The daemon currently exposes a LAN HTTP API. Treat it as a local development bridge, keep it on trusted networks, and do not expose port `4242` directly to the public internet.

## Contributing

Issues and pull requests are welcome. The best contributions keep the daemon portable, keep the macOS app thin, and improve real mobile development review loops with concrete artifacts.

Good first areas:

- Android run detection and `adb` launch support;
- daemon test coverage around T3 project sync and task lifecycle behavior;
- clearer setup errors for missing T3 state or inactive runtimes;
- preview artifact plumbing;
- iOS app polish for diffs, logs, and reconnection states.

Before opening a PR, run:

```bash
npm run typecheck
npm test
```

For Swift changes, also build or test the affected Xcode project from Xcode.

## License

MIT
