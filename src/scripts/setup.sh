#!/bin/bash

set -eu -o pipefail

if [ -z "${CIRCLE_OIDC_TOKEN:-}" ]; then
  echo "Error: CIRCLE_OIDC_TOKEN is not set."
  exit 1
fi

ip="$(curl --fail https://checkip.amazonaws.com/)"
echo "Registering IP: $ip"

max_attempts="${PARAM_REG_RETRY_ATTEMPTS:-5}"
retry_delay="${PARAM_REG_RETRY_DELAY:-30}"
attempt=0
http_code=0
until [ "$http_code" -eq 200 ] || [ "$attempt" -ge "$max_attempts" ]; do
  attempt=$((attempt + 1))
  if [[ "${DEBUG:-}" == "true" ]]; then
    echo "DEBUG: IP registration attempt ${attempt}/${max_attempts}"
  fi
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H 'Accept: application/json' \
    -H "Authorization: Bearer ${CIRCLE_OIDC_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"ip":"'"${ip}"'"}' \
    "https://internal.circleci.com/api/private/site-to-site/ip-policy/register")

  if [ "$http_code" -eq 200 ]; then
    break
  fi

  echo "Error: IP registration failed (HTTP ${http_code}) on attempt ${attempt}/${max_attempts}"
  if [ "$http_code" -eq 404 ]; then
    echo "This typically indicates an OIDC authentication issue."
    break
  fi
  if [ "$http_code" -eq 500 ] && [ "$attempt" -lt "$max_attempts" ]; then
    echo "Retrying in ${retry_delay} seconds..."
    sleep "${retry_delay}"
  fi
done

if [ "$http_code" -ne 200 ]; then
  echo "Error: IP registration failed after ${attempt} attempt(s) (HTTP ${http_code})"
  exit 1
fi

echo "Fetching tunnel details"
td_response=$(mktemp)
td_attempt=0
td_http_code=0
until [ "$td_http_code" -eq 200 ] || [ "$td_attempt" -ge "$max_attempts" ]; do
  td_attempt=$((td_attempt + 1))
  if [[ "${DEBUG:-}" == "true" ]]; then
    echo "DEBUG: tunnel-details attempt ${td_attempt}/${max_attempts}"
  fi
  td_http_code=$(curl -s -o "${td_response}" -w "%{http_code}" \
    -H "Authorization: Bearer ${CIRCLE_OIDC_TOKEN}" \
    -H "Accept: application/json" \
    "https://internal.circleci.com/api/private/site-to-site/tunnel-details")

  if [ "$td_http_code" -eq 200 ]; then
    break
  fi

  echo "Error: tunnel-details failed (HTTP ${td_http_code}) on attempt ${td_attempt}/${max_attempts}"
  if [ "$td_http_code" -eq 404 ]; then
    echo "This typically indicates an OIDC authentication issue."
    break
  fi
  if [ "$td_http_code" -eq 500 ] && [ "$td_attempt" -lt "$max_attempts" ]; then
    echo "Retrying in ${retry_delay} seconds..."
    sleep "${retry_delay}"
  fi
done

if [ "$td_http_code" -ne 200 ]; then
  echo "Error: tunnel-details failed after ${td_attempt} attempt(s) (HTTP ${td_http_code})"
  rm -f "${td_response}"
  exit 1
fi

tunnel_details="$(cat "${td_response}")"
rm -f "${td_response}"

tunnel_count=$(echo "$tunnel_details" | jq '.tunnels | length')
if [ "$tunnel_count" -eq 0 ]; then
  echo "Error: no tunnels returned from tunnel-details"
  exit 1
fi

# Detect OS and architecture for binary download
os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch_raw="$(uname -m)"
case "$arch_raw" in
x86_64) arch="amd64" ;;
aarch64 | arm64) arch="arm64" ;;
*)
  echo "Error: unsupported architecture: $arch_raw"
  exit 1
  ;;
esac

proxy_bin="${TMPDIR:-/tmp/}tunnel-proxy"
proxy_version="${PARAM_TUNNEL_PROXY_VERSION:-latest}"

if [ "$proxy_version" = "latest" ]; then
  download_url="https://github.com/CircleCI-Labs/site-to-site-tunnel-proxy/releases/latest/download/tunnel-proxy_${os}_${arch}"
else
  download_url="https://github.com/CircleCI-Labs/site-to-site-tunnel-proxy/releases/download/${proxy_version}/tunnel-proxy_${os}_${arch}"
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
  nohup "${proxy_bin}" serve "${serve_args[@]}" >/tmp/tunnel-proxy.log 2>&1 &
  disown
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
while IFS=$'\t' read -r host ssh_domain; do
  echo "  SSH tunnel: ${host}:22 -> ${ssh_domain}:443"
  cat >>~/.ssh/config <<EOF

Host ${host}
  ProxyCommand ${proxy_bin} connect --tunnel ${host}:22=tls://${ssh_domain}:443 %h:%p
  StrictHostKeyChecking accept-new
EOF
done < <(echo "$tunnel_details" | jq -r '.tunnels[] | select(.service_type == "ssh") | [.internal_host, .tunnel_domain] | @tsv')

echo "export EXECUTOR_IP=\"${ip}\"" >>"$BASH_ENV"

# shellcheck source=/dev/null
source "$BASH_ENV"

if [[ -n "${PARAM_VERIFY_TUNNEL:-}" ]]; then
  echo "Verifying tunnel connectivity"
  while IFS=$'\t' read -r service_type internal_host tunnel_domain; do
    echo "  Verifying: ${internal_host} -> ${tunnel_domain}:443 (${service_type})"
    verified=0
    for i in $(seq 1 "${PARAM_VERIFY_TUNNEL_ATTEMPTS:-5}"); do
      echo "  Attempt $i"
      set +e +o pipefail
      if [[ "$service_type" == "ssh" ]]; then
        # Read first 4 bytes — SSH server sends banner immediately on connect.
        # sleep holds stdin open so connect doesn't close the remote before the banner arrives.
        response=$(sleep 1 | timeout 5 "${proxy_bin}" connect \
          --tunnel "${internal_host}:22=tls://${tunnel_domain}:443" \
          "${internal_host}:22" 2>/dev/null | head -c 4 || true)
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
fi

echo "CircleCI tunnel setup complete"
