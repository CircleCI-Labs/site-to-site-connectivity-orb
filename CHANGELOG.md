# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial orb structure with three commands: setup, checkout, and cleanup
- Support for CircleCI tunnel-based site to site connectivity
- IP policy rule management for secure access
- Automatic environment variable exports for downstream steps
- CI jobs that validate the macOS coreutils install path on Xcode 26.3 and
  26.4 `m4pro.medium` executors, gating `orb-tools/publish` so a broken
  coreutils install blocks a production release.

### Fixed
- Removed the invalid `-y` flag from `brew install coreutils` in
  `src/scripts/setup.sh`. `brew` does not accept `-y`, which caused macOS
  executors to fail the coreutils install step with
  `Error: invalid option: -y`.
- Hardened the macOS coreutils install path: verify Homebrew is present
  on `PATH` before installing, skip reinstall when coreutils is already
  installed, set `NONINTERACTIVE=1` / `HOMEBREW_NO_AUTO_UPDATE=1` /
  `HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1` / `HOMEBREW_NO_ENV_HINTS=1`
  for the install, verify the install succeeded, and confirm that
  `timeout` or `gtimeout` is available on `PATH` before the rest of
  `setup.sh` runs.
