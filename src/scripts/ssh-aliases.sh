#!/bin/bash

set -eu -o pipefail

# Check if environment variables are set
missing=0

# Resolve indirect values (PARAM_* contains the variable name to read)
resolved_tunnel_address="${!PARAM_TUNNEL_ADDRESS:-}"
resolved_tunnel_port="${!PARAM_TUNNEL_PORT:-}"

if [ -z "${resolved_tunnel_address}" ]; then
  echo "Error: ${PARAM_TUNNEL_ADDRESS} is not set or empty"
  missing=1
fi
if [ -z "${resolved_tunnel_port}" ]; then
  echo "Error: ${PARAM_TUNNEL_PORT} is not set or empty"
  missing=1
fi
if [ -z "${ORIGINAL_HOSTNAME:-}" ]; then
  echo "Error: ORIGINAL_HOSTNAME is not set or empty"
  missing=1
fi
if [ "$missing" -ne 0 ]; then
  exit 1
fi

# Create the SSH directory if it doesn't exist
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# Add the tunnel host to known_hosts
echo "Adding tunnel host to known_hosts..."
# ssh-keyscan -p "${resolved_tunnel_port}" "${resolved_tunnel_address}" >> ~/.ssh/known_hosts 2>/dev/null
ssh-keyscan -T 10 -p "${resolved_tunnel_port}" "${resolved_tunnel_address}" >> ~/.ssh/known_hosts 2>/dev/null || true #for testing

# Create or append to SSH config
SSH_CONFIG=~/.ssh/config

echo "Configuring SSH alias for ${ORIGINAL_HOSTNAME} -> ${resolved_tunnel_address}:${resolved_tunnel_port}"

cat >> "$SSH_CONFIG" << EOF

# CircleCI tunnel redirect for ${ORIGINAL_HOSTNAME}
# Added by site-to-site-connectivity orb
Host ${ORIGINAL_HOSTNAME}
    HostName ${resolved_tunnel_address}
    Port ${resolved_tunnel_port}
    User git
    StrictHostKeyChecking no
    UserKnownHostsFile ~/.ssh/known_hosts

EOF

chmod 600 "$SSH_CONFIG"

if [[ -n "${DEBUG:-}" ]]; then
  echo "DEBUG: SSH config contents:"
  cat "$SSH_CONFIG"
fi

echo "SSH configuration complete."
echo "Git commands using '${ORIGINAL_HOSTNAME}' will now route through the tunnel."
echo ""
echo "Example: git clone git@${ORIGINAL_HOSTNAME}:org/repo.git"
echo "  -> Will connect to ${resolved_tunnel_address}:${resolved_tunnel_port}"