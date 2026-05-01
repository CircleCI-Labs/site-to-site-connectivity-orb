#!/bin/bash

set -eu -o pipefail

tunnel_details="$(cat "${TMPDIR:-/tmp}/tunnel_details.json")"

# Detect OS for platform-specific command workarounds
os="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$os" in
  msys_nt* | msys* | mingw* | cygwin*) os="windows" ;;
esac

ext=""
[ "$os" = "windows" ] && ext=".exe"
proxy_bin="${TMPDIR:-/tmp}/tunnel-proxy${ext}"

echo "Verifying tunnel connectivity"
while IFS=$'\t' read -r service_type internal_host tunnel_domain; do
  echo "  Verifying: ${internal_host} -> ${tunnel_domain}:443 (${service_type})"
  verified=0
  for i in $(seq 1 "${PARAM_VERIFY_ATTEMPTS:-5}"); do
    echo "  Attempt $i"
    set +e +o pipefail
    if [[ "$service_type" == "ssh" ]]; then
      # Read first 4 bytes — SSH server sends banner immediately on connect.
      # sleep holds stdin open so connect doesn't close the remote before the banner arrives.
      # timeout is not available in Git Bash on Windows (Windows timeout.exe has different syntax)
      if [ "$os" = "windows" ]; then
        response=$(sleep 1 | "${proxy_bin}" connect \
          --tunnel "${internal_host}:22=tls://${tunnel_domain}:443" \
          "${internal_host}:22" 2>/dev/null | head -c 4 || true)
      else
        response=$(sleep 1 | timeout 5 "${proxy_bin}" connect \
          --tunnel "${internal_host}:22=tls://${tunnel_domain}:443" \
          "${internal_host}:22" 2>/dev/null | head -c 4 || true)
      fi
      [[ "$response" == "SSH-" ]] && verified=1
    else
      # Any HTTP response (even an error) confirms the tunnel is routing traffic
      http_code=$(curl -k -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 5 --max-time 5 \
        --proxy http://127.0.0.1:4140 \
        "https://${internal_host}/" 2>/dev/null || true)
      [[ "${http_code:-0}" -gt 0 ]] && verified=1
    fi
    set -e -o pipefail
    if [[ $verified -eq 1 ]]; then
      echo "  Connection verified"
      break
    fi
    sleep 3
    echo "  Connection not verified, retrying..."
  done
  if [[ $verified -eq 0 ]]; then
    echo "Error: Could not verify connection to ${internal_host} via ${tunnel_domain}:443"
    exit 1
  fi
done < <(echo "$tunnel_details" | jq -r '.tunnels[] | [.service_type, .internal_host, .tunnel_domain] | @tsv')

echo "CircleCI tunnel setup complete"
