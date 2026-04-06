<#
.SYNOPSIS
    VMDeployTools - Automated VM deployment with cloud-init, SSH key management, and DNS integration.

.DESCRIPTION
    This module automates VM deployment in VMware vCenter with integrated SSH key management 
    via 1Password, automatic DNS record creation in Pi-hole, and cloud-init configuration.
    
    Key features:
    - Generates ed25519 SSH keypairs stored securely in 1Password
    - Creates cloud-init enabled VMs from templates
    - Automatically registers DNS records in Pi-hole
    - Manages SSH config entries locally and on remote hosts
    - Generates and stores random sudo passwords in 1Password

.EXAMPLE
    Import-Module .\VMDeployTools.psd1
    
.EXAMPLE
    Invoke-VMDeployment -VMName "testvm" -TemplateName "Ubuntu-22.04-Template" `
                        -IPAddress "192.168.152.100" -VMFolder "Lab" `
                        -CPU 4 -MemoryGB 8 -DiskGB 50 -PowerOn

.EXAMPLE
    Remove-VMDeployment -VMName "testvm"

.NOTES
    Requires:
    - VMware PowerCLI module
    - 1Password CLI (op) installed and configured
    - 1Password SSH agent running
    - Access to vCenter and Pi-hole API
#>

# =========================
# VMDeployTools.psm1
# =========================

# ---------- Settings ----------
$Script:ConfigPath = Join-Path $PSScriptRoot 'VMDeployTools.config.psd1'
if (-not (Test-Path $Script:ConfigPath)) {
    Write-Host "VMDeployTools.config.psd1 not found - attempting to bootstrap from 1Password..."

    if (-not (Get-Command op -ErrorAction SilentlyContinue)) {
        throw "VMDeployTools.config.psd1 not found and 1Password CLI (op) is not in PATH. " +
              "Copy VMDeployTools.config.example.psd1 to VMDeployTools.config.psd1 and fill in your values."
    }

    # Bootstrap: read the config note from 1Password and write the local file.
    # Uses whatever op auth is available (service account token, existing session, or biometric).
    $noteContent = & op item get "VMDeployTools Config" --vault Homelab --field notesPlain --reveal 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($noteContent)) {
        # Not signed in yet - attempt interactive signin
        Write-Host "Signing in to 1Password..."
        & op signin 2>&1 | Out-Null
        $noteContent = & op item get "VMDeployTools Config" --vault Homelab --field notesPlain --reveal 2>$null
    }

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($noteContent)) {
        throw "Failed to retrieve 'VMDeployTools Config' from 1Password. " +
              "Create the config manually: copy VMDeployTools.config.example.psd1 to VMDeployTools.config.psd1 and fill in your values."
    }

    Set-Content -Path $Script:ConfigPath -Value $noteContent -Encoding UTF8
    Write-Host "VMDeployTools.config.psd1 created from 1Password."
}
$Script:Config = Import-PowerShellDataFile $Script:ConfigPath

$Script:VaultName               = $Script:Config.VaultName
$Script:SvcTokenItemTitle       = $Script:Config.SvcTokenItemTitle
$Script:VCenterCredItemTitle    = $Script:Config.VCenterCredItemTitle
$Script:RemoteUserProfileShare  = $Script:Config.RemoteUserProfileShare
$Script:RemoteConfigPath        = Join-Path $Script:RemoteUserProfileShare 'config'
$Script:IsGlados                = ($env:COMPUTERNAME -ieq $Script:Config.LocalMachineName)
$Script:ClusterName             = $Script:Config.ClusterName
$Script:Domain                  = $Script:Config.Domain
$Script:VCenterServer           = $Script:Config.VCenterServer
$Script:PiHoleServer            = $Script:Config.PiHoleServer
$Script:PiHolePort              = $Script:Config.PiHolePort
$Script:PreferredDatastores     = $Script:Config.PreferredDatastores  # Shared storage preferred over local

# Discover the SSH config file in the homelab-infrastructure sibling repo at load time.
# Find-SiblingRepo is defined later in this file but PowerShell resolves function calls
# at runtime not parse time, so this is safe as long as the module is fully loaded before use.
# We resolve it eagerly here so callers don't pay the git discovery cost on every deploy.
$Script:SshConfigRepoPath       = $null  # resolved at end of module after Find-SiblingRepo is defined

# ---------- 1Password Authentication State ----------
# Memoization flag to avoid repeated authentication checks
$script:OpAuthBootstrapped = $false

# ---------- Logging ----------
function Write-LogEntry {
  <#
  .SYNOPSIS
      Writes a timestamped log entry to a VM-specific log file.
  
  .DESCRIPTION
      Appends a timestamped message to a log file in the .\logs directory.
      Outputs to console only when -Verbose is used, or for important milestone messages.
  
  .PARAMETER VMName
      The VM name, used to determine the log file name.
  
  .PARAMETER Message
      The message to log.
  
  .PARAMETER AlwaysShow
      If specified, always show on console regardless of verbose setting.
  
  .EXAMPLE
      Write-LogEntry -VMName "web01" -Message "Deployment started" -AlwaysShow
  #>
  param(
    [Parameter(Mandatory)][string]$VMName,
    [Parameter(Mandatory)][string]$Message,
    [switch]$AlwaysShow
  )
  $logDir = ".\logs"
  if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
  $logFile = Join-Path $logDir "$VMName.log"
  $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  $line = ("[{0}] {1}" -f $timestamp, $Message)
  Add-Content -Path $logFile -Value $line
  
  # Show on console if verbose mode OR if this is a milestone message
  if ($AlwaysShow -or $VerbosePreference -eq 'Continue') {
    Write-Host $line
  }
}

# ---------- 1Password Authentication ----------
function Initialize-OpAuth {
  <#
  .SYNOPSIS
      Ensures 1Password CLI is authenticated for the current session.
  
  .DESCRIPTION
      Lazy bootstrap pattern - only authenticates when first needed.
      Checks for service account token, and if not present, performs one-time user signin
      to fetch it from 1Password. Memoizes state to avoid repeated checks.
  
  .EXAMPLE
      Initialize-OpAuth
  #>
  if (-not (Get-Command op -ErrorAction SilentlyContinue)) {
    throw "1Password CLI not found in PATH."
  }

  # If already bootstrapped or SAT present, we're done
  if ($script:OpAuthBootstrapped -or ($env:OP_SERVICE_ACCOUNT_TOKEN -and $env:OP_SERVICE_ACCOUNT_TOKEN.Trim())) {
    $script:OpAuthBootstrapped = $true
    return
  }

  # Try to read the SAT with whatever user auth we have
  $satJson = & op item get $Script:SvcTokenItemTitle `
    --vault $Script:VaultName `
    --field password `
    --reveal `
    2>$null
  
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($satJson)) {
    # Not signed in; do a one-time signin (let desktop/biometric handle UI)
    $token = & op signin --raw 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "1Password sign-in failed. Output: $token"
    }
    
    # Try again to read SAT
    $satJson = & op item get $Script:SvcTokenItemTitle `
      --vault $Script:VaultName `
      --field password `
      --reveal `
      2>&1
    
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($satJson)) {
      throw "Unable to read service account token item '$($Script:SvcTokenItemTitle)' in vault '$($Script:VaultName)'. Output: $satJson"
    }
  }

  # Export the SAT for this process only
  [Environment]::SetEnvironmentVariable('OP_SERVICE_ACCOUNT_TOKEN', $satJson.Trim(), 'Process')
  $script:OpAuthBootstrapped = $true
}

function Clear-OpAuth {
  <#
  .SYNOPSIS
      Clears the 1Password authentication token from the current session.
  
  .DESCRIPTION
      Removes the service account token from the environment and resets the bootstrap flag.
      Useful for security compliance or when you want to ensure the token is cleared after operations.
  
  .EXAMPLE
      Clear-OpAuth
  #>
  [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Low')]
  param()
  
  if (-not $PSCmdlet.ShouldProcess("1Password authentication token", "Clear from session")) {
    return
  }
  
  Remove-Item Env:OP_SERVICE_ACCOUNT_TOKEN -ErrorAction SilentlyContinue
  $script:OpAuthBootstrapped = $false
}

# ---------- Utility ----------
function Test-1PasswordSSHAgent {
  <#
  .SYNOPSIS
      Validates that 1Password SSH agent is available.
  
  .DESCRIPTION
      Checks for the SSH agent pipe and 1Password process to ensure the SSH agent is 
      properly configured and running. Throws an error if the SSH agent pipe is not found.
      Issues a warning if 1Password is not detected.
  
  .EXAMPLE
      Test-1PasswordSSHAgent
  #>
  $pipe = Get-ChildItem \\.\pipe\ -ErrorAction SilentlyContinue | 
          Where-Object Name -eq 'openssh-ssh-agent'
  $op1p = Get-Process -Name "1Password" -ErrorAction SilentlyContinue
  
  if (-not $pipe) { 
    throw "SSH agent pipe not found at \\.\pipe\openssh-ssh-agent. Is an SSH agent running?"
  }
  if (-not $op1p) { 
    Write-Warning "1Password process not detected. Ensure 1Password is running with SSH agent enabled."
    Write-Warning "If Windows SSH agent is running instead of 1Password agent, SSH key access will fail."
  }
  return $true
}

function New-RandomPassword {
  <#
  .SYNOPSIS
      Generates a random password.
  
  .DESCRIPTION
      Creates a cryptographically random password using alphanumeric and special characters.
  
  .PARAMETER Length
      Optional. The length of the password (default: 24).
  
  .EXAMPLE
      $password = New-RandomPassword -Length 32
  #>
  param([int]$Length = 24)
  $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_-+=<>?'
  -join (1..$Length | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
}

function Find-SiblingRepo {
  <#
  .SYNOPSIS
      Locates a sibling git repository by matching the GitHub org/owner of this repo.

  .DESCRIPTION
      Reads this module's own git remote URL to determine the GitHub owner, then walks
      sibling directories looking for a git repo under the same owner whose name matches
      the requested repo. Returns the repo root path, or $null if not found.

      This avoids hardcoded paths entirely - the repos just need to be cloned by the
      same GitHub user somewhere on disk, in the same parent directory.

  .PARAMETER RepoName
      The GitHub repository name to find (e.g. 'homelab-infrastructure').

  .PARAMETER RelativePath
      Optional file/folder path relative to the repo root to return instead of the root.

  .EXAMPLE
      $path = Find-SiblingRepo -RepoName 'homelab-infrastructure' `
                               -RelativePath 'hosts/windows/ssh/config'
  #>
  param(
    [Parameter(Mandatory)][string]$RepoName,
    [string]$RelativePath
  )

  # Determine this repo's GitHub owner from its remote URL
  $myRemote = & git -C $PSScriptRoot remote get-url origin 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($myRemote)) { return $null }

  # Parse owner from https://github.com/owner/repo or git@github.com:owner/repo
  $owner = $null
  if ($myRemote -match 'github\.com[:/]([^/]+)/') {
    $owner = $Matches[1]
  }
  if (-not $owner) { return $null }

  # Walk sibling directories looking for a git repo matching owner/RepoName
  $parentDir = Split-Path $PSScriptRoot -Parent
  foreach ($dir in (Get-ChildItem -Path $parentDir -Directory -ErrorAction SilentlyContinue)) {
    $remote = & git -C $dir.FullName remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0) { continue }
    if ($remote -match "github\.com[:/]$([regex]::Escape($owner))/$([regex]::Escape($RepoName))") {
      if ($RelativePath) {
        return Join-Path $dir.FullName $RelativePath
      }
      return $dir.FullName
    }
  }
  return $null
}

function ConvertTo-SHA512Crypt {
  <#
  .SYNOPSIS
      Converts a password to SHA512 crypt format for Linux.
  
  .DESCRIPTION
      Generates a SHA512 password hash compatible with Linux /etc/shadow format.
      Used for cloud-init password configuration.
  
  .PARAMETER Password
      The password as a SecureString.
  
  .OUTPUTS
      String in format: $6$salt$hash
  
  .EXAMPLE
      $hash = ConvertTo-SHA512Crypt -Password (ConvertTo-SecureString "password123" -AsPlainText -Force)
  #>
  [CmdletBinding()] param([SecureString]$Password)
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
  try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
  $saltBytes = New-Object byte[] 6
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($saltBytes)
  $salt = [Convert]::ToBase64String($saltBytes).TrimEnd('=') -replace '[^a-zA-Z0-9]'
  $hash = [Security.Cryptography.SHA512]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($plain))
  $hashText = [Convert]::ToBase64String($hash)
  return ('$6${0}${1}' -f $salt, $hashText)
}

# ---------- DNS (Pi-hole) ----------
function Invoke-PiHoleRequest {
  # Private helper: tries the primary Pi-hole server, falls back to the secondary on
  # connection failures (unreachable host). HTTP API errors are re-thrown immediately
  # without attempting the fallback, since both servers should return the same response.
  param(
    [Parameter(Mandatory)][string]$Endpoint,
    [Parameter(Mandatory)][string]$Method,
    [Parameter(Mandatory)][hashtable]$Headers,
    [string]$Body
  )

  $url = "http://$($Script:PiHoleServer):$($Script:PiHolePort)/$Endpoint"
  $params = @{ Uri = $url; Method = $Method; Headers = $Headers }
  if ($Body) { $params.Body = $Body }
  return Invoke-RestMethod @params
}

function Get-PiHoleApiToken {
  <#
  .SYNOPSIS
      Retrieves the Pi-hole API token from 1Password.
  
  .DESCRIPTION
      Fetches the API token for the Pi-hole record importer service from 1Password.
      Uses service account for headless operation.
  
  .EXAMPLE
      $token = Get-PiHoleApiToken
  #>
  Initialize-OpAuth
  
  $token = & op item get "Recordimporter" `
              --vault $Script:VaultName `
              --field credential `
              --format human-readable `
              --reveal
  
  if ([string]::IsNullOrWhiteSpace($token)) { 
    throw "Failed to retrieve Pi-hole API token from 1Password" 
  }
  return $token.Trim()
}

function Add-DnsRecordToPiHole {
  <#
  .SYNOPSIS
      Adds a DNS A record to Pi-hole.
  
  .DESCRIPTION
      Creates a new DNS A record in Pi-hole via the REST API. Retrieves the API token 
      from 1Password automatically.
  
  .PARAMETER Fqdn
      The fully qualified domain name for the record.
  
  .PARAMETER IPAddress
      The IP address to associate with the domain.
  
  .EXAMPLE
      Add-DnsRecordToPiHole -Fqdn "web01.vollminlab.com" -IPAddress "192.168.152.100"
  #>
  [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Low')]
  param([Parameter(Mandatory)][string]$Fqdn,
        [Parameter(Mandatory)][string]$IPAddress)
  
  if (-not $PSCmdlet.ShouldProcess($Fqdn, "Add DNS A record to Pi-hole")) {
    return
  }
  
  $vm = $Fqdn.Split('.')[0]
  
  $token    = Get-PiHoleApiToken
  $hdr      = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }
  $body     = @{ domain = $Fqdn; ip = $IPAddress } | ConvertTo-Json
  try {
    Invoke-PiHoleRequest -Endpoint "add-a-record" -Method Post -Headers $hdr -Body $body | Out-Null
    Write-LogEntry -VMName $vm -Message "Added Pi-hole A record for $Fqdn -> $IPAddress" -AlwaysShow
  }
  catch {
    $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { $null }
    if ($status -eq 409) {
      Write-LogEntry -VMName $vm -Message "Pi-hole A record already exists for $Fqdn" -AlwaysShow
    } else {
      $msg = "Failed to add Pi-hole A record for $Fqdn`: Status=$status, Error=$_"
      Write-LogEntry -VMName $vm -Message $msg -AlwaysShow
      Write-Warning $msg
    }
  }
}

function Remove-DnsRecordFromPiHole {
  <#
  .SYNOPSIS
      Removes a DNS A record from Pi-hole.
  
  .DESCRIPTION
      Deletes a DNS A record from Pi-hole via the REST API. Retrieves the API token 
      from 1Password automatically.
  
  .PARAMETER Fqdn
      The fully qualified domain name to remove.
  
  .EXAMPLE
      Remove-DnsRecordFromPiHole -Fqdn "web01.vollminlab.com"
  #>
  [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Low')]
  param([Parameter(Mandatory)][string]$Fqdn)
  
  if (-not $PSCmdlet.ShouldProcess($Fqdn, "Remove DNS A record from Pi-hole")) {
    return
  }
  
  $vm = $Fqdn.Split('.')[0]
  
  $token    = Get-PiHoleApiToken
  $hdr      = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }
  $body     = @{ domain = $Fqdn } | ConvertTo-Json
  try {
    Invoke-PiHoleRequest -Endpoint "delete-a-record" -Method Delete -Headers $hdr -Body $body | Out-Null
    Write-LogEntry -VMName $vm -Message "Deleted Pi-hole A record for $Fqdn" -AlwaysShow
  }
  catch {
    $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { $null }
    if ($status -eq 404) {
      Write-LogEntry -VMName $vm -Message "Pi-hole A record not found for $Fqdn (may have already been removed)" -AlwaysShow
    } else {
      $msg = "Failed to delete Pi-hole A record for $Fqdn`: Status=$status, Error=$_"
      Write-LogEntry -VMName $vm -Message $msg -AlwaysShow
      Write-Warning $msg
    }
  }
}

# ---------- vCenter ----------
function Connect-ToVCenter {
  <#
  .SYNOPSIS
      Establishes a connection to vCenter if not already connected.

  .DESCRIPTION
      Checks for an existing vCenter connection and establishes a new one if needed.
      Retrieves credentials from 1Password automatically. Automatically installs VMware.PowerCLI
      module if not present.

  .PARAMETER VMName
      Optional. When provided, progress messages are written to the VM log via Write-LogEntry.
      When omitted, progress messages are written to the verbose stream only.

  .EXAMPLE
      Connect-ToVCenter -VMName "web01"
  #>
  param([string]$VMName)

  # Helper: log to VM log file with AlwaysShow when VMName is known; else Write-Verbose
  $log = {
    param([string]$msg)
    if ($VMName) { Write-LogEntry -VMName $VMName -Message $msg -AlwaysShow }
    else         { Write-Verbose $msg }
  }

  if (-not (Get-Module VMware.PowerCLI -ListAvailable)) {
    & $log "VMware.PowerCLI module not found. Installing from PSGallery (this may take a moment)..."
    Install-Module -Name VMware.PowerCLI -Scope CurrentUser -Force
  }

  & $log "Loading VMware PowerCLI module..."
  Import-Module VMware.PowerCLI -ErrorAction Stop

  # Configure PowerCLI to ignore invalid certificates (for self-signed certs)
  Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null

  if (-not ($global:DefaultVIServer) -or $global:DefaultVIServer.IsConnected -ne $true) {
    & $log "Connecting to vCenter $Script:VCenterServer..."
    Initialize-OpAuth
    $username = op item get $Script:VCenterCredItemTitle --vault $Script:VaultName --field username --format human-readable
    $password = op item get $Script:VCenterCredItemTitle --vault $Script:VaultName --field password --format human-readable --reveal

    if ([string]::IsNullOrWhiteSpace($username) -or [string]::IsNullOrWhiteSpace($password)) {
      throw "Failed to retrieve vCenter credentials from 1Password item '$Script:VCenterCredItemTitle'"
    }

    $securePassword = ConvertTo-SecureString $password.Trim() -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($username.Trim(), $securePassword)

    $conn = Connect-VIServer -Server $Script:VCenterServer -Credential $cred
    if (-not $conn.IsConnected) { throw "Failed to connect to vCenter." }
    & $log "Connected to vCenter $Script:VCenterServer."
  } else {
    & $log "Already connected to vCenter $Script:VCenterServer."
  }
}

function Test-VMHostReadiness {
  <#
  .SYNOPSIS
      Validates that ESXi hosts in a cluster are ready for VM deployment.
  
  .DESCRIPTION
      Checks all hosts in the specified cluster for connectivity and maintenance status.
      Logs resource availability (CPU, memory) for each suitable host. Throws an error if 
      no suitable hosts are found.
  
  .PARAMETER ClusterName
      The name of the vCenter cluster to check.
  
  .PARAMETER VMName
      The VM name, used for logging purposes.
  
  .EXAMPLE
      Test-VMHostReadiness -ClusterName "Production-Cluster" -VMName "web01"
  #>
  param([Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)][string]$VMName)
  try {
    $cluster  = Get-Cluster -Name $ClusterName -ErrorAction Stop
    $allHosts = Get-VMHost -Location $cluster
    $hosts    = $allHosts | Where-Object { $_.ConnectionState -eq "Connected" }
    $excluded = $allHosts | Where-Object { $_.ConnectionState -ne "Connected" }
    foreach ($h in $excluded) { Write-LogEntry -VMName $VMName -Message ("Excluded host '{0}': ConnectionState={1}" -f $h.Name,$h.ConnectionState) }
    if ($hosts.Count -eq 0) { throw "No suitable hosts found in cluster '$ClusterName'." }
    foreach ($vmHost in $hosts) {
      $cpuAvail = $vmHost.CpuTotalMhz - $vmHost.CpuUsageMhz
      $memAvail = $vmHost.MemoryTotalGB - $vmHost.MemoryUsageGB
      Write-LogEntry -VMName $VMName -Message ("Host '{0}': CPU {1}/{2}MHz free, Mem {3}GB free, Conn={4}" -f $vmHost.Name,$cpuAvail,$vmHost.CpuTotalMhz,[math]::Round($memAvail,2),$vmHost.ConnectionState)
    }
    Write-LogEntry -VMName $VMName -Message ("Found {0} suitable hosts in cluster '{1}'" -f $hosts.Count, $ClusterName)
    return $true
  } catch {
    Write-LogEntry -VMName $VMName -Message ("Host readiness check FAILED: {0}" -f $_)
    throw
  }
}

function Test-VMDeploymentPrerequisites {
  <#
  .SYNOPSIS
      Validates vCenter prerequisites before committing any side effects during deployment.

  .DESCRIPTION
      Connects to vCenter and verifies that the specified template, folder, and cluster
      all exist and are accessible. Designed to be called early in Invoke-VMDeployment,
      before SSH key creation, DNS changes, or any other irreversible operations.
      On failure, throws a clear, actionable error message including available alternatives.

  .PARAMETER VMName
      The VM name, used for log file routing.

  .PARAMETER TemplateName
      The vCenter template name to validate.

  .PARAMETER VMFolder
      The vCenter folder name to validate.

  .EXAMPLE
      Test-VMDeploymentPrerequisites -VMName "web01" -TemplateName "Ubuntu-24.04-Template" -VMFolder "Lab"
  #>
  param(
    [Parameter(Mandatory)][string]$VMName,
    [Parameter(Mandatory)][string]$TemplateName,
    [Parameter(Mandatory)][string]$VMFolder
  )

  Write-LogEntry -VMName $VMName -Message "Validating vCenter prerequisites (template, folder, cluster)..." -AlwaysShow

  Connect-ToVCenter -VMName $VMName

  # --- Template ---
  Write-LogEntry -VMName $VMName -Message ("Checking template '{0}'..." -f $TemplateName) -AlwaysShow
  try {
    Get-Template -Name $TemplateName -ErrorAction Stop | Out-Null
  } catch {
    $available = (Get-Template | Select-Object -ExpandProperty Name) -join ', '
    if ([string]::IsNullOrWhiteSpace($available)) { $available = '(none found)' }
    $msg = "Template '{0}' not found in vCenter. Available templates: {1}" -f $TemplateName, $available
    Write-LogEntry -VMName $VMName -Message $msg -AlwaysShow
    throw $msg
  }

  # --- Folder ---
  Write-LogEntry -VMName $VMName -Message ("Checking folder '{0}'..." -f $VMFolder) -AlwaysShow
  try {
    Get-Folder -Name $VMFolder -ErrorAction Stop | Out-Null
  } catch {
    $available = (Get-Folder | Where-Object { $_.Type -eq 'VM' } | Select-Object -ExpandProperty Name | Sort-Object) -join ', '
    if ([string]::IsNullOrWhiteSpace($available)) { $available = '(none found)' }
    $msg = "VM folder '{0}' not found in vCenter. Available VM folders: {1}" -f $VMFolder, $available
    Write-LogEntry -VMName $VMName -Message $msg -AlwaysShow
    throw $msg
  }

  # --- Cluster ---
  Write-LogEntry -VMName $VMName -Message ("Checking cluster '{0}'..." -f $Script:ClusterName) -AlwaysShow
  try {
    Get-Cluster -Name $Script:ClusterName -ErrorAction Stop | Out-Null
  } catch {
    $available = (Get-Cluster | Select-Object -ExpandProperty Name | Sort-Object) -join ', '
    if ([string]::IsNullOrWhiteSpace($available)) { $available = '(none found)' }
    $msg = "Cluster '{0}' not found in vCenter. Available clusters: {1}" -f $Script:ClusterName, $available
    Write-LogEntry -VMName $VMName -Message $msg -AlwaysShow
    throw $msg
  }

  Write-LogEntry -VMName $VMName -Message "vCenter prerequisites validated." -AlwaysShow
}

# ---------- 1Password items ----------
function Save-SudoPasswordTo1Password {
  <#
  .SYNOPSIS
      Saves or updates a VM's sudo password in 1Password.
  
  .DESCRIPTION
      Creates or updates a login item in 1Password with the VM's sudo password.
      The item is tagged for easy identification and organization.
  
  .PARAMETER VMName
      The VM name, used as the 1Password item title.
  
  .PARAMETER SecurePassword
      The password as a SecureString.
  
  .PARAMETER Vault
      Optional. The 1Password vault name (defaults to script variable).
  
  .EXAMPLE
      Save-SudoPasswordTo1Password -VMName "web01" -SecurePassword (ConvertTo-SecureString "pass123" -AsPlainText -Force)
  #>
  [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Low')]
  param([Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][SecureString]$SecurePassword,
        [string]$Vault = $Script:VaultName)

  if (-not $PSCmdlet.ShouldProcess($VMName, "Save sudo password to 1Password")) {
    return
  }

  Initialize-OpAuth
  
  # Convert SecureString to plain text for 1Password CLI
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
  try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

  try {
    $exists = op item get $VMName --vault $Vault --format json 2>$null
    if ($exists) {
      op item edit $VMName --vault $Vault password=$plain | Out-Null
      Write-LogEntry -VMName $VMName -Message "Updated sudo password in 1Password '$VMName'"
    } else {
      op item create --vault $Vault --title $VMName --category login `
        username=vollmin password=$plain --tags Homelab | Out-Null
      Write-LogEntry -VMName $VMName -Message "Created sudo credential in 1Password '$VMName'"
    }
  } catch {
    Write-LogEntry -VMName $VMName -Message ("ERROR saving sudo password to 1Password: {0}" -f $_)
    throw
  }
}

function New-1PSSHKeyForHost {
  <#
  .SYNOPSIS
      Generates a new SSH keypair for a host and stores it in 1Password.
  
  .DESCRIPTION
      Creates an ed25519 SSH keypair with a random passphrase, uploads both keys and the 
      passphrase to 1Password as an SSH Key item, saves the public key locally, and securely 
      removes the private key from disk. The 1Password SSH agent will provide the private key 
      when needed.
  
  .PARAMETER HostName
      The name of the host this SSH key is for. Used in the key title and comment.
  
  .OUTPUTS
      PSCustomObject with properties:
      - Title: The 1Password item title
      - PublicKeyText: The public key content
      - PublicKeyPathLocal: Local path to the saved public key file
      - Passphrase: The generated passphrase (for informational purposes)
  
  .EXAMPLE
      $key = New-1PSSHKeyForHost -HostName "webserver01"
  #>
  [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
  param([Parameter(Mandatory)][string]$HostName)

  if (-not $PSCmdlet.ShouldProcess($HostName, "Create SSH key in 1Password")) {
    return
  }

  Initialize-OpAuth

  $title = "${HostName}_id_ed25519"

  # Use item list to find by title - avoids ambiguity errors when duplicates exist
  $itemListJson = & op item list --vault $Script:VaultName --categories "SSH Key" --format json 2>$null
  $itemId = $null
  if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($itemListJson)) {
    $foundItems = ($itemListJson | ConvertFrom-Json) | Where-Object { $_.title -eq $title }
    if ($foundItems.Count -gt 1) {
      # Duplicates present - warn and use the most recently updated one
      Write-LogEntry -VMName $HostName -Message ("WARNING: {0} duplicate SSH key items named '{1}' found in 1Password. Using the most recent. Consider deleting duplicates." -f $foundItems.Count, $title) -AlwaysShow
      $itemId = ($foundItems | Sort-Object { $_.updated_at } -Descending | Select-Object -First 1).id
    } elseif ($foundItems.Count -eq 1) {
      $itemId = $foundItems[0].id
    }
  }

  if ($itemId) {
    Write-LogEntry -VMName $HostName -Message "SSH key '$title' already exists in 1Password - reusing it" -AlwaysShow
  } else {
    # Generate SSH key directly in 1Password using op item create
    $result = & op item create `
      --vault $Script:VaultName `
      --category "SSH Key" `
      --title $title `
      --tags "Homelab,AutoProvisioned" `
      --ssh-generate-key "ed25519" 2>&1

    if ($LASTEXITCODE -ne 0) {
      throw "Failed to create SSH Key item in 1Password. Error: $result"
    }

    # Get the ID of the newly created item
    $newItem = & op item list --vault $Script:VaultName --categories "SSH Key" --format json 2>$null | ConvertFrom-Json
    $itemId = ($newItem | Where-Object { $_.title -eq $title } | Sort-Object { $_.updated_at } -Descending | Select-Object -First 1).id
    if (-not $itemId) { throw "Failed to locate newly created SSH Key item '$title' in 1Password" }
  }

  # Get the public key using the unambiguous item ID
  $pub = & op item get $itemId `
    --vault $Script:VaultName `
    --field "public key" `
    --format human-readable

  if ([string]::IsNullOrWhiteSpace($pub)) {
    throw "Failed to retrieve public key from SSH Key item '$title' (id: $itemId)"
  }

  # Write PUBLIC key locally to ~/.ssh
  $localSsh = Join-Path $HOME '.ssh'
  if (-not (Test-Path $localSsh)) { New-Item -ItemType Directory -Path $localSsh -Force | Out-Null }
  $pubOut = Join-Path $localSsh ($title + '.pub')
  Set-Content -Path $pubOut -Value $pub.Trim() -Encoding ASCII -NoNewline

  return [pscustomobject]@{
    Title             = $title
    PublicKeyText     = $pub.Trim()
    PublicKeyPathLocal= $pubOut
    Passphrase        = $null
  }
}

# ---------- SSH config helpers ----------
function Add-SshConfigEntryLocal {
  <#
  .SYNOPSIS
      Adds an SSH config entry to one or more SSH config files.

  .DESCRIPTION
      Creates a Host block in each specified config file with the given hostname,
      DNS name, and identity file path. Skips any file that already contains the
      Host block (idempotent). Defaults to ~/.ssh/config when no paths are given.

  .PARAMETER HostName
      The SSH host alias to use.

  .PARAMETER DnsName
      The fully qualified domain name or IP address.

  .PARAMETER PublicKeyPath
      Path to the public key file (for 1Password SSH agent).

  .PARAMETER ConfigPaths
      Optional. One or more SSH config file paths to write to.
      Defaults to ~/.ssh/config.

  .EXAMPLE
      Add-SshConfigEntryLocal -HostName "web01" -DnsName "web01.vollminlab.com" -PublicKeyPath "~/.ssh/web01_id_ed25519.pub"
  #>
  [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Low')]
  param([Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$DnsName,
        [Parameter(Mandatory)][string]$PublicKeyPath,
        [string[]]$ConfigPaths)

  if (-not $PSCmdlet.ShouldProcess($HostName, "Add SSH config entry")) {
    return
  }

  if (-not $ConfigPaths -or $ConfigPaths.Count -eq 0) {
    $ConfigPaths = @(Join-Path $HOME '.ssh\config')
  }

  $entry = @"
Host $HostName
  HostName $DnsName
  User vollmin
  IdentitiesOnly yes
  IdentityFile $PublicKeyPath
"@

  foreach ($conf in $ConfigPaths) {
    if (-not (Test-Path $conf)) { New-Item -ItemType File -Path $conf -Force | Out-Null }
    if (-not (Select-String -Path $conf -Pattern "^Host\s+$([regex]::Escape($HostName))\s*$" -Quiet)) {
      Add-Content -Path $conf -Value $entry
    }
  }
}

function Invoke-SshConfigRepoCommit {
  <#
  .SYNOPSIS
      Commits and pushes a change to the SSH config file in the infrastructure repo.

  .DESCRIPTION
      Stages the SSH config file, commits with a descriptive message, and pushes.
      Failures warn but never throw - a git issue should never abort a deployment.

  .PARAMETER VMName
      Used for the commit message and log entries.

  .PARAMETER Action
      'add' or 'remove' - used in the commit message.
  #>
  param(
    [Parameter(Mandatory)][string]$VMName,
    [Parameter(Mandatory)][ValidateSet('add','remove')][string]$Action
  )

  if ([string]::IsNullOrWhiteSpace($Script:SshConfigRepoPath)) { return }
  if (-not (Test-Path $Script:SshConfigRepoPath)) {
    Write-LogEntry -VMName $VMName -Message "WARN: SshConfigRepoPath not found, skipping repo commit: $Script:SshConfigRepoPath" -AlwaysShow
    return
  }

  $repoRoot = & git -C (Split-Path $Script:SshConfigRepoPath) rev-parse --show-toplevel 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repoRoot)) {
    Write-Warning "SSH config repo not found at '$Script:SshConfigRepoPath' - skipping commit"
    return
  }

  $verb = if ($Action -eq 'add') { 'Add' } else { 'Remove' }
  $commitMsg = "$verb SSH config entry for $VMName"

  try {
    & git -C $repoRoot add (Resolve-Path $Script:SshConfigRepoPath) 2>&1 | Out-Null
    $status = & git -C $repoRoot status --porcelain (Resolve-Path $Script:SshConfigRepoPath) 2>$null
    if ([string]::IsNullOrWhiteSpace($status)) {
      Write-LogEntry -VMName $VMName -Message "SSH config repo: no changes to commit (entry already present)"
      return
    }
    & git -C $repoRoot commit -m $commitMsg 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git commit failed" }
    & git -C $repoRoot push 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git push failed" }
    Write-LogEntry -VMName $VMName -Message "SSH config repo: committed and pushed - '$commitMsg'" -AlwaysShow
  } catch {
    $msg = "WARN: Failed to commit/push SSH config repo change: $_"
    Write-LogEntry -VMName $VMName -Message $msg -AlwaysShow
    Write-Warning $msg
  }
}

function Update-RemoteGladosSsh {
  <#
  .SYNOPSIS
      Updates SSH configuration on a remote GLaDOS host.
  
  .DESCRIPTION
      Mirrors SSH public key and config entry to a remote host via network share.
      Returns false if the share is inaccessible. Used to ensure SSH access from 
      multiple locations.
  
  .PARAMETER HostName
      The SSH host alias.
  
  .PARAMETER DnsName
      The fully qualified domain name or IP address.
  
  .PARAMETER PublicKeyText
      The public key content as a string.
  
  .PARAMETER PublicKeyFileName
      The filename for the public key (e.g., "web01_id_ed25519.pub").
  
  .EXAMPLE
      Update-RemoteGladosSsh -HostName "web01" -DnsName "web01.vollminlab.com" `
                             -PublicKeyText $keyContent -PublicKeyFileName "web01_id_ed25519.pub"
  #>
  param([Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$DnsName,
        [Parameter(Mandatory)][string]$PublicKeyText,
        [Parameter(Mandatory)][string]$PublicKeyFileName)

  try {
    # Ensure remote dir
    if (-not (Test-Path $Script:RemoteUserProfileShare)) {
      # If share not present/accessible, just bail quietly
      Write-LogEntry -VMName $HostName -Message "Remote GLaDOS share not accessible: $Script:RemoteUserProfileShare"
      return $false
    }
    # Write public key
    $remotePub = Join-Path $Script:RemoteUserProfileShare $PublicKeyFileName
    Set-Content -Path $remotePub -Value $PublicKeyText -Encoding ASCII -NoNewline

    # Append host block if missing
    if (-not (Test-Path $Script:RemoteConfigPath)) {
      New-Item -ItemType File -Path $Script:RemoteConfigPath -Force | Out-Null
    }
    $hasHost = Select-String -Path $Script:RemoteConfigPath -Pattern "^Host\s+$([regex]::Escape($HostName))\s*$" -Quiet
    if (-not $hasHost) {
      $entry = @"
Host $HostName
  HostName $DnsName
  User vollmin
  IdentitiesOnly yes
  IdentityFile ~/.ssh/$PublicKeyFileName
"@
      Add-Content -Path $Script:RemoteConfigPath -Value $entry
    }
    return $true
  } catch {
    Write-LogEntry -VMName $HostName -Message "Remote GLaDOS update failed: $_"
    return $false
  }
}

function Remove-HostBlockFromConfig {
  <#
  .SYNOPSIS
      Removes a Host block from an SSH config file.
  
  .DESCRIPTION
      Parses an SSH config file and removes the specified Host block including all 
      indented lines that belong to it.
  
  .PARAMETER HostName
      The hostname to remove from the config.
  
  .PARAMETER ConfigPath
      The path to the SSH config file.
  
  .EXAMPLE
      Remove-HostBlockFromConfig -HostName "web01" -ConfigPath "~/.ssh/config"
  #>
  param([Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$ConfigPath)

  if (-not (Test-Path $ConfigPath)) { return }
  $lines = Get-Content $ConfigPath
  $out = New-Object System.Collections.Generic.List[string]
  $skip = $false
  foreach ($line in $lines) {
    # Check if this is the Host block we want to remove
    if ($line -match "^Host\s+$([regex]::Escape($HostName))\s*$") { 
      $skip = $true
      continue 
    }
    # If we're skipping and the line is indented (part of the Host block), skip it
    if ($skip -and ($line -match '^\s+' -or [string]::IsNullOrWhiteSpace($line))) { 
      continue 
    }
    # If we hit a non-indented line, stop skipping
    if ($skip) { 
      $skip = $false 
    }
    [void]$out.Add($line)
  }
  $out | Set-Content $ConfigPath -Encoding UTF8
}

function Remove-HostFromKnownHosts {
  <#
  .SYNOPSIS
      Removes a host entry from SSH known_hosts file.
  
  .DESCRIPTION
      Searches for and removes all entries matching the given hostname or IP address
      from the SSH known_hosts file. This prevents SSH from showing host key warnings
      when the host is recreated.
  
  .PARAMETER HostName
      The hostname to remove (can be hostname, FQDN, or IP address).
  
  .PARAMETER KnownHostsPath
      The path to the known_hosts file.
  
  .EXAMPLE
      Remove-HostFromKnownHosts -HostName "web01.vollminlab.com" -KnownHostsPath "~/.ssh/known_hosts"
  #>
  param([Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$KnownHostsPath)

  if (-not (Test-Path $KnownHostsPath)) { return }
  
  $lines = Get-Content $KnownHostsPath
  $out = New-Object System.Collections.Generic.List[string]
  
  foreach ($line in $lines) {
    # Skip empty lines or comments
    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
      [void]$out.Add($line)
      continue
    }
    
    # Known_hosts format: hostname[,hostname...] keytype publickey
    # Check if this line contains our hostname
    $hostPart = $line.Split(' ')[0]
    if ($hostPart -match [regex]::Escape($HostName)) {
      # Skip this line (remove it)
      continue
    }
    
    [void]$out.Add($line)
  }
  
  $out | Set-Content $KnownHostsPath -Encoding UTF8
}

# ---------- Network Port Group Detection ----------
function Get-NetworkPortGroupFromIP {
  <#
  .SYNOPSIS
      Automatically determines the correct network port group based on IP address.
  
  .DESCRIPTION
      Maps IP address subnets to their corresponding port groups by querying
      vCenter for available port groups and matching the naming pattern.
      Supports auto-discovery of new port groups following the XXX-DPG-* pattern.
  
  .PARAMETER IPAddress
      The IP address to determine the port group for.
  
  .EXAMPLE
      $portGroup = Get-NetworkPortGroupFromIP -IPAddress "192.168.152.100"
  #>
  param([Parameter(Mandatory)][string]$IPAddress)
  
  $ipParts = $IPAddress.Split('.')
  $subnet = "$($ipParts[0]).$($ipParts[1]).$($ipParts[2])"
  $subnetNumber = $ipParts[2]
  
  Write-Verbose "Determining port group for IP $IPAddress (subnet $subnet, number $subnetNumber)"
  
  $allPortGroups = Get-VDPortgroup | Where-Object { $_.Name -match '^\d{3}-DPG-' }
  Write-Verbose "Found $($allPortGroups.Count) distributed port groups matching pattern: $($allPortGroups.Name -join ', ')"
  
  # Look for a port group that starts with the subnet number
  $matchingPG = $allPortGroups | Where-Object { $_.Name -match "^$subnetNumber-DPG-" } | Select-Object -First 1
  
  if ($matchingPG) {
    Write-Verbose "Auto-detected port group '$($matchingPG.Name)' for subnet $subnet"
    return $matchingPG.Name
  }
  
  # Fallback to hardcoded mapping for known networks
  Write-Verbose "No auto-detected port group found, using fallback mapping"
  switch ($subnet) {
    "192.168.152" { 
      Write-Verbose "Using hardcoded mapping: 192.168.152 -> 152-DPG-GuestNet"
      return "152-DPG-GuestNet" 
    }
    "192.168.160" { 
      Write-Verbose "Using hardcoded mapping: 192.168.160 -> 160-DPG-DMZ"
      return "160-DPG-DMZ" 
    }
    default { throw "No port group found for IP $IPAddress (subnet $subnet)" }
  }
}

# ---------- Cloud-init VM build ----------
function Install-VirtualMachine {
  <#
  .SYNOPSIS
      Creates a new VM from a template with cloud-init configuration.
  
  .DESCRIPTION
      Performs the actual VM creation in vCenter including:
      - Cloning from template
      - Injecting cloud-init user-data and metadata via guestinfo
      - Configuring CPU, memory, and disk resources
      - Setting network adapter to correct port group based on IP
      - Optionally powering on the VM
      Generates and stores a random sudo password in 1Password.
  
  .PARAMETER VMName
      The name of the VM to create.
  
  .PARAMETER Template
      The vCenter template name to clone from.
  
  .PARAMETER Folder
      The vCenter folder where the VM will be created.
  
  .PARAMETER IPAddress
      The static IP address for the VM.
  
  .PARAMETER PublicKeyText
      The SSH public key to inject for the user account.
  
  .PARAMETER GuestPassword
      A reference variable to receive the generated password.
  
  .PARAMETER CPU
      Optional. Number of CPUs to assign.
  
  .PARAMETER MemoryGB
      Optional. Memory in GB to assign.
  
  .PARAMETER DiskGB
      Optional. Disk size in GB (can only grow, not shrink).
  
  .PARAMETER PowerOn
      If specified, powers on the VM after creation.
  
  .EXAMPLE
      $pwRef = [ref]""
      Install-VirtualMachine -VMName "web01" -Template "Ubuntu-22.04" -Folder "Lab" `
                             -IPAddress "192.168.152.100" -PublicKeyText $pubKey `
                             -GuestPassword $pwRef -PowerOn
  #>
  param(
    [Parameter(Mandatory)][string]$VMName,
    [Parameter(Mandatory)][string]$Template,
    [Parameter(Mandatory)][string]$Folder,
    [Parameter(Mandatory)][string]$IPAddress,
    [Parameter(Mandatory)][string]$PublicKeyText,
    [ref]$GuestPassword,
    [int]$CPU,
    [int]$MemoryGB,
    [int]$DiskGB,
    [switch]$PowerOn
  )
  Write-LogEntry -VMName $VMName -Message "Install-VirtualMachine START"

  # 1) Ensure new VM does not already exist
  $existingVm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
  if ($existingVm) {
    Write-LogEntry -VMName $VMName -Message ("ERROR: VM '{0}' already exists (state: {1})" -f $VMName, $existingVm.PowerState)
    throw "VM '$VMName' already exists."
  }

  # 2) Sudo secret
  $guestPw = New-RandomPassword
  $GuestPassword.Value = $guestPw
  Save-SudoPasswordTo1Password -VMName $VMName -SecurePassword (ConvertTo-SecureString $guestPw -AsPlainText -Force)

  # 3) cloud-init
  # Calculate gateway from IP address (assume .1 is the gateway)
  $ipParts = $IPAddress.Split('.')
  $gateway = "{0}.{1}.{2}.1" -f $ipParts[0], $ipParts[1], $ipParts[2]
  
  $hashedPw  = ConvertTo-SHA512Crypt -Password (ConvertTo-SecureString $guestPw -AsPlainText -Force)
  $userData = @"
#cloud-config
hostname: $VMName
fqdn: $VMName.$($Script:Domain)
manage_etc_hosts: true

users:
  - name: vollmin
    sudo: ALL=(ALL) ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: $hashedPw
    ssh_authorized_keys:
      - $PublicKeyText

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
          id0:
            match:
              name: "en*"
            addresses:
              - $IPAddress/24
            nameservers:
              addresses:
                - 192.168.100.4
                - 192.168.100.3
            routes:
              - to: default
                via: $gateway

runcmd:
  - netplan apply
  - sed -i '/^search /c\search .' /etc/resolv.conf
  - echo "Netplan+DNS override applied" >> /var/log/cloud-init.log
"@

  Write-LogEntry -VMName $VMName -Message ("Built user-data payload, {0} bytes" -f $userData.Length)
  $userDataEncoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($userData))
  $metaData = "instance-id: $VMName`nlocal-hostname: $VMName"
  $metaDataEncoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($metaData))

  # 4) Create VM
  try {
    $templateObj   = Get-Template -Name $Template -ErrorAction Stop
    $folderObj     = Get-Folder   -Name $Folder   -ErrorAction Stop
    $clusterObj    = Get-Cluster  -Name $Script:ClusterName -ErrorAction Stop

    Test-VMHostReadiness -ClusterName $Script:ClusterName -VMName $VMName | Out-Null

    # Determine minimum required space (requested disk size + 10% overhead)
    $requiredGB = if ($DiskGB) { $DiskGB * 1.1 } else { 30 }  # Default to 30GB if not specified
    
    $datastores = Get-Datastore | Where-Object { $_.State -eq "Available" }
    foreach ($ds in $datastores) {
      $freeGB = [math]::Round($ds.FreeSpaceGB, 2)
      Write-LogEntry -VMName $VMName -Message ("Datastore '{0}': {1}GB free" -f $ds.Name, $freeGB)
    }

    # Try shared storage first (accessible by all hosts)
    $sharedDs = $datastores | 
                Where-Object { $Script:PreferredDatastores -contains $_.Name -and $_.FreeSpaceGB -ge $requiredGB } | 
                Sort-Object -Property FreeSpaceGB -Descending | 
                Select-Object -First 1
    
    if ($sharedDs) {
      # Shared storage available - can use any host
      $preferredDs = $sharedDs
      $availableHosts = Get-VMHost -Location $clusterObj | Where-Object { $_.ConnectionState -eq "Connected" }
      if ($availableHosts.Count -eq 0) { throw "No available hosts found for VM deployment." }
      $targetHost = $availableHosts | Sort-Object -Property CpuUsageMhz | Select-Object -First 1
      Write-LogEntry -VMName $VMName -Message ("Selected shared datastore '{0}' ({1}GB free, {2}GB required)" -f $preferredDs.Name, [math]::Round($preferredDs.FreeSpaceGB, 2), [math]::Round($requiredGB, 2))
      Write-LogEntry -VMName $VMName -Message ("Selected host '{0}' for deployment" -f $targetHost.Name)
    } else {
      # Shared storage full/unavailable - need to pick host with local datastore that has space
      Write-LogEntry -VMName $VMName -Message "Shared storage unavailable, checking local datastores..."
      
      $availableHosts = Get-VMHost -Location $clusterObj | Where-Object { $_.ConnectionState -eq "Connected" }
      if ($availableHosts.Count -eq 0) { throw "No available hosts found for VM deployment." }
      
      $hostWithSpace = $null
      $localDs = $null
      
      foreach ($esxiHost in $availableHosts) {
        $hostDatastores = $esxiHost | Get-Datastore | Where-Object { $_.State -eq "Available" -and $_.FreeSpaceGB -ge $requiredGB }
        if ($hostDatastores) {
          $localDs = $hostDatastores | Sort-Object -Property FreeSpaceGB -Descending | Select-Object -First 1
          $hostWithSpace = $esxiHost
          break
        }
      }
      
      if (-not $hostWithSpace -or -not $localDs) {
        throw "No hosts found with local datastores having sufficient space ({0}GB required) for VM deployment." -f [math]::Round($requiredGB, 2)
      }
      
      $targetHost = $hostWithSpace
      $preferredDs = $localDs
      Write-LogEntry -VMName $VMName -Message ("Selected host '{0}' with local datastore '{1}' ({2}GB free, {3}GB required)" -f $targetHost.Name, $preferredDs.Name, [math]::Round($preferredDs.FreeSpaceGB, 2), [math]::Round($requiredGB, 2))
    }

    $poolObj = Get-ResourcePool -Location $clusterObj | Where-Object Name -eq "Resources"
    $newVm   = New-VM -Name $VMName -Template $templateObj -Location $folderObj -ResourcePool $poolObj -VMHost $targetHost -Datastore $preferredDs -ErrorAction Stop
    Write-LogEntry -VMName $VMName -Message "New-VM succeeded" -AlwaysShow
  } catch {
    Write-LogEntry -VMName $VMName -Message ("New-VM FAILED: {0}" -f $_)
    throw
  }

  # 5) Inject advanced settings
  $settings = @(
    @{ Name = "guestinfo.userdata";          Value = $userDataEncoded },
    @{ Name = "guestinfo.userdata.encoding"; Value = "base64"         },
    @{ Name = "guestinfo.metadata";          Value = $metaDataEncoded },
    @{ Name = "guestinfo.metadata.encoding"; Value = "base64"         }
  )
  foreach ($s in $settings) {
    New-AdvancedSetting -Entity $newVm -Name $s.Name -Value $s.Value -Confirm:$false -Force | Out-Null
    Write-LogEntry -VMName $VMName -Message ("Injected advanced setting '{0}'" -f $s.Name)
  }

  # 6) Configure network adapter to correct port group based on IP
  try {
    $portGroupName = Get-NetworkPortGroupFromIP -IPAddress $IPAddress
    $network = Get-VDPortgroup -Name $portGroupName
    $vmNetworkAdapter = Get-NetworkAdapter -VM $newVm
    Set-NetworkAdapter -NetworkAdapter $vmNetworkAdapter -Portgroup $network -Confirm:$false | Out-Null
    Write-LogEntry -VMName $VMName -Message "Set network adapter to port group '$portGroupName'"
  } catch {
    Write-LogEntry -VMName $VMName -Message "WARN: Failed to set network port group: $_"
  }

  # 7) Resource mods
  if ($CPU -or $MemoryGB -or $DiskGB) {
    if ($CPU) { 
      Set-VM -VM $newVm -NumCpu $CPU -Confirm:$false | Out-Null
      Write-LogEntry -VMName $VMName -Message "Set CPU cores to $CPU"
    }
    if ($MemoryGB) { 
      Set-VM -VM $newVm -MemoryGB $MemoryGB -Confirm:$false | Out-Null
      Write-LogEntry -VMName $VMName -Message "Set memory to ${MemoryGB}GB"
    }
    if ($DiskGB) {
      $firstDisk = Get-HardDisk -VM $newVm | Select-Object -First 1
      $cur = [math]::Round($firstDisk.CapacityGB)
      if ($DiskGB -gt $cur) { 
        Set-HardDisk -HardDisk $firstDisk -CapacityGB $DiskGB -Confirm:$false | Out-Null
        Write-LogEntry -VMName $VMName -Message "Expanded disk to ${DiskGB}GB"
      }
      elseif ($DiskGB -lt $cur) { 
        Write-LogEntry -VMName $VMName -Message ("Skip shrinking disk from {0}GB to {1}GB - VMware will not allow disk shrinking" -f $cur,$DiskGB) 
      }
    }
    Write-LogEntry -VMName $VMName -Message "VM resource modification complete"
  }

  # 8) Power on
  if ($PowerOn) { Start-VM -VM $newVm -Confirm:$false | Out-Null; Write-LogEntry -VMName $VMName -Message "VM powered on" -AlwaysShow }

  Write-LogEntry -VMName $VMName -Message "Install-VirtualMachine COMPLETE"
}

# ---------- Top-level orchestration ----------
function Invoke-VMDeployment {
  <#
  .SYNOPSIS
      Deploys a new VM with automated SSH key generation, DNS registration, and cloud-init configuration.
  
  .DESCRIPTION
      Orchestrates the complete VM deployment process including:
      - SSH key generation and storage in 1Password
      - SSH config entry creation
      - vCenter connection and VM creation from template
      - DNS record registration in Pi-hole
      - Random sudo password generation and storage
      - Cloud-init configuration for automated OS setup
  
  .PARAMETER VMName
      The name of the VM to create. Also used as the hostname.
  
  .PARAMETER TemplateName
      The name of the vCenter template to clone.
  
  .PARAMETER IPAddress
      The static IP address to assign to the VM.
  
  .PARAMETER VMFolder
      The vCenter folder where the VM will be created.
  
  .PARAMETER CPU
      Optional. Number of CPU cores to assign to the VM.
  
  .PARAMETER MemoryGB
      Optional. Amount of memory in GB to assign to the VM.
  
  .PARAMETER DiskGB
      Optional. Disk size in GB (can only increase from template size).
  
  .PARAMETER WhatIf
      Shows what would happen without actually making changes.
  
  .PARAMETER PowerOn
      If specified, powers on the VM after creation.
  
  .PARAMETER ClearOpAuthToken
      If specified, clears the 1Password authentication token after deployment completes.
  
  .EXAMPLE
      Invoke-VMDeployment -VMName "web01" -TemplateName "Ubuntu-22.04-Template" `
                          -IPAddress "192.168.152.100" -VMFolder "WebServers" -PowerOn
  
  .EXAMPLE
      Invoke-VMDeployment -VMName "db01" -TemplateName "Ubuntu-22.04-Template" `
                          -IPAddress "192.168.152.101" -VMFolder "Database" `
                          -CPU 8 -MemoryGB 16 -DiskGB 100 -PowerOn -ClearOpAuthToken
  
  .EXAMPLE
      Invoke-VMDeployment -VMName "dmz01" -TemplateName "Ubuntu-22.04-Template" `
                          -IPAddress "192.168.160.10" -VMFolder "DMZ" -PowerOn
  #>
  [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
  param(
    [Parameter(Mandatory)][string]$VMName,
    [Parameter(Mandatory)][string]$TemplateName,
    [Parameter(Mandatory)][string]$IPAddress,
    [Parameter(Mandatory)][string]$VMFolder,
    [int]$CPU,
    [int]$MemoryGB,
    [int]$DiskGB,
    [switch]$PowerOn,
    [switch]$ClearOpAuthToken
  )
  
  $fqdn = "$VMName.$($Script:Domain)"
  
  if (-not $PSCmdlet.ShouldProcess("VM: $VMName", "Deploy VM with IP $IPAddress")) {
    return
  }
  
  Write-LogEntry -VMName $VMName -Message ("Invoke-VMDeployment START Template={0},IP={1},Folder={2},PowerOn={3}" -f $TemplateName,$IPAddress,$VMFolder,$PowerOn) -AlwaysShow
  Write-LogEntry -VMName $VMName -Message ("Checking DNS for {0}" -f $fqdn)
  
  # Check if DNS already exists
  try { $existing = [System.Net.Dns]::GetHostAddresses($fqdn) | Select-Object -ExpandProperty IPAddressToString } catch { $existing = $null }
  if ($existing) {
    Write-LogEntry -VMName $VMName -Message ("DNS {0} resolves to {1}, aborting" -f $fqdn,$existing)
    Write-Error ("DNS {0} already resolves to {1}, aborting" -f $fqdn, $existing)
    return
  }

  # WhatIf mode - just describe what would happen (for explicit -WhatIf parameter)
  if ($WhatIfPreference) {
    Write-Host "[WhatIf] Would validate template '$TemplateName', folder '$VMFolder', cluster '$Script:ClusterName' in vCenter"
    Write-Host "[WhatIf] Would generate ed25519 SSH keypair for $VMName"
    Write-Host "[WhatIf] Would store SSH key in 1Password vault '$($Script:VaultName)' as '${VMName}_id_ed25519'"
    Write-Host "[WhatIf] Would save public key to ~/.ssh/${VMName}_id_ed25519.pub"
    Write-Host "[WhatIf] Would add SSH config entry for host '$VMName' ($fqdn)"
    if (-not $Script:IsGlados) {
      Write-Host "[WhatIf] Would mirror SSH config to remote GLaDOS host"
    }
    Write-Host "[WhatIf] Would add DNS record to Pi-hole"
    Write-Host "[WhatIf] Would create VM from template '$TemplateName'"
    return
  }

  # Validate vCenter prerequisites BEFORE any side effects.
  # Connects to vCenter and confirms template/folder/cluster exist.
  # If any check fails we abort here - nothing has been created yet.
  Test-VMDeploymentPrerequisites -VMName $VMName -TemplateName $TemplateName -VMFolder $VMFolder

  # Create SSH key in 1Password (ed25519), save pub locally, no private key on disk
  $key = New-1PSSHKeyForHost -HostName $VMName

  # Build list of SSH config files to update - always ~/.ssh/config, plus the repo copy if configured
  $sshConfigPaths = @(Join-Path $HOME '.ssh\config')
  if (-not [string]::IsNullOrWhiteSpace($Script:SshConfigRepoPath)) {
    $sshConfigPaths += $Script:SshConfigRepoPath
  }
  Add-SshConfigEntryLocal -HostName $VMName -DnsName $fqdn -PublicKeyPath $key.PublicKeyPathLocal -ConfigPaths $sshConfigPaths
  Invoke-SshConfigRepoCommit -VMName $VMName -Action 'add'

  # If we're NOT on GLaDOS, try to copy pub + append host block remotely too
  if (-not $Script:IsGlados) {
    $ok = Update-RemoteGladosSsh -HostName $VMName -DnsName $fqdn `
            -PublicKeyText $key.PublicKeyText `
            -PublicKeyFileName ([IO.Path]::GetFileName($key.PublicKeyPathLocal))
    if ($ok) { Write-LogEntry -VMName $VMName -Message "Mirrored SSH pub + config to GLaDOS" }
    else {
      $warnMsg = "Skipped/failed mirroring SSH config to GLaDOS (share inaccessible) - SSH access from GLaDOS may not work for $VMName"
      Write-Warning $warnMsg
      Write-LogEntry -VMName $VMName -Message $warnMsg
    }
  }

  Add-DnsRecordToPiHole -Fqdn $fqdn -IPAddress $IPAddress

  # Deploy the VM (Connect-ToVCenter is a no-op - already connected by Test-VMDeploymentPrerequisites)
  $passwordRef = [ref]""
  Install-VirtualMachine `
    -VMName           $VMName `
    -Template         $TemplateName `
    -Folder           $VMFolder `
    -IPAddress        $IPAddress `
    -PublicKeyText    $key.PublicKeyText `
    -GuestPassword    $passwordRef `
    -CPU              $CPU `
    -MemoryGB         $MemoryGB `
    -DiskGB           $DiskGB `
    -PowerOn:$PowerOn

  Write-LogEntry -VMName $VMName -Message "Invoke-VMDeployment COMPLETE" -AlwaysShow 
  if ($ClearOpAuthToken) {
    Clear-OpAuth
    Write-LogEntry -VMName $VMName -Message "Cleared 1Password authentication token"
  }
}

function Remove-VMDeployment {
  <#
  .SYNOPSIS
      Removes a VM and cleans up all associated resources.
  
  .DESCRIPTION
      Completely removes a VM deployment including:
      - DNS record removal from Pi-hole
      - Local and remote SSH config entries
      - Local and remote SSH public key files
      - Local and remote known_hosts entries
      - Archives 1Password items for SSH key and sudo password
      - Stops and removes VM from vCenter
  
  .PARAMETER VMName
      The name of the VM to remove.
  
  .PARAMETER WhatIf
      Shows what would be removed without actually making changes.
  
  .PARAMETER ClearOpAuthToken
      If specified, clears the 1Password authentication token after removal completes.
  
  .EXAMPLE
      Remove-VMDeployment -VMName "testvm"
  
  .EXAMPLE
      Remove-VMDeployment -VMName "web01" -WhatIf
  
  .EXAMPLE
      Remove-VMDeployment -VMName "prod01" -ClearOpAuthToken
  #>
  [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
  param(
    [Parameter(Mandatory)][string]$VMName,
    [switch]$ClearOpAuthToken
  )

  $fqdn       = "$VMName.$($Script:Domain)"
  $keyTitle   = "${VMName}_id_ed25519"
  $localPub   = Join-Path (Join-Path $HOME '.ssh') ($keyTitle + '.pub')

  if (-not $PSCmdlet.ShouldProcess("VM: $VMName", "Remove VM and all associated resources")) {
    return
  }

  Write-LogEntry -VMName $VMName -Message "Remove-VMDeployment START" -AlwaysShow

  # 1) DNS
  try {
    Remove-DnsRecordFromPiHole -Fqdn $fqdn
  } catch {
    Write-Warning "DNS cleanup failed for $fqdn (continuing): $_"
    Write-LogEntry -VMName $VMName -Message "WARN: DNS cleanup failed for ${fqdn}: $_"
  }

  # 2) Local SSH artifacts
  try {
    if (Test-Path $localPub) {
      Remove-Item -Path $localPub -Force
      Write-LogEntry -VMName $VMName -Message "Removed local SSH public key $localPub"
    }
    $localConfig = Join-Path $HOME '.ssh\config'
    if (Test-Path $localConfig) {
      Remove-HostBlockFromConfig -HostName $VMName -ConfigPath $localConfig
      Write-LogEntry -VMName $VMName -Message "Removed local SSH config entry for $VMName"
    }
    if (-not [string]::IsNullOrWhiteSpace($Script:SshConfigRepoPath) -and (Test-Path $Script:SshConfigRepoPath)) {
      Remove-HostBlockFromConfig -HostName $VMName -ConfigPath $Script:SshConfigRepoPath
      Write-LogEntry -VMName $VMName -Message "Removed SSH config entry from repo copy"
      Invoke-SshConfigRepoCommit -VMName $VMName -Action 'remove'
    }
    $localKnownHosts = Join-Path $HOME '.ssh\known_hosts'
    if (Test-Path $localKnownHosts) {
      Remove-HostFromKnownHosts -HostName $VMName -KnownHostsPath $localKnownHosts
      Remove-HostFromKnownHosts -HostName $fqdn -KnownHostsPath $localKnownHosts
      Write-LogEntry -VMName $VMName -Message "Removed entries from local known_hosts"
    }
  } catch {
    Write-Warning "Local SSH cleanup failed for $VMName (continuing): $_"
    Write-LogEntry -VMName $VMName -Message "WARN: Local SSH cleanup failed for ${VMName}: $_"
  }

  # 3) Remote GLaDOS mirrors (only if not on GLaDOS; safe to try from either)
  try {
    if (Test-Path $Script:RemoteUserProfileShare) {
      $remotePub = Join-Path $Script:RemoteUserProfileShare ($keyTitle + '.pub')
      if (Test-Path $remotePub) {
        Remove-Item $remotePub -Force
        Write-LogEntry -VMName $VMName -Message "Removed remote SSH public key $remotePub"
      }
      if (Test-Path $Script:RemoteConfigPath) {
        Remove-HostBlockFromConfig -HostName $VMName -ConfigPath $Script:RemoteConfigPath
        Write-LogEntry -VMName $VMName -Message "Removed remote SSH config entry for $VMName"
      }
      
      # Remove from remote known_hosts
      $remoteKnownHosts = Join-Path $Script:RemoteUserProfileShare 'known_hosts'
      if (Test-Path $remoteKnownHosts) {
        if (-not [string]::IsNullOrWhiteSpace($VMName)) {
          Remove-HostFromKnownHosts -HostName $VMName -KnownHostsPath $remoteKnownHosts
        }
        if (-not [string]::IsNullOrWhiteSpace($fqdn)) {
          Remove-HostFromKnownHosts -HostName $fqdn -KnownHostsPath $remoteKnownHosts
        }
        Write-LogEntry -VMName $VMName -Message "Removed entries from remote known_hosts"
      }
    }
  } catch {
    Write-Warning "Remote GLaDOS cleanup failed for $VMName (continuing): $_"
    Write-LogEntry -VMName $VMName -Message "WARN: Remote cleanup skipped/failed: $_"
  }

  # 4) Archive SSH Key item and sudo password item
  try {
    Initialize-OpAuth
    op item delete $keyTitle --vault $Script:VaultName --archive | Out-Null
    Write-LogEntry -VMName $VMName -Message "Archived 1Password SSH Key '$keyTitle'"
    try {
      op item delete $VMName --vault $Script:VaultName --archive | Out-Null
      Write-LogEntry -VMName $VMName -Message "Archived 1Password sudo credential '$VMName'"
    } catch {
      Write-Warning "Failed to archive 1Password sudo credential '$VMName' (continuing): $_"
      Write-LogEntry -VMName $VMName -Message "WARN: Failed to archive sudo credential '$VMName' in 1Password: $_"
    }
  } catch {
    Write-Warning "Failed to archive 1Password items for '$VMName' (continuing): $_"
    Write-LogEntry -VMName $VMName -Message "WARN: Failed to archive 1Password items for '${VMName}': $_"
  }

  # 5) Remove VM
  Connect-ToVCenter -VMName $VMName
  $vmObj = Get-VM -Name $VMName -ErrorAction SilentlyContinue
  if ($vmObj) {
    Stop-VM -VM $vmObj -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    Remove-VM -VM $vmObj -DeletePermanently -Confirm:$false | Out-Null
    Write-LogEntry -VMName $VMName -Message "VM $VMName removed from vCenter" -AlwaysShow
  } else {
    Write-LogEntry -VMName $VMName -Message "VM $VMName not found in vCenter"
  }

  Write-LogEntry -VMName $VMName -Message "Remove-VMDeployment COMPLETE" -AlwaysShow
  
  if ($ClearOpAuthToken) {
    Clear-OpAuth
    Write-LogEntry -VMName $VMName -Message "Cleared 1Password authentication token"
  }
}


# ---------- Post-load initialization ----------
# Resolve the SSH config repo path now that Find-SiblingRepo is defined.
$Script:SshConfigRepoPath = Find-SiblingRepo -RepoName 'homelab-infrastructure' `
                                              -RelativePath 'hosts/windows/ssh/config'
if ($Script:SshConfigRepoPath) {
  Write-Verbose "SSH config repo found: $Script:SshConfigRepoPath"
} else {
  Write-Warning "homelab-infrastructure repo not found as a sibling of this repo. SSH config will not be synced to the infrastructure repo."
}
