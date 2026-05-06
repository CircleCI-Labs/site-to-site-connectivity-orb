#!/bin/bash

set -eu -o pipefail

if [ -z "${CIRCLE_OIDC_TOKEN:-}" ]; then
  echo "Error: CIRCLE_OIDC_TOKEN is not set."
  exit 1
fi

ip="$(curl -s --fail --max-time 10 https://checkip.amazonaws.com/ | tr -d '[:space:]')"
echo "Registering IP: $ip"

max_attempts="${PARAM_REG_RETRY_ATTEMPTS:-5}"
retry_delay="${PARAM_REG_RETRY_DELAY:-30}"
attempt=0
http_code=0
until [ "$http_code" -eq 200 ] || [ "$attempt" -ge "$max_attempts" ]; do
  attempt=$((attempt + 1))
  [ "$attempt" -gt 1 ] && echo "IP registration attempt ${attempt}/${max_attempts} (timeout: 30s)..."
  reg_body=$(mktemp)
  http_code=$(curl -s -o "${reg_body}" -w "%{http_code}" \
    --max-time 30 --connect-timeout 10 \
    -H 'Accept: application/json' \
    -H "Authorization: Bearer ${CIRCLE_OIDC_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"ip\":\"${ip}\"}" \
    "https://internal.circleci.com/api/private/site-to-site/ip-policy/register")
  [ "$http_code" -ne 200 ] && echo "  HTTP ${http_code}"
  if [[ "${DEBUG:-}" == "true" ]]; then
    echo "  Response body: $(cat "${reg_body}")"
  fi
  rm -f "${reg_body}"

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
  [ "$td_attempt" -gt 1 ] && echo "Tunnel-details attempt ${td_attempt}/${max_attempts} (timeout: 30s)..."
  td_http_code=$(curl -s -o "${td_response}" -w "%{http_code}" \
    --max-time 30 --connect-timeout 10 \
    -H "Authorization: Bearer ${CIRCLE_OIDC_TOKEN}" \
    -H "Accept: application/json" \
    "https://internal.circleci.com/api/private/site-to-site/tunnel-details")
  [ "$td_http_code" -ne 200 ] && echo "  HTTP ${td_http_code}"
  if [[ "${DEBUG:-}" == "true" ]]; then
    echo "  Response body: $(cat "${td_response}")"
  fi

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

echo "$tunnel_details" > "${TMPDIR:-/tmp}/tunnel_details.json"
echo "export EXECUTOR_IP=\"${ip}\"" >>"$BASH_ENV"
