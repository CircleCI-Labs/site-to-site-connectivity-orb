#!/bin/bash

set -eu -o pipefail

# Check if environment variables are set
missing=0

# Resolve indirect values (PARAM_* contains the variable name to read)
resolved_tunnel_address="${!PARAM_TUNNEL_ADDRESS:-}"
resolved_tunnel_port="${!PARAM_TUNNEL_PORT:-}"

# Validate resolved values are non-empty
if [ -z "${CIRCLE_OIDC_TOKEN:-}" ]; then
  echo "Error: CIRCLE_OIDC_TOKEN is not set."
  missing=1
fi
if [ -z "${resolved_tunnel_address}" ]; then
  echo "Error: ${PARAM_TUNNEL_ADDRESS} is not set or empty"
  missing=1
fi
if [ -z "${resolved_tunnel_port}" ]; then
  echo "Error: ${PARAM_TUNNEL_PORT} is not set or empty"
  missing=1
fi
if [ "$missing" -ne 0 ]; then
  exit 1
fi

ip="$(curl --fail https://checkip.amazonaws.com/)"

echo "Setting up the CircleCI tunnel with IP: $ip"

if [[ "$(uname -s)" == "Darwin" ]]; then
  echo "macOS detected, installing coreutils..."
  brew install coreutils
else
  echo "Non-macOS system detected, skipping coreutils installation"
fi

if [[ -n "${DEBUG:-}" ]]; then
  echo "DEBUG curl command:"
  echo curl -H 'Accept: application/json' \
    -H "Authorization: Bearer \${CIRCLE_OIDC_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"ip":"'"${ip}"'"}' \
    "https://internal.circleci.com/api/private/site-to-site/ip-policy/register"
fi

max_attempts="${PARAM_REG_RETRY_ATTEMPTS:-3}"
retry_delay="${PARAM_REG_RETRY_DELAY:-5}"
attempt=0
http_code=0
until [ "$http_code" -eq 200 ] || [ "$attempt" -ge "$max_attempts" ]; do
  attempt=$((attempt + 1))
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

if [[ -n "${PARAM_VERIFY_TUNNEL:-}" ]]; then
  echo "Verifying the connection before exiting"
  verified=0
  for i in $(seq 1 ${PARAM_VERIFY_TUNNEL_ATTEMPTS:-}); do
    echo "Attempt $i"
    set +e +o pipefail
    timeout 1s nc -v "${resolved_tunnel_address}" "${resolved_tunnel_port}"
    # When timeout is reached the connection is not immediately closed and we can assume the connection is working
    if [[ $? -eq 124 ]]; then
      echo "Connection verified"
      verified=1
      break
    fi
    set -e -o pipefail
    sleep 3
    echo "Connection not verified, retrying..."
  done
  if [[ $verified -eq 0 ]]; then
    echo "Connection not verified after 30 attempts"
    exit 1
  fi
fi

echo "Exporting EXECUTOR_IP to environment"
echo "export EXECUTOR_IP=\"${ip}\"" >> "$BASH_ENV"
echo "Sourcing BASH_ENV to update the environment"
# shellcheck source=/dev/null
source "$BASH_ENV"

if [[ -n "${DEBUG:-}" ]]; then
  echo "DEBUG EXECUTOR_IP: ${EXECUTOR_IP}"
fi

echo "The CircleCI tunnel setup is complete"
