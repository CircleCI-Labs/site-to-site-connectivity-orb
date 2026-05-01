#!/bin/bash

set -eu -o pipefail

tunnel_details="$(cat "${TMPDIR:-/tmp}/tunnel_details.json")"

# Detect OS and architecture for binary download
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

ext=""
[ "$os" = "windows" ] && ext=".exe"

proxy_bin="${TMPDIR:-/tmp}/tunnel-proxy${ext}"
proxy_version="${PARAM_TUNNEL_PROXY_VERSION:-latest}"

if [ "$proxy_version" = "latest" ]; then
  download_url="https://github.com/CircleCI-Labs/site-to-site-tunnel-proxy/releases/latest/download/tunnel-proxy_${os}_${arch}${ext}"
else
  download_url="https://github.com/CircleCI-Labs/site-to-site-tunnel-proxy/releases/download/${proxy_version}/tunnel-proxy_${os}_${arch}${ext}"
fi

echo "Downloading tunnel-proxy from ${download_url}"
curl -fsSL -o "${proxy_bin}" "${download_url}"
chmod +x "${proxy_bin}"

# Add tunnel-proxy to PATH for subsequent steps (including SSH ProxyCommand lookups)
echo "export PATH=\"$(dirname "${proxy_bin}"):\$PATH\"" >>"$BASH_ENV"

# Start HTTP CONNECT proxy daemon for HTTPS traffic — one --tunnel per vcs mapping
serve_args=()
while IFS=$'\t' read -r host domain; do
  serve_args+=("--tunnel" "${host}=tls://${domain}:443")
  echo "  HTTPS tunnel: ${host} -> tls://${domain}:443"
done < <(echo "$tunnel_details" | jq -r '.tunnels[] | select(.service_type == "https") | [.internal_host, .tunnel_domain] | @tsv')

if [ "${#serve_args[@]}" -gt 0 ]; then
  echo "Starting tunnel-proxy serve"
  if [ "$os" = "windows" ]; then
    # Windows MSYS nohup exists but behaves differently; & disown is sufficient
    # since Windows does not deliver SIGHUP when the parent shell exits
    "${proxy_bin}" serve "${serve_args[@]}" >"/tmp/tunnel-proxy.log" 2>&1 &
  else
    nohup "${proxy_bin}" serve "${serve_args[@]}" >/tmp/tunnel-proxy.log 2>&1 &
  fi
  proxy_pid=$!
  # disown is deferred until after the readiness check so bash can reap the
  # child if it crashes, making kill -0 a reliable liveness signal
  proxy_ready=0
  for _ in $(seq 1 10); do
    sleep 0.5
    if ! kill -0 "$proxy_pid" 2>/dev/null; then
      echo "Error: tunnel-proxy exited unexpectedly"
      cat /tmp/tunnel-proxy.log >&2
      exit 1
    fi
    if (echo >/dev/tcp/127.0.0.1/4140) 2>/dev/null; then
      proxy_ready=1
      break
    fi
  done
  if [ "$proxy_ready" -eq 0 ]; then
    echo "Error: tunnel-proxy did not bind to port 4140 within 5 seconds"
    kill "$proxy_pid" 2>/dev/null || true
    cat /tmp/tunnel-proxy.log >&2
    exit 1
  fi
  disown "$proxy_pid"

  echo "export HTTPS_PROXY=\"http://127.0.0.1:4140\"" >>"$BASH_ENV"
  # Exclude system/CircleCI domains from the proxy; the proxy 403s unknown hosts.
  no_proxy="localhost,127.0.0.1,circleci.com,*.circleci.com"
  if [ -n "${PARAM_NO_PROXY:-}" ]; then
    no_proxy="${no_proxy},${PARAM_NO_PROXY}"
  fi
  echo "export NO_PROXY=\"${no_proxy}\"" >>"$BASH_ENV"
fi

# Write SSH config ProxyCommand entries for each vcs-ssh mapping
[ ! -d ~/.ssh ] && mkdir -p ~/.ssh
# OpenSSH on Windows requires a native Windows path in ProxyCommand
if [ "$os" = "windows" ]; then
  ssh_proxy_bin="$(cygpath -w "${proxy_bin}")"
else
  ssh_proxy_bin="${proxy_bin}"
fi
while IFS=$'\t' read -r host ssh_domain; do
  echo "  SSH tunnel: ${host}:22 -> ${ssh_domain}:443"
  cat >>~/.ssh/config <<EOF

Host ${host}
  ProxyCommand ${ssh_proxy_bin} connect --tunnel ${host}:22=tls://${ssh_domain}:443 %h:%p
  StrictHostKeyChecking accept-new
EOF
done < <(echo "$tunnel_details" | jq -r '.tunnels[] | select(.service_type == "ssh") | [.internal_host, .tunnel_domain] | @tsv')
