# Contributing

Thanks for helping improve Anywhere.

Anywhere is a local-first bridge for using T3 Code from a phone. Contributions should keep T3 Code as the source of truth for project and execution state, keep the daemon portable, and keep the native macOS app as a thin wrapper around that daemon.

## Development Setup

```bash
npm install
npm run typecheck
npm test
```

For Swift changes, also build or test the affected Xcode project from Xcode:

- `apps/desktop-ui/anywhere-bridge/anywhere-bridge.xcodeproj`
- `apps/anywhere-ios/anywhere.xcodeproj`

## Pull Requests

Before opening a pull request:

- run `npm run typecheck`
- run `npm test`
- build the affected Swift app if you changed iOS or macOS code
- avoid committing `.anywhere/`, Xcode user state, local T3 paths, or generated build output

When adding features, prefer asking whether the behavior belongs in the daemon, the macOS shell, or the phone client. Core orchestration should live in the daemon unless it is specifically native desktop wrapper behavior.
