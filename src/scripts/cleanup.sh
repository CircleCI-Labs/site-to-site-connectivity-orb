#!/bin/bash

set -eu -o pipefail

# Check if environment variables are set
missing=0

if [ -z "${CIRCLE_OIDC_TOKEN:-}" ]; then
  echo "Error: CIRCLE_OIDC_TOKEN is not set."
  missing=1
fi
if [ -z "${EXECUTOR_IP:-}" ]; then
  echo "Error: EXECUTOR_IP is not set or empty"
  missing=1
fi
if [ "$missing" -ne 0 ]; then
  exit 1
fi

echo "Cleaning up CircleCI tunnel for IP: ${EXECUTOR_IP}"

# Stop the tunnel-proxy daemon before deregistering so it releases the port
# and closes connections cleanly
pkill -f "tunnel-proxy serve" 2>/dev/null || true

max_attempts=3
retry_delay=10
attempt=0
http_code=0
until [ "$http_code" -eq 200 ] || [ "$attempt" -ge "$max_attempts" ]; do
  attempt=$((attempt + 1))
  if [[ "${DEBUG:-}" == "true" ]]; then
    echo "DEBUG: IP removal attempt ${attempt}/${max_attempts}"
  fi
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H 'Accept: application/json' \
    -H "Authorization: Bearer ${CIRCLE_OIDC_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg ip "${EXECUTOR_IP}" '{"ip":$ip}')" \
    "https://internal.circleci.com/api/private/site-to-site/ip-policy/remove")

  if [ "$http_code" -eq 200 ]; then
    break
  fi

  echo "Error: IP removal failed (HTTP ${http_code}) on attempt ${attempt}/${max_attempts}"
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
  echo "Error: IP removal failed after ${attempt} attempt(s) (HTTP ${http_code})"
  exit 1
fi

echo "CircleCI tunnel cleanup complete"
