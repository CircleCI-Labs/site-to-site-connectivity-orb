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
if [ -z "${GIT_URL:-}" ]; then
  echo "Error: GIT_URL is not set or empty"
  missing=1
fi
if [ -z "${CHECKOUT_FOLDER:-}" ]; then
  echo "Error: CHECKOUT_FOLDER is not set or empty"
  missing=1
fi
if [ "$missing" -ne 0 ]; then
  exit 1
fi

# Extract the repository path from the Git URL
echo "Extracting repository path from Git URL: ${GIT_URL}"
REPO_PATH="${GIT_URL#*:}"

if [[ -n "${DEBUG:-}" ]]; then
  echo "DEBUG REPO_PATH: ${REPO_PATH}"
fi

REPO_URL="ssh://git@${resolved_tunnel_address}:${resolved_tunnel_port}/${REPO_PATH}"
echo "Constructed repository URL: ${REPO_URL}"

# Create the SSH directory if it doesn't exist
mkdir ~/.ssh || true

# Scan the SSH key for the repository
ssh-keyscan -p "${resolved_tunnel_port}" "${resolved_tunnel_address}" >> ~/.ssh/known_hosts

# Clone the repository
echo "Cloning repository from: ${REPO_URL} into: ${CHECKOUT_FOLDER}"

# Determine git history depth or unlimited
depth_arg=""
if [ -n "${CHECKOUT_DEPTH:-}" ]; then
  depth_arg="--depth ${CHECKOUT_DEPTH}"
fi

# Determine what to clone (branch or tag)
if [ -n "${CIRCLE_BRANCH:-}" ]; then
  echo "Cloning branch: ${CIRCLE_BRANCH}"
  GIT_TERMINAL_PROMPT=0 git clone --branch ${CIRCLE_BRANCH} --single-branch ${depth_arg} "$REPO_URL" "${CHECKOUT_FOLDER}"
elif [ -n "${CIRCLE_TAG:-}" ]; then
  echo "Cloning tag: ${CIRCLE_TAG}"
  GIT_TERMINAL_PROMPT=0 git clone --branch ${CIRCLE_TAG} --single-branch ${depth_arg} "$REPO_URL" "${CHECKOUT_FOLDER}"
else
  echo "Error: Neither CIRCLE_BRANCH nor CIRCLE_TAG is set"
  exit 1
fi

echo "Repository cloned successfully."
