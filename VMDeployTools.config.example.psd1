# VMDeployTools Configuration
# Copy this file to VMDeployTools.config.psd1 and fill in your values.
# VMDeployTools.config.psd1 is gitignored and will never be committed.
@{
    # -- 1Password --
    # Name of the 1Password vault containing all items below
    VaultName               = 'YourVaultName'

    # 1Password item title that holds your VMDeploy service account token (field: password)
    SvcTokenItemTitle       = 'YourServiceAccountTokenItem'

    # 1Password item title that holds your vCenter credentials (fields: username / password)
    VCenterCredItemTitle    = 'YourVCenterCredentialItem'

    # -- Local Machine --
    # Hostname of the machine that runs this module (used to decide whether to mirror SSH config remotely)
    LocalMachineName        = 'YourMachineName'

    # UNC path to the .ssh directory on the remote machine to mirror SSH config/keys to
    # Leave as empty string '' to disable remote SSH mirroring
    RemoteUserProfileShare  = '\\YourMachine\c$\Users\YourUsername\.ssh'

    # -- VMware --
    # vCenter server hostname or IP
    VCenterServer           = 'vcenter.yourdomain.local'

    # VMware cluster name
    ClusterName             = 'your-ESXi-Cluster'

    # Shared datastores preferred over local datastores during VM placement
    PreferredDatastores     = @('datastore1', 'datastore2')

    # -- DNS / Network --
    # Internal DNS domain (appended to VM names for FQDNs)
    Domain                  = 'yourdomain.local'

    # Pi-hole hostname or IP
    PiHoleServer            = 'pihole.yourdomain.local'

    # Pi-hole API port
    PiHolePort              = '5001'
}
