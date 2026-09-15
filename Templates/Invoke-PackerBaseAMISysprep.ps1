<#
.SYNOPSIS
    PackerBaseAMI sysprep orchestrator for Windows Server 2022/2025. Runs as NT AUTHORITY\SYSTEM
    (SSM AWS-RunPowerShellScript) and arranges for Sysprep to run under the built-in
    Administrator instead of SYSTEM, because Microsoft does not support sysprep as Local System
    and it breaks XAML apps on Server 2025:
    https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/sysprep-as-system-windows-11
.DESCRIPTION
    Two execution contexts (chosen by the module, overridable with -SysprepExecutionContext):

      InteractiveAutoLogon (default for Full / Desktop Experience images of Server 2022 and 2025)
        Pass 1: patch EC2Launch config, set CopyProfile=false, arm a one-shot AutoAdminLogon as
                the built-in Administrator, register a RunOnce that starts the interactive
                launcher, then `exit 3010` so SSM reboots and re-runs this script.
        Pass 2: wait for the launcher to prove it is running interactively (LAUNCHER_STARTED),
                scrub every autologon secret, restore the logon banner, rotate the password,
                and only then set Phase=Launched, which the launcher waits for before it starts
                sysprep. Then watch the launcher's markers and report Success only after the
                image is confirmed generalized. The interactive launcher runs sysprep in a real
                console session (positive Server 2025 evidence).

      BatchLogon (default for Core images, and the fallback when autologon cannot work)
        Single pass: LogonUser(BATCH) + CreateProcessAsUser as the built-in Administrator to run
        `ec2launch sysprep --shutdown=false` (AWS's own AWSEC2-RunSysprep pattern), verify that
        sysprep.exe ran as the built-in Administrator and the image generalized, then shut down.
        No reboot. Evidence is written to the same identity log as the interactive path.

    Fail-closed: on any failure the script exits non-zero without shutting down; the module then
    terminates the build instance so Packer creates no AMI. Success is reported before shutdown.

    The module replaces the placeholder tokens in the variable assignments below (the sysprep
    context, the build id, the install-XAML flag, and the base64-encoded launcher and stub
    scripts) before sending this script to the instance.
.NOTES
    Author: Robert D. Biddle - https://github.com/RobBiddle/PackerBaseAMI - GPL v3.0
#>
$ErrorActionPreference = 'Stop'

$SysprepContext = '__SYSPREP_CONTEXT__'     # InteractiveAutoLogon | BatchLogon
$BuildId        = '__BUILD_ID__'
$InstallXaml    = '__INSTALL_XAML__' -eq 'True'
$LauncherB64    = '__LAUNCHER_B64__'
$XamlStubB64    = '__XAML_STUB_B64__'

$LogDir        = 'C:\ProgramData\Amazon\EC2Launch\log'
$WorkDir       = 'C:\ProgramData\PackerBaseAMI'
$StateKey      = 'HKLM:\SOFTWARE\PackerBaseAMI\SysprepOrchestrator'
$WinlogonKey   = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$RunOnceKey    = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
$BannerKeys    = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System', 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon')
$VolatileArmed = 'SOFTWARE\PackerBaseAMI\ArmedThisBoot'   # created volatile: absent after a reboot
$LauncherPath  = Join-Path $WorkDir 'Invoke-PackerBaseAMISysprepLauncher.ps1'
$XamlStubPath  = Join-Path $WorkDir 'Register-XamlPackages.ps1'
$IdentityLog   = Join-Path $LogDir 'PackerBaseAMI-SysprepIdentity.log'
$EC2LaunchExe  = 'C:\Program Files\Amazon\EC2Launch\EC2Launch.exe'
$UnattendPath  = 'C:\ProgramData\Amazon\EC2Launch\sysprep\unattend.xml'
$ReadyState    = 'IMAGE_STATE_COMPLETE'
$SealedState   = 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'
$SetupStateKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State'

$null = New-Item -ItemType Directory -Path $LogDir, $WorkDir -Force -ErrorAction SilentlyContinue
Start-Transcript -Path (Join-Path $LogDir 'PackerBaseAMI-SSM.log') -Append -Force | Out-Null

function Write-Step([string]$m) { Write-Output ('{0:o} [SYSTEM] {1}' -f (Get-Date), $m) }
function Get-ImageState { (Get-ItemProperty $SetupStateKey -ErrorAction SilentlyContinue).ImageState }

# Run a native exe without letting its stderr raise a terminating error under EAP=Stop
# (a real PS 5.1 trap: `& exe 2>...` throws NativeCommandError on the first stderr line,
# regardless of exit code). Returns exit code and captured output.
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
    } finally { $ErrorActionPreference = $eap }
}

function Remove-AutoLogonSecrets {
    Remove-ItemProperty -Path $WinlogonKey -Name 'DefaultPassword' -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $WinlogonKey -Name 'AutoLogonCount'  -ErrorAction SilentlyContinue
    # Restore the pre-build autologon values we recorded, or remove ones we introduced.
    $orig = Get-ItemProperty -Path $StateKey -ErrorAction SilentlyContinue
    foreach ($name in 'AutoAdminLogon', 'DefaultUserName', 'DefaultDomainName') {
        $savedName = "Orig_$name"
        if ($orig -and $null -ne $orig.PSObject.Properties[$savedName]) {
            Set-ItemProperty -Path $WinlogonKey -Name $name -Value $orig.$savedName -Type String -ErrorAction SilentlyContinue
        } else {
            Remove-ItemProperty -Path $WinlogonKey -Name $name -ErrorAction SilentlyContinue
        }
    }
    # No LSA-secret cleanup is needed: pass 1 refuses to arm autologon when an LSA DefaultPassword
    # secret exists, and this script only ever writes the registry value.
}

function Assert-NoAutoLogonSecrets {
    $w = Get-ItemProperty -Path $WinlogonKey -ErrorAction SilentlyContinue
    if ($w -and $null -ne $w.PSObject.Properties['DefaultPassword']) { throw 'DefaultPassword is still present after scrub.' }
    if ($w -and "$($w.AutoAdminLogon)" -eq '1') { throw 'AutoAdminLogon is still 1 after scrub.' }
}

# A logon banner (LegalNotice*) blocks AutoAdminLogon. Clear it for the build's one-shot autologon
# and restore the original values before Sysprep, so the banner is unchanged in the resulting AMI.
function Clear-LogonBanner {
    $any = $false
    foreach ($k in $BannerKeys) {
        $abbr = if ($k -like '*Policies*') { 'PS' } else { 'WL' }
        $p = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
        foreach ($name in 'LegalNoticeCaption', 'LegalNoticeText') {
            # Windows ships these values empty; only a non-empty banner blocks autologon.
            if ($p -and $null -ne $p.PSObject.Properties[$name] -and -not [string]::IsNullOrEmpty([string]$p.$name)) {
                Set-ItemProperty -Path $StateKey -Name "Banner_${abbr}_$name" -Value ([string]$p.$name) -Type String
                Remove-ItemProperty -Path $k -Name $name -ErrorAction SilentlyContinue
                $any = $true
            }
        }
    }
    if ($any) {
        Set-ItemProperty -Path $StateKey -Name 'BannerCleared' -Value 1 -Type DWord
        Write-Step 'Temporarily cleared logon banner (LegalNotice*) so AutoAdminLogon can work; it is restored before Sysprep.'
    }
}
function Restore-LogonBanner {
    $s = Get-ItemProperty -Path $StateKey -ErrorAction SilentlyContinue
    if (-not $s -or [int]$s.BannerCleared -ne 1) { return }
    foreach ($k in $BannerKeys) {
        $abbr = if ($k -like '*Policies*') { 'PS' } else { 'WL' }
        foreach ($name in 'LegalNoticeCaption', 'LegalNoticeText') {
            $sv = "Banner_${abbr}_$name"
            if ($null -ne $s.PSObject.Properties[$sv]) { Set-ItemProperty -Path $k -Name $name -Value $s.$sv -Type String }
        }
    }
    Set-ItemProperty -Path $StateKey -Name 'BannerCleared' -Value 0 -Type DWord
    Write-Step 'Restored logon banner (LegalNotice*) to the image.'
}

# Append to the shared identity/marker log (the interactive launcher writes to the same file).
function Write-IdentityLog([string]$m) {
    for ($i = 0; $i -lt 5; $i++) {
        try { Add-Content -Path $IdentityLog -Value ('{0:o} [SYSTEM {1}] {2}' -f (Get-Date), $SysprepContext, $m) -ErrorAction Stop; return }
        catch { Start-Sleep -Milliseconds 150 }
    }
}

# Print the identity log to the Run Command output without the long whoami /all block, so the
# failure reason stays inside the 2,500-character output the module shows (whoami stays in the file).
function Write-IdentityLogSummary {
    $txt = ''; try { $txt = Get-Content $IdentityLog -Raw -ErrorAction Stop } catch {}
    $txt.Split("`n") | Where-Object { $_ -and $_ -notmatch '\] whoami: ' } | ForEach-Object { Write-Step $_.TrimEnd() }
}

function Fail([string]$m) {
    Write-Step "FAIL: $m"
    Write-IdentityLog "FAIL: $m"
    try { if ($SysprepContext -eq 'InteractiveAutoLogon') { Remove-AutoLogonSecrets; Restore-LogonBanner } } catch { Write-Step "Scrub error: $($_.Exception.Message)" }
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}

function New-RandomPassword {
    $bytes = New-Object 'System.Byte[]' 48
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return ([Convert]::ToBase64String($bytes) + 'aA1!')   # guarantees the four complexity classes
}
function Get-BuiltinAdministrator {
    $a = Get-LocalUser -ErrorAction Stop | Where-Object { $_.SID.Value -match '^S-1-5-21-\d+-\d+-\d+-500$' }
    if (-not $a) { throw 'Built-in Administrator (RID 500) not found.' }
    return $a
}
function Set-RandomAdminPassword($Admin) {
    $pw = New-RandomPassword
    $Admin | Set-LocalUser -Password (ConvertTo-SecureString -String $pw -AsPlainText -Force)
    return $pw
}

# -IgnorePendingReboot: pending-reboot flags only clear with a reboot, so InteractiveAutoLogon pass 1
# (which is about to reboot) does not wait for them; the launcher re-checks them after the reboot.
function Wait-SysprepReadiness([int]$TimeoutMinutes, [switch]$IgnorePendingReboot) {
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $clean = 0
    while ($true) {
        $reasons = @()
        $imageState = Get-ImageState
        if ($imageState -ne $ReadyState) { $reasons += "ImageState=$imageState" }
        $pending = @()
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pending += 'CBS RebootPending' }
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pending += 'WU RebootRequired' }
        if ($pending -and -not $IgnorePendingReboot) { $reasons += $pending }
        if (Get-Process -Name TiWorker, TrustedInstaller -ErrorAction SilentlyContinue) { $reasons += 'servicing active (TiWorker/TrustedInstaller)' }
        if (Test-Path $EC2LaunchExe) {
            $st = (Invoke-Native $EC2LaunchExe @('status')).ExitCode   # 0 ok, 1 failed (expected on 2025 preReady), 2 running
            if ($st -eq 2) { $reasons += 'EC2Launch agent still running (status=2)' }
        }
        if (-not $reasons) {
            $clean++
            if ($clean -ge 3) {
                if ($pending) { Write-Step "Pending reboot ($($pending -join '; ')) left to the upcoming reboot." }
                Write-Step "Ready for sysprep (ImageState=$imageState)."; return
            }
        } else { $clean = 0 }
        if ((Get-Date) -gt $deadline) { throw "Not ready for sysprep after $TimeoutMinutes min: $($reasons -join '; ')" }
        if ($reasons) { Write-Step "Waiting for readiness: $($reasons -join '; ')" }
        Start-Sleep -Seconds 20
    }
}

function Invoke-EgpuPatch {
    # Server 2025 removed wmic.exe, which the installEgpuManager task needs; remove that task.
    $configPath = 'C:\ProgramData\Amazon\EC2Launch\config\agent-config.yml'
    if (-not (Test-Path $configPath)) { Write-Step 'agent-config.yml not found; skipping EC2Launch patch.'; return }
    $config  = Get-Content -Path $configPath -Raw
    $patched = $config -replace '(?m)^\s*-\s*task:\s*installEgpuManager.*(\r?\n)', ''
    if ($patched -eq $config) { Write-Step 'installEgpuManager task not present; config unchanged.'; return }
    Copy-Item $configPath "$configPath.PackerBaseAMI.bak" -Force
    Set-Content -Path $configPath -Value $patched -Force -NoNewline
    $v = Invoke-Native $EC2LaunchExe @('validate'); $v.Output | ForEach-Object { Write-Step "validate: $_" }
    if ($v.ExitCode -ne 0) { Copy-Item "$configPath.PackerBaseAMI.bak" $configPath -Force; throw 'EC2Launch validate failed after patch; original config restored.' }
    Remove-Item "$configPath.PackerBaseAMI.bak" -Force -ErrorAction SilentlyContinue
    Write-Step 'installEgpuManager task removed from EC2Launch v2 config.'
}

function Disable-CopyProfile {
    # The module performs no default-profile customization, so avoid CopyProfile copying the
    # build-time Administrator profile into Default for every new user.
    if (-not (Test-Path $UnattendPath)) { Write-Step 'unattend.xml not found; leaving CopyProfile unchanged.'; return }
    $x = Get-Content -Path $UnattendPath -Raw
    if ($x -match '(?is)<CopyProfile>\s*true\s*</CopyProfile>') {
        $x = $x -replace '(?is)<CopyProfile>\s*true\s*</CopyProfile>', '<CopyProfile>false</CopyProfile>'
        Set-Content -Path $UnattendPath -Value $x -Force -NoNewline
        Write-Step 'Set CopyProfile=false in EC2Launch unattend.xml (the setting stays in the AMI for later Sysprep runs).'
    } else { Write-Step 'CopyProfile is not true in unattend.xml; unchanged.' }
}

function Install-XamlLogonTask {
    # Opt-in defense in depth: register the three XAML packages for every user at logon,
    # per Microsoft's Solution. Baked into the AMI; harmless on 2022/Core (the stub self-skips).
    [IO.File]::WriteAllText($XamlStubPath, [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($XamlStubB64)))
    $action    = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$XamlStubPath`""
    $trigger   = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited   # BUILTIN\Users, each in their own context
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName 'PackerBaseAMI-XamlRegistration' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Step 'Installed per-user XAML registration logon task (PackerBaseAMI-XamlRegistration).'
}

# ============================== main ==============================
try {
    $admin = Get-BuiltinAdministrator
    if (-not $admin.Enabled) { Fail 'Built-in Administrator (RID 500) is disabled; cannot run sysprep as a non-SYSTEM admin.' }

    if (-not (Test-Path $StateKey)) { $null = New-Item -Path $StateKey -Force }   # create-if-absent: NEVER -Force an existing key (it wipes values)
    $state = Get-ItemProperty -Path $StateKey -ErrorAction SilentlyContinue
    $imageState = Get-ImageState
    Write-Step "BuildId=$BuildId Context=$SysprepContext Phase=$($state.Phase) ImageState=$imageState whoami=$((Invoke-Native 'whoami.exe' @()).Output)"

    # A re-run after Phase=Launched means the SSM agent restarted the in-progress command (its document
    # worker died). InteractiveAutoLogon resumes watching the launcher below; BatchLogon has lost its
    # child process handle, so it fails closed.
    if ($state.Phase -eq 'Launched' -and $SysprepContext -ne 'InteractiveAutoLogon') { Fail 'Sysprep was already launched on this instance (one-shot). Rebuild on a fresh instance.' }

    # -------------------------------------------------------------- InteractiveAutoLogon
    if ($SysprepContext -eq 'InteractiveAutoLogon') {

        if ($state.Phase -notin 'AutoLogonArmed', 'Launched') {
            # ---------- PASS 1 ----------
            if ($imageState -ne $ReadyState) { Fail "ImageState is $imageState, not $ReadyState; the source image is not ready to sysprep." }
            Remove-Item -Path $IdentityLog -Force -ErrorAction SilentlyContinue
            if (Test-Path 'HKLM:\SECURITY\Policy\Secrets\DefaultPassword') { Fail 'An LSA DefaultPassword secret exists and would override the registry value. Re-run with -SysprepExecutionContext BatchLogon.' }

            Wait-SysprepReadiness -TimeoutMinutes 20 -IgnorePendingReboot
            Invoke-EgpuPatch
            Disable-CopyProfile
            if ($InstallXaml) { Install-XamlLogonTask }
            Clear-LogonBanner   # a LegalNotice banner blocks autologon; cleared now, restored in pass 2 before sysprep

            # Record pre-build autologon values so pass 2 can restore them exactly.
            $w = Get-ItemProperty -Path $WinlogonKey -ErrorAction SilentlyContinue
            foreach ($name in 'AutoAdminLogon', 'DefaultUserName', 'DefaultDomainName') {
                if ($w -and $null -ne $w.PSObject.Properties[$name]) { Set-ItemProperty -Path $StateKey -Name "Orig_$name" -Value ([string]$w.$name) -Type String }
            }

            # Write the interactive launcher and arm a one-shot autologon + RunOnce.
            [IO.File]::WriteAllText($LauncherPath, [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($LauncherB64)))
            $pw = Set-RandomAdminPassword -Admin $admin
            Set-ItemProperty -Path $WinlogonKey -Name 'DefaultUserName'   -Value $admin.Name        -Type String
            Set-ItemProperty -Path $WinlogonKey -Name 'DefaultDomainName' -Value $env:COMPUTERNAME  -Type String
            Set-ItemProperty -Path $WinlogonKey -Name 'DefaultPassword'   -Value $pw                -Type String
            Set-ItemProperty -Path $WinlogonKey -Name 'AutoLogonCount'    -Value 1                  -Type DWord
            Set-ItemProperty -Path $WinlogonKey -Name 'AutoAdminLogon'    -Value '1'                -Type String
            Remove-Variable pw
            Set-ItemProperty -Path $RunOnceKey -Name 'PackerBaseAMISysprep' -Value ("`"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$LauncherPath`"") -Type String

            Set-ItemProperty -Path $StateKey -Name 'Phase' -Value 'AutoLogonArmed' -Type String
            Set-ItemProperty -Path $StateKey -Name 'RebootRetries' -Value 0 -Type DWord
            $null = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($VolatileArmed, [Microsoft.Win32.RegistryKeyPermissionCheck]::Default, [Microsoft.Win32.RegistryOptions]::Volatile)
            Write-Step 'Autologon armed (one-shot) and RunOnce launcher installed. Requesting SSM reboot (exit 3010).'
            try { Stop-Transcript | Out-Null } catch {}
            exit 3010
        }

        # ---------- PASS 2 (after reboot) ----------
        if ($state.Phase -eq 'AutoLogonArmed') {
            if (Test-Path "HKLM:\$VolatileArmed") {
                $retries = [int]$state.RebootRetries
                if ($retries -ge 3) { Fail 'Reboot was requested but the volatile boot marker persists after 3 attempts.' }
                Set-ItemProperty -Path $StateKey -Name 'RebootRetries' -Value ($retries + 1) -Type DWord
                Write-Step "No reboot detected yet (attempt $($retries + 1)); requesting reboot again (exit 3010)."
                try { Stop-Transcript | Out-Null } catch {}
                exit 3010
            }
            Write-Step 'Reboot confirmed. Waiting for the interactive launcher to start (autologon).'

            # Wait for the launcher to prove it started interactively.
            $deadline = (Get-Date).AddMinutes(15); $started = $false
            while ((Get-Date) -lt $deadline) {
                $txt = ''; try { $txt = Get-Content $IdentityLog -Raw -ErrorAction Stop } catch {}
                if ($txt -match 'MARKER LAUNCHER_STARTED') { $started = $true; break }
                Start-Sleep -Seconds 5
            }
            if (-not $started) { Fail 'AUTOLOGON_TIMEOUT: the interactive launcher never started (autologon may be blocked). Re-run with -SysprepExecutionContext BatchLogon.' }

            # Scrub the build-time autologon state BEFORE setting Phase=Launched. The launcher waits for
            # Phase=Launched before it starts sysprep, so the image can never be sealed with this state.
            Remove-AutoLogonSecrets
            Assert-NoAutoLogonSecrets
            Restore-LogonBanner   # put the original LegalNotice banner back before sysprep captures the image
            Remove-ItemProperty -Path $RunOnceKey -Name 'PackerBaseAMISysprep' -ErrorAction SilentlyContinue
            $null = Set-RandomAdminPassword -Admin $admin
            Remove-Item -Path $LauncherPath -Force -ErrorAction SilentlyContinue   # the running launcher has already loaded it
            Set-ItemProperty -Path $StateKey -Name 'Phase' -Value 'Launched' -Type String
            Write-Step 'Launcher is running interactively; autologon secrets scrubbed, banner restored and Administrator password rotated. Sysprep may start.'
        } else {
            Write-Step 'Phase=Launched: the SSM agent restarted this command; resuming the launcher watch.'
        }

        # Watch the launcher's markers, and independently guard against a SYSTEM-owned sysprep.
        # The launcher may spend up to ~30 minutes on readiness and package cleanup before
        # LAUNCHING_SYSPREP; generalize then gets its own 75-minute budget, covering the launcher's
        # 5-minute owner watch, 45-minute ec2launch wait and 20-minute sysprep drain.
        $bad = @('IDENTITY_FAIL', 'READINESS_TIMEOUT', 'ORCHESTRATOR_TIMEOUT', 'SYSPREP_OWNER_SYSTEM', 'SYSPREP_OWNER_MISMATCH', 'SYSPREP_NOT_STARTED', 'LAUNCHER_EXCEPTION')
        $deadline = (Get-Date).AddMinutes(35); $sysprepStarted = $false
        while ((Get-Date) -lt $deadline) {
            $txt = ''; try { $txt = Get-Content $IdentityLog -Raw -ErrorAction Stop } catch {}
            foreach ($b in $bad) {
                if ($txt -match "MARKER $b") { Write-Step "Launcher reported $b; identity log follows."; Write-IdentityLogSummary; Fail "Launcher reported $b." }
            }
            if ($txt -match 'MARKER SYSPREP_FAILED_') { Write-Step 'Launcher reported the image did not generalize; identity log follows.'; Write-IdentityLogSummary; Fail 'Launcher reported the image did not generalize (SYSPREP_FAILED).' }
            if (-not $sysprepStarted -and $txt -match 'MARKER LAUNCHING_SYSPREP') { $sysprepStarted = $true; $deadline = (Get-Date).AddMinutes(75) }
            # Independent safety net: if any sysprep.exe is running as SYSTEM, kill it and fail.
            foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='sysprep.exe'" -ErrorAction SilentlyContinue)) {
                $owner = (Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction SilentlyContinue).Sid
                if ($owner -eq 'S-1-5-18') { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue; Fail 'A sysprep.exe was found running as SYSTEM; killed it. The image would have hit the XAML skip.' }
            }
            if ($txt -match 'MARKER SYSPREP_GENERALIZED') {
                Write-IdentityLogSummary
                if ((Get-ImageState) -ne $SealedState) { Fail "Launcher reported generalized but ImageState is $(Get-ImageState)." }
                Remove-Item -Path 'HKLM:\SOFTWARE\PackerBaseAMI' -Recurse -Force -ErrorAction SilentlyContinue
                if (-not $InstallXaml) { Remove-Item -Path $WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
                Write-Step 'SUCCESS: sysprep ran as the interactive built-in Administrator and the image is generalized. The instance will power off shortly.'
                try { Stop-Transcript | Out-Null } catch {}
                exit 0
            }
            Start-Sleep -Seconds 5
        }
        # Timed out: show the evidence and stop any sysprep still running so it cannot seal the image
        # (and power off via the launcher) after this command has already reported Failed.
        Write-IdentityLogSummary
        Get-Process -Name sysprep, EC2Launch -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        if ($sysprepStarted) { Fail 'Timed out waiting for the launcher to report a generalized image; stopped sysprep.' }
        Fail 'Timed out waiting for the launcher to start sysprep (no LAUNCHING_SYSPREP marker).'
    }

    # -------------------------------------------------------------- BatchLogon
    elseif ($SysprepContext -eq 'BatchLogon') {
        if ($imageState -ne $ReadyState) { Fail "ImageState is $imageState, not $ReadyState; the source image is not ready to sysprep." }
        Remove-Item -Path $IdentityLog -Force -ErrorAction SilentlyContinue
        Wait-SysprepReadiness -TimeoutMinutes 20
        Invoke-EgpuPatch
        Disable-CopyProfile
        if ($InstallXaml) { Install-XamlLogonTask }

        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
namespace PackerBaseAMI {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct PROFILEINFO { public int dwSize; public int dwFlags; public string lpUserName; public string lpProfilePath;
    public string lpDefaultPath; public string lpServerName; public string lpPolicyPath; public IntPtr hProfile; }
  [StructLayout(LayoutKind.Sequential)]
  public struct PROCESS_INFORMATION { public IntPtr hProcess; public IntPtr hThread; public int dwProcessId; public int dwThreadId; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct STARTUPINFO { public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
    public int dwX; public int dwY; public int dwXSize; public int dwYSize; public int dwXCountChars; public int dwYCountChars;
    public int dwFillAttribute; public int dwFlags; public short wShowWindow; public short cbReserved2; public IntPtr lpReserved2;
    public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError; }
  public static class Native {
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool LogonUser(string user, string domain, IntPtr password, int logonType, int provider, out IntPtr token);
    [DllImport("userenv.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool LoadUserProfile(IntPtr token, ref PROFILEINFO pi);
    [DllImport("userenv.dll", SetLastError=true)] public static extern bool CreateEnvironmentBlock(out IntPtr env, IntPtr token, bool inherit);
    [DllImport("userenv.dll", SetLastError=true)] public static extern bool DestroyEnvironmentBlock(IntPtr env);
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool CreateProcessAsUser(IntPtr token, string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit,
      int flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetExitCodeProcess(IntPtr h, out int code);
    // AWS AWSEC2-RunSysprep flags: NORMAL_PRIORITY_CLASS | CREATE_NEW_CONSOLE | CREATE_UNICODE_ENVIRONMENT
    public const int FLAGS = 0x00000020 | 0x00000010 | 0x00000400;
    public const int LOGON32_LOGON_BATCH = 4;
    public const int LOGON32_PROVIDER_DEFAULT = 0;
    // Returns the child's process id. hProcess stays open so the caller can wait for the child and
    // read its exit code; the user profile stays loaded until the instance shuts down.
    public static int Launch(string user, IntPtr pw, string command, out IntPtr hProcess) {
      hProcess = IntPtr.Zero;
      IntPtr token;
      if (!LogonUser(user, ".", pw, LOGON32_LOGON_BATCH, LOGON32_PROVIDER_DEFAULT, out token))
        throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "LogonUser(BATCH)");
      try {
        var pi = new PROFILEINFO(); pi.dwSize = Marshal.SizeOf(typeof(PROFILEINFO)); pi.lpUserName = user;
        if (!LoadUserProfile(token, ref pi)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "LoadUserProfile");
        if (pi.hProfile == IntPtr.Zero) throw new Exception("LoadUserProfile returned a null profile handle.");
        IntPtr env;
        if (!CreateEnvironmentBlock(out env, token, false)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "CreateEnvironmentBlock");
        try {
          var si = new STARTUPINFO(); si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
          // "" rather than NULL: connect to the batch logon session's own window station and desktop
          // instead of inheriting SYSTEM's Service-0x0-3e7$, which the Administrator token may not be
          // able to open (the child would then fail to initialize with STATUS_DLL_INIT_FAILED).
          si.lpDesktop = "";
          PROCESS_INFORMATION proc;
          // CreateProcessW may write to the command-line buffer, so pass a writable StringBuilder.
          if (!CreateProcessAsUser(token, null, new StringBuilder(command), IntPtr.Zero, IntPtr.Zero, false, FLAGS, env, null, ref si, out proc))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "CreateProcessAsUser");
          CloseHandle(proc.hThread);
          hProcess = proc.hProcess;
          return proc.dwProcessId;
        } finally { DestroyEnvironmentBlock(env); }
      } finally { CloseHandle(token); }
    }
  }
}
'@

        $pw = Set-RandomAdminPassword -Admin $admin
        $pwPtr = [Runtime.InteropServices.Marshal]::StringToHGlobalUni($pw); Remove-Variable pw
        # Run ec2launch through cmd.exe so its output is captured to files and its exit code is returned.
        $BatchOutLog = Join-Path $LogDir 'PackerBaseAMI-ec2launch-sysprep.out.log'
        $BatchErrLog = Join-Path $LogDir 'PackerBaseAMI-ec2launch-sysprep.err.log'
        $cmd = "`"$env:SystemRoot\System32\cmd.exe`" /d /c `"`"$EC2LaunchExe`" sysprep --shutdown=false 1>`"$BatchOutLog`" 2>`"$BatchErrLog`"`""
        $hChild = [IntPtr]::Zero
        try {
            $childPid = [PackerBaseAMI.Native]::Launch($admin.Name, $pwPtr, $cmd, [ref]$hChild)
        } catch {
            Fail "Batch LogonUser/CreateProcessAsUser failed: $($_.Exception.Message) (error 1385 = Administrator lacks 'Log on as a batch job')."
        } finally { [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($pwPtr) }
        Set-ItemProperty -Path $StateKey -Name 'Phase' -Value 'Launched' -Type String
        Write-Step "ec2launch sysprep started as the batch built-in Administrator (pid=$childPid)."
        Write-IdentityLog "MARKER BATCH_LAUNCHED pid=$childPid User=$($admin.Name) SID=$($admin.SID.Value) LogonType=BATCH"

        # sysprep.exe must run as the built-in Administrator, never SYSTEM. Wait for the ec2launch child
        # to exit (it exits early if sysprep never starts), then verify ownership and generalize.
        $deadline = (Get-Date).AddMinutes(45); $ownerVerified = $false; $childExit = $null; $loggedPids = @{}
        while ((Get-Date) -lt $deadline) {
            foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='sysprep.exe'" -ErrorAction SilentlyContinue)) {
                $owner = (Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction SilentlyContinue).Sid
                if (-not $owner) { continue }   # exited between enumeration and the owner query: no evidence either way
                if (-not $loggedPids.ContainsKey($p.ProcessId)) {
                    $loggedPids[$p.ProcessId] = $true
                    Write-IdentityLog "sysprep.exe pid=$($p.ProcessId) OwnerSid=$owner Session=$($p.SessionId) ParentPid=$($p.ParentProcessId)"
                }
                if ($owner -eq 'S-1-5-18') {
                    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
                    Write-IdentityLog 'MARKER SYSPREP_OWNER_SYSTEM'
                    Fail 'sysprep.exe was running as SYSTEM under the batch context; killed it.'
                }
                if ($owner -ne $admin.SID.Value) {
                    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
                    Write-IdentityLog 'MARKER SYSPREP_OWNER_MISMATCH'
                    Fail "sysprep.exe ran as $owner, not the built-in Administrator ($($admin.SID.Value)); killed it."
                }
                if (-not $ownerVerified) { $ownerVerified = $true; Write-IdentityLog 'MARKER SYSPREP_OWNER_OK' }
            }
            if ([PackerBaseAMI.Native]::WaitForSingleObject($hChild, 0) -eq 0) {
                $code = 0; $null = [PackerBaseAMI.Native]::GetExitCodeProcess($hChild, [ref]$code); $childExit = $code
                break
            }
            Start-Sleep -Seconds 5
        }
        $null = [PackerBaseAMI.Native]::CloseHandle($hChild)
        if ($null -eq $childExit) {
            Get-Process -Name sysprep, EC2Launch -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Write-IdentityLog 'MARKER SYSPREP_FAILED_TIMEOUT'
            Write-IdentityLogSummary
            Fail 'ec2launch sysprep did not finish within 45 minutes; stopped it.'
        }
        Write-IdentityLog "ec2launch.exe exited with $childExit."
        # Like the interactive launcher, give sysprep.exe up to 20 minutes to finish after ec2launch exits.
        $waitSysprep = (Get-Date).AddMinutes(20)
        while ((Get-Date) -lt $waitSysprep -and (Get-Process -Name sysprep -ErrorAction SilentlyContinue)) { Start-Sleep -Seconds 5 }
        $finalState = Get-ImageState
        if (-not $ownerVerified) { Write-IdentityLog 'MARKER SYSPREP_NOT_STARTED' }
        elseif ($finalState -ne $SealedState) { Write-IdentityLog "MARKER SYSPREP_FAILED_$finalState" }
        else { Write-IdentityLog 'MARKER SYSPREP_GENERALIZED' }
        # Result line first, then the evidence: the module shows only the first 2,500 characters of output.
        Write-Step "Batch result: ec2launch exit=$childExit sysprepOwnerVerified=$ownerVerified ImageState=$finalState"
        Write-IdentityLogSummary
        foreach ($f in $BatchOutLog, $BatchErrLog) {
            if (Test-Path $f) { Get-Content $f -Tail 10 -ErrorAction SilentlyContinue | ForEach-Object { Write-Step "$(Split-Path $f -Leaf): $_" } }
        }
        if (-not $ownerVerified) { Fail "sysprep.exe was never observed running as the built-in Administrator (ec2launch exit code $childExit)." }
        if ($finalState -ne $SealedState) {
            if (Test-Path 'C:\Windows\System32\Sysprep\Panther\setuperr.log') { Get-Content 'C:\Windows\System32\Sysprep\Panther\setuperr.log' -Tail 40 -ErrorAction SilentlyContinue | ForEach-Object { Write-Step "setuperr: $_" } }
            Fail "Image did not generalize (ImageState=$finalState, ec2launch exit code $childExit)."
        }

        Remove-Item -Path 'HKLM:\SOFTWARE\PackerBaseAMI' -Recurse -Force -ErrorAction SilentlyContinue
        if (-not $InstallXaml) { Remove-Item -Path $WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
        Write-Step 'SUCCESS: sysprep ran as the batch built-in Administrator and the image is generalized. Shutting down in 120s.'
        try { Stop-Transcript | Out-Null } catch {}
        & shutdown.exe /s /t 120 /d p:2:4 /c 'PackerBaseAMI: sysprep generalized (batch Administrator).'
        exit 0
    }

    else { Fail "Unknown SysprepExecutionContext '$SysprepContext'." }
}
catch { Fail $_.Exception.Message }
