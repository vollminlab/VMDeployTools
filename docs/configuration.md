# VMDeployTools — Configuration

## Bootstrap (first run on a new machine)

Configuration auto-bootstraps from a 1Password secure note on first import. No manual config file editing required.

**1Password item required:** A secure note titled `"VMDeployTools Config"` in the Homelab vault with a field named `"credential"` containing the full config hashtable:

```powershell
@{
    VaultName               = 'Homelab'
    SvcTokenItemTitle       = 'VMDeployTools-ServiceAccount'   # 1P item with service account token
    VCenterCredItemTitle    = 'vCenter-Admin'                  # 1P item with vCenter credentials
    LocalMachineName        = 'GLaDOS'                         # Hostname that is primary admin machine
    RemoteUserProfileShare  = '\\GLaDOS\c$\Users\scott'       # UNC to primary admin's .ssh (optional)
    VCenterServer           = 'vcenter.vollminlab.com'
    ClusterName             = 'vollminlab-cluster'
    PreferredDatastores     = @('shared-datastore-1', 'shared-datastore-2')
    Domain                  = 'vollminlab.com'
    PiHoleServer            = '192.168.100.1'                  # VRRP VIP
    PiHolePort              = '5001'
}
```

On `Import-Module VMDeployTools`, the module fetches this note via the 1Password CLI and writes the config locally. Subsequent imports load from the local file.

## Config file location

After bootstrap, the config is saved to:
```
~\AppData\Local\VMDeployTools\VMDeployTools.config.psd1
```

**Never commit this file** — it contains resolved paths and vault references. The `.gitignore` excludes it.

## Key config values explained

| Key | Purpose |
|-----|---------|
| `VaultName` | 1Password vault to search for all homelab items |
| `SvcTokenItemTitle` | 1P item whose `credential` field holds the service account token for non-interactive CLI auth |
| `VCenterCredItemTitle` | 1P item with `username` and `password` fields for vCenter |
| `LocalMachineName` | If the current hostname matches this, SSH keys are NOT mirrored to the remote share (you're already on the primary machine) |
| `RemoteUserProfileShare` | UNC path to the primary admin machine's user profile — SSH public keys and config entries are mirrored here from secondary machines |
| `PreferredDatastores` | Ordered list of shared datastores — first with enough free space wins |
| `PiHoleServer` | The VRRP VIP, not pihole1 or pihole2 directly — ensures HA-aware DNS registration |

## Required 1Password items

| Item title | Fields needed | Purpose |
|-----------|--------------|---------|
| `VMDeployTools Config` | `credential` (secure note body) | Bootstrap config |
| `<SvcTokenItemTitle>` | `credential` | 1Password service account token for non-interactive auth |
| `<VCenterCredItemTitle>` | `username`, `password` | vCenter login |
| `Recordimporter` | `credential` | Pi-hole API bearer token |

## Authentication flow

```
Import-Module VMDeployTools
        │
        └──► First op call triggers Initialize-OpAuth
                    │
                    ├── Checks $env:OP_SERVICE_ACCOUNT_TOKEN
                    └── If not set, reads from 1P item <SvcTokenItemTitle>
                                │
                                └──► Sets $env:OP_SERVICE_ACCOUNT_TOKEN for session
```

Clear the token when done (especially on shared machines):
```powershell
Clear-OpAuth
# or use: Invoke-VMDeployment ... -ClearOpAuthToken
```

## Disaster recovery

If the local config file is lost:
```powershell
# Re-bootstrap from 1Password
Remove-Item ~\AppData\Local\VMDeployTools\VMDeployTools.config.psd1 -ErrorAction SilentlyContinue
Import-Module VMDeployTools -Force
# Module will re-fetch from 1Password and regenerate the local config
```
