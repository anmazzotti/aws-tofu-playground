# aws-tofu-playground

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
  certificates across reboots.
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

# 2. Initialise providers
tofu init

# 3. Review the plan
tofu plan

# 4. Deploy
tofu apply
```

After `apply` completes, note the Elastic IP from the AWS console (or `tofu output` if you add an
output). The Pangolin dashboard will be available at:

```
https://pangolin.<elastic-ip>.sslip.io
```

Bootstrap takes ~3–5 minutes. You can follow the cloud-init progress via AWS SSM:

```sh
aws ssm start-session --target <instance-id>
sudo tail -f /var/log/cloud-init-output.log
```

## Variables

| Variable | Description | Default |
|---|---|---|
| `owner` | Your name — used for resource tags | **required** |
| `owner_email` | Email for Let's Encrypt certificate notifications | **required** |
| `pangolin_server_secret` | Pangolin server secret (sensitive) | **required** |
| `key_name` | EC2 key pair name for SSH. Leave empty to disable SSH | `""` |
| `ssh_allowed_cidrs` | CIDRs allowed for SSH. Leave empty for no public SSH (recommended) | `[]` |

> `terraform.tfvars` is gitignored. **Never commit real values.**

## Post-deployment: setting up Pangolin

### 1. Create the first admin account

Open the dashboard URL and complete the initial account setup. Registration is
invite-only by default (`disable_signup_without_invite: true`) — the first admin can issue
invites for additional team members.

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

This configuration uses `sslip.io` (IP-based wildcard DNS) for simplicity. EDR 009 specifies a
**dedicated domain**. If you need one, update `pangolin_base_domain` in `pangolin_init.sh` to
your domain and configure DNS A records for both the apex and `*.<domain>` pointing to the
Elastic IP.

## Importing pre-existing resources

If an EC2 instance and Elastic IP already exist and you want to manage them with OpenTofu:

```sh
OWNER=yourname ./import_resources.sh
```

## Maintenance

| Task | How |
|---|---|
| Stop paying during idle periods | Stop the EC2 instance from the AWS console. The Elastic IP and EBS volume (and their charges) persist. Terminate the instance only if you are done entirely. |
| Snapshots | EBS snapshot runs weekly (Saturdays, 04:00 UTC). Last 5 retained. Managed by DLM. |
| Update Pangolin | Update the image tag in `pangolin_init.sh` and re-run `tofu apply` to reprovision, or pull new images manually on the instance. |
| Destroy everything | `tofu destroy` |

## License

Copyright © 2026 SUSE LLC — Apache License 2.0. See [LICENSE](LICENSE) for details.
