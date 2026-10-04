<#
.SYNOPSIS
    Tiny11 ARM64 Core Builder - Creates a heavily slimmed Windows 11 ARM64 ISO.

.DESCRIPTION
    Builds a "Core" edition of Windows 11 ARM64 by removing provisioned Appx
    packages, non-essential system packages, Edge, OneDrive, WinRE, and the
    WinSxS component store. Injects offline registry tweaks to bypass TPM/Secure
    Boot/RAM/CPU checks and disable telemetry. Output is a bootable ARM64 ISO.

.PARAMETER ISODrive
    Drive letter of the mounted Windows 11 ARM64 ISO (e.g., "E" or "E:").

.PARAMETER WorkDrive
    Drive used for temporary working directories. Defaults to system drive.

.PARAMETER OutputISO
    Full path to write the resulting ISO.

.PARAMETER EnableNetFx3
    Optional. Enables .NET Framework 3.5 in the image.

.PARAMETER SkipCopy
    Optional. Reuses existing working directory if present.

.PARAMETER AssumeYes
    Optional. Automatically selects Windows 11 Pro (or last index).

.PARAMETER KeepLog
    Optional. Keeps the transcript running after the script finishes.

.NOTES
    Author:   Tiny11 ARM64 Core Builder contributors
    Version:  2.0.1
    License:  MIT
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory, HelpMessage="Drive letter of the mounted Windows 11 ARM64 ISO (e.g., 'E').")]
    [ValidateNotNullOrEmpty()]
    [string]$ISODrive,

    [string]$WorkDrive = $env:SystemDrive,

    [string]$OutputISO = "$PSScriptRoot\tiny11-arm64.iso",

    [switch]$EnableNetFx3,
    [switch]$SkipCopy,
    [switch]$AssumeYes,
    [switch]$KeepLog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$script:Version   = '2.0.1'
$script:StartTime = Get-Date
$script:WorkRoot  = Join-Path $WorkDrive 'tiny11'
$script:MountDir  = Join-Path $WorkDrive 'tiny11-mount'
$script:LogPath   = Join-Path $PSScriptRoot 'tiny11.log'
$script:Arch      = $null
$script:LangCode  = 'en-US'
$script:Success   = $false
$script:HostArch  = $env:PROCESSOR_ARCHITECTURE

Start-Transcript -Path $script:LogPath -Force | Out-Null

# =============================================================
# Logging helpers
# =============================================================
function Write-Step {
    param([string]$Message, [ConsoleColor]$Color = 'Cyan')
    Write-Host "`n==> $Message" -ForegroundColor $Color
}

function Write-Info { param([string]$Message) Write-Host "    $Message" -ForegroundColor Gray }
function Write-Warn { param([string]$Message) Write-Host "    [WARN] $Message" -ForegroundColor Yellow }
function Write-Err  { param([string]$Message) Write-Host "    [ERR]  $Message" -ForegroundColor Red }

# =============================================================
# Pre-flight checks
# =============================================================
function Test-Prerequisites {
    Write-Step "Pre-flight checks" 'Green'

    $sourceRoot = $ISODrive.TrimEnd('\').TrimEnd(':') + ':'
    if (-not (Test-Path $sourceRoot)) {
        throw "ISO drive '$sourceRoot' does not exist."
    }
    if (-not (Test-Path "$sourceRoot\sources\boot.wim")) {
        throw "boot.wim not found in $sourceRoot\sources. Ensure the ISO is mounted."
    }
    Write-Info "Source ISO: $sourceRoot"

    $driveLetter = $WorkDrive.TrimEnd('\').TrimEnd(':')
    if ($driveLetter.Length -gt 1) { $driveLetter = $driveLetter.Substring(0, 1) }
    $driveLetter += ':'
    $disk = Get-PSDrive -Name $driveLetter.TrimEnd(':') -ErrorAction SilentlyContinue
    if ($disk) {
        $freeGB = [Math]::Round($disk.Free / 1GB, 1)
        Write-Info "Work drive $driveLetter free space: $freeGB GB"
        if ($freeGB -lt 25) {
            throw "Not enough free space on $driveLetter (need >= 25 GB, have $freeGB GB)."
        }
    }

    $dismPath = Join-Path $env:SystemRoot 'System32\Dism.exe'
    if (-not (Test-Path $dismPath)) {
        throw "DISM not found at $dismPath."
    }
    Write-Info "DISM: $dismPath"
    Write-Info "Host architecture: $script:HostArch"
    Write-Info "Script version:    $script:Version"
}

function Test-CrossArchitecture {
    param([string]$TargetArch)
    if ($script:HostArch -eq 'AMD64' -and $TargetArch -eq 'arm64') {
        Write-Warn "Host is x64 but target image is ARM64."
        Write-Warn "DISM write-mount on cross-architecture WIMs is known to be flaky."
        Write-Warn "If mount keeps failing, please run this script on an ARM64 device."
    }
    if ($script:HostArch -eq 'ARM64' -and $TargetArch -eq 'amd64') {
        Write-Warn "Host is ARM64 but target image is x64."
        Write-Warn "Cross-architecture mount may fail."
    }
}

# =============================================================
# File system helpers
# =============================================================
function New-CleanDir {
    param([string]$Path)
    if (Test-Path $Path) { Remove-Item $Path -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Take-Ownership {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    if (Test-Path $Path -PathType Container) {
        & takeown.exe /F $Path /R /D Y 2>&1 | Out-Null
        & icacls.exe   $Path /grant "*S-1-5-32-544:(F)" /T /C /Q 2>&1 | Out-Null
    } else {
        & takeown.exe /F $Path 2>&1 | Out-Null
        & icacls.exe   $Path /grant "*S-1-5-32-544:(F)" /C /Q 2>&1 | Out-Null
    }
}

function Remove-Safe {
    param([string]$Path)
    if (Test-Path $Path) {
        Take-Ownership $Path
        Remove-Item $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Clear-ReadOnlyAttributes {
    param([string]$RootPath)
    Get-ChildItem -Path $RootPath -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Attributes -band [IO.FileAttributes]::ReadOnly) {
            $_.Attributes = $_.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)
        }
    }
}

# =============================================================
# DISM helpers
# =============================================================
function Invoke-Dism {
    param(
        [Parameter(Mandatory, Position=0)] [string[]]$Arguments,
        [switch]$IgnoreError,
        [switch]$PassThru
    )
    $output = & dism.exe /English @Arguments 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $IgnoreError) {
        throw "DISM failed (exit code $code): $($output -join "`n")"
    }
    if ($PassThru) { return $output }
}

function Reset-WimServ {
    Write-Warn "Restarting wimserv service to clear stuck mount state..."
    Stop-Service -Name wimserv -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Start-Service -Name wimserv -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
}

function Clear-Mountpoints {
    & dism.exe /English /Cleanup-Mountpoints 2>&1 | Out-Null
    & dism.exe /English /Cleanup-Wim 2>&1 | Out-Null
}

function Test-MountValid {
    param([string]$MountDir)
    return ((Test-Path "$MountDir\Windows\System32") -and (Test-Path "$MountDir\Windows\explorer.exe"))
}

function Mount-WimSafely {
    param(
        [string]$WimPath,
        [int]$Index,
        [string]$MountDir,
        [int]$MaxRetries = 6
    )

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        $waitSec = [Math]::Min(5 * $attempt, 30)
        Write-Info "Mount attempt $attempt / $MaxRetries"

        if (Test-Path $MountDir) {
            & dism.exe /English /Unmount-Image /MountDir:$MountDir /Discard 2>&1 | Out-Null
            Remove-Item $MountDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Clear-Mountpoints

        try {
            Invoke-Dism -Arguments @('/Mount-Image', "/ImageFile:$WimPath", "/Index:$Index", "/MountDir:$MountDir") -IgnoreError
            Start-Sleep -Seconds 3

            if (Test-MountValid -MountDir $MountDir) {
                Write-Info "Mount succeeded and verified."
                return
            }
            Write-Warn "Mount command returned but verification failed."
        } catch {
            Write-Warn "Mount threw exception: $($_.Exception.Message)"
        }

        Reset-WimServ
        Write-Info "Waiting $waitSec seconds before retry..."
        Start-Sleep -Seconds $waitSec
    }

    throw "Failed to mount $WimPath after $MaxRetries attempts. If running on x64 host with ARM64 image, please use an ARM64 host."
}

function Dismount-WimSafely {
    param(
        [string]$MountDir,
        [switch]$Discard,
        [int]$MaxRetries = 6
    )

    $flag = if ($Discard) { '/Discard' } else { '/Commit' }

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        $waitSec = [Math]::Min(10 * $attempt, 60)
        Write-Info "Dismount attempt $attempt / $MaxRetries ($flag)"

        try {
            Invoke-Dism -Arguments @('/Unmount-Image', "/MountDir:$MountDir", $flag) -IgnoreError
            if (-not (Test-Path "$MountDir\Windows\System32")) {
                Write-Info "Dismount succeeded."
                return
            }
            Write-Warn "Dismount command returned but mount dir still populated."
        } catch {
            Write-Warn "Dismount threw exception: $($_.Exception.Message)"
        }

        Start-Sleep -Seconds $waitSec
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    }

    throw "Failed to dismount $MountDir after $MaxRetries attempts."
}

function Export-WimSafely {
    param(
        [string]$SourceWim,
        [int]$Index,
        [string]$DestinationWim,
        [string]$Compress = 'max',
        [int]$MaxRetries = 6
    )

    if (Test-Path $DestinationWim) { Remove-Item $DestinationWim -Force -ErrorAction SilentlyContinue }

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        $waitSec = [Math]::Min(10 * $attempt, 60)
        Write-Info "Export attempt $attempt / $MaxRetries"

        try {
            Invoke-Dism -Arguments @('/Export-Image', "/SourceImageFile:$SourceWim", "/SourceIndex:$Index", "/DestinationImageFile:$DestinationWim", "/Compress:$Compress") -IgnoreError
            if (Test-Path $DestinationWim) {
                Write-Info "Export succeeded."
                return
            }
            Write-Warn "Export command returned but destination file missing."
        } catch {
            Write-Warn "Export threw exception: $($_.Exception.Message)"
        }

        Start-Sleep -Seconds $waitSec
    }

    throw "Failed to export $SourceWim after $MaxRetries attempts."
}

# =============================================================
# WIM info helpers
# =============================================================
function Get-WimImages {
    param([string]$WimPath)
    $output = Invoke-Dism -Arguments @('/Get-WimInfo', "/WimFile:$WimPath") -PassThru
    $list = @()
    $current = $null
    foreach ($line in $output) {
        if ($line -match '^Index\s*:\s*(\d+)') {
            if ($current) { $list += $current }
            $current = [PSCustomObject]@{ Index = [int]$Matches[1]; Name = ''; Description = '' }
        } elseif ($line -match '^Name\s*:\s*(.+)' -and $current) {
            $current.Name = $Matches[1].Trim()
        } elseif ($line -match '^Description\s*:\s*(.+)' -and $current) {
            $current.Description = $Matches[1].Trim()
        }
    }
    if ($current) { $list += $current }
    return $list
}

function Get-WimArch {
    param([string]$WimPath, [int]$Index)
    $output = Invoke-Dism -Arguments @('/Get-WimInfo', "/WimFile:$WimPath", "/Index:$Index") -PassThru
    foreach ($line in $output) {
        if ($line -match '^Architecture\s*:\s*(\S+)') { return $Matches[1].Trim() }
    }
    return $null
}

function Get-DismPackages {
    param([string]$MountDir)
    $output = Invoke-Dism -Arguments @("/Image:$MountDir", '/Get-Packages', '/Format:Table') -PassThru
    $result = @()
    foreach ($line in $output) {
        if ($line -match '^\s*\|\s*([^\|]+?)\s*\|\s*Installed\s*\|') {
            $result += $Matches[1].Trim()
        }
    }
    return $result
}

function Get-DismAppx {
    param([string]$MountDir)
    $output = Invoke-Dism -Arguments @("/Image:$MountDir", '/Get-ProvisionedAppxPackages') -PassThru
    $result = @()
    foreach ($line in $output) {
        if ($line -match '^PackageName\s*:\s*(.+)') { $result += $Matches[1].Trim() }
    }
    return $result
}

# =============================================================
# Registry mount / dismount
# =============================================================
$script:HiveMap = @{
    COMPONENTS = 'COMPONENTS'
    DEFAULT    = 'default'
    NTUSER     = 'Users\Default\ntuser.dat'
    SOFTWARE   = 'SOFTWARE'
    SYSTEM     = 'SYSTEM'
}

function Mount-RegistryHives {
    param([string]$MountDir, [hashtable]$HiveMap)
    foreach ($name in $HiveMap.Keys) {
        $hiveFile = if ($name -eq 'NTUSER') {
            Join-Path $MountDir 'Users\Default\ntuser.dat'
        } else {
            Join-Path $MountDir "Windows\System32\config\$($HiveMap[$name])"
        }
        if (-not (Test-Path $hiveFile)) {
            Write-Warn "Registry hive not found, skipping: $hiveFile"
            continue
        }
        & cmd.exe /c "reg.exe load `"HKLM\z$name`" `"$hiveFile`" 2>nul"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to load registry hive $name ($hiveFile)."
        }
    }
}

function Dismount-RegistryHives {
    param([hashtable]$HiveMap)
    foreach ($name in $HiveMap.Keys) {
        $regPath = "HKLM:\z$name"
        if (Test-Path $regPath) {
            & cmd.exe /c "reg.exe unload `"HKLM\z$name`" 2>nul"
        }
    }
}

function Set-OfflineRegistryTweaks {
    param([hashtable]$HiveMap, [array]$Tweaks)
    foreach ($t in $Tweaks) {
        $full = "HKLM:\z$($t.Hive)\$($t.Path)"
        $type = if ($t.Type -eq 'DWord') { 'DWord' } else { 'String' }
        if (-not (Test-Path $full)) {
            New-Item -Path $full -Force | Out-Null
        }
        New-ItemProperty -Path $full -Name $t.Name -Value $t.Value -PropertyType $type -Force | Out-Null
    }
}

# =============================================================
# Removal lists
# =============================================================
$script:AppxPrefixes = @(
    'Clipchamp.Clipchamp_', 'Microsoft.BingNews_', 'Microsoft.BingWeather_',
    'Microsoft.GamingApp_', 'Microsoft.GetHelp_', 'Microsoft.Getstarted_',
    'Microsoft.MicrosoftOfficeHub_', 'Microsoft.MicrosoftSolitaireCollection_',
    'Microsoft.People_', 'Microsoft.PowerAutomateDesktop_', 'Microsoft.Todos_',
    'Microsoft.WindowsAlarms_', 'microsoft.windowscommunicationsapps_',
    'Microsoft.WindowsFeedbackHub_', 'Microsoft.WindowsMaps_',
    'Microsoft.WindowsSoundRecorder_', 'Microsoft.Xbox.TCUI_',
    'Microsoft.XboxGamingOverlay_', 'Microsoft.XboxGameOverlay_',
    'Microsoft.XboxSpeechToTextOverlay_', 'Microsoft.YourPhone_',
    'Microsoft.ZuneMusic_', 'Microsoft.ZuneVideo_',
    'MicrosoftCorporationII.MicrosoftFamily_', 'MicrosoftCorporationII.QuickAssist_',
    'MicrosoftTeams_', 'MSTeams_', 'Microsoft.OutlookForWindows_',
    'Microsoft.Windows.Teams_', 'Microsoft.Windows.Copilot', 'Microsoft.Copilot_'
)

function Remove-AppxFromImage {
    Write-Step "Removing provisioned Appx packages"
    $appxList = @(Get-DismAppx -MountDir $script:MountDir)
    $removed = 0
    foreach ($name in $appxList) {
        if ($script:AppxPrefixes | Where-Object { $name.StartsWith($_) }) {
            Write-Info "  - $name"
            Invoke-Dism -Arguments @("/Image:$script:MountDir", '/Remove-ProvisionedAppxPackage', "/PackageName:$name") -IgnoreError
            $removed++
        }
    }
    Write-Info "Removed $removed Appx packages."
}

function Get-SystemPackagePatterns {
    $common = @(
        'Microsoft-Windows-InternetExplorer-Optional-Package~31bf3856ad364e35',
        "Microsoft-Windows-LanguageFeatures-Handwriting-$script:LangCode-Package~31bf3856ad364e35",
        "Microsoft-Windows-LanguageFeatures-OCR-$script:LangCode-Package~31bf3856ad364e35",
        "Microsoft-Windows-LanguageFeatures-Speech-$script:LangCode-Package~31bf3856ad364e35",
        "Microsoft-Windows-LanguageFeatures-TextToSpeech-$script:LangCode-Package~31bf3856ad364e35",
        'Microsoft-Windows-MediaPlayer-Package~31bf3856ad364e35',
        'Microsoft-Windows-Wallpaper-Content-Extended-FoD-Package~31bf3856ad364e35',
        'Windows-Defender-Client-Package~31bf3856ad364e35~',
        'Microsoft-Windows-WordPad-FoD-Package~',
        'Microsoft-Windows-TabletPCMath-Package~',
        'Microsoft-Windows-StepsRecorder-Package~'
    )
    if ($script:Arch -eq 'amd64') {
        $common += 'Microsoft-Windows-Kernel-LA57-FoD-Package~31bf3856ad364e35~amd64'
    }
    return $common
}

function Remove-SystemPackages {
    Write-Step "Removing system packages"
    $patterns = Get-SystemPackagePatterns
    $installed = Get-DismPackages -MountDir $script:MountDir
    foreach ($pattern in $patterns) {
        $installed | Where-Object { $_ -like "$pattern*" } | ForEach-Object {
            Write-Info "  - $_"
            Invoke-Dism -Arguments @("/Image:$script:MountDir", '/Remove-Package', "/PackageName:$_") -IgnoreError
        }
    }
}

function Remove-BundledApps {
    Write-Step "Removing Edge / OneDrive / WinRE"

    $edgePaths = @(
        'Program Files (x86)\Microsoft\Edge',
        'Program Files\Microsoft\Edge',
        'Program Files (x86)\Microsoft\EdgeUpdate',
        'Program Files\Microsoft\EdgeUpdate',
        'Program Files (x86)\Microsoft\EdgeCore',
        'Program Files\Microsoft\EdgeCore',
        'Windows\System32\Microsoft-Edge-Webview'
    )
    foreach ($rel in $edgePaths) {
        Remove-Safe (Join-Path $script:MountDir $rel)
    }

    $edgeFilter = if ($script:Arch -eq 'arm64') {
        'arm64_microsoft-edge-webview_31bf3856ad364e35*'
    } else {
        'amd64_microsoft-edge-webview_31bf3856ad364e35*'
    }
    Get-ChildItem (Join-Path $script:MountDir 'Windows\WinSxS') -Filter $edgeFilter -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Safe $_.FullName }

    Remove-Safe (Join-Path $script:MountDir 'Windows\System32\OneDriveSetup.exe')

    $recoveryDir = Join-Path $script:MountDir 'Windows\System32\Recovery'
    Remove-Safe (Join-Path $recoveryDir 'winre.wim')
    if (-not (Test-Path $recoveryDir)) { New-Item -ItemType Directory $recoveryDir -Force | Out-Null }
    New-Item -Path (Join-Path $recoveryDir 'winre.wim') -ItemType File -Force | Out-Null
}

# =============================================================
# WinSxS keep-list
# =============================================================
$script:WinSxSKeepAmd64 = @(
    'x86_microsoft.windows.common-controls_6595b64144ccf1df_*',
    'x86_microsoft.windows.gdiplus_6595b64144ccf1df_*',
    'x86_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*',
    'x86_microsoft.windows.isolationautomation_6595b64144ccf1df_*',
    'x86_microsoft-windows-s..ngstack-onecorebase_31bf3856ad364e35_*',
    'x86_microsoft-windows-s..stack-termsrv-extra_31bf3856ad364e35_*',
    'x86_microsoft-windows-servicingstack_31bf3856ad364e35_*',
    'x86_microsoft-windows-servicingstack-inetsrv_*',
    'x86_microsoft-windows-servicingstack-onecore_*',
    'amd64_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*',
    'amd64_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*',
    'amd64_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*',
    'amd64_microsoft.windows.common-controls_6595b64144ccf1df_*',
    'amd64_microsoft.windows.gdiplus_6595b64144ccf1df_*',
    'amd64_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*',
    'amd64_microsoft.windows.isolationautomation_6595b64144ccf1df_*',
    'amd64_microsoft-windows-s..stack-inetsrv-extra_31bf3856ad364e35_*',
    'amd64_microsoft-windows-s..stack-msg.resources_31bf3856ad364e35_*',
    'amd64_microsoft-windows-s..stack-termsrv-extra_31bf3856ad364e35_*',
    'amd64_microsoft-windows-servicingstack_31bf3856ad364e35_*',
    'amd64_microsoft-windows-servicingstack-inetsrv_31bf3856ad364e35_*',
    'amd64_microsoft-windows-servicingstack-msg_31bf3856ad364e35_*',
    'amd64_microsoft-windows-servicingstack-onecore_31bf3856ad364e35_*',
    'Catalogs', 'FileMaps', 'Fusion', 'InstallTemp', 'Manifests',
    'x86_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*',
    'x86_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*',
    'x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*'
)

$script:WinSxSKeepArm64 = @(
    'arm64_microsoft-windows-servicingstack-onecore_31bf3856ad364e35_*',
    'Catalogs', 'FileMaps', 'Fusion', 'InstallTemp', 'Manifests',
    'SettingsManifests', 'Temp',
    'x86_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*',
    'x86_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*',
    'x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*',
    'x86_microsoft.windows.common-controls_6595b64144ccf1df_*',
    'x86_microsoft.windows.gdiplus_6595b64144ccf1df_*',
    'x86_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*',
    'x86_microsoft.windows.isolationautomation_6595b64144ccf1df_*',
    'arm_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*',
    'arm_microsoft.windows.common-controls_6595b64144ccf1df_*',
    'arm_microsoft.windows.gdiplus_6595b64144ccf1df_*',
    'arm_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*',
    'arm_microsoft.windows.isolationautomation_6595b64144ccf1df_*',
    'arm64_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*',
    'arm64_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*',
    'arm64_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*',
    'arm64_microsoft.windows.common-controls_6595b64144ccf1df_*',
    'arm64_microsoft.windows.gdiplus_6595b64144ccf1df_*',
    'arm64_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*',
    'arm64_microsoft.windows.isolationautomation_6595b64144ccf1df_*',
    'arm64_microsoft-windows-servicing-adm_31bf3856ad364e35_*',
    'arm64_microsoft-windows-servicingcommon_31bf3856ad364e35_*',
    'arm64_microsoft-windows-servicing-onecore-uapi_31bf3856ad364e35_*',
    'arm64_microsoft-windows-servicingstack_31bf3856ad364e35_*',
    'arm64_microsoft-windows-servicingstack-inetsrv_31bf3856ad364e35_*',
    'arm64_microsoft-windows-servicingstack-msg_31bf3856ad364e35_*'
)

function Compress-WinSxS {
    Write-Step "Slimming WinSxS" 'Yellow'

    $sxs     = Join-Path $script:MountDir 'Windows\WinSxS'
    $sxsEdit = Join-Path $script:MountDir 'Windows\WinSxS_edit'
    $keep    = if ($script:Arch -eq 'arm64') { $script:WinSxSKeepArm64 } else { $script:WinSxSKeepAmd64 }

    if (-not (Test-Path $sxs)) {
        Write-Warn "WinSxS folder not found, skipping."
        return
    }

    New-CleanDir $sxsEdit
    Take-Ownership $sxs

    foreach ($pattern in $keep) {
        Get-ChildItem $sxs -Filter $pattern -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item $_.FullName -Destination (Join-Path $sxsEdit $_.Name) -Recurse -Force
        }
    }

    Write-Info "Deleting original WinSxS..."
    Remove-Item $sxs -Recurse -Force -ErrorAction SilentlyContinue
    Rename-Item $sxsEdit -NewName 'WinSxS'
}

# =============================================================
# Offline registry tweaks
# =============================================================
$script:RegTweaks = @(
    @{Hive='DEFAULT'; Path='Control Panel\UnsupportedHardwareNotificationCache'; Name='SV1'; Type='DWord'; Value='0'}
    @{Hive='DEFAULT'; Path='Control Panel\UnsupportedHardwareNotificationCache'; Name='SV2'; Type='DWord'; Value='0'}
    @{Hive='NTUSER';  Path='Control Panel\UnsupportedHardwareNotificationCache'; Name='SV1'; Type='DWord'; Value='0'}
    @{Hive='NTUSER';  Path='Control Panel\UnsupportedHardwareNotificationCache'; Name='SV2'; Type='DWord'; Value='0'}
    @{Hive='SYSTEM';  Path='Setup\LabConfig'; Name='BypassCPUCheck';        Type='DWord'; Value='1'}
    @{Hive='SYSTEM';  Path='Setup\LabConfig'; Name='BypassRAMCheck';        Type='DWord'; Value='1'}
    @{Hive='SYSTEM';  Path='Setup\LabConfig'; Name='BypassSecureBootCheck'; Type='DWord'; Value='1'}
    @{Hive='SYSTEM';  Path='Setup\LabConfig'; Name='BypassStorageCheck';    Type='DWord'; Value='1'}
    @{Hive='SYSTEM';  Path='Setup\LabConfig'; Name='BypassTPMCheck';        Type='DWord'; Value='1'}
    @{Hive='SYSTEM';  Path='Setup\MoSetup';   Name='AllowUpgradesWithUnsupportedTPMOrCPU'; Type='DWord'; Value='1'}
    @{Hive='NTUSER';  Path='SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='OemPreInstalledAppsEnabled'; Type='DWord'; Value='0'}
    @{Hive='NTUSER';  Path='SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='PreInstalledAppsEnabled';    Type='DWord'; Value='0'}
    @{Hive='NTUSER';  Path='SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SilentInstalledAppsEnabled'; Type='DWord'; Value='0'}
    @{Hive='NTUSER';  Path='SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='ContentDeliveryAllowed';     Type='DWord'; Value='0'}
    @{Hive='NTUSER';  Path='SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SubscribedContentEnabled';   Type='DWord'; Value='0'}
    @{Hive='NTUSER';  Path='SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name='SystemPaneSuggestionsEnabled'; Type='DWord'; Value='0'}
    @{Hive='SOFTWARE';Path='Policies\Microsoft\Windows\CloudContent'; Name='DisableWindowsConsumerFeatures'; Type='DWord'; Value='1'}
    @{Hive='SOFTWARE';Path='Policies\Microsoft\Windows\CloudContent'; Name='DisableConsumerAccountStateContent'; Type='DWord'; Value='1'}
    @{Hive='SOFTWARE';Path='Policies\Microsoft\Windows\CloudContent'; Name='DisableCloudOptimizedContent'; Type='DWord'; Value='1'}
    @{Hive='SOFTWARE';Path='Policies\Microsoft\PushToInstall'; Name='DisablePushToInstall'; Type='DWord'; Value='1'}
    @{Hive='SOFTWARE';Path='Policies\Microsoft\MRT'; Name='DontOfferThroughWUAU'; Type='DWord'; Value='1'}
    @{Hive='SOFTWARE';Path='Microsoft\Windows\CurrentVersion\OOBE'; Name='BypassNRO';     Type='DWord'; Value='1'}
    @{Hive='SOFTWARE';Path='Microsoft\Windows\CurrentVersion\OOBE'; Name='DisableOnline'; Type='DWord'; Value='1'}
    @{Hive='SOFTWARE';Path='Microsoft\Windows\CurrentVersion\ReserveManager'; Name='ShippedWithReserves'; Type='DWord'; Value='0'}
    @{Hive='SYSTEM';  Path='ControlSet001\Control\BitLocker'; Name='PreventDeviceEncryption'; Type='DWord'; Value='1'}
    @{Hive='SOFTWARE';Path='Policies\Microsoft\Windows\Windows Chat'; Name='ChatIcon'; Type='DWord'; Value='3'}
    @{Hive='NTUSER';  Path='SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='TaskbarMn'; Type='DWord'; Value='0'}
    @{Hive='SOFTWARE';Path='Policies\Microsoft\Windows\OneDrive'; Name='DisableFileSyncNGSC'; Type='DWord'; Value='1'}
    @{Hive='NTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name='Enabled'; Type='DWord'; Value='0'}
    @{Hive='NTUSER';  Path='Software\Microsoft\Windows\CurrentVersion\Privacy'; Name='TailoredExperiencesWithDiagnosticDataEnabled'; Type='DWord'; Value='0'}
    @{Hive='NTUSER';  Path='Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy'; Name='HasAccepted'; Type='DWord'; Value='0'}
    @{Hive='NTUSER';  Path='Software\Microsoft\Input\TIPC'; Name='Enabled'; Type='DWord'; Value='0'}
    @{Hive='NTUSER';  Path='Software\Microsoft\InputPersonalization'; Name='RestrictImplicitInkCollection';  Type='DWord'; Value='1'}
    @{Hive='NTUSER';  Path='Software\Microsoft\InputPersonalization'; Name='RestrictImplicitTextCollection'; Type='DWord'; Value='1'}
    @{Hive='NTUSER';  Path='Software\Microsoft\InputPersonalization\TrainedDataStore'; Name='HarvestContacts'; Type='DWord'; Value='0'}
    @{Hive='NTUSER';  Path='Software\Microsoft\Personalization\Settings'; Name='AcceptedPrivacyPolicy'; Type='DWord'; Value='0'}
    @{Hive='SOFTWARE';Path='Policies\Microsoft\Windows\DataCollection'; Name='AllowTelemetry'; Type='DWord'; Value='0'}
    @{Hive='SYSTEM';  Path='ControlSet001\Services\dmwappushservice'; Name='Start'; Type='DWord'; Value='4'}
    @{Hive='SOFTWARE';Path='Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate'; Name='workCompleted'; Type='DWord'; Value='1'}
    @{Hive='SOFTWARE';Path='Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate'; Name='workCompleted'; Type='DWord'; Value='1'}
    @{Hive='SOFTWARE';Path='Policies\Microsoft\Windows\WindowsCopilot'; Name='TurnOffWindowsCopilot'; Type='DWord'; Value='1'}
    @{Hive='SOFTWARE';Path='Policies\Microsoft\Edge'; Name='HubsSidebarEnabled'; Type='DWord'; Value='0'}
    @{Hive='SOFTWARE';Path='Policies\Microsoft\Windows\Explorer'; Name='DisableSearchBoxSuggestions'; Type='DWord'; Value='1'}
    @{Hive='SOFTWARE';Path='Policies\Microsoft\Teams'; Name='DisableInstallation'; Type='DWord'; Value='1'}
    @{Hive='SOFTWARE';Path='Policies\Microsoft\Windows\Windows Mail'; Name='PreventRun'; Type='DWord'; Value='1'}
    @{Hive='SOFTWARE';Path='Policies\Microsoft\Windows\WindowsUpdate'; Name='DoNotConnectToWindowsUpdateInternetLocations'; Type='DWord'; Value='1'}
    @{Hive='SOFTWARE';Path='Policies\Microsoft\Windows\WindowsUpdate'; Name='DisableWindowsUpdateAccess'; Type='DWord'; Value='1'}
    @{Hive='SOFTWARE';Path='Policies\Microsoft\Windows\WindowsUpdate'; Name='WUServer'; Type='String'; Value='localhost'}
    @{Hive='SOFTWARE';Path='Policies\Microsoft\Windows\WindowsUpdate'; Name='WUStatusServer'; Type='String'; Value='localhost'}
    @{Hive='SOFTWARE';Path='Policies\Microsoft\Windows\WindowsUpdate\AU'; Name='UseWUServer'; Type='DWord'; Value='1'}
    @{Hive='SOFTWARE';Path='Policies\Microsoft\Windows\WindowsUpdate\AU'; Name='NoAutoUpdate'; Type='DWord'; Value='1'}
    @{Hive='SYSTEM';  Path='ControlSet001\Services\wuauserv'; Name='Start'; Type='DWord'; Value='4'}
    @{Hive='SOFTWARE';Path='Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name='SettingsPageVisibility'; Type='String'; Value='hide:virus;windowsupdate'}
)

function Remove-TrackingTasks {
    Write-Step "Removing telemetry scheduled tasks"
    $tasksRoot = Join-Path $script:MountDir 'Windows\System32\Tasks'
    $tasks = @(
        'Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
        'Microsoft\Windows\Customer Experience Improvement Program',
        'Microsoft\Windows\Application Experience\ProgramDataUpdater',
        'Microsoft\Windows\Chkdsk\Proxy',
        'Microsoft\Windows\Windows Error Reporting\QueueReporting'
    )
    foreach ($t in $tasks) {
        Remove-Item (Join-Path $tasksRoot $t) -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# =============================================================
# oscdimg locator
# =============================================================
function Get-Oscdimg {
    $candidates = @()

    $adkRoot = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools'
    if (Test-Path $adkRoot) {
        $found = Get-ChildItem $adkRoot -Recurse -Filter oscdimg.exe -ErrorAction SilentlyContinue |
                 Select-Object -First 1 -ExpandProperty FullName
        if ($found) { $candidates += $found }
    }

    if ($env:OSCDIMG) { $candidates += $env:OSCDIMG }

    $scriptDir = Join-Path $PSScriptRoot 'oscdimg.exe'
    if (Test-Path $scriptDir) { $candidates += $scriptDir }

    $fromPath = Get-Command oscdimg.exe -ErrorAction SilentlyContinue
    if ($fromPath) { $candidates += $fromPath.Source }

    foreach ($c in $candidates) {
        if (Test-Path $c) {
            Write-Info "oscdimg found: $c"
            return $c
        }
    }

    Write-Warn "oscdimg.exe not found locally. Attempting download from Microsoft symbols server..."
    $downloadPath = Join-Path $PSScriptRoot 'oscdimg.exe'
    $url = 'https://msdl.microsoft.com/download/symbols/oscdimg.exe/3D44737265000/oscdimg.exe'
    try {
        Invoke-WebRequest -Uri $url -OutFile $downloadPath -UseBasicParsing
        if (Test-Path $downloadPath) {
            Write-Info "Downloaded oscdimg to $downloadPath"
            return $downloadPath
        }
    } catch {
        Write-Warn "Download failed: $($_.Exception.Message)"
    }

    throw @"
Could not locate oscdimg.exe.
Please do one of the following:
  1. Install Windows ADK (Deployment Tools) and rerun this script.
  2. Manually place oscdimg.exe next to this script.
  3. Set the OSCDIMG environment variable to its full path.
"@
}

# =============================================================
# ISO creation
# =============================================================
function New-TinyISO {
    param([string]$SourceDir, [string]$OutputPath, [string]$Arch)

    Write-Step "Creating ISO"
    $oscdimg = Get-Oscdimg

    $efiBoot  = Join-Path $SourceDir 'efi\microsoft\boot\efisys.bin'
    $biosBoot = Join-Path $SourceDir 'boot\etfsboot.com'

    if (-not (Test-Path $efiBoot)) {
        throw "ARM64 EFI boot file not found: $efiBoot"
    }

    $bootData = if ($Arch -eq 'arm64') {
        "2#pEF,e,b$efiBoot"
    } else {
        "2#p0,e,b$biosBoot#pEF,e,b$efiBoot"
    }

    Write-Info "Building ISO..."
    & $oscdimg -m -o -u2 -udfver102 "-bootdata:$bootData" `
               "-lTINY11" $SourceDir $OutputPath | Out-Null

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $OutputPath)) {
        throw "ISO creation failed (oscdimg exit code $LASTEXITCODE)."
    }
    Write-Host "ISO created: $OutputPath" -ForegroundColor Green
}

# =============================================================
# Version selector (FIX: Out-Host keeps Format-Table output off the return value)
# =============================================================
function Select-ImageIndex {
    param([array]$Images)

    if ($Images.Count -eq 1) {
        Write-Info "Only one image found. Using index $($Images[0].Index)."
        return [int]$Images[0].Index
    }

    if ($AssumeYes) {
        $proImage = $Images | Where-Object { $_.Name -match 'Pro' } | Select-Object -First 1
        if ($proImage) {
            Write-Info "Auto-selecting Pro image: index $($proImage.Index) : $($proImage.Name)"
            return [int]$proImage.Index
        }
        $last = $Images[-1]
        Write-Info "Auto-selecting last image: index $($last.Index) : $($last.Name)"
        return [int]$last.Index
    }

    $Images | Format-Table Index, Name -AutoSize | Out-Host
    $selected = Read-Host "Select the index to slim (recommended: Windows 11 Pro)"
    return [int]$selected
}

# =============================================================
# Main
# =============================================================
try {
    Write-Host "`nTiny11 ARM64 Core Builder v$script:Version" -ForegroundColor Green
    Write-Host "Host architecture: $script:HostArch" -ForegroundColor Gray

    Test-Prerequisites

    $source = $ISODrive.TrimEnd(':') + ':'

    Write-Step "Pre-flight cleanup" 'Yellow'
    if (Test-Path $script:MountDir) {
        & dism.exe /English /Unmount-Image /MountDir:$script:MountDir /Discard 2>&1 | Out-Null
        Remove-Item $script:MountDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Clear-Mountpoints
    Reset-WimServ
    Dismount-RegistryHives -HiveMap $script:HiveMap

    if ($SkipCopy -and ((Test-Path (Join-Path $script:WorkRoot 'sources\install.esd')) -or (Test-Path (Join-Path $script:WorkRoot 'sources\install.wim')))) {
        Write-Step "Reusing existing working directory (SkipCopy)"
    } else {
        Write-Step "Copying source files to $script:WorkRoot"
        New-CleanDir $script:WorkRoot
        Copy-Item "$source\*" $script:WorkRoot -Recurse -Force
    }

    Write-Step "Clearing read-only attributes on source files"
    Clear-ReadOnlyAttributes -RootPath $script:WorkRoot

    $installWim = Join-Path $script:WorkRoot 'sources\install.wim'
    $installEsd = Join-Path $script:WorkRoot 'sources\install.esd'

    if (-not (Test-Path $installWim) -and (Test-Path $installEsd)) {
        Write-Step "ESD -> WIM conversion (all indexes)"
        $esdList = Get-WimImages -WimPath $installEsd
        if (-not $esdList) { throw "Could not read ESD image info." }

        $first = $true
        $total = $esdList.Count
        $count = 0
        foreach ($img in $esdList) {
            $count++
            $pct = [int](($count / $total) * 100)
            Write-Progress -Activity "ESD -> WIM conversion" -Status "Index $($img.Index) : $($img.Name)" -PercentComplete $pct
            Write-Info "Exporting index $($img.Index) : $($img.Name)..."

            $args = @('/Export-Image', "/SourceImageFile:$installEsd", "/SourceIndex:$($img.Index)", "/DestinationImageFile:$installWim", '/Compress:max', '/CheckIntegrity')
            if (-not $first) { $args += '/Append' }
            Invoke-Dism -Arguments $args
            $first = $false
        }
        Write-Progress -Activity "ESD -> WIM conversion" -Completed
        Remove-Item $installEsd -Force
    }

    $images = Get-WimImages -WimPath $installWim
    [int]$index = Select-ImageIndex -Images $images

    Write-Step "Mounting install.wim (index $index)"
    New-CleanDir $script:MountDir
    Mount-WimSafely -WimPath $installWim -Index $index -MountDir $script:MountDir

    $script:Arch = Get-WimArch -WimPath $installWim -Index $index
    Write-Host "Architecture: $($script:Arch)"

    Test-CrossArchitecture -TargetArch $script:Arch

    $intl = Invoke-Dism -Arguments @("/Image:$script:MountDir", '/Get-Intl') -PassThru
    $intlText = $intl -join "`n"
    $langMatch = [regex]::Match($intlText, 'Default system UI language\s*:\s*([a-zA-Z]{2}-[a-zA-Z]{2})')
    if ($langMatch.Success) {
        $script:LangCode = $langMatch.Groups[1].Value
    }
    Write-Host "Language: $($script:LangCode)"

    Remove-AppxFromImage
    Remove-SystemPackages
    Remove-BundledApps

    if ($EnableNetFx3) {
        Write-Step "Enabling .NET 3.5"
        Invoke-Dism -Arguments @("/Image:$script:MountDir", '/Enable-Feature', '/FeatureName:NetFx3', '/All', "/Source:$(Join-Path $script:WorkRoot 'sources\sxs')") -IgnoreError
    }

    Compress-WinSxS

    Write-Step "Applying offline registry tweaks"
    Mount-RegistryHives -MountDir $script:MountDir -HiveMap $script:HiveMap
    try {
        Set-OfflineRegistryTweaks -HiveMap $script:HiveMap -Tweaks $script:RegTweaks
    } finally {
        Dismount-RegistryHives -HiveMap $script:HiveMap
    }

    Remove-TrackingTasks

    Write-Step "Cleaning component store"
    Invoke-Dism -Arguments @("/Image:$script:MountDir", '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase') -IgnoreError

    Write-Host "`n    Waiting 15s for background services to release file locks..."
    Start-Sleep -Seconds 15
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()

    Write-Step "Unmounting install.wim"
    Dismount-WimSafely -MountDir $script:MountDir

    Write-Step "Re-exporting install.wim"
    $tmpWim = "$installWim.new"
    Export-WimSafely -SourceWim $installWim -Index $index -DestinationWim $tmpWim -Compress 'max'
    Remove-Item $installWim -Force
    Rename-Item $tmpWim -NewName 'install.wim'

    Write-Step "Patching boot.wim"
    New-CleanDir $script:MountDir
    $bootWim = Join-Path $script:WorkRoot 'sources\boot.wim'
    $bootImages = Get-WimImages -WimPath $bootWim
    $bootIndex = ($bootImages | Where-Object { $_.Name -match 'Setup' } | Select-Object -First 1).Index
    if (-not $bootIndex) { $bootIndex = $bootImages[-1].Index }
    Write-Host "Using boot.wim index: $bootIndex"

    Mount-WimSafely -WimPath $bootWim -Index $bootIndex -MountDir $script:MountDir

    Mount-RegistryHives -MountDir $script:MountDir -HiveMap $script:HiveMap
    try {
        $setupTweaks = $script:RegTweaks | Where-Object { $_.Path -like 'Setup\*' }
        Set-OfflineRegistryTweaks -HiveMap $script:HiveMap -Tweaks $setupTweaks

        $fullSetup = "HKLM:\zSYSTEM\Setup"
        if (-not (Test-Path $fullSetup)) { New-Item -Path $fullSetup -Force | Out-Null }
        New-ItemProperty -Path $fullSetup -Name "CmdLine" -Value "X:\sources\setup.exe" -PropertyType String -Force | Out-Null
    } finally {
        Dismount-RegistryHives -HiveMap $script:HiveMap
    }
    Dismount-WimSafely -MountDir $script:MountDir

    Write-Step "install.wim -> install.esd"
    $esdOut = Join-Path $script:WorkRoot 'sources\install.esd'
    Export-WimSafely -SourceWim $installWim -Index $index -DestinationWim $esdOut -Compress 'recovery'
    Remove-Item $installWim -Force

    New-TinyISO -SourceDir $script:WorkRoot -OutputPath $OutputISO -Arch $script:Arch

    $script:Success = $true

    $elapsed = (Get-Date) - $script:StartTime
    $isoSize = if (Test-Path $OutputISO) { [Math]::Round((Get-Item $OutputISO).Length / 1GB, 2) } else { 0 }
    Write-Host "`n=======================================================" -ForegroundColor Green
    Write-Host " Build completed successfully" -ForegroundColor Green
    Write-Host "=======================================================" -ForegroundColor Green
    Write-Host "  Output ISO : $OutputISO"
    Write-Host "  ISO size   : $isoSize GB"
    Write-Host "  Arch       : $script:Arch"
    Write-Host "  Language   : $script:LangCode"
    Write-Host "  Duration   : $($elapsed.ToString('hh\:mm\:ss'))"
    Write-Host "  Log        : $script:LogPath"
    Write-Host "=======================================================`n" -ForegroundColor Green
}
catch {
    Write-Host "`nFailed: $_" -ForegroundColor Red
    if ($_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    }
    Write-Host "`nTroubleshooting hints:" -ForegroundColor Yellow
    Write-Host "  1. Run 'dism /Cleanup-Mountpoints' and retry." -ForegroundColor Yellow
    Write-Host "  2. If the error is 0xC1510111 or 0xc1420127, restart your PC." -ForegroundColor Yellow
    Write-Host "  3. If mounting keeps failing on x64 host with ARM64 image, use an ARM64 host." -ForegroundColor Yellow
    Write-Host "  4. Check the DISM log at C:\Windows\Logs\DISM\dism.log" -ForegroundColor Yellow
    exit 1
}
finally {
    Dismount-RegistryHives -HiveMap $script:HiveMap

    if (Test-Path $script:MountDir) {
        & dism.exe /English /Unmount-Image /MountDir:$script:MountDir /Discard 2>&1 | Out-Null
    }

    if ($script:Success) {
        Remove-Item $script:WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $script:MountDir -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "`nWork directories preserved for debugging:" -ForegroundColor Yellow
        Write-Host "  $script:WorkRoot" -ForegroundColor Yellow
        Write-Host "  $script:MountDir" -ForegroundColor Yellow
        Write-Host "  Run 'dism /Cleanup-Mountpoints' before retrying.`n" -ForegroundColor Yellow
    }

    if (-not $KeepLog) { Stop-Transcript | Out-Null }
}
