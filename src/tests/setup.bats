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
}

teardown() {
  lsof -ti tcp:4140 2>/dev/null | xargs kill 2>/dev/null || true
  rm -rf "$TEST_TMP"
  rm -rf /tmp/tunnel-proxy-bin
  rm -f /tmp/.tunnel-proxy-version
}

@test "register fails when CIRCLE_OIDC_TOKEN is unset" {
  unset CIRCLE_OIDC_TOKEN
  run bash src/scripts/register.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"CIRCLE_OIDC_TOKEN"* ]]
}

@test "register exports EXECUTOR_IP to BASH_ENV" {
  run bash src/scripts/register.sh
  [ "$status" -eq 0 ]
  grep -q 'EXECUTOR_IP="1.2.3.4"' "$BASH_ENV"
}

@test "setup exports HTTPS_PROXY when vcs tunnel exists" {
  run bash -c "bash src/scripts/register.sh && bash src/scripts/launch-proxy.sh"
  [ "$status" -eq 0 ]
  grep -q 'HTTPS_PROXY' "$BASH_ENV"
}

@test "setup exports NO_PROXY when HTTPS_PROXY is set" {
  run bash -c "bash src/scripts/register.sh && bash src/scripts/launch-proxy.sh"
  [ "$status" -eq 0 ]
  grep -q 'NO_PROXY' "$BASH_ENV"
}

@test "setup writes SSH config ProxyCommand for vcs-ssh tunnel" {
  run bash -c "bash src/scripts/register.sh && bash src/scripts/launch-proxy.sh"
  [ "$status" -eq 0 ]
  grep -q "Host ghe.corp.test" "$HOME/.ssh/config"
  grep -q "ProxyCommand" "$HOME/.ssh/config"
  grep -q "tunnel-proxy connect" "$HOME/.ssh/config"
  grep -q "vcs-ssh.tun.example.com" "$HOME/.ssh/config"
}

@test "setup writes SSH config entry for each host in multi-tunnel response" {
  write_curl_mock "$MOCK_MULTI_TUNNEL"

  run bash -c "bash src/scripts/register.sh && bash src/scripts/launch-proxy.sh"
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
    mkdir -p /tmp/tunnel-proxy-bin
    printf '#!/bin/bash\nexit 0\n' > "\$arg"
    chmod +x "\$arg" 2>/dev/null || true
    exit 0
  fi
  [[ "\$arg" == "-o" ]] && got_o=true
done
exit 0
CURLEOF
  chmod +x "$MOCK_BIN/curl"

  run bash -c "bash src/scripts/register.sh && bash src/scripts/launch-proxy.sh"
  [ "$status" -eq 0 ]
  grep -q "CircleCI-Labs/site-to-site-tunnel-proxy" "$curl_calls"
}

@test "setup skips HTTPS_PROXY when only vcs-ssh tunnel exists" {
  write_curl_mock "$MOCK_SSH_ONLY_TUNNEL"

  run bash -c "bash src/scripts/register.sh && bash src/scripts/launch-proxy.sh"
  [ "$status" -eq 0 ]
  ! grep -q 'HTTPS_PROXY' "$BASH_ENV"
}

@test "register retries tunnel-details on HTTP 500 and succeeds" {
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
    mkdir -p /tmp/tunnel-proxy-bin
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
  run bash src/scripts/register.sh
  [ "$status" -eq 0 ]
}

@test "register fails when tunnel-details returns non-200 after all retries" {
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
  run bash src/scripts/register.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"tunnel-details"* ]]
}

@test "setup PATH export does not bake in current PATH value" {
  run bash -c "bash src/scripts/register.sh && bash src/scripts/launch-proxy.sh"
  [ "$status" -eq 0 ]
  grep -qF '$PATH"' "$BASH_ENV"
}

@test "setup appends PARAM_NO_PROXY to NO_PROXY" {
  export PARAM_NO_PROXY="internal.corp.test,*.corp.test"
  run bash -c "bash src/scripts/register.sh && bash src/scripts/launch-proxy.sh"
  [ "$status" -eq 0 ]
  grep -q 'NO_PROXY=.*internal.corp.test' "$BASH_ENV"
  grep -q 'NO_PROXY=.*circleci.com' "$BASH_ENV"
}

@test "launch-proxy fails and dumps log when tunnel-proxy crashes on startup" {
  local crash_stub="$MOCK_BIN/crash-stub"
  printf '#!/bin/bash\nif [[ "$1" == "serve" ]]; then echo "fatal: failed to initialize" >&2; exit 1; fi\nexit 0\n' > "$crash_stub"
  chmod +x "$crash_stub"
  write_curl_mock_with_stub "$MOCK_SINGLE_TUNNEL" "$crash_stub"

  bash src/scripts/register.sh
  run bash src/scripts/launch-proxy.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"exited unexpectedly"* ]]
}

@test "launch-proxy fails and dumps log when tunnel-proxy does not bind to port 4140" {
  local sleep_stub="$MOCK_BIN/sleep-stub"
  printf '#!/bin/bash\nif [[ "$1" == "serve" ]]; then sleep 30; fi\nexit 0\n' > "$sleep_stub"
  chmod +x "$sleep_stub"
  write_curl_mock_with_stub "$MOCK_SINGLE_TUNNEL" "$sleep_stub"

  bash src/scripts/register.sh
  run bash src/scripts/launch-proxy.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not bind to port 4140"* ]]
}

@test "launch-proxy skips download when binary already exists (cache hit)" {
  # Pre-write tunnel details and pre-create the binary to simulate a cache hit
  echo "$MOCK_SSH_ONLY_TUNNEL" > "$TEST_TMP/tunnel_details.json"
  mkdir -p /tmp/tunnel-proxy-bin
  printf '#!/bin/bash\nexit 0\n' > /tmp/tunnel-proxy-bin/tunnel-proxy
  chmod +x /tmp/tunnel-proxy-bin/tunnel-proxy

  local curl_calls="$TEST_TMP/curl_calls"
  cat > "$MOCK_BIN/curl" <<CURLEOF
#!/bin/bash
echo "\$@" >> ${curl_calls}
exit 0
CURLEOF
  chmod +x "$MOCK_BIN/curl"

  run bash src/scripts/launch-proxy.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"Using cached tunnel-proxy"* ]]
  ! grep -q "CircleCI-Labs/site-to-site-tunnel-proxy" "$curl_calls"
}

# resolve-version.sh tests

@test "resolve-version writes pinned version to checksum file" {
  export PARAM_TUNNEL_PROXY_VERSION="v0.0.3"
  run bash src/scripts/resolve-version.sh
  [ "$status" -eq 0 ]
  [ -f "/tmp/.tunnel-proxy-version" ]
  [[ "$(cat /tmp/.tunnel-proxy-version)" == v0.0.3-* ]]
  [[ "$output" == *"v0.0.3"* ]]
}

@test "resolve-version resolves 'latest' via GitHub API" {
  # write_curl_mock (from setup) handles api.github.com and returns tag_name v0.0.3
  run bash src/scripts/resolve-version.sh
  [ "$status" -eq 0 ]
  [ -f "/tmp/.tunnel-proxy-version" ]
  [[ "$(cat /tmp/.tunnel-proxy-version)" == v0.0.3-* ]]
  [[ "$output" == *"Resolved to: v0.0.3"* ]]
}

@test "resolve-version includes OS and arch in checksum file" {
  export PARAM_TUNNEL_PROXY_VERSION="v0.0.3"
  run bash src/scripts/resolve-version.sh
  [ "$status" -eq 0 ]
  # Version file must have format: version-os-arch (three hyphen-separated segments)
  local content
  content="$(cat /tmp/.tunnel-proxy-version)"
  [[ "$content" =~ ^[^-]+-[^-]+-[^-]+$ ]]
}

# Windows-specific tests
# These mock uname to return MSYS_NT-10.0-20348, matching the actual CircleCI Windows Server 2022 executor.
# tunnel_details.json is pre-written directly (launch-proxy.sh reads it; register.sh writes it).

@test "launch-proxy uses 'windows' in download URL" {
  local curl_calls="$TEST_TMP/curl_calls"
  write_windows_uname_mock
  mock_cmd cygpath 0 "C:/tmp/tunnel-proxy-bin/tunnel-proxy.exe"
  # SSH-only tunnel: no HTTPS proxy daemon started, so no liveness check needed
  echo "$MOCK_SSH_ONLY_TUNNEL" > "$TEST_TMP/tunnel_details.json"

  cat > "$MOCK_BIN/curl" <<CURLEOF
#!/bin/bash
echo "\$@" >> ${curl_calls}
got_o=false
for arg in "\$@"; do
  if \$got_o; then
    mkdir -p /tmp/tunnel-proxy-bin
    printf '#!/bin/bash\nexit 0\n' > "\$arg"
    chmod +x "\$arg" 2>/dev/null || true
    exit 0
  fi
  [[ "\$arg" == "-o" ]] && got_o=true
done
exit 0
CURLEOF
  chmod +x "$MOCK_BIN/curl"

  run bash src/scripts/launch-proxy.sh
  [ "$status" -eq 0 ]
  grep -q "tunnel-proxy_windows_amd64" "$curl_calls"
}

@test "launch-proxy appends .exe to binary name on Windows" {
  local curl_calls="$TEST_TMP/curl_calls"
  write_windows_uname_mock
  mock_cmd cygpath 0 "C:/tmp/tunnel-proxy-bin/tunnel-proxy.exe"
  echo "$MOCK_SSH_ONLY_TUNNEL" > "$TEST_TMP/tunnel_details.json"

  cat > "$MOCK_BIN/curl" <<CURLEOF
#!/bin/bash
echo "\$@" >> ${curl_calls}
got_o=false
for arg in "\$@"; do
  if \$got_o; then
    mkdir -p /tmp/tunnel-proxy-bin
    printf '#!/bin/bash\nexit 0\n' > "\$arg"
    chmod +x "\$arg" 2>/dev/null || true
    exit 0
  fi
  [[ "\$arg" == "-o" ]] && got_o=true
done
exit 0
CURLEOF
  chmod +x "$MOCK_BIN/curl"

  run bash src/scripts/launch-proxy.sh
  [ "$status" -eq 0 ]
  grep -q "tunnel-proxy_windows_amd64.exe" "$curl_calls"
}

@test "launch-proxy skips nohup on Windows and still starts daemon" {
  write_windows_uname_mock
  mock_cmd cygpath 0 "C:/tmp/tunnel-proxy-bin/tunnel-proxy.exe"
  echo "$MOCK_SINGLE_TUNNEL" > "$TEST_TMP/tunnel_details.json"
  write_curl_mock "$MOCK_SINGLE_TUNNEL"

  local nohup_called="$TEST_TMP/nohup_called"
  cat > "$MOCK_BIN/nohup" <<NOHUPEOF
#!/bin/bash
touch "${nohup_called}"
exec "\$@"
NOHUPEOF
  chmod +x "$MOCK_BIN/nohup"

  run bash src/scripts/launch-proxy.sh
  [ "$status" -eq 0 ]
  [ ! -f "$nohup_called" ]
  grep -q 'HTTPS_PROXY' "$BASH_ENV"
}

@test "launch-proxy uses cygpath-converted path in SSH ProxyCommand on Windows" {
  write_windows_uname_mock
  mock_cmd cygpath 0 "C:/tmp/tunnel-proxy-bin/tunnel-proxy.exe"
  echo "$MOCK_SINGLE_TUNNEL" > "$TEST_TMP/tunnel_details.json"
  write_curl_mock "$MOCK_SINGLE_TUNNEL"

  run bash src/scripts/launch-proxy.sh
  [ "$status" -eq 0 ]
  grep -qF "C:/tmp/tunnel-proxy-bin/tunnel-proxy.exe" "$HOME/.ssh/config"
}

@test "launch-proxy writes tunnel env to PowerShell profile on Windows" {
  local ps_profile="$TEST_TMP/ps_profile.ps1"
  write_windows_uname_mock
  write_powershell_mock "$ps_profile"
  echo "$MOCK_SINGLE_TUNNEL" > "$TEST_TMP/tunnel_details.json"
  write_curl_mock "$MOCK_SINGLE_TUNNEL"

  run bash src/scripts/launch-proxy.sh
  [ "$status" -eq 0 ]
  [ -f "$ps_profile" ]
  grep -q 'HTTPS_PROXY' "$ps_profile"
  grep -q 'NO_PROXY' "$ps_profile"
  grep -q 'tunnel-proxy-bin' "$ps_profile"
  grep -q 'BEGIN site-to-site-orb' "$ps_profile"
}

@test "launch-proxy writes PATH but not HTTPS_PROXY to PowerShell profile on SSH-only tunnel" {
  local ps_profile="$TEST_TMP/ps_profile.ps1"
  write_windows_uname_mock
  write_powershell_mock "$ps_profile"
  echo "$MOCK_SSH_ONLY_TUNNEL" > "$TEST_TMP/tunnel_details.json"
  write_curl_mock "$MOCK_SSH_ONLY_TUNNEL"

  run bash src/scripts/launch-proxy.sh
  [ "$status" -eq 0 ]
  [ -f "$ps_profile" ]
  grep -q 'tunnel-proxy-bin' "$ps_profile"
  ! grep -q 'HTTPS_PROXY' "$ps_profile"
}

@test "launch-proxy verifies SHA256 of binary when PARAM_TUNNEL_PROXY_SHA256 is set" {
  # Pre-create binary with known content; skip download by placing it at the expected path
  echo "$MOCK_SSH_ONLY_TUNNEL" > "$TEST_TMP/tunnel_details.json"
  mkdir -p /tmp/tunnel-proxy-bin
  printf '#!/bin/bash\nexit 0\n' > /tmp/tunnel-proxy-bin/tunnel-proxy
  chmod +x /tmp/tunnel-proxy-bin/tunnel-proxy

  local sha
  if command -v sha256sum &>/dev/null; then
    sha=$(sha256sum /tmp/tunnel-proxy-bin/tunnel-proxy | awk '{print $1}')
  else
    sha=$(shasum -a 256 /tmp/tunnel-proxy-bin/tunnel-proxy | awk '{print $1}')
  fi

  export PARAM_TUNNEL_PROXY_SHA256="$sha"
  run bash src/scripts/launch-proxy.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHA256 verified"* ]]
}

@test "launch-proxy fails when SHA256 does not match" {
  echo "$MOCK_SSH_ONLY_TUNNEL" > "$TEST_TMP/tunnel_details.json"
  mkdir -p /tmp/tunnel-proxy-bin
  printf '#!/bin/bash\nexit 0\n' > /tmp/tunnel-proxy-bin/tunnel-proxy
  chmod +x /tmp/tunnel-proxy-bin/tunnel-proxy

  export PARAM_TUNNEL_PROXY_SHA256="0000000000000000000000000000000000000000000000000000000000000000"
  run bash src/scripts/launch-proxy.sh
  [ "$status" -ne 0 ]
}

@test "cleanup removes PowerShell profile entries on Windows" {
  local ps_profile="$TEST_TMP/ps_profile.ps1"
  cat > "$ps_profile" <<'PS1EOF'
# some existing content
# BEGIN site-to-site-orb
$env:HTTPS_PROXY = 'http://127.0.0.1:4140'
# END site-to-site-orb
PS1EOF

  write_windows_uname_mock
  write_powershell_mock "$ps_profile"
  mock_cmd taskkill 0 ""

  export CIRCLE_OIDC_TOKEN="test-token"
  export EXECUTOR_IP="1.2.3.4"

  cat > "$MOCK_BIN/curl" <<'CURLEOF'
#!/bin/bash
if [[ "$*" == *"ip-policy/remove"* ]]; then echo "200"; fi
exit 0
CURLEOF
  chmod +x "$MOCK_BIN/curl"

  run bash src/scripts/cleanup.sh
  [ "$status" -eq 0 ]
  grep -q 'some existing content' "$ps_profile"
  ! grep -q 'HTTPS_PROXY' "$ps_profile"
  ! grep -q 'BEGIN site-to-site-orb' "$ps_profile"
}
