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

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$os" in
  msys_nt* | msys* | mingw* | cygwin*) os="windows" ;;
esac

# Stop the tunnel-proxy daemon before deregistering so it releases the port
# and closes connections cleanly
if [ "$os" = "windows" ]; then
  taskkill /F /IM tunnel-proxy.exe 2>/dev/null || true
else
  pkill tunnel-proxy 2>/dev/null || true
fi

# On Windows, remove the env var block written to the PowerShell profile by
# launch-proxy.sh so subsequent jobs on the same machine start clean.
if [ "$os" = "windows" ]; then
  # shellcheck disable=SC2016
  _ps_profile_win=$(powershell.exe -NoProfile -NonInteractive \
    -Command '$PROFILE.AllUsersCurrentHost' 2>/dev/null | tr -d '\r\n' || true)
  if [ -n "$_ps_profile_win" ]; then
    _ps_profile=$(cygpath "$_ps_profile_win" 2>/dev/null || echo "$_ps_profile_win")
    if [ -f "$_ps_profile" ]; then
      if sed '/# BEGIN site-to-site-orb/,/# END site-to-site-orb/d' \
          "$_ps_profile" > "${_ps_profile}.tmp"; then
        mv "${_ps_profile}.tmp" "$_ps_profile" || true
      fi
    fi
  fi
fi

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
    --max-time 30 --connect-timeout 10 \
    -H 'Accept: application/json' \
    -H "Authorization: Bearer ${CIRCLE_OIDC_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"ip\":\"${EXECUTOR_IP}\"}" \
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
