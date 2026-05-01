# Site to Site Connectivity Orb

[![CircleCI Build Status](https://circleci.com/gh/CircleCI-Labs/site-to-site-connectivity-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/CircleCI-Labs/site-to-site-connectivity-orb) [![CircleCI Orb Version](https://badges.circleci.com/orbs/cci-labs/site-to-site-connectivity.svg)](https://circleci.com/developer/orbs/orb/cci-labs/site-to-site-connectivity) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/CircleCI-Labs/site-to-site-connectivity-orb/master/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

A CircleCI orb for establishing site-to-site connectivity via CircleCI tunnels, enabling secure access to private repositories and resources during builds.

### Disclaimer

CircleCI Labs, including this repo, is a collection of solutions developed by members of CircleCI's Field Engineering teams through our engagement with various customer needs.

    ✅ Created by engineers @ CircleCI
    ✅ Used by real CircleCI customers
    ❌ not officially supported by CircleCI support

## Overview

This orb:

1. Registers the executor's public IP with the CircleCI tunnel allowlist
2. Downloads and starts `tunnel-proxy`, caching the binary between jobs
3. Configures `HTTPS_PROXY` and SSH `ProxyCommand` so subsequent steps reach private infrastructure transparently — including the built-in `checkout` step
4. Deregisters the executor IP on cleanup

**Supported executors:**

| Executor | Image / Config | Architecture | Notes |
|---|---|---|---|
| Docker | `cimg/base:current` (or any image) | amd64, arm64 | Use `resource_class: arm.medium` for ARM |
| Linux machine | `ubuntu-2204:current` | amd64, arm64 | Use `resource_class: arm.medium` for ARM |
| macOS | `xcode: 16.x`, `macos.m1.medium.gen1` | arm64 (M1/M2) | |
| Windows (bash.exe) | `windows-server-2022-gui:current` | amd64 | `shell: bash.exe` optional at executor level |
| Windows (PowerShell) | `windows-server-2022-gui:current` | amd64 | Works — orb forces `shell: bash` per-step |
| Windows ARM | `windows-server-2022-gui:current` | arm64 | Available on CircleCI, currently undocumented |
| GPU (Linux) | `ubuntu-2204-cuda12:current` | amd64 | Treated as a standard Linux machine |

All orb `run` steps explicitly use `shell: bash`, so the orb works regardless of the executor's default shell. On Windows, bash resolves to Git Bash (pre-installed on all CircleCI Windows images). You do **not** need to set `shell: bash.exe` at the executor level, though doing so is harmless.

> **PowerShell steps work automatically.** On Windows, the orb appends `$env:HTTPS_PROXY`, `$env:NO_PROXY`, and `$env:PATH` to `$PROFILE.AllUsersCurrentHost`, which PowerShell sources before every step. `cleanup` removes those entries. No manual configuration required.

## Commands

### `setup`

Registers the executor IP, fetches tunnel configuration, downloads `tunnel-proxy`, starts the proxy daemon, and configures HTTPS and SSH routing.

**Parameters:**

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `tunnel-proxy-version` | string | `latest` | Version of `tunnel-proxy` to use (e.g. `v0.0.3`). `latest` resolves at job start via the GitHub API. Pin to a specific version for fully reproducible builds. |
| `cache-version` | string | `v1` | Cache key prefix. Increment (e.g. `v2`) to force a fresh download and discard any previously cached binary. |
| `cache` | boolean | `true` | Cache the `tunnel-proxy` binary between jobs. Set to `false` to always download a fresh copy. |
| `registration-retry-attempts` | integer | `5` | Max retry attempts for IP registration and tunnel lookup on 500 errors |
| `registration-retry-delay` | integer | `30` | Seconds between retry attempts |
| `no-proxy` | string | `""` | Additional comma-separated hosts to exclude from the HTTPS proxy |
| `verify-tunnel` | boolean | `true` | Verify each tunnel is reachable before the step completes |
| `verify-tunnel-attempts` | integer | `5` | Number of connection attempts per tunnel during verification |
| `debug` | boolean | `false` | Enable verbose debug logging |

**Exports to subsequent steps via `$BASH_ENV`:**

| Variable | Value |
|----------|-------|
| `EXECUTOR_IP` | The executor's public IP (required by `cleanup`) |
| `HTTPS_PROXY` | `http://127.0.0.1:4140` — set when at least one `https` tunnel exists |
| `NO_PROXY` | `localhost,127.0.0.1,circleci.com,*.circleci.com[,<no-proxy>]` — set alongside `HTTPS_PROXY` |
| `PATH` | Prepended with `/tmp/tunnel-proxy-bin` so `tunnel-proxy` is available in subsequent steps |

**SSH config:** An `~/.ssh/config` entry with a `ProxyCommand` is written for each `ssh` tunnel, so `git clone` and the built-in `checkout` step work without additional configuration.

### `cleanup`

Deregisters the executor IP from the site-to-site allowlist and stops the `tunnel-proxy` daemon.

Always run with `when: always` so cleanup executes even when earlier steps fail.

**Parameters:**

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `debug` | boolean | `false` | Enable verbose debug logging |

## Example Usage

### Docker / Linux machine

```yaml
version: 2.1

orbs:
  site-to-site-connectivity: cci-labs/site-to-site-connectivity@1.0.0

jobs:
  build:
    docker:
      - image: cimg/base:current
    steps:
      - site-to-site-connectivity/setup
      - checkout
      - run:
          name: Build
          command: make build
      - site-to-site-connectivity/cleanup:
          when: always

workflows:
  main:
    jobs:
      - build:
          context: site-to-site-tunnel
```

### Windows machine executor

The orb works with the default PowerShell executor — no `shell: bash.exe` required at the executor level. You may still set it if all your own steps also need bash.

```yaml
version: 2.1

orbs:
  site-to-site-connectivity: cci-labs/site-to-site-connectivity@1.0.0

jobs:
  build:
    machine:
      image: windows-server-2022-gui:current
      resource_class: windows.medium
      # shell: bash.exe is optional — the orb works with the default PowerShell shell
    steps:
      - site-to-site-connectivity/setup
      - checkout
      - run:
          name: Build
          command: make build
      - site-to-site-connectivity/cleanup:
          when: always

workflows:
  main:
    jobs:
      - build:
          context: site-to-site-tunnel
```

### GPU (Linux) executor

No special configuration required — the GPU executor is treated as a standard Linux machine:

```yaml
jobs:
  build:
    machine:
      image: ubuntu-2204-cuda12:current
    resource_class: gpu.nvidia.small.gen2
    steps:
      - site-to-site-connectivity/setup
      - checkout
      - run: python train.py
      - site-to-site-connectivity/cleanup:
          when: always
```

### Pin a specific version and disable caching

```yaml
- site-to-site-connectivity/setup:
    tunnel-proxy-version: v0.0.3
    cache: false
```

### Bust the cache after a forced upgrade

```yaml
- site-to-site-connectivity/setup:
    cache-version: v2
```

## Caching

`setup` caches the `tunnel-proxy` binary in `/tmp/tunnel-proxy-bin` using a cache key derived from the resolved version and the executor's OS and architecture:

```
<cache-version>-tunnel-proxy-{{ checksum "/tmp/.tunnel-proxy-version" }}
```

Linux and Windows jobs get separate cache entries automatically because the checksum file includes the OS and architecture (e.g. `v0.0.3-linux-amd64` vs `v0.0.3-windows-amd64`).

On a cache hit, the download is skipped entirely. On a cache miss, the binary is downloaded and cached for subsequent jobs.

## Resources

### How to Contribute

We welcome [issues](https://github.com/CircleCI-Labs/site-to-site-connectivity-orb/issues) to and [pull requests](https://github.com/CircleCI-Labs/site-to-site-connectivity-orb/pulls) against this repository!

### How to Publish An Update

1. Merge pull requests with desired changes to the main branch.
2. Find the current version of the orb.
   - You can run `circleci orb info cci-labs/site-to-site-connectivity | grep "Latest"` to see the current version.
3. Create a [new Release](https://github.com/CircleCI-Labs/site-to-site-connectivity-orb/releases/new) on GitHub.
   - Click "Choose a tag" and create a new [semantically versioned](http://semver.org/) tag. (ex: v1.0.0)
4. Click "Publish Release".
   - This will push a new tag and trigger your publishing pipeline on CircleCI.
