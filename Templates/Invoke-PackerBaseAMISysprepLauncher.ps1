<#
.SYNOPSIS
    PackerBaseAMI interactive sysprep launcher. Runs as the auto-logged-on built-in
    Administrator in a real console session (started by a RunOnce entry after autologon),
    NOT as Local System. Runs ec2launch.exe sysprep, verifies the image actually
    generalized, and shuts the instance down.
.DESCRIPTION
    Microsoft: running sysprep as Local System skips AppX registration for certain XAML
    packages on Server 2025, breaking Explorer / Start / Settings:
    https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/sysprep-as-system-windows-11
    The only execution context with a positive Server 2025 report is an interactive logon.

    This script is written to disk and launched by the SYSTEM orchestrator
    (Invoke-PackerBaseAMISysprep.ps1). It communicates back to the orchestrator, and to the
    operator, through a shared identity/marker log so the orchestrator can report
    Success/Failed to the SSM Run Command and terminate the build instance on failure
    (fail-closed: a bad or SYSTEM-context sysprep never becomes an AMI).

    Handshake: the launcher does not start sysprep until the orchestrator's pass 2 has scrubbed
    the autologon secrets, restored the logon banner, rotated the Administrator password, and
    set Phase=Launched. If pass 2 never gets there, the launcher fails instead of sealing an
    image that still carries that build-time state.

    Exit codes (informational; the orchestrator keys on the MARKER lines):
      0  generalized and shutdown scheduled      10 unhandled exception
      11 identity check failed                    12 readiness timed out
      13 sysprep.exe owner was SYSTEM or not us   14 sysprep never started
      15 sysprep did not generalize / timed out   16 orchestrator handshake timed out
.NOTES
    Author: Robert D. Biddle - https://github.com/RobBiddle/PackerBaseAMI - GPL v3.0
#>
$ErrorActionPreference = 'Stop'
$IdentityLog  = 'C:\ProgramData\Amazon\EC2Launch\log\PackerBaseAMI-SysprepIdentity.log'
$EC2LaunchExe = 'C:\Program Files\Amazon\EC2Launch\EC2Launch.exe'
$ReadyState   = 'IMAGE_STATE_COMPLETE'
$SealedState  = 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'
$SetupStateKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State'
$StateKey     = 'HKLM:\SOFTWARE\PackerBaseAMI\SysprepOrchestrator'
$ec2 = $null

function Log([string]$m) {
    # Never throw from logging: the SYSTEM side reads this file concurrently.
    for ($i = 0; $i -lt 5; $i++) {
        try { Add-Content -Path $IdentityLog -Value ('{0:o} [LAUNCHER pid={1}] {2}' -f (Get-Date), $PID, $m) -ErrorAction Stop; return }
        catch { Start-Sleep -Milliseconds 150 }
    }
}
function Marker([string]$m) { Log "MARKER $m" }
function Get-ImageState { (Get-ItemProperty $SetupStateKey -ErrorAction SilentlyContinue).ImageState }
function Stop-SysprepChain {
    Get-CimInstance Win32_Process -Filter "Name='sysprep.exe'" -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    if ($ec2 -and -not $ec2.HasExited) { Stop-Process -Id $ec2.Id -Force -ErrorAction SilentlyContinue }
}

try {
    Marker 'LAUNCHER_STARTED'

    # ---- Prove the execution context: interactive, elevated, RID-500, not SYSTEM ----
    $me   = [Security.Principal.WindowsIdentity]::GetCurrent()
    $sids = @($me.Groups | ForEach-Object { $_.Value })
    $sess = (Get-Process -Id $PID).SessionId
    Log "User=$($me.Name) SID=$($me.User.Value) SessionId=$sess"
    (& whoami.exe /all 2>&1) | ForEach-Object { Log "whoami: $_" }

    $isSystem  = $me.User.Value -eq 'S-1-5-18'
    $isRid500  = $me.User.Value -match '^S-1-5-21-\d+-\d+-\d+-500$'
    $isHigh    = [bool]((& whoami.exe /groups 2>&1) -match 'S-1-16-12288')       # High Mandatory Level
    $isInter   = $sids -contains 'S-1-5-4'                                        # INTERACTIVE
    Log "Checks: isSystem=$isSystem rid500=$isRid500 highIntegrity=$isHigh interactive=$isInter session=$sess"
    if ($isSystem -or -not $isRid500 -or -not $isHigh -or -not $isInter -or $sess -eq 0) {
        Marker 'IDENTITY_FAIL'; exit 11
    }
    Marker 'IDENTITY_OK'

    # ---- Re-check readiness (a reboot + first logon happened since the orchestrator's pass-1 check) ----
    $deadline = (Get-Date).AddMinutes(20)
    while ($true) {
        $reasons = @()
        $imageState = Get-ImageState
        if ($imageState -ne $ReadyState) { $reasons += "ImageState=$imageState" }
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'CBS RebootPending' }
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'WU RebootRequired' }
        if (Get-Process -Name TiWorker, TrustedInstaller -ErrorAction SilentlyContinue) { $reasons += 'servicing active' }
        if (-not $reasons) { Log "Ready for sysprep (ImageState=$imageState)."; break }
        if ((Get-Date) -gt $deadline) { Log "Readiness timed out: $($reasons -join '; ')"; Marker 'READINESS_TIMEOUT'; exit 12 }
        Log "Waiting for readiness: $($reasons -join '; ')"; Start-Sleep -Seconds 20
    }

    # ---- Avoid the well-known 0x80073CF2 sysprep failure: remove packages registered for THIS
    #      user that are not provisioned for all users. Compare by package Name against the
    #      provisioned DisplayName: provisioned entries are bundle identities (..._neutral_~_...)
    #      that never equal a per-user PackageFullName, so a full-name comparison would also
    #      remove provisioned inbox apps. ----
    try {
        $provisionedNames = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | ForEach-Object { $_.DisplayName })
        if (-not $provisionedNames) {
            Log 'Get-AppxProvisionedPackage returned nothing; skipping per-user package cleanup.'
        } else {
            Get-AppxPackage -ErrorAction SilentlyContinue |
                Where-Object { -not $_.IsFramework -and -not $_.NonRemovable -and $_.SignatureKind -ne 'System' -and $provisionedNames -notcontains $_.Name } |
                ForEach-Object {
                    Log "Removing per-user non-provisioned package: $($_.PackageFullName)"
                    try { Remove-AppxPackage -Package $_.PackageFullName -ErrorAction Stop } catch { Log "Remove failed: $($_.Exception.Message)" }
                }
        }
    } catch { Log "Per-user package cleanup skipped: $($_.Exception.Message)" }

    # ---- Handshake: wait for the orchestrator (pass 2) to finish scrubbing autologon state, so
    #      sysprep can never seal an image that still has it. ----
    #      The orchestrator itself allows the SSM agent 15 minutes to resume pass 2 after the reboot.
    $deadline = (Get-Date).AddMinutes(25)
    while (((Get-ItemProperty -Path $StateKey -ErrorAction SilentlyContinue).Phase) -ne 'Launched') {
        if ((Get-Date) -gt $deadline) { Log 'The orchestrator did not confirm the autologon scrub (Phase=Launched) within 25 minutes; not running sysprep.'; Marker 'ORCHESTRATOR_TIMEOUT'; exit 16 }
        Start-Sleep -Seconds 5
    }
    Log 'Orchestrator confirmed autologon secrets scrubbed, banner restored and password rotated (Phase=Launched).'

    # ---- Run ec2launch sysprep WITHOUT shutdown so we can verify generalize first. ----
    if (-not (Test-Path $EC2LaunchExe)) { Log "EC2Launch.exe not found at $EC2LaunchExe"; Marker 'SYSPREP_NOT_STARTED'; exit 14 }
    Marker 'LAUNCHING_SYSPREP'
    $ec2 = Start-Process -FilePath $EC2LaunchExe -ArgumentList 'sysprep', '--shutdown=false' -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput 'C:\ProgramData\Amazon\EC2Launch\log\PackerBaseAMI-ec2launch-sysprep.out.log' `
        -RedirectStandardError  'C:\ProgramData\Amazon\EC2Launch\log\PackerBaseAMI-ec2launch-sysprep.err.log'
    $null = $ec2.Handle   # cache the handle so ExitCode is available after exit (Windows PowerShell 5.1)
    Log "ec2launch.exe sysprep started (pid=$($ec2.Id))."

    # ---- Confirm sysprep.exe runs as US (RID-500 in our session), NOT Local System.
    #      If ec2launch hands the actual sysprep to the SYSTEM service, we catch it here and
    #      fail the build rather than ship an AMI that hit the XAML skip. ----
    $seen = $false; $watch = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $watch -and -not $seen) {
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='sysprep.exe'" -ErrorAction SilentlyContinue)) {
            $owner = (Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction SilentlyContinue).Sid
            if (-not $owner) { continue }   # exited between enumeration and the owner query: no evidence either way
            Log "sysprep.exe pid=$($p.ProcessId) OwnerSid=$owner Session=$($p.SessionId) ParentPid=$($p.ParentProcessId)"
            if ($owner -eq 'S-1-5-18') { Marker 'SYSPREP_OWNER_SYSTEM'; Stop-SysprepChain; exit 13 }
            if ($owner -ne $me.User.Value -or $p.SessionId -ne $sess) { Marker 'SYSPREP_OWNER_MISMATCH'; Stop-SysprepChain; exit 13 }
            $seen = $true
        }
        if (-not $seen) {
            if ($ec2.HasExited) { Log "ec2launch exited ($($ec2.ExitCode)) before sysprep.exe appeared."; Marker 'SYSPREP_NOT_STARTED'; exit 14 }
            Start-Sleep -Milliseconds 500
        }
    }
    if (-not $seen) { Marker 'SYSPREP_NOT_STARTED'; Stop-SysprepChain; exit 14 }
    Marker 'SYSPREP_OWNER_OK'

    # ---- Wait (bounded) for sysprep/ec2launch to finish, then verify the image really generalized. ----
    if (-not $ec2.WaitForExit(45 * 60 * 1000)) {
        Log 'ec2launch.exe sysprep did not exit within 45 minutes.'; Stop-SysprepChain; Marker 'SYSPREP_FAILED_TIMEOUT'; exit 15
    }
    Log "ec2launch.exe exited with $($ec2.ExitCode)."
    $waitState = (Get-Date).AddMinutes(20)
    while ((Get-Date) -lt $waitState -and (Get-Process -Name sysprep -ErrorAction SilentlyContinue)) { Start-Sleep -Seconds 5 }
    if (Test-Path 'C:\Windows\System32\Sysprep\Panther\setuperr.log') {
        Get-Content 'C:\Windows\System32\Sysprep\Panther\setuperr.log' -Tail 40 -ErrorAction SilentlyContinue | ForEach-Object { Log "setuperr: $_" }
    }
    $finalState = Get-ImageState
    Log "ImageState after sysprep: $finalState (expected $SealedState)."
    if ($finalState -ne $SealedState) { Marker "SYSPREP_FAILED_$finalState"; exit 15 }
    Marker 'SYSPREP_GENERALIZED'

    # ---- Success. Shut down with a delay so the orchestrator (SYSTEM) and the module can
    #      observe SYSPREP_GENERALIZED and let the Run Command finish Success before power-off. ----
    Log 'Generalize verified. Scheduling shutdown in 120s so the Run Command can report Success.'
    & shutdown.exe /s /t 120 /d p:2:4 /c 'PackerBaseAMI: sysprep generalized (interactive Administrator).'
    exit 0
}
catch {
    Log "EXCEPTION $($_.Exception.Message)"
    try { Stop-SysprepChain } catch {}
    Marker 'LAUNCHER_EXCEPTION'
    exit 10
}
