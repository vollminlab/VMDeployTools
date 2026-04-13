# VMDeployTools — Operations

## Deploying a VM

```powershell
Import-Module VMDeployTools

Invoke-VMDeployment `
    -VMName "myserver01" `
    -TemplateName "Ubuntu-24.04-Template" `
    -IPAddress "192.168.152.100" `
    -VMFolder "Linux VMs" `
    -CPU 2 -MemoryGB 4 -DiskGB 40 `
    -PowerOn `
    -ClearOpAuthToken
```

**What to expect:**
- DNS conflict check runs first — will abort if `myserver01.vollminlab.com` already resolves
- vCenter validation runs before SSH key creation — if the template doesn't exist, you get a clear error with available alternatives
- SSH key appears in 1Password as `myserver01_id_ed25519`
- Sudo password stored in 1Password as login item `myserver01`
- homelab-infrastructure repo gets a commit with the new SSH config entry
- VM powers on and cloud-init runs (allow ~2 min for first boot)

**First SSH connection:**
```powershell
# After VM powers on and cloud-init completes (~2 min)
ssh myserver01
# Uses the SSH config entry and 1Password SSH agent key automatically
```

## Removing a VM

```powershell
Remove-VMDeployment -VMName "myserver01" -ClearOpAuthToken
```

**What gets cleaned up:**
- DNS A record deleted from Pi-hole
- SSH config entry removed from `~/.ssh/config`
- known_hosts entry removed
- homelab-infrastructure repo SSH config entry removed and committed
- 1Password items archived (not deleted): `myserver01_id_ed25519`, `myserver01` login
- VM powered off and deleted from vCenter

**Note:** 1Password items are archived, not permanently deleted. Recover them via the 1Password web UI if needed.

## Available templates

```powershell
# List available VM templates in vCenter
Connect-ToVCenter
Get-Template | Select-Object Name
```

## Checking cluster readiness before a large deployment

```powershell
Test-VMHostReadiness -ClusterName "vollminlab-cluster"
```

Checks all ESXi hosts in the cluster for connectivity, resource availability, and datastore access. Run before batch deployments.

## Updating SSH config across all machines

If you're on a secondary admin machine (not GLaDOS), SSH public keys and config entries are mirrored to the GLaDOS share automatically during deployment. To manually trigger a mirror:

```powershell
Update-RemoteGladosSsh -VMName "myserver01"
```

## Retrieving VM credentials

```powershell
# SSH key (for manual use)
op read "op://Homelab/myserver01_id_ed25519/private key"

# Sudo password
op read "op://Homelab/myserver01/password"
```

## Rotating a VM's sudo password

```powershell
Save-SudoPasswordTo1Password -VMName "myserver01" -NewPassword (New-RandomPassword)
# Then SSH in and update with: sudo passwd vollmin
```

## Troubleshooting

**"Template not found" error:**
The error message lists all available templates. Check spelling and case — vCenter template names are case-sensitive.

**VM created but can't SSH:**
1. Check cloud-init completed: `ssh -i ~/.ssh/myserver01_id_ed25519 vollmin@<IP> "sudo cloud-init status"`
2. If cloud-init failed: `sudo cat /var/log/cloud-init-output.log`
3. Check DNS resolves: `nslookup myserver01.vollminlab.com`
4. Verify the SSH config entry exists: `grep -A5 "Host myserver01" ~/.ssh/config`

**VM deployed but SSH config not committed to homelab-infrastructure:**
```powershell
Invoke-SshConfigRepoCommit -VMName "myserver01"
```

**1Password SSH agent not running:**
```powershell
Test-1PasswordSSHAgent
```
If it returns false, open the 1Password desktop app and enable the SSH agent in Settings → Developer.

**Pi-hole DNS registration failed:**
DNS failure is non-fatal — the VM still deploys. Register manually:
```bash
cd ~/repos/vollminlab/pihole-flask-api
API_KEY=$(op read "op://Homelab/recordimporter-api-token/password")
curl -X POST -H "Authorization: Bearer $API_KEY" \
  http://192.168.100.2:5001/add-a-record \
  -d '{"domain":"myserver01.vollminlab.com","ip":"192.168.152.100"}'
curl -X POST -H "Authorization: Bearer $API_KEY" \
  http://192.168.100.3:5001/add-a-record \
  -d '{"domain":"myserver01.vollminlab.com","ip":"192.168.152.100"}'
```
