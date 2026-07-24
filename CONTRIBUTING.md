# Contributing

Thank you for contributing to Accio Computer Use.

## Development requirements

- macOS 14 or later
- Swift 6
- Python 3.10 or later
- Accessibility and Screen Recording permission for manual integration tests

## Build and test

```bash
swift build
swift test
swift build -c release --product AccioComputerUse
python3 -m unittest discover -s coding/tests -p 'test_*.py'
bash -n scripts/install-macos.sh
bash -n scripts/install-daemon.sh
```

Tests that create Unix sockets must run in an environment that permits local
socket creation.

## Pull requests

1. Create a focused branch from `main`.
2. Add or update tests before changing behavior.
3. Run the full Swift and Python suites.
4. Confirm that no credentials, screenshots, logs, traces, or private paths
   are included.
5. Explain user-visible behavior and security implications in the PR.

By submitting a contribution, you agree that it is licensed under the Apache
License 2.0 and that you have the right to submit it.

## Platform-sensitive changes

Changes involving TCC permissions, signing identities, LaunchAgents, input
injection, ScreenCaptureKit, or SkyLight must include:

- a regression test where practical;
- the macOS versions tested;
- a description of fallback and failure behavior;
- confirmation that automation still fails closed when paused.

Do not include reverse-engineered Apple binaries, private SDK headers, or
third-party assets without documented redistribution rights.
