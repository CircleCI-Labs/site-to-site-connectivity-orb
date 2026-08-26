#!/usr/bin/env bats

# Compile-time gating tests.
#
# The `when:` conditions in src/commands/setup.yml are resolved by the config
# compiler, not by bash, so setup.bats cannot reach them — it runs the scripts
# directly and never sees the step wiring. These tests pack the orb, inline it
# into a throwaway config, and assert which steps survive processing for a
# given parameter set. No credentials, no network, no tunnels.
#
# Every release up to 0.2.1 gated verification at runtime instead, with
# `[[ -n "${PARAM_VERIFY_TUNNEL:-}" ]]`. A boolean parameter interpolates into
# the environment as the literal text `false`, and `-n "false"` is true, so
# `verify-tunnel: false` was a silent no-op. These tests pin the compile-time
# behaviour so that cannot ship again.

# gating.bats needs the v1 CircleCI CLI (cli.circleci.com): `orb pack` and
# `config process`. The legacy 0.1.x CLI is a different binary.
is_new_circleci_cli() {
  command -v circleci >/dev/null || return 1
  local ver
  ver="$(circleci version 2>/dev/null || true)"
  [[ "$ver" == circleci\ 1.* ]] || return 1
  circleci orb pack --help >/dev/null 2>&1
}

setup_file() {
  export PACKED="$BATS_FILE_TMPDIR/packed.yml"
  if is_new_circleci_cli; then
    circleci orb pack src >"$PACKED"
  fi
}

setup() {
  is_new_circleci_cli || skip "v1 CircleCI CLI (cli.circleci.com) with orb pack is required"
  [[ -s "${PACKED:-}" ]] || skip "orb pack did not produce packed.yml"
}

# compile <params-yaml>
# Processes `s2s/setup` with the given parameter block and emits the resulting
# job definition. Params are required — `- s2s/setup:` with a null value is not
# valid config.
compile() {
  local cfg="$BATS_TEST_TMPDIR/config.yml"
  {
    echo "version: 2.1"
    echo "orbs:"
    echo "  s2s:"
    sed 's/^/    /' "$PACKED"
    echo "jobs:"
    echo "  t:"
    echo "    docker:"
    echo "      - image: cimg/base:current"
    echo "    steps:"
    echo "      - s2s/setup:"
    echo "$1" | sed 's/^/          /'
    echo "workflows:"
    echo "  w:"
    echo "    jobs: [t]"
  } >"$cfg"
  circleci config process "$cfg"
}

# steps <params-yaml> — one step name per line, in order.
# restore_cache/save_cache carry no `name:` key and so do not appear here;
# use has_step_key for those.
steps() {
  compile "$1" | grep -o 'name: .*' | sed 's/^name: //'
}

# has_step_key <step-key> <params-yaml>
# True if the compiled job contains the given bare step key. Anchored to the
# YAML list item, because these keys also appear in embedded script comments.
has_step_key() {
  compile "$2" | grep -qE "^ *- $1:"
}

@test "verify-tunnel: false drops the verify step from the compiled job" {
  run steps "verify-tunnel: false"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Verify tunnel connectivity"* ]]
  # The rest of the command must still be intact — a config that failed to
  # compile at all would also satisfy the assertion above.
  [[ "$output" == *"Launch tunnel proxy"* ]]
}

@test "verify-tunnel: true keeps the verify step" {
  run steps "verify-tunnel: true"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Verify tunnel connectivity"* ]]
}

@test "verify-tunnel defaults to on" {
  run steps "no-proxy: ''"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Verify tunnel connectivity"* ]]
}

@test "verify step is ordered after the proxy is launched" {
  run steps "verify-tunnel: true"
  [ "$status" -eq 0 ]
  launch=$(echo "$output" | grep -n 'Launch tunnel proxy' | cut -d: -f1)
  verify=$(echo "$output" | grep -n 'Verify tunnel connectivity' | cut -d: -f1)
  [ "$launch" -lt "$verify" ]
}

@test "cache: false drops both cache steps" {
  ! has_step_key restore_cache "cache: false"
  ! has_step_key save_cache "cache: false"
}

@test "cache: true keeps both cache steps" {
  has_step_key restore_cache "cache: true"
  has_step_key save_cache "cache: true"
}

@test "debug: false drops the log dump step" {
  run steps "debug: false"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Dump tunnel-proxy logs"* ]]
}

@test "debug: true keeps the log dump step" {
  run steps "debug: true"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dump tunnel-proxy logs"* ]]
}

@test "boolean params are never gated with a bare -n string test" {
  # `[[ -n "false" ]]` is true. Gating a boolean this way is what made
  # verify-tunnel a no-op in every release up to 0.2.1. PARAM_NO_PROXY is a
  # string parameter and is legitimately tested with -n.
  run grep -rn -- '-n "${DEBUG' src/scripts/
  [ "$status" -ne 0 ]
  run grep -rn -- '-n "${PARAM_VERIFY' src/scripts/
  [ "$status" -ne 0 ]
}
