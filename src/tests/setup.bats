#!/usr/bin/env bats

load 'helpers/mocks'

setup() {
  TEST_TMP="$(mktemp -d)"
  MOCK_BIN="$TEST_TMP/bin"
  mkdir -p "$TEST_TMP/.ssh"
  mkdir -p "$MOCK_BIN"
  export PATH="$MOCK_BIN:$PATH"
  export BASH_ENV="$TEST_TMP/bash_env"
  export HOME="$TEST_TMP"
  export TMPDIR="$TEST_TMP"
  touch "$BASH_ENV"

  export CIRCLE_OIDC_TOKEN="test-oidc-token"
  export PARAM_REG_RETRY_ATTEMPTS=1
  export PARAM_REG_RETRY_DELAY=0
  unset DEBUG
  unset PARAM_TUNNEL_PROXY_VERSION

  write_curl_mock "$MOCK_SINGLE_TUNNEL"
  mock_cmd tunnel-proxy 0 ""
}

teardown() {
  rm -rf "$TEST_TMP"
}

@test "setup fails when CIRCLE_OIDC_TOKEN is unset" {
  unset CIRCLE_OIDC_TOKEN
  run bash src/scripts/setup.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"CIRCLE_OIDC_TOKEN"* ]]
}

@test "setup exports EXECUTOR_IP to BASH_ENV" {
  run bash src/scripts/setup.sh
  [ "$status" -eq 0 ]
  grep -q 'EXECUTOR_IP="1.2.3.4"' "$BASH_ENV"
}

@test "setup exports HTTPS_PROXY when vcs tunnel exists" {
  run bash src/scripts/setup.sh
  [ "$status" -eq 0 ]
  grep -q 'HTTPS_PROXY' "$BASH_ENV"
}

@test "setup exports NO_PROXY when HTTPS_PROXY is set" {
  run bash src/scripts/setup.sh
  [ "$status" -eq 0 ]
  grep -q 'NO_PROXY' "$BASH_ENV"
}

@test "setup writes SSH config ProxyCommand for vcs-ssh tunnel" {
  run bash src/scripts/setup.sh
  [ "$status" -eq 0 ]
  grep -q "Host ghe.corp.test" "$HOME/.ssh/config"
  grep -q "ProxyCommand" "$HOME/.ssh/config"
  grep -q "tunnel-proxy connect" "$HOME/.ssh/config"
  grep -q "vcs-ssh.tun.example.com" "$HOME/.ssh/config"
}

@test "setup writes SSH config entry for each host in multi-tunnel response" {
  write_curl_mock "$MOCK_MULTI_TUNNEL"

  run bash src/scripts/setup.sh
  [ "$status" -eq 0 ]
  grep -q "Host ghe.corp1.test" "$HOME/.ssh/config"
  grep -q "Host gitlab.corp2.test" "$HOME/.ssh/config"
}

@test "setup downloads tunnel-proxy binary from GitHub releases URL" {
  local curl_calls="$TEST_TMP/curl_calls"
  cat > "$MOCK_BIN/curl" <<CURLEOF
#!/bin/bash
if [[ "\$*" == *"checkip"* ]]; then echo "1.2.3.4"; exit 0; fi
if [[ "\$*" == *"ip-policy/register"* ]]; then
  if [[ "\$*" == *"%{http_code}"* ]]; then echo "200"; fi
  exit 0
fi
if [[ "\$*" == *"tunnel-details"* ]]; then
  got_o=false
  for arg in "\$@"; do
    if \$got_o; then
      echo '{"tunnels":[{"service_type":"ssh","tunnel_domain":"vcs-ssh.tun.example.com","internal_host":"ghe.corp.test"}]}' > "\$arg"
      got_o=false
    fi
    [[ "\$arg" == "-o" ]] && got_o=true
  done
  echo "200"
  exit 0
fi
echo "\$@" >> ${curl_calls}
got_o=false
for arg in "\$@"; do
  if \$got_o; then
    printf '#!/bin/bash\nexit 0\n' > "\$arg"
    chmod +x "\$arg" 2>/dev/null || true
    exit 0
  fi
  [[ "\$arg" == "-o" ]] && got_o=true
done
exit 0
CURLEOF
  chmod +x "$MOCK_BIN/curl"

  run bash src/scripts/setup.sh
  [ "$status" -eq 0 ]
  grep -q "CircleCI-Labs/site-to-site-tunnel-proxy" "$curl_calls"
}

@test "setup skips HTTPS_PROXY when only vcs-ssh tunnel exists" {
  write_curl_mock "$MOCK_SSH_ONLY_TUNNEL"

  run bash src/scripts/setup.sh
  [ "$status" -eq 0 ]
  ! grep -q 'HTTPS_PROXY' "$BASH_ENV"
}

@test "setup retries tunnel-details on HTTP 500 and succeeds" {
  local call_count_file="$TEST_TMP/td_calls"
  echo 0 > "$call_count_file"
  cat > "$MOCK_BIN/curl" <<CURLEOF
#!/bin/bash
if [[ "\$*" == *"checkip"* ]]; then echo "1.2.3.4"; exit 0; fi
if [[ "\$*" == *"ip-policy/register"* ]]; then
  if [[ "\$*" == *"%{http_code}"* ]]; then echo "200"; fi
  exit 0
fi
if [[ "\$*" == *"tunnel-details"* ]]; then
  count=\$(cat ${call_count_file})
  count=\$((count + 1))
  echo "\$count" > ${call_count_file}
  if [ "\$count" -lt 2 ]; then echo "500"; exit 0; fi
  got_o=false
  for arg in "\$@"; do
    if \$got_o; then
      echo '{"tunnels":[{"service_type":"ssh","tunnel_domain":"vcs-ssh.tun.example.com","internal_host":"ghe.corp.test"}]}' > "\$arg"
      got_o=false
    fi
    [[ "\$arg" == "-o" ]] && got_o=true
  done
  echo "200"; exit 0
fi
got_o=false
for arg in "\$@"; do
  if \$got_o; then
    printf '#!/bin/bash\nexit 0\n' > "\$arg"
    chmod +x "\$arg" 2>/dev/null || true
    exit 0
  fi
  [[ "\$arg" == "-o" ]] && got_o=true
done
exit 0
CURLEOF
  chmod +x "$MOCK_BIN/curl"

  export PARAM_REG_RETRY_ATTEMPTS=3
  export PARAM_REG_RETRY_DELAY=0
  run bash src/scripts/setup.sh
  [ "$status" -eq 0 ]
}

@test "setup fails when tunnel-details returns non-200 after all retries" {
  cat > "$MOCK_BIN/curl" <<'CURLEOF'
#!/bin/bash
if [[ "$*" == *"checkip"* ]]; then echo "1.2.3.4"; exit 0; fi
if [[ "$*" == *"ip-policy/register"* ]]; then
  if [[ "$*" == *"%{http_code}"* ]]; then echo "200"; fi
  exit 0
fi
if [[ "$*" == *"tunnel-details"* ]]; then echo "500"; exit 0; fi
exit 0
CURLEOF
  chmod +x "$MOCK_BIN/curl"

  export PARAM_REG_RETRY_ATTEMPTS=2
  export PARAM_REG_RETRY_DELAY=0
  run bash src/scripts/setup.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"tunnel-details"* ]]
}

@test "setup PATH export does not bake in current PATH value" {
  run bash src/scripts/setup.sh
  [ "$status" -eq 0 ]
  grep -qF '$PATH"' "$BASH_ENV"
}

@test "setup appends PARAM_NO_PROXY to NO_PROXY" {
  export PARAM_NO_PROXY="internal.corp.test,*.corp.test"
  run bash src/scripts/setup.sh
  [ "$status" -eq 0 ]
  grep -q 'NO_PROXY=.*internal.corp.test' "$BASH_ENV"
  grep -q 'NO_PROXY=.*circleci.com' "$BASH_ENV"
}
