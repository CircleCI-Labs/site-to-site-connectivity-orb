# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- New `checkout` command for cloning repositories hosted on internal SSH
  endpoints reached through the tunnel (e.g. self-hosted GitLab, Bitbucket
  Server, Gitea). Relies on the SSH `ProxyCommand` entries that `setup`
  writes for each `internal_host` returned by tunnel-details, so no
  per-host SSH configuration is required in user pipelines.
- On macOS executors, `checkout` optionally installs Homebrew `coreutils`
  so `gtimeout` is available for bounded per-attempt clone timeouts. The
  install is hardened against the v0.1.2 regression: brew presence is
  checked first, install runs non-interactively (`NONINTERACTIVE=1`,
  `HOMEBREW_NO_AUTO_UPDATE=1`), and `timeout`/`gtimeout` availability is
  verified afterwards. Skipped automatically when `timeout` is already
  on PATH or the executor is not macOS.
- `site_to_site_workflow.yml` example: third job demonstrating
  `checkout` against an internal GitLab host.

### Notes
- Reintroduces a `checkout` command that was present in v0.1.x but removed
  in the multi-tunnel refactor (PR #16). The new implementation is built
  on top of the `tunnel-proxy` architecture rather than the old
  `nc`/`ssh-keyscan` flow.

## [Initial]

### Added
- Initial orb structure with three commands: setup, checkout, and cleanup
- Support for CircleCI tunnel-based site to site connectivity
- IP policy rule management for secure access
- Automatic environment variable exports for downstream steps
