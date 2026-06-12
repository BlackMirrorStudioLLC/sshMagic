# Changelog

All notable changes to sshMagic are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_Nothing yet._

## [0.1.0] — 2026-06-12

Initial development version: a working, native macOS SSH manager.

### Added

- **Network discovery**
  - Passive Bonjour discovery of `_ssh._tcp` services via `NWBrowser`.
  - Active TCP‑22 subnet sweep, scoped to physical (`en*`) interfaces so virtual
    bridge/VPN networks don't balloon the scan.
  - Reverse‑DNS / mDNS hostname resolution for discovered IPs.
  - De‑duplicated, source‑badged host list (Bonjour / Scan / Saved), live‑updating
    while a scan runs.
- **Embedded SSH terminals**
  - Per‑tab `ssh` sessions in a real PTY via SwiftTerm, inheriting `~/.ssh/config`,
    keys, agent, `known_hosts`, and jump hosts.
  - Closeable tabs with live OSC‑driven titles; reconnect on disconnect.
- **Authentication**
  - Connect dialog for username + optional password, with a "remember" option.
  - Passwords stored in the macOS Keychain and delivered to `ssh` via
    `SSH_ASKPASS` (never on the command line).
  - Per‑host saved logins; "Connect As…" for ad‑hoc credentials.
- **Integrated SFTP file browser**
  - Native side panel per session with directory browsing and navigation.
  - Drag files in from Finder to upload; drag rows out to Finder to download.
  - Upload picker and "Download to Downloads" actions.
  - SSH connection multiplexing (one authenticated control connection per
    session) for fast, no‑re‑auth transfers.
- **Ghostty hand‑off** — right‑click a host to open the session in Ghostty.
- **Saved hosts** — manual host entry, persisted locally.
- **App icon** — generated programmatically (`scripts/make_icon.swift`) into a
  multi‑resolution `.icns`; used for the bundle and Dock.
- **Packaging** — `scripts/bundle_app.sh` assembles, configures (Local Network /
  Bonjour usage), icons, and ad‑hoc signs `sshMagic.app`.
- **Tooling & CI** — GitHub Actions: build + test + bundle smoke test (macOS),
  SwiftLint, swift‑format, Trojan‑Source Unicode scan, ShellCheck, zizmor
  workflow audit, automated PR review, and Dependabot.

### Notes

- Distributed under a proprietary license (see `LICENSE.md`).
- Mac App Store distribution will require sandboxing work (an in‑process SSH/SFTP
  stack) — see the Distribution section of `README.md`.

[Unreleased]: https://github.com/BlackMirrorStudioLLC/sshMagic/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/BlackMirrorStudioLLC/sshMagic/releases/tag/v0.1.0
