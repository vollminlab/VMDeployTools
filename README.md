# VMDeployTools

PowerShell module for automated VM deployment in VMware vSphere with integrated 1Password SSH key management, DNS automation, and cloud-init configuration.

## Features

- **Automated VM Deployment**: Clone VMs from templates with customizable CPU, memory, and disk
- **1Password Integration**: 
  - SSH key generation and secure storage using 1Password SSH agent
  - Service account token management with lazy authentication
  - Automatic credential retrieval for vCenter and Pi-hole
- **DNS Management**: Automatic A record creation/removal in Pi-hole
- **Cloud-init Support**: Automated OS configuration with user accounts and SSH keys
- **Complete Cleanup**: Removes all traces including SSH configs, known_hosts, and 1Password items
- **Professional Logging**: Timestamped logs for each VM deployment
- **PowerShell Best Practices**: Full `-WhatIf` and `-Confirm` support

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- [VMware PowerCLI](https://developer.vmware.com/powercli) module
- [1Password CLI](https://developer.1password.com/docs/cli/) (`op`) installed and configured
- 1Password SSH agent running
- Access to:
  - VMware vCenter
  - Pi-hole API (for DNS management)
  - 1Password vault with appropriate service account

## Installation

1. Clone this repository:
   ```powershell
   git clone https://github.com/VollminLab/VMDeployTools.git
   cd VMDeployTools
   ```

2. Create your local configuration file:
   ```powershell
   Copy-Item VMDeployTools.config.example.psd1 VMDeployTools.config.psd1
   ```
   Then open `VMDeployTools.config.psd1` and fill in your values (see [Configuration](#configuration) below).

3. Import the module:
   ```powershell
   Import-Module .\VMDeployTools.psd1
   ```

4. (Optional) Set the service account token permanently to avoid authentication prompts:
   ```powershell
   $token = op item get "<SvcTokenItemTitle>" --vault "<VaultName>" --field password --reveal
   [Environment]::SetEnvironmentVariable('OP_SERVICE_ACCOUNT_TOKEN', $token, 'User')
   ```

## Configuration

Copy `VMDeployTools.config.example.psd1` to `VMDeployTools.config.psd1` and fill in your values.
This file is gitignored and will never be committed.

| Key | Description |
|-----|-------------|
| `VaultName` | 1Password vault name |
| `SvcTokenItemTitle` | 1Password item holding the service account token (field: `password`) |
| `VCenterCredItemTitle` | 1Password item holding vCenter credentials (fields: `username` / `password`) |
| `LocalMachineName` | Hostname of the machine running this module (used for SSH mirroring logic) |
| `RemoteUserProfileShare` | UNC path to the `.ssh` directory on a secondary machine to mirror SSH config/keys to |
| `VCenterServer` | vCenter hostname or IP |
| `ClusterName` | VMware cluster name |
| `PreferredDatastores` | Shared datastore names (preferred over local datastores for VM placement) |
| `Domain` | Internal DNS domain appended to VM names |
| `PiHoleServer` | Pi-hole hostname or IP |
| `PiHolePort` | Pi-hole API port |

## Quick Start

### Deploy a VM

```powershell
Invoke-VMDeployment -VMName "webserver01" `
                    -TemplateName "ubuntu-template" `
                    -IPAddress "10.0.0.100" `
                    -VMFolder "Production" `
                    -CPU 4 `
                    -MemoryGB 8 `
                    -DiskGB 50 `
                    -PowerOn
```

This will:
1. Generate an ed25519 SSH keypair in 1Password
2. Save the public key locally to `~/.ssh/webserver01_id_ed25519.pub`
3. Add SSH config entries (local and remote)
4. Connect to vCenter using credentials from 1Password
5. Create a DNS A record in Pi-hole
6. Clone VM from template with cloud-init configuration
7. Generate and store a random sudo password in 1Password
8. Configure CPU, memory, and disk resources
9. Power on the VM

### Remove a VM

```powershell
Remove-VMDeployment -VMName "webserver01"
```

This will:
1. Remove DNS A record from Pi-hole
2. Remove local SSH public key, config entry, and known_hosts entries
3. Remove remote SSH public key, config entry, and known_hosts entries
4. Archive (not delete) SSH key and sudo password in 1Password
5. Stop and remove VM from vCenter

### Preview Changes with -WhatIf

```powershell
Invoke-VMDeployment "testvm" -TemplateName "ubuntu-template" `
    -IPAddress "10.0.0.100" -VMFolder "Lab" `
    -CPU 2 -MemoryGB 4 -DiskGB 30 -PowerOn -WhatIf

Remove-VMDeployment "testvm" -WhatIf
```

### Security: Clear Auth Token After Operations

```powershell
Invoke-VMDeployment "prodvm" -TemplateName "ubuntu-template" `
    -IPAddress "10.0.0.100" -VMFolder "Production" `
    -CPU 4 -MemoryGB 8 -DiskGB 50 -PowerOn -ClearOpAuthToken
```

## Authentication

The module uses **lazy authentication** - it only authenticates to 1Password when you first use a function that needs it (not at module import).

1. **First operation**: You'll get one 1Password authentication prompt
2. **Subsequent operations**: The service account token persists for the session
3. **New session**: Re-authenticate once

The authentication token is stored in `$env:OP_SERVICE_ACCOUNT_TOKEN` for the current PowerShell session only.

## Exported Functions

### Main Operations
- `Invoke-VMDeployment` - Deploy a new VM with all automation
- `Remove-VMDeployment` - Remove VM and clean up all resources

### DNS Management
- `Add-DnsRecordToPiHole` - Add an A record to Pi-hole
- `Remove-DnsRecordFromPiHole` - Remove an A record from Pi-hole

### SSH Key Management  
- `New-1PSSHKeyForHost` - Generate SSH key in 1Password
- `Add-SshConfigEntryLocal` - Add SSH config entry locally
- `Update-RemoteGladosSsh` - Mirror SSH config to remote host

### 1Password
- `Initialize-OpAuth` - Manually trigger 1Password authentication
- `Clear-OpAuth` - Clear authentication token from session
- `Save-SudoPasswordTo1Password` - Store sudo password in 1Password

### Utilities
- `Connect-ToVCenter` - Connect to vCenter with 1Password credentials
- `Test-VMHostReadiness` - Verify cluster has available hosts
- `Test-1PasswordSSHAgent` - Check if 1Password SSH agent is running
- `Install-VirtualMachine` - Lower-level VM creation function

## Logging

All operations are logged to `.\logs\{VMName}.log` with timestamps. Each log file contains:
- Deployment start/completion timestamps
- DNS operations
- SSH key generation and configuration
- vCenter operations (VM creation, resource modifications)
- Cleanup operations

Example log output:
```
[2025-10-12 03:05:09] Invoke-VMDeployment START Template=ubuntu-template,IP=10.0.0.100,Folder=Linux VMs,PowerOn=True
[2025-10-12 03:05:09] Checking DNS for deploytest.yourdomain.local
[2025-10-12 03:05:14] Mirrored SSH pub + config to remote host
[2025-10-12 03:05:15] Added Pi-hole A record for deploytest.yourdomain.local -> 10.0.0.100
[2025-10-12 03:05:15] Install-VirtualMachine START
[2025-10-12 03:05:17] Created sudo credential in 1Password 'deploytest'
[2025-10-12 03:05:39] New-VM succeeded
[2025-10-12 03:05:48] Set CPU cores to 1
[2025-10-12 03:05:49] Set memory to 1GB
[2025-10-12 03:05:50] VM powered on
[2025-10-12 03:05:50] Install-VirtualMachine COMPLETE
[2025-10-12 03:05:50] Invoke-VMDeployment COMPLETE
```

## How It Works

### SSH Key Management with 1Password

1. SSH keys are generated directly in 1Password using `op item create --category "SSH Key" --ssh-generate-key ed25519`
2. The private key never touches disk - it stays securely in 1Password
3. The public key is saved locally to `~/.ssh/{hostname}_id_ed25519.pub`
4. SSH config entries point to the public key; the 1Password SSH agent provides the private key via Windows IPC
5. The agent automatically handles authentication when you SSH to the host

### Cloud-init Configuration

The module generates cloud-init `user-data` and `metadata` that:
- Sets the hostname and FQDN
- Creates a `vollmin` user with sudo privileges
- Configures the SSH public key for authentication
- Sets a random sudo password (retrievable from 1Password)
- Configures static IP networking

### vCenter Integration

- Automatically connects to vCenter using credentials from 1Password
- Handles self-signed certificates (configurable)
- Selects the best ESXi host based on available resources
- Injects cloud-init data via VMware guestinfo properties

## Security Features

- **No credentials in code**: All secrets retrieved from 1Password
- **Service account tokens**: Process-scoped only, never written to disk
- **SSH private keys**: Never stored locally, only in 1Password
- **Secure password handling**: SecureString conversion with proper memory cleanup
- **Optional token clearing**: Use `-ClearOpAuthToken` for compliance
- **Confirmation prompts**: Destructive operations require confirmation (High impact)

## Troubleshooting

### 1Password Authentication Issues

If you get repeated authentication prompts:
```powershell
# Clear the token and re-authenticate
Clear-OpAuth
Initialize-OpAuth
```

### SSH Agent Not Working

Verify the 1Password SSH agent is running:
```powershell
Test-1PasswordSSHAgent
```

Expected output:
```
1Password SSH agent is available at \\.\pipe\openssh-ssh-agent
```

### DNS Record Already Exists

The module checks for existing DNS records before deployment. If a record exists, the deployment will abort with an error. Remove the old record first:
```powershell
Remove-DnsRecordFromPiHole -Fqdn "hostname.yourdomain.local"
```

### VM Already Exists

If a VM with the same name exists, deployment will abort. Remove the old VM first:
```powershell
Remove-VMDeployment -VMName "hostname"
```

## Examples

### Deploy Multiple VMs

```powershell
Import-Module .\VMDeployTools.psd1

# Deploy web servers
1..3 | ForEach-Object {
    Invoke-VMDeployment -VMName "web0$_" `
                        -TemplateName "ubuntu-template" `
                        -IPAddress "10.0.0.10$_" `
                        -VMFolder "WebServers" `
                        -CPU 2 -MemoryGB 4 -DiskGB 30 -PowerOn
}
```

### Deploy with Confirmation

```powershell
# This will prompt for confirmation (ConfirmImpact='Medium')
Invoke-VMDeployment "prodvm" -TemplateName "ubuntu-template" `
    -IPAddress "10.0.0.100" -VMFolder "Production" `
    -CPU 8 -MemoryGB 16 -DiskGB 100 -PowerOn -Confirm
```

### Clean Removal with Token Clearing

```powershell
Remove-VMDeployment "webserver01" -ClearOpAuthToken -Verbose
```

## License

MIT License - See LICENSE file for details

## Author

Scott Vollmin - VollminLab

## Contributing

This is a personal homelab project, but suggestions and improvements are welcome via issues or pull requests.

---

**Note**: This module is designed for homelab use and includes configurations specific to the VollminLab environment. Modify the script settings to match your infrastructure before use.
