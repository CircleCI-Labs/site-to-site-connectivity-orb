# Site to Site Connectivity Orb

[![CircleCI Build Status](https://circleci.com/gh/CircleCI-Labs/site-to-site-connectivity-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/CircleCI-Labs/site-to-site-connectivity-orb) [![CircleCI Orb Version](https://badges.circleci.com/orbs/cci-labs/site-to-site-connectivity.svg)](https://circleci.com/developer/orbs/orb/cci-labs/site-to-site-connectivity) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/CircleCI-Labs/site-to-site-connectivity-orb/master/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

A CircleCI orb for establishing site to site connectivity via CircleCI tunnels to enable secure access to private repositories and resources during builds.

### Disclaimer

CircleCI Labs, including this repo, is a collection of solutions developed by members of CircleCI's Field Engineering teams through our engagement with various customer needs.

    ✅ Created by engineers @ CircleCI
    ✅ Used by real CircleCI customers
    ❌ not officially supported by CircleCI support

## Overview

This orb:

1. Sets up CircleCI tunnels with IP rules for secure access
2. Configures HTTPS and SSH routing transparently for subsequent steps
3. Deregisters the executor IP on cleanup

## Commands

### `setup`

Registers the executor IP, discovers tunnel endpoints, downloads `tunnel-proxy`, and configures both HTTPS and SSH routing.

**Parameters:**

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `tunnel-proxy-version` | string | `latest` | Version of `tunnel-proxy` to download (e.g. `v1.2.3`) |
| `registration-retry-attempts` | integer | `5` | Max retry attempts for IP registration and tunnel-details on 500 errors |
| `registration-retry-delay` | integer | `30` | Seconds between retry attempts |
| `no-proxy` | string | `""` | Additional comma-separated hosts to exclude from the HTTPS proxy |
| `debug` | boolean | `false` | Enable debug logging |

**Exports to subsequent steps:**

| Variable | Value |
|----------|-------|
| `EXECUTOR_IP` | The executor's public IP (used by `cleanup`) |
| `HTTPS_PROXY` | `http://127.0.0.1:4140` — set when at least one `vcs` tunnel exists |
| `NO_PROXY` | `localhost,127.0.0.1,circleci.com,*.circleci.com` — set alongside `HTTPS_PROXY` |

**SSH config:** An `~/.ssh/config` `Host` entry with a `ProxyCommand` is written for each `vcs-ssh` tunnel, so the built-in `checkout` step works without additional configuration.

### `cleanup`

Deregisters the executor IP from the site-to-site allowlist. Run with `when: always` to ensure it executes even if earlier steps fail.

**Parameters:**

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `debug` | boolean | `false` | Enable debug logging |

## Example Usage

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
          context:
            - site-to-site-tunnel
```

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
