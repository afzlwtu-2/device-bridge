# Contributing to DeviceBridge

Thank you for contributing to DeviceBridge! Pull requests, bug reports, security findings, and documentation improvements are welcome.

## Development Setup

- **Go:** `1.26+` (`1.27.4` for `spikes/tsnet`) with CGO enabled (`gcc` / `clang`).
- **Flutter:** `3.50.0` (Dart `3.14.0`).
- **Linux Desktop Builds:** `clang`, `cmake`, `ninja-build`, `pkg-config`, `libgtk-3-dev`, `liblzma-dev`, `xxhash`.
- **Android Builds:** JDK 21, Android SDK (`compileSdk 36`, `buildTools 36.0.0`), and NDK `28.2.13676358`.

## Pull Request Workflow

1. Fork this repository on GitHub and create a topic branch off `main`:
   ```bash
   git checkout -b fix/short-description
   ```
2. Make focused, well-tested changes. Follow existing architecture patterns:
   - Keep protocol changes backward-compatible and versioned.
   - Keep filesystem operations scoped through `os.Root` and verified with XXH64 (`xxhsum -H1`).
   - Do not bypass privilege boundaries (`Standard` / `Shizuku` / `Root` tiers on Android must remain explicit and opt-in).
3. Run formatting, linting, and tests before pushing:
   ```bash
   gofmt -w cmd internal protocol test spikes/tsnet spikes/wireguard
   bash scripts/check.sh
   (cd spikes/tsnet && go vet ./... && go test -race ./...)
   (cd spikes/wireguard && go vet ./... && go test -race ./...)
   cd app && flutter analyze && flutter test
   ```
4. Ensure no generated build artifacts, keys, `.agent-session-lock`, or local notes are staged (`git status`).
5. Push your branch and open a Pull Request against `main` describing:
   - The problem solved or feature added
   - Checks/tests run (unit, race, widget, or device tests)
   - Screenshots if your PR changes UI
