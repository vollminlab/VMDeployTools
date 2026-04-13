# CLAUDE.md — VMDeployTools

PowerShell module for automated VMware vSphere VM provisioning in the vollminlab homelab. Integrates with 1Password (SSH keys, credentials), Pi-hole (DNS), and the homelab-infrastructure repo (SSH config).

## What it does

`Invoke-VMDeployment` — full VM provisioning: SSH key → DNS registration → VM clone → cloud-init → password storage  
`Remove-VMDeployment` — full teardown: DNS → SSH config → 1Password archive → VM deletion

## Key design facts

- Config bootstraps from 1Password secure note `"VMDeployTools Config"` on first import — no manual setup
- vCenter prerequisites validated BEFORE any side effects (SSH keys, DNS, VM creation)
- homelab-infrastructure repo must be cloned in the same parent directory as VMDeployTools (auto-discovered by GitHub owner)
- 1Password SSH agent must be running for SSH key auth to work
- Pi-hole API called against VRRP VIP (192.168.100.1) — HA-aware

## DNS

Pi-hole REST API at port 5001. Token: `op://Homelab/recordimporter-api-token/credential`  
VMs get A record: `{VMName}.vollminlab.com → {IPAddress}`

## Networks

| Subnet | vSphere port group |
|--------|-------------------|
| 192.168.152.x | 152-DPG-GuestNet |
| 192.168.160.x | 160-DPG-DMZ |

## 1Password items created per VM

- `{VMName}_id_ed25519` — SSH keypair
- `{VMName}` — login item with sudo password (username: vollmin)

## Key docs

- `docs/architecture.md` — full deployment workflow, cloud-init config, integration points
- `docs/configuration.md` — 1Password bootstrap, config keys explained
- `docs/operations.md` — deploy/remove commands, troubleshooting
