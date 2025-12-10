# Private Connectivity Orb

A CircleCI orb for establishing private connectivity via circleci tunnels to enable secure access to private repositories and resources during builds.

## Overview

This orb provides commands to:
- Set up circleci tunnels with IP policy rules for secure access
- Checkout code from private repositories through the tunnel
- Clean up tunnel resources after the build

## Prerequisites

- An ngrok account with API access
- ngrok API token stored as an environment variable (`NGROK_API_TOKEN`)
- An IP policy ID configured in your ngrok account and stored as an environment variable (`CIRCLE_IP_POLICY_ID`)

## Commands

### setup

Sets up an circleci tunnel by creating an IP policy rule for the current CircleCI build's IP address.

**Parameters:**
- `ngrok-api-token` (env_var_name): Environment variable containing the ngrok API token (default: `NGROK_API_TOKEN`)
- `ip-policy-id` (env_var_name): Environment variable containing the IP policy ID for circleci tunnel (default: `CIRCLE_IP_POLICY_ID`)
- `tcp-address` (string): TCP address for circleci tunnel (default: `"1.tcp.ngrok.io"`)
- `tcp-port` (string): TCP port for circleci tunnel (default: `"28402"`)

**Exports:**
- `REPO_URL`: SSH URL to the repository via circleci tunnel
- `IPR_ID`: IP policy rule ID for cleanup

### checkout

Checks out code from a private repository via the circleci tunnel.

**Parameters:** None (uses environment variables set by `setup` command)

### cleanup

Removes the IP policy rule created during setup to clean up tunnel access.

**Parameters:**
- `ngrok-api-token` (env_var_name): Environment variable containing the ngrok API token (default: `NGROK_API_TOKEN`)

## Example Usage

```yaml
version: 2.1

orbs:
  private-connectivity: your-namespace/private-connectivity@0.0.1

jobs:
  build-with-private-repo:
    docker:
      - image: cimg/base:current
    steps:
      - private-connectivity/setup:
          ngrok-api-token: NGROK_API_TOKEN
          ip-policy-id: CIRCLE_IP_POLICY_ID
          tcp-address: "1.tcp.ngrok.io"
          tcp-port: "28402"
      - private-connectivity/checkout
      - run:
          name: Build application
          command: |
            # Your build commands here
            echo "Building application..."
      - private-connectivity/cleanup

workflows:
  private-repo-workflow:
    jobs:
      - build-with-private-repo:
          context:
            - ngrok-credentials
```

## Resources

### How to Contribute

We welcome [issues](https://github.com/vjpandian/private-connectivity-orb/issues) to and [pull requests](https://github.com/vjpandian/private-connectivity-orb/pulls) against this repository!

### How to Publish An Update

1. Merge pull requests with desired changes to the main branch.
2. Find the current version of the orb.
   - You can run `circleci orb info your-namespace/private-connectivity | grep "Latest"` to see the current version.
3. Create a [new Release](https://github.com/vjpandian/private-connectivity-orb/releases/new) on GitHub.
   - Click "Choose a tag" and create a new [semantically versioned](http://semver.org/) tag. (ex: v1.0.0)
4. Click "Publish Release".
   - This will push a new tag and trigger your publishing pipeline on CircleCI.
