# Site to Site Connectivity Orb

[![CircleCI Build Status](https://circleci.com/gh/CircleCI-Labs/site-to-site-connectivity-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/CircleCI-Labs/site-to-site-connectivity-orb) [![CircleCI Orb Version](https://badges.circleci.com/orbs/cci-labs/site-to-site-connectivity-orb.svg)](https://circleci.com/developer/orbs/orb/cci-labs/site-to-site-connectivity-orb) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/CircleCI-Labs/site-to-site-connectivity-orb/master/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

A CircleCI orb for establishing site to site connectivity via CircleCI tunnels to enable secure access to private repositories and resources during builds.

### Disclaimer:

CircleCI Labs, including this repo, is a collection of solutions developed by members of CircleCI's Field Engineering teams through our engagement with various customer needs.

    ✅ Created by engineers @ CircleCI
    ✅ Used by real CircleCI customers
    ❌ not officially supported by CircleCI support

## Overview

This orb provides commands to:
- Set up CircleCI tunnels with IP policy rules for secure access
- Checkout code from private repositories through the tunnel
- Clean up tunnel resources after the build

## Prerequisites

- An Ngrok account with API access, which is provided by CircleCI
- Ngrok API token stored as an environment variable (`NGROK_API_TOKEN`), which is provided by CircleCI
- An IP policy ID configured in your Ngrok account and stored as an environment variable (`IP_POLICY_ID`), which is provided by CircleCI
- Creation of a CircleCI context which holds the following environment variables:
  - NGROK_API_TOKEN
  - IP_POLICY_ID
  - TUNNEL_ADDRESS
  - TUNNEL_PORT

## Commands

### Setup

Sets up an CircleCI tunnel by creating an IP policy rule for the current CircleCI build's IP address.

**Parameters:**
- `ngrok-api-token` (env_var_name): Name of the env var containing the Ngrok API token (default: `NGROK_API_TOKEN`)
- `ip-policy-id` (env_var_name): Name of the env var containing the IP policy ID (default: `IP_POLICY_ID`)
- `tunnel-address` (env_var_name): Name of the env var containing the tunnel address (default: `TUNNEL_ADDRESS`)
- `tunnel-port` (env_var_name): Name of the env var containing the tunnel port (default: `TUNNEL_PORT`)
- `verify-tunnel` (boolean): Verifies tunnel or fails the step (default: `true`)
- `verify-tunnel-attempts` (integer): Number of attempts before abandoning the tunnel (default: `30`)
- `debug` (boolean): Enable debug logging (prints the curl command), default: `false`

**Exports:**
- `REPO_URL`: SSH URL to the repository via circleci tunnel
- `IPR_ID`: IP policy rule ID for cleanup

Note on env_var_name parameters:
- These parameters expect the NAME of an environment variable, not the value. The orb resolves the actual values at runtime via indirect expansion.

### checkout

Checks out code from a private repository via the circleci tunnel.

**Parameters:**
- `tunnel-address` (env_var_name): Name of the env var containing the tunnel address (default: `TUNNEL_ADDRESS`)
- `tunnel-port` (env_var_name): Name of the env var containing the tunnel port (default: `TUNNEL_PORT`)
- `git-url` (string): Repository URL (supports SSH scp-like `git@host:org/repo.git` and HTTPS/SSH URLs)
- `checkout-folder` (string): Folder to clone the repository into (default: `~/project`)
- `debug` (boolean): Enable debug logging (prints derived values), default: `false`

### cleanup

Removes the IP policy rule created during setup to clean up tunnel access.

**Parameters:**
- `ngrok-api-token` (env_var_name): Name of the env var containing the Ngrok API token (default: `NGROK_API_TOKEN`)
- `debug` (boolean): Enable debug logging, default: `false`

## Example Usage

```yaml
version: 2.1

orbs:
  site-to-site-connectivity: your-namespace/site-to-site-connectivity@0.0.1

parameters:
  ngrok-api-token:
    type: env_var_name
    description: "Environment variable name containing the Ngrok API token"
    default: NGROK_API_TOKEN
  tunnel-address:
    type: env_var_name
    description: >
      Environment variable name containing the tunnel address for the
      CircleCI tunnel
    default: "TUNNEL_ADDRESS"
  tunnel-port:
    type: env_var_name
    description: >
      Environment variable name containing the tunnel port for the
      CircleCI tunnel
    default: "TUNNEL_PORT"
  debug:
    type: boolean
    description: "Enable debug mode"
    default: false

jobs:
  build-with-private-repo:
    docker:
      - image: cimg/base:current
    steps:
      - site-to-site-connectivity/setup
      - site-to-site-connectivity/checkout:
          git-url: << pipeline.parameters.git-url >>
      - run:
          name: Build application
          command: |
            # Your build commands here
            echo "Building application..."
      - site-to-site-connectivity/cleanup

workflows:
  private-repo-workflow:
    jobs:
      - build-with-private-repo:
          context:
            - ngrok-credentials
```

## Resources

### How to Contribute

We welcome [issues](https://github.com/CircleCI-Labs/site-to-site-connectivity-orb/issues) to and [pull requests](https://github.com/CircleCI-Labs/site-to-site-connectivity-orb/pulls) against this repository!

### How to Publish An Update

1. Merge pull requests with desired changes to the main branch.
2. Find the current version of the orb.
   - You can run `circleci orb info your-namespace/site-to-site-connectivity | grep "Latest"` to see the current version.
3. Create a [new Release](https://github.com/CircleCI-Labs/site-to-site-connectivity-orb/releases/new) on GitHub.
   - Click "Choose a tag" and create a new [semantically versioned](http://semver.org/) tag. (ex: v1.0.0)
4. Click "Publish Release".
   - This will push a new tag and trigger your publishing pipeline on CircleCI.
