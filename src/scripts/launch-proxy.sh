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

mkdir -p /tmp/tunnel-proxy-bin
proxy_bin="/tmp/tunnel-proxy-bin/tunnel-proxy${ext}"
proxy_version="${PARAM_TUNNEL_PROXY_VERSION:-latest}"

if [ ! -f "${proxy_bin}" ]; then
  if [ "$proxy_version" = "latest" ]; then
    download_url="https://github.com/CircleCI-Labs/site-to-site-tunnel-proxy/releases/latest/download/tunnel-proxy_${os}_${arch}${ext}"
  else
    download_url="https://github.com/CircleCI-Labs/site-to-site-tunnel-proxy/releases/download/${proxy_version}/tunnel-proxy_${os}_${arch}${ext}"
  fi
  echo "Downloading tunnel-proxy from ${download_url}"
  curl -fsSL -o "${proxy_bin}" "${download_url}"
  chmod +x "${proxy_bin}"
else
  echo "Using cached tunnel-proxy at ${proxy_bin}"
fi

if [ -n "${PARAM_TUNNEL_PROXY_SHA256:-}" ]; then
  echo "Verifying tunnel-proxy SHA256..."
  # Use sha256sum (GNU/Linux/Windows) or shasum (macOS) — avoid --check because
  # BSD sha256sum (macOS) does not support that flag.
  _actual_sha=""
  if command -v sha256sum &>/dev/null; then
    _actual_sha=$(sha256sum "${proxy_bin}" | awk '{print $1}')
  elif command -v shasum &>/dev/null; then
    _actual_sha=$(shasum -a 256 "${proxy_bin}" | awk '{print $1}')
  else
    echo "Warning: no SHA256 tool available; skipping verification" >&2
  fi
  if [ -n "$_actual_sha" ] && [ "$_actual_sha" != "${PARAM_TUNNEL_PROXY_SHA256}" ]; then
    echo "Error: SHA256 mismatch for ${proxy_bin}"
    echo "  Expected: ${PARAM_TUNNEL_PROXY_SHA256}"
    echo "  Got:      ${_actual_sha}"
    exit 1
  fi
  echo "SHA256 verified"
fi

# Add tunnel-proxy to PATH for subsequent steps (including SSH ProxyCommand lookups)
echo "export PATH=\"/tmp/tunnel-proxy-bin:\$PATH\"" >>"$BASH_ENV"

# Start HTTP CONNECT proxy daemon for HTTPS traffic — one --tunnel per vcs mapping
serve_args=()
no_proxy=""
while IFS=$'\t' read -r host domain; do
  serve_args+=("--tunnel" "${host}=tls://${domain}:443")
  echo "  HTTPS tunnel: ${host} -> tls://${domain}:443"
done < <(echo "$tunnel_details" | jq -r '.tunnels[] | select(.service_type == "https") | [.internal_host, .tunnel_domain] | @tsv')

if [ "${#serve_args[@]}" -gt 0 ]; then
  echo "Starting tunnel-proxy serve"
  if [ "$os" = "windows" ]; then
    # Windows MSYS nohup exists but behaves differently; & disown is sufficient
    # since Windows does not deliver SIGHUP when the parent shell exits
    "${proxy_bin}" serve "${serve_args[@]}" >"${TMPDIR:-/tmp}/tunnel-proxy.log" 2>&1 &
  else
    nohup "${proxy_bin}" serve "${serve_args[@]}" >"${TMPDIR:-/tmp}/tunnel-proxy.log" 2>&1 &
  fi
  proxy_pid=$!
  # disown is deferred until after the readiness check so bash can reap the
  # child if it crashes, making kill -0 a reliable liveness signal
  proxy_ready=0
  for _ in $(seq 1 10); do
    sleep 0.5
    if ! kill -0 "$proxy_pid" 2>/dev/null; then
      echo "Error: tunnel-proxy exited unexpectedly"
      cat "${TMPDIR:-/tmp}/tunnel-proxy.log" >&2
      exit 1
    fi
    if nc -z 127.0.0.1 4140 2>/dev/null || (echo >/dev/tcp/127.0.0.1/4140) 2>/dev/null; then
      proxy_ready=1
      break
    fi
  done
  if [ "$proxy_ready" -eq 0 ]; then
    echo "Error: tunnel-proxy did not bind to port 4140 within 5 seconds"
    kill "$proxy_pid" 2>/dev/null || true
    cat "${TMPDIR:-/tmp}/tunnel-proxy.log" >&2
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

# On Windows, also write env vars into the PowerShell profile so they are
# available in every subsequent PowerShell step without any user configuration.
# $PROFILE.AllUsersCurrentHost is sourced by powershell.exe at startup;
# CircleCI does not pass -NoProfile to job steps.
if [ "$os" = "windows" ]; then
  # shellcheck disable=SC2016
  _ps_profile_win=$(powershell.exe -NoProfile -NonInteractive \
    -Command '$PROFILE.AllUsersCurrentHost' 2>/dev/null | tr -d '\r\n' || true)
  if [ -n "$_ps_profile_win" ]; then
    _ps_profile=$(cygpath "$_ps_profile_win" 2>/dev/null || echo "$_ps_profile_win")
    mkdir -p "$(dirname "$_ps_profile")" 2>/dev/null || true
    _win_bin=$(cygpath -w /tmp/tunnel-proxy-bin 2>/dev/null || printf '%s' 'C:\tmp\tunnel-proxy-bin')
    # Escape single quotes for PowerShell string literals (PS doubles them: '' → ')
    _win_bin_ps="${_win_bin//\'/\'\'}"
    _no_proxy_ps="${no_proxy//\'/\'\'}"
    {
      printf '\n# BEGIN site-to-site-orb\n'
      printf "\$env:PATH = '%s;' + \$env:PATH\n" "$_win_bin_ps"
      if [ -n "$no_proxy" ]; then
        printf "\$env:HTTPS_PROXY = 'http://127.0.0.1:4140'\n"
        printf "\$env:NO_PROXY = '%s'\n" "$_no_proxy_ps"
      fi
      printf '# END site-to-site-orb\n'
    } >> "$_ps_profile"
    echo "PowerShell profile updated: $_ps_profile"
  fi
fi
