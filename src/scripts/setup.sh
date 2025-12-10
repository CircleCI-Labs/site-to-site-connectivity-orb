#!/bin/bash

set -eu -o pipefail

tunnel_file="$(mktemp)"
ip="$(curl --fail https://checkip.amazonaws.com/)"

echo "Setting up circleci tunnel with IP: $ip"

curl -H 'Accept: application/json' \
  -H "Authorization: Bearer ${NGROK_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "Ngrok-Version: 2" \
  -d '{"action":"allow","cidr":"'${ip}'/32","description":"'$CIRCLE_BUILD_URL'","ip_policy_id":"'${IP_POLICY_ID}'"}' \
  --fail -o $tunnel_file \
  "https://api.ngrok.com/ip_policy_rules"

export REPO_PATH="${CIRCLE_REPO_URL#*:}"
echo "export REPO_URL=\"ssh://git@${TCP_ADDR}:${TCP_PORT}/$REPO_PATH\"" >> $BASH_ENV
echo "export IPR_ID=\"$(jq -r '.id' $tunnel_file)\"" >> $BASH_ENV

echo "Tunnel setup complete. REPO_URL and IPR_ID exported to environment."
