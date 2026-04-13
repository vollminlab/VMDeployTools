# VMDeployTools — Architecture

## What it does

A PowerShell module that automates the full lifecycle of VMware vSphere VM deployment in the vollminlab homelab. A single command (`Invoke-VMDeployment`) provisions a VM end-to-end: SSH key generation, DNS registration, VM cloning, cloud-init configuration, and password storage — all integrated with 1Password and Pi-hole.

`Remove-VMDeployment` tears down everything: DNS, SSH config, 1Password items, and the VM itself.

## Design principles

- **1Password is the source of truth** for all credentials — nothing stored on disk or in environment variables between sessions
- **Early validation** — vCenter prerequisites (template, folder, cluster existence) checked before any side effects (SSH keys, DNS, VM creation)
- **Idempotent** where possible — SSH key creation reuses existing 1Password items, DNS add returns success if record already exists
- **Graceful degradation** — remote SSH mirroring and repo syncing fail silently, never abort deployment

## Full deployment workflow

```
Invoke-VMDeployment
│
├── 1. DNS conflict check (abort if FQDN already resolves)
│
├── 2. vCenter prerequisites validation (abort if template/folder/cluster missing)
│
├── 3. SSH key generation
│   └── Creates ed25519 keypair in 1Password as "{VMName}_id_ed25519"
│       Reuses existing key if found
│
├── 4. SSH config update
│   ├── Writes Host block to ~/.ssh/config (local)
│   ├── Writes to homelab-infrastructure repo SSH config (auto-discovered)
│   ├── Commits and pushes: "Add SSH config entry for {VMName}"
│   └── Mirrors to remote GLaDOS share if on secondary admin host
│
├── 5. DNS registration
│   └── POST /add-a-record to Pi-hole VRRP VIP:{VMName}.{Domain} → {IPAddress}
│
├── 6. VM creation
│   ├── Connect to vCenter
│   ├── Select datastore (prefers shared, falls back to local ESXi)
│   ├── Auto-detect network port group from IP subnet
│   ├── Clone from template
│   ├── Inject cloud-init via guestinfo properties (base64 encoded):
│   │   ├── user-data: hostname, user, SSH key, static IP, sudo password hash
│   │   └── metadata: instance-id, local-hostname
│   └── Resize CPU/memory/disk if specified
│
├── 7. Power on (optional -PowerOn flag)
│
└── 8. Store sudo password in 1Password as login item "{VMName}"
```

## Cloud-init configuration injected

```yaml
# user-data (simplified)
hostname: <VMName>
fqdn: <VMName>.<Domain>
users:
  - name: vollmin
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - <ed25519 public key from 1Password>
    passwd: <SHA-512 hashed random password>

network:
  version: 2
  ethernets:
    ens192:
      addresses: [<IPAddress>/24]
      gateway4: <first-three-octets>.1
      nameservers:
        addresses: [192.168.100.4, 192.168.100.3]
```

## Network port group detection

Port groups are selected based on the IP subnet of the VM:

| Subnet | Port group | Notes |
|--------|-----------|-------|
| 192.168.152.x | `152-DPG-GuestNet` | Main VM network |
| 192.168.160.x | `160-DPG-DMZ` | DMZ network |
| Other | Dynamic lookup (`{subnet}-DPG-*`) | Falls back to hardcoded map |

## Datastore selection

1. Checks datastores listed in `PreferredDatastores` config — uses first with sufficient free space
2. Falls back to the ESXi host's local datastore

## Repository auto-discovery

The module finds `homelab-infrastructure` automatically by:
1. Getting the GitHub remote URL of `VMDeployTools`
2. Extracting the org owner (`vollminlab`)
3. Searching sibling directories for a repo with the same GitHub owner

No hardcoded paths — works as long as both repos are cloned under the same parent directory.

## 1Password items created per VM

| Item title | Type | Contents |
|-----------|------|----------|
| `{VMName}_id_ed25519` | SSH Key | ed25519 keypair |
| `{VMName}` | Login | sudo password, username=vollmin |

Both items are archived (not deleted) on `Remove-VMDeployment`.

## Integration points

| System | How it's used |
|--------|--------------|
| 1Password CLI (`op`) | Key generation, secret storage, config bootstrap |
| 1Password SSH agent | SSH key auth (must be running at deploy time) |
| Pi-hole REST API | DNS A record registration/removal |
| VMware vCenter | VM clone, power, hardware config via PowerCLI |
| homelab-infrastructure repo | SSH config committed and pushed |
| Git | Auto-commit of SSH config changes |
