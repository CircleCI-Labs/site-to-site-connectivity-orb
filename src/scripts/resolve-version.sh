#!/bin/bash

set -eu -o pipefail

# Detect OS and architecture to generate a platform-specific cache key.
# Including OS and arch ensures Linux and Windows get separate cache entries.
os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch_raw="$(uname -m)"
case "$os" in
  # Git Bash on CircleCI Windows reports MSYS_NT-10.0-XXXXX (lowercased: msys_nt-*)
  msys_nt* | msys* | mingw* | cygwin*) os="windows" ;;
esac
case "$arch_raw" in
  x86_64) arch="amd64" ;;
  aarch64 | arm64) arch="arm64" ;;
  *)
    echo "Error: unsupported architecture: $arch_raw"
    exit 1
    ;;
esac

version="${PARAM_TUNNEL_PROXY_VERSION:-latest}"

if [ "$version" = "latest" ]; then
  echo "Resolving latest tunnel-proxy version from GitHub..."
  version=$(curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/CircleCI-Labs/site-to-site-tunnel-proxy/releases/latest" \
    | jq -r '.tag_name')
  echo "Resolved to: ${version}"
else
  echo "Using pinned tunnel-proxy version: ${version}"
fi

# Write platform-specific version string to a fixed path so CircleCI's
# {{ checksum }} template can reference it for restore_cache / save_cache keys.
echo "${version}-${os}-${arch}" > /tmp/.tunnel-proxy-version
echo "Cache key content: $(cat /tmp/.tunnel-proxy-version)"
