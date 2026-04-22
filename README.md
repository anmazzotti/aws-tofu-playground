# terraform-aws-pangolin

OpenTofu configuration to deploy a self-hosted [Pangolin](https://github.com/fosrl/pangolin)
tunnelling server on AWS, replacing Ngrok for local Rancher development environments.

This repository implements EDR 009: Pangolin as a Replacement for Ngrok.

## Architecture

```
┌──────────────────────────────────────────────┐
│  AWS eu-west-2a                               │
│                                              │
│  ┌──────────────────────────────────────┐   │
│  │  EC2 t3.micro (Debian 13)            │   │
│  │                                      │   │
│  │  ┌─────────┐  ┌────────┐  ┌───────┐ │   │
│  │  │Pangolin │  │ Gerbil │  │Traefik│ │   │
│  │  │ :3000   │  │WireGrd │  │ :443  │ │   │
│  │  └─────────┘  └────────┘  └───────┘ │   │
│  │  (Docker Compose, systemd-managed)   │   │
│  │                                      │   │
│  │  EBS 1 GB (/opt/pangolin — config    │   │
│  │  and Let's Encrypt state persist     │   │
│  │  across instance stops/starts)       │   │
│  └──────────────────────────────────────┘   │
│           │ Elastic IP (static)             │
└───────────┼─────────────────────────────────┘
            │ HTTPS / WireGuard tunnels
   ┌────────┴──────────────────────────┐
   │  Local kind cluster (developer)   │
   │  Newt agent (Helm) ──────────────►│
   └───────────────────────────────────┘
```

- **EC2 `t3.micro`** (Debian 13, `eu-west-2a`) — Pangolin + Gerbil + Traefik via Docker Compose,
  managed as a systemd service.
- **Elastic IP** — stable public endpoint that survives instance stops and starts.
- **EBS 1 GB** mounted at `/opt/pangolin` — persists Pangolin configuration and Let's Encrypt
  certificates across reboots and instance replacements.
- **DLM snapshot policy** — weekly EBS snapshot every Saturday at 04:00 UTC, last 5 retained.
- **Domain** — automatically derived from the Elastic IP using `sslip.io`
  (e.g. `pangolin.1-2-3-4.sslip.io`). No DNS delegation required.
- **TLS** — Let's Encrypt, HTTP-01 challenge via Traefik.

## Prerequisites

- [OpenTofu](https://opentofu.org/) ≥ 1.6
- AWS credentials with the following permissions: EC2 (instances, EIPs, security groups, EBS,
  DLM), IAM (role + policy creation for DLM).
- An [EC2 key pair](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-key-pairs.html) in
  `eu-west-2` — required if you enable SSH access (`key_name` + `ssh_allowed_cidrs`).

## Quickstart

```sh
# 1. Copy and fill in your variables
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

# 2. Run the bootstrap script — provisions everything and creates the first admin account
./bootstrap.sh
```

The script runs `tofu init`, shows you the plan, asks for confirmation, applies, then polls
the Pangolin API and creates the initial admin account automatically.

Follow the cloud-init progress at any point via AWS SSM:

```sh
aws ssm start-session --target <instance-id>
sudo tail -f /var/log/cloud-init-output.log
```

## Variables

| Variable | Description | Default |
|---|---|---|
| `region` | AWS region | `eu-west-2` |
| `owner` | Your name — used for resource tags | **required** |
| `owner_email` | Email for Let's Encrypt certificate notifications | **required** |
| `pangolin_server_secret` | Pangolin server secret (sensitive) | **required** |
| `key_name` | EC2 key pair name for SSH. Leave empty to disable SSH | `""` |
| `ssh_allowed_cidrs` | Your public IP as a `/32`. Leave empty for no SSH | `[]` |
| `hosted_zone_id` | Route53 hosted zone ID. Set together with `custom_domain` to use a real domain instead of sslip.io | `""` |
| `custom_domain` | Fully-qualified Pangolin dashboard domain (e.g. `pangolin.example.com`). Creates A records for the dashboard and `*.<parent>` for tunnels | `""` |
| `user_data_template` | Path to a custom bootstrap script template. Receives `owner_email`, `pangolin_server_secret`, `pangolin_device`, `pangolin_custom_domain` | bundled `pangolin_init.sh` |

> `terraform.tfvars` is gitignored. **Never commit real values.**

## Using this as a module

Other teams can consume the `pangolin-server` module directly from this repository:

```hcl
module "pangolin_server" {
  source = "github.com/anmazzotti/terraform-aws-pangolin//modules/pangolin-server?ref=<tag>"

  region                 = "us-east-1"
  owner                  = "alice"
  owner_email            = "alice@example.com"
  pangolin_server_secret = var.pangolin_server_secret
}

output "pangolin_url" {
  value = module.pangolin_server.pangolin_url
}
```

To use a customised bootstrap script while reusing the rest of the infrastructure, pass a path
to your own template via `user_data_template`. The template receives the same variables as the
bundled `pangolin_init.sh`: `owner_email`, `pangolin_server_secret`, `pangolin_device`,
`pangolin_custom_domain`.

## Post-deployment: setting up Pangolin

### 1. Create the first admin account

`bootstrap.sh` does this automatically — it polls the Pangolin API after `apply` and creates
the admin account via the API. If you skipped `bootstrap.sh` or the automated step failed,
open the dashboard URL printed by `tofu output pangolin_url` and complete registration manually.
Registration is invite-only after the first account is created (`disable_signup_without_invite: true`);
the first admin can issue invites for additional team members.

### 2. Create a Site

In the Pangolin dashboard:

1. Go to **Sites → New Site**.
2. Give it a name (e.g. your cluster name) and save the **Site ID** and **Secret**.

### 3. Create a Resource

1. Go to **Resources → New Resource** under your Site.
2. Set the **Target** to a cluster-internal address — always use `*.svc.cluster.local`, never bare
   IPs or external hostnames (EDR 009 mandatory requirement).  
   Example: `rancher.cattle-system.svc.cluster.local:80`
3. Set a **subdomain** for the resource, e.g. `rancher` → accessible at
   `https://rancher.<elastic-ip>.sslip.io`.

### 4. Install Newt on the local cluster

Use the [Newt Helm chart](https://github.com/fosrl/newt) to connect your local kind cluster to
the Pangolin server:

```sh
helm repo add pangolin https://charts.pangolin.net
helm repo update

# Store Site credentials as a Kubernetes Secret — never in plaintext Helm values
kubectl create namespace newt-system
kubectl create secret generic newt-site \
  --namespace newt-system \
  --from-literal=id=<SITE_ID> \
  --from-literal=secret=<SITE_SECRET>

helm install newt pangolin/newt \
  --namespace newt-system \
  --set pangolin.endpoint=https://pangolin.<elastic-ip>.sslip.io \
  --set site.existingSecret=newt-site
```

> See the Newt chart documentation for the exact secret key names.

## Security

The following controls are **mandatory** per EDR 009:

| Control | Status in this repo |
|---|---|
| No public SSH | ✅ SSH disabled by default (`ssh_allowed_cidrs = []`). To enable, set to your public IP as a `/32`. Key-based auth only — passwords always disabled (EDR 009). |
| Cluster-internal targets only (`*.svc.cluster.local`) | ✅ Enforced by team policy; admission webhook recommended where feasible |
| Pangolin authentication always enabled | ✅ `disable_signup_without_invite: true` in `pangolin_init.sh` |
| Site credentials as Kubernetes Secrets | ✅ Documented above; never commit plaintext values |
| Minimal Security Group exposure | ✅ Only ports 80, 443 (TCP+UDP), 51820 UDP, 21820 UDP exposed publicly |
| OS-level patching | ✅ `unattended-upgrades` installed and enabled at boot; security-only, auto-reboot at 04:30 |

Recommended controls (EDR 009):

- Apply a Kubernetes `NetworkPolicy` on the Newt pod to restrict egress to the Pangolin server IP
  and cluster-internal destinations, explicitly denying RFC-1918 and VPN-internal CIDRs.
- Consider running the kind cluster inside an isolated VM (Lima / Multipass) with no VPN
  interface to eliminate the lateral-movement risk surface entirely.

### Domain note

By default this configuration uses `sslip.io` (IP-based wildcard DNS) — no DNS delegation
required. To use a real domain, set `hosted_zone_id` and `custom_domain` in `terraform.tfvars`:

```hcl
hosted_zone_id = "Z1PA6795UKMFR9"   # Route53 hosted zone for example.com
custom_domain  = "pangolin.example.com"
```

This creates two Route53 A records pointing to the Elastic IP:
- `pangolin.example.com` — Pangolin dashboard
- `*.example.com` — resource tunnel subdomains (e.g. `rancher.example.com`)

The AWS credentials need `route53:ChangeResourceRecordSets` and `route53:GetChange` in addition
to the standard EC2/IAM/DLM permissions.

## Maintenance

### Costs (eu-west-2, ~150 GB/month outbound)

| Resource | Running | Stopped |
|---|---|---|
| EC2 t3.micro | ~$8.50/month | $0 |
| Elastic IP | free (attached) | ~$3.65/month |
| EBS 1 GB | ~$0.10/month | ~$0.10/month |
| EBS snapshots (5 × incremental) | ~$0.25/month | ~$0.25/month |
| Data out (~150 GB) | ~$13.50/month | $0 |
| **Total** | **~$22–24/month** | **~$4/month** |

Stopping the instance during idle periods (nights, weekends) is the easiest way to reduce costs.
The Elastic IP, EBS volume, and snapshots continue to accrue charges regardless.

### Weekly automated refresh

A GitHub Action (`.github/workflows/weekly-refresh.yml`) runs every Sunday at 03:00 UTC — after
Saturday's EBS snapshot. It refreshes the EC2 instance without maintaining any Terraform state:

```
1. Import all existing AWS resources into a fresh local state
2. tofu destroy -target module.pangolin_server.aws_instance.pangolin
3. tofu apply
```

The EBS volume and Elastic IP are **never destroyed**, so Pangolin configuration, Let's Encrypt
certificates, and the dashboard URL all survive. The new instance boots with the current
`pangolin_init.sh`, which pulls the pinned image versions. When Renovate merges a version bump
PR, the next weekly run picks it up automatically.

Configure the following in your GitHub repository before enabling the workflow:

| Type | Name | Value |
|---|---|---|
| Secret | `AWS_ACCESS_KEY_ID` | AWS access key with EC2/IAM/DLM permissions |
| Secret | `AWS_SECRET_ACCESS_KEY` | Corresponding secret key |
| Secret | `TF_VAR_PANGOLIN_SERVER_SECRET` | Pangolin server secret |
| Variable | `OWNER` | Your name (matches resource tags) |
| Variable | `OWNER_EMAIL` | Email for Let's Encrypt |
| Variable | `AWS_REGION` | AWS region (optional, defaults to `eu-west-2`) |

### Other tasks

| Task | How |
|---|---|
| Stop paying during idle periods | Stop the EC2 instance from the AWS console. The Elastic IP and EBS volume (and their charges) persist. Terminate the instance only if you are done entirely. |
| Snapshots | EBS snapshot runs weekly (Saturdays, 04:00 UTC). Last 5 retained. Managed by DLM. |
| Destroy everything | `tofu destroy` |

## License

Copyright © 2026 SUSE LLC — Apache License 2.0. See [LICENSE](LICENSE) for details.
