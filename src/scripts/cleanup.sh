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

if [[ "${DEBUG:-}" == "true" ]]; then
  echo "DEBUG curl command:"
  echo curl -H 'Accept: application/json' \
    -H "Authorization: Bearer \${CIRCLE_OIDC_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"ip":"'"${EXECUTOR_IP}"'"}' \
    "https://internal.circleci.com/api/private/site-to-site/ip-policy/remove"
fi

http_code=$(curl -s -o /dev/null -w "%{http_code}" \
  -H 'Accept: application/json' \
  -H "Authorization: Bearer ${CIRCLE_OIDC_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"ip":"'"${EXECUTOR_IP}"'"}' \
  "https://internal.circleci.com/api/private/site-to-site/ip-policy/remove")

if [ "$http_code" -ne 200 ]; then
  echo "Error: IP removal failed (HTTP ${http_code})"
  if [ "$http_code" -eq 404 ]; then
    echo "This typically indicates an OIDC authentication issue."
  fi
  exit 1
fi

echo "CircleCI tunnel cleanup complete"
