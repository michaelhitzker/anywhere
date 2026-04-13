# Security

Anywhere is currently intended for trusted local networks and private development environments.

## Current Model

- Execution stays on the developer's machine.
- Provider credentials and T3 Code auth remain in the local T3 Code setup.
- Non-loopback phone API requests require QR pairing.
- Pairing tickets are short-lived.
- Paired phone credentials expire after 30 days and can be revoked from the macOS Bridge.

The daemon exposes a local HTTP API, usually on port `4242`, and binds to `0.0.0.0` by default so a phone on the LAN can reach it. Do not expose this port directly to the public internet.

## Reporting Issues

Please report security concerns privately to the project maintainer before opening a public issue. Include:

- the affected component
- reproduction steps
- expected impact
- any relevant logs or request examples, with tokens and local paths removed

## Sensitive Local Files

Do not commit `.anywhere/` runtime state. It can contain local paths, project metadata, pairing state, and other machine-specific configuration.
