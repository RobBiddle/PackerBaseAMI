<#
.SYNOPSIS
    Registers the XAML SystemApps packages that a Local System sysprep leaves unregistered
    on Windows Server 2025 / Windows 11 24H2+, in the context of the CURRENT user.
.DESCRIPTION
    Implements Microsoft's remediation for "explorer.exe / Start menu / Settings / Office
    sign-in crash after sysprep as System":
    https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/sysprep-as-system-windows-11

    Runs in the affected user's own session (Add-AppxPackage -Register is per-user). It is
    idempotent and version-aware: a package is (re-)registered only when it is missing, its
    registered version is older than the on-disk SystemApps manifest, or its Status is not Ok.
    If anything was registered it restarts SiHost and Explorer for the session so the shell
    picks up the change (per Microsoft's "restart SiHost" note).

    Safe to run anywhere: it exits 0 without doing anything on Server 2022, Server Core, and
    builds older than 26100, or when the manifests are absent.

    PackerBaseAMI uses this file in two ways:
      1. Baked into a built AMI (opt-in) as a per-user logon task, so every new user is
         repaired on first sign-in and again after a cumulative update changes the packages.
      2. Copied to an already-affected instance and run once per user session to repair it.
.NOTES
    Author: Robert D. Biddle
    https://github.com/RobBiddle/PackerBaseAMI
    PackerBaseAMI  Copyright (C) 2017  Robert D. Biddle
    GNU General Public License v3.0
#>
[CmdletBinding()]
param(
    # Also (re-)register the Web Account Manager broker used by Office / Entra sign-in.
    # The Office sign-in crash is a hypothesis (see README); this is off unless requested.
    [switch]$IncludeBrokerPlugin,

    # Restart SiHost/Explorer if anything was registered. On by default; the logon-task
    # wrapper leaves it on, remediation callers may turn it off to avoid disrupting a session.
    [bool]$RestartShell = $true
)

$ErrorActionPreference = 'Continue'
$logDir = Join-Path $env:LOCALAPPDATA 'PackerBaseAMI'
$null = New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue
$log = Join-Path $logDir 'Register-XamlPackages.log'
function Write-Log([string]$Message) {
    try { Add-Content -Path $log -Value ('{0:o} [{1}] {2}' -f (Get-Date), $env:USERNAME, $Message) } catch {}
}

try {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    $build = 0; [int]::TryParse([string]$cv.CurrentBuildNumber, [ref]$build) | Out-Null
    if ($build -lt 26100 -or $cv.InstallationType -ne 'Server') {
        Write-Log "Skip: build=$build InstallationType=$($cv.InstallationType) (mitigation only applies to Server 2025 Desktop Experience)."
        exit 0
    }

    # The three XAML SystemApps packages Microsoft names, plus the optional WAM broker.
    $targets = @(
        'MicrosoftWindows.Client.CBS'
        'Microsoft.UI.Xaml.CBS'
        'MicrosoftWindows.Client.Core'
    )
    if ($IncludeBrokerPlugin) { $targets += 'Microsoft.AAD.BrokerPlugin' }

    $registeredAny = $false
    foreach ($name in $targets) {
        # Locate the on-disk manifest under %SystemRoot%\SystemApps\<name>_<publisherhash>\appxmanifest.xml
        $dir = Get-ChildItem (Join-Path $env:SystemRoot 'SystemApps') -Directory -Filter "$($name)_*" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $dir) { Write-Log "Skip ${name}: no SystemApps folder present."; continue }
        $manifest = Join-Path $dir.FullName 'appxmanifest.xml'
        if (-not (Test-Path -LiteralPath $manifest)) { Write-Log "Skip ${name}: no appxmanifest.xml in $($dir.FullName)."; continue }

        # Desired version from the manifest; current registration for THIS user.
        $wantVersion = $null
        try { $wantVersion = ([xml](Get-Content -LiteralPath $manifest -Raw)).Package.Identity.Version } catch {}
        $have = Get-AppxPackage -Name $name -ErrorAction SilentlyContinue

        $needs = $false; $why = ''
        if (-not $have) { $needs = $true; $why = 'not registered' }
        elseif ($have.Status -and $have.Status -ne 'Ok') { $needs = $true; $why = "status=$($have.Status)" }
        elseif ($wantVersion -and $have.Version -and ([version]$have.Version -lt [version]$wantVersion)) { $needs = $true; $why = "version $($have.Version) < manifest $wantVersion" }

        Write-Log ("PRE {0}: have={1}/{2} want={3} -> {4}" -f $name, $have.Version, $have.Status, $wantVersion, ($(if ($needs) { "register ($why)" } else { 'ok, skip' })))
        if (-not $needs) { continue }

        try {
            Add-AppxPackage -Register -Path $manifest -DisableDevelopmentMode -ErrorAction Stop
            $registeredAny = $true
            $after = Get-AppxPackage -Name $name -ErrorAction SilentlyContinue
            Write-Log ("Registered {0}: now {1}/{2}" -f $name, $after.Version, $after.Status)
        } catch {
            Write-Log "Register $name FAILED: $($_.Exception.Message)"
        }
    }

    if ($registeredAny -and $RestartShell) {
        # Restart the shell for this session so it re-reads the freshly registered packages.
        foreach ($proc in 'sihost', 'ShellExperienceHost', 'StartMenuExperienceHost', 'explorer') {
            Get-Process -Name $proc -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq (Get-Process -Id $PID).SessionId } | ForEach-Object {
                try { Stop-Process -Id $_.Id -Force -ErrorAction Stop; Write-Log "Restarted $proc (pid $($_.Id))" } catch { Write-Log "Could not stop ${proc}: $($_.Exception.Message)" }
            }
        }
    } else {
        Write-Log 'Nothing registered; no shell restart needed.'
    }
} catch {
    Write-Log "ERROR $($_.Exception.Message)"
}
exit 0
