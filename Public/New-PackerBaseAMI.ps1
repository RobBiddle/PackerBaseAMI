<#
.Synopsis
    Create a Windows Base AMI using Packer, Encrypted by default
.DESCRIPTION
    Create a Windows Base AMI using Packer, Encrypted by default
.EXAMPLE
   New-PackerBaseAMI -AccountNumber '111111111111' -Alias 'ExampleAlias' -BaseOS 'Windows_Server-2025-English-Full-Base' -IamRole 'ExampleRoleName' -Region 'us-east-1' -InstanceType 't3.medium' -OutputDirectoryPath 'c:\example\directory'
.NOTES
    Author: Robert D. Biddle
    https://github.com/RobBiddle
    https://github.com/RobBiddle/PackerBaseAMI
    PackerBaseAMI  Copyright (C) 2017  Robert D. Biddle
    This program comes with ABSOLUTELY NO WARRANTY; for details type `"help New-PackerBaseAMI -full`".
    This is free software, and you are welcome to redistribute it
    under certain conditions; for details type `"help New-PackerBaseAMI -full`".
    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.
    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
    The GNU General Public License does not permit incorporating your program
    into proprietary programs.  If your program is a subroutine library, you
    may consider it more useful to permit linking proprietary applications with
    the library.  If this is what you want to do, use the GNU Lesser General
    Public License instead of this License.  But first, please read
    <http://www.gnu.org/philosophy/why-not-lgpl.html>.
#>
function New-PackerBaseAMI {
    [CmdletBinding()]
    [Alias()]
    [OutputType([String])]
    Param
    (
        # AWS Account Number, without dashes
        [Parameter(Mandatory = $true,
            ValueFromPipelineByPropertyName = $true,
            Position = 0)]
        [String]
        $AccountNumber,

        # Friendly Name for Account
        [Parameter(Mandatory = $false,
            ValueFromPipelineByPropertyName = $true)]        
        [String]
        $Alias = $AccountNumber,

        # Base Operating System
        [Parameter(Mandatory = $true, 
            ValueFromPipelineByPropertyName = $false)]
        [String]
        $BaseOS = 'Windows_Server-2025-English-Full-Base',

        # Do Not Encrypt the new AMI
        [Parameter(Mandatory = $false, 
            ValueFromPipelineByPropertyName = $false)]
        [Switch]
        $DoNotEncrypt,

        # IAM Role to use
        [Parameter(Mandatory = $true, 
            ValueFromPipelineByPropertyName = $false)]
        [String]
        $IamRole,

        # AWS Region
        [Parameter(Mandatory = $true,
            ValueFromPipelineByPropertyName = $true)]
        [String]
        $Region,
        
        # Output Path for Log Files, if not specified then output is to users' home Directory
        [Parameter(Mandatory = $false,
            ValueFromPipelineByPropertyName = $false)]
        [ValidateScript( {
                if ((Test-Path $_)) {
                    Write-Output "Outputing log files to: $_"
                }else {
                    Throw "$_ is not a valid directory"
                }
            })]
        [String]
        $OutputDirectoryPath = '~',

        # Name of stored AWS Profile to use
        [Parameter(Mandatory = $false,
            ValueFromPipelineByPropertyName = $false)]
        [String]
        $AwsProfileName = $AwsProfileName,

        # EC2 Instance Type to use for building the AMI
        [Parameter(Mandatory = $false,
            ValueFromPipelineByPropertyName = $false)]
        [String]
        $InstanceType = 't3.medium',

        # Windows Server 2022/2025 only: the account context Sysprep runs under. Microsoft does
        # not support running Sysprep as Local System (broken Start menu / Explorer / Settings
        # from a skipped XAML AppX registration):
        # https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/sysprep-as-system-windows-11
        # InteractiveAutoLogon: one reboot, then Sysprep runs in a real console session as the
        #   built-in Administrator (the context with a positive Server 2025 report).
        # BatchLogon: AWS's AWSEC2-RunSysprep-style batch logon as the built-in Administrator,
        #   no reboot; needed on Server Core, which has no Explorer shell for the console launcher.
        # If not specified, the default is InteractiveAutoLogon for Full (Desktop Experience)
        # images of both 2022 and 2025, and BatchLogon for Core images.
        [Parameter(Mandatory = $false,
            ValueFromPipelineByPropertyName = $false)]
        [ValidateSet('InteractiveAutoLogon', 'BatchLogon')]
        [String]
        $SysprepExecutionContext,

        # Windows Server 2022/2025 builds: also bake a per-user logon task into the AMI that
        # re-registers the affected XAML packages on sign-in (Microsoft's remediation), as defense
        # in depth against a residual skip or a future cumulative update. The task is installed on
        # any 2022/2025 build but only acts on Server 2025 Desktop Experience. Off by default.
        [Parameter(Mandatory = $false,
            ValueFromPipelineByPropertyName = $false)]
        [Switch]
        $InstallXamlLogonMitigation,

        [Parameter(Mandatory = $false,
            ValueFromPipelineByPropertyName = $false)]
            [switch]
            $debugMode
    )

    Begin {
        $null = Confirm-PackerIsInstalled
        $null = Confirm-AwsModulesAreInstalled
        $RunDateTime = Get-ShortDate -FilenameCompatibleFormat
    }
    Process {
        # Windows Server 2022/2025 images build via SSM Run Command (see below). Anchor on the image
        # name's OS segment so e.g. 'Windows_Server-2019-English-Full-SQL_2022_Standard' is not
        # mistaken for Server 2022.
        $IsSsmBuild = $BaseOS -match 'Windows_Server-(2022|2025)-'
        if ($IsSsmBuild) {
            # Default the Sysprep context unless the caller chose one. Microsoft's unsupported
            # "Sysprep as Local System" guidance spans Windows 10/11 and Server 2022/2025, so both
            # 2022 and 2025 run Sysprep as the built-in Administrator. Full (Desktop Experience)
            # images use the interactive console context; Core images use the batch context,
            # because Server Core has no Explorer shell to run the RunOnce launcher.
            if (-not $SysprepExecutionContext) {
                $SysprepExecutionContext = if ($BaseOS -match 'Core') { 'BatchLogon' } else { 'InteractiveAutoLogon' }
            } elseif ($SysprepExecutionContext -eq 'InteractiveAutoLogon' -and $BaseOS -match 'Core') {
                throw "-SysprepExecutionContext InteractiveAutoLogon cannot work on a Server Core image ($BaseOS): Core has no Explorer shell to run the RunOnce launcher. Use BatchLogon or omit the parameter."
            }
        } elseif ($PSBoundParameters.ContainsKey('SysprepExecutionContext') -or $InstallXamlLogonMitigation) {
            Write-Warning "-SysprepExecutionContext and -InstallXamlLogonMitigation only apply to Windows Server 2022/2025 images; ignoring them for $BaseOS."
        }

        # Get Temporary AWS Credentials via IAM Switch Role process
        $GetTemporaryCredentials_Params = @{
            AccountNumber = $AccountNumber
            Alias         = $Alias
            Region        = $Region
            IamRole       = $IamRole
        }
        if ($IsSsmBuild) {
            # The SSM build (reboot, readiness gates, sysprep, then AMI creation and encryption) can
            # outlast the default 1-hour session, and neither Packer nor this module can refresh
            # the credentials. Ask for 4 hours; Get-AwsTemporaryCredential falls back to 1 hour
            # with a warning if the role's MaxSessionDuration does not allow it.
            $GetTemporaryCredentials_Params += @{
                DurationInSeconds = 14400
            }
        }
        if ($AwsProfileName) {
            $GetTemporaryCredentials_Params += @{
                AwsProfileName = $AwsProfileName
            }
        }
        $AwsTemporaryCredentials = Get-AwsTemporaryCredential @GetTemporaryCredentials_Params
        # Store Temporary AWS Credentials in environment variables for Packer to access
        $Env:AWS_ACCESS_KEY_ID = $AwsTemporaryCredentials.Credentials.AccessKeyId
        $Env:AWS_SECRET_ACCESS_KEY = $AwsTemporaryCredentials.Credentials.SecretAccessKey
        $Env:AWS_SESSION_TOKEN = $AwsTemporaryCredentials.Credentials.SessionToken
        $Env:AWS_DEFAULT_REGION = $Region
        # Hashtable of credentials for parameter splatting
        $AwsCredentialParams = @{
            AccessKey    = $AwsTemporaryCredentials.Credentials.AccessKeyId
            SecretKey    = $AwsTemporaryCredentials.Credentials.SecretAccessKey
            SessionToken = $AwsTemporaryCredentials.Credentials.SessionToken
        }
        # Validate BaseOS Parameter input
        if (Get-Command Get-EC2ImageByName -ErrorAction SilentlyContinue | Out-Null) {
            $OldImageNameValues = @(Get-EC2ImageByName @AwsCredentialParams -Region $Region)
        } else {
            $OldImageNameValues = @()
        }
        
        $NewImageNameValues = @((Get-SSMLatestEC2Image @AwsCredentialParams -Region $Region -Path ami-windows-latest | Sort-Object Name).Name)
        $ValidBaseOSStrings = $OldImageNameValues
        $ValidBaseOSStrings += $NewImageNameValues 
        $ValidBaseOSStrings = $ValidBaseOSStrings -imatch 'Windows' | Sort-Object
        if ($BaseOS -notin $ValidBaseOSStrings) {
            Write-Warning "Valid Values for BaseOS are: `n$($ValidBaseOSStrings | Foreach-Object {"`n$_"})"
            Break
        }

        # Query for AMI
        if ($BaseOS -in $OldImageNameValues) {
            # Support for old images
            $AmiToPack = Get-EC2ImageByName @AwsCredentialParams -Region $Region -Name $BaseOS -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        } elseif ($BaseOS -in $NewImageNameValues) {
            $AmiToPack = Get-Ec2Image @AwsCredentialParams -Region $Region (Get-SSMLatestEC2Image @AwsCredentialParams -Region $Region -Path ami-windows-latest -ImageName $BaseOS)
        }

        if (-NOT $AmiToPack) {
            Write-Error "No Matching AMI Found"
            Break
        }

        $NewAMIName = "$($AccountNumber)_$($AmiToPack.Name)"
        $vpcId = (Get-EC2Vpc @AwsCredentialParams -Region $Region | Select-Object -First 1).VpcId
        $supportedAZs = (Get-EC2InstanceTypeOffering @AwsCredentialParams -Region $Region -LocationType availability-zone -Filter @{Name='instance-type'; Values=@($InstanceType)}).Location
        # Prefer public subnets so the build instance can reach SSM/EC2Messages endpoints
        # without depending on NAT or VPC endpoints. Fall back to any matching subnet.
        $candidateSubnets = Get-EC2Subnet @AwsCredentialParams -Region $Region |
            Where-Object { $_.VpcId -eq $vpcId -and $_.AvailabilityZone -in $supportedAZs }
        $subnetId = ($candidateSubnets | Where-Object { $_.MapPublicIpOnLaunch } | Select-Object -First 1).SubnetId
        if (-not $subnetId) {
            $subnetId = ($candidateSubnets | Select-Object -First 1).SubnetId
        }
        if (-not $subnetId) {
            Write-Error "No subnet found in an availability zone that supports instance type '$InstanceType' in region '$Region'."
            Break
        }
        if ($DoNotEncrypt) {
            $encrypt_boot = "false"
        }
        else {
            $encrypt_boot = "true"
        }

        # Build the Packer Template
        if ($IsSsmBuild) {
            # Windows Server 2025 removed wmic.exe which EC2Launch v2 depends on, and
            # newer EC2Launch v2 / Server 2022 base AMIs hit the same class of preReady
            # failure that prevents UserData (and therefore sysprep) from running.
            # Use SSM Run Command after Packer launches the instance to patch the
            # EC2Launch v2 config and trigger sysprep directly, bypassing UserData entirely.
            $PackerBuildId = [guid]::NewGuid().ToString()
            # With disable_stop_instance, Packer starts waiting for 'stopped' as soon as the instance
            # is running, polling aws_polling.max_attempts x delay_seconds, and then halts and
            # terminates the instance. Every later Packer step uses the same static credentials, so
            # size that wait to the credential lifetime, keeping 30 minutes for AMI creation,
            # encryption and cleanup; never below the previous 55 minutes or above 3 hours.
            $CredentialExpiration = $AwsTemporaryCredentials.Credentials.Expiration
            $CredentialSeconds = if ($CredentialExpiration) { ([datetime]$CredentialExpiration).ToUniversalTime().Subtract([datetime]::UtcNow).TotalSeconds } else { 3600 }
            $PackerPollDelaySeconds = 10
            $PackerPollMaxAttempts = [int][math]::Min(1080, [math]::Max(330, [math]::Floor(($CredentialSeconds - 1800) / $PackerPollDelaySeconds)))
            $PackerStopWaitSeconds = $PackerPollMaxAttempts * $PackerPollDelaySeconds
            # Attach a temporary instance profile so SSM Agent can register without
            # depending on Default Host Management Configuration (DHMC). Packer
            # creates and deletes this profile around the build.
            $TempInstanceProfilePolicy = [PSCustomObject]@{
                Version   = "2012-10-17"
                Statement = @(
                    [PSCustomObject]@{
                        Effect   = "Allow"
                        Action   = @("ssm:*", "ssmmessages:*", "ec2messages:*")
                        Resource = "*"
                    }
                )
            }
            $builders = [PSCustomObject]@{
                type                                            = "amazon-ebs"
                communicator                                    = "none"
                disable_stop_instance                           = "true"
                encrypt_boot                                    = $encrypt_boot
                region                                          = $Region
                Vpc_Id                                          = $vpcId
                Subnet_Id                                       = $subnetId
                associate_public_ip_address                     = "true"
                instance_type                                   = $InstanceType
                source_ami                                      = $AmiToPack.ImageId
                ami_name                                        = $NewAMIName
                temporary_iam_instance_profile_policy_document  = $TempInstanceProfilePolicy
                run_tags                                        = [PSCustomObject]@{
                    PackerBuildId = $PackerBuildId
                }
                aws_polling                                     = [PSCustomObject]@{
                    delay_seconds = $PackerPollDelaySeconds
                    max_attempts  = $PackerPollMaxAttempts
                }
            }
            $PackerTemplate = [PSCustomObject]@{
                builders = @($builders)
            }
        } else {
            # Build UserData for the Packer Template
            if ($BaseOS -match '2012') {
                # UserData for EC2Config
                $UserDataFile = "$(Split-Path (Get-Module PackerBaseAMI).Path -Parent)\Private\UserDataEC2Config.xml"
            } elseif ($BaseOS -match '2016|2019') {
                # UserData for EC2Launch
                $UserDataFile = "$(Split-Path (Get-Module PackerBaseAMI).Path -Parent)\Private\UserDataEC2Launch.xml"
            } else {
                # UserData for EC2Launch V2
                $UserDataFile = "$(Split-Path (Get-Module PackerBaseAMI).Path -Parent)\Private\UserDataEC2LaunchV2.xml"
            }
            $builders = [PSCustomObject]@{
                type                  = "amazon-ebs"
                communicator          = "none"
                disable_stop_instance = "true"
                encrypt_boot          = $encrypt_boot
                region                = $Region
                Vpc_Id                = $vpcId
                Subnet_Id             = $subnetId
                instance_type         = $InstanceType
                source_ami            = $AmiToPack.ImageId
                ami_name              = $NewAMIName
                user_data_file        = $UserDataFile
            }
            $PackerTemplate = [PSCustomObject]@{
                builders = @($builders)
            }
        }

        if ($IsSsmBuild) {
            # Build the on-instance script before Packer launches anything, so a missing template or a
            # missing permission fails fast instead of after an instance is running. The scripts live
            # under Templates\ (not Private\, so the module does not dot-source them on import) and
            # are shipped verbatim: no backtick escaping, no here-string embedded in the module.
            $ModuleRoot = $MyInvocation.MyCommand.Module.ModuleBase
            try {
                $Orchestrator = Get-Content -Path (Join-Path $ModuleRoot 'Templates\Invoke-PackerBaseAMISysprep.ps1') -Raw -ErrorAction Stop
                $LauncherScript = Get-Content -Path (Join-Path $ModuleRoot 'Templates\Invoke-PackerBaseAMISysprepLauncher.ps1') -Raw -ErrorAction Stop
                $XamlStubScript = Get-Content -Path (Join-Path $ModuleRoot 'Templates\Register-XamlPackages.ps1') -Raw -ErrorAction Stop
            } catch {
                throw "Cannot read the PackerBaseAMI sysprep templates under $ModuleRoot\Templates ($($_.Exception.Message)). Reinstall the module."
            }
            if ([string]::IsNullOrWhiteSpace($Orchestrator) -or [string]::IsNullOrWhiteSpace($LauncherScript) -or [string]::IsNullOrWhiteSpace($XamlStubScript)) {
                throw "A PackerBaseAMI sysprep template under $ModuleRoot\Templates is empty. Reinstall the module."
            }
            $Orchestrator = $Orchestrator.
                Replace('__SYSPREP_CONTEXT__', $SysprepExecutionContext).
                Replace('__BUILD_ID__', $PackerBuildId).
                Replace('__INSTALL_XAML__', $(if ($InstallXamlLogonMitigation) { 'True' } else { 'False' })).
                Replace('__LAUNCHER_B64__', [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($LauncherScript))).
                Replace('__XAML_STUB_B64__', [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($XamlStubScript)))
            if ($Orchestrator -cmatch '__[A-Z_]+__') {
                throw "Unreplaced placeholder $($Matches[0]) in the sysprep orchestrator template."
            }

            # The orchestrator with the embedded launcher and stub is ~58 KB. Gzip+base64 it (to ~27 KB)
            # to keep the Run Command request small, and send a tiny bootstrap that decompresses and
            # runs it in-process, so `exit 3010`/`exit 0`/`exit 1` still propagate to the Run Command
            # (verified: `& [ScriptBlock]::Create()` preserves the exit code under -File).
            $memStream = New-Object System.IO.MemoryStream
            $gzipStream = New-Object System.IO.Compression.GZipStream($memStream, [System.IO.Compression.CompressionMode]::Compress)
            $orchBytes = [System.Text.Encoding]::UTF8.GetBytes($Orchestrator)
            $gzipStream.Write($orchBytes, 0, $orchBytes.Length)
            $gzipStream.Close()
            $OrchestratorPayload = [Convert]::ToBase64String($memStream.ToArray())
            $memStream.Dispose()

            $Bootstrap = @"
`$ErrorActionPreference = 'Stop'
`$PBA_Payload = '$OrchestratorPayload'
`$PBA_ms = New-Object System.IO.MemoryStream(,[Convert]::FromBase64String(`$PBA_Payload))
`$PBA_gz = New-Object System.IO.Compression.GZipStream(`$PBA_ms, [System.IO.Compression.CompressionMode]::Decompress)
`$PBA_sr = New-Object System.IO.StreamReader(`$PBA_gz, [System.Text.Encoding]::UTF8)
`$PBA_code = `$PBA_sr.ReadToEnd()
`$PBA_sr.Dispose(); `$PBA_gz.Dispose(); `$PBA_ms.Dispose()
& ([ScriptBlock]::Create(`$PBA_code))
# Every orchestrator path ends in an explicit exit; reaching this line means it did not run.
Write-Output 'PackerBaseAMI: the sysprep orchestrator returned without an exit code.'
exit 1
"@
            $SysprepCommands = [string[]]($Bootstrap -split '\r?\n')
            Write-Output "Sysprep orchestration payload: $([math]::Round(($SysprepCommands -join "`n").Length / 1KB, 1)) KB (compressed)."

            # Fail fast if the role cannot read Run Command results: without ssm:ListCommandInvocations
            # the build cannot confirm Sysprep succeeded and would terminate the instance minutes in.
            # -NoAutoIteration: in AWS.Tools, -MaxResult is only the page size, and the cmdlet would
            # otherwise page through every invocation in the account (and get throttled).
            try {
                $null = Get-SSMCommandInvocation @AwsCredentialParams -Region $Region -MaxResult 1 -NoAutoIteration -ErrorAction Stop
            } catch {
                if ("$($_.Exception.ErrorCode) $($_.Exception.Message) $($_.Exception.InnerException.Message)" -match 'AccessDenied|UnauthorizedOperation|not authorized') {
                    throw "The IAM role '$IamRole' cannot call ssm:ListCommandInvocations, which Windows Server 2022/2025 builds need to confirm Sysprep succeeded: $($_.Exception.Message)"
                }
                Write-Warning "Could not verify ssm:ListCommandInvocations before the build: $($_.Exception.Message)"
            }
            Write-Output "Packer will wait up to $([math]::Round($PackerStopWaitSeconds / 60)) minutes for the instance to stop (credentials valid for $([math]::Round($CredentialSeconds / 60)) minutes)."
        }

        # Export the Packer Template to a JSON file
        $PackerTemplate | ConvertTo-Json -Depth 10 | Out-File $OutputDirectoryPath\temptemplate.json -Encoding default -Force
        $PackerTemplateJsonFilePath = (Get-Item $OutputDirectoryPath\temptemplate.json).FullName

        # Find Packer Executable
        $PackerExecutable = (Get-PackerExecutable).FullName
        # Load amazon-ebs plugin
        $PackerArgs = "plugins install `"github.com/hashicorp/amazon`""
        Write-Output "Installing Packer amazon plugin..."
        $PackerPluginProcess = Start-Process -FilePath $PackerExecutable `
            -ArgumentList $PackerArgs `
            -RedirectStandardOutput "$OutputDirectoryPath\PluginInstall-$RunDateTime-Log.txt" `
            -RedirectStandardError "$OutputDirectoryPath\PluginInstall-$RunDateTime-Errors.txt" `
            -PassThru -WindowStyle Hidden;
        $PackerPluginProcess | Wait-Process

        # Run Packer
        Write-Output "Starting Packer Process using Template: $PackerTemplateJsonFilePath"
        if ($debugMode) {
            Write-Output "Debug Mode Enabled"
            $PackerArgs = "build -debug $PackerTemplateJsonFilePath"
            $PackerProcess = Start-Process -FilePath $PackerExecutable `
            -ArgumentList $PackerArgs `
            -PassThru;
        } else {
            $PackerArgs = "build $PackerTemplateJsonFilePath"
            $PackerProcess = Start-Process -FilePath $PackerExecutable `
            -ArgumentList $PackerArgs `
            -RedirectStandardOutput "$OutputDirectoryPath\$NewAMIName-$RunDateTime-Log.txt" `
            -RedirectStandardError "$OutputDirectoryPath\$NewAMIName-$RunDateTime-Errors.txt" `
            -PassThru -WindowStyle Hidden;
        }
        
        if ($PackerProcess) { $null = $PackerProcess.Handle }   # cache the handle so ExitCode is readable after Packer exits (Windows PowerShell 5.1)
        Write-Output "Packer Process ID: $($PackerProcess.Id)"
        Write-Output "Logfiles will be prefixed with $NewAMIName-$RunDateTime and located in $((Get-Item $OutputDirectoryPath).FullName)"

        if ($IsSsmBuild) {
            # Microsoft does not support running Sysprep as Local System, and on Server 2025 doing
            # so silently skips AppX registration for certain XAML packages, so instances launched
            # from the AMI have a broken Start menu / Explorer / Settings:
            # https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/sysprep-as-system-windows-11
            # SSM Run Command runs as SYSTEM, so instead of calling ec2launch sysprep directly we
            # send an orchestrator that runs Sysprep under the built-in Administrator, verifies the
            # image actually generalized, and reports Success/Failed before the instance shuts down.
            # It still removes the installEgpuManager task (needs wmic.exe, gone in Server 2025).
            Write-Output "Server 2022/2025 detected. Sysprep will run as the built-in Administrator ($SysprepExecutionContext)..."

            # FAIL CLOSED: unless the Run Command positively reports Success, the finally block below
            # terminates the build instance so Packer halts without registering an AMI. It terminates
            # first and reports second, so a caller running with ErrorActionPreference = 'Stop' (for
            # example a GitHub Actions pwsh step) cannot skip the termination.
            $instanceId = $null
            $sysprepSucceeded = $false
            $failureReason = 'the Run Command result could not be confirmed'
            $ssmCommand = $null
            try {
                # Wait for the Packer instance to launch and find it by the build tag
                Write-Output "Waiting for Packer instance to launch..."
                $instanceTimeout = (Get-Date).AddMinutes(5)
                while (-not $instanceId -and (Get-Date) -lt $instanceTimeout) {
                    Start-Sleep -Seconds 10
                    # Packer can fail before launching anything (e.g. the AMI name already exists).
                    if ($PackerProcess -and $PackerProcess.HasExited) { break }
                    try {
                        $reservation = Get-EC2Instance @AwsCredentialParams -Region $Region -Filter @(
                            @{Name = "tag:PackerBuildId"; Values = @($PackerBuildId)},
                            @{Name = "instance-state-name"; Values = @("running")}
                        ) -ErrorAction Stop
                        if ($reservation.Instances) {
                            $instanceId = $reservation.Instances[0].InstanceId
                        }
                    } catch {
                        Write-Verbose "Get-EC2Instance failed, retrying: $($_.Exception.Message)"
                    }
                }

                if (-not $instanceId) {
                    if ($PackerProcess -and $PackerProcess.HasExited) {
                        $PackerLog = "$OutputDirectoryPath\$NewAMIName-$RunDateTime-Log.txt"
                        Write-Warning "Packer exited (exit code $($PackerProcess.ExitCode)) before launching the build instance. Last lines of $($PackerLog):"
                        Get-Content -Path $PackerLog -Tail 15 -ErrorAction SilentlyContinue | ForEach-Object { Write-Warning $_ }
                    } else {
                        Write-Warning "Could not find Packer instance within timeout. Check Packer logs for errors."
                    }
                    Write-Error "No build instance was found for PackerBuildId $PackerBuildId, so Sysprep was not run and no AMI will be created."
                    return
                }
                Write-Output "Found Packer instance: $instanceId"

                # Wait for SSM Agent to come online
                Write-Output "Waiting for SSM Agent to register..."
                $ssmReady = $false
                $ssmTimeout = (Get-Date).AddMinutes(10)
                while (-not $ssmReady -and (Get-Date) -lt $ssmTimeout) {
                    Start-Sleep -Seconds 5
                    try {
                        $ssmInfo = Get-SSMInstanceInformation @AwsCredentialParams -Region $Region `
                            -InstanceInformationFilterList @{Key = "InstanceIds"; ValueSet = @($instanceId)} -ErrorAction Stop
                        if ($ssmInfo -and $ssmInfo.PingStatus -eq "Online") {
                            $ssmReady = $true
                        }
                    } catch {
                        # SSM not ready yet, retry
                    }
                }

                if (-not $ssmReady) {
                    $failureReason = 'the SSM Agent did not come online within 10 minutes'
                    return
                }
                Write-Output "SSM Agent online. Sending sysprep orchestration script..."

                # executionTimeout must cover the on-instance waits and survive the exit-3010 reboot in
                # InteractiveAutoLogon mode; there is no point running longer than Packer will wait.
                try {
                    $ssmCommand = Send-SSMCommand @AwsCredentialParams -Region $Region `
                        -InstanceId @($instanceId) `
                        -DocumentName "AWS-RunPowerShellScript" `
                        -Comment "PackerBaseAMI sysprep $PackerBuildId" `
                        -Parameter @{
                            commands         = $SysprepCommands
                            executionTimeout = @([string]$PackerStopWaitSeconds)
                        } -ErrorAction Stop
                } catch {
                    $failureReason = "Send-SSMCommand failed: $($_.Exception.Message)"
                    return
                }
                if (-not $ssmCommand.CommandId) {
                    $failureReason = 'Send-SSMCommand returned no command ID'
                    return
                }

                Write-Output "SSM Command sent (ID: $($ssmCommand.CommandId))."
                Write-Output "On-instance logs: C:\ProgramData\Amazon\EC2Launch\log\PackerBaseAMI-SSM.log and PackerBaseAMI-SysprepIdentity.log"
                if ($SysprepExecutionContext -eq 'InteractiveAutoLogon') {
                    Write-Output "The instance will reboot once (one-shot autologon as Administrator) before Sysprep runs."
                }

                # Poll the Run Command to a terminal state (requires ssm:ListCommandInvocations).
                $terminalStatuses = @('Success', 'Failed', 'Cancelled', 'TimedOut')
                $invocation = $null
                $apiErrors = 0
                $pollSeconds = $PackerStopWaitSeconds + 300
                $pollTimeout = (Get-Date).AddSeconds($pollSeconds)
                $failureReason = "no terminal Run Command status within $([math]::Round($pollSeconds / 60)) minutes"
                while ((Get-Date) -lt $pollTimeout) {
                    Start-Sleep -Seconds 15
                    try {
                        $invocation = Get-SSMCommandInvocation @AwsCredentialParams -Region $Region `
                            -CommandId $ssmCommand.CommandId -InstanceId $instanceId -Detail $true -ErrorAction Stop
                        $apiErrors = 0
                    } catch {
                        if ("$($_.Exception.ErrorCode) $($_.Exception.Message) $($_.Exception.InnerException.Message)" -match 'AccessDenied|UnauthorizedOperation|not authorized') {
                            $failureReason = "the role cannot read the Run Command result (ssm:ListCommandInvocations is required): $($_.Exception.Message)"
                            break
                        }
                        # Do not silently loop forever on a persistent API error.
                        if ((++$apiErrors) -ge 8) {
                            $failureReason = "Get-SSMCommandInvocation failed $apiErrors times in a row: $($_.Exception.Message)"
                            break
                        }
                        continue
                    }
                    if ($invocation -and $invocation.Status.Value -in $terminalStatuses) { break }
                    if ($PackerProcess -and $PackerProcess.HasExited) {
                        $failureReason = "Packer exited (exit code $($PackerProcess.ExitCode)) before the Run Command finished, usually because its wait for the instance to stop timed out; see the Packer log"
                        break
                    }
                    try {
                        $instanceState = (Get-EC2Instance @AwsCredentialParams -Region $Region -InstanceId $instanceId -ErrorAction Stop).Instances[0].State.Name.Value
                    } catch {
                        Write-Verbose "Get-EC2Instance failed, retrying: $($_.Exception.Message)"
                        continue
                    }
                    if ($instanceState -in @('stopping', 'stopped', 'shutting-down', 'terminated')) {
                        # On success the orchestrator reports Success (exit 0) about 120 seconds before the
                        # scheduled power-off, so re-read the status once before deciding: this avoids
                        # terminating a build whose Success result is only just becoming readable.
                        try {
                            $invocation = Get-SSMCommandInvocation @AwsCredentialParams -Region $Region `
                                -CommandId $ssmCommand.CommandId -InstanceId $instanceId -Detail $true -ErrorAction Stop
                        } catch { Write-Verbose "Final Get-SSMCommandInvocation failed: $($_.Exception.Message)" }
                        $failureReason = "the instance reached '$instanceState' before the Run Command reported Success"
                        break
                    }
                }

                if ($invocation) {
                    Write-Output "Run Command status: $($invocation.Status.Value) ($($invocation.StatusDetails))"
                    $invocation.CommandPlugins | ForEach-Object { if ($_.Output) { Write-Output $_.Output } }
                }

                if ($invocation -and $invocation.Status.Value -eq 'Success') {
                    $sysprepSucceeded = $true
                    Write-Output "Verified on-instance: Sysprep ran as the built-in Administrator and the image is generalized."
                    Write-Output "Packer (PID: $($PackerProcess.Id)) is waiting for the instance to stop, then will create the AMI (roughly 10 minutes, 20 if encrypting). Follow progress in the Packer log."
                } elseif ($invocation -and $invocation.Status.Value -in $terminalStatuses) {
                    $failureReason = "the Run Command finished with status $($invocation.Status.Value)"
                }
            } finally {
                if (-not $sysprepSucceeded -and $instanceId) {
                    # Terminate first, report second (see FAIL CLOSED above).
                    $terminated = $false
                    try {
                        $null = Remove-EC2Instance @AwsCredentialParams -Region $Region -InstanceId $instanceId -Force -ErrorAction Stop
                        $terminated = $true
                    } catch {
                        Write-Warning "Failed to terminate build instance ${instanceId}: $($_.Exception.Message). Terminate it manually so it does not become an AMI."
                    }
                    $outcome = if ($terminated) { "Terminated build instance $instanceId so Packer halts without creating an AMI." } else { "Could not terminate build instance $instanceId." }
                    $details = if ($ssmCommand.CommandId) { " The full on-instance output is in the Systems Manager Run Command history (command ID $($ssmCommand.CommandId))." } else { '' }
                    Write-Error "Sysprep orchestration did not succeed: $failureReason. $outcome$details"
                }
            }
        } else {
            Write-Output "This process will take roughly 20 minutes to complete. 10 minutes if you chose not to encrypt."
        }
    }
    End {

    }
}
