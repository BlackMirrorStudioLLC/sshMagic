<div align="center">

# sshMagic

**A native macOS SSH manager — scan your network, find devices, and connect in embedded terminal tabs with an integrated SFTP file browser.**

MobaXterm‑style power, with a clean Mac look.

_A [BlackMirror Studio LLC](https://github.com/BlackMirrorStudioLLC) product._

</div>

---

## Features

- **Network discovery** — passive Bonjour (`_ssh._tcp`) plus an active TCP‑22
  subnet sweep of your physical LAN. Discovered IPs are resolved to hostnames
  (reverse DNS / mDNS) and merged with your saved hosts into one de‑duplicated,
  badge‑labelled list.
- **Embedded SSH terminals** — each tab runs the system `ssh` in a real PTY
  (powered by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)), so your
  `~/.ssh/config`, keys, agent, `known_hosts` and jump hosts all just work. Tabs
  are closeable with live, OSC‑driven titles.
- **Username & password auth** — a clean connect dialog captures the login;
  passwords are stored in the **macOS Keychain** and supplied to `ssh`
  non‑interactively via the supported `SSH_ASKPASS` mechanism (never on the
  command line). Logins are remembered per host.
- **Integrated SFTP file browser** — a native side panel per session:
  browse the remote filesystem, **drag files in from Finder to upload**, and
  **drag rows out to Finder to download**. Uses SSH connection multiplexing, so
  it authenticates once and transfers ride the existing connection.
- **Open in Ghostty** — right‑click any host to launch the session in
  [Ghostty](https://ghostty.org) instead of an embedded tab.
- **Saved hosts** — add endpoints by hand (off‑subnet boxes, DNS names); they
  persist locally.

## Requirements

- macOS 13 (Ventura) or later
- A recent Swift toolchain (Xcode 16+) to build

## Build & run (development)

```sh
# Quick iteration (no Local Network permission — discovery finds nothing):
swift build && swift run

# Full app with Bonjour + LAN scanning + the bundled icon (recommended):
./scripts/bundle_app.sh release
open dist/sshMagic.app
```

> **Why the bundle?** macOS gates Bonjour browsing and outbound LAN connections
> behind the *Local Network* privacy permission, only granted to a signed `.app`
> carrying `NSLocalNetworkUsageDescription` + `NSBonjourServices`. A bare
> `swift run` executable can't request it. `scripts/bundle_app.sh` builds, lays
> out the bundle, writes the Info.plist, generates the app icon, and ad‑hoc
> signs it. First launch prompts for Local Network access.

```sh
swift test          # run the test suite
```

## Distribution

sshMagic is a **macOS** application (there is no Android/Play Store build). There
are two ways to ship a paid macOS app, and they differ in an architecturally
important way:

| | Developer ID (direct sale / own store) | Mac App Store |
|---|---|---|
| **Sandbox** | Not required | **Required** |
| **Current code works as‑is** | ✅ Yes | ❌ No — see below |
| **Signing** | Developer ID + notarization | App Store provisioning |

**The catch for the Mac App Store:** today sshMagic shells out to `/usr/bin/ssh`
and reads `~/.ssh` (config, keys, `known_hosts`). The App Sandbox blocks a child
`ssh` process from reading `~/.ssh`, so a sandboxed build would need an
**in‑process SSH/SFTP stack** (e.g. `swift-nio-ssh`) plus its own key management —
a meaningful rewrite. The non‑sandboxed `Developer ID + notarization` path
(direct download or a non‑MAS storefront) ships the current architecture
unchanged and is the recommended route for v1. See `scripts/sshMagic.entitlements`.

## Architecture

```
Sources/sshMagic/
  App.swift              @main entry, activation policy, Dock icon
  AppState.swift         top-level model: discovery, hosts, tabs, credentials
  Models/                Host, RemoteFile
  Discovery/             Bonjour + subnet scanner, reverse DNS, manager
  Terminal/              session, SwiftTerm SSH view, askpass password helper
  Files/                 SFTPClient (multiplexed) + file panel model
  Security/              KeychainStore
  Ghostty/               external-launch hand-off
  Views/                 SwiftUI chrome — sidebar, tabs, file panel, theme
scripts/
  bundle_app.sh          assemble + sign the .app
  make_icon.swift        generate the app icon (CoreGraphics → .icns)
```

## Tooling & CI

`.github/workflows/ci.yml` runs build + tests + an app‑bundle smoke test on
macOS, plus SwiftLint, swift‑format, a Trojan‑Source Unicode scan, ShellCheck,
and a zizmor workflow audit. `claude-review.yml` posts an automated PR review.

## License

**Proprietary.** Copyright © 2026 BlackMirror Studio LLC. All rights reserved.
See [LICENSE.md](LICENSE.md). Third‑party components are listed in
[THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md).
