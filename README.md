# VMDeployTools

PowerShell module for automated VM deployment in VMware vSphere with integrated 1Password SSH key management, Pi-hole DNS automation, and cloud-init configuration.

## Features

- **Zero-touch setup**: Config auto-bootstraps from a 1Password secure note on first import
- **Automated VM deployment**: Clone VMs from templates with customizable CPU, memory, and disk
- **Prereq validation**: Verifies template, folder, and cluster exist in vCenter before any side effects
- **1Password integration**: SSH key generation, vCenter credentials, sudo passwords - all in the vault
- **DNS management**: Automatic A record creation/removal via Pi-hole API (VRRP VIP aware)
- **SSH config sync**: Host blocks written to `~/.ssh/config` and the `homelab-infrastructure` repo simultaneously, with auto-commit and push
- **Infrastructure repo auto-discovery**: Finds the sibling `homelab-infrastructure` repo by matching GitHub owner - no hardcoded paths
- **Cloud-init support**: Automated OS configuration including user accounts, SSH keys, and static networking
- **Complete teardown**: `Remove-VMDeployment` removes DNS, SSH config, known_hosts, 1Password items, and the VM
- **Idempotent retries**: SSH key creation reuses existing 1Password items; DNS and SSH config skip if already present

## Requirements

- Windows PowerShell 5.1+
- [VMware PowerCLI](https://developer.vmware.com/powercli) (auto-installed if missing)
- [1Password CLI](https://developer.1password.com/docs/cli/) (`op`) in PATH
- 1Password SSH agent running
- Access to VMware vCenter and Pi-hole API

## Installation

```powershell
git clone https://github.com/vollminlab/VMDeployTools
git clone https://github.com/vollminlab/homelab-infrastructure  # sibling repo, same parent dir
```

Import the module. On first import, if `VMDeployTools.config.psd1` does not exist it is
automatically created from the `VMDeployTools Config` secure note in 1Password:

```powershell
Import-Module .\VMDeployTools\VMDeployTools.psd1
```

That's it. No manual config file editing required on a fresh machine.

### Manual config (fallback)

If you need to set up without 1Password access, copy the example and fill in your values:

```powershell
Copy-Item VMDeployTools.config.example.psd1 VMDeployTools.config.psd1
# Edit VMDeployTools.config.psd1
```

`VMDeployTools.config.psd1` is gitignored and never committed.

## Configuration

| Key | Description |
|-----|-------------|
| `VaultName` | 1Password vault name |
| `SvcTokenItemTitle` | 1Password item holding the service account token (field: `password`) |
| `VCenterCredItemTitle` | 1Password item holding vCenter credentials (fields: `username` / `password`) |
| `LocalMachineName` | Hostname of this machine - controls whether SSH config is mirrored to the remote share |
| `RemoteUserProfileShare` | UNC path to `.ssh` on a secondary admin machine for SSH config mirroring |
| `VCenterServer` | vCenter hostname or IP |
| `ClusterName` | VMware cluster name |
| `PreferredDatastores` | Shared datastore names preferred over local datastores for VM placement |
| `Domain` | Internal DNS domain appended to VM names (e.g. `vollminlab.com`) |
| `PiHoleServer` | Pi-hole API endpoint - use the VRRP/keepalived VIP if running HA Pi-hole |
| `PiHolePort` | Pi-hole Flask API port |

> **Note on `SshConfigRepoPath`**: This is no longer a config value. At module load time,
> `Find-SiblingRepo` automatically locates `homelab-infrastructure` by matching the GitHub
> owner from this repo's own remote URL. Both repos must be cloned in the same parent directory.

## Quick Start

### Deploy a VM

```powershell
Invoke-VMDeployment -VMName "webserver01" `
                    -TemplateName "Ubuntu-24.04-Template" `
                    -IPAddress "192.168.152.100" `
                    -VMFolder "Linux VMs" `
                    -CPU 4 -MemoryGB 8 -DiskGB 50 `
                    -PowerOn
```

What happens in order:

1. DNS conflict check (aborts if FQDN already resolves)
2. vCenter prereq validation - confirms template, folder, and cluster exist before touching anything
3. SSH keypair generated in 1Password (reuses existing key if present)
4. SSH config entry written to `~/.ssh/config` and the `homelab-infrastructure` repo; repo auto-committed and pushed
5. DNS A record added to Pi-hole
6. VM cloned from template with cloud-init payload (hostname, user, SSH key, static IP, sudo password)
7. CPU / memory / disk resized if specified
8. VM powered on

### Remove a VM

```powershell
Remove-VMDeployment -VMName "webserver01"
```

What happens:

1. DNS A record removed from Pi-hole
2. SSH public key, config entry, and known_hosts entries removed locally
3. Same cleanup on the remote SSH share (if accessible)
4. SSH config entry removed from `homelab-infrastructure` repo; repo auto-committed and pushed
5. SSH key and sudo password archived (not deleted) in 1Password
6. VM stopped and permanently removed from vCenter

### Preview with -WhatIf

```powershell
Invoke-VMDeployment -VMName "testvm" -TemplateName "Ubuntu-24.04-Template" `
    -IPAddress "192.168.152.100" -VMFolder "Linux VMs" -PowerOn -WhatIf

Remove-VMDeployment -VMName "testvm" -WhatIf
```

### Clear auth token after sensitive operations

```powershell
Invoke-VMDeployment -VMName "prodvm" -TemplateName "Ubuntu-24.04-Template" `
    -IPAddress "192.168.152.100" -VMFolder "Production" -PowerOn -ClearOpAuthToken
```

## Disaster Recovery

Full rebuild on a new machine:

```powershell
# 1. Install prerequisites: 1Password CLI, 1Password desktop (SSH agent)
# 2. Clone repos into the same parent directory
git clone https://github.com/vollminlab/VMDeployTools
git clone https://github.com/vollminlab/homelab-infrastructure

# 3. Import - config bootstraps from 1Password, infra repo is auto-discovered
Import-Module .\VMDeployTools\VMDeployTools.psd1

# 4. Copy SSH public keys from the infra repo to ~/.ssh/
Copy-Item homelab-infrastructure\hosts\windows\ssh\*.pub ~\.ssh\

# 5. Copy the SSH config
Copy-Item homelab-infrastructure\hosts\windows\ssh\config ~\.ssh\config
```

The `VMDeployTools Config` secure note in 1Password is the source of truth for all config values.
Update that note when infrastructure changes (e.g. new vCenter, new Pi-hole VIP).

## Authentication

The module uses lazy authentication - 1Password is only contacted when first needed, not at import.

- **Config bootstrap** (import time, one-time): Uses personal 1Password auth (biometric/desktop) to read the config note and write `VMDeployTools.config.psd1`
- **Runtime operations**: Use the service account token stored in the vault, fetched once per session and held in `$env:OP_SERVICE_ACCOUNT_TOKEN`

On a subsequent session after the config file exists, no auth prompt occurs at import - only when the first operation is invoked.

## Exported Functions

### Main Operations
| Function | Description |
|----------|-------------|
| `Invoke-VMDeployment` | Deploy a new VM with full automation |
| `Remove-VMDeployment` | Remove a VM and clean up all resources |

### DNS Management
| Function | Description |
|----------|-------------|
| `Add-DnsRecordToPiHole` | Add an A record to Pi-hole |
| `Remove-DnsRecordFromPiHole` | Remove an A record from Pi-hole |

### SSH
| Function | Description |
|----------|-------------|
| `New-1PSSHKeyForHost` | Generate or reuse an ed25519 SSH key in 1Password |
| `Add-SshConfigEntryLocal` | Add a Host block to one or more SSH config files |
| `Update-RemoteGladosSsh` | Mirror SSH public key and config to a remote share |

### vCenter
| Function | Description |
|----------|-------------|
| `Connect-ToVCenter` | Connect using credentials from 1Password |
| `Test-VMDeploymentPrerequisites` | Validate template, folder, and cluster exist |
| `Test-VMHostReadiness` | Verify cluster has connected, non-maintenance hosts |
| `Install-VirtualMachine` | Lower-level VM clone and configure function |

### 1Password
| Function | Description |
|----------|-------------|
| `Initialize-OpAuth` | Ensure service account token is active |
| `Clear-OpAuth` | Remove token from session |
| `Save-SudoPasswordTo1Password` | Store or update a VM's sudo password |

### Utilities
| Function | Description |
|----------|-------------|
| `Find-SiblingRepo` | Locate a sibling GitHub repo by owner matching |
| `Test-1PasswordSSHAgent` | Verify 1Password SSH agent pipe is present |

## Logging

All operations log to `.\logs\{VMName}.log`. The file is created automatically and appended on each run. Key milestones also print to the console.

```
[2026-04-05 21:52:15] Invoke-VMDeployment START Template=Ubuntu-Template,IP=192.168.152.3,Folder=Linux VMs,PowerOn=True
[2026-04-05 21:52:15] Validating vCenter prerequisites (template, folder, cluster)...
[2026-04-05 21:52:15] Loading VMware PowerCLI module...
[2026-04-05 21:52:15] Already connected to vCenter vcenter.vollminlab.com.
[2026-04-05 21:52:15] Checking template 'Ubuntu-Template'...
[2026-04-05 21:52:15] vCenter prerequisites validated.
[2026-04-05 21:52:40] New-VM succeeded
[2026-04-05 21:52:56] VM powered on
[2026-04-05 21:52:57] Invoke-VMDeployment COMPLETE
```

## Troubleshooting

### Config file missing on a new machine
Import the module - it will prompt for 1Password authentication and write the config automatically.
If `op` is not installed, copy `VMDeployTools.config.example.psd1` to `VMDeployTools.config.psd1` and fill in manually.

### homelab-infrastructure repo not found
```
WARNING: homelab-infrastructure repo not found as a sibling of this repo. SSH config will not be synced to the infrastructure repo.
```
Clone `homelab-infrastructure` into the same parent directory as `VMDeployTools`. Both must have the same GitHub owner in their remote URL.

### Template / folder not found
The module validates these before creating any resources and lists available options in the error:
```
Template 'Ubuntu-24.04-Template' not found in vCenter. Available templates: Ubuntu-22.04-Template, Windows-2022-Template
```

### Duplicate SSH keys in 1Password
If two items share the same name (e.g. from a failed retry), the module warns and uses the most recently updated one. Clean up duplicates manually:
```powershell
op item list --vault Homelab --categories "SSH Key" --format json | ConvertFrom-Json |
    Where-Object title -eq "hostname_id_ed25519"
# Then: op item delete <id> --vault Homelab
```

### Pi-hole DNS not updating
Verify the Pi-hole API is reachable at the configured VIP:
```powershell
Invoke-RestMethod -Uri "http://192.168.100.4:5001/" -Method Get
```
If unreachable, check that the keepalived VIP is active on one of the Pi-hole nodes.

### 1Password auth issues
```powershell
Clear-OpAuth
Initialize-OpAuth
```

### SSH agent not working
```powershell
Test-1PasswordSSHAgent
```

## License

MIT - see LICENSE file.
