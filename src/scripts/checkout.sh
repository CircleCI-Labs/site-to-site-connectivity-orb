#!/bin/bash

set -eu -o pipefail

if [ -z "${PARAM_GIT_URL:-}" ]; then
  echo "Error: git-url parameter is required" >&2
  exit 1
fi
git_url="${PARAM_GIT_URL}"
checkout_folder="${PARAM_CHECKOUT_FOLDER:-$HOME/project}"
# shellcheck disable=SC2088
case "$checkout_folder" in
  '~'/*) checkout_folder="$HOME/${checkout_folder#~/}" ;;
  '~') checkout_folder="$HOME" ;;
esac
checkout_depth="${PARAM_CHECKOUT_DEPTH:-1}"
clone_timeout="${PARAM_CLONE_TIMEOUT:-120}"
max_attempts="${PARAM_MAX_ATTEMPTS:-3}"
retry_delay="${PARAM_RETRY_DELAY:-10}"
install_coreutils="${PARAM_INSTALL_COREUTILS:-true}"

ref="${PARAM_REF:-}"
if [ -z "$ref" ]; then
  if [ -n "${CIRCLE_TAG:-}" ]; then
    ref="$CIRCLE_TAG"
  elif [ -n "${CIRCLE_BRANCH:-}" ]; then
    ref="$CIRCLE_BRANCH"
  fi
fi
if [ -z "$ref" ]; then
  echo "Error: no ref to clone — set the 'ref' parameter or ensure CIRCLE_TAG/CIRCLE_BRANCH is exported." >&2
  exit 1
fi

# Best-effort host extraction from git@host:path syntax, used only for clearer
# diagnostics. SSH ProxyCommand routing is driven entirely by ~/.ssh/config
# entries that the setup command writes.
host_from_url=""
case "$git_url" in
  *@*:*)
    host_from_url="${git_url#*@}"
    host_from_url="${host_from_url%%:*}"
    ;;
esac

# On macOS, `timeout` is not in PATH by default. Optionally install Homebrew
# coreutils so `gtimeout` is available for bounded clone attempts. Hardened
# against the v0.1.2 issues: no `-y` flag, non-interactive, brew presence
# check, post-install verification.
need_install=0
if [[ "$(uname -s)" == "Darwin" ]] \
  && [[ "$install_coreutils" == "true" || "$install_coreutils" == "1" ]] \
  && ! command -v timeout >/dev/null 2>&1 \
  && ! command -v gtimeout >/dev/null 2>&1; then
  need_install=1
fi

if [ "$need_install" -eq 1 ]; then
  echo "macOS detected and no timeout/gtimeout on PATH; installing coreutils..."

  if ! command -v brew >/dev/null 2>&1; then
    echo "Error: Homebrew (brew) was not found on PATH; cannot install coreutils." >&2
    echo "Install Homebrew (https://brew.sh), pre-install coreutils, or set install-coreutils=false." >&2
    exit 1
  fi

  if brew list --formula coreutils >/dev/null 2>&1; then
    echo "coreutils already installed; skipping install."
  else
    echo "Installing coreutils via Homebrew..."
    export NONINTERACTIVE=1
    export HOMEBREW_NO_AUTO_UPDATE=1
    export HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1
    export HOMEBREW_NO_ENV_HINTS=1
    if ! brew install coreutils; then
      echo "Error: 'brew install coreutils' failed." >&2
      exit 1
    fi
  fi

  if ! brew list --formula coreutils >/dev/null 2>&1; then
    echo "Error: coreutils not detected after install attempt." >&2
    exit 1
  fi

  if ! command -v gtimeout >/dev/null 2>&1 && ! command -v timeout >/dev/null 2>&1; then
    echo "Error: neither 'timeout' nor 'gtimeout' is available on PATH after coreutils install." >&2
    exit 1
  fi

  echo "coreutils is installed and gtimeout is available."
fi

timeout_bin=""
if command -v gtimeout >/dev/null 2>&1; then
  timeout_bin="gtimeout"
elif command -v timeout >/dev/null 2>&1; then
  timeout_bin="timeout"
else
  echo "Note: no timeout/gtimeout on PATH; clone attempts will not be time-bounded." >&2
fi

depth_args=()
if [ "$checkout_depth" -gt 0 ] 2>/dev/null; then
  depth_args+=("--depth" "$checkout_depth")
fi

if [[ "${DEBUG:-}" == "true" || "${DEBUG:-}" == "1" ]]; then
  echo "DEBUG checkout config:"
  echo "  git_url:         $git_url"
  echo "  host:            ${host_from_url:-<unparsed>}"
  echo "  ref:             $ref"
  echo "  checkout_folder: $checkout_folder"
  echo "  checkout_depth:  $checkout_depth"
  echo "  clone_timeout:   ${clone_timeout}s"
  echo "  max_attempts:    $max_attempts"
  echo "  retry_delay:     ${retry_delay}s"
  echo "  timeout_bin:     ${timeout_bin:-<none>}"
fi

# setup writes per-host ProxyCommand blocks with `StrictHostKeyChecking
# accept-new`, so ssh-keyscan is unnecessary. Sanity-check the config exists
# and warn (but don't fail) if the target host has no matching block.
if [ -n "$host_from_url" ] && [ -f "${HOME}/.ssh/config" ]; then
  if ! grep -qE "^[[:space:]]*Host[[:space:]]+${host_from_url}([[:space:]]|$)" "${HOME}/.ssh/config"; then
    echo "Warning: ${host_from_url} has no SSH ProxyCommand entry in ~/.ssh/config." >&2
    echo "  Confirm this host is returned by the tunnel-details API and that" >&2
    echo "  the site-to-site-connectivity/setup command ran in this job." >&2
  fi
fi

attempt=0
last_status=1
while [ "$attempt" -lt "$max_attempts" ]; do
  attempt=$((attempt + 1))
  echo "Clone attempt ${attempt}/${max_attempts}: ${git_url} -> ${checkout_folder} (ref: ${ref})"

  rm -rf "$checkout_folder"
  mkdir -p "$(dirname "$checkout_folder")"

  set +e
  if [ -n "$timeout_bin" ]; then
    GIT_TERMINAL_PROMPT=0 "$timeout_bin" "${clone_timeout}s" \
      git clone --branch "$ref" --single-branch "${depth_args[@]}" \
      "$git_url" "$checkout_folder"
  else
    GIT_TERMINAL_PROMPT=0 \
      git clone --branch "$ref" --single-branch "${depth_args[@]}" \
      "$git_url" "$checkout_folder"
  fi
  last_status=$?
  set -e

  if [ "$last_status" -eq 0 ]; then
    echo "Clone succeeded on attempt ${attempt}."
    exit 0
  fi

  echo "Clone attempt ${attempt} failed with exit ${last_status}." >&2
  if [ "$attempt" -lt "$max_attempts" ]; then
    echo "Retrying in ${retry_delay}s..." >&2
    sleep "$retry_delay"
  fi
done

echo "Error: clone failed after ${max_attempts} attempts (last exit: ${last_status})." >&2
exit "$last_status"
