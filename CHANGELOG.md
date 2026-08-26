# Changelog

All notable changes to Exhaust are recorded here, starting from 1.0.0. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Exhaust follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Replay seeds are covered by semantic versioning: a seed recorded under one release reproduces the same run under every later release with the same major version. A change that breaks an existing seed is a major release and is listed under **Replay** in its entry.

## [Unreleased]

## [1.0.0] - 2026-08-26

### Added

- First stable release. The public API is covered by semantic versioning from this release on.
- `#explore(…, time:)` ships as experimental. It warns at every call site, and its settings and report shape sit outside the versioning contract.

### Replay

- Seeds recorded before 1.0.0 are not covered by the guarantee above.

[Unreleased]: https://github.com/nesevis/exhaust/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/nesevis/exhaust/releases/tag/v1.0.0
