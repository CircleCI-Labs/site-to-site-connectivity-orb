# Terraform Test Infrastructure for Site-to-Site Orb

## Problem

All tests in `src/tests/setup.bats` are fully mocked. They verify script logic but
cannot catch failures in the actual tunnel path: OIDC auth against the CircleCI API,
tunnel-proxy binary behavior, or real SSH/HTTPS traffic flowing through the tunnel.

There is currently no automated test that runs the orb against a live tunnel target.

---

## Proposed Architecture

```
CircleCI executor
      │
      │ OIDC token (CIRCLE_OIDC_TOKEN)
      ▼
CircleCI Site-to-Site API  ──  register IP / fetch tunnel-details
      │
      │ tls://tunnel_domain:443
      ▼
  tunnel-proxy (local daemon)
      │  HTTPS_PROXY / SSH ProxyCommand
      ▼
Private target inside AWS VPC
  ┌──────────────────────────────────────┐
  │  VPC (10.0.0.0/16)                   │
  │                                      │
  │  ┌────────────┐   ┌───────────────┐  │
  │  │  Bastion / │   │  Mock HTTPS   │  │
  │  │  SSH target│   │  server       │  │
  │  │ :22        │   │  :443 / :80   │  │
  │  └────────────┘   └───────────────┘  │
  └──────────────────────────────────────┘
```

The CircleCI tunnel already handles the networking bridge from executor → VPC. The
Terraform only needs to stand up the VPC and the two test targets.

---

## Terraform Modules

### VPC (`modules/vpc`)

- Single VPC in `us-east-1` (CircleCI Cloud's primary region for tunnels)
- One private subnet (no IGW, no NAT — the tunnel is the only ingress)
- Security group: allow SSH (22) and HTTPS (443) from the tunnel's internal CIDR only

### SSH Target (`modules/ssh-target`)

- `t3.micro` running Amazon Linux 2023
- `openssh-server` installed and started
- Test user + authorized key injected via `user_data`
- Purpose: orb's SSH ProxyCommand + `git clone` flow can be validated

### HTTPS Target (`modules/https-target`)

- `t3.micro` running Amazon Linux 2023
- `nginx` serving HTTPS on port 443 with a self-signed cert
- Default `nginx` response is sufficient (orb only checks for any HTTP response)
- Purpose: confirm HTTPS_PROXY routing works end to end

### State Backend (`modules/backend`)

- S3 bucket + DynamoDB table for remote state
- Separate Terraform workspace per environment (dev / ci)

---

## CircleCI Integration

```yaml
# .circleci/test-deploy.yml (addition)
jobs:
  integration-test:
    docker:
      - image: cimg/base:current
    steps:
      - site-to-site-connectivity/setup
      - run:
          name: SSH connectivity check
          command: |
            ssh -o StrictHostKeyChecking=accept-new \
              testuser@<internal-ssh-host> 'echo connected'
      - run:
          name: HTTPS connectivity check
          command: |
            curl -k -s -o /dev/null -w "%{http_code}" \
              https://<internal-https-host>/ | grep -q '^[1-9]'
      - site-to-site-connectivity/cleanup:
          when: always
```

The internal host values come from Terraform outputs stored as CircleCI context
variables. The `site-to-site-tunnel` context already provides `CIRCLE_OIDC_TOKEN`.

---

## Estimated AWS Cost

| Resource | Type | Monthly (approx.) |
|---|---|---|
| SSH target EC2 | t3.micro | ~$8 |
| HTTPS target EC2 | t3.micro | ~$8 |
| VPC / networking | — | ~$0 |
| S3 state | minimal | ~$0 |
| **Total** | | **~$16/month** |

These instances only need to run during CI — they can be stopped between pipeline
runs or replaced with Lambda/ECS tasks to reduce cost further.

---

## Directory Layout

```
terraform/
├── main.tf              # root module wiring
├── variables.tf
├── outputs.tf
├── backend.tf           # S3 + DynamoDB state
└── modules/
    ├── vpc/
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    ├── ssh-target/
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    └── https-target/
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```

---

## Open Questions

1. **Which AWS account?** CircleCI Labs infra account, or a personal/team sandbox?
2. **Tunnel configuration**: the CircleCI tunnel allowlist must include the VPC's
   internal IP range. Who provisions the tunnel on the CircleCI side?
3. **SSH key management**: the test user key pair should live in AWS Secrets Manager
   and be surfaced to CircleCI as a context SSH key, not hardcoded in Terraform.
4. **Terraform apply in CI**: a separate `terraform-apply` workflow on
   infra-change PRs, with manual approval gate, keeps the infra in sync without
   running `apply` on every test pipeline run.
5. **Teardown policy**: do we destroy the instances after each pipeline run
   (lowest cost, slowest cold start) or leave them running (fastest, small fixed cost)?

---

## What This Does NOT Replace

The unit tests in `setup.bats` should remain. They run in 10 seconds, require no
credentials, and give fast feedback on script-level logic. The integration tests
complement them by confirming the full path works — they are not a replacement.
