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

# On Windows, CircleCI cache resolves /tmp/ to C:\tmp\ in YAML paths.
# Git Bash maps /tmp/ to a different location, so use /c/tmp/ (C:\tmp\)
# to keep the binary path consistent with restore_cache / save_cache.
# WIN_TMP can be overridden in tests where /c/ is not writable.
WIN_TMP="${WIN_TMP:-/c/tmp}"
if [ "$os" = "windows" ]; then
  mkdir -p "${WIN_TMP}/tunnel-proxy-bin"
  proxy_bin="${WIN_TMP}/tunnel-proxy-bin/tunnel-proxy${ext}"
else
  mkdir -p /tmp/tunnel-proxy-bin
  proxy_bin="/tmp/tunnel-proxy-bin/tunnel-proxy${ext}"
fi
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
echo "export PATH=\"$(dirname "${proxy_bin}"):\$PATH\"" >>"$BASH_ENV"

# Start HTTP CONNECT proxy daemon for HTTPS traffic — one --tunnel per vcs mapping
serve_args=()
no_proxy=""
while IFS=$'\t' read -r host domain; do
  serve_args+=("--tunnel" "${host}=tls://${domain}:443")
  echo "  HTTPS tunnel: ${host} -> tls://${domain}:443"
done < <(echo "$tunnel_details" | jq -r '.tunnels[] | select(.service_type == "https") | [.internal_host, .tunnel_domain] | @tsv' | tr -d '\r')

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
done < <(echo "$tunnel_details" | jq -r '.tunnels[] | select(.service_type == "ssh") | [.internal_host, .tunnel_domain] | @tsv' | tr -d '\r')

# On Windows, write env vars into the PowerShell profile so they are available
# in every subsequent PowerShell step without any user configuration.
# Use PowerShell itself (via a temp script) to write to $PROFILE.AllUsersCurrentHost
# — bash/cygpath path mapping is unreliable for locating the correct profile file.
if [ "$os" = "windows" ]; then
  _win_bin=$(cygpath -w "${WIN_TMP}/tunnel-proxy-bin" 2>/dev/null || printf '%s' 'C:\tmp\tunnel-proxy-bin')
  # Escape single quotes for PowerShell string literals (PS doubles them: '' → ')
  _win_bin_ps="${_win_bin//\'/\'\'}"
  _no_proxy_ps="${no_proxy//\'/\'\'}"

  _ps_script="${WIN_TMP}/site-to-site-orb-profile.ps1"
  {
    printf '$profileDir = Split-Path $PROFILE.AllUsersCurrentHost\n'
    printf 'if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }\n'
    printf 'if (-not (Test-Path $PROFILE.AllUsersCurrentHost)) { New-Item -ItemType File -Path $PROFILE.AllUsersCurrentHost -Force | Out-Null }\n'
    printf '"" | Add-Content $PROFILE.AllUsersCurrentHost\n'
    printf '"# BEGIN site-to-site-orb" | Add-Content $PROFILE.AllUsersCurrentHost\n'
    printf '"`$env:PATH = '"'"'%s;'"'"' + `$env:PATH" | Add-Content $PROFILE.AllUsersCurrentHost\n' "$_win_bin_ps"
    if [ -n "$no_proxy" ]; then
      printf '"`$env:HTTPS_PROXY = '"'"'http://127.0.0.1:4140'"'"'" | Add-Content $PROFILE.AllUsersCurrentHost\n'
      printf '"`$env:NO_PROXY = '"'"'%s'"'"'" | Add-Content $PROFILE.AllUsersCurrentHost\n' "$_no_proxy_ps"
    fi
    printf '"# END site-to-site-orb" | Add-Content $PROFILE.AllUsersCurrentHost\n'
    printf 'Write-Host ("PowerShell profile updated: " + $PROFILE.AllUsersCurrentHost)\n'
  } > "$_ps_script"
  powershell.exe -NoProfile -NonInteractive -File "$(cygpath -w "$_ps_script")" 2>/dev/null || true
  rm -f "$_ps_script"
fi
