#!/bin/bash

set -eu -o pipefail

echo "Cleaning up circleci tunnel with IPR_ID: $IPR_ID"

curl -H 'Accept: application/json' \
  -H "Authorization: Bearer ${NGROK_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "Ngrok-Version: 2" \
  -X DELETE \
  --fail \
  "https://api.ngrok.com/ip_policy_rules/${IPR_ID}"

echo "Tunnel cleanup complete."
