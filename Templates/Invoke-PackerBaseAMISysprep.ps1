<#
.SYNOPSIS
    PackerBaseAMI sysprep orchestrator for Windows Server 2022/2025. Runs as NT AUTHORITY\SYSTEM
    (SSM AWS-RunPowerShellScript) and arranges for Sysprep to run under the built-in
    Administrator instead of SYSTEM, because Microsoft does not support sysprep as Local System
    and it breaks XAML apps on Server 2025:
    https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/sysprep-as-system-windows-11
.DESCRIPTION
    Two execution contexts (chosen by the module, overridable with -SysprepExecutionContext):

      InteractiveAutoLogon (default on Server 2025 Desktop Experience)
        Pass 1: patch EC2Launch config, set CopyProfile=false, arm a one-shot AutoAdminLogon as
                the built-in Administrator, register a RunOnce that starts the interactive
                launcher, then `exit 3010` so SSM reboots and re-runs this script.
        Pass 2: wait for the launcher to prove it is running interactively (LAUNCHER_STARTED),
                scrub every autologon secret, then watch the launcher's markers and report
                Success only after the image is confirmed generalized. The interactive launcher
                runs sysprep in a real console session (positive Server 2025 evidence).

      BatchLogon (default on Server 2022, and the fallback when autologon cannot work)
        Single pass: LogonUser(BATCH) + CreateProcessAsUser as the built-in Administrator to run
        `ec2launch sysprep --shutdown=false` (AWS's own AWSEC2-RunSysprep pattern), verify the
        image generalized, then shut down. No reboot.

    Fail-closed: on any failure the script exits non-zero; the module then terminates the build
    instance so Packer creates no AMI. Success is reported before shutdown so the operator sees it.

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
    # LSA-stored autologon password (Winlogon prefers this over the registry value).
    Remove-ItemProperty -Path $WinlogonKey -Name 'DefaultPassword' -ErrorAction SilentlyContinue
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
            if ($p -and $null -ne $p.PSObject.Properties[$name]) {
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

function Fail([string]$m) {
    Write-Step "FAIL: $m"
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

function Wait-SysprepReadiness([int]$TimeoutMinutes) {
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $clean = 0
    while ($true) {
        $reasons = @()
        $imageState = Get-ImageState
        if ($imageState -ne $ReadyState) { $reasons += "ImageState=$imageState" }
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'CBS RebootPending' }
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'WU RebootRequired' }
        if (Get-Process -Name TiWorker, TrustedInstaller -ErrorAction SilentlyContinue) { $reasons += 'servicing active (TiWorker/TrustedInstaller)' }
        if (Test-Path $EC2LaunchExe) {
            $st = (Invoke-Native $EC2LaunchExe @('status')).ExitCode   # 0 ok, 1 failed (expected on 2025 preReady), 2 running
            if ($st -eq 2) { $reasons += 'EC2Launch agent still running (status=2)' }
        }
        if (-not $reasons) {
            $clean++
            if ($clean -ge 3) { Write-Step "Ready for sysprep (ImageState=$imageState)."; return }
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
        Write-Step 'Set CopyProfile=false in EC2Launch unattend.xml.'
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

    if ($state.Phase -eq 'Launched') { Fail 'Sysprep was already launched on this instance (one-shot). Rebuild on a fresh instance.' }

    # -------------------------------------------------------------- InteractiveAutoLogon
    if ($SysprepContext -eq 'InteractiveAutoLogon') {

        if ($state.Phase -ne 'AutoLogonArmed') {
            # ---------- PASS 1 ----------
            if ($imageState -ne $ReadyState) { Fail "ImageState is $imageState, not $ReadyState; the source image is not ready to sysprep." }
            Remove-Item -Path $IdentityLog -Force -ErrorAction SilentlyContinue
            if (Test-Path 'HKLM:\SECURITY\Policy\Secrets\DefaultPassword') { Fail 'An LSA DefaultPassword secret exists and would override the registry value. Re-run with -SysprepExecutionContext BatchLogon.' }

            Wait-SysprepReadiness -TimeoutMinutes 20
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
        if (Test-Path "HKLM:\$VolatileArmed") {
            $retries = [int]$state.RebootRetries
            if ($retries -ge 3) { Fail 'Reboot was requested but the volatile boot marker persists after 3 attempts.' }
            Set-ItemProperty -Path $StateKey -Name 'RebootRetries' -Value ($retries + 1) -Type DWord
            Write-Step "No reboot detected yet (attempt $($retries + 1)); requesting reboot again (exit 3010)."
            try { Stop-Transcript | Out-Null } catch {}
            exit 3010
        }
        Write-Step 'Reboot confirmed. Waiting for the interactive launcher to start (autologon).'

        # Wait for the launcher to prove it started interactively, then scrub autologon secrets.
        $deadline = (Get-Date).AddMinutes(15); $started = $false
        while ((Get-Date) -lt $deadline) {
            $txt = ''; try { $txt = Get-Content $IdentityLog -Raw -ErrorAction Stop } catch {}
            if ($txt -match 'MARKER LAUNCHER_STARTED') { $started = $true; break }
            Start-Sleep -Seconds 5
        }
        if (-not $started) { Fail 'AUTOLOGON_TIMEOUT: the interactive launcher never started (autologon may be blocked). Re-run with -SysprepExecutionContext BatchLogon.' }
        Remove-AutoLogonSecrets
        Assert-NoAutoLogonSecrets
        Restore-LogonBanner   # put the original LegalNotice banner back before sysprep captures the image
        Remove-ItemProperty -Path $RunOnceKey -Name 'PackerBaseAMISysprep' -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $StateKey -Name 'Phase' -Value 'Launched' -Type String
        Write-Step 'Launcher is running interactively; autologon secrets scrubbed and Administrator password rotated.'
        $null = Set-RandomAdminPassword -Admin $admin

        # Watch the launcher's markers, and independently guard against a SYSTEM-owned sysprep.
        $bad = @('IDENTITY_FAIL', 'READINESS_TIMEOUT', 'SYSPREP_OWNER_SYSTEM', 'SYSPREP_NOT_STARTED', 'LAUNCHER_EXCEPTION')
        $deadline = (Get-Date).AddMinutes(45)
        while ((Get-Date) -lt $deadline) {
            $txt = ''; try { $txt = Get-Content $IdentityLog -Raw -ErrorAction Stop } catch {}
            foreach ($b in $bad)        { if ($txt -match "MARKER $b") { $txt.Split("`n") | ForEach-Object { Write-Step $_ }; Fail "Launcher reported $b." } }
            if ($txt -match 'MARKER SYSPREP_FAILED_') { $txt.Split("`n") | ForEach-Object { Write-Step $_ }; Fail 'Launcher reported the image did not generalize (SYSPREP_FAILED).' }
            # Independent safety net: if any sysprep.exe is running as SYSTEM, kill it and fail.
            foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='sysprep.exe'" -ErrorAction SilentlyContinue)) {
                $owner = (Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction SilentlyContinue).Sid
                if ($owner -eq 'S-1-5-18') { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue; Fail 'A sysprep.exe was found running as SYSTEM; killed it. The image would have hit the XAML skip.' }
            }
            if ($txt -match 'MARKER SYSPREP_GENERALIZED') {
                $txt.Split("`n") | ForEach-Object { Write-Step $_ }
                if ((Get-ImageState) -ne $SealedState) { Fail "Launcher reported generalized but ImageState is $(Get-ImageState)." }
                Remove-Item -Path 'HKLM:\SOFTWARE\PackerBaseAMI' -Recurse -Force -ErrorAction SilentlyContinue
                Write-Step 'SUCCESS: sysprep ran as the interactive built-in Administrator and the image is generalized. The instance will power off shortly.'
                try { Stop-Transcript | Out-Null } catch {}
                exit 0
            }
            Start-Sleep -Seconds 5
        }
        Fail 'Timed out waiting for the launcher to report a generalized image.'
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
    public static extern bool CreateProcessAsUser(IntPtr token, string app, string cmd, IntPtr pa, IntPtr ta, bool inherit,
      int flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
    // AWS AWSEC2-RunSysprep flags: NORMAL_PRIORITY_CLASS | CREATE_NEW_CONSOLE | CREATE_UNICODE_ENVIRONMENT
    public const int FLAGS = 0x00000020 | 0x00000010 | 0x00000400;
    public const int LOGON32_LOGON_BATCH = 4;
    public const int LOGON32_PROVIDER_DEFAULT = 0;
    public static int Launch(string user, IntPtr pw, string command) {
      IntPtr token;
      if (!LogonUser(user, ".", pw, LOGON32_LOGON_BATCH, LOGON32_PROVIDER_DEFAULT, out token))
        throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "LogonUser(BATCH)");
      var pi = new PROFILEINFO(); pi.dwSize = Marshal.SizeOf(typeof(PROFILEINFO)); pi.lpUserName = user;
      if (!LoadUserProfile(token, ref pi)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "LoadUserProfile");
      if (pi.hProfile == IntPtr.Zero) throw new Exception("LoadUserProfile returned a null profile handle.");
      IntPtr env;
      if (!CreateEnvironmentBlock(out env, token, false)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "CreateEnvironmentBlock");
      try {
        var si = new STARTUPINFO(); si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        PROCESS_INFORMATION proc;
        if (!CreateProcessAsUser(token, null, command, IntPtr.Zero, IntPtr.Zero, false, FLAGS, env, null, ref si, out proc))
          throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "CreateProcessAsUser");
        CloseHandle(proc.hThread); CloseHandle(proc.hProcess);
        return proc.dwProcessId;
      } finally { DestroyEnvironmentBlock(env); CloseHandle(token); }
    }
  }
}
'@

        $pw = Set-RandomAdminPassword -Admin $admin
        $pwPtr = [Runtime.InteropServices.Marshal]::StringToHGlobalUni($pw); Remove-Variable pw
        try {
            $cmd = "`"$EC2LaunchExe`" sysprep --shutdown=false"
            $childPid = [PackerBaseAMI.Native]::Launch($admin.Name, $pwPtr, $cmd)
        } catch {
            Fail "Batch LogonUser/CreateProcessAsUser failed: $($_.Exception.Message) (error 1385 = Administrator lacks 'Log on as a batch job')."
        } finally { [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($pwPtr) }
        Set-ItemProperty -Path $StateKey -Name 'Phase' -Value 'Launched' -Type String
        Write-Step "ec2launch sysprep started as the batch built-in Administrator (pid=$childPid)."

        # Wait for the ec2launch child to exit, then verify generalize. Guard against SYSTEM ownership.
        $deadline = (Get-Date).AddMinutes(45); $sawSysprep = $false
        while ((Get-Date) -lt $deadline) {
            if (-not (Get-Process -Id $childPid -ErrorAction SilentlyContinue) -and $sawSysprep) { break }
            foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='sysprep.exe'" -ErrorAction SilentlyContinue)) {
                $sawSysprep = $true
                $owner = (Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction SilentlyContinue).Sid
                if ($owner -eq 'S-1-5-18') { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue; Fail 'sysprep.exe was running as SYSTEM under the batch context; killed it.' }
            }
            if ((Get-ImageState) -eq $SealedState) { break }
            Start-Sleep -Seconds 10
        }
        if (Test-Path 'C:\Windows\System32\Sysprep\Panther\setuperr.log') { Get-Content 'C:\Windows\System32\Sysprep\Panther\setuperr.log' -Tail 40 -ErrorAction SilentlyContinue | ForEach-Object { Write-Step "setuperr: $_" } }
        if ((Get-ImageState) -ne $SealedState) { Fail "Image did not generalize (ImageState=$(Get-ImageState))." }

        Remove-Item -Path 'HKLM:\SOFTWARE\PackerBaseAMI' -Recurse -Force -ErrorAction SilentlyContinue
        Write-Step 'SUCCESS: sysprep ran as the batch built-in Administrator and the image is generalized. Shutting down in 120s.'
        try { Stop-Transcript | Out-Null } catch {}
        & shutdown.exe /s /t 120 /d p:2:4 /c 'PackerBaseAMI: sysprep generalized (batch Administrator).'
        exit 0
    }

    else { Fail "Unknown SysprepExecutionContext '$SysprepContext'." }
}
catch { Fail $_.Exception.Message }
