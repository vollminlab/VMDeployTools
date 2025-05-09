# VMDeployTools.psm1

# Global flag for console echo of logs
$Script:VerboseLogging = $false

function Write-LogEntry {
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Message
    )
    $logDir = "C:\modules\VMDeployTools\logs"
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $logFile = Join-Path $logDir "$VMName.log"
    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = ("[{0}] {1}" -f $timestamp, $Message)
    Add-Content -Path $logFile -Value $line
    if ($Script:VerboseLogging) { Write-Host $line }
}

function Set-OpSession {
    if (-not (Get-Command op -ErrorAction SilentlyContinue)) {
        Write-Error "1Password CLI not installed or not in PATH."
        exit 1
    }
    try {
        $whoami = op whoami
        if (-not $whoami) {
            Write-Host "Signing in to 1Password..."
            Invoke-Expression (& op signin)
        }
    } catch {
        Write-Host "Signing in to 1Password..."
        Invoke-Expression (& op signin)
    }
}

function Save-SudoPasswordTo1Password {
    param(
        [Parameter(Mandatory=$true)][string]$VMName,
        [Parameter(Mandatory=$true)][SecureString]$SecurePassword,
        [string]$Vault = 'homelab-vault'
    )
    # Ensure 1Password session
    Set-OpSession

    # Convert SecureString to plaintext
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
    try {
        $PlainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    try {
        op item create login `
            --vault $Vault `
            --title $VMName `
            --category login `
            username=vollmin `
            password=$PlainPassword `
            --tags Homelab
        Write-LogEntry -VMName $VMName -Message "Sudo password saved to 1Password item '$VMName'"
    } catch {
        Write-LogEntry -VMName $VMName -Message ("ERROR saving sudo password to 1Password: {0}" -f $_)
        throw
    }
}

function Connect-ToVCenter {
    param([switch]$WhatIf)
    if ($WhatIf) {
        Write-Host "[WhatIf] Would connect to vCenter"
        return
    }
    if (-not (Get-Module VMware.PowerCLI -ListAvailable)) {
        Install-Module -Name VMware.PowerCLI -Scope CurrentUser -Force
    }
    Import-Module VMware.PowerCLI -ErrorAction Stop
    if (-not ($global:DefaultVIServer) -or $global:DefaultVIServer.IsConnected -ne $true) {
        $cred = Get-Credential -Message "Enter vCenter credentials"
        $conn = Connect-VIServer -Server "vcenter.vollminlab.com" -Credential $cred
        if (-not $conn.IsConnected) {
            throw "Failed to connect to vCenter."
        }
    }
}

function New-RandomPassword {
    return ([System.Web.Security.Membership]::GeneratePassword(20, 3))
}

function ConvertTo-SHA512Crypt {
    [CmdletBinding()]
    param([SecureString]$Password)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    $saltBytes = New-Object byte[] 6
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($saltBytes)
    $salt = [Convert]::ToBase64String($saltBytes).TrimEnd('=') -replace '[^a-zA-Z0-9]'
    $hash = [Security.Cryptography.SHA512]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($plain))
    $hashText = [Convert]::ToBase64String($hash)
    return ('$6${0}${1}' -f $salt, $hashText)
}

function Get-PiHoleApiToken {
    Set-OpSession

    # Retrieve the token field from the 1Password item
    $token = op item get "recordimporter-api-token" `
        --vault "homelab-vault" `
        --field password `
        --format human-readable `
        --reveal

    if (-not $token) {
        throw "Failed to retrieve Pi-hole API token from 1Password"
    }
    return $token.Trim()
}

function Add-DnsRecordToPiHole {
    param(
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][string]$IPAddress,
        [switch]$WhatIf
    )
    $vm = $Domain.Split('.')[0]
    if ($WhatIf) {
        Write-Host "[WhatIf] Would add DNS A record for $Domain -> $IPAddress"
        return
    }
    Write-LogEntry -VMName $vm -Message ("Add-DnsRecord START {0}->{1}" -f $Domain, $IPAddress)
    $url   = "http://pihole1.vollminlab.com:5001/add-a-record"
    $token = Get-PiHoleApiToken
    $hdr   = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }
    $body  = @{ domain = $Domain; ip = $IPAddress } | ConvertTo-Json
    try {
        Invoke-RestMethod -Uri $url -Method Post -Headers $hdr -Body $body
        Write-LogEntry -VMName $vm -Message ("A record added for {0}->{1}" -f $Domain, $IPAddress)
    } catch {
        Write-LogEntry -VMName $vm -Message ("Add-DnsRecord ERROR: {0}" -f $_)
    }
    Write-LogEntry -VMName $vm -Message "Add-DnsRecord COMPLETE"
}

function Remove-DnsRecordFromPiHole {
    param(
        [Parameter(Mandatory)][string]$Domain,
        [switch]$WhatIf
    )

    $vm = $Domain.Split('.')[0]
    if ($WhatIf) {
        Write-Host "[WhatIf] Would remove DNS A record for $Domain"
        return
    }

    Write-LogEntry -VMName $vm -Message ("Remove-DnsRecord START {0}" -f $Domain)

    $url   = "http://pihole1.vollminlab.com:5001/delete-a-record"
    $token = Get-PiHoleApiToken
    $hdr   = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }
    $body  = @{ domain = $Domain } | ConvertTo-Json

    try {
        Invoke-RestMethod -Uri $url -Method Delete -Headers $hdr -Body $body
        Write-LogEntry -VMName $vm -Message ("A record deleted for {0}" -f $Domain)
    } catch {
        Write-LogEntry -VMName $vm -Message ("Remove-DnsRecord ERROR: {0}" -f $_)
    }

    Write-LogEntry -VMName $vm -Message "Remove-DnsRecord COMPLETE"
}

function New-SshKeyPair {
    param(
        [Parameter(Mandatory)][string]$KeyPath,
        [switch]$WhatIf,
        [ref]$Passphrase
    )
    $vm = [IO.Path]::GetFileNameWithoutExtension($KeyPath)
    if ($WhatIf) {
        Write-Host "[WhatIf] Would generate SSH key at $KeyPath"
        return
    }
    Write-LogEntry -VMName $vm -Message ("New-SshKeyPair START Path={0}" -f $KeyPath)
    $dir = Split-Path $KeyPath
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if (-not (Test-Path $KeyPath)) {
        $pw = New-RandomPassword
        $Passphrase.Value = $pw
        ssh-keygen -t rsa -b 2048 -f $KeyPath -N $pw -q
        Write-LogEntry -VMName $vm -Message ("SSH key generated, passphrase={0}" -f $pw)
    }
    Write-LogEntry -VMName $vm -Message "New-SshKeyPair COMPLETE"
}

function Add-SshConfigEntry {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$DnsName,
        [Parameter(Mandatory)][string]$KeyPath,
        [switch]$WhatIf
    )
    $conf = Join-Path $HOME '.ssh\config'
    if ($WhatIf) {
        Write-Host "[WhatIf] Would add SSH config for $HostName"
        return
    }
    Write-LogEntry -VMName $HostName -Message "Add-SshConfig START"
    if (-not (Test-Path $conf)) {
        New-Item -ItemType File -Path $conf -Force | Out-Null
    }
    if (-not (Select-String -Path $conf -Pattern "^Host\s+$HostName" -Quiet)) {
        $entry = @"
Host $HostName
    HostName $DnsName
    User vollmin
    IdentityFile $KeyPath
    IdentitiesOnly yes
"@
        Add-Content -Path $conf -Value $entry
        Write-LogEntry -VMName $HostName -Message "SSH config added"
    }
    Write-LogEntry -VMName $HostName -Message "Add-SshConfig COMPLETE"
}

function Install-VirtualMachine {
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Template,
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][string]$IPAddress,
        [Parameter(Mandatory)][string]$PublicKeyPath,
        [ref]$GuestPassword,
        [switch]$WhatIf,
        [switch]$PowerOn
    )
    if ($WhatIf) {
        Write-Host "[WhatIf] Would deploy VM $VMName"
        return
    }
    Write-LogEntry -VMName $VMName -Message "Install-VirtualMachine START"

    # 1) sudo password
    $guestPw = New-RandomPassword
    $GuestPassword.Value = $guestPw
    Save-SudoPasswordTo1Password -VMName $VMName -SecurePassword (ConvertTo-SecureString $guestPw -AsPlainText -Force)

    # 2) cloud-init
    $hashedPw = ConvertTo-SHA512Crypt -Password (ConvertTo-SecureString $guestPw -AsPlainText -Force)
    $publicKey = Get-Content $PublicKeyPath -Raw
    $userData = @"
#cloud-config
hostname: $VMName
fqdn: $VMName.vollminlab.com
manage_etc_hosts: true

users:
  - name: vollmin
    sudo: ALL=(ALL) ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: $hashedPw
    ssh_authorized_keys:
      - $publicKey

ssh_pwauth: false

chpasswd:
  list: |
    vollmin:$guestPw
  expire: false

write_files:
  - path: /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
    content: |
      network: {config: disabled}

  - path: /etc/netplan/50-cloud-init.yaml
    content: |
      network:
        version: 2
        ethernets:
          ens33:
            addresses:
              - $IPAddress/24
            nameservers:
              addresses:
                - 192.168.100.4
                - 192.168.100.3
            routes:
              - to: default
                via: 192.168.152.1

runcmd:
  - netplan apply
  - sed -i '/^search /c\search .' /etc/resolv.conf
  - echo "Netplan+DNS override applied" >> /var/log/cloud-init.log
"@
    Write-LogEntry -VMName $VMName -Message ("Built user-data payload, {0} bytes" -f $userData.Length)

    $userDataEncoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($userData))
    $metaData = "instance-id: $VMName`nlocal-hostname: $VMName"
    $metaDataEncoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($metaData))

    # 3) Create VM
    try {
        $templateObj   = Get-Template     -Name $Template   -ErrorAction Stop
        $folderObj     = Get-Folder       -Name $Folder     -ErrorAction Stop
        $clusterObj    = Get-Cluster      -Name "vollminlab-ESXi-Cluster" -ErrorAction Stop
        $poolObj       = Get-ResourcePool -Location $clusterObj | Where-Object Name -eq "Resources"
        $newVm         = New-VM           -Name $VMName -Template $templateObj -Location $folderObj -ResourcePool $poolObj -ErrorAction Stop
        Write-LogEntry -VMName $VMName -Message "New-VM succeeded"
    } catch {
        Write-LogEntry -VMName $VMName -Message ("New-VM FAILED: {0}" -f $_)
        throw
    }

    # 4) Inject advanced settings
    $settings = @(
        @{ Name = "guestinfo.userdata";           Value = $userDataEncoded },
        @{ Name = "guestinfo.userdata.encoding";  Value = "base64"       },
        @{ Name = "guestinfo.metadata";           Value = $metaDataEncoded },
        @{ Name = "guestinfo.metadata.encoding";  Value = "base64"       }
    )

    foreach ($s in $settings) {
        # Verbose-only “about to inject” message
        Write-Verbose ("Injecting advanced setting '{0}' (value length: {1})" -f $s.Name, $s.Value.Length)

        # Do the actual injection
        New-AdvancedSetting `
            -Entity  $newVm `
            -Name    $s.Name `
            -Value   $s.Value `
            -Confirm:$false `
            -Force

        # Single log entry in your file
        Write-LogEntry -VMName $VMName -Message ("Injected advanced setting '{0}'" -f $s.Name)
    }

    Write-LogEntry -VMName $VMName -Message "Cloud-init data injected"

    # 5) Power on
    if ($PowerOn) {
        Start-VM -VM $newVm -Confirm:$false | Out-Null
        Write-LogEntry -VMName $VMName -Message "VM powered on"
    }

    Write-LogEntry -VMName $VMName -Message "Install-VirtualMachine COMPLETE"
}

function Invoke-VMDeployment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$TemplateName,
        [Parameter(Mandatory)][string]$IPAddress,
        [Parameter(Mandatory)][string]$VMFolder,
        [switch]$WhatIf,
        [switch]$PowerOn
    )
    if ($PSBoundParameters.ContainsKey('Verbose')) { $Script:VerboseLogging = $true }

    $dns = "$VMName.vollminlab.com"
    if (-not $WhatIf) {
        Write-LogEntry -VMName $VMName -Message ("Invoke-VMDeployment START Template={0},IP={1},Folder={2},PowerOn={3}" -f $TemplateName, $IPAddress, $VMFolder, $PowerOn)
        Write-LogEntry -VMName $VMName -Message ("Checking DNS for {0}" -f "$VMName.vollminlab.com")
    }
    try { $existing = [System.Net.Dns]::GetHostAddresses($dns) | Select-Object -ExpandProperty IPAddressToString } catch { $existing = $null }
    if ($existing) {
        Write-LogEntry -VMName $VMName -Message ("DNS {0} resolves to {1}, aborting" -f $dns, $existing)
        Write-Error ("DNS {0} already resolves to {1}, aborting" -f $dns, $existing)
        return
    }
    Connect-ToVCenter    -WhatIf:$WhatIf
    Add-DnsRecordToPiHole -Domain $dns -IPAddress $IPAddress -WhatIf:$WhatIf
    New-SshKeyPair        -KeyPath "C:\.ssh\converted\$VMName`_id_rsa" -Passphrase ([ref]"") -WhatIf:$WhatIf
    Add-SshConfigEntry    -HostName $VMName -DnsName $dns -KeyPath "C:\.ssh\converted\$VMName`_id_rsa" -WhatIf:$WhatIf
    $pwRef = [ref]""
    Install-VirtualMachine `
        -VMName        $VMName `
        -Template      $TemplateName `
        -Folder        $VMFolder `
        -IPAddress     $IPAddress `
        -PublicKeyPath "C:\.ssh\converted\$VMName`_id_rsa.pub" `
        -GuestPassword $pwRef `
        -WhatIf:$WhatIf `
        -PowerOn:$PowerOn
    if (-not $WhatIf) {
        Write-LogEntry -VMName $VMName -Message "Invoke-VMDeployment COMPLETE"
    }
}

function Remove-VMDeployment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [switch]$WhatIf
    )

    if ($PSBoundParameters.ContainsKey('Verbose')) {
        $Script:VerboseLogging = $true
    }

    $domain     = "$VMName.vollminlab.com"
    $sshKeyPath = "C:\.ssh\converted\$VMName`_id_rsa"
    $sshConfig  = Join-Path $HOME '.ssh\config'
    $knownHosts = Join-Path $HOME '.ssh\known_hosts'

    if ($WhatIf) {
        Write-Host "[WhatIf] Would remove DNS record for $domain"
        Write-Host "[WhatIf] Would delete SSH key pair at $sshKeyPath and $sshKeyPath.pub"
        Write-Host "[WhatIf] Would remove SSH config entry for host $VMName in $sshConfig"
        Write-Host "[WhatIf] Would prune known_hosts entry for $domain in $knownHosts"
        Write-Host "[WhatIf] Would delete 1Password item '$VMName' from vault 'homelab-vault'"
        Write-Host "[WhatIf] Would connect to vCenter"
        Write-Host "[WhatIf] Would power off and remove VM '$VMName' from vCenter"
        return
    }

    Write-LogEntry -VMName $VMName -Message "Remove-VMDeployment START"

    # 1) Delete Pi-hole record
    Remove-DnsRecordFromPiHole -Domain $domain
    Write-LogEntry -VMName $VMName -Message "Deleted Pi-hole A record for $domain"

    # 2) Remove SSH keys
    if (Test-Path $sshKeyPath) {
        Remove-Item -Path $sshKeyPath -Force
        Write-LogEntry -VMName $VMName -Message "Deleted SSH private key $sshKeyPath"
    }
    if (Test-Path "$sshKeyPath.pub") {
        Remove-Item -Path "$sshKeyPath.pub" -Force
        Write-LogEntry -VMName $VMName -Message "Deleted SSH public key $sshKeyPath.pub"
    }

    # 3) Remove SSH config block
    if (Test-Path $sshConfig) {
        $lines    = Get-Content $sshConfig
        $filtered = @()
        $skipping = $false

        foreach ($line in $lines) {
            if ($line -match "^Host\s+$VMName") {
                $skipping = $true; continue
            }
            if ($skipping -and $line -match '^\s') {
                continue
            }
            $skipping = $false
            $filtered += $line
        }

        $filtered | Set-Content $sshConfig
        Write-LogEntry -VMName $VMName -Message "Removed SSH config entry for host $VMName"
    }

    # 4) Prune known_hosts entry if present
    if (Test-Path $knownHosts) {
        $allLines = Get-Content $knownHosts
        if ($allLines -match [regex]::Escape($domain)) {
            # Only call ssh-keygen if an entry existed
            ssh-keygen -R $domain -f $knownHosts 2>$null
            Write-LogEntry -VMName $VMName -Message "Pruned known_hosts entry for $domain"
        } else {
            Write-LogEntry -VMName $VMName -Message "No known_hosts entry for $domain. Skipping"
        }
    }

    # 5) Delete from 1Password
    Set-OpSession
    op item delete $VMName --vault homelab-vault
    Write-LogEntry -VMName $VMName -Message "Deleted 1Password item '$VMName'"

    # 6) Remove VM in vCenter (power off then delete)
    Connect-ToVCenter -WhatIf:$false
    $vmObj = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($vmObj) {
        Stop-VM   -VM $vmObj -Confirm:$false -ErrorAction SilentlyContinue
        Remove-VM -VM $vmObj -DeletePermanently -Confirm:$false
        Write-LogEntry -VMName $VMName -Message "VM $VMName removed from vCenter"
    } else {
        Write-LogEntry -VMName $VMName -Message "VM $VMName not found in vCenter"
    }

    Write-LogEntry -VMName $VMName -Message "Remove-VMDeployment COMPLETE"
}

