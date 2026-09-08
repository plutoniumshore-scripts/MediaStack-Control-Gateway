#requires -RunAsAdministrator
<#
MediaStack Control Gateway Installer for Windows Server
v3.4.10 - WATCHDOG + LOG ROTATION / TUNNEL DIAGNOSTICS / ARR STATUS + COLORING / INSTALLER LOGGING / HUB CACHE REFRESH / ADDED AT METADATA / EPISODE METADATA / ITEM POSTER METADATA / ITEM SUMMARY METADATA / ARR MANAGEMENT / TAUTULLI REPORTING / COLLECTION METADATA / SELF-HEALING TUNNEL / IDEMPOTENT

Safe to run repeatedly.

Behavior:
  * Reuses a working tunnel-client and application-local Python installation.
  * Installs Python packages only when imports fail.
  * Rewrites the generated MCP server only when its content changes.
  * Reuses or repairs the tunnel profile and Scheduled Tasks as needed.
  * Keeps generated PowerShell/Python/config files editable by the invoking Windows user while retaining restricted ACLs.
  * Provides Plex library, collection, smart-collection, metadata, artwork, episode, playlist, addedAt/Touch, and transient-hub tools.
  * Provides Tautulli-backed reporting and controlled local CSV/JSON export workflows.
  * Provides Sonarr, Radarr, and Lidarr reporting and controlled management workflows.
  * v3.4.4 adds read/write metadata tools for individual TV episodes.
  * v3.4.5 adds addedAt metadata controls for movies, shows, seasons, and episodes for Recently Added ordering.
  * v3.4.6 adds non-destructive Plex transient-hub refresh/warm plus Recently Added verification.
  * v3.4.7 adds timestamped full installer transcript logging.
  * v3.4.8 fixes current nested Arr status parsing and normalizes console severity colors.
  * v3.4.9 adds read-only tunnel timing and bounded runtime diagnostics.
  * v3.4.10 separates tunnel liveness from readiness to prevent restart storms, adds readiness thresholds/cooldowns/startup grace, bounded UTF-8 runtime/watchdog logs, installer-log retention, a clearly named health endpoint state file, and a dynamic local admin UI launcher.
  * Arr deletions require a short-lived prepared confirmation token before the destructive call can execute.
  * New Radarr/Sonarr/Lidarr requests require an explicit root folder/profile instead of guessing storage paths.

By default, working files live under:
  C:\Scripts\MediaStack-Control-Gateway

The install root and operational thresholds can be changed in the local configuration file.

This script is intentionally NONINTERACTIVE.

PUBLIC REPOSITORY NOTE:
  Credentials and environment-specific addresses are loaded from the local
  MediaStack-Control-Gateway.config.psd1 file. Do not place secrets directly
  into this installer or commit the real config file to source control.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'Continue'

# HARD NONINTERACTIVE MODE
# Equivalent to answering "Yes to All" for PowerShell confirmation prompts.
$ConfirmPreference = 'None'
$PSDefaultParameterValues['*:Confirm'] = $false

# Force overwrite/removal behavior only for common filesystem cmdlets used by
# this installer. This prevents repeat runs from stopping for confirmation.
$PSDefaultParameterValues['New-Item:Force'] = $true
$PSDefaultParameterValues['Copy-Item:Force'] = $true
$PSDefaultParameterValues['Move-Item:Force'] = $true
$PSDefaultParameterValues['Remove-Item:Force'] = $true
$PSDefaultParameterValues['Set-Content:Force'] = $true

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Normalize severity colors for the interactive installer console. Neutral data
# remains at the host default color. These assignments are best-effort because
# some non-console hosts do not expose mutable PrivateData color properties.
try {
    if ($null -ne $Host.PrivateData) {
        $Host.PrivateData.WarningForegroundColor = 'Yellow'
        $Host.PrivateData.ErrorForegroundColor = 'Red'
    }
}
catch {
}

# ===========================================================================
# Local configuration
# ===========================================================================
# Secrets and environment-specific values are intentionally kept outside this
# installer. Copy MediaStack-Control-Gateway.config.example.psd1 to
# MediaStack-Control-Gateway.config.psd1, then replace every <REQUIRED: ...>
# placeholder before running the installer. The real config file is excluded
# by the repository .gitignore.
$ConfigFileName = 'MediaStack-Control-Gateway.config.psd1'
$ConfigPath = Join-Path $PSScriptRoot $ConfigFileName

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath`r`nCopy MediaStack-Control-Gateway.config.example.psd1 to $ConfigFileName and replace every <REQUIRED: ...> placeholder."
}

$Config = Import-PowerShellDataFile -LiteralPath $ConfigPath

$TunnelId = [string]$Config['TunnelId']
$OpenAiRuntimeKey = [string]$Config['OpenAiRuntimeKey']
$PlexUrl = [string]$Config['PlexUrl']
$PlexToken = [string]$Config['PlexToken']
$TautulliUrl = [string]$Config['TautulliUrl']
$TautulliApiKey = [string]$Config['TautulliApiKey']
$SonarrUrl = [string]$Config['SonarrUrl']
$SonarrApiKey = [string]$Config['SonarrApiKey']
$RadarrUrl = [string]$Config['RadarrUrl']
$RadarrApiKey = [string]$Config['RadarrApiKey']
$LidarrUrl = [string]$Config['LidarrUrl']
$LidarrApiKey = [string]$Config['LidarrApiKey']

if ($Config.ContainsKey('InstallRoot') -and -not [string]::IsNullOrWhiteSpace([string]$Config['InstallRoot'])) {
    $Root = [string]$Config['InstallRoot']
}
else {
    $Root = 'C:\Scripts\MediaStack-Control-Gateway'
}

function Get-OptionalPositiveInt {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][int]$Default
    )
    if (-not $Config.ContainsKey($Name) -or $null -eq $Config[$Name] -or [string]::IsNullOrWhiteSpace([string]$Config[$Name])) {
        return $Default
    }
    $value = 0
    if (-not [int]::TryParse([string]$Config[$Name], [ref]$value) -or $value -lt 1) {
        throw "Optional configuration field '$Name' must be a positive integer."
    }
    return $value
}

# ===========================================================================
# Fixed paths
# ===========================================================================
$BinDir = Join-Path $Root 'bin'
$DownloadDir = Join-Path $Root 'downloads'
$ProfileDir = Join-Path $Root 'profiles'
$LogDir = Join-Path $Root 'logs'
$ReportingExportDir = Join-Path $Root 'reporting-exports'
$HealthUrlFile = Join-Path $LogDir 'tunnel-health-endpoint.txt'
$LegacyHealthUrlFile = Join-Path $LogDir 'tunnel-health.url'
$WatchdogStateFile = Join-Path $LogDir 'tunnel-watchdog-state.json'
$OpenTunnelUiScript = Join-Path $Root 'Open-Tunnel-UI.ps1'

# Managed log/watchdog policy. Defaults are conservative and can be overridden
# in the local configuration file.
$RuntimeLogMaxBytes = (Get-OptionalPositiveInt -Name 'RuntimeLogMaxMB' -Default 25) * 1MB
$RuntimeLogRetainedFiles = Get-OptionalPositiveInt -Name 'RuntimeLogRetainedFiles' -Default 3
$WatchdogLogMaxBytes = (Get-OptionalPositiveInt -Name 'WatchdogLogMaxMB' -Default 5) * 1MB
$WatchdogLogRetainedFiles = Get-OptionalPositiveInt -Name 'WatchdogLogRetainedFiles' -Default 3
$InstallerLogRetainCount = Get-OptionalPositiveInt -Name 'InstallerLogRetainCount' -Default 10
$WatchdogReadinessFailureThreshold = Get-OptionalPositiveInt -Name 'WatchdogReadinessFailureThreshold' -Default 3
$WatchdogReadinessRestartCooldownMinutes = Get-OptionalPositiveInt -Name 'WatchdogReadinessRestartCooldownMinutes' -Default 10
$WatchdogStartupGraceSeconds = Get-OptionalPositiveInt -Name 'WatchdogStartupGraceSeconds' -Default 90
$WatchdogHealthyHeartbeatMinutes = Get-OptionalPositiveInt -Name 'WatchdogHealthyHeartbeatMinutes' -Default 60
# Python is deliberately application-local. We use the official CPython NuGet
# distribution instead of the Windows MSI/bootstrapper, so there is no Windows
# installation state, registry entry, maintenance mode, or reboot dependency.
$PythonPackageVersion = '3.12.10'
$PythonDir = Join-Path $Root 'Python312-NuGet'
$PythonExe = Join-Path $PythonDir 'tools\python.exe'
$TunnelExe = Join-Path $BinDir 'tunnel-client.exe'
$CloudflaredExe = Join-Path $BinDir 'cloudflared.exe'
$McpServer = Join-Path $Root 'media_stack_gateway.py'
$TunnelRunner = Join-Path $Root 'run-tunnel.ps1'
$WatchdogScript = Join-Path $Root 'watch-tunnel.ps1'
$TaskName = 'MediaStack Control Gateway Tunnel'
$WatchdogTaskName = 'MediaStack Control Gateway Tunnel Watchdog'
$ProfileName = 'media-stack'
$TotalStages = 12

# ===========================================================================
# Timestamped installer transcript logging
# ===========================================================================
# Capture the complete installer console stream, including warnings and errors,
# so installation problems can be reviewed after the PowerShell window closes.
# This is separate from the tunnel runtime/watchdog/doctor logs below.
if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force -Confirm:$false | Out-Null
}

$InstallerTimestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$InstallerLog = Join-Path $LogDir ("installer-{0}.log" -f $InstallerTimestamp)
$InstallerTranscriptActive = $false

try {
    Start-Transcript -Path $InstallerLog -Force -ErrorAction Stop | Out-Null
    $InstallerTranscriptActive = $true
}
catch {
    # Logging must never prevent the installer itself from running.
    Write-Warning "Unable to start installer transcript logging at '$InstallerLog': $($_.Exception.Message)"
}

# Retain only the newest managed installer transcripts. Neutral historical logs
# with other names are left untouched.
try {
    $oldInstallerLogs = @(
        Get-ChildItem -LiteralPath $LogDir -Filter 'installer-*.log' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -Skip $InstallerLogRetainCount
    )
    foreach ($oldInstallerLog in $oldInstallerLogs) {
        Remove-Item -LiteralPath $oldInstallerLog.FullName -Force -Confirm:$false -ErrorAction SilentlyContinue
    }
}
catch {
    Write-Warning "Installer log retention cleanup could not complete: $($_.Exception.Message)"
}

try {

function Expand-ZipNoPrompt {
    param(
        [Parameter(Mandatory=$true)][string]$Source,
        [Parameter(Mandatory=$true)][string]$Destination,
        [switch]$CleanDestination
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "ZIP source does not exist: $Source"
    }

    if ($CleanDestination -and (Test-Path -LiteralPath $Destination)) {
        Remove-Item -LiteralPath $Destination -Recurse -Force -Confirm:$false
    }

    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force -Confirm:$false | Out-Null
    }

    # Use .NET directly instead of Expand-Archive. This bypasses PowerShell's
    # ShouldProcess confirmation mechanism completely.
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($Source, $Destination)
    }
    catch {
        throw "ZIP extraction failed for '$Source' -> '$Destination': $($_.Exception.Message)"
    }
}

function Get-TunnelHealthBaseUrl {
    if (-not (Test-Path -LiteralPath $HealthUrlFile)) {
        return $null
    }

    try {
        $url = (Get-Content -LiteralPath $HealthUrlFile -Raw -ErrorAction Stop).Trim()
        if ($url -match '^http://127\.0\.0\.1:\d+$') {
            return $url.TrimEnd('/')
        }
    }
    catch {
    }

    return $null
}

function Get-TunnelLocalProbe {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('/healthz','/readyz')][string]$Path,
        [int]$TimeoutSeconds = 3
    )

    $baseUrl = Get-TunnelHealthBaseUrl
    if (-not $baseUrl) {
        return [pscustomobject]@{ Ok = $false; StatusCode = $null; Body = ''; Error = 'Health endpoint file is missing or invalid.'; BaseUrl = $null }
    }

    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri ($baseUrl + $Path) -TimeoutSec $TimeoutSeconds -ErrorAction Stop
        return [pscustomobject]@{
            Ok = ($response.StatusCode -eq 200)
            StatusCode = [int]$response.StatusCode
            Body = [string]$response.Content
            Error = $null
            BaseUrl = $baseUrl
        }
    }
    catch {
        $statusCode = $null
        $body = ''
        if ($null -ne $_.Exception.Response) {
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                if ($null -ne $stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
                }
            }
            catch { }
        }
        return [pscustomobject]@{
            Ok = $false
            StatusCode = $statusCode
            Body = $body
            Error = $_.Exception.Message
            BaseUrl = $baseUrl
        }
    }
}

function Test-TunnelHealth {
    return [bool](Get-TunnelLocalProbe -Path '/healthz' -TimeoutSeconds 3).Ok
}

function Test-TunnelReady {
    return [bool](Get-TunnelLocalProbe -Path '/readyz' -TimeoutSeconds 3).Ok
}

function Wait-TunnelReady {
    param([int]$TimeoutSeconds = 60)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-TunnelReady) {
            return $true
        }
        Start-Sleep -Seconds 1
    }

    return $false
}

function Stop-TunnelTaskIfRunning {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

    if ($task -and $task.State -eq 'Running') {
        Write-Fix 'Stopping currently running tunnel task before validation/reconfiguration.'
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

        $deadline = (Get-Date).AddSeconds(15)
        do {
            Start-Sleep -Milliseconds 500
            $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        } while ($task -and $task.State -eq 'Running' -and (Get-Date) -lt $deadline)
    }
}

function Show-Stage {
    param(
        [Parameter(Mandatory=$true)][int]$Number,
        [Parameter(Mandatory=$true)][string]$Text
    )

    $pct = [math]::Floor((($Number - 1) / $TotalStages) * 100)
    Write-Progress -Id 1 -Activity 'MediaStack Control Gateway installation' -Status "[$Number/$TotalStages] $Text" -PercentComplete $pct
    Write-Host ""
    Write-Host "=== [$Number/$TotalStages] $Text ===" -ForegroundColor Cyan
}

function Write-Good {
    param([Parameter(Mandatory=$true)][string]$Text)
    Write-Host "OK  : $Text" -ForegroundColor Green
}

function Write-Skip {
    param([Parameter(Mandatory=$true)][string]$Text)
    Write-Host "SKIP: $Text" -ForegroundColor Green
}

function Write-Fix {
    param([Parameter(Mandatory=$true)][string]$Text)
    # A corrective action is informational, not a warning.
    Write-Host "INFO: $Text" -ForegroundColor Cyan
}

function Assert-ExitCode {
    param([Parameter(Mandatory=$true)][string]$Message)
    if ($LASTEXITCODE -ne 0) {
        throw "$Message Exit code: $LASTEXITCODE"
    }
}

function Invoke-NativeCaptured {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][string[]]$ArgumentList,
        [string]$Label = 'native-command'
    )

    $stdoutFile = Join-Path $env:TEMP ("MediaStack-Control-Gateway-" + [Guid]::NewGuid().ToString('N') + ".out")
    $stderrFile = Join-Path $env:TEMP ("MediaStack-Control-Gateway-" + [Guid]::NewGuid().ToString('N') + ".err")

    $oldErrorActionPreference = $ErrorActionPreference

    try {
        # IMPORTANT:
        # Use PowerShell's native invocation operator so each array element remains
        # a distinct process argument. Start-Process -ArgumentList on Windows
        # PowerShell 5.1 joins the array into one command-line string, which breaks
        # complex Python `-c` expressions unless manually re-quoted.
        #
        # Native programs legitimately use stderr. Temporarily use Continue so
        # Windows PowerShell 5.1 does not promote native stderr to a terminating
        # NativeCommandError while the installer itself uses Stop globally.
        $ErrorActionPreference = 'Continue'

        & $FilePath @ArgumentList 1> $stdoutFile 2> $stderrFile
        $exitCode = $LASTEXITCODE

        $stdout = ''
        $stderr = ''

        if (Test-Path -LiteralPath $stdoutFile) {
            $stdout = Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $stderrFile) {
            $stderr = Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue
        }

        return [pscustomobject]@{
            Label    = $Label
            ExitCode = $exitCode
            StdOut   = $stdout
            StdErr   = $stderr
        }
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
        Remove-Item -LiteralPath $stdoutFile -Force -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrFile -Force -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Set-SecureAcl {
    param([Parameter(Mandatory=$true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    # These files can contain embedded credentials, so keep them restricted to
    # SYSTEM, local Administrators, and the Windows account running this installer.
    # Previous versions granted only SYSTEM + Administrators. With UAC, that could
    # make the files appear read-only when the same admin user opened an editor
    # without elevation. Granting the invoking user's SID Full Control keeps the
    # files private while still allowing that user to edit the PS1/Python files.
    try {
        $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $currentUserSid = $currentIdentity.User.Value
        $currentUserGrant = '*{0}:(F)' -f $currentUserSid

        & icacls.exe $Path /inheritance:r /grant:r `
            '*S-1-5-18:(F)' `
            '*S-1-5-32-544:(F)' `
            $currentUserGrant | Out-Null

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Could not set editable secure ACL on $Path"
        }
    }
    catch {
        Write-Warning "Could not set editable secure ACL on $Path : $($_.Exception.Message)"
    }

    # Clear a filesystem ReadOnly attribute and Mark-of-the-Web if present.
    # Neither is required for security once the NTFS ACL above is in place.
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -and ($item.Attributes -band [System.IO.FileAttributes]::ReadOnly)) {
            $item.IsReadOnly = $false
        }
    }
    catch {
        Write-Warning "Could not clear ReadOnly attribute on $Path"
    }

    try {
        Unblock-File -LiteralPath $Path -ErrorAction SilentlyContinue
    }
    catch {
    }
}

function Set-ContentIfChanged {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Content
    )

    $existing = $null
    if (Test-Path -LiteralPath $Path) {
        $existing = Get-Content -LiteralPath $Path -Raw
    }

    if ($existing -eq $Content) {
        Write-Skip "$Path is already current."
        return $false
    }

    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
    Write-Fix "Updated $Path"
    return $true
}

function Get-PythonVersion {
    if (-not (Test-Path -LiteralPath $PythonExe)) {
        return $null
    }

    try {
        $result = Invoke-NativeCaptured `
            -FilePath $PythonExe `
            -ArgumentList @('-c', "import sys; print('.'.join(map(str, sys.version_info[:3])))") `
            -Label 'python-version'

        if ($result.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($result.StdOut)) {
            return $result.StdOut.Trim()
        }
    }
    catch {
        return $null
    }

    return $null
}

function Test-PythonPip {
    if (-not (Test-Path -LiteralPath $PythonExe)) {
        return $false
    }

    $result = Invoke-NativeCaptured `
        -FilePath $PythonExe `
        -ArgumentList @('-m', 'pip', '--version') `
        -Label 'python-pip-test'

    return ($result.ExitCode -eq 0)
}

function Test-PythonPackages {
    if (-not (Test-Path -LiteralPath $PythonExe)) {
        return $false
    }

    # Do NOT invoke python.exe directly here. Windows PowerShell 5.1 converts
    # native stderr into NativeCommandError records, which become terminating
    # errors while $ErrorActionPreference is Stop.
    $code = "import importlib.metadata as md; import plexapi; from mcp.server import MCPServer; major=int(md.version('mcp').split('.')[0]); raise SystemExit(0 if major >= 2 else 1)"
    $result = Invoke-NativeCaptured `
        -FilePath $PythonExe `
        -ArgumentList @('-c', $code) `
        -Label 'python-package-test'

    return ($result.ExitCode -eq 0)
}

function Test-TunnelClient {
    if (-not (Test-Path -LiteralPath $TunnelExe)) {
        return $false
    }

    try {
        & $TunnelExe --version *> $null
        return ($LASTEXITCODE -eq 0)
    }
    catch {
        return $false
    }
}

Write-Host "MediaStack Control Gateway installer for Windows Server - v3.4.10 WATCHDOG + LOG ROTATION / TUNNEL DIAGNOSTICS / ARR STATUS + COLORING / INSTALLER LOGGING / HUB CACHE REFRESH / ADDED AT METADATA / EPISODE METADATA / ITEM POSTER METADATA / ITEM SUMMARY METADATA / ARR MANAGEMENT / TAUTULLI REPORTING / COLLECTION METADATA / SELF-HEALING TUNNEL / IDEMPOTENT" -ForegroundColor Green
Write-Host "Safe to run repeatedly. Existing working components are skipped." -ForegroundColor Green
Write-Host "Installer log: $InstallerLog" -ForegroundColor Green
Write-Host "HARD NONINTERACTIVE MODE: all PowerShell confirmation prompts are suppressed." -ForegroundColor Green
Write-Host "Working root: $Root" -ForegroundColor Green

# ===========================================================================
# 1. Validate configuration and prepare directories
# ===========================================================================
Show-Stage 1 'Validate configuration and prepare directories'

function Assert-ConfiguredValue {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [AllowEmptyString()][string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -match '^<REQUIRED:') {
        throw "Configuration field '$Name' has not been configured. Edit $ConfigPath and replace its placeholder value."
    }
}

foreach ($required in @(
    @{ Name = 'TunnelId'; Value = $TunnelId },
    @{ Name = 'OpenAiRuntimeKey'; Value = $OpenAiRuntimeKey },
    @{ Name = 'PlexUrl'; Value = $PlexUrl },
    @{ Name = 'PlexToken'; Value = $PlexToken },
    @{ Name = 'TautulliUrl'; Value = $TautulliUrl },
    @{ Name = 'TautulliApiKey'; Value = $TautulliApiKey },
    @{ Name = 'SonarrUrl'; Value = $SonarrUrl },
    @{ Name = 'SonarrApiKey'; Value = $SonarrApiKey },
    @{ Name = 'RadarrUrl'; Value = $RadarrUrl },
    @{ Name = 'RadarrApiKey'; Value = $RadarrApiKey },
    @{ Name = 'LidarrUrl'; Value = $LidarrUrl },
    @{ Name = 'LidarrApiKey'; Value = $LidarrApiKey }
)) {
    Assert-ConfiguredValue -Name $required.Name -Value $required.Value
}

if ($TunnelId -notmatch '^tunnel_[A-Za-z0-9]+$') {
    throw "Configuration field 'TunnelId' is not a valid OpenAI tunnel ID."
}

foreach ($service in @(
    @{ Name = 'PlexUrl'; Value = $PlexUrl },
    @{ Name = 'TautulliUrl'; Value = $TautulliUrl },
    @{ Name = 'SonarrUrl'; Value = $SonarrUrl },
    @{ Name = 'RadarrUrl'; Value = $RadarrUrl },
    @{ Name = 'LidarrUrl'; Value = $LidarrUrl }
)) {
    $parsedUri = $null
    if (-not [Uri]::TryCreate($service.Value, [UriKind]::Absolute, [ref]$parsedUri) -or $parsedUri.Scheme -notin @('http', 'https')) {
        throw "Configuration field '$($service.Name)' must be an absolute http:// or https:// URL."
    }
}

foreach ($dir in @($Root, $BinDir, $DownloadDir, $ProfileDir, $LogDir, $ReportingExportDir)) {
    if (Test-Path -LiteralPath $dir) {
        Write-Skip "$dir already exists."
    }
    else {
        New-Item -ItemType Directory -Path $dir -Force -Confirm:$false | Out-Null
        Write-Fix "Created $dir"
    }
}

# Restrict the local configuration because it contains credentials.
Set-SecureAcl -Path $ConfigPath
Set-SecureAcl -Path $ReportingExportDir

# ===========================================================================
# 2. Install/reuse OpenAI tunnel-client
# ===========================================================================
Show-Stage 2 'Install or reuse OpenAI tunnel-client'

if (Test-TunnelClient) {
    $tunnelVersion = (& $TunnelExe --version 2>$null | Select-Object -First 1)
    Write-Skip "Working tunnel-client already installed. $tunnelVersion"
}
else {
    Write-Fix 'Working tunnel-client not found. Downloading current official release.'

    $arch = $env:PROCESSOR_ARCHITECTURE
    switch ($arch) {
        'AMD64' { $platformName = 'windows-amd64' }
        'ARM64' { $platformName = 'windows-arm64' }
        default { throw "Unsupported Windows architecture: $arch" }
    }

    # First look for a FULL client archive already placed in C:\Scripts.
    # Explicitly exclude runtime-only archives.
    $localCandidates = @(
        Get-ChildItem -LiteralPath 'C:\Scripts' -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -match '^tunnel-client-v[0-9].*-windows-(amd64|arm64)\.zip$' -and
                $_.Name -notmatch '^tunnel-client-runtime-'
            } |
            Sort-Object LastWriteTime -Descending
    )

    $localFullZip = $localCandidates |
        Where-Object { $_.Name -like "*-$platformName.zip" } |
        Select-Object -First 1

    Write-Progress -Id 2 -ParentId 1 -Activity 'OpenAI tunnel-client' -Status 'Querying GitHub release metadata...' -PercentComplete 10

    if ($localFullZip) {
        Write-Skip "Found cached FULL tunnel-client archive in C:\Scripts: $($localFullZip.Name)"

        if ($localFullZip.Name -notmatch '^tunnel-client-(v[0-9][^-]*)-windows-(amd64|arm64)\.zip$') {
            throw "Could not parse version from cached tunnel archive '$($localFullZip.Name)'."
        }

        $localTag = $Matches[1]
        $release = Invoke-RestMethod -UseBasicParsing -Headers @{ 'User-Agent' = 'MediaStack-Control-Gateway-Installer' } -Uri "https://api.github.com/repos/openai/tunnel-client/releases/tags/$localTag"
    }
    else {
        $release = Invoke-RestMethod -UseBasicParsing -Headers @{ 'User-Agent' = 'MediaStack-Control-Gateway-Installer' } -Uri 'https://api.github.com/repos/openai/tunnel-client/releases/latest'
    }

    # IMPORTANT: v0.0.12+ publishes three similarly named Windows archives:
    #   tunnel-client-...
    #   tunnel-client-runtime-...
    #   tunnel-client-runtime-cloudflared-...
    # Only the FULL client implements init/profile management. Select its exact name.
    $expectedAssetName = "tunnel-client-$($release.tag_name)-$platformName.zip"
    $asset = $release.assets | Where-Object { $_.name -eq $expectedAssetName } | Select-Object -First 1

    if (-not $asset) {
        $available = ($release.assets | ForEach-Object { $_.name } | Sort-Object) -join "`r`n  "
        throw "Could not find the required FULL tunnel-client archive '$expectedAssetName'. Available release assets were:`r`n  $available"
    }

    if ($asset.name -like 'tunnel-client-runtime-*') {
        throw "Refusing runtime-only archive '$($asset.name)'. The installer requires the full tunnel-client archive."
    }

    # Prefer the manually cached full copy in C:\Scripts so repeated runs do not redownload it.
    if ($localFullZip -and $localFullZip.Name -eq $asset.name) {
        $localCachedZip = $localFullZip.FullName
    }
    else {
        $localCachedZip = Join-Path 'C:\Scripts' $asset.name
    }

    $downloadedZip = Join-Path $DownloadDir $asset.name

    if (Test-Path -LiteralPath $localCachedZip) {
        $zipPath = $localCachedZip
        Write-Skip "Using cached full tunnel-client archive: $localCachedZip"
    }
    elseif (Test-Path -LiteralPath $downloadedZip) {
        $zipPath = $downloadedZip
        Write-Skip "Using previously downloaded full tunnel-client archive: $downloadedZip"
    }
    else {
        $zipPath = $downloadedZip
        Write-Host "Downloading FULL OpenAI tunnel-client archive: $($asset.name)..."
        Write-Progress -Id 2 -ParentId 1 -Activity 'OpenAI tunnel-client' -Status 'Downloading release...' -PercentComplete 35
        Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -OutFile $zipPath
    }

    if ($asset.PSObject.Properties.Name -contains 'digest' -and $asset.digest -and $asset.digest -match '^sha256:(.+)$') {
        $expected = $Matches[1].ToLowerInvariant()
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            throw "Tunnel-client SHA256 verification failed for $zipPath."
        }
        Write-Good 'SHA256 verification passed.'
    }

    $extractDir = Join-Path $DownloadDir 'tunnel-client-extracted'
    if (Test-Path -LiteralPath $extractDir) {
        Remove-Item -LiteralPath $extractDir -Recurse -Force -Confirm:$false
    }
    New-Item -ItemType Directory -Path $extractDir -Force -Confirm:$false | Out-Null

    Write-Progress -Id 2 -ParentId 1 -Activity 'OpenAI tunnel-client' -Status 'Extracting release...' -PercentComplete 70
    Expand-ZipNoPrompt -Source $zipPath -Destination $extractDir -CleanDestination

    $downloadedTunnel = Get-ChildItem -Path $extractDir -Filter 'tunnel-client.exe' -Recurse | Select-Object -First 1
    if (-not $downloadedTunnel) {
        $archiveContents = (Get-ChildItem -Path $extractDir -File -Recurse | ForEach-Object { $_.FullName.Substring($extractDir.Length).TrimStart('\') }) -join ', '
        throw "The FULL OpenAI archive '$($asset.name)' did not contain tunnel-client.exe. Extracted files: $archiveContents"
    }

    Copy-Item -LiteralPath $downloadedTunnel.FullName -Destination $TunnelExe -Force -Confirm:$false

    $downloadedCloudflared = Get-ChildItem -Path $extractDir -Filter 'cloudflared.exe' -Recurse | Select-Object -First 1
    if ($downloadedCloudflared) {
        Copy-Item -LiteralPath $downloadedCloudflared.FullName -Destination $CloudflaredExe -Force -Confirm:$false
    }

    if (-not (Test-TunnelClient)) {
        throw 'tunnel-client.exe was installed but does not execute successfully.'
    }

    Write-Progress -Id 2 -ParentId 1 -Activity 'OpenAI tunnel-client' -Status 'Installed' -PercentComplete 100 -Completed
}

# ===========================================================================
# 3. Install/reuse application-local Python from official CPython NuGet package
# ===========================================================================
Show-Stage 3 'Install or reuse portable Python 3.12 from official NuGet package'

$pythonVersion = Get-PythonVersion

if ($pythonVersion -eq $PythonPackageVersion -and (Test-PythonPip)) {
    Write-Skip "Portable Python $pythonVersion with pip is already working at $PythonExe"
}
else {
    if (Test-Path -LiteralPath $PythonDir) {
        Write-Fix 'Portable Python directory exists but is incomplete/stale. Removing only the managed portable Python directory.'
        Remove-Item -LiteralPath $PythonDir -Recurse -Force -Confirm:$false
    }

    New-Item -ItemType Directory -Path $PythonDir -Force -Confirm:$false | Out-Null

    # NuGet packages are ZIP-format archives. Look for a local cached copy first.
    $localPythonCandidates = @(
        "C:\Scripts\python.$PythonPackageVersion.nupkg",
        "C:\Scripts\python.$PythonPackageVersion.zip",
        "C:\Scripts\python-$PythonPackageVersion.nupkg",
        "C:\Scripts\python-$PythonPackageVersion.zip"
    )

    $pythonPackage = $null
    foreach ($candidate in $localPythonCandidates) {
        if (Test-Path -LiteralPath $candidate) {
            $pythonPackage = $candidate
            break
        }
    }

    if ($pythonPackage) {
        Write-Skip "Using cached CPython NuGet package: $pythonPackage"
    }
    else {
        $pythonPackage = Join-Path $DownloadDir "python.$PythonPackageVersion.zip"
        if (Test-Path -LiteralPath $pythonPackage) {
            Write-Skip "Using previously downloaded CPython NuGet package: $pythonPackage"
        }
        else {
            $nugetUrl = "https://www.nuget.org/api/v2/package/python/$PythonPackageVersion"
            Write-Fix "Downloading official CPython NuGet package $PythonPackageVersion..."
            Write-Progress -Id 3 -ParentId 1 -Activity 'Portable Python' -Status 'Downloading official CPython NuGet package...' -PercentComplete 30
            Invoke-WebRequest -UseBasicParsing -Uri $nugetUrl -OutFile $pythonPackage
        }
    }

    # Expand-Archive expects ZIP-like input. .nupkg is ZIP format, so copy it to
    # a temporary .zip name only when needed.
    $expandSource = $pythonPackage
    $temporaryZip = $null

    if ([System.IO.Path]::GetExtension($pythonPackage) -ine '.zip') {
        $temporaryZip = Join-Path $DownloadDir "python.$PythonPackageVersion.expand.zip"
        Copy-Item -LiteralPath $pythonPackage -Destination $temporaryZip -Force -Confirm:$false
        $expandSource = $temporaryZip
    }

    try {
        Write-Progress -Id 3 -ParentId 1 -Activity 'Portable Python' -Status 'Extracting package...' -PercentComplete 65
        Expand-ZipNoPrompt -Source $expandSource -Destination $PythonDir -CleanDestination
    }
    finally {
        if ($temporaryZip -and (Test-Path -LiteralPath $temporaryZip)) {
            Remove-Item -LiteralPath $temporaryZip -Force -Confirm:$false -ErrorAction SilentlyContinue
        }
    }

    if (-not (Test-Path -LiteralPath $PythonExe)) {
        $foundFiles = ''
        if (Test-Path -LiteralPath $PythonDir) {
            $foundFiles = (Get-ChildItem -LiteralPath $PythonDir -File -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 30 |
                ForEach-Object { $_.FullName }) -join "`r`n"
        }
        throw "Portable Python package extracted, but python.exe was not found at $PythonExe.`r`nFiles found:`r`n$foundFiles"
    }

    $pythonVersion = Get-PythonVersion
    if (-not $pythonVersion) {
        $directTest = Invoke-NativeCaptured `
            -FilePath $PythonExe `
            -ArgumentList @('--version') `
            -Label 'python-direct-version-test'
        throw "python.exe exists at $PythonExe but could not be executed successfully.`r`nExitCode: $($directTest.ExitCode)`r`nSTDOUT:`r`n$($directTest.StdOut)`r`nSTDERR:`r`n$($directTest.StdErr)"
    }

    if ($pythonVersion -ne $PythonPackageVersion) {
        throw "Portable Python executed successfully, but returned version $pythonVersion instead of expected $PythonPackageVersion."
    }

    if (-not (Test-PythonPip)) {
        throw "Portable Python $pythonVersion is present at $PythonExe, but 'python -m pip' is not available. The official NuGet package should contain pip."
    }

    Write-Good "Portable Python ready: $pythonVersion at $PythonExe"
    Write-Skip "Verified executable directly: $PythonExe"
    Write-Progress -Id 3 -ParentId 1 -Activity 'Portable Python' -Status 'Ready' -PercentComplete 100 -Completed
}

# ===========================================================================
# 4. Install/reuse MCP and PlexAPI Python packages
# ===========================================================================
Show-Stage 4 'Install or reuse Python MCP and PlexAPI packages'

if (Test-PythonPackages) {
    $versionResult = Invoke-NativeCaptured `
        -FilePath $PythonExe `
        -ArgumentList @('-c', "import importlib.metadata as md; print('mcp=' + md.version('mcp') + ', plexapi=' + md.version('plexapi'))") `
        -Label 'python-package-versions'
    $packageVersions = $versionResult.StdOut.Trim()
    Write-Skip "Required Python packages are already installed and import correctly ($packageVersions)."
}
else {
    Write-Fix 'Required Python packages are missing or stale. Installing/upgrading them.'

    $pipUpgrade = Invoke-NativeCaptured `
        -FilePath $PythonExe `
        -ArgumentList @('-m', 'pip', 'install', '--disable-pip-version-check', '--no-input', '--upgrade', 'pip') `
        -Label 'pip-upgrade'
    if ($pipUpgrade.ExitCode -ne 0) {
        throw "pip self-update failed.`r`nSTDOUT:`r`n$($pipUpgrade.StdOut)`r`nSTDERR:`r`n$($pipUpgrade.StdErr)"
    }
    if (-not [string]::IsNullOrWhiteSpace($pipUpgrade.StdOut)) {
        Write-Host $pipUpgrade.StdOut.Trim()
    }

    $packageInstall = Invoke-NativeCaptured `
        -FilePath $PythonExe `
        -ArgumentList @('-m', 'pip', 'install', '--disable-pip-version-check', '--no-input', '--upgrade', 'mcp[cli]>=2,<3', 'plexapi') `
        -Label 'pip-packages'
    if ($packageInstall.ExitCode -ne 0) {
        throw "Python package installation failed.`r`nSTDOUT:`r`n$($packageInstall.StdOut)`r`nSTDERR:`r`n$($packageInstall.StdErr)"
    }
    if (-not [string]::IsNullOrWhiteSpace($packageInstall.StdOut)) {
        Write-Host $packageInstall.StdOut.Trim()
    }

    if (-not (Test-PythonPackages)) {
        $diagnostic = Invoke-NativeCaptured `
            -FilePath $PythonExe `
            -ArgumentList @('-c', "import sys; print(sys.version); import plexapi; from mcp.server import MCPServer; print('MCP v2 and PlexAPI imports OK')") `
            -Label 'python-package-diagnostic'
        throw "Python packages installed but MCP/PlexAPI import validation still fails.`r`nSTDOUT:`r`n$($diagnostic.StdOut)`r`nSTDERR:`r`n$($diagnostic.StdErr)"
    }
}

# ===========================================================================
# 5. Create/update MediaStack Control Gateway MCP server
# ===========================================================================
Show-Stage 5 'Create or update MediaStack Control Gateway MCP server'

$pythonServer = @'
import base64
import csv
import json
import logging
import os
import re
import secrets
import time
import uuid
from datetime import datetime
from pathlib import Path
from typing import Optional
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


from mcp.server import MCPServer
from mcp.types import ToolAnnotations
from plexapi.server import PlexServer
from plexapi.playlist import Playlist

PLEX_URL = "__PLEX_URL__"
PLEX_TOKEN = "__PLEX_TOKEN__"
TAUTULLI_URL = "__TAUTULLI_URL__"
TAUTULLI_API_KEY = "__TAUTULLI_API_KEY__"
SONARR_URL = "__SONARR_URL__"
SONARR_API_KEY = "__SONARR_API_KEY__"
RADARR_URL = "__RADARR_URL__"
RADARR_API_KEY = "__RADARR_API_KEY__"
LIDARR_URL = "__LIDARR_URL__"
LIDARR_API_KEY = "__LIDARR_API_KEY__"
REPORT_EXPORT_DIR = "__REPORT_EXPORT_DIR__"
TUNNEL_RUNTIME_LOG = "__TUNNEL_RUNTIME_LOG__"
TUNNEL_HEALTH_URL_FILE = "__TUNNEL_HEALTH_URL_FILE__"

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("media-stack-control-gateway")

mcp = MCPServer(
    "Plex",
    instructions=(
        "Tools for visibility across all Plex libraries and collections, regular collection "
        "management, collection metadata management, individual movie/show summary and poster metadata management, movie/show/season/episode added-at metadata management, non-destructive Plex transient-hub refresh and Recently Added verification, individual TV episode metadata management, read-only tunnel timing/runtime diagnostics, smart collection filter management, narrowly "
        "scoped TV episode playlist creation, Tautulli-backed reporting, and Sonarr/Radarr/Lidarr management. "
        "Use plex_reporting_* for Plex analytics and arr_*/sonarr_*/radarr_*/lidarr_* for Arr reporting and management. "
        "Large datasets should be processed locally and summarized before crossing the tunnel. Resolve exact items with read tools "
        "before writes. New media requests must use an explicitly selected root folder/profile and must never guess a storage path. "
        "Ordinary non-delete bulk writes may execute when the user instruction is explicit. Every Arr deletion must first use "
        "arr_prepare_delete and arr_confirm_delete must only be called after the user explicitly confirms the exact prepared deletion, "
        "including whether physical media files are to be deleted. Plex collection operations never delete underlying media files."
    ),
)


def _plex() -> PlexServer:
    return PlexServer(PLEX_URL, PLEX_TOKEN, timeout=20)


def _sections(server: PlexServer):
    return list(server.library.sections())


def _tv_sections(server: PlexServer):
    return [section for section in _sections(server) if getattr(section, "type", None) == "show"]


def _find_sections(server: PlexServer, library_name: Optional[str] = None):
    sections = _sections(server)
    if library_name is None:
        return sections

    needle = library_name.casefold()
    return [section for section in sections if section.title.casefold() == needle]


def _item_summary(item, library_name: Optional[str] = None) -> dict:
    item_type = getattr(item, "TYPE", None) or item.__class__.__name__.lower()

    result = {
        "type": item_type,
        "title": getattr(item, "title", None),
        "year": getattr(item, "year", None),
        "rating_key": str(getattr(item, "ratingKey", "")) or None,
        "library": library_name,
    }

    # These fields make generic results useful for episodes, tracks, albums, etc.
    for source_name, output_name in (
        ("parentTitle", "parent_title"),
        ("grandparentTitle", "grandparent_title"),
        ("parentIndex", "parent_index"),
        ("index", "index"),
        ("originallyAvailableAt", "originally_available_at"),
        ("addedAt", "added_at"),
    ):
        value = getattr(item, source_name, None)
        if value is not None:
            if source_name in {"originallyAvailableAt", "addedAt"} and hasattr(value, "isoformat"):
                value = value.isoformat()
            result[output_name] = value

    return result



def _exact_section(server: PlexServer, library_name: str):
    matches = _find_sections(server, library_name)
    if not matches:
        raise ValueError(f"Library not found: {library_name}")
    if len(matches) != 1:
        raise ValueError(f"Library name is ambiguous: {library_name}")
    return matches[0]


def _exact_collection(section, collection_title: str):
    matches = [
        collection
        for collection in section.collections()
        if collection.title.casefold() == collection_title.casefold()
    ]

    if not matches:
        raise ValueError(
            f"Collection '{collection_title}' was not found in library '{section.title}'."
        )
    if len(matches) != 1:
        raise ValueError(
            f"Collection '{collection_title}' is ambiguous in library '{section.title}'."
        )

    return matches[0]


def _collection_exists(section, collection_title: str) -> bool:
    return any(
        collection.title.casefold() == collection_title.casefold()
        for collection in section.collections()
    )


def _load_rating_key_items(
    server: PlexServer,
    section,
    rating_keys: list[str],
    require_same_type: bool = True,
) -> list:
    if not rating_keys:
        raise ValueError("At least one Plex rating key is required.")

    normalized = []
    for raw_key in rating_keys:
        try:
            normalized.append(int(str(raw_key).strip()))
        except Exception as exc:
            raise ValueError(f"Invalid Plex rating key: {raw_key}") from exc

    items = []
    missing = []

    for key in normalized:
        try:
            item = server.fetchItem(key)
        except Exception:
            missing.append(str(key))
            continue

        item_section_id = getattr(item, "librarySectionID", None)
        if item_section_id is None:
            try:
                item_section_id = item.section().key
            except Exception:
                item_section_id = None

        if str(item_section_id) != str(section.key):
            raise ValueError(
                f"Rating key {key} belongs to a different Plex library, not '{section.title}'."
            )

        items.append(item)

    if missing:
        raise ValueError(f"These Plex rating keys could not be found: {', '.join(missing)}")

    item_types = {getattr(item, "type", None) for item in items}
    if require_same_type and len(item_types) != 1:
        raise ValueError(
            "A regular Plex collection cannot mix different media item types in one collection."
        )

    return items


def _parse_filters_json(filters_json: str) -> dict:
    if filters_json is None or not str(filters_json).strip():
        return {}

    try:
        parsed = json.loads(filters_json)
    except json.JSONDecodeError as exc:
        raise ValueError(f"Smart filter JSON is invalid: {exc}") from exc

    if not isinstance(parsed, dict):
        raise ValueError("Smart filter JSON must describe a JSON object/dictionary.")

    return parsed


def _smart_collection_summary(collection) -> dict:
    result = {
        "title": collection.title,
        "library": getattr(collection, "librarySectionTitle", None),
        "smart": bool(getattr(collection, "smart", False)),
        "subtype": getattr(collection, "subtype", None),
        "rating_key": str(getattr(collection, "ratingKey", "")) or None,
        "content": getattr(collection, "content", None),
    }

    if getattr(collection, "smart", False):
        try:
            result["filters"] = collection.filters()
        except Exception as exc:
            result["filters_error"] = str(exc)

    return result


_COLLECTION_MODE_NAMES = {
    -1: "default",
    0: "hide",
    1: "hideItems",
    2: "showItems",
}

_COLLECTION_SORT_NAMES = {
    0: "release",
    1: "alpha",
    2: "custom",
}

_COLLECTION_FILTER_USER_NAMES = {
    0: "admin",
    1: "user",
}


def _iso_or_none(value):
    if value is None:
        return None
    if hasattr(value, "isoformat"):
        return value.isoformat()
    return value


def _label_names(collection) -> list[str]:
    try:
        return [
            getattr(label, "tag", None)
            for label in collection.labels
            if getattr(label, "tag", None)
        ]
    except Exception:
        return []


def _field_lock_states(collection) -> dict:
    locks = {}
    try:
        for field in collection.fields:
            name = getattr(field, "name", None)
            if name:
                locks[name] = bool(getattr(field, "locked", False))
    except Exception:
        pass
    return locks


def _collection_metadata(collection, section, include_visibility: bool = True) -> dict:
    # section.collections() may return partial objects. Reload the exact collection
    # so fields such as summary, labels, art and advanced settings are authoritative.
    collection.reload()

    item_count = getattr(collection, "childCount", None)
    if item_count is None:
        item_count = getattr(collection, "leafCount", None)

    mode_value = getattr(collection, "collectionMode", None)
    sort_value = getattr(collection, "collectionSort", None)
    filter_user_value = getattr(collection, "collectionFilterBasedOnUser", None)

    result = {
        "title": collection.title,
        "title_sort": getattr(collection, "titleSort", collection.title),
        "summary": getattr(collection, "summary", None),
        "summary_missing": not bool((getattr(collection, "summary", None) or "").strip()),
        "library": section.title,
        "library_type": getattr(section, "type", None),
        "smart": bool(getattr(collection, "smart", False)),
        "subtype": getattr(collection, "subtype", None),
        "item_count": item_count,
        "rating_key": str(getattr(collection, "ratingKey", "")) or None,
        "guid": getattr(collection, "guid", None),
        "thumb": getattr(collection, "thumb", None),
        "art": getattr(collection, "art", None),
        "content_rating": getattr(collection, "contentRating", None),
        "labels": _label_names(collection),
        "collection_mode": _COLLECTION_MODE_NAMES.get(mode_value, mode_value),
        "collection_mode_raw": mode_value,
        "collection_sort": _COLLECTION_SORT_NAMES.get(sort_value, sort_value),
        "collection_sort_raw": sort_value,
        "collection_published": bool(getattr(collection, "collectionPublished", False)),
        "filter_based_on_user": _COLLECTION_FILTER_USER_NAMES.get(filter_user_value, filter_user_value),
        "added_at": _iso_or_none(getattr(collection, "addedAt", None)),
        "updated_at": _iso_or_none(getattr(collection, "updatedAt", None)),
        "min_year": getattr(collection, "minYear", None),
        "max_year": getattr(collection, "maxYear", None),
        "field_locks": _field_lock_states(collection),
    }

    if getattr(collection, "smart", False):
        result["content"] = getattr(collection, "content", None)
        try:
            result["filters"] = collection.filters()
        except Exception as exc:
            result["filters_error"] = str(exc)

    if include_visibility:
        try:
            hub = collection.visibility()
            result["visibility"] = {
                "promoted_to_recommended": bool(getattr(hub, "promotedToRecommended", False)),
                "promoted_to_own_home": bool(getattr(hub, "promotedToOwnHome", False)),
                "promoted_to_shared_home": bool(getattr(hub, "promotedToSharedHome", False)),
                "recommendations_visibility": getattr(hub, "recommendationsVisibility", None),
                "home_visibility": getattr(hub, "homeVisibility", None),
            }
        except Exception as exc:
            result["visibility_error"] = str(exc)

    return result


def _normalize_labels(labels: list[str]) -> list[str]:
    normalized = []
    seen = set()
    for raw in labels:
        value = str(raw).strip()
        if not value:
            continue
        key = value.casefold()
        if key in seen:
            continue
        seen.add(key)
        normalized.append(value)
    return normalized


def _validate_image_source(image_url: Optional[str], local_filepath: Optional[str]) -> tuple[Optional[str], Optional[str]]:
    has_url = bool(image_url and str(image_url).strip())
    has_file = bool(local_filepath and str(local_filepath).strip())

    if has_url == has_file:
        raise ValueError("Provide exactly one image source: image_url or local_filepath.")

    if has_url:
        image_url = str(image_url).strip()
        if not image_url.lower().startswith(("http://", "https://")):
            raise ValueError("image_url must begin with http:// or https://")
        return image_url, None

    local_filepath = os.path.abspath(str(local_filepath).strip())
    if not os.path.isfile(local_filepath):
        raise ValueError(f"Local image file was not found on the Plex server: {local_filepath}")

    allowed_extensions = {".jpg", ".jpeg", ".png", ".webp"}
    extension = os.path.splitext(local_filepath)[1].lower()
    if extension not in allowed_extensions:
        raise ValueError(
            "Local artwork must be a .jpg, .jpeg, .png, or .webp image."
        )

    return None, local_filepath


@mcp.tool(
    description="Return Plex server status and all Plex library sections.",
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def plex_status() -> dict:
    server = _plex()
    sections = _sections(server)
    return {
        "server_name": server.friendlyName,
        "version": server.version,
        "machine_identifier": server.machineIdentifier,
        "libraries": [
            {
                "title": section.title,
                "type": getattr(section, "type", None),
                "key": str(getattr(section, "key", "")) or None,
                "uuid": getattr(section, "uuid", None),
            }
            for section in sections
        ],
        "tv_libraries": [section.title for section in sections if getattr(section, "type", None) == "show"],
    }


def _redact_tunnel_log_line(line: str) -> str:
    text = str(line or "")
    text = re.sub(r"sk-[A-Za-z0-9_-]{12,}", "sk-[REDACTED]", text)
    text = re.sub(
        r"(?i)((?:authorization|api[_-]?key|token)[\"'\s:=]+)([^\"'\s,}]+)",
        lambda m: m.group(1) + "[REDACTED]",
        text,
    )
    return text[:2000]


def _local_tunnel_probe(path: str, timeout: int = 3) -> dict:
    if not os.path.isfile(TUNNEL_HEALTH_URL_FILE):
        return {"available": False, "error": "Tunnel health endpoint file does not exist."}
    try:
        base = Path(TUNNEL_HEALTH_URL_FILE).read_text(encoding="utf-8-sig").strip().rstrip("/")
    except Exception as exc:
        return {"available": False, "error": f"Could not read tunnel health endpoint file: {exc}"}
    if not re.match(r"^http://127\.0\.0\.1:\d+$", base):
        return {"available": False, "error": "Tunnel health endpoint file did not contain a valid loopback URL."}
    try:
        with urlopen(Request(base + path, headers={"User-Agent": "MediaStack-Control-Gateway-Diagnostics/3.4.10"}), timeout=timeout) as response:
            raw = response.read(4096).decode("utf-8", errors="replace")
            return {"available": True, "status_code": int(response.status), "body": raw[:1000]}
    except HTTPError as exc:
        try:
            body = exc.read(4096).decode("utf-8", errors="replace")
        except Exception:
            body = ""
        return {"available": True, "status_code": int(exc.code), "body": body[:1000], "error": str(exc.reason)}
    except Exception as exc:
        return {"available": False, "error": str(exc)}


@mcp.tool(
    description=(
        "Read-only tunnel timing diagnostic. Sleeps locally inside the MCP tool for the requested number of seconds "
        "and then returns the measured elapsed time. It does not contact or modify Plex. Use controlled values to "
        "measure the effective ChatGPT/tunnel command-response deadline; if the outer gateway times out first, this "
        "tool may return a gateway error instead of a result. Delay is capped at 120 seconds."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def plex_tunnel_delay_test(delay_seconds: int = 5) -> dict:
    seconds = max(0, min(int(delay_seconds), 120))
    started_wall = datetime.now().astimezone().isoformat()
    started = time.monotonic()
    time.sleep(seconds)
    elapsed = time.monotonic() - started
    return {
        "completed": True,
        "requested_seconds": seconds,
        "elapsed_seconds": round(elapsed, 3),
        "started_at": started_wall,
        "finished_at": datetime.now().astimezone().isoformat(),
        "note": "No Plex, Arr, Tautulli, filesystem, or metadata changes were made.",
    }


@mcp.tool(
    description=(
        "Read-only local tunnel diagnostics. Summarizes recent tunnel-runtime log events relevant to 502s, response "
        "deadlines, connection TTL, transport closure, process exits/restarts, and timeouts, and probes local /healthz "
        "and /readyz. Returns only a bounded redacted diagnostic summary and does not modify the tunnel or Plex."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def plex_tunnel_runtime_diagnostics(max_log_lines: int = 2000, max_events: int = 50) -> dict:
    max_log_lines = max(100, min(int(max_log_lines), 10000))
    max_events = max(1, min(int(max_events), 200))
    result = {
        "runtime_log": TUNNEL_RUNTIME_LOG,
        "runtime_log_exists": os.path.isfile(TUNNEL_RUNTIME_LOG),
        "health": _local_tunnel_probe("/healthz"),
        "ready": _local_tunnel_probe("/readyz"),
        "configured_by_installer": {
            "mcp_connection_max_ttl_override": None,
            "runtime_log_max_bytes": 25 * 1024 * 1024,
            "runtime_log_retained_files": 3,
            "watchdog_log_max_bytes": 5 * 1024 * 1024,
            "watchdog_log_retained_files": 3,
            "watchdog_readiness_failure_threshold": 3,
            "watchdog_readiness_restart_cooldown_minutes": 10,
            "watchdog_startup_grace_seconds": 90,
            "health_endpoint_file": TUNNEL_HEALTH_URL_FILE,
            "note": "Installer does not override mcp.connection_max_ttl; tunnel-client default applies. Watchdog separates /healthz liveness from /readyz readiness and uses bounded restart behavior.",
        },
    }
    if not result["runtime_log_exists"]:
        result["event_counts"] = {}
        result["recent_events"] = []
        return result

    try:
        with open(TUNNEL_RUNTIME_LOG, "r", encoding="utf-8-sig", errors="replace") as handle:
            lines = handle.readlines()[-max_log_lines:]
    except Exception as exc:
        result["log_error"] = str(exc)
        result["event_counts"] = {}
        result["recent_events"] = []
        return result

    categories = {
        "http_502": (" 502", "\"502\"", "status=502", "resp_code=502"),
        "response_deadline": ("response deadline", "deadline reached", "response_timeout"),
        "connection_ttl": ("connection ttl", "max ttl", "connection_max_ttl"),
        "transport_closed": ("transport_closed", "closed pipe", "file already closed", "connection closed"),
        "timeout": ("timeout", "timed out", "deadline exceeded"),
        "process_exit": ("tunnel-client exited", "requesting tunnel-client shutdown", "supervisor caught exception"),
        "restart": ("restarting in", "starting tunnel-client", "tunnel supervisor started"),
    }
    counts = {key: 0 for key in categories}
    events = []
    for raw in lines:
        lower = raw.casefold()
        matched = []
        for category, needles in categories.items():
            if any(needle.casefold() in lower for needle in needles):
                counts[category] += 1
                matched.append(category)
        if matched:
            events.append({"categories": matched, "line": _redact_tunnel_log_line(raw.rstrip())})

    try:
        stat = os.stat(TUNNEL_RUNTIME_LOG)
        result["runtime_log_size_bytes"] = int(stat.st_size)
        result["runtime_log_modified_at"] = datetime.fromtimestamp(stat.st_mtime).astimezone().isoformat()
    except Exception:
        pass
    result["lines_scanned"] = len(lines)
    result["event_counts"] = counts
    result["recent_events"] = events[-max_events:]
    result["note"] = "Diagnostic only; no service restart, cache clear, scan, metadata write, or filesystem mutation was performed."
    return result


@mcp.tool(
    description="List every Plex library on the server, including movies, TV, music, photos, and other section types.",
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def plex_list_libraries() -> list[dict]:
    server = _plex()
    return [
        {
            "title": section.title,
            "type": getattr(section, "type", None),
            "key": str(getattr(section, "key", "")) or None,
            "uuid": getattr(section, "uuid", None),
        }
        for section in _sections(server)
    ]


@mcp.tool(
    description=(
        "List Plex collections. Optionally provide an exact library name to limit the search "
        "to that library. This is read-only."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def plex_list_collections(library_name: Optional[str] = None) -> dict:
    server = _plex()
    sections = _find_sections(server, library_name)

    if library_name is not None and not sections:
        return {
            "found_library": False,
            "library": library_name,
            "collections": [],
        }

    results = []
    errors = []

    for section in sections:
        try:
            collections = section.collections()
        except Exception as exc:
            errors.append(
                {
                    "library": section.title,
                    "library_type": getattr(section, "type", None),
                    "error": str(exc),
                }
            )
            continue

        for collection in collections:
            item_count = getattr(collection, "childCount", None)
            if item_count is None:
                item_count = getattr(collection, "leafCount", None)

            entry = {
                "title": collection.title,
                "library": section.title,
                "library_type": getattr(section, "type", None),
                "smart": bool(getattr(collection, "smart", False)),
                "subtype": getattr(collection, "subtype", None),
                "item_count": item_count,
                "rating_key": str(getattr(collection, "ratingKey", "")) or None,
            }

            if getattr(collection, "smart", False):
                entry["content"] = getattr(collection, "content", None)
                try:
                    entry["filters"] = collection.filters()
                except Exception as exc:
                    entry["filters_error"] = str(exc)

            results.append(entry)

    return {
        "found_library": True,
        "library": library_name,
        "collection_count": len(results),
        "collections": results,
        "errors": errors,
    }


@mcp.tool(
    description=(
        "Read high-level metadata for one exact Plex collection. Returns summary, sort title, labels, "
        "poster/background paths, collection display mode/order, published state, promoted visibility, "
        "field lock state, smart filters when applicable, and basic collection identity. Read-only."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def plex_get_collection_metadata(
    library_name: str,
    collection_title: str,
) -> dict:
    server = _plex()
    section = _exact_section(server, library_name)
    collection = _exact_collection(section, collection_title)
    return _collection_metadata(collection, section, include_visibility=True)


@mcp.tool(
    description=(
        "List collections whose Summary field is empty or missing. Optionally limit to one exact library. "
        "Potential blanks are reloaded individually before being reported, so this is suitable for collection "
        "cleanup without loading full metadata for every collection. Read-only."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def plex_list_collections_missing_summary(
    library_name: Optional[str] = None,
) -> dict:
    server = _plex()
    sections = _find_sections(server, library_name)

    if library_name is not None and not sections:
        return {
            "found_library": False,
            "library": library_name,
            "collection_count": 0,
            "collections": [],
            "errors": [],
        }

    missing = []
    errors = []

    for section in sections:
        try:
            collections = section.collections()
        except Exception as exc:
            errors.append({"library": section.title, "error": str(exc)})
            continue

        for collection in collections:
            summary = getattr(collection, "summary", None)
            if summary is not None and str(summary).strip():
                continue

            # Verify a possible blank against the full collection object. This avoids
            # reporting false blanks if the collection-list endpoint omitted Summary.
            try:
                collection.reload()
                summary = getattr(collection, "summary", None)
            except Exception as exc:
                errors.append(
                    {
                        "library": section.title,
                        "collection": collection.title,
                        "rating_key": str(getattr(collection, "ratingKey", "")) or None,
                        "error": str(exc),
                    }
                )
                continue

            if summary is None or not str(summary).strip():
                missing.append(
                    {
                        "title": collection.title,
                        "library": section.title,
                        "library_type": getattr(section, "type", None),
                        "smart": bool(getattr(collection, "smart", False)),
                        "subtype": getattr(collection, "subtype", None),
                        "item_count": getattr(collection, "childCount", None),
                        "rating_key": str(getattr(collection, "ratingKey", "")) or None,
                    }
                )

    return {
        "found_library": True,
        "library": library_name,
        "collection_count": len(missing),
        "collections": missing,
        "errors": errors,
    }


@mcp.tool(
    description=(
        "Update high-level metadata for one exact Plex collection. Every argument is optional and omitted fields "
        "are left unchanged. Supports Summary, sort title, exact label replacement, collection display mode "
        "(default/hide/hideItems/showItems), regular-collection item order (release/alpha/custom), and promoted "
        "visibility on Recommended/Home/Shared Home. Metadata field edits are locked to preserve manual values."
    ),
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=True),
)
def plex_update_collection_metadata(
    library_name: str,
    collection_title: str,
    summary: Optional[str] = None,
    sort_title: Optional[str] = None,
    labels: Optional[list[str]] = None,
    collection_mode: Optional[str] = None,
    collection_sort: Optional[str] = None,
    promoted_recommended: Optional[bool] = None,
    promoted_home: Optional[bool] = None,
    promoted_shared: Optional[bool] = None,
) -> dict:
    server = _plex()
    section = _exact_section(server, library_name)
    collection = _exact_collection(section, collection_title)
    collection.reload()

    if collection_mode is not None and collection_mode not in set(_COLLECTION_MODE_NAMES.values()):
        raise ValueError(
            "collection_mode must be one of: default, hide, hideItems, showItems"
        )

    if collection_sort is not None and collection_sort not in set(_COLLECTION_SORT_NAMES.values()):
        raise ValueError("collection_sort must be one of: release, alpha, custom")

    changes = []
    batch_needed = False

    current_summary = getattr(collection, "summary", None) or ""
    current_sort_title = getattr(collection, "titleSort", collection.title) or collection.title

    desired_labels = None
    current_labels = _label_names(collection)
    if labels is not None:
        desired_labels = _normalize_labels(labels)

    if summary is not None and current_summary != summary:
        batch_needed = True
    if sort_title is not None and current_sort_title != sort_title:
        batch_needed = True
    if desired_labels is not None:
        current_label_keys = {label.casefold() for label in current_labels}
        desired_label_keys = {label.casefold() for label in desired_labels}
        if current_label_keys != desired_label_keys:
            batch_needed = True

    if batch_needed:
        collection.batchEdits()

        if summary is not None and current_summary != summary:
            collection.editSummary(summary, locked=True)
            changes.append("summary")

        if sort_title is not None and current_sort_title != sort_title:
            collection.editSortTitle(sort_title, locked=True)
            changes.append("sort_title")

        if desired_labels is not None:
            current_by_key = {label.casefold(): label for label in current_labels}
            desired_by_key = {label.casefold(): label for label in desired_labels}
            to_remove = [current_by_key[key] for key in current_by_key.keys() - desired_by_key.keys()]
            to_add = [desired_by_key[key] for key in desired_by_key.keys() - current_by_key.keys()]

            if to_remove:
                collection.removeLabel(to_remove, locked=True)
            if to_add:
                collection.addLabel(to_add, locked=True)
            if to_remove or to_add:
                changes.append("labels")

        collection.saveEdits()
        collection.reload()

    if collection_mode is not None:
        current_mode = _COLLECTION_MODE_NAMES.get(getattr(collection, "collectionMode", None))
        if current_mode != collection_mode:
            collection.modeUpdate(mode=collection_mode)
            collection.reload()
            changes.append("collection_mode")

    if collection_sort is not None:
        if bool(getattr(collection, "smart", False)):
            raise ValueError("collection_sort cannot be changed on a smart collection; update its smart sort/filter instead.")
        current_sort = _COLLECTION_SORT_NAMES.get(getattr(collection, "collectionSort", None))
        if current_sort != collection_sort:
            collection.sortUpdate(sort=collection_sort)
            collection.reload()
            changes.append("collection_sort")

    if any(value is not None for value in (promoted_recommended, promoted_home, promoted_shared)):
        hub = collection.visibility()
        visibility_changed = (
            (promoted_recommended is not None and bool(getattr(hub, "promotedToRecommended", False)) != promoted_recommended)
            or (promoted_home is not None and bool(getattr(hub, "promotedToOwnHome", False)) != promoted_home)
            or (promoted_shared is not None and bool(getattr(hub, "promotedToSharedHome", False)) != promoted_shared)
        )
        if visibility_changed:
            hub.updateVisibility(
                recommended=promoted_recommended,
                home=promoted_home,
                shared=promoted_shared,
            )
            changes.append("visibility")

    return {
        "changed": bool(changes),
        "changed_fields": changes,
        "metadata": _collection_metadata(collection, section, include_visibility=True),
    }


@mcp.tool(
    description=(
        "Read the current Summary field for one exact Plex movie or TV show by rating key. "
        "Returns only compact identity/summary metadata and makes no changes."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def plex_get_item_summary(
    library_name: str,
    rating_key: str,
) -> dict:
    server = _plex()
    section = _exact_section(server, library_name)
    items = _load_rating_key_items(server, section, [rating_key])
    item = items[0]
    item.reload()

    item_type = getattr(item, "TYPE", None) or item.__class__.__name__.lower()
    if item_type not in {"movie", "show"}:
        raise ValueError("plex_get_item_summary currently supports movie and show items only.")

    summary = getattr(item, "summary", None) or ""
    locked = None
    try:
        for field in getattr(item, "fields", []) or []:
            if getattr(field, "name", None) == "summary":
                locked = bool(getattr(field, "locked", False))
                break
    except Exception:
        locked = None

    return {
        "library": section.title,
        "type": item_type,
        "title": getattr(item, "title", None),
        "year": getattr(item, "year", None),
        "rating_key": str(getattr(item, "ratingKey", "")) or None,
        "summary": summary,
        "summary_missing": not bool(summary.strip()),
        "summary_locked": locked,
    }


@mcp.tool(
    description=(
        "Replace the Summary field for one exact Plex movie or TV show by rating key. "
        "Only Summary is changed; title, artwork, collections, labels, ratings, files, and all other metadata are preserved. "
        "The edited Summary is locked so future metadata refreshes do not overwrite the manual value."
    ),
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=True),
)
def plex_update_item_summary(
    library_name: str,
    rating_key: str,
    summary: str,
) -> dict:
    server = _plex()
    section = _exact_section(server, library_name)
    items = _load_rating_key_items(server, section, [rating_key])
    item = items[0]
    item.reload()

    item_type = getattr(item, "TYPE", None) or item.__class__.__name__.lower()
    if item_type not in {"movie", "show"}:
        raise ValueError("plex_update_item_summary currently supports movie and show items only.")

    desired = str(summary)
    current = getattr(item, "summary", None) or ""
    if current == desired:
        return {
            "changed": False,
            "library": section.title,
            "type": item_type,
            "title": getattr(item, "title", None),
            "year": getattr(item, "year", None),
            "rating_key": str(getattr(item, "ratingKey", "")) or None,
            "summary": current,
        }

    item.batchEdits()
    item.editSummary(desired, locked=True)
    item.saveEdits()
    item.reload()

    return {
        "changed": True,
        "library": section.title,
        "type": item_type,
        "title": getattr(item, "title", None),
        "year": getattr(item, "year", None),
        "rating_key": str(getattr(item, "ratingKey", "")) or None,
        "summary": getattr(item, "summary", None) or "",
    }



@mcp.tool(
    description=(
        "Read editable metadata for one exact Plex TV episode by rating key. Returns title, Summary, "
        "original air/release date, content rating, episode number, season number, show identity, and field lock states. "
        "This tool is read-only."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def plex_get_episode_metadata(
    library_name: str,
    rating_key: str,
) -> dict:
    server = _plex()
    section = _exact_section(server, library_name)
    if getattr(section, "type", None) != "show":
        raise ValueError(f"Library '{section.title}' is not a TV library.")

    items = _load_rating_key_items(server, section, [rating_key])
    item = items[0]
    item.reload()

    item_type = getattr(item, "TYPE", None) or item.__class__.__name__.lower()
    if item_type != "episode":
        raise ValueError("plex_get_episode_metadata requires an individual TV episode rating key.")

    aired = getattr(item, "originallyAvailableAt", None)
    if aired is not None and hasattr(aired, "date"):
        aired = aired.date().isoformat()
    elif aired is not None and hasattr(aired, "isoformat"):
        aired = aired.isoformat()

    season_number = getattr(item, "parentIndex", None)
    episode_number = getattr(item, "index", None)

    return {
        "library": section.title,
        "type": item_type,
        "show": getattr(item, "grandparentTitle", None),
        "season": season_number,
        "episode": episode_number,
        "code": (
            f"S{int(season_number):02d}E{int(episode_number):02d}"
            if season_number is not None and episode_number is not None
            else None
        ),
        "title": getattr(item, "title", None),
        "summary": getattr(item, "summary", None) or "",
        "originally_available_at": aired,
        "content_rating": getattr(item, "contentRating", None),
        "rating_key": str(getattr(item, "ratingKey", "")) or None,
        "field_locks": _field_lock_states(item),
    }


@mcp.tool(
    description=(
        "Update editable metadata for one exact Plex TV episode by rating key. Every metadata field is optional and omitted fields are preserved. "
        "Supports title, Summary, original air/release date (YYYY-MM-DD), content rating, and episode number within the current season. "
        "Changed fields are locked so normal Plex metadata refreshes do not overwrite the manual values. "
        "This does not rename or move media files and does not change the episode's season assignment."
    ),
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=True),
)
def plex_update_episode_metadata(
    library_name: str,
    rating_key: str,
    title: Optional[str] = None,
    summary: Optional[str] = None,
    originally_available_at: Optional[str] = None,
    content_rating: Optional[str] = None,
    episode_number: Optional[int] = None,
) -> dict:
    if all(
        value is None
        for value in (title, summary, originally_available_at, content_rating, episode_number)
    ):
        raise ValueError("At least one episode metadata field must be supplied.")

    server = _plex()
    section = _exact_section(server, library_name)
    if getattr(section, "type", None) != "show":
        raise ValueError(f"Library '{section.title}' is not a TV library.")

    items = _load_rating_key_items(server, section, [rating_key])
    item = items[0]
    item.reload()

    item_type = getattr(item, "TYPE", None) or item.__class__.__name__.lower()
    if item_type != "episode":
        raise ValueError("plex_update_episode_metadata requires an individual TV episode rating key.")

    desired_title = None if title is None else str(title)
    desired_summary = None if summary is None else str(summary)
    desired_content_rating = None if content_rating is None else str(content_rating)

    desired_airdate = None
    if originally_available_at is not None:
        desired_airdate = str(originally_available_at).strip()
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", desired_airdate):
            raise ValueError("originally_available_at must use YYYY-MM-DD format.")
        try:
            time.strptime(desired_airdate, "%Y-%m-%d")
        except ValueError as exc:
            raise ValueError("originally_available_at is not a valid calendar date.") from exc

    desired_episode_number = None
    if episode_number is not None:
        try:
            desired_episode_number = int(episode_number)
        except Exception as exc:
            raise ValueError("episode_number must be an integer.") from exc
        if desired_episode_number < 0:
            raise ValueError("episode_number cannot be negative.")

    current_airdate = getattr(item, "originallyAvailableAt", None)
    if current_airdate is not None and hasattr(current_airdate, "date"):
        current_airdate = current_airdate.date().isoformat()
    elif current_airdate is not None and hasattr(current_airdate, "isoformat"):
        current_airdate = current_airdate.isoformat()

    changes = []
    if desired_title is not None and (getattr(item, "title", None) or "") != desired_title:
        changes.append("title")
    if desired_summary is not None and (getattr(item, "summary", None) or "") != desired_summary:
        changes.append("summary")
    if desired_airdate is not None and current_airdate != desired_airdate:
        changes.append("originally_available_at")
    if desired_content_rating is not None and (getattr(item, "contentRating", None) or "") != desired_content_rating:
        changes.append("content_rating")
    if desired_episode_number is not None and getattr(item, "index", None) != desired_episode_number:
        changes.append("episode_number")

    if changes:
        item.batchEdits()
        if "title" in changes:
            item.editTitle(desired_title, locked=True)
        if "summary" in changes:
            item.editSummary(desired_summary, locked=True)
        if "originally_available_at" in changes:
            item.editOriginallyAvailable(desired_airdate, locked=True)
        if "content_rating" in changes:
            item.editContentRating(desired_content_rating, locked=True)
        if "episode_number" in changes:
            # Plex exposes an episode's number as the editable index field. PlexAPI does
            # not currently wrap this scalar with an editEpisodeNumber helper, so use
            # the same low-level batch-edit keys that Plex itself accepts.
            item._edits["index.value"] = desired_episode_number
            item._edits["index.locked"] = 1
        item.saveEdits()
        item.reload()

    aired = getattr(item, "originallyAvailableAt", None)
    if aired is not None and hasattr(aired, "date"):
        aired = aired.date().isoformat()
    elif aired is not None and hasattr(aired, "isoformat"):
        aired = aired.isoformat()

    season_number = getattr(item, "parentIndex", None)
    resulting_episode_number = getattr(item, "index", None)

    return {
        "changed": bool(changes),
        "changed_fields": changes,
        "library": section.title,
        "type": item_type,
        "show": getattr(item, "grandparentTitle", None),
        "season": season_number,
        "episode": resulting_episode_number,
        "code": (
            f"S{int(season_number):02d}E{int(resulting_episode_number):02d}"
            if season_number is not None and resulting_episode_number is not None
            else None
        ),
        "title": getattr(item, "title", None),
        "summary": getattr(item, "summary", None) or "",
        "originally_available_at": aired,
        "content_rating": getattr(item, "contentRating", None),
        "rating_key": str(getattr(item, "ratingKey", "")) or None,
        "field_locks": _field_lock_states(item),
    }


def _added_at_iso(unix_timestamp: int) -> str:
    return datetime.fromtimestamp(int(unix_timestamp)).astimezone().isoformat()


def _parse_added_at_value(added_at: Optional[str]) -> tuple[int, str]:
    if added_at is None or not str(added_at).strip() or str(added_at).strip().casefold() == "now":
        value = int(time.time())
        return value, "now"

    raw = str(added_at).strip()
    if re.fullmatch(r"\d{9,12}", raw):
        value = int(raw)
        if value <= 0:
            raise ValueError("added_at unix timestamp must be greater than zero.")
        return value, "unix"

    try:
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", raw):
            parsed = datetime.strptime(raw, "%Y-%m-%d")
            return int(round(parsed.timestamp())), "date"

        normalized = raw[:-1] + "+00:00" if raw.endswith("Z") else raw
        parsed = datetime.fromisoformat(normalized)
        return int(round(parsed.timestamp())), "iso_datetime"
    except ValueError as exc:
        raise ValueError(
            "added_at must be 'now', a unix timestamp, YYYY-MM-DD, or an ISO-8601 date/time."
        ) from exc


def _normalize_rating_keys(rating_keys: list[str]) -> list[str]:
    normalized = []
    seen = set()
    for raw_key in rating_keys:
        key = str(raw_key).strip()
        if not key:
            continue
        if key in seen:
            continue
        seen.add(key)
        normalized.append(key)
    if not normalized:
        raise ValueError("At least one Plex rating key is required.")
    return normalized


def _set_added_at_for_items(
    items: list,
    base_timestamp: int,
    stagger_seconds: int,
    locked: bool,
) -> list[dict]:
    allowed_types = {"movie", "show", "season", "episode"}
    stagger_seconds = int(stagger_seconds)
    if stagger_seconds < 0 or stagger_seconds > 3600:
        raise ValueError("stagger_seconds must be between 0 and 3600.")

    updates = []
    for position, item in enumerate(items):
        item.reload()
        item_type = getattr(item, "TYPE", None) or item.__class__.__name__.lower()
        if item_type not in allowed_types:
            raise ValueError(
                f"addedAt editing supports movie, show, season, and episode items only; "
                f"rating key {getattr(item, 'ratingKey', '?')} is type '{item_type}'."
            )
        if not hasattr(item, "editAddedAt"):
            raise ValueError(
                f"PlexAPI does not expose addedAt editing for rating key {getattr(item, 'ratingKey', '?')}."
            )

        previous = getattr(item, "addedAt", None)
        previous_iso = previous.isoformat() if hasattr(previous, "isoformat") else previous
        target_timestamp = int(base_timestamp) - (position * stagger_seconds)
        item.editAddedAt(target_timestamp, locked=bool(locked))

        updates.append({
            "position": position + 1,
            "type": item_type,
            "title": getattr(item, "title", None),
            "year": getattr(item, "year", None),
            "show": getattr(item, "grandparentTitle", None),
            "season": getattr(item, "parentIndex", None),
            "episode": getattr(item, "index", None) if item_type == "episode" else None,
            "rating_key": str(getattr(item, "ratingKey", "")) or None,
            "previous_added_at": previous_iso,
            "added_at_unix": target_timestamp,
            "added_at": _added_at_iso(target_timestamp),
            "added_at_locked": bool(locked),
        })

    return updates


@mcp.tool(
    description=(
        "Read the current Plex addedAt timestamp for one exact movie, TV show, season, or episode by rating key. "
        "This field controls Recently Added ordering. Read-only and does not touch media files."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def plex_get_item_added_at(
    library_name: str,
    rating_key: str,
) -> dict:
    server = _plex()
    section = _exact_section(server, library_name)
    items = _load_rating_key_items(server, section, [rating_key])
    item = items[0]
    item.reload()

    item_type = getattr(item, "TYPE", None) or item.__class__.__name__.lower()
    if item_type not in {"movie", "show", "season", "episode"}:
        raise ValueError("plex_get_item_added_at supports movie, show, season, and episode items only.")

    value = getattr(item, "addedAt", None)
    return {
        "library": section.title,
        "type": item_type,
        "title": getattr(item, "title", None),
        "year": getattr(item, "year", None),
        "show": getattr(item, "grandparentTitle", None),
        "season": getattr(item, "parentIndex", None),
        "episode": getattr(item, "index", None) if item_type == "episode" else None,
        "rating_key": str(getattr(item, "ratingKey", "")) or None,
        "added_at": value.isoformat() if hasattr(value, "isoformat") else value,
        "field_locks": _field_lock_states(item),
    }


@mcp.tool(
    description=(
        "Set Plex addedAt for exact movie/show/season/episode rating keys without moving, deleting, rematching, or downloading media. "
        "Omit added_at or use 'now' to place the items at the top of Recently Added. The supplied rating-key order is newest first. "
        "stagger_seconds defaults to 1 so Plex has an unambiguous order; each subsequent item receives an earlier timestamp. "
        "added_at may also be a unix timestamp, YYYY-MM-DD, or ISO-8601 date/time. Returns previous timestamps for audit/reversal."
    ),
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=False),
)
def plex_set_items_added_at(
    library_name: str,
    rating_keys: list[str],
    added_at: Optional[str] = None,
    stagger_seconds: int = 1,
    locked: bool = True,
) -> dict:
    keys = _normalize_rating_keys(rating_keys)
    if len(keys) > 500:
        raise ValueError("A single addedAt update is limited to 500 exact items.")

    server = _plex()
    section = _exact_section(server, library_name)
    items = _load_rating_key_items(server, section, keys, require_same_type=False)
    base_timestamp, parsed_as = _parse_added_at_value(added_at)
    updates = _set_added_at_for_items(items, base_timestamp, stagger_seconds, locked)

    return {
        "changed": bool(updates),
        "library": section.title,
        "target_count": len(updates),
        "base_added_at_unix": base_timestamp,
        "base_added_at": _added_at_iso(base_timestamp),
        "parsed_as": parsed_as,
        "stagger_seconds": int(stagger_seconds),
        "newest_first": True,
        "items": updates,
        "note": "Only Plex addedAt metadata was changed. Media files and other metadata were not modified.",
    }


@mcp.tool(
    description=(
        "Set Plex addedAt in bulk for items selected by PlexAPI library filters, without moving, deleting, rematching, or downloading media. "
        "Use filters_json with Plex filter syntax, for example {\"actor\":\"Dolly Parton\"}, {\"director\":\"John Carpenter\"}, "
        "or {\"collection\":\"Alien Collection\"}. libtype may be movie, show, season, or episode. "
        "Omit added_at or use 'now' to make every matched item Recently Added. Results are sorted deterministically before timestamps are staggered. "
        "The operation refuses to run if the match count exceeds max_items, preventing silent partial updates."
    ),
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=False),
)
def plex_set_filtered_items_added_at(
    library_name: str,
    filters_json: str,
    libtype: Optional[str] = None,
    added_at: Optional[str] = None,
    stagger_seconds: int = 1,
    sort: Optional[str] = "titleSort",
    max_items: int = 500,
    locked: bool = True,
) -> dict:
    server = _plex()
    section = _exact_section(server, library_name)
    filters = _parse_filters_json(filters_json)
    if not filters:
        raise ValueError("filters_json must contain at least one Plex library filter for a bulk addedAt write.")

    max_items = max(1, min(int(max_items), 500))
    if libtype is not None and str(libtype).casefold() not in {"movie", "show", "season", "episode"}:
        raise ValueError("libtype must be movie, show, season, episode, or omitted.")

    items = section.search(
        libtype=libtype,
        sort=sort,
        filters=filters,
        maxresults=max_items + 1,
    )
    if len(items) > max_items:
        raise ValueError(
            f"The filter matched more than max_items={max_items}. Narrow the filter or explicitly raise max_items up to 500. "
            "No addedAt values were changed."
        )
    if not items:
        return {
            "changed": False,
            "library": section.title,
            "library_type": getattr(section, "type", None),
            "filters": filters,
            "libtype": libtype,
            "target_count": 0,
            "items": [],
            "reason": "no_matches",
        }

    base_timestamp, parsed_as = _parse_added_at_value(added_at)
    updates = _set_added_at_for_items(items, base_timestamp, stagger_seconds, locked)
    return {
        "changed": bool(updates),
        "library": section.title,
        "library_type": getattr(section, "type", None),
        "filters": filters,
        "libtype": libtype,
        "sort": sort,
        "target_count": len(updates),
        "base_added_at_unix": base_timestamp,
        "base_added_at": _added_at_iso(base_timestamp),
        "parsed_as": parsed_as,
        "stagger_seconds": int(stagger_seconds),
        "newest_first": True,
        "items": updates,
        "note": "Only Plex addedAt metadata was changed. Media files and other metadata were not modified.",
    }


@mcp.tool(
    description=(
        "Refresh/warm Plex's transient hubs for one exact library, including rows such as Recently Added, then verify the library's "
        "current Recently Added ordering directly from addedAt. This is a non-destructive cache nudge only: it does not scan the library, "
        "refresh item metadata, restart Plex, delete cache files, move media, or change any metadata. It may reduce stale Home hub behavior, "
        "but individual Plex clients can still retain their own local cached Home rows."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def plex_refresh_library_hubs(
    library_name: str,
    hub_item_count: int = 20,
    verify_recent_count: int = 25,
) -> dict:
    server = _plex()
    section = _exact_section(server, library_name)

    hub_item_count = max(1, min(int(hub_item_count), 100))
    verify_recent_count = max(1, min(int(verify_recent_count), 100))

    # Plex documents onlyTransient=1 for hubs prone to changing after media
    # playback or addition (for example On Deck and Recently Added). Fetching
    # the section-scoped transient hubs is intentionally only a refresh/warm
    # request; it does not mutate library metadata or invoke a library scan.
    hub_key = f"/hubs/sections/{section.key}?{urlencode({'onlyTransient': 1, 'count': hub_item_count})}"
    hub_root = server.query(hub_key)

    hubs = []
    try:
        for hub in list(hub_root):
            attrib = getattr(hub, "attrib", {}) or {}
            hubs.append({
                "title": attrib.get("title"),
                "identifier": attrib.get("hubIdentifier") or attrib.get("identifier"),
                "type": attrib.get("type"),
                "size": _safe_int(attrib.get("size"), 0),
            })
    except Exception:
        # A successful query is the refresh action. Hub parsing is best-effort
        # because Plex response shape can vary by server/library type.
        hubs = []

    libtype = getattr(section, "type", None)
    recent_items = section.recentlyAdded(
        maxresults=verify_recent_count,
        libtype=libtype,
    )
    recent_rows = []
    for position, item in enumerate(recent_items, start=1):
        value = getattr(item, "addedAt", None)
        recent_rows.append({
            "position": position,
            "type": getattr(item, "TYPE", None) or item.__class__.__name__.lower(),
            "title": getattr(item, "title", None),
            "year": getattr(item, "year", None),
            "rating_key": str(getattr(item, "ratingKey", "")) or None,
            "added_at": value.isoformat() if hasattr(value, "isoformat") else value,
        })

    return {
        "refreshed": True,
        "library": section.title,
        "library_key": str(section.key),
        "library_type": libtype,
        "method": "GET section transient hubs (onlyTransient=1) followed by direct Recently Added verification",
        "transient_hubs_returned": len(hubs),
        "transient_hubs": hubs,
        "recently_added_verified_count": len(recent_rows),
        "recently_added_top": recent_rows,
        "note": (
            "No Plex media, metadata, filesystem cache, library scan, or server process was modified. "
            "This warms/refreshes the server-side transient hub response and verifies current addedAt ordering; "
            "a Plex client may still need to refresh its own cached Home screen."
        ),
    }


@mcp.tool(
    description=(
        "Upload or replace the poster for one exact Plex movie or TV show by rating key. Provide exactly one source: "
        "an http/https image_url, or a local_filepath on the Plex server. Local files are limited to jpg/jpeg/png/webp. "
        "Only the selected item's poster is changed; title, summary, collections, labels, ratings, files, and all other metadata are preserved. "
        "The selected poster is locked so a normal metadata refresh does not replace the manual artwork."
    ),
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=False),
)
def plex_set_item_poster(
    library_name: str,
    rating_key: str,
    image_url: Optional[str] = None,
    local_filepath: Optional[str] = None,
) -> dict:
    server = _plex()
    section = _exact_section(server, library_name)
    items = _load_rating_key_items(server, section, [rating_key])
    item = items[0]
    item.reload()

    item_type = getattr(item, "TYPE", None) or item.__class__.__name__.lower()
    if item_type not in {"movie", "show"}:
        raise ValueError("plex_set_item_poster currently supports movie and show items only.")

    image_url, local_filepath = _validate_image_source(image_url, local_filepath)
    previous_thumb = getattr(item, "thumb", None)

    item.uploadPoster(url=image_url, filepath=local_filepath)
    item.lockPoster()
    item.reload()

    return {
        "changed": True,
        "library": section.title,
        "type": item_type,
        "title": getattr(item, "title", None),
        "year": getattr(item, "year", None),
        "rating_key": str(getattr(item, "ratingKey", "")) or None,
        "previous_thumb": previous_thumb,
        "thumb": getattr(item, "thumb", None),
        "poster_locked": True,
        "source": "url" if image_url else "local_filepath",
    }


@mcp.tool(
    description=(
        "Upload or replace the poster for one exact Plex collection. Provide exactly one source: an http/https "
        "image_url, or a local_filepath on the Plex server. Local files are limited to jpg/jpeg/png/webp. "
        "This changes collection artwork only and never changes collection membership or underlying media."
    ),
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=False),
)
def plex_set_collection_poster(
    library_name: str,
    collection_title: str,
    image_url: Optional[str] = None,
    local_filepath: Optional[str] = None,
) -> dict:
    server = _plex()
    section = _exact_section(server, library_name)
    collection = _exact_collection(section, collection_title)
    image_url, local_filepath = _validate_image_source(image_url, local_filepath)

    collection.uploadPoster(url=image_url, filepath=local_filepath)
    try:
        collection.lockPoster()
    except Exception:
        pass
    collection.reload()

    return {
        "changed": True,
        "library": section.title,
        "collection": collection.title,
        "rating_key": str(collection.ratingKey),
        "thumb": getattr(collection, "thumb", None),
        "source": "url" if image_url else "local_filepath",
    }


@mcp.tool(
    description=(
        "Upload or replace the background artwork for one exact Plex collection. Provide exactly one source: "
        "an http/https image_url, or a local_filepath on the Plex server. Local files are limited to "
        "jpg/jpeg/png/webp. This changes collection artwork only and never changes collection membership or media."
    ),
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=False),
)
def plex_set_collection_background(
    library_name: str,
    collection_title: str,
    image_url: Optional[str] = None,
    local_filepath: Optional[str] = None,
) -> dict:
    server = _plex()
    section = _exact_section(server, library_name)
    collection = _exact_collection(section, collection_title)
    image_url, local_filepath = _validate_image_source(image_url, local_filepath)

    collection.uploadArt(url=image_url, filepath=local_filepath)
    try:
        collection.lockArt()
    except Exception:
        pass
    collection.reload()

    return {
        "changed": True,
        "library": section.title,
        "collection": collection.title,
        "rating_key": str(collection.ratingKey),
        "art": getattr(collection, "art", None),
        "source": "url" if image_url else "local_filepath",
    }


@mcp.tool(
    description=(
        "List the contents of an exact Plex collection. Optionally provide an exact library name "
        "to disambiguate collections with the same title. Works across library types and is read-only."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def plex_list_collection_items(
    collection_title: str,
    library_name: Optional[str] = None,
) -> dict:
    server = _plex()
    sections = _find_sections(server, library_name)

    if library_name is not None and not sections:
        return {
            "found": False,
            "reason": "library_not_found",
            "library": library_name,
            "collection": collection_title,
            "items": [],
        }

    matches = []

    for section in sections:
        try:
            collections = section.collections()
        except Exception:
            continue

        for collection in collections:
            if collection.title.casefold() != collection_title.casefold():
                continue

            try:
                raw_items = collection.items()
            except Exception as exc:
                matches.append(
                    {
                        "library": section.title,
                        "library_type": getattr(section, "type", None),
                        "collection": collection.title,
                        "rating_key": str(getattr(collection, "ratingKey", "")) or None,
                        "error": str(exc),
                        "items": [],
                    }
                )
                continue

            max_items = 1000
            summarized = [
                _item_summary(item, section.title)
                for item in raw_items[:max_items]
            ]

            matches.append(
                {
                    "library": section.title,
                    "library_type": getattr(section, "type", None),
                    "collection": collection.title,
                    "rating_key": str(getattr(collection, "ratingKey", "")) or None,
                    "total_items": len(raw_items),
                    "returned_items": len(summarized),
                    "truncated": len(raw_items) > max_items,
                    "items": summarized,
                }
            )

    return {
        "found": bool(matches),
        "collection": collection_title,
        "library": library_name,
        "matches": matches,
    }


@mcp.tool(
    description=(
        "Search items in one exact Plex library by title. Partial title matches are allowed. "
        "Optionally specify a Plex media type such as movie, show, season, episode, artist, "
        "album, track, photoalbum, photo, or collection. Read-only and useful for obtaining "
        "exact rating keys before collection writes."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def plex_search_library_items(
    library_name: str,
    query: str,
    libtype: Optional[str] = None,
    max_results: int = 100,
) -> dict:
    server = _plex()
    section = _exact_section(server, library_name)

    max_results = max(1, min(int(max_results), 500))
    results = section.search(
        title=query,
        libtype=libtype,
        maxresults=max_results,
    )

    return {
        "library": section.title,
        "library_type": getattr(section, "type", None),
        "query": query,
        "libtype": libtype,
        "result_count": len(results),
        "items": [_item_summary(item, section.title) for item in results],
    }


@mcp.tool(
    description=(
        "Preview a smart collection filter without creating or modifying anything. "
        "filters_json must be a JSON object using PlexAPI search-filter syntax. Nested "
        "and/or filters are supported. Returns the items that currently match."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def plex_preview_smart_collection(
    library_name: str,
    filters_json: str,
    libtype: Optional[str] = None,
    sort: Optional[str] = None,
    limit: Optional[int] = None,
    max_results: int = 200,
) -> dict:
    server = _plex()
    section = _exact_section(server, library_name)
    filters = _parse_filters_json(filters_json)

    max_results = max(1, min(int(max_results), 500))
    effective_limit = limit
    if effective_limit is not None:
        effective_limit = max(1, int(effective_limit))

    items = section.search(
        libtype=libtype,
        sort=sort,
        limit=effective_limit,
        filters=filters,
        maxresults=max_results,
    )

    return {
        "library": section.title,
        "library_type": getattr(section, "type", None),
        "libtype": libtype,
        "sort": sort,
        "limit": effective_limit,
        "filters": filters,
        "matched_returned": len(items),
        "max_results": max_results,
        "items": [_item_summary(item, section.title) for item in items],
    }


@mcp.tool(
    description=(
        "Create a regular Plex collection in one exact library using exact Plex rating keys. "
        "All items must come from that library and be the same media type. This creates a "
        "collection only and never deletes or changes underlying media."
    ),
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=False),
)
def plex_create_collection(
    library_name: str,
    collection_title: str,
    rating_keys: list[str],
) -> dict:
    server = _plex()
    section = _exact_section(server, library_name)

    if _collection_exists(section, collection_title):
        return {
            "created": False,
            "reason": "collection_exists",
            "library": section.title,
            "collection": collection_title,
        }

    items = _load_rating_key_items(server, section, rating_keys)
    collection = server.createCollection(
        title=collection_title,
        section=section,
        items=items,
    )

    return {
        "created": True,
        "library": section.title,
        "collection": collection.title,
        "smart": bool(getattr(collection, "smart", False)),
        "subtype": getattr(collection, "subtype", None),
        "rating_key": str(collection.ratingKey),
        "items": len(items),
    }


@mcp.tool(
    description=(
        "Add exact Plex items to an existing regular collection. Smart collections cannot "
        "accept manually added items; update their filters instead. Underlying media is untouched."
    ),
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=False),
)
def plex_add_to_collection(
    library_name: str,
    collection_title: str,
    rating_keys: list[str],
) -> dict:
    server = _plex()
    section = _exact_section(server, library_name)
    collection = _exact_collection(section, collection_title)

    if collection.smart:
        return {
            "changed": False,
            "reason": "smart_collection",
            "message": "Smart collections are filter-driven. Use plex_update_smart_collection_filters.",
        }

    items = _load_rating_key_items(server, section, rating_keys)
    existing_keys = {str(item.ratingKey) for item in collection.items()}
    to_add = [item for item in items if str(item.ratingKey) not in existing_keys]

    if not to_add:
        return {
            "changed": False,
            "reason": "all_items_already_present",
            "library": section.title,
            "collection": collection.title,
        }

    collection.addItems(to_add)

    return {
        "changed": True,
        "library": section.title,
        "collection": collection.title,
        "added": [_item_summary(item, section.title) for item in to_add],
    }


@mcp.tool(
    description=(
        "Remove exact Plex items from an existing regular collection. This does NOT delete "
        "the media from Plex or the filesystem. Smart collections are filter-driven and are rejected."
    ),
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=False),
)
def plex_remove_from_collection(
    library_name: str,
    collection_title: str,
    rating_keys: list[str],
) -> dict:
    server = _plex()
    section = _exact_section(server, library_name)
    collection = _exact_collection(section, collection_title)

    if collection.smart:
        return {
            "changed": False,
            "reason": "smart_collection",
            "message": "Smart collections are filter-driven. Use plex_update_smart_collection_filters.",
        }

    requested = {str(key).strip() for key in rating_keys}
    current_items = collection.items()
    to_remove = [item for item in current_items if str(item.ratingKey) in requested]

    if not to_remove:
        return {
            "changed": False,
            "reason": "none_of_the_requested_items_are_in_the_collection",
            "library": section.title,
            "collection": collection.title,
        }

    collection.removeItems(to_remove)

    return {
        "changed": True,
        "library": section.title,
        "collection": collection.title,
        "removed": [_item_summary(item, section.title) for item in to_remove],
    }


@mcp.tool(
    description=(
        "Replace the membership of an existing regular collection with exactly the supplied "
        "Plex rating keys. This changes collection membership only; it never deletes media. "
        "Smart collections are rejected because their membership is controlled by filters."
    ),
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=True),
)
def plex_replace_collection_items(
    library_name: str,
    collection_title: str,
    rating_keys: list[str],
) -> dict:
    server = _plex()
    section = _exact_section(server, library_name)
    collection = _exact_collection(section, collection_title)

    if collection.smart:
        return {
            "changed": False,
            "reason": "smart_collection",
            "message": "Use plex_update_smart_collection_filters for a smart collection.",
        }

    desired_items = _load_rating_key_items(server, section, rating_keys)
    desired_by_key = {str(item.ratingKey): item for item in desired_items}
    current_items = collection.items()
    current_by_key = {str(item.ratingKey): item for item in current_items}

    remove_keys = sorted(set(current_by_key) - set(desired_by_key))
    add_keys = sorted(set(desired_by_key) - set(current_by_key))

    if remove_keys:
        collection.removeItems([current_by_key[key] for key in remove_keys])
    if add_keys:
        collection.addItems([desired_by_key[key] for key in add_keys])

    return {
        "changed": bool(remove_keys or add_keys),
        "library": section.title,
        "collection": collection.title,
        "removed_rating_keys": remove_keys,
        "added_rating_keys": add_keys,
        "final_requested_count": len(desired_by_key),
    }


@mcp.tool(
    description=(
        "Rename an exact Plex collection inside one exact library. Works with both regular "
        "and smart collections. Does not affect collection membership or underlying media."
    ),
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=True),
)
def plex_rename_collection(
    library_name: str,
    collection_title: str,
    new_title: str,
) -> dict:
    server = _plex()
    section = _exact_section(server, library_name)
    collection = _exact_collection(section, collection_title)

    if not new_title.strip():
        raise ValueError("New collection title cannot be empty.")

    if collection.title.casefold() == new_title.casefold():
        return {
            "changed": False,
            "reason": "same_title",
            "library": section.title,
            "collection": collection.title,
        }

    if _collection_exists(section, new_title):
        return {
            "changed": False,
            "reason": "target_title_already_exists",
            "library": section.title,
            "collection": collection.title,
            "new_title": new_title,
        }

    old_title = collection.title
    collection.edit(**{"title.value": new_title, "title.locked": 1})
    collection.reload()

    return {
        "changed": True,
        "library": section.title,
        "old_title": old_title,
        "new_title": collection.title,
        "rating_key": str(collection.ratingKey),
    }


@mcp.tool(
    description=(
        "Delete a Plex collection object from one exact library. This is destructive to the "
        "collection definition but DOES NOT delete any underlying movies, shows, music, photos, "
        "or media files."
    ),
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=True, idempotent_hint=False),
)
def plex_delete_collection(
    library_name: str,
    collection_title: str,
) -> dict:
    server = _plex()
    section = _exact_section(server, library_name)
    collection = _exact_collection(section, collection_title)

    details = {
        "library": section.title,
        "collection": collection.title,
        "smart": bool(collection.smart),
        "rating_key": str(collection.ratingKey),
    }

    collection.delete()

    return {
        "deleted": True,
        **details,
        "underlying_media_deleted": False,
    }


@mcp.tool(
    description=(
        "Create a smart Plex collection. filters_json must be a JSON object using PlexAPI "
        "filter syntax; nested and/or filters are supported. Optionally specify libtype, sort, "
        "and limit. Smart membership automatically changes as library metadata matches the filters."
    ),
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=False),
)
def plex_create_smart_collection(
    library_name: str,
    collection_title: str,
    filters_json: str,
    libtype: Optional[str] = None,
    sort: Optional[str] = None,
    limit: Optional[int] = None,
) -> dict:
    server = _plex()
    section = _exact_section(server, library_name)

    if _collection_exists(section, collection_title):
        return {
            "created": False,
            "reason": "collection_exists",
            "library": section.title,
            "collection": collection_title,
        }

    filters = _parse_filters_json(filters_json)
    effective_limit = None if limit is None else max(1, int(limit))

    # Validate the filter against the library before writing the collection.
    preview = section.search(
        libtype=libtype,
        sort=sort,
        limit=effective_limit,
        filters=filters,
        maxresults=5,
    )

    collection = server.createCollection(
        title=collection_title,
        section=section,
        smart=True,
        libtype=libtype,
        sort=sort,
        limit=effective_limit,
        filters=filters,
    )

    return {
        "created": True,
        "library": section.title,
        "collection": collection.title,
        "smart": True,
        "subtype": getattr(collection, "subtype", None),
        "rating_key": str(collection.ratingKey),
        "filters": filters,
        "sort": sort,
        "limit": effective_limit,
        "preview_match_count_returned": len(preview),
    }


@mcp.tool(
    description=(
        "Replace the filter definition of an existing smart Plex collection. filters_json must "
        "be a JSON object using PlexAPI filter syntax; nested and/or filters are supported. "
        "The supplied libtype, sort, limit, and filters become the new smart membership rule. "
        "Regular collections are rejected."
    ),
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=True),
)
def plex_update_smart_collection_filters(
    library_name: str,
    collection_title: str,
    filters_json: str,
    libtype: Optional[str] = None,
    sort: Optional[str] = None,
    limit: Optional[int] = None,
) -> dict:
    server = _plex()
    section = _exact_section(server, library_name)
    collection = _exact_collection(section, collection_title)

    if not collection.smart:
        return {
            "changed": False,
            "reason": "regular_collection",
            "message": "Regular collections have explicit item membership rather than smart filters.",
        }

    filters = _parse_filters_json(filters_json)
    effective_limit = None if limit is None else max(1, int(limit))

    # Preview validates the new expression before changing the smart collection.
    preview = section.search(
        libtype=libtype,
        sort=sort,
        limit=effective_limit,
        filters=filters,
        maxresults=5,
    )

    before = _smart_collection_summary(collection)

    collection.updateFilters(
        libtype=libtype,
        limit=effective_limit,
        sort=sort,
        filters=filters,
    )
    collection.reload()

    return {
        "changed": True,
        "library": section.title,
        "collection": collection.title,
        "rating_key": str(collection.ratingKey),
        "before": before,
        "filters": filters,
        "sort": sort,
        "limit": effective_limit,
        "preview_match_count_returned": len(preview),
        "content": getattr(collection, "content", None),
    }


@mcp.tool(
    description="Search all Plex TV libraries for shows whose titles contain the supplied text.",
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def plex_search_shows(query: str) -> list[dict]:
    server = _plex()
    needle = query.casefold()
    results = []

    for section in _tv_sections(server):
        for show in section.all():
            if needle in show.title.casefold():
                results.append(
                    {
                        "title": show.title,
                        "year": getattr(show, "year", None),
                        "library": section.title,
                        "rating_key": str(show.ratingKey),
                    }
                )

    return results[:100]


@mcp.tool(
    description="List episodes for one Plex TV show. Optionally limit the result to a season number.",
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def plex_list_episodes(show_title: str, season: Optional[int] = None) -> list[dict]:
    server = _plex()
    matches = []

    for section in _tv_sections(server):
        for show in section.search(title=show_title, libtype="show"):
            if show.title.casefold() != show_title.casefold():
                continue

            for ep in show.episodes():
                if season is not None and ep.seasonNumber != season:
                    continue

                matches.append(
                    {
                        "show": show.title,
                        "season": ep.seasonNumber,
                        "episode": ep.episodeNumber,
                        "code": f"S{ep.seasonNumber:02d}E{ep.episodeNumber:02d}",
                        "title": ep.title,
                        "originally_available_at": (
                            ep.originallyAvailableAt.isoformat()
                            if getattr(ep, "originallyAvailableAt", None)
                            else None
                        ),
                        "rating_key": str(ep.ratingKey),
                    }
                )

    return matches


@mcp.tool(
    description="Find one exact TV episode by show title, season number, and episode number.",
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def plex_find_episode(show_title: str, season: int, episode: int) -> dict:
    server = _plex()

    for section in _tv_sections(server):
        for show in section.search(title=show_title, libtype="show"):
            if show.title.casefold() != show_title.casefold():
                continue

            try:
                ep = show.episode(season=season, episode=episode)
                return {
                    "found": True,
                    "show": show.title,
                    "season": ep.seasonNumber,
                    "episode": ep.episodeNumber,
                    "code": f"S{ep.seasonNumber:02d}E{ep.episodeNumber:02d}",
                    "title": ep.title,
                    "rating_key": str(ep.ratingKey),
                    "library": section.title,
                }
            except Exception:
                pass

    return {
        "found": False,
        "show": show_title,
        "season": season,
        "episode": episode,
    }


@mcp.tool(
    description="List existing Plex playlists.",
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def plex_list_playlists() -> list[dict]:
    server = _plex()
    return [
        {
            "title": p.title,
            "type": p.playlistType,
            "smart": bool(p.smart),
            "items": p.leafCount,
            "rating_key": str(p.ratingKey),
        }
        for p in server.playlists()
    ]


@mcp.tool(
    description=(
        "Create a Plex video playlist from exact TV episode specifications. "
        "Each item must use the form 'Show Title|S01E02'. "
        "The supplied order is preserved. Existing playlists are not replaced unless "
        "replace_existing is true."
    ),
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=False),
)
def plex_create_tv_playlist(
    name: str,
    episode_specs: list[str],
    replace_existing: bool = False,
) -> dict:
    server = _plex()

    if not name.strip():
        raise ValueError("Playlist name cannot be empty.")
    if not episode_specs:
        raise ValueError("At least one episode specification is required.")

    existing = [p for p in server.playlists() if p.title.casefold() == name.casefold()]
    if existing and not replace_existing:
        return {
            "created": False,
            "reason": "playlist_exists",
            "playlist": existing[0].title,
            "items": existing[0].leafCount,
        }

    items = []
    missing = []

    for spec in episode_specs:
        try:
            show_title, code = spec.rsplit("|", 1)
            code = code.strip().upper()
            if len(code) != 6 or code[0] != "S" or code[3] != "E":
                raise ValueError
            season = int(code[1:3])
            episode = int(code[4:6])
        except Exception:
            missing.append({"spec": spec, "reason": "invalid_format"})
            continue

        found = None
        for section in _tv_sections(server):
            for show in section.search(title=show_title.strip(), libtype="show"):
                if show.title.casefold() != show_title.strip().casefold():
                    continue
                try:
                    found = show.episode(season=season, episode=episode)
                    break
                except Exception:
                    pass
            if found is not None:
                break

        if found is None:
            missing.append({"spec": spec, "reason": "episode_not_found"})
        else:
            items.append(found)

    if missing:
        return {
            "created": False,
            "reason": "one_or_more_episodes_not_found",
            "matched_count": len(items),
            "missing": missing,
        }

    if existing and replace_existing:
        for playlist in existing:
            playlist.delete()

    created = Playlist.create(server, name, items=items)
    return {
        "created": True,
        "playlist": created.title,
        "items": len(items),
        "rating_key": str(created.ratingKey),
    }


# ===========================================================================
# Tautulli-backed reporting subsystem
# ===========================================================================

def _safe_int(value, default=0):
    try:
        if value in (None, ""):
            return default
        return int(value)
    except Exception:
        return default


def _human_bytes(value) -> str:
    size = float(_safe_int(value, 0))
    units = ["B", "KB", "MB", "GB", "TB", "PB"]
    for unit in units:
        if abs(size) < 1024.0 or unit == units[-1]:
            if unit == "B":
                return f"{int(size)} {unit}"
            return f"{size:.2f} {unit}"
        size /= 1024.0
    return f"{size:.2f} PB"


def _timestamp_iso(value):
    ivalue = _safe_int(value, 0)
    if not ivalue:
        return None
    try:
        from datetime import datetime, timezone
        return datetime.fromtimestamp(ivalue, tz=timezone.utc).isoformat()
    except Exception:
        return None


def _tautulli_endpoint(cmd: str, params: Optional[dict] = None) -> str:
    if not TAUTULLI_URL.strip():
        raise RuntimeError("Tautulli URL is not configured.")
    if not TAUTULLI_API_KEY.strip():
        raise RuntimeError("Tautulli API key is not configured.")

    query = {"apikey": TAUTULLI_API_KEY, "cmd": cmd}
    if params:
        for key, value in params.items():
            if value is not None:
                query[key] = value
    return TAUTULLI_URL.rstrip("/") + "/api/v2?" + urlencode(query, doseq=True)


def _tautulli_api(cmd: str, params: Optional[dict] = None, timeout: int = 60):
    url = _tautulli_endpoint(cmd, params)
    request = Request(url, headers={"User-Agent": "MediaStack-Control-Gateway/3.4.6"})
    try:
        with urlopen(request, timeout=timeout) as response:
            raw = response.read()
    except Exception as exc:
        raise RuntimeError(f"Tautulli API request failed for '{cmd}': {exc}") from exc

    try:
        payload = json.loads(raw.decode("utf-8-sig"))
    except Exception as exc:
        raise RuntimeError(f"Tautulli returned non-JSON data for '{cmd}'.") from exc

    envelope = payload.get("response", payload) if isinstance(payload, dict) else payload
    if isinstance(envelope, dict):
        result = envelope.get("result")
        if result not in (None, "success"):
            message = envelope.get("message") or "Unknown Tautulli error"
            raise RuntimeError(f"Tautulli command '{cmd}' failed: {message}")
        if "data" in envelope:
            return envelope.get("data")
    return envelope


def _tautulli_libraries() -> list[dict]:
    data = _tautulli_api("get_libraries")
    return data if isinstance(data, list) else []


def _tautulli_exact_library(library_name: str) -> dict:
    if library_name is None or not str(library_name).strip():
        raise ValueError("Library name cannot be empty.")

    needle = str(library_name).casefold()
    matches = [
        library for library in _tautulli_libraries()
        if str(library.get("section_name", "")).casefold() == needle
    ]
    if not matches:
        raise ValueError(f"Tautulli library not found: {library_name}")
    if len(matches) != 1:
        raise ValueError(f"Tautulli library name is ambiguous: {library_name}")
    return matches[0]


def _tautulli_media_info(
    section_id,
    start: int = 0,
    length: int = 25,
    order_column: Optional[str] = None,
    order_dir: str = "asc",
    search: Optional[str] = None,
):
    params = {
        "section_id": str(section_id),
        "start": max(0, int(start)),
        "length": max(1, int(length)),
        "order_dir": order_dir,
    }
    if order_column:
        params["order_column"] = order_column
    if search:
        params["search"] = search
    data = _tautulli_api("get_library_media_info", params=params, timeout=120)
    return data if isinstance(data, dict) else {}


def _tautulli_all_media_rows(section_id, page_size: int = 500) -> list[dict]:
    page_size = max(25, min(int(page_size), 1000))
    rows = []
    start = 0
    expected = None

    while True:
        page = _tautulli_media_info(section_id, start=start, length=page_size)
        page_rows = page.get("data") or []
        if expected is None:
            expected = _safe_int(page.get("recordsFiltered"), _safe_int(page.get("recordsTotal"), 0))
        rows.extend(page_rows)
        start += len(page_rows)
        if not page_rows or (expected and start >= expected) or len(page_rows) < page_size:
            break

    return rows


def _library_counts(library: dict) -> dict:
    section_type = str(library.get("section_type", "")).lower()
    count = _safe_int(library.get("count"), 0)
    parent = _safe_int(library.get("parent_count"), 0)
    child = _safe_int(library.get("child_count"), 0)

    if section_type == "movie":
        return {"movies": count}
    if section_type == "show":
        return {"shows": count, "seasons": parent, "episodes": child}
    if section_type == "artist":
        return {"artists": count, "albums": parent, "tracks": child}
    if section_type == "photo":
        return {"photo_albums": count, "photos": child or parent}
    return {"items": count, "parent_items": parent, "child_items": child}


def _reporting_library_row(library: dict) -> dict:
    section_id = library.get("section_id")
    media = _tautulli_media_info(section_id, start=0, length=1)
    total_size = _safe_int(media.get("total_file_size"), 0)
    return {
        "library": library.get("section_name"),
        "section_id": str(section_id) if section_id is not None else None,
        "library_type": library.get("section_type"),
        "counts": _library_counts(library),
        "reporting_rows": _safe_int(media.get("recordsTotal"), 0),
        "logical_size_bytes": total_size,
        "logical_size_human": _human_bytes(total_size),
        "last_refreshed": _safe_int(media.get("last_refreshed"), 0) or None,
        "last_refreshed_utc": _timestamp_iso(media.get("last_refreshed")),
    }


def _normalized_media_row(row: dict, library_name: str) -> dict:
    size = _safe_int(row.get("file_size"), 0)
    result = {
        "library": library_name,
        "media_type": row.get("media_type"),
        "title": row.get("title") or row.get("sort_title"),
        "sort_title": row.get("sort_title"),
        "year": row.get("year"),
        "rating_key": str(row.get("rating_key")) if row.get("rating_key") not in (None, "") else None,
        "parent_rating_key": str(row.get("parent_rating_key")) if row.get("parent_rating_key") not in (None, "") else None,
        "grandparent_rating_key": str(row.get("grandparent_rating_key")) if row.get("grandparent_rating_key") not in (None, "") else None,
        "added_at": _safe_int(row.get("added_at"), 0) or None,
        "last_played": _safe_int(row.get("last_played"), 0) or None,
        "play_count": _safe_int(row.get("play_count"), 0),
        "file_size_bytes": size,
        "file_size_human": _human_bytes(size),
        "container": row.get("container"),
        "bitrate": row.get("bitrate"),
        "video_codec": row.get("video_codec"),
        "video_resolution": row.get("video_resolution"),
        "video_framerate": row.get("video_framerate"),
        "audio_codec": row.get("audio_codec"),
        "audio_channels": row.get("audio_channels"),
    }
    return result


@mcp.tool(
    description=(
        "Check the local Tautulli reporting connection, version, Plex-server identity match, and libraries. "
        "Read-only and intended to verify that reporting data is available without querying every Plex item."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def plex_reporting_status() -> dict:
    try:
        info = _tautulli_api("get_tautulli_info") or {}
        server_info = _tautulli_api("get_server_info") or {}
        libraries = _tautulli_libraries()
        plex = _plex()
        tautulli_identifier = server_info.get("pms_identifier") if isinstance(server_info, dict) else None
        return {
            "available": True,
            "tautulli_url": TAUTULLI_URL,
            "tautulli": info,
            "tautulli_plex_server": server_info,
            "plex_server_name": plex.friendlyName,
            "plex_machine_identifier": plex.machineIdentifier,
            "identity_match": (
                str(tautulli_identifier) == str(plex.machineIdentifier)
                if tautulli_identifier else None
            ),
            "library_count": len(libraries),
            "libraries": [
                {
                    "section_id": str(lib.get("section_id")),
                    "name": lib.get("section_name"),
                    "type": lib.get("section_type"),
                    "counts": _library_counts(lib),
                }
                for lib in libraries
            ],
        }
    except Exception as exc:
        return {
            "available": False,
            "tautulli_url": TAUTULLI_URL,
            "error": str(exc),
        }


@mcp.tool(
    description=(
        "Return a compact reporting summary for every Tautulli-tracked Plex library: hierarchy counts, "
        "cached reporting row count, logical media bytes, human-readable size, and cache refresh time. "
        "The server-wide total is the sum of library totals and is not deduplicated across libraries."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def plex_reporting_summary() -> dict:
    libraries = _tautulli_libraries()
    rows = []
    errors = []
    for library in libraries:
        try:
            rows.append(_reporting_library_row(library))
        except Exception as exc:
            errors.append({"library": library.get("section_name"), "error": str(exc)})

    total_size = sum(_safe_int(row.get("logical_size_bytes"), 0) for row in rows)
    return {
        "source": "Tautulli cached library media info",
        "library_count": len(rows),
        "logical_total_size_bytes": total_size,
        "logical_total_size_human": _human_bytes(total_size),
        "deduplicated_across_libraries": False,
        "libraries": rows,
        "errors": errors,
    }


@mcp.tool(
    description=(
        "Return detailed cached Tautulli statistics for one exact Plex library, including movie/show/season/episode "
        "or artist/album/track counts, logical media size, collection count when available, and cache timestamp."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def plex_reporting_library_stats(library_name: str) -> dict:
    library = _tautulli_exact_library(library_name)
    result = _reporting_library_row(library)
    section_id = library.get("section_id")

    try:
        details = _tautulli_api("get_library", {"section_id": section_id, "include_last_accessed": 1}) or {}
        result["library_details"] = details
    except Exception as exc:
        result["library_details_error"] = str(exc)

    try:
        collections = _tautulli_api("get_collections_table", {"section_id": section_id}) or {}
        if isinstance(collections, dict):
            result["collection_count"] = _safe_int(collections.get("recordsTotal"), 0)
    except Exception as exc:
        result["collection_count_error"] = str(exc)

    return result


@mcp.tool(
    description=(
        "Report logical media storage from Tautulli for one library or all libraries. This is media-file size "
        "reported by Plex/Tautulli, not filesystem allocated blocks, snapshots, recycle bins, or NAS overhead."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def plex_reporting_storage(library_name: Optional[str] = None) -> dict:
    if library_name:
        row = _reporting_library_row(_tautulli_exact_library(library_name))
        return {
            "source": "Tautulli cached library media info",
            "logical_size_definition": "Plex/Tautulli media file sizes, not filesystem allocated blocks",
            "library": row,
        }
    summary = plex_reporting_summary()
    return {
        "source": summary.get("source"),
        "logical_size_definition": "Plex/Tautulli media file sizes, not filesystem allocated blocks",
        "logical_total_size_bytes": summary.get("logical_total_size_bytes"),
        "logical_total_size_human": summary.get("logical_total_size_human"),
        "deduplicated_across_libraries": False,
        "libraries": summary.get("libraries", []),
        "errors": summary.get("errors", []),
    }


@mcp.tool(
    description=(
        "Return one paged slice of Tautulli's cached media-info table for an exact library. Useful for reporting "
        "without re-enumerating Plex. Supports sorting and search. Maximum 500 rows per call."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def plex_reporting_library_items(
    library_name: str,
    start: int = 0,
    length: int = 100,
    order_column: str = "sort_title",
    order_dir: str = "asc",
    search: Optional[str] = None,
) -> dict:
    allowed_order = {
        "added_at", "sort_title", "container", "bitrate", "video_codec", "video_resolution",
        "video_framerate", "audio_codec", "audio_channels", "file_size", "last_played", "play_count"
    }
    if order_column not in allowed_order:
        raise ValueError(f"Unsupported order_column: {order_column}")
    if order_dir not in {"asc", "desc"}:
        raise ValueError("order_dir must be 'asc' or 'desc'.")

    library = _tautulli_exact_library(library_name)
    length = max(1, min(int(length), 500))
    page = _tautulli_media_info(
        library.get("section_id"),
        start=max(0, int(start)),
        length=length,
        order_column=order_column,
        order_dir=order_dir,
        search=search,
    )
    rows = page.get("data") or []
    return {
        "library": library.get("section_name"),
        "section_id": str(library.get("section_id")),
        "start": max(0, int(start)),
        "returned": len(rows),
        "records_total": _safe_int(page.get("recordsTotal"), 0),
        "records_filtered": _safe_int(page.get("recordsFiltered"), 0),
        "filtered_file_size_bytes": _safe_int(page.get("filtered_file_size"), 0),
        "filtered_file_size_human": _human_bytes(page.get("filtered_file_size")),
        "total_file_size_bytes": _safe_int(page.get("total_file_size"), 0),
        "total_file_size_human": _human_bytes(page.get("total_file_size")),
        "last_refreshed": _safe_int(page.get("last_refreshed"), 0) or None,
        "items": [_normalized_media_row(row, library.get("section_name")) for row in rows],
    }


@mcp.tool(
    description=(
        "Aggregate a Tautulli cached library by one field and return counts plus logical bytes per bucket. "
        "Supported group_by values: media_type, year, container, video_codec, video_resolution, video_framerate, "
        "audio_codec, audio_channels. Processing occurs locally and only the aggregate crosses the tunnel."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def plex_reporting_media_breakdown(library_name: str, group_by: str) -> dict:
    allowed = {
        "media_type", "year", "container", "video_codec", "video_resolution",
        "video_framerate", "audio_codec", "audio_channels"
    }
    if group_by not in allowed:
        raise ValueError(f"Unsupported group_by: {group_by}")

    library = _tautulli_exact_library(library_name)
    rows = _tautulli_all_media_rows(library.get("section_id"))
    buckets = {}
    for row in rows:
        value = row.get(group_by)
        key = str(value).strip() if value not in (None, "") else "Unknown"
        bucket = buckets.setdefault(key, {"value": key, "count": 0, "logical_size_bytes": 0})
        bucket["count"] += 1
        bucket["logical_size_bytes"] += _safe_int(row.get("file_size"), 0)

    result_rows = sorted(
        buckets.values(),
        key=lambda item: (-item["count"], item["value"].casefold()),
    )
    for item in result_rows:
        item["logical_size_human"] = _human_bytes(item["logical_size_bytes"])

    unknown_count = next((item["count"] for item in result_rows if item["value"] == "Unknown"), 0)
    return {
        "library": library.get("section_name"),
        "library_type": library.get("section_type"),
        "group_by": group_by,
        "source_rows": len(rows),
        "unknown_count": unknown_count,
        "note": (
            "Tautulli's top-level TV/music reporting rows may not carry per-episode/per-track technical fields; "
            "use a level-2 metadata export for full file-part detail."
            if unknown_count else None
        ),
        "buckets": result_rows,
    }


@mcp.tool(
    description=(
        "Return the largest cached Tautulli media rows by logical file size for one library or across all libraries. "
        "For TV and music, top-level rows can represent aggregate show or artist size. Maximum 100 results."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def plex_reporting_largest_items(library_name: Optional[str] = None, limit: int = 25) -> dict:
    limit = max(1, min(int(limit), 100))
    libraries = [_tautulli_exact_library(library_name)] if library_name else _tautulli_libraries()
    rows = []
    errors = []

    for library in libraries:
        try:
            page = _tautulli_media_info(
                library.get("section_id"),
                start=0,
                length=limit,
                order_column="file_size",
                order_dir="desc",
            )
            rows.extend(
                _normalized_media_row(row, library.get("section_name"))
                for row in (page.get("data") or [])
            )
        except Exception as exc:
            errors.append({"library": library.get("section_name"), "error": str(exc)})

    rows.sort(key=lambda row: -_safe_int(row.get("file_size_bytes"), 0))
    return {
        "limit": limit,
        "items": rows[:limit],
        "errors": errors,
    }


@mcp.tool(
    description=(
        "Query Tautulli watch history with optional library, media type, user, and inclusive date range. "
        "Returns compact history rows plus Tautulli's filtered duration totals. Maximum 500 rows per call."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def plex_reporting_history(
    library_name: Optional[str] = None,
    media_type: Optional[str] = None,
    user: Optional[str] = None,
    after: Optional[str] = None,
    before: Optional[str] = None,
    start: int = 0,
    length: int = 100,
) -> dict:
    params = {
        "grouping": 1,
        "start": max(0, int(start)),
        "length": max(1, min(int(length), 500)),
        "order_column": "date",
        "order_dir": "desc",
    }
    if library_name:
        params["section_id"] = _tautulli_exact_library(library_name).get("section_id")
    if media_type:
        params["media_type"] = media_type
    if user:
        params["user"] = user
    if after:
        params["after"] = after
    if before:
        params["before"] = before

    data = _tautulli_api("get_history", params=params, timeout=120) or {}
    rows = data.get("data") or [] if isinstance(data, dict) else []
    compact = []
    for row in rows:
        compact.append({
            "date": row.get("date"),
            "date_utc": _timestamp_iso(row.get("date")),
            "user": row.get("friendly_name") or row.get("user"),
            "full_title": row.get("full_title"),
            "title": row.get("title"),
            "grandparent_title": row.get("grandparent_title"),
            "media_type": row.get("media_type"),
            "year": row.get("year"),
            "play_duration": _safe_int(row.get("play_duration"), 0),
            "percent_complete": row.get("percent_complete"),
            "watched_status": row.get("watched_status"),
            "transcode_decision": row.get("transcode_decision"),
            "player": row.get("player"),
            "platform": row.get("platform"),
            "rating_key": str(row.get("rating_key")) if row.get("rating_key") not in (None, "") else None,
        })

    return {
        "records_total": _safe_int(data.get("recordsTotal"), 0) if isinstance(data, dict) else len(compact),
        "records_filtered": _safe_int(data.get("recordsFiltered"), 0) if isinstance(data, dict) else len(compact),
        "total_duration": data.get("total_duration") if isinstance(data, dict) else None,
        "filter_duration": data.get("filter_duration") if isinstance(data, dict) else None,
        "start": max(0, int(start)),
        "returned": len(compact),
        "history": compact,
    }


@mcp.tool(
    description=(
        "Return Tautulli's pre-aggregated top/popular statistics for plays or duration over a time range. "
        "Useful for top movies, TV, music, libraries, users, platforms, last watched, or concurrency without "
        "transmitting raw history."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def plex_reporting_top_stats(
    time_range: int = 30,
    stats_type: str = "plays",
    stat_id: Optional[str] = None,
    library_name: Optional[str] = None,
    count: int = 10,
    before: Optional[str] = None,
    after: Optional[str] = None,
):
    if stats_type not in {"plays", "duration"}:
        raise ValueError("stats_type must be 'plays' or 'duration'.")
    params = {
        "time_range": max(1, int(time_range)),
        "stats_type": stats_type,
        "stats_start": 0,
        "stats_count": max(1, min(int(count), 100)),
    }
    if stat_id:
        params["stat_id"] = stat_id
    if library_name:
        params["section_id"] = _tautulli_exact_library(library_name).get("section_id")
    if before:
        params["before"] = before
    if after:
        params["after"] = after
    return _tautulli_api("get_home_stats", params=params, timeout=120)


@mcp.tool(
    description=(
        "List the metadata and media-info fields Tautulli can include in an export. Useful for discovering "
        "advanced CSV/JSON fields before starting a custom inventory export."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def plex_reporting_export_fields(media_type: str, sub_media_type: Optional[str] = None):
    params = {"media_type": media_type}
    if sub_media_type:
        params["sub_media_type"] = sub_media_type
    return _tautulli_api("get_export_fields", params=params, timeout=120)


@mcp.tool(
    description=(
        "Start a Tautulli metadata export for one exact Plex library. This does not change Plex media or metadata; "
        "it only creates a reporting export inside Tautulli. Media-info level 2 includes physical part path and size."
    ),
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=False),
)
def plex_reporting_start_export(
    library_name: str,
    file_format: str = "csv",
    metadata_level: int = 2,
    media_info_level: int = 2,
    custom_fields: Optional[list[str]] = None,
) -> dict:
    file_format = str(file_format).lower()
    if file_format not in {"csv", "json", "xml", "m3u"}:
        raise ValueError("file_format must be csv, json, xml, or m3u.")
    metadata_level = int(metadata_level)
    media_info_level = int(media_info_level)
    if metadata_level not in {0, 1, 2, 3, 9}:
        raise ValueError("metadata_level must be 0, 1, 2, 3, or 9.")
    if media_info_level not in {0, 1, 2, 3, 9}:
        raise ValueError("media_info_level must be 0, 1, 2, 3, or 9.")

    library = _tautulli_exact_library(library_name)
    params = {
        "section_id": library.get("section_id"),
        "file_format": file_format,
        "metadata_level": metadata_level,
        "media_info_level": media_info_level,
        "thumb_level": 0,
        "art_level": 0,
        "individual_files": 0,
    }
    if custom_fields:
        params["custom_fields"] = ",".join(str(field) for field in custom_fields if str(field).strip())

    data = _tautulli_api("export_metadata", params=params, timeout=120)
    export_id = None
    if isinstance(data, dict):
        export_id = data.get("export_id")
    return {
        "started": export_id is not None,
        "library": library.get("section_name"),
        "section_id": str(library.get("section_id")),
        "export_id": export_id,
        "file_format": file_format,
        "metadata_level": metadata_level,
        "media_info_level": media_info_level,
        "custom_fields": custom_fields or [],
        "note": "Export is generated locally by Tautulli and does not modify Plex media or metadata.",
    }


@mcp.tool(
    description=(
        "Return the status/details of a Tautulli reporting export for one exact library and export ID. Read-only."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def plex_reporting_export_status(library_name: str, export_id: int) -> dict:
    library = _tautulli_exact_library(library_name)
    data = _tautulli_api(
        "get_exports_table",
        {
            "section_id": library.get("section_id"),
            "start": 0,
            "length": 500,
            "order_dir": "desc",
        },
        timeout=120,
    ) or {}
    rows = data.get("data") or [] if isinstance(data, dict) else []
    for row in rows:
        if _safe_int(row.get("export_id"), -1) == int(export_id):
            result = dict(row)
            if "file_size" in result:
                result["file_size_human"] = _human_bytes(result.get("file_size"))
            return {"found": True, "library": library.get("section_name"), "export": result}
    return {"found": False, "library": library.get("section_name"), "export_id": int(export_id)}


def _download_export_to_local_cache(export_id: int) -> dict:
    export_id = int(export_id)
    url = _tautulli_endpoint("download_export", {"export_id": export_id})
    request = Request(url, headers={"User-Agent": "MediaStack-Control-Gateway/3.4.6"})
    try:
        with urlopen(request, timeout=300) as response:
            raw = response.read()
            filename = None
            try:
                filename = response.headers.get_filename()
            except Exception:
                filename = None
    except Exception as exc:
        raise RuntimeError(f"Unable to download Tautulli export {export_id}: {exc}") from exc

    if not filename:
        filename = f"tautulli-export-{export_id}.dat"
    safe_name = os.path.basename(filename).replace("..", "_")
    cache_dir = Path(REPORT_EXPORT_DIR)
    cache_dir.mkdir(parents=True, exist_ok=True)
    destination = cache_dir / f"export-{export_id}-{safe_name}"
    destination.write_bytes(raw)
    return {
        "export_id": export_id,
        "filename": destination.name,
        "local_path": str(destination),
        "size_bytes": len(raw),
        "size_human": _human_bytes(len(raw)),
    }


@mcp.tool(
    description=(
        "Download a completed Tautulli reporting export once to the MCP server's local export cache. "
        "This only creates a local reporting file; it does not modify Plex or Tautulli library metadata."
    ),
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=True),
)
def plex_reporting_prepare_export(export_id: int) -> dict:
    cache_dir = Path(REPORT_EXPORT_DIR)
    cache_dir.mkdir(parents=True, exist_ok=True)
    existing = sorted(cache_dir.glob(f"export-{int(export_id)}-*"))
    if existing:
        path = existing[0]
        size = path.stat().st_size
        return {
            "prepared": True,
            "cached": True,
            "export_id": int(export_id),
            "filename": path.name,
            "local_path": str(path),
            "size_bytes": size,
            "size_human": _human_bytes(size),
        }
    result = _download_export_to_local_cache(export_id)
    result["prepared"] = True
    result["cached"] = False
    return result


@mcp.tool(
    description=(
        "Read one base64 chunk from a locally prepared Tautulli export. This allows large CSV/JSON exports to be "
        "transferred only when explicitly requested instead of sending the whole library during normal reporting."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def plex_reporting_read_export_chunk(
    export_id: int,
    offset_bytes: int = 0,
    max_bytes: int = 131072,
) -> dict:
    cache_dir = Path(REPORT_EXPORT_DIR)
    existing = sorted(cache_dir.glob(f"export-{int(export_id)}-*"))
    if not existing:
        raise ValueError(
            f"Export {export_id} is not prepared locally. Call plex_reporting_prepare_export first."
        )
    path = existing[0]
    total_size = path.stat().st_size
    offset = max(0, int(offset_bytes))
    chunk_size = max(1024, min(int(max_bytes), 262144))
    if offset > total_size:
        offset = total_size

    with path.open("rb") as handle:
        handle.seek(offset)
        chunk = handle.read(chunk_size)

    next_offset = offset + len(chunk)
    return {
        "export_id": int(export_id),
        "filename": path.name,
        "offset_bytes": offset,
        "chunk_bytes": len(chunk),
        "next_offset_bytes": next_offset,
        "total_size_bytes": total_size,
        "eof": next_offset >= total_size,
        "encoding": "base64",
        "data": base64.b64encode(chunk).decode("ascii"),
    }


@mcp.tool(
    description=(
        "Return item count and logical media size for one exact Plex collection by joining the live collection "
        "membership to Tautulli's cached top-level media rows. Processing stays local and only the aggregate crosses the tunnel."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def plex_reporting_collection_stats(library_name: str, collection_title: str) -> dict:
    server = _plex()
    section = _exact_section(server, library_name)
    collection = _exact_collection(section, collection_title)
    items = list(collection.items())

    library = _tautulli_exact_library(section.title)
    rows = _tautulli_all_media_rows(library.get("section_id"))
    by_key = {
        str(row.get("rating_key")): row
        for row in rows
        if row.get("rating_key") not in (None, "")
    }

    matched = []
    unmatched = []
    total_size = 0
    for item in items:
        rating_key = str(getattr(item, "ratingKey", ""))
        row = by_key.get(rating_key)
        if row is None:
            unmatched.append({
                "title": getattr(item, "title", None),
                "rating_key": rating_key or None,
            })
            continue
        normalized = _normalized_media_row(row, section.title)
        matched.append(normalized)
        total_size += _safe_int(normalized.get("file_size_bytes"), 0)

    matched.sort(key=lambda row: -_safe_int(row.get("file_size_bytes"), 0))
    return {
        "library": section.title,
        "collection": collection.title,
        "smart": bool(getattr(collection, "smart", False)),
        "item_count": len(items),
        "matched_reporting_items": len(matched),
        "unmatched_reporting_items": len(unmatched),
        "logical_size_bytes": total_size,
        "logical_size_human": _human_bytes(total_size),
        "largest_items": matched[:25],
        "unmatched": unmatched[:100],
        "note": "Logical size is based on Tautulli cached top-level media rows for the collection members.",
    }


@mcp.tool(
    description=(
        "Start one Tautulli metadata export job for every tracked Plex library. Returns one export ID per library. "
        "This creates reporting files only and does not change Plex media or metadata."
    ),
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=False),
)
def plex_reporting_start_all_exports(
    file_format: str = "csv",
    metadata_level: int = 2,
    media_info_level: int = 2,
    custom_fields: Optional[list[str]] = None,
) -> dict:
    file_format = str(file_format).lower()
    if file_format not in {"csv", "json", "xml", "m3u"}:
        raise ValueError("file_format must be csv, json, xml, or m3u.")
    metadata_level = int(metadata_level)
    media_info_level = int(media_info_level)
    if metadata_level not in {0, 1, 2, 3, 9}:
        raise ValueError("metadata_level must be 0, 1, 2, 3, or 9.")
    if media_info_level not in {0, 1, 2, 3, 9}:
        raise ValueError("media_info_level must be 0, 1, 2, 3, or 9.")

    results = []
    errors = []
    for library in _tautulli_libraries():
        params = {
            "section_id": library.get("section_id"),
            "file_format": file_format,
            "metadata_level": metadata_level,
            "media_info_level": media_info_level,
            "thumb_level": 0,
            "art_level": 0,
            "individual_files": 0,
        }
        if custom_fields:
            params["custom_fields"] = ",".join(str(field) for field in custom_fields if str(field).strip())
        try:
            data = _tautulli_api("export_metadata", params=params, timeout=120)
            export_id = data.get("export_id") if isinstance(data, dict) else None
            results.append({
                "library": library.get("section_name"),
                "section_id": str(library.get("section_id")),
                "export_id": export_id,
                "started": export_id is not None,
            })
        except Exception as exc:
            errors.append({"library": library.get("section_name"), "error": str(exc)})

    return {
        "file_format": file_format,
        "metadata_level": metadata_level,
        "media_info_level": media_info_level,
        "exports": results,
        "errors": errors,
    }


# ===========================================================================
# Sonarr / Radarr / Lidarr integration
# ===========================================================================
ARR_APPS = {
    "sonarr": {"url": SONARR_URL.rstrip("/"), "api_key": SONARR_API_KEY, "api_version": "v3"},
    "radarr": {"url": RADARR_URL.rstrip("/"), "api_key": RADARR_API_KEY, "api_version": "v3"},
    "lidarr": {"url": LIDARR_URL.rstrip("/"), "api_key": LIDARR_API_KEY, "api_version": "v1"},
}
ARR_DELETE_CONFIRMATIONS: dict[str, dict] = {}
ARR_EXPORTS: dict[str, str] = {}


def _arr_cfg(app: str) -> dict:
    key = str(app or "").strip().casefold()
    if key not in ARR_APPS:
        raise ValueError("app must be one of: sonarr, radarr, lidarr")
    cfg = ARR_APPS[key]
    if not cfg["url"]:
        raise RuntimeError(f"{key.title()} URL is not configured.")
    if not cfg["api_key"]:
        raise RuntimeError(f"{key.title()} API key is not configured.")
    return cfg


def _arr_api(
    app: str,
    method: str,
    path: str,
    params: Optional[dict] = None,
    body=None,
    timeout: int = 30,
):
    cfg = _arr_cfg(app)
    path = str(path or "").lstrip("/")
    url = f'{cfg["url"]}/api/{cfg["api_version"]}/{path}'
    if params:
        clean = {k: v for k, v in params.items() if v is not None}
        if clean:
            url += "?" + urlencode(clean, doseq=True)

    data = None
    headers = {
        "X-Api-Key": cfg["api_key"],
        "Accept": "application/json",
        "User-Agent": "MediaStack-Control-Gateway-Arr/3.4.5",
    }
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"

    request = Request(url, data=data, headers=headers, method=method.upper())
    try:
        with urlopen(request, timeout=timeout) as response:
            payload = response.read()
    except HTTPError as exc:
        try:
            detail = exc.read().decode("utf-8", errors="replace")[:1000]
        except Exception:
            detail = ""
        raise RuntimeError(
            f"{app.title()} API {method.upper()} {path} failed with HTTP {exc.code}: {detail or exc.reason}"
        ) from exc
    except URLError as exc:
        raise RuntimeError(f"{app.title()} API is unreachable at {cfg['url']}: {exc.reason}") from exc
    except Exception as exc:
        raise RuntimeError(f"{app.title()} API request failed for {method.upper()} {path}: {exc}") from exc

    if not payload:
        return None
    text = payload.decode("utf-8", errors="replace")
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return text


def _arr_command(app: str, name: str, **kwargs) -> dict:
    payload = {"name": name}
    payload.update({k: v for k, v in kwargs.items() if v is not None})
    result = _arr_api(app, "POST", "command", body=payload, timeout=60)
    return result if isinstance(result, dict) else {"result": result}


def _arr_file_quality(file_row: Optional[dict]) -> dict:
    if not isinstance(file_row, dict):
        return {"name": None, "resolution": None, "source": None, "cutoff_unmet": None}
    model = file_row.get("quality") or {}
    quality = model.get("quality") if isinstance(model, dict) else {}
    if not isinstance(quality, dict):
        quality = {}
    resolution = quality.get("resolution")
    try:
        resolution = int(resolution) if resolution is not None else None
    except (TypeError, ValueError):
        resolution = None
    return {
        "name": quality.get("name") or model.get("name") if isinstance(model, dict) else None,
        "resolution": resolution,
        "source": quality.get("source"),
        "cutoff_unmet": file_row.get("qualityCutoffNotMet"),
    }


def _arr_audio_bitrate_kbps(file_row: Optional[dict]) -> Optional[int]:
    if not isinstance(file_row, dict):
        return None
    media = file_row.get("mediaInfo") or {}
    raw = media.get("audioBitRate") if isinstance(media, dict) else None
    if raw is not None:
        match = re.search(r"([0-9]+(?:\.[0-9]+)?)", str(raw).replace(",", ""))
        if match:
            value = float(match.group(1))
            # Lidarr commonly returns strings representing kbps; tolerate bps if obviously large.
            if value > 10000:
                value /= 1000.0
            return int(round(value))
    quality = _arr_file_quality(file_row).get("name") or ""
    match = re.search(r"(?:-|\b)(\d{2,4})(?:k|kbps)?\b", quality, re.I)
    return int(match.group(1)) if match else None


def _human_bytes(value: int) -> str:
    size = float(value or 0)
    units = ["B", "KB", "MB", "GB", "TB", "PB"]
    for unit in units:
        if abs(size) < 1024.0 or unit == units[-1]:
            return f"{size:.2f} {unit}" if unit != "B" else f"{int(size)} B"
        size /= 1024.0
    return f"{int(value or 0)} B"


def _arr_item_label(app: str, item: dict) -> dict:
    if app == "radarr":
        return {
            "id": item.get("id"),
            "title": item.get("title"),
            "year": item.get("year"),
            "path": item.get("path"),
            "monitored": item.get("monitored"),
            "quality_profile_id": item.get("qualityProfileId"),
            "has_file": item.get("hasFile"),
            "tmdb_id": item.get("tmdbId"),
        }
    if app == "sonarr":
        stats = item.get("statistics") or {}
        return {
            "id": item.get("id"),
            "title": item.get("title"),
            "year": item.get("year"),
            "path": item.get("path"),
            "monitored": item.get("monitored"),
            "quality_profile_id": item.get("qualityProfileId"),
            "tvdb_id": item.get("tvdbId"),
            "episode_count": stats.get("episodeCount"),
            "episode_file_count": stats.get("episodeFileCount"),
            "size_on_disk": stats.get("sizeOnDisk"),
        }
    stats = item.get("statistics") or {}
    return {
        "id": item.get("id"),
        "artist": item.get("artistName"),
        "path": item.get("path"),
        "monitored": item.get("monitored"),
        "quality_profile_id": item.get("qualityProfileId"),
        "metadata_profile_id": item.get("metadataProfileId"),
        "foreign_artist_id": item.get("foreignArtistId"),
        "album_count": stats.get("albumCount"),
        "track_file_count": stats.get("trackFileCount"),
        "size_on_disk": stats.get("sizeOnDisk"),
    }


def _arr_all_files(app: str, items: Optional[list[dict]] = None) -> list[dict]:
    """Return all managed file rows using API shapes supported by current Arr releases.

    The standalone moviefile/episodefile/trackfile endpoints require an owner ID,
    so they cannot be called once without parameters. Radarr already embeds its
    MovieFileResource in each MovieResource. Sonarr and Lidarr require one file
    query per series/artist respectively.
    """
    name = str(app).casefold()
    if name not in ("radarr", "sonarr", "lidarr"):
        raise ValueError("app must be one of: sonarr, radarr, lidarr")

    source_items = items if items is not None else _arr_all_items(name)
    files: list[dict] = []

    if name == "radarr":
        for movie in source_items:
            movie_file = movie.get("movieFile") if isinstance(movie, dict) else None
            if not isinstance(movie_file, dict) or not movie_file:
                continue
            row = dict(movie_file)
            row.setdefault("movieId", movie.get("id"))
            if row.get("qualityCutoffNotMet") is None and movie.get("qualityCutoffNotMet") is not None:
                row["qualityCutoffNotMet"] = movie.get("qualityCutoffNotMet")
            files.append(row)
        return files

    endpoint = "episodefile" if name == "sonarr" else "trackfile"
    owner_param = "seriesId" if name == "sonarr" else "artistId"
    owner_label = "series" if name == "sonarr" else "artist"

    for item in source_items:
        if not isinstance(item, dict) or item.get("id") is None:
            continue
        owner_id = int(item.get("id"))
        data = _arr_api(name, "GET", endpoint, params={owner_param: owner_id}, timeout=120)
        if data is None:
            continue
        if not isinstance(data, list):
            raise RuntimeError(
                f"{name.title()} API returned an unexpected {endpoint} payload for {owner_label} ID {owner_id}."
            )
        for file_row in data:
            if not isinstance(file_row, dict):
                continue
            row = dict(file_row)
            row.setdefault(owner_param, owner_id)
            files.append(row)
    return files


def _arr_all_items(app: str) -> list[dict]:
    endpoint = {"radarr": "movie", "sonarr": "series", "lidarr": "artist"}[app]
    data = _arr_api(app, "GET", endpoint, timeout=120)
    return data if isinstance(data, list) else []


def _arr_file_owner_id(app: str, file_row: dict) -> Optional[int]:
    field = {"radarr": "movieId", "sonarr": "seriesId", "lidarr": "artistId"}[app]
    value = file_row.get(field)
    try:
        return int(value) if value is not None else None
    except (TypeError, ValueError):
        return None


def _arr_quality_matches(
    app: str,
    max_resolution: Optional[int] = None,
    max_audio_bitrate_kbps: Optional[int] = None,
    include_equal: bool = False,
    include_missing: bool = False,
    cutoff_unmet_only: bool = False,
    root_folder_contains: Optional[str] = None,
    monitored: Optional[bool] = None,
    quality_profile_id: Optional[int] = None,
) -> list[dict]:
    items = _arr_all_items(app)
    files = _arr_all_files(app, items=items)
    files_by_owner: dict[int, list[dict]] = {}
    for file_row in files:
        owner = _arr_file_owner_id(app, file_row)
        if owner is not None:
            files_by_owner.setdefault(owner, []).append(file_row)

    root_needle = root_folder_contains.casefold() if root_folder_contains else None
    matches = []
    for item in items:
        try:
            item_id = int(item.get("id"))
        except (TypeError, ValueError):
            continue
        if monitored is not None and bool(item.get("monitored")) != monitored:
            continue
        if quality_profile_id is not None and int(item.get("qualityProfileId") or 0) != int(quality_profile_id):
            continue
        if root_needle and root_needle not in str(item.get("path") or "").casefold():
            continue

        owned = files_by_owner.get(item_id, [])
        if not owned and not include_missing:
            continue

        low_files = []
        cutoff_files = []
        values = []
        for file_row in owned:
            quality = _arr_file_quality(file_row)
            if app in ("radarr", "sonarr"):
                value = quality.get("resolution")
                if value is not None:
                    values.append(value)
                    if max_resolution is not None:
                        is_low = value <= max_resolution if include_equal else value < max_resolution
                        if is_low:
                            low_files.append(file_row)
            else:
                value = _arr_audio_bitrate_kbps(file_row)
                if value is not None:
                    values.append(value)
                    if max_audio_bitrate_kbps is not None:
                        is_low = value <= max_audio_bitrate_kbps if include_equal else value < max_audio_bitrate_kbps
                        if is_low:
                            low_files.append(file_row)
            if quality.get("cutoff_unmet"):
                cutoff_files.append(file_row)

        threshold_requested = max_resolution is not None or max_audio_bitrate_kbps is not None
        threshold_match = bool(low_files) or (include_missing and not owned)
        cutoff_match = bool(cutoff_files) or (include_missing and not owned)
        if cutoff_unmet_only and not cutoff_match:
            continue
        if threshold_requested and not threshold_match:
            continue
        if not threshold_requested and not cutoff_unmet_only and not (include_missing and not owned):
            continue

        entry = _arr_item_label(app, item)
        entry.update({
            "file_count": len(owned),
            "matching_file_count": len(low_files) if threshold_requested else len(cutoff_files),
            "missing": not owned,
        })
        if values:
            entry["lowest_file_quality_value"] = min(values)
            entry["highest_file_quality_value"] = max(values)
        matches.append(entry)
    return matches


def _arr_run_search(app: str, item_ids: list[int]) -> dict:
    ids = sorted({int(i) for i in item_ids})
    if not ids:
        return {"requested": 0, "commands": [], "errors": []}
    commands = []
    errors = []
    if app == "radarr":
        try:
            command = _arr_command("radarr", "MoviesSearch", movieIds=ids)
            commands.append({"item_ids": ids, "command_id": command.get("id"), "name": command.get("name")})
        except Exception as exc:
            errors.append({"item_ids": ids, "error": str(exc)})
    elif app == "sonarr":
        for item_id in ids:
            try:
                command = _arr_command("sonarr", "SeriesSearch", seriesId=item_id)
                commands.append({"item_id": item_id, "command_id": command.get("id"), "name": command.get("name")})
            except Exception as exc:
                errors.append({"item_id": item_id, "error": str(exc)})
    else:
        for item_id in ids:
            try:
                command = _arr_command("lidarr", "ArtistSearch", artistId=item_id)
                commands.append({"item_id": item_id, "command_id": command.get("id"), "name": command.get("name")})
            except Exception as exc:
                errors.append({"item_id": item_id, "error": str(exc)})
    return {"requested": len(ids), "commands_started": len(commands), "commands": commands, "errors": errors}


@mcp.tool(
    description=(
        "Lightweight Sonarr, Radarr, and Lidarr connectivity check. Returns application version, URL, "
        "health issue count, and configured API generation without enumerating the full libraries. Read-only."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def arr_status() -> dict:
    results = {}
    for app in ("sonarr", "radarr", "lidarr"):
        try:
            status = _arr_api(app, "GET", "system/status", timeout=15) or {}
            health = _arr_api(app, "GET", "health", timeout=15) or []
            results[app] = {
                "available": True,
                "url": ARR_APPS[app]["url"],
                "api_version": ARR_APPS[app]["api_version"],
                "version": status.get("version") if isinstance(status, dict) else None,
                "app_name": status.get("appName") if isinstance(status, dict) else None,
                "instance_name": status.get("instanceName") if isinstance(status, dict) else None,
                "health_issue_count": len(health) if isinstance(health, list) else None,
            }
        except Exception as exc:
            results[app] = {"available": False, "url": ARR_APPS[app]["url"], "error": str(exc)}
    return {
        "applications": results,
        "all_available": all(bool(row.get("available")) for row in results.values()),
        "note": "This status check intentionally avoids full library enumeration so connectivity checks remain fast.",
    }


@mcp.tool(
    description="Return health warnings/errors for Sonarr, Radarr, Lidarr, or all three. Read-only.",
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def arr_health(app: Optional[str] = None) -> dict:
    apps = [str(app).casefold()] if app else ["sonarr", "radarr", "lidarr"]
    result = {}
    for name in apps:
        _arr_cfg(name)
        try:
            result[name] = _arr_api(name, "GET", "health") or []
        except Exception as exc:
            result[name] = {"error": str(exc)}
    return result


def _arr_item_storage_stats(app: str, items: list[dict]) -> tuple[int, int]:
    """Return logical bytes and managed-file count from parent item statistics.

    This avoids calling file endpoints without their required owner IDs. Sonarr
    and Lidarr expose aggregate size/file counts in statistics; Radarr exposes
    the managed MovieFileResource on each movie and may also expose sizeOnDisk.
    """
    size = 0
    file_count = 0
    for item in items:
        if not isinstance(item, dict):
            continue
        if app == "radarr":
            movie_file = item.get("movieFile") or {}
            if isinstance(movie_file, dict) and movie_file:
                file_size = int(movie_file.get("size") or item.get("sizeOnDisk") or 0)
                if file_size > 0 or bool(item.get("hasFile")):
                    file_count += 1
                size += file_size
            else:
                fallback = int(item.get("sizeOnDisk") or 0)
                size += fallback
                if bool(item.get("hasFile")):
                    file_count += 1
            continue

        statistics = item.get("statistics") or {}
        if not isinstance(statistics, dict):
            statistics = {}
        size += int(statistics.get("sizeOnDisk") or 0)
        if app == "sonarr":
            file_count += int(statistics.get("episodeFileCount") or 0)
        else:
            file_count += int(statistics.get("trackFileCount") or 0)
    return size, file_count


@mcp.tool(
    description=(
        "Report logical media-file storage for Sonarr, Radarr, Lidarr, or all three using library/item statistics "
        "reported by each application. Read-only and does not inspect filesystem allocation/snapshots."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def arr_storage(app: Optional[str] = None) -> dict:
    apps = [str(app).casefold()] if app else ["sonarr", "radarr", "lidarr"]
    result = {}
    total = 0
    for name in apps:
        _arr_cfg(name)
        try:
            items = _arr_all_items(name)
            size, file_count = _arr_item_storage_stats(name, items)
            total += size
            result[name] = {
                "item_count": len(items),
                "file_count": file_count,
                "logical_size_bytes": size,
                "logical_size_human": _human_bytes(size),
            }
        except Exception as exc:
            result[name] = {"error": str(exc)}
    return {"applications": result, "logical_total_size_bytes": total, "logical_total_size_human": _human_bytes(total)}


@mcp.tool(
    description=(
        "Return configured root folders, quality profiles, tags, and (for Lidarr) metadata profiles for one app. "
        "Use this before adding media so the user can explicitly choose the correct root folder/profile. Read-only."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def arr_config(app: str) -> dict:
    name = str(app).casefold()
    _arr_cfg(name)
    result = {
        "app": name,
        "root_folders": _arr_api(name, "GET", "rootfolder") or [],
        "quality_profiles": _arr_api(name, "GET", "qualityprofile") or [],
        "tags": _arr_api(name, "GET", "tag") or [],
    }
    if name == "lidarr":
        result["metadata_profiles"] = _arr_api(name, "GET", "metadataprofile") or []
    return result


@mcp.tool(
    description="Return the current download queue for Sonarr, Radarr, or Lidarr. Read-only. Maximum 500 rows.",
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def arr_queue(app: str, page: int = 1, page_size: int = 100) -> dict:
    name = str(app).casefold()
    _arr_cfg(name)
    page_size = max(1, min(int(page_size), 500))
    data = _arr_api(name, "GET", "queue", params={"page": max(1, int(page)), "pageSize": page_size}, timeout=60)
    return data if isinstance(data, dict) else {"records": data or []}


@mcp.tool(
    description="Return paged Sonarr, Radarr, or Lidarr history. Read-only. Maximum 500 rows per call.",
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def arr_history(app: str, page: int = 1, page_size: int = 100, event_type: Optional[int] = None) -> dict:
    name = str(app).casefold()
    _arr_cfg(name)
    page_size = max(1, min(int(page_size), 500))
    params = {"page": max(1, int(page)), "pageSize": page_size, "sortKey": "date", "sortDirection": "descending"}
    if event_type is not None:
        params["eventType"] = int(event_type)
    data = _arr_api(name, "GET", "history", params=params, timeout=60)
    return data if isinstance(data, dict) else {"records": data or []}


@mcp.tool(
    description="Return one Sonarr/Radarr/Lidarr command/job by ID. Read-only.",
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def arr_command_status(app: str, command_id: int) -> dict:
    name = str(app).casefold()
    _arr_cfg(name)
    data = _arr_api(name, "GET", f"command/{int(command_id)}")
    return data if isinstance(data, dict) else {"result": data}


@mcp.tool(
    description=(
        "List Radarr movies with compact file-quality details. Optional filters: monitored, has_file, root_folder_contains, "
        "quality_profile_id. Read-only."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def radarr_list_movies(
    monitored: Optional[bool] = None,
    has_file: Optional[bool] = None,
    root_folder_contains: Optional[str] = None,
    quality_profile_id: Optional[int] = None,
    offset: int = 0,
    max_results: int = 500,
) -> dict:
    movies = _arr_all_items("radarr")
    files = _arr_all_files("radarr", items=movies)
    file_map = {int(f.get("movieId")): f for f in files if f.get("movieId") is not None}
    needle = root_folder_contains.casefold() if root_folder_contains else None
    rows = []
    for movie in movies:
        if monitored is not None and bool(movie.get("monitored")) != monitored:
            continue
        actual_has_file = bool(movie.get("hasFile")) or int(movie.get("id") or 0) in file_map
        if has_file is not None and actual_has_file != has_file:
            continue
        if quality_profile_id is not None and int(movie.get("qualityProfileId") or 0) != int(quality_profile_id):
            continue
        if needle and needle not in str(movie.get("path") or "").casefold():
            continue
        row = _arr_item_label("radarr", movie)
        file_row = file_map.get(int(movie.get("id") or 0))
        quality = _arr_file_quality(file_row)
        row.update({
            "file_quality": quality.get("name"),
            "file_resolution": quality.get("resolution"),
            "quality_cutoff_unmet": quality.get("cutoff_unmet"),
            "file_size_bytes": int(file_row.get("size") or 0) if file_row else 0,
            "file_size_human": _human_bytes(int(file_row.get("size") or 0)) if file_row else "0 B",
            "file_path": file_row.get("path") if file_row else None,
        })
        rows.append(row)
    rows.sort(key=lambda r: (str(r.get("title") or "").casefold(), int(r.get("year") or 0)))
    offset = max(0, int(offset))
    max_results = max(1, min(int(max_results), 1000))
    return {"matched": len(rows), "offset": offset, "returned": len(rows[offset:offset + max_results]), "movies": rows[offset:offset + max_results]}


@mcp.tool(
    description="Search Radarr's movie lookup provider by title/term. Read-only; returns candidates with TMDB IDs.",
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def radarr_search_movie(term: str, max_results: int = 20) -> list[dict]:
    data = _arr_api("radarr", "GET", "movie/lookup", params={"term": term}, timeout=60) or []
    rows = []
    for item in data[:max(1, min(int(max_results), 100))]:
        rows.append({
            "title": item.get("title"), "year": item.get("year"), "tmdb_id": item.get("tmdbId"),
            "imdb_id": item.get("imdbId"), "title_slug": item.get("titleSlug"), "status": item.get("status"),
            "overview": item.get("overview"), "remote_poster": item.get("remotePoster"),
        })
    return rows


@mcp.tool(
    description=(
        "Add one exact TMDB movie to Radarr. root_folder_path and quality_profile_id are deliberately required so "
        "the assistant must ask the user which media path/profile to use instead of guessing. Can optionally search immediately."
    ),
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=False),
)
def radarr_add_movie(
    tmdb_id: int,
    root_folder_path: str,
    quality_profile_id: int,
    monitored: bool = True,
    search_on_add: bool = True,
    minimum_availability: str = "released",
    tags: Optional[list[int]] = None,
) -> dict:
    lookup = _arr_api("radarr", "GET", "movie/lookup/tmdb", params={"tmdbId": int(tmdb_id)}, timeout=60)
    if not isinstance(lookup, dict):
        raise ValueError(f"Radarr could not resolve TMDB ID {tmdb_id}.")
    payload = {
        "title": lookup.get("title"),
        "year": lookup.get("year"),
        "tmdbId": int(tmdb_id),
        "titleSlug": lookup.get("titleSlug"),
        "images": lookup.get("images") or [],
        "qualityProfileId": int(quality_profile_id),
        "rootFolderPath": str(root_folder_path),
        "monitored": bool(monitored),
        "minimumAvailability": minimum_availability,
        "tags": [int(x) for x in (tags or [])],
        "addOptions": {"searchForMovie": bool(search_on_add)},
    }
    result = _arr_api("radarr", "POST", "movie", body=payload, timeout=60)
    return _arr_item_label("radarr", result if isinstance(result, dict) else payload)


@mcp.tool(
    description=(
        "Update one existing Radarr movie. Omitted fields are preserved. Supports monitored state, quality profile, root folder, "
        "minimum availability, tags, and optional file move when the root folder changes. Does not delete media."
    ),
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=True),
)
def radarr_update_movie(
    movie_id: int,
    monitored: Optional[bool] = None,
    quality_profile_id: Optional[int] = None,
    root_folder_path: Optional[str] = None,
    minimum_availability: Optional[str] = None,
    tags: Optional[list[int]] = None,
    move_files: bool = False,
) -> dict:
    movie = _arr_api("radarr", "GET", f"movie/{int(movie_id)}")
    if not isinstance(movie, dict):
        raise ValueError(f"Radarr movie ID {movie_id} was not found.")
    if monitored is not None: movie["monitored"] = bool(monitored)
    if quality_profile_id is not None: movie["qualityProfileId"] = int(quality_profile_id)
    if root_folder_path is not None: movie["rootFolderPath"] = str(root_folder_path)
    if minimum_availability is not None: movie["minimumAvailability"] = minimum_availability
    if tags is not None: movie["tags"] = [int(x) for x in tags]
    updated = _arr_api("radarr", "PUT", f"movie/{int(movie_id)}", params={"moveFiles": bool(move_files)}, body=movie, timeout=60)
    return _arr_item_label("radarr", updated if isinstance(updated, dict) else movie)


@mcp.tool(
    description=(
        "Preview Radarr movies selected by current file resolution (for example below 1080), cutoff-unmet state, missing file, "
        "monitoring state, root folder, or quality profile. Read-only. Use before a bulk action when the scope is uncertain."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def radarr_bulk_quality_preview(
    max_resolution: Optional[int] = None,
    include_equal: bool = False,
    include_missing: bool = False,
    cutoff_unmet_only: bool = False,
    root_folder_contains: Optional[str] = None,
    monitored: Optional[bool] = None,
    quality_profile_id: Optional[int] = None,
    max_results: int = 500,
) -> dict:
    rows = _arr_quality_matches(
        "radarr", max_resolution=max_resolution, include_equal=include_equal, include_missing=include_missing,
        cutoff_unmet_only=cutoff_unmet_only, root_folder_contains=root_folder_contains,
        monitored=monitored, quality_profile_id=quality_profile_id,
    )
    max_results = max(1, min(int(max_results), 1000))
    return {"matched": len(rows), "returned": min(len(rows), max_results), "movies": rows[:max_results]}


@mcp.tool(
    description=(
        "Bulk-update Radarr movies selected by current file resolution/cutoff/missing conditions. Can set monitored state and/or "
        "quality profile and then start searches locally. This is a normal non-delete bulk write; explicit user instructions are sufficient."
    ),
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=False),
)
def radarr_bulk_quality_update(
    max_resolution: Optional[int] = None,
    include_equal: bool = False,
    include_missing: bool = False,
    cutoff_unmet_only: bool = False,
    root_folder_contains: Optional[str] = None,
    monitored_filter: Optional[bool] = None,
    quality_profile_filter_id: Optional[int] = None,
    set_monitored: Optional[bool] = True,
    set_quality_profile_id: Optional[int] = None,
    run_search: bool = True,
    max_items: int = 5000,
) -> dict:
    rows = _arr_quality_matches(
        "radarr", max_resolution=max_resolution, include_equal=include_equal, include_missing=include_missing,
        cutoff_unmet_only=cutoff_unmet_only, root_folder_contains=root_folder_contains,
        monitored=monitored_filter, quality_profile_id=quality_profile_filter_id,
    )
    if len(rows) > int(max_items):
        raise ValueError(f"Matched {len(rows)} movies, exceeding max_items={max_items}. Narrow the filter or raise max_items explicitly.")
    ids = [int(r["id"]) for r in rows]
    if not ids:
        return {"matched": 0, "updated": 0, "search": {"requested": 0}, "items": []}
    editor = {"movieIds": ids}
    if set_monitored is not None: editor["monitored"] = bool(set_monitored)
    if set_quality_profile_id is not None: editor["qualityProfileId"] = int(set_quality_profile_id)
    if len(editor) > 1:
        _arr_api("radarr", "PUT", "movie/editor", body=editor, timeout=120)
    search = _arr_run_search("radarr", ids) if run_search else {"requested": 0, "commands": [], "errors": []}
    return {"matched": len(ids), "updated": len(ids) if len(editor) > 1 else 0, "set_monitored": set_monitored,
            "set_quality_profile_id": set_quality_profile_id, "search": search, "items": rows[:100]}


@mcp.tool(
    description="Start a Radarr search for exact movie IDs without changing monitoring/profile state.",
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=False),
)
def radarr_search_movies(movie_ids: list[int]) -> dict:
    return _arr_run_search("radarr", movie_ids)


@mcp.tool(
    description=(
        "List Sonarr series with monitoring/profile/path/statistics. Optional filters: monitored, root_folder_contains, "
        "quality_profile_id. Read-only."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def sonarr_list_series(
    monitored: Optional[bool] = None,
    root_folder_contains: Optional[str] = None,
    quality_profile_id: Optional[int] = None,
    offset: int = 0,
    max_results: int = 500,
) -> dict:
    items = _arr_all_items("sonarr")
    needle = root_folder_contains.casefold() if root_folder_contains else None
    rows = []
    for item in items:
        if monitored is not None and bool(item.get("monitored")) != monitored: continue
        if quality_profile_id is not None and int(item.get("qualityProfileId") or 0) != int(quality_profile_id): continue
        if needle and needle not in str(item.get("path") or "").casefold(): continue
        row = _arr_item_label("sonarr", item)
        if row.get("size_on_disk") is not None:
            row["size_on_disk_human"] = _human_bytes(int(row.get("size_on_disk") or 0))
        rows.append(row)
    rows.sort(key=lambda r: str(r.get("title") or "").casefold())
    offset = max(0, int(offset)); max_results = max(1, min(int(max_results), 1000))
    return {"matched": len(rows), "offset": offset, "returned": len(rows[offset:offset + max_results]), "series": rows[offset:offset + max_results]}


@mcp.tool(
    description="Search Sonarr's series lookup provider by title/term. Read-only; returns candidates with TVDB IDs.",
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def sonarr_search_series(term: str, max_results: int = 20) -> list[dict]:
    data = _arr_api("sonarr", "GET", "series/lookup", params={"term": term}, timeout=60) or []
    rows = []
    for item in data[:max(1, min(int(max_results), 100))]:
        rows.append({"title": item.get("title"), "year": item.get("year"), "tvdb_id": item.get("tvdbId"),
                     "title_slug": item.get("titleSlug"), "status": item.get("status"), "overview": item.get("overview"),
                     "network": item.get("network"), "remote_poster": item.get("remotePoster")})
    return rows


@mcp.tool(
    description=(
        "Add one exact TVDB series to Sonarr. root_folder_path and quality_profile_id are deliberately required so the assistant "
        "must ask the user which path/profile to use rather than guessing. Can search for missing episodes immediately."
    ),
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=False),
)
def sonarr_add_series(
    tvdb_id: int,
    root_folder_path: str,
    quality_profile_id: int,
    monitored: bool = True,
    search_on_add: bool = True,
    monitor: str = "all",
    season_folder: bool = True,
    series_type: str = "standard",
    tags: Optional[list[int]] = None,
) -> dict:
    candidates = _arr_api("sonarr", "GET", "series/lookup", params={"term": f"tvdb:{int(tvdb_id)}"}, timeout=60) or []
    lookup = next((x for x in candidates if int(x.get("tvdbId") or 0) == int(tvdb_id)), None)
    if not isinstance(lookup, dict):
        raise ValueError(f"Sonarr could not resolve TVDB ID {tvdb_id}.")
    payload = {
        "title": lookup.get("title"), "year": lookup.get("year"), "tvdbId": int(tvdb_id),
        "titleSlug": lookup.get("titleSlug"), "images": lookup.get("images") or [],
        "qualityProfileId": int(quality_profile_id), "rootFolderPath": str(root_folder_path),
        "monitored": bool(monitored), "seasonFolder": bool(season_folder), "seriesType": series_type,
        "tags": [int(x) for x in (tags or [])],
        "addOptions": {"monitor": monitor, "searchForMissingEpisodes": bool(search_on_add), "searchForCutoffUnmetEpisodes": False},
    }
    result = _arr_api("sonarr", "POST", "series", body=payload, timeout=60)
    return _arr_item_label("sonarr", result if isinstance(result, dict) else payload)


@mcp.tool(
    description=(
        "Update one Sonarr series. Omitted fields are preserved. Supports monitored state, quality profile, root folder, series type, "
        "season-folder behavior, tags, and optional file move. Does not delete media."
    ),
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=True),
)
def sonarr_update_series(
    series_id: int,
    monitored: Optional[bool] = None,
    quality_profile_id: Optional[int] = None,
    root_folder_path: Optional[str] = None,
    series_type: Optional[str] = None,
    season_folder: Optional[bool] = None,
    tags: Optional[list[int]] = None,
    move_files: bool = False,
) -> dict:
    series = _arr_api("sonarr", "GET", f"series/{int(series_id)}")
    if not isinstance(series, dict): raise ValueError(f"Sonarr series ID {series_id} was not found.")
    if monitored is not None: series["monitored"] = bool(monitored)
    if quality_profile_id is not None: series["qualityProfileId"] = int(quality_profile_id)
    if root_folder_path is not None: series["rootFolderPath"] = str(root_folder_path)
    if series_type is not None: series["seriesType"] = series_type
    if season_folder is not None: series["seasonFolder"] = bool(season_folder)
    if tags is not None: series["tags"] = [int(x) for x in tags]
    updated = _arr_api("sonarr", "PUT", f"series/{int(series_id)}", params={"moveFiles": bool(move_files)}, body=series, timeout=60)
    return _arr_item_label("sonarr", updated if isinstance(updated, dict) else series)


@mcp.tool(
    description=(
        "Preview Sonarr series that contain episode files below a resolution threshold, have cutoff-unmet episode files, or are missing files. "
        "Filtering is performed locally on the MCP server and only the compact result crosses the tunnel. Read-only."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def sonarr_bulk_quality_preview(
    max_resolution: Optional[int] = None,
    include_equal: bool = False,
    include_missing: bool = False,
    cutoff_unmet_only: bool = False,
    root_folder_contains: Optional[str] = None,
    monitored: Optional[bool] = None,
    quality_profile_id: Optional[int] = None,
    max_results: int = 500,
) -> dict:
    rows = _arr_quality_matches("sonarr", max_resolution=max_resolution, include_equal=include_equal,
        include_missing=include_missing, cutoff_unmet_only=cutoff_unmet_only, root_folder_contains=root_folder_contains,
        monitored=monitored, quality_profile_id=quality_profile_id)
    max_results = max(1, min(int(max_results), 1000))
    return {"matched": len(rows), "returned": min(len(rows), max_results), "series": rows[:max_results]}


@mcp.tool(
    description=(
        "Bulk-update Sonarr series selected because they contain episode files below a resolution threshold/cutoff or are missing files. "
        "Can set monitored state and/or quality profile and then issue SeriesSearch commands locally. Non-delete bulk write."
    ),
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=False),
)
def sonarr_bulk_quality_update(
    max_resolution: Optional[int] = None,
    include_equal: bool = False,
    include_missing: bool = False,
    cutoff_unmet_only: bool = False,
    root_folder_contains: Optional[str] = None,
    monitored_filter: Optional[bool] = None,
    quality_profile_filter_id: Optional[int] = None,
    set_monitored: Optional[bool] = True,
    set_quality_profile_id: Optional[int] = None,
    run_search: bool = True,
    max_items: int = 1000,
) -> dict:
    rows = _arr_quality_matches("sonarr", max_resolution=max_resolution, include_equal=include_equal,
        include_missing=include_missing, cutoff_unmet_only=cutoff_unmet_only, root_folder_contains=root_folder_contains,
        monitored=monitored_filter, quality_profile_id=quality_profile_filter_id)
    if len(rows) > int(max_items): raise ValueError(f"Matched {len(rows)} series, exceeding max_items={max_items}.")
    ids = [int(r["id"]) for r in rows]
    if not ids: return {"matched": 0, "updated": 0, "search": {"requested": 0}, "items": []}
    editor = {"seriesIds": ids}
    if set_monitored is not None: editor["monitored"] = bool(set_monitored)
    if set_quality_profile_id is not None: editor["qualityProfileId"] = int(set_quality_profile_id)
    if len(editor) > 1: _arr_api("sonarr", "PUT", "series/editor", body=editor, timeout=120)
    search = _arr_run_search("sonarr", ids) if run_search else {"requested": 0, "commands": [], "errors": []}
    return {"matched": len(ids), "updated": len(ids) if len(editor) > 1 else 0, "search": search, "items": rows[:100]}


@mcp.tool(
    description="Start Sonarr SeriesSearch jobs for exact series IDs without changing monitoring/profile state.",
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=False),
)
def sonarr_search_series_ids(series_ids: list[int]) -> dict:
    return _arr_run_search("sonarr", series_ids)


@mcp.tool(
    description="List Lidarr artists with monitoring/profile/path/statistics. Read-only.",
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def lidarr_list_artists(
    monitored: Optional[bool] = None,
    root_folder_contains: Optional[str] = None,
    quality_profile_id: Optional[int] = None,
    offset: int = 0,
    max_results: int = 500,
) -> dict:
    items = _arr_all_items("lidarr")
    needle = root_folder_contains.casefold() if root_folder_contains else None
    rows = []
    for item in items:
        if monitored is not None and bool(item.get("monitored")) != monitored: continue
        if quality_profile_id is not None and int(item.get("qualityProfileId") or 0) != int(quality_profile_id): continue
        if needle and needle not in str(item.get("path") or "").casefold(): continue
        row = _arr_item_label("lidarr", item)
        if row.get("size_on_disk") is not None: row["size_on_disk_human"] = _human_bytes(int(row.get("size_on_disk") or 0))
        rows.append(row)
    rows.sort(key=lambda r: str(r.get("artist") or "").casefold())
    offset = max(0, int(offset)); max_results = max(1, min(int(max_results), 1000))
    return {"matched": len(rows), "offset": offset, "returned": len(rows[offset:offset + max_results]), "artists": rows[offset:offset + max_results]}


@mcp.tool(
    description="Search Lidarr's artist lookup provider by name/term. Read-only; returns MusicBrainz/foreign IDs.",
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def lidarr_search_artist(term: str, max_results: int = 20) -> list[dict]:
    data = _arr_api("lidarr", "GET", "artist/lookup", params={"term": term}, timeout=60) or []
    rows = []
    for item in data[:max(1, min(int(max_results), 100))]:
        rows.append({"artist": item.get("artistName"), "foreign_artist_id": item.get("foreignArtistId"),
                     "mb_id": item.get("mbId"), "status": item.get("status"), "overview": item.get("overview"),
                     "disambiguation": item.get("disambiguation")})
    return rows


@mcp.tool(
    description=(
        "Add one exact MusicBrainz/foreign artist to Lidarr. root_folder_path, quality_profile_id, and metadata_profile_id are required "
        "so the assistant must ask for the correct destination/profile rather than guessing."
    ),
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=False),
)
def lidarr_add_artist(
    foreign_artist_id: str,
    root_folder_path: str,
    quality_profile_id: int,
    metadata_profile_id: int,
    monitored: bool = True,
    search_on_add: bool = True,
    monitor: str = "all",
    tags: Optional[list[int]] = None,
) -> dict:
    candidates = _arr_api("lidarr", "GET", "artist/lookup", params={"term": f"lidarr:{foreign_artist_id}"}, timeout=60) or []
    lookup = next((x for x in candidates if str(x.get("foreignArtistId") or x.get("mbId") or "").casefold() == str(foreign_artist_id).casefold()), None)
    if lookup is None:
        candidates = _arr_api("lidarr", "GET", "artist/lookup", params={"term": foreign_artist_id}, timeout=60) or []
        lookup = next((x for x in candidates if str(x.get("foreignArtistId") or x.get("mbId") or "").casefold() == str(foreign_artist_id).casefold()), None)
    if not isinstance(lookup, dict): raise ValueError(f"Lidarr could not resolve artist ID {foreign_artist_id}.")
    payload = {
        "artistName": lookup.get("artistName"), "foreignArtistId": lookup.get("foreignArtistId") or foreign_artist_id,
        "qualityProfileId": int(quality_profile_id), "metadataProfileId": int(metadata_profile_id),
        "rootFolderPath": str(root_folder_path), "monitored": bool(monitored), "monitorNewItems": "all",
        "tags": [int(x) for x in (tags or [])],
        "addOptions": {"monitor": monitor, "searchForMissingAlbums": bool(search_on_add)},
    }
    result = _arr_api("lidarr", "POST", "artist", body=payload, timeout=60)
    return _arr_item_label("lidarr", result if isinstance(result, dict) else payload)


@mcp.tool(
    description=(
        "Update one Lidarr artist. Omitted fields are preserved. Supports monitored state, quality profile, metadata profile, root folder, "
        "tags, and optional file move. Does not delete media."
    ),
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=True),
)
def lidarr_update_artist(
    artist_id: int,
    monitored: Optional[bool] = None,
    quality_profile_id: Optional[int] = None,
    metadata_profile_id: Optional[int] = None,
    root_folder_path: Optional[str] = None,
    tags: Optional[list[int]] = None,
    move_files: bool = False,
) -> dict:
    artist = _arr_api("lidarr", "GET", f"artist/{int(artist_id)}")
    if not isinstance(artist, dict): raise ValueError(f"Lidarr artist ID {artist_id} was not found.")
    if monitored is not None: artist["monitored"] = bool(monitored)
    if quality_profile_id is not None: artist["qualityProfileId"] = int(quality_profile_id)
    if metadata_profile_id is not None: artist["metadataProfileId"] = int(metadata_profile_id)
    if root_folder_path is not None: artist["rootFolderPath"] = str(root_folder_path)
    if tags is not None: artist["tags"] = [int(x) for x in tags]
    updated = _arr_api("lidarr", "PUT", f"artist/{int(artist_id)}", params={"moveFiles": bool(move_files)}, body=artist, timeout=60)
    return _arr_item_label("lidarr", updated if isinstance(updated, dict) else artist)


@mcp.tool(
    description=(
        "Preview Lidarr artists with track files below an audio bitrate threshold, cutoff-unmet track files, or missing files. "
        "Read-only; filtering occurs locally."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def lidarr_bulk_quality_preview(
    max_audio_bitrate_kbps: Optional[int] = None,
    include_equal: bool = False,
    include_missing: bool = False,
    cutoff_unmet_only: bool = False,
    root_folder_contains: Optional[str] = None,
    monitored: Optional[bool] = None,
    quality_profile_id: Optional[int] = None,
    max_results: int = 500,
) -> dict:
    rows = _arr_quality_matches("lidarr", max_audio_bitrate_kbps=max_audio_bitrate_kbps, include_equal=include_equal,
        include_missing=include_missing, cutoff_unmet_only=cutoff_unmet_only, root_folder_contains=root_folder_contains,
        monitored=monitored, quality_profile_id=quality_profile_id)
    max_results = max(1, min(int(max_results), 1000))
    return {"matched": len(rows), "returned": min(len(rows), max_results), "artists": rows[:max_results]}


@mcp.tool(
    description=(
        "Bulk-update Lidarr artists selected because track files are below an audio bitrate threshold/cutoff or missing. "
        "Can set monitored state and/or quality profile and then issue ArtistSearch commands locally. Non-delete bulk write."
    ),
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=False),
)
def lidarr_bulk_quality_update(
    max_audio_bitrate_kbps: Optional[int] = None,
    include_equal: bool = False,
    include_missing: bool = False,
    cutoff_unmet_only: bool = False,
    root_folder_contains: Optional[str] = None,
    monitored_filter: Optional[bool] = None,
    quality_profile_filter_id: Optional[int] = None,
    set_monitored: Optional[bool] = True,
    set_quality_profile_id: Optional[int] = None,
    run_search: bool = True,
    max_items: int = 1000,
) -> dict:
    rows = _arr_quality_matches("lidarr", max_audio_bitrate_kbps=max_audio_bitrate_kbps, include_equal=include_equal,
        include_missing=include_missing, cutoff_unmet_only=cutoff_unmet_only, root_folder_contains=root_folder_contains,
        monitored=monitored_filter, quality_profile_id=quality_profile_filter_id)
    if len(rows) > int(max_items): raise ValueError(f"Matched {len(rows)} artists, exceeding max_items={max_items}.")
    ids = [int(r["id"]) for r in rows]
    if not ids: return {"matched": 0, "updated": 0, "search": {"requested": 0}, "items": []}
    editor = {"artistIds": ids}
    if set_monitored is not None: editor["monitored"] = bool(set_monitored)
    if set_quality_profile_id is not None: editor["qualityProfileId"] = int(set_quality_profile_id)
    if len(editor) > 1: _arr_api("lidarr", "PUT", "artist/editor", body=editor, timeout=120)
    search = _arr_run_search("lidarr", ids) if run_search else {"requested": 0, "commands": [], "errors": []}
    return {"matched": len(ids), "updated": len(ids) if len(editor) > 1 else 0, "search": search, "items": rows[:100]}


@mcp.tool(
    description="Start Lidarr ArtistSearch jobs for exact artist IDs without changing monitoring/profile state.",
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=False),
)
def lidarr_search_artists(artist_ids: list[int]) -> dict:
    return _arr_run_search("lidarr", artist_ids)


@mcp.tool(
    description=(
        "Prepare a deletion from Sonarr, Radarr, or Lidarr and return a short-lived confirmation token plus the exact item/path. "
        "This does NOT delete anything. The confirm tool must not be called until the user explicitly confirms the presented deletion."
    ),
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=False),
)
def arr_prepare_delete(app: str, item_id: int, delete_files: bool = False) -> dict:
    name = str(app).casefold(); _arr_cfg(name)
    endpoint = {"radarr": "movie", "sonarr": "series", "lidarr": "artist"}[name]
    item = _arr_api(name, "GET", f"{endpoint}/{int(item_id)}")
    if not isinstance(item, dict): raise ValueError(f"{name.title()} item {item_id} was not found.")
    token = secrets.token_urlsafe(18)
    expires = int(time.time()) + 600
    ARR_DELETE_CONFIRMATIONS[token] = {"app": name, "item_id": int(item_id), "delete_files": bool(delete_files), "expires": expires}
    return {
        "confirmation_required": True,
        "confirmation_token": token,
        "expires_in_seconds": 600,
        "app": name,
        "item": _arr_item_label(name, item),
        "delete_files": bool(delete_files),
        "warning": "delete_files=true permanently asks the Arr application to delete managed media files. Do not confirm without explicit user approval.",
    }


@mcp.tool(
    description=(
        "Execute a previously prepared Sonarr/Radarr/Lidarr deletion using its short-lived token. DESTRUCTIVE. "
        "Call only after the user explicitly confirms the exact prepared deletion and whether media files should be deleted."
    ),
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=True, idempotent_hint=False),
)
def arr_confirm_delete(
    app: str,
    item_id: int,
    confirmation_token: str,
    delete_files: bool = False,
    add_import_exclusion: bool = False,
) -> dict:
    name = str(app).casefold(); _arr_cfg(name)
    record = ARR_DELETE_CONFIRMATIONS.get(str(confirmation_token))
    if not record: raise ValueError("Deletion confirmation token is invalid or has already been used.")
    if int(record.get("expires") or 0) < int(time.time()):
        ARR_DELETE_CONFIRMATIONS.pop(str(confirmation_token), None)
        raise ValueError("Deletion confirmation token has expired. Prepare the deletion again.")
    if record.get("app") != name or int(record.get("item_id")) != int(item_id) or bool(record.get("delete_files")) != bool(delete_files):
        raise ValueError("Deletion confirmation does not match the prepared app/item/delete-files choice.")
    endpoint = {"radarr": "movie", "sonarr": "series", "lidarr": "artist"}[name]
    params = {"deleteFiles": bool(delete_files)}
    params["addImportExclusion" if name == "radarr" else "addImportListExclusion"] = bool(add_import_exclusion)
    _arr_api(name, "DELETE", f"{endpoint}/{int(item_id)}", params=params, timeout=120)
    ARR_DELETE_CONFIRMATIONS.pop(str(confirmation_token), None)
    return {"deleted": True, "app": name, "item_id": int(item_id), "delete_files": bool(delete_files), "import_exclusion_added": bool(add_import_exclusion)}


def _arr_inventory_rows(app: str) -> list[dict]:
    items = _arr_all_items(app)
    files = _arr_all_files(app, items=items)
    item_map = {int(x.get("id")): x for x in items if x.get("id") is not None}
    rows = []
    if app == "radarr":
        file_map = {int(f.get("movieId")): f for f in files if f.get("movieId") is not None}
        for item_id, item in item_map.items():
            f = file_map.get(item_id); q = _arr_file_quality(f)
            rows.append({"app": app, "item_id": item_id, "title": item.get("title"), "year": item.get("year"),
                "monitored": item.get("monitored"), "root_path": item.get("path"), "quality_profile_id": item.get("qualityProfileId"),
                "has_file": bool(f), "file_path": f.get("path") if f else None, "file_size_bytes": int(f.get("size") or 0) if f else 0,
                "file_quality": q.get("name"), "resolution": q.get("resolution"), "cutoff_unmet": q.get("cutoff_unmet"),
                "tmdb_id": item.get("tmdbId")})
    elif app == "sonarr":
        for f in files:
            item = item_map.get(int(f.get("seriesId") or 0), {}); q = _arr_file_quality(f)
            rows.append({"app": app, "series_id": f.get("seriesId"), "series": item.get("title"), "year": item.get("year"),
                "monitored": item.get("monitored"), "root_path": item.get("path"), "quality_profile_id": item.get("qualityProfileId"),
                "episode_file_id": f.get("id"), "relative_path": f.get("relativePath"), "file_path": f.get("path"),
                "file_size_bytes": int(f.get("size") or 0), "file_quality": q.get("name"), "resolution": q.get("resolution"),
                "cutoff_unmet": q.get("cutoff_unmet"), "tvdb_id": item.get("tvdbId")})
    else:
        for f in files:
            item = item_map.get(int(f.get("artistId") or 0), {}); q = _arr_file_quality(f)
            rows.append({"app": app, "artist_id": f.get("artistId"), "artist": item.get("artistName"), "album_id": f.get("albumId"),
                "monitored": item.get("monitored"), "root_path": item.get("path"), "quality_profile_id": item.get("qualityProfileId"),
                "track_file_id": f.get("id"), "file_path": f.get("path"), "file_size_bytes": int(f.get("size") or 0),
                "file_quality": q.get("name"), "audio_bitrate_kbps": _arr_audio_bitrate_kbps(f), "cutoff_unmet": q.get("cutoff_unmet")})
    return rows


@mcp.tool(
    description=(
        "Generate a Sonarr/Radarr/Lidarr inventory export locally on the MCP server as CSV or JSON. The bulk dataset stays local until "
        "arr_read_export_chunk is explicitly used. Does not change media or application metadata."
    ),
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=False),
)
def arr_export_inventory(app: str, file_format: str = "csv") -> dict:
    name = str(app).casefold(); _arr_cfg(name)
    fmt = str(file_format).casefold()
    if fmt not in ("csv", "json"): raise ValueError("file_format must be csv or json")
    rows = _arr_inventory_rows(name)
    export_id = uuid.uuid4().hex
    os.makedirs(REPORT_EXPORT_DIR, exist_ok=True)
    path = os.path.join(REPORT_EXPORT_DIR, f"arr-{name}-{export_id}.{fmt}")
    if fmt == "json":
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(rows, handle, ensure_ascii=False, indent=2)
    else:
        fields = sorted({key for row in rows for key in row.keys()})
        with open(path, "w", encoding="utf-8-sig", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=fields)
            writer.writeheader(); writer.writerows(rows)
    ARR_EXPORTS[export_id] = path
    return {"export_id": export_id, "app": name, "format": fmt, "row_count": len(rows), "local_path": path,
            "file_size_bytes": os.path.getsize(path), "file_size_human": _human_bytes(os.path.getsize(path))}


@mcp.tool(
    description="Read one base64 chunk from a locally generated Arr inventory export so large reports can cross the tunnel incrementally.",
    annotations=ToolAnnotations(read_only_hint=True, idempotent_hint=True),
)
def arr_read_export_chunk(export_id: str, offset_bytes: int = 0, max_bytes: int = 131072) -> dict:
    path = ARR_EXPORTS.get(str(export_id))
    if not path or not os.path.isfile(path): raise ValueError("Arr export ID is unknown or its local file no longer exists.")
    offset = max(0, int(offset_bytes)); amount = max(1, min(int(max_bytes), 1048576))
    size = os.path.getsize(path)
    with open(path, "rb") as handle:
        handle.seek(offset); chunk = handle.read(amount)
    next_offset = offset + len(chunk)
    return {"export_id": export_id, "offset_bytes": offset, "returned_bytes": len(chunk), "file_size_bytes": size,
            "next_offset_bytes": next_offset if next_offset < size else None, "eof": next_offset >= size,
            "base64_data": base64.b64encode(chunk).decode("ascii")}

if __name__ == "__main__":
    mcp.run()
'@

$pythonServer = $pythonServer.Replace('__PLEX_URL__', $PlexUrl.Replace('\', '\\').Replace('"', '\"'))
$pythonServer = $pythonServer.Replace('__PLEX_TOKEN__', $PlexToken.Replace('\', '\\').Replace('"', '\"'))
$pythonServer = $pythonServer.Replace('__TAUTULLI_URL__', $TautulliUrl.Replace('\', '\\').Replace('"', '\"'))
$pythonServer = $pythonServer.Replace('__TAUTULLI_API_KEY__', $TautulliApiKey.Replace('\', '\\').Replace('"', '\"'))
$pythonServer = $pythonServer.Replace('__SONARR_URL__', $SonarrUrl.Replace('\', '\\').Replace('"', '\"'))
$pythonServer = $pythonServer.Replace('__SONARR_API_KEY__', $SonarrApiKey.Replace('\', '\\').Replace('"', '\"'))
$pythonServer = $pythonServer.Replace('__RADARR_URL__', $RadarrUrl.Replace('\', '\\').Replace('"', '\"'))
$pythonServer = $pythonServer.Replace('__RADARR_API_KEY__', $RadarrApiKey.Replace('\', '\\').Replace('"', '\"'))
$pythonServer = $pythonServer.Replace('__LIDARR_URL__', $LidarrUrl.Replace('\', '\\').Replace('"', '\"'))
$pythonServer = $pythonServer.Replace('__LIDARR_API_KEY__', $LidarrApiKey.Replace('\', '\\').Replace('"', '\"'))
$pythonServer = $pythonServer.Replace('__REPORT_EXPORT_DIR__', $ReportingExportDir.Replace('\', '\\').Replace('"', '\"'))
$pythonServer = $pythonServer.Replace('__TUNNEL_RUNTIME_LOG__', (Join-Path $LogDir 'tunnel-runtime.log').Replace('\', '\\').Replace('"', '\"'))
$pythonServer = $pythonServer.Replace('__TUNNEL_HEALTH_URL_FILE__', $HealthUrlFile.Replace('\', '\\').Replace('"', '\"'))

$McpServerChanged = Set-ContentIfChanged -Path $McpServer -Content $pythonServer
Set-SecureAcl -Path $McpServer

if ($McpServerChanged) {
    Write-Fix 'MCP server definition changed. The tunnel runtime will be restarted so ChatGPT can discover the new tool schema.'
}
else {
    Write-Skip 'MCP server definition is unchanged.'
}

# ===========================================================================
# 6. Validate Plex, Tautulli, and Arr connections
# ===========================================================================
Show-Stage 6 'Validate Plex, Tautulli, Sonarr, Radarr, and Lidarr connections'

Write-Host "Testing Plex at $PlexUrl..."
$plexCode = "import importlib.util; s=importlib.util.spec_from_file_location('media_stack_gateway', r'$McpServer'); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); p=m._plex(); print(p.friendlyName)"
$plexResult = Invoke-NativeCaptured `
    -FilePath $PythonExe `
    -ArgumentList @('-c', $plexCode) `
    -Label 'plex-connection-test'

if ($plexResult.ExitCode -ne 0) {
    throw "Plex connection failed.`r`nSTDOUT:`r`n$($plexResult.StdOut)`r`nSTDERR:`r`n$($plexResult.StdErr)"
}

$plexName = $plexResult.StdOut.Trim()
Write-Skip "Plex connection works. Server: $plexName"

Write-Host "Testing Tautulli reporting API at $TautulliUrl..."
$tautulliCode = "import importlib.util, json; s=importlib.util.spec_from_file_location('media_stack_gateway', r'$McpServer'); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(json.dumps(m.plex_reporting_status()))"
$tautulliResult = Invoke-NativeCaptured `
    -FilePath $PythonExe `
    -ArgumentList @('-c', $tautulliCode) `
    -Label 'tautulli-connection-test'

$tautulliAvailable = $false
$tautulliVersion = $null
if ($tautulliResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($tautulliResult.StdOut)) {
    try {
        $tautulliStatus = $tautulliResult.StdOut.Trim() | ConvertFrom-Json
        $tautulliAvailable = [bool]$tautulliStatus.available
        if ($tautulliAvailable) {
            $tautulliVersion = $tautulliStatus.tautulli.tautulli_version
            Write-Skip "Tautulli reporting API works. Version: $tautulliVersion"
            if ($null -ne $tautulliStatus.identity_match -and -not [bool]$tautulliStatus.identity_match) {
                Write-Warning 'Tautulli is reachable but its configured Plex server identifier does not match the Plex server used by this MCP app.'
            }
        }
        else {
            Write-Warning "Tautulli reporting API is unavailable: $($tautulliStatus.error)"
        }
    }
    catch {
        Write-Warning "Tautulli validation returned data that could not be parsed: $($tautulliResult.StdOut.Trim())"
    }
}
else {
    Write-Warning "Tautulli reporting validation failed. Existing Plex functionality will still be installed. STDERR: $($tautulliResult.StdErr.Trim())"
}

$arrAvailability = @{ sonarr = $false; radarr = $false; lidarr = $false }
Write-Host "Testing Sonarr, Radarr, and Lidarr APIs..."
$arrCode = "import importlib.util, json; s=importlib.util.spec_from_file_location('media_stack_gateway', r'$McpServer'); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(json.dumps(m.arr_status()))"
$arrResult = Invoke-NativeCaptured `
    -FilePath $PythonExe `
    -ArgumentList @('-c', $arrCode) `
    -Label 'arr-connection-test'
if ($arrResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($arrResult.StdOut)) {
    try {
        $arrStatuses = $arrResult.StdOut.Trim() | ConvertFrom-Json

        # Current arr_status() returns application states under an "applications"
        # object. Retain compatibility with older gateway responses that returned
        # sonarr/radarr/lidarr directly at the root.
        if ($arrStatuses.PSObject.Properties.Name -contains 'applications' -and $null -ne $arrStatuses.applications) {
            $arrApplications = $arrStatuses.applications
        }
        else {
            $arrApplications = $arrStatuses
        }

        foreach ($arrName in @('sonarr', 'radarr', 'lidarr')) {
            $displayName = (Get-Culture).TextInfo.ToTitleCase($arrName)
            $status = $arrApplications.$arrName

            if ($null -eq $status) {
                $arrAvailability[$arrName] = $false
                Write-Warning "$displayName status was missing from the Arr validation response."
                continue
            }

            $available = [bool]$status.available
            $arrAvailability[$arrName] = $available

            if ($available) {
                $details = @()
                if ($status.PSObject.Properties.Name -contains 'version' -and $status.version) {
                    $details += "Version: $($status.version)"
                }
                if ($status.PSObject.Properties.Name -contains 'api_version' -and $status.api_version) {
                    $details += "API: $($status.api_version)"
                }
                if ($status.PSObject.Properties.Name -contains 'health_issue_count' -and $null -ne $status.health_issue_count) {
                    $details += "Health issues: $($status.health_issue_count)"
                }

                $detailText = if ($details.Count -gt 0) { ' ' + ($details -join '; ') } else { '' }
                Write-Good "$displayName API works.$detailText"
            }
            else {
                $errorText = if ($status.PSObject.Properties.Name -contains 'error' -and $status.error) { $status.error } else { 'No error detail returned.' }
                Write-Warning "$displayName API unavailable: $errorText"
            }
        }
    }
    catch {
        Write-Warning "Arr validation response processing failed: $($_.Exception.Message)"
    }
}
else {
    Write-Warning "Arr validation failed. Plex/Tautulli functionality will still install. STDERR: $($arrResult.StdErr.Trim())"
}

# ===========================================================================
# 7. Validate MCP server imports/launch command
# ===========================================================================
Show-Stage 7 'Validate MCP server and launch command'

$importCode = "import importlib.util; s=importlib.util.spec_from_file_location('media_stack_gateway', r'$McpServer'); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print('MCP server imports successfully')"
$importResult = Invoke-NativeCaptured `
    -FilePath $PythonExe `
    -ArgumentList @('-c', $importCode) `
    -Label 'mcp-server-import-test'

if ($importResult.ExitCode -ne 0) {
    throw "MCP server import validation failed.`r`nSTDOUT:`r`n$($importResult.StdOut)`r`nSTDERR:`r`n$($importResult.StdErr)"
}

Write-Skip $importResult.StdOut.Trim()
# tunnel-client parses mcp.command with shell-style tokenization.
# On Windows, literal backslashes in an unquoted command are treated as escape
# characters by that parser. Use forward slashes ONLY in the MCP command string.
# Windows and Go's os/exec accept C:/... paths normally.
$McpPythonPath = $PythonExe.Replace('\', '/')
$McpServerPath = $McpServer.Replace('\', '/')
$McpCommand = "$McpPythonPath $McpServerPath"
Write-Host "Native Python path : $PythonExe"
Write-Host "Native MCP path    : $McpServer"
Write-Host "Tunnel MCP command : $McpCommand"

if ($McpCommand.StartsWith('"') -or $McpCommand.StartsWith("'")) {
    throw "Internal error: MCP command must not begin with a literal quote character: $McpCommand"
}
if (-not (Test-Path -LiteralPath $PythonExe)) {
    throw "MCP preflight failed locally: Python executable does not exist at $PythonExe"
}
if (-not (Test-Path -LiteralPath $McpServer)) {
    throw "MCP preflight failed locally: MCP server script does not exist at $McpServer"
}

# ===========================================================================
# 8. Create/reuse/repair OpenAI tunnel profile
# ===========================================================================
Show-Stage 8 'Create, reuse, or repair OpenAI tunnel profile'

$env:CONTROL_PLANE_API_KEY = $OpenAiRuntimeKey
$env:TUNNEL_CLIENT_PROFILE_DIR = $ProfileDir

# IMPORTANT:
# Do not call "tunnel-client init --mcp-command ..." from Windows PowerShell 5.1.
# PowerShell's native argument marshalling can cause the quotes needed to preserve
# the command string as one flag value to become literal quote characters inside
# the value received by tunnel-client. The tunnel client's own preflight then
# looks for an executable whose filename begins with a quote.
#
# OpenAI's sample_mcp_stdio_local profile is simple YAML. Write that documented
# profile format directly, then have tunnel-client doctor validate it.
$ProfileFile = Join-Path $ProfileDir ($ProfileName + '.yaml')

# None of these managed paths contain a single quote. The MCP command uses
# forward slashes so shell-style parsing does not consume Windows backslashes.
foreach ($yamlValue in @($TunnelId, $McpCommand)) {
    if ($yamlValue.Contains("'")) {
        throw "Internal configuration contains a single quote and cannot be safely serialized by this installer: $yamlValue"
    }
}

$profileContent = @"
config_version: 1

control_plane:
  base_url: 'https://api.openai.com'
  tunnel_id: '$TunnelId'
  api_key: 'env:CONTROL_PLANE_API_KEY'

health:
  # Port 0 asks Windows for an unused loopback port.
  listen_addr: '127.0.0.1:0'
  url_file: '$($HealthUrlFile.Replace('\', '/'))'

admin_ui:
  open_browser: false

log:
  level: info
  format: json

mcp:
  commands:
    - channel: main
      command: '$McpCommand'
"@

$profileChanged = Set-ContentIfChanged -Path $ProfileFile -Content $profileContent
Set-SecureAcl -Path $ProfileFile

if ($profileChanged) {
    Write-Fix "Wrote direct stdio MCP profile: $ProfileFile"
}
else {
    Write-Skip "Direct stdio MCP profile is already current: $ProfileFile"
}

$doctorLog = Join-Path $LogDir 'doctor.txt'

$existingTaskAtStage8 = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$runtimeAlreadyHealthy = ($existingTaskAtStage8 -and $existingTaskAtStage8.State -eq 'Running' -and (Test-TunnelHealth))
$runtimeAlreadyReady = ($runtimeAlreadyHealthy -and (Test-TunnelReady))

if ((-not $profileChanged) -and (-not $McpServerChanged) -and $runtimeAlreadyHealthy) {
    if ($runtimeAlreadyReady) {
        Write-Skip 'Existing tunnel runtime is healthy and ready; profile and MCP code are unchanged. Skipping doctor.'
    }
    else {
        Write-Warning 'Existing tunnel runtime is live (/healthz is healthy) but /readyz is not currently ready. Leaving the live tunnel intact and skipping doctor.'
    }
}
else {
    if ($existingTaskAtStage8 -and $existingTaskAtStage8.State -eq 'Running') {
        if ($McpServerChanged) {
            Write-Fix 'Stopping existing tunnel because MCP tool definitions changed.'
        }
        elseif ($profileChanged) {
            Write-Fix 'Stopping existing tunnel because the tunnel profile changed.'
        }
        else {
            Write-Fix 'Stopping existing tunnel because liveness validation failed.'
        }
        Stop-TunnelTaskIfRunning
    }

    Remove-Item -LiteralPath $HealthUrlFile -Force -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $LegacyHealthUrlFile -Force -Confirm:$false -ErrorAction SilentlyContinue

    Write-Host 'Validating profile with tunnel-client doctor...'
    & $TunnelExe doctor --profile $ProfileName --explain *> $doctorLog

    if ($LASTEXITCODE -ne 0) {
        $details = Get-Content -LiteralPath $doctorLog -Raw -ErrorAction SilentlyContinue
        throw "tunnel-client doctor failed for the directly generated profile.`r`n$details"
    }

    Write-Skip 'Directly generated tunnel profile passes tunnel-client doctor.'

    # doctor is short-lived and may publish its temporary health endpoint. Delete it
    # so the persistent runtime must publish a fresh endpoint in Stage 11.
    Remove-Item -LiteralPath $HealthUrlFile -Force -Confirm:$false -ErrorAction SilentlyContinue
}

# ===========================================================================
# 9. Create/update self-healing tunnel runner and watchdog
# ===========================================================================
Show-Stage 9 'Create or update self-healing tunnel runner and watchdog'

$runnerContent = @"
`$ErrorActionPreference = 'Continue'
`$env:CONTROL_PLANE_API_KEY = '$OpenAiRuntimeKey'
`$env:TUNNEL_CLIENT_PROFILE_DIR = '$ProfileDir'

`$runtimeLog = '$LogDir\tunnel-runtime.log'
`$runtimeLogMaxBytes = [int64]$RuntimeLogMaxBytes
`$runtimeLogRetain = $RuntimeLogRetainedFiles
`$restartDelaySeconds = 10
`$utf8NoBom = New-Object System.Text.UTF8Encoding(`$false)
`$script:RuntimeLogBytes = 0L

function Rotate-RuntimeLog {
    param([switch]`$Force)

    try {
        if (-not (Test-Path -LiteralPath `$runtimeLog)) {
            `$script:RuntimeLogBytes = 0L
            return
        }

        `$item = Get-Item -LiteralPath `$runtimeLog -ErrorAction Stop
        if ((-not `$Force) -and `$item.Length -lt `$runtimeLogMaxBytes) {
            `$script:RuntimeLogBytes = [int64]`$item.Length
            return
        }

        # If an old pre-rotation log is enormous, preserve only its newest
        # RuntimeLogMaxBytes as .1 rather than retaining gigabytes of stale data.
        if (`$item.Length -gt (`$runtimeLogMaxBytes * (`$runtimeLogRetain + 1))) {
            for (`$i = `$runtimeLogRetain; `$i -ge 2; `$i--) {
                `$source = "`$runtimeLog.`$(`$i - 1)"
                `$dest = "`$runtimeLog.`$i"
                if (Test-Path -LiteralPath `$dest) { Remove-Item -LiteralPath `$dest -Force -Confirm:`$false -ErrorAction SilentlyContinue }
                if (Test-Path -LiteralPath `$source) { Move-Item -LiteralPath `$source -Destination `$dest -Force -Confirm:`$false }
            }

            `$tailTemp = "`$runtimeLog.trim.tmp"
            if (Test-Path -LiteralPath `$tailTemp) { Remove-Item -LiteralPath `$tailTemp -Force -Confirm:`$false -ErrorAction SilentlyContinue }
            `$input = [System.IO.File]::Open(`$runtimeLog, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                `$tailBytes = [Math]::Min([int64]`$runtimeLogMaxBytes, [int64]`$input.Length)
                [void]`$input.Seek(-`$tailBytes, [System.IO.SeekOrigin]::End)
                `$output = [System.IO.File]::Open(`$tailTemp, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                try { `$input.CopyTo(`$output) } finally { `$output.Dispose() }
            }
            finally { `$input.Dispose() }

            `$firstArchive = "`$runtimeLog.1"
            if (Test-Path -LiteralPath `$firstArchive) { Remove-Item -LiteralPath `$firstArchive -Force -Confirm:`$false -ErrorAction SilentlyContinue }
            Move-Item -LiteralPath `$tailTemp -Destination `$firstArchive -Force -Confirm:`$false
            Remove-Item -LiteralPath `$runtimeLog -Force -Confirm:`$false -ErrorAction SilentlyContinue
        }
        else {
            for (`$i = `$runtimeLogRetain; `$i -ge 1; `$i--) {
                `$source = if (`$i -eq 1) { `$runtimeLog } else { "`$runtimeLog.`$(`$i - 1)" }
                `$dest = "`$runtimeLog.`$i"
                if (Test-Path -LiteralPath `$dest) { Remove-Item -LiteralPath `$dest -Force -Confirm:`$false -ErrorAction SilentlyContinue }
                if (Test-Path -LiteralPath `$source) { Move-Item -LiteralPath `$source -Destination `$dest -Force -Confirm:`$false }
            }
        }
    }
    catch {
        # Logging maintenance must never take the tunnel offline.
    }

    `$script:RuntimeLogBytes = 0L
}

function Write-RuntimeLogLine {
    param(
        [AllowEmptyString()][string]`$Text,
        [switch]`$Supervisor
    )

    `$entry = if (`$Supervisor) { "[`$([DateTime]::Now.ToString('s'))] SUPERVISOR `$Text" } else { [string]`$Text }
    `$payload = `$entry + [Environment]::NewLine
    `$bytes = [int64]`$utf8NoBom.GetByteCount(`$payload)

    if ((`$script:RuntimeLogBytes + `$bytes) -gt `$runtimeLogMaxBytes) {
        Rotate-RuntimeLog -Force
    }

    try {
        [System.IO.File]::AppendAllText(`$runtimeLog, `$payload, `$utf8NoBom)
        `$script:RuntimeLogBytes += `$bytes
    }
    catch {
        # Never terminate the supervisor because a diagnostic log write failed.
    }
}

# Initialize size accounting and collapse any legacy runaway log before the
# first tunnel-client launch under the new supervisor.
Rotate-RuntimeLog
Write-RuntimeLogLine -Supervisor -Text 'Tunnel supervisor started.'

while (`$true) {
    try {
        Write-RuntimeLogLine -Supervisor -Text 'Starting tunnel-client.'

        # Stream both native stdout and stderr through PowerShell so the runner
        # can rotate the file while the tunnel remains alive. This also keeps
        # the managed runtime log consistently UTF-8 instead of mixed encodings.
        & '$TunnelExe' run --profile '$ProfileName' 2>&1 | ForEach-Object {
            Write-RuntimeLogLine -Text ([string]`$_)
        }
        `$exitCode = `$LASTEXITCODE

        Write-RuntimeLogLine -Supervisor -Text "tunnel-client exited with code `$exitCode. Restarting in `$restartDelaySeconds seconds."
    }
    catch {
        Write-RuntimeLogLine -Supervisor -Text "Tunnel supervisor caught exception: `$(`$_.Exception.Message). Restarting in `$restartDelaySeconds seconds."
    }

    Start-Sleep -Seconds `$restartDelaySeconds
}
"@

$TunnelRunnerChanged = Set-ContentIfChanged -Path $TunnelRunner -Content $runnerContent
Set-SecureAcl -Path $TunnelRunner

$watchdogContent = @"
`$ErrorActionPreference = 'Continue'

`$taskName = '$TaskName'
`$healthUrlFile = '$HealthUrlFile'
`$watchdogLog = '$LogDir\tunnel-watchdog.log'
`$stateFile = '$WatchdogStateFile'
`$logMaxBytes = [int64]$WatchdogLogMaxBytes
`$logRetain = $WatchdogLogRetainedFiles
`$readinessFailureThreshold = $WatchdogReadinessFailureThreshold
`$readinessRestartCooldownMinutes = $WatchdogReadinessRestartCooldownMinutes
`$startupGraceSeconds = $WatchdogStartupGraceSeconds
`$healthyHeartbeatMinutes = $WatchdogHealthyHeartbeatMinutes
`$utf8NoBom = New-Object System.Text.UTF8Encoding(`$false)

function Rotate-WatchdogLogIfNeeded {
    try {
        if (-not (Test-Path -LiteralPath `$watchdogLog)) { return }
        `$item = Get-Item -LiteralPath `$watchdogLog -ErrorAction Stop
        if (`$item.Length -lt `$logMaxBytes) { return }
        for (`$i = `$logRetain; `$i -ge 1; `$i--) {
            `$source = if (`$i -eq 1) { `$watchdogLog } else { "`$watchdogLog.`$(`$i - 1)" }
            `$dest = "`$watchdogLog.`$i"
            if (Test-Path -LiteralPath `$dest) { Remove-Item -LiteralPath `$dest -Force -Confirm:`$false -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath `$source) { Move-Item -LiteralPath `$source -Destination `$dest -Force -Confirm:`$false }
        }
    }
    catch { }
}

function Write-WatchdogLog {
    param([string]`$Message)
    Rotate-WatchdogLogIfNeeded
    try {
        `$line = "[`$([DateTime]::Now.ToString('s'))] `$Message" + [Environment]::NewLine
        [System.IO.File]::AppendAllText(`$watchdogLog, `$line, `$utf8NoBom)
    }
    catch { }
}

function Get-DefaultState {
    return @{
        readiness_failures = 0
        last_readiness_restart_utc = `$null
        last_healthy_log_utc = `$null
        last_status = 'unknown'
    }
}

function Get-WatchdogState {
    `$state = Get-DefaultState
    if (-not (Test-Path -LiteralPath `$stateFile)) { return `$state }
    try {
        `$loaded = Get-Content -LiteralPath `$stateFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        foreach (`$name in @('readiness_failures','last_readiness_restart_utc','last_healthy_log_utc','last_status')) {
            if (`$loaded.PSObject.Properties.Name -contains `$name) { `$state[`$name] = `$loaded.`$name }
        }
    }
    catch { }
    return `$state
}

function Save-WatchdogState {
    param([hashtable]`$State)
    try {
        `$json = `$State | ConvertTo-Json -Depth 3
        [System.IO.File]::WriteAllText(`$stateFile, `$json, `$utf8NoBom)
    }
    catch { }
}

function Parse-UtcDate {
    param([object]`$Value)
    if (`$null -eq `$Value -or [string]::IsNullOrWhiteSpace([string]`$Value)) { return `$null }
    try { return [DateTime]::Parse([string]`$Value).ToUniversalTime() } catch { return `$null }
}

function Get-HealthBaseUrl {
    if (-not (Test-Path -LiteralPath `$healthUrlFile)) { return `$null }
    try {
        `$baseUrl = (Get-Content -LiteralPath `$healthUrlFile -Raw -ErrorAction Stop).Trim().TrimEnd('/')
        if (`$baseUrl -match '^http://127\.0\.0\.1:\d+`$') { return `$baseUrl }
    }
    catch { }
    return `$null
}

function Invoke-LocalProbe {
    param(
        [Parameter(Mandatory=`$true)][string]`$BaseUrl,
        [Parameter(Mandatory=`$true)][string]`$Path
    )

    try {
        `$response = Invoke-WebRequest -UseBasicParsing -Uri (`$BaseUrl + `$Path) -TimeoutSec 5 -ErrorAction Stop
        return [pscustomobject]@{ Ok = (`$response.StatusCode -eq 200); StatusCode = [int]`$response.StatusCode; Body = [string]`$response.Content; Error = `$null }
    }
    catch {
        `$statusCode = `$null
        `$body = ''
        if (`$null -ne `$_.Exception.Response) {
            try { `$statusCode = [int]`$_.Exception.Response.StatusCode } catch { }
            try {
                `$stream = `$_.Exception.Response.GetResponseStream()
                if (`$null -ne `$stream) {
                    `$reader = New-Object System.IO.StreamReader(`$stream)
                    try { `$body = `$reader.ReadToEnd() } finally { `$reader.Dispose() }
                }
            }
            catch { }
        }
        return [pscustomobject]@{ Ok = `$false; StatusCode = `$statusCode; Body = `$body; Error = `$_.Exception.Message }
    }
}

function Format-ProbeDetail {
    param([object]`$Probe)
    `$parts = @()
    if (`$null -ne `$Probe.StatusCode) { `$parts += "HTTP `$(`$Probe.StatusCode)" }
    if (-not [string]::IsNullOrWhiteSpace([string]`$Probe.Error)) { `$parts += [string]`$Probe.Error }
    if (-not [string]::IsNullOrWhiteSpace([string]`$Probe.Body)) {
        `$body = ([string]`$Probe.Body -replace '[\r\n]+',' ').Trim()
        if (`$body.Length -gt 500) { `$body = `$body.Substring(0,500) }
        `$parts += "body=`$body"
    }
    if (`$parts.Count -eq 0) { return 'no response detail' }
    return (`$parts -join '; ')
}

function Restart-PrimaryTunnel {
    param([Parameter(Mandatory=`$true)][string]`$Reason)
    Write-WatchdogLog "RESTART: `$Reason"
    Stop-ScheduledTask -TaskName `$taskName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Remove-Item -LiteralPath `$healthUrlFile -Force -Confirm:`$false -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskName `$taskName
}

try {
    `$state = Get-WatchdogState
    `$task = Get-ScheduledTask -TaskName `$taskName -ErrorAction SilentlyContinue

    if (-not `$task) {
        Write-WatchdogLog 'ERROR: Primary tunnel task does not exist.'
        exit 2
    }

    if (`$task.State -ne 'Running') {
        Write-WatchdogLog "REPAIR: Primary tunnel task state is '`$(`$task.State)'. Starting it."
        `$state['readiness_failures'] = 0
        `$state['last_status'] = 'starting'
        Save-WatchdogState -State `$state
        Remove-Item -LiteralPath `$healthUrlFile -Force -Confirm:`$false -ErrorAction SilentlyContinue
        Start-ScheduledTask -TaskName `$taskName
        exit 0
    }

    `$taskInfo = Get-ScheduledTaskInfo -TaskName `$taskName -ErrorAction SilentlyContinue
    `$taskAgeSeconds = [double]::PositiveInfinity
    if (`$null -ne `$taskInfo -and `$taskInfo.LastRunTime.Year -ge 2000) {
        `$taskAgeSeconds = [Math]::Max(0, ((Get-Date) - `$taskInfo.LastRunTime).TotalSeconds)
    }

    `$baseUrl = Get-HealthBaseUrl
    if (-not `$baseUrl) {
        if (`$taskAgeSeconds -lt `$startupGraceSeconds) {
            `$state['last_status'] = 'startup-grace-no-endpoint'
            Save-WatchdogState -State `$state
            Write-WatchdogLog "INFO: Tunnel is within startup grace (`$([int]`$taskAgeSeconds)s/`$startupGraceSeconds s); health endpoint file is not available yet."
            exit 0
        }
        Restart-PrimaryTunnel -Reason 'health endpoint file is missing/invalid after startup grace.'
        `$state['readiness_failures'] = 0
        `$state['last_status'] = 'restarting-health'
        Save-WatchdogState -State `$state
        exit 0
    }

    `$health = Invoke-LocalProbe -BaseUrl `$baseUrl -Path '/healthz'
    if (-not `$health.Ok) {
        if (`$taskAgeSeconds -lt `$startupGraceSeconds) {
            `$state['last_status'] = 'startup-grace-health'
            Save-WatchdogState -State `$state
            Write-WatchdogLog "INFO: Tunnel /healthz is not ready during startup grace: `$(Format-ProbeDetail `$health)"
            exit 0
        }
        Restart-PrimaryTunnel -Reason "local /healthz liveness failed: `$(Format-ProbeDetail `$health)"
        `$state['readiness_failures'] = 0
        `$state['last_status'] = 'restarting-health'
        Save-WatchdogState -State `$state
        exit 0
    }

    `$ready = Invoke-LocalProbe -BaseUrl `$baseUrl -Path '/readyz'
    if (-not `$ready.Ok) {
        `$failures = 1 + [int]`$state['readiness_failures']
        `$state['readiness_failures'] = `$failures
        `$state['last_status'] = 'not-ready'
        `$detail = Format-ProbeDetail `$ready
        Write-WatchdogLog "WARN: /healthz is healthy but /readyz is not ready (`$failures/`$readinessFailureThreshold): `$detail"

        if (`$failures -ge `$readinessFailureThreshold) {
            `$lastRestart = Parse-UtcDate `$state['last_readiness_restart_utc']
            `$cooldownActive = `$false
            if (`$null -ne `$lastRestart) {
                `$cooldownActive = ((([DateTime]::UtcNow - `$lastRestart).TotalMinutes) -lt `$readinessRestartCooldownMinutes)
            }

            if (`$cooldownActive) {
                Write-WatchdogLog "WARN: Readiness restart suppressed by `$readinessRestartCooldownMinutes-minute cooldown; tunnel remains live because /healthz is healthy."
            }
            else {
                `$state['last_readiness_restart_utc'] = [DateTime]::UtcNow.ToString('o')
                `$state['readiness_failures'] = 0
                `$state['last_status'] = 'restarting-readiness'
                Save-WatchdogState -State `$state
                Restart-PrimaryTunnel -Reason "readiness failed `$failures consecutive checks while liveness remained healthy: `$detail"
                exit 0
            }
        }

        Save-WatchdogState -State `$state
        exit 0
    }

    `$previousFailures = [int]`$state['readiness_failures']
    `$previousStatus = [string]`$state['last_status']
    `$state['readiness_failures'] = 0
    `$state['last_status'] = 'healthy'

    if (`$previousFailures -gt 0 -or `$previousStatus -ne 'healthy') {
        Write-WatchdogLog 'OK: Tunnel recovered; /healthz and /readyz both return HTTP 200.'
        `$state['last_healthy_log_utc'] = [DateTime]::UtcNow.ToString('o')
    }
    else {
        `$lastHealthyLog = Parse-UtcDate `$state['last_healthy_log_utc']
        if (`$null -eq `$lastHealthyLog -or (([DateTime]::UtcNow - `$lastHealthyLog).TotalMinutes -ge `$healthyHeartbeatMinutes)) {
            Write-WatchdogLog 'OK: Tunnel is healthy and ready.'
            `$state['last_healthy_log_utc'] = [DateTime]::UtcNow.ToString('o')
        }
    }

    Save-WatchdogState -State `$state
    exit 0
}
catch {
    Write-WatchdogLog "ERROR: Watchdog exception: `$(`$_.Exception.Message)"
    exit 1
}
"@

$WatchdogScriptChanged = Set-ContentIfChanged -Path $WatchdogScript -Content $watchdogContent
Set-SecureAcl -Path $WatchdogScript

$openUiContent = @"
`$ErrorActionPreference = 'Stop'
`$endpointFile = '$HealthUrlFile'
if (-not (Test-Path -LiteralPath `$endpointFile)) {
    throw "Tunnel health endpoint file does not exist yet: `$endpointFile"
}
`$baseUrl = (Get-Content -LiteralPath `$endpointFile -Raw).Trim().TrimEnd('/')
if (`$baseUrl -notmatch '^http://127\.0\.0\.1:\d+`$') {
    throw "Tunnel health endpoint file does not contain a valid localhost URL: `$baseUrl"
}
Start-Process (`$baseUrl + '/ui')
"@

$OpenTunnelUiChanged = Set-ContentIfChanged -Path $OpenTunnelUiScript -Content $openUiContent
Set-SecureAcl -Path $OpenTunnelUiScript

# ===========================================================================
# 10. Create/reuse scheduled tasks
# ===========================================================================
Show-Stage 10 'Create or reuse tunnel and watchdog scheduled tasks'

$expectedExecute = 'powershell.exe'
$expectedArguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$TunnelRunner`""

$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$taskNeedsUpdate = $true

if ($existingTask) {
    $action = $existingTask.Actions | Select-Object -First 1
    if ($action.Execute -ieq $expectedExecute -and $action.Arguments -eq $expectedArguments) {
        $taskNeedsUpdate = $false
        Write-Skip 'Primary tunnel scheduled task already exists with the correct action.'
    }
    else {
        Write-Fix 'Primary tunnel scheduled task exists but needs to be updated.'
    }
}

if ($taskNeedsUpdate) {
    $action = New-ScheduledTaskAction -Execute $expectedExecute -Argument $expectedArguments
    $trigger = New-ScheduledTaskTrigger -AtStartup

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -MultipleInstances IgnoreNew

    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal `
        -Description 'Self-healing OpenAI secure tunnel for the local MediaStack Control Gateway MCP server.' `
        -Force | Out-Null

    Write-Good 'Primary tunnel scheduled task created/updated.'
}

# Watchdog runs every minute and repairs the primary task if it is stopped or unhealthy.
$watchdogArguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$WatchdogScript`""
$watchdogAction = New-ScheduledTaskAction -Execute $expectedExecute -Argument $watchdogArguments

# Create a repeating trigger that begins one minute from now and repeats indefinitely.
$watchdogTrigger = New-ScheduledTaskTrigger `
    -Once `
    -At ((Get-Date).AddMinutes(1)) `
    -RepetitionInterval (New-TimeSpan -Minutes 1)

$watchdogSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
    -MultipleInstances IgnoreNew

$watchdogPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

$existingWatchdog = Get-ScheduledTask -TaskName $WatchdogTaskName -ErrorAction SilentlyContinue
$watchdogNeedsUpdate = $true

if ($existingWatchdog) {
    $wdAction = $existingWatchdog.Actions | Select-Object -First 1
    if ($wdAction.Execute -ieq $expectedExecute -and $wdAction.Arguments -eq $watchdogArguments) {
        $watchdogNeedsUpdate = $false
        Write-Skip 'Tunnel watchdog scheduled task already exists with the correct action.'
    }
    else {
        Write-Fix 'Tunnel watchdog scheduled task exists but needs to be updated.'
    }
}

if ($watchdogNeedsUpdate) {
    Register-ScheduledTask `
        -TaskName $WatchdogTaskName `
        -Action $watchdogAction `
        -Trigger $watchdogTrigger `
        -Settings $watchdogSettings `
        -Principal $watchdogPrincipal `
        -Description 'Checks MediaStack Control Gateway tunnel health every minute and performs bounded recovery when necessary.' `
        -Force | Out-Null

    Write-Good 'Tunnel watchdog scheduled task created/updated.'
}

# ===========================================================================
# 11. Start/reuse tunnel runtime
# ===========================================================================
Show-Stage 11 'Start or reuse tunnel runtime'

$task = Get-ScheduledTask -TaskName $TaskName
$runtimeHealthyNow = ($task.State -eq 'Running' -and (Test-TunnelHealth))
$runtimeNeedsReload = ($McpServerChanged -or $profileChanged -or $TunnelRunnerChanged)

if ($runtimeHealthyNow -and (-not $runtimeNeedsReload)) {
    Write-Skip 'Tunnel scheduled task is running and /healthz reports healthy; runtime code/profile are unchanged.'
    if (-not (Test-TunnelReady)) {
        $readyDetail = Get-TunnelLocalProbe -Path '/readyz' -TimeoutSeconds 3
        $detailText = @()
        if ($null -ne $readyDetail.StatusCode) { $detailText += "HTTP $($readyDetail.StatusCode)" }
        if (-not [string]::IsNullOrWhiteSpace($readyDetail.Error)) { $detailText += $readyDetail.Error }
        if (-not [string]::IsNullOrWhiteSpace($readyDetail.Body)) { $detailText += (($readyDetail.Body -replace '[\r\n]+',' ').Trim()) }
        Write-Warning ("Tunnel is live but /readyz is not currently ready. It will not be restarted immediately. " + ($detailText -join '; '))
    }
}
else {
    if ($task.State -eq 'Running') {
        if ($McpServerChanged) {
            Write-Fix 'Tunnel task is healthy but MCP code changed. Restarting to load the new tool schema.'
        }
        elseif ($profileChanged) {
            Write-Fix 'Tunnel profile changed. Restarting the runtime to publish the new health endpoint file and settings.'
        }
        elseif ($TunnelRunnerChanged) {
            Write-Fix 'Tunnel supervisor changed. Restarting the runtime to load the new supervisor/log-rotation behavior.'
        }
        else {
            Write-Fix 'Tunnel task is running but /healthz liveness failed. Restarting it.'
        }
        Stop-TunnelTaskIfRunning
    }
    else {
        Write-Fix "Tunnel task state is '$($task.State)'. Starting it."
    }

    Remove-Item -LiteralPath $HealthUrlFile -Force -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $LegacyHealthUrlFile -Force -Confirm:$false -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskName $TaskName

    Write-Progress -Id 3 -ParentId 1 -Activity 'Tunnel runtime' -Status 'Waiting for /readyz...' -PercentComplete 50

    if (-not (Wait-TunnelReady -TimeoutSeconds 60)) {
        $task = Get-ScheduledTask -TaskName $TaskName
        $info = Get-ScheduledTaskInfo -TaskName $TaskName
        $publishedUrl = Get-TunnelHealthBaseUrl

        if (Test-TunnelHealth) {
            $readyDetail = Get-TunnelLocalProbe -Path '/readyz' -TimeoutSeconds 3
            Write-Warning "Tunnel became live but /readyz did not reach HTTP 200 within 60 seconds. Leaving the live tunnel running for bounded watchdog recovery. Status=$($readyDetail.StatusCode); Error=$($readyDetail.Error); Body=$($readyDetail.Body)"
        }
        else {
            $runtimeLog = ''
            if (Test-Path -LiteralPath (Join-Path $LogDir 'tunnel-runtime.log')) {
                $runtimeLog = (Get-Content -LiteralPath (Join-Path $LogDir 'tunnel-runtime.log') -Tail 60) -join "`r`n"
            }
            throw "Tunnel runtime did not become live within 60 seconds. TaskState=$($task.State), LastTaskResult=$($info.LastTaskResult), HealthURL=$publishedUrl`r`nRuntime log tail:`r`n$runtimeLog"
        }
    }

    Write-Progress -Id 3 -ParentId 1 -Activity 'Tunnel runtime' -Completed
}

$task = Get-ScheduledTask -TaskName $TaskName
if ($task.State -ne 'Running') {
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    throw "Tunnel became ready but the scheduled task is no longer Running. State=$($task.State), LastTaskResult=$($info.LastTaskResult)"
}

Write-Skip 'Tunnel runtime is running and ready.'

# ===========================================================================
# 12. Final validation and summary
# ===========================================================================
Show-Stage 12 'Final live runtime validation'

$healthBaseUrl = Get-TunnelHealthBaseUrl
if (-not $healthBaseUrl) {
    throw "The running tunnel did not publish a valid health URL to $HealthUrlFile"
}

$healthProbe = Get-TunnelLocalProbe -Path '/healthz' -TimeoutSeconds 3
if (-not $healthProbe.Ok) {
    throw "The tunnel runtime is running but /healthz liveness failed. Status=$($healthProbe.StatusCode); Error=$($healthProbe.Error); Body=$($healthProbe.Body)"
}
Write-Skip "Live tunnel health check passed: $healthBaseUrl/healthz"

$readyProbe = Get-TunnelLocalProbe -Path '/readyz' -TimeoutSeconds 3
if ($readyProbe.Ok) {
    Write-Skip "Live tunnel readiness check passed: $healthBaseUrl/readyz"
}
else {
    Write-Warning "Tunnel liveness is healthy, but /readyz is not currently HTTP 200. Status=$($readyProbe.StatusCode); Error=$($readyProbe.Error); Body=$($readyProbe.Body)"
}

# Migration cleanup: the previous .url file was a plain-text state file, not a
# Windows Internet Shortcut. Remove it only after the new endpoint file is live.
if (Test-Path -LiteralPath $LegacyHealthUrlFile) {
    Remove-Item -LiteralPath $LegacyHealthUrlFile -Force -Confirm:$false -ErrorAction SilentlyContinue
    Write-Fix "Removed obsolete health endpoint state file: $LegacyHealthUrlFile"
}

Write-Progress -Id 1 -Activity 'MediaStack Control Gateway installation' -Completed

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "INSTALLATION COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "Plex server       : $plexName"
Write-Host "Tautulli API      : $TautulliUrl"
Write-Host "Tautulli available: $tautulliAvailable"
Write-Host "Sonarr API        : $SonarrUrl"
Write-Host "Sonarr available  : $($arrAvailability['sonarr'])"
Write-Host "Radarr API        : $RadarrUrl"
Write-Host "Radarr available  : $($arrAvailability['radarr'])"
Write-Host "Lidarr API        : $LidarrUrl"
Write-Host "Lidarr available  : $($arrAvailability['lidarr'])"
Write-Host "Reporting exports : $ReportingExportDir"
Write-Host "Tunnel ID         : $TunnelId"
Write-Host "Install root      : $Root"
Write-Host "Portable Python   : $PythonExe"
Write-Host "MCP server        : $McpServer"
Write-Host "Tunnel client     : $TunnelExe"
Write-Host "Tunnel profile dir: $ProfileDir"
Write-Host "Tunnel task       : $TaskName"
Write-Host "Watchdog task     : $WatchdogTaskName"
Write-Host "Runtime log       : $(Join-Path $LogDir 'tunnel-runtime.log')"
Write-Host "Watchdog log      : $(Join-Path $LogDir 'tunnel-watchdog.log')"
Write-Host "Health endpoint   : $HealthUrlFile"
Write-Host "Open tunnel UI    : $OpenTunnelUiScript"
Write-Host "Doctor log        : $doctorLog"
Write-Host "Installer log     : $InstallerLog"
Write-Host "Health URL        : $healthBaseUrl/healthz"
Write-Host "Ready URL         : $healthBaseUrl/readyz"
Write-Host "Local admin UI    : $healthBaseUrl/ui"
Write-Host ""
Write-Host "This installer is now safe to run again." -ForegroundColor Green
Write-Host "Working stages will report SKIP; only missing/broken stages will be repaired." -ForegroundColor Green
Write-Host "SELF-HEALING ENABLED: tunnel-client restarts automatically after exit; watchdog uses /healthz liveness plus bounded /readyz recovery ($WatchdogReadinessFailureThreshold failures, $WatchdogReadinessRestartCooldownMinutes-minute readiness restart cooldown)." -ForegroundColor Green
Write-Host "COLLECTION METADATA ENABLED: read/update summaries, sort/display settings, labels, visibility, posters, and background art." -ForegroundColor Green
Write-Host "ITEM SUMMARY METADATA ENABLED: read/update movie and TV show summaries by exact Plex rating key; edits are locked and preserve all other metadata." -ForegroundColor Green
Write-Host "ITEM POSTER METADATA ENABLED: replace individual movie and TV show posters by exact Plex rating key from URL or local image; selected posters are locked." -ForegroundColor Green
Write-Host "ADDED AT METADATA ENABLED: read/update movie, show, season, and episode addedAt values; exact and filtered bulk writes can reorder Recently Added without touching media files." -ForegroundColor Green
Write-Host "HUB CACHE REFRESH ENABLED: non-destructively refresh/warm a library's transient Plex hubs and verify current Recently Added ordering." -ForegroundColor Green
Write-Host "INSTALLER LOGGING ENABLED: full timestamped installer transcripts are stored under $LogDir." -ForegroundColor Green
Write-Host "TUNNEL DIAGNOSTICS ENABLED: read-only timing and runtime-log diagnostics can measure response deadlines, TTL events, restarts, and transport failures." -ForegroundColor Green
Write-Host "BOUNDED LOGGING ENABLED: runtime log rotates at $([math]::Round($RuntimeLogMaxBytes / 1MB)) MB with $RuntimeLogRetainedFiles retained files; watchdog log rotates at $([math]::Round($WatchdogLogMaxBytes / 1MB)) MB with $WatchdogLogRetainedFiles retained files; $InstallerLogRetainCount installer transcripts retained." -ForegroundColor Green
Write-Host "HEALTH ENDPOINT STATE: dynamic localhost endpoint is stored as tunnel-health-endpoint.txt; Open-Tunnel-UI.ps1 opens the current admin UI." -ForegroundColor Green
Write-Host "TAUTULLI REPORTING ENABLED: cached library counts, logical storage, media breakdowns, history/top stats, and local CSV/JSON exports." -ForegroundColor Green
Write-Host "REPORTING DESIGN: normal questions return compact aggregates; full inventory data crosses the tunnel only when an export is explicitly requested." -ForegroundColor Green
Write-Host "ARR MANAGEMENT ENABLED: Sonarr/Radarr/Lidarr reporting, adds/edits, explicit-path requests, bulk monitor/profile/search workflows, and inventory exports." -ForegroundColor Green
Write-Host "ARR DELETE SAFETY: deletion requires prepare + explicit user confirmation + short-lived token; physical media deletion is separately bound to the prepared choice." -ForegroundColor Green
Write-Host "EDITABLE ACL ENABLED: protected generated files also grant Full Control to the Windows account that ran this installer." -ForegroundColor Green
if ($McpServerChanged) {
    Write-Host "MCP CODE CHANGED: the tunnel runtime was restarted and the new tool schema is now live." -ForegroundColor Cyan
    Write-Host "Refresh/Rescan the MediaStack Control Gateway app actions in ChatGPT now." -ForegroundColor Cyan
}
elseif ($profileChanged -or $TunnelRunnerChanged) {
    Write-Host "TUNNEL RUNTIME UPDATED: profile/supervisor changes were loaded without changing the MCP tool schema." -ForegroundColor Cyan
}
Write-Host ""
Write-Host "Next in ChatGPT:" -ForegroundColor Cyan
Write-Host "  Settings -> Connectors/Apps -> add a developer MCP app -> Connection: Tunnel"
Write-Host "  Select/paste tunnel: $TunnelId"
Write-Host "  Scan tools."
}
finally {
    if ($InstallerTranscriptActive) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {
            # Do not hide an installer result because transcript shutdown failed.
        }
        $InstallerTranscriptActive = $false
    }
}
