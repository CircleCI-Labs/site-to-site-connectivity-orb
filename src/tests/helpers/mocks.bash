# write_curl_mock_with_stub <tunnel_json> <stub_file>
# Creates a curl mock that handles all S2S API calls and copies stub_file to
# the -o target for binary download requests.
write_curl_mock_with_stub() {
  local tunnel_json="$1"
  local stub_file="$2"
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
      echo '${tunnel_json}' > "\$arg"
      got_o=false
    fi
    [[ "\$arg" == "-o" ]] && got_o=true
  done
  echo "200"
  exit 0
fi
got_o=false
for arg in "\$@"; do
  if \$got_o; then
    cp "${stub_file}" "\$arg"
    chmod +x "\$arg" 2>/dev/null || true
    exit 0
  fi
  [[ "\$arg" == "-o" ]] && got_o=true
done
exit 0
CURLEOF
  chmod +x "$MOCK_BIN/curl"
}

# write_curl_mock <tunnel_json>
# Creates a curl mock backed by a tunnel-proxy stub that binds to port 4140
# on 'serve' (satisfying both the kill -0 liveness check and nc -z port check).
write_curl_mock() {
  local tunnel_json="$1"
  local stub_file="$MOCK_BIN/tunnel-proxy-stub"
  cat > "$stub_file" <<'STUBEOF'
#!/bin/bash
if [[ "$1" == "serve" ]]; then
  python3 -c "
import socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 4140))
s.listen(1)
time.sleep(30)
"
  exit 0
fi
exit 0
STUBEOF
  chmod +x "$stub_file"
  write_curl_mock_with_stub "$tunnel_json" "$stub_file"
}

# mock_cmd <name> <exit_code> <stdout>
# Creates a mock binary in MOCK_BIN that prints stdout and exits with exit_code.
# Requires MOCK_BIN to be set and in PATH before calling.
mock_cmd() {
  local name="$1" code="$2" out="$3"
  cat > "$MOCK_BIN/$name" <<EOF
#!/bin/bash
echo '$out'
exit $code
EOF
  chmod +x "$MOCK_BIN/$name"
}

# Single-tunnel response: one internal host, both vcs and vcs-ssh
MOCK_SINGLE_TUNNEL='{"tunnels":[{"service_type":"https","tunnel_domain":"vcs.tun.example.com","internal_host":"ghe.corp.test"},{"service_type":"ssh","tunnel_domain":"vcs-ssh.tun.example.com","internal_host":"ghe.corp.test"}]}'

# Multi-tunnel response: two internal hosts, each with https and ssh
MOCK_MULTI_TUNNEL='{"tunnels":[{"service_type":"https","tunnel_domain":"vcs1.tun.example.com","internal_host":"ghe.corp1.test"},{"service_type":"ssh","tunnel_domain":"vcs-ssh1.tun.example.com","internal_host":"ghe.corp1.test"},{"service_type":"https","tunnel_domain":"vcs2.tun.example.com","internal_host":"gitlab.corp2.test"},{"service_type":"ssh","tunnel_domain":"vcs-ssh2.tun.example.com","internal_host":"gitlab.corp2.test"}]}'

# SSH-only response: no https, only ssh
MOCK_SSH_ONLY_TUNNEL='{"tunnels":[{"service_type":"ssh","tunnel_domain":"vcs-ssh.tun.example.com","internal_host":"ghe.corp.test"}]}'
