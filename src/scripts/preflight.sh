#!/bin/bash

set -eu -o pipefail

missing=()
for tool in curl jq; do
  command -v "$tool" &>/dev/null || missing+=("$tool")
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo "Error: the following tools are required by this orb but were not found:" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  exit 1
fi
