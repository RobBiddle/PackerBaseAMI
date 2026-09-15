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
        # not support running Sysprep as Local System (broken Start menu / Explorer / Settings /
        # Office sign-in from a skipped XAML AppX registration):
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

        # Windows Server 2025 only: also bake a per-user logon task into the AMI that re-registers
        # the affected XAML packages on every sign-in (Microsoft's remediation), as defense in
        # depth against a residual skip or a future cumulative update. Off by default.
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
        # Get Temporary AWS Credentials via IAM Switch Role process
        $GetTemporaryCredentials_Params = @{
            AccountNumber = $AccountNumber
            Alias         = $Alias
            Region        = $Region
            IamRole       = $IamRole
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
        if ($BaseOS -match '2022|2025') {
            # Windows Server 2025 removed wmic.exe which EC2Launch v2 depends on, and
            # newer EC2Launch v2 / Server 2022 base AMIs hit the same class of preReady
            # failure that prevents UserData (and therefore sysprep) from running.
            # Use SSM Run Command after Packer launches the instance to patch the
            # EC2Launch v2 config and trigger sysprep directly, bypassing UserData entirely.
            $PackerBuildId = [guid]::NewGuid().ToString()
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
                    delay_seconds = 10
                    max_attempts  = 330
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
            -ArgumentList $PackerArgs;
        } else {
            $PackerArgs = "build $PackerTemplateJsonFilePath"
            $PackerProcess = Start-Process -FilePath $PackerExecutable `
            -ArgumentList $PackerArgs `
            -RedirectStandardOutput "$OutputDirectoryPath\$NewAMIName-$RunDateTime-Log.txt" `
            -RedirectStandardError "$OutputDirectoryPath\$NewAMIName-$RunDateTime-Errors.txt" `
            -PassThru -WindowStyle Hidden;
        }
        
        Write-Output "Packer Process ID: $($PackerProcess.Id)"
        Write-Output "Logfiles will be prefixed with $NewAMIName-$RunDateTime and located in $((Get-Item $OutputDirectoryPath).FullName)"

        if ($BaseOS -match '2022|2025') {
            # Microsoft does not support running Sysprep as Local System, and on Server 2025 doing
            # so silently skips AppX registration for certain XAML packages, so instances launched
            # from the AMI have a broken Start menu / Explorer / Settings and crashing Office
            # sign-in:
            # https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/sysprep-as-system-windows-11
            # SSM Run Command runs as SYSTEM, so instead of calling ec2launch sysprep directly we
            # send an orchestrator that runs Sysprep under the built-in Administrator, verifies the
            # image actually generalized, and reports Success/Failed before the instance shuts down.
            # It still removes the installEgpuManager task (needs wmic.exe, gone in Server 2025).

            # Default the Sysprep context unless the caller chose one. Microsoft's unsupported
            # "Sysprep as Local System" guidance now spans Windows 10/11 and Server 2022/2025, so
            # both 2022 and 2025 run Sysprep as the built-in Administrator. Full (Desktop
            # Experience) images use the interactive console context; Core images fall back to the
            # batch context, which does not need an Explorer shell for the launcher.
            if (-not $SysprepExecutionContext) {
                $SysprepExecutionContext = if ($BaseOS -match 'Core') { 'BatchLogon' } else { 'InteractiveAutoLogon' }
            }
            Write-Output "Server 2022/2025 detected. Sysprep will run as the built-in Administrator ($SysprepExecutionContext)..."

            # Wait for the Packer instance to launch and find it by the build tag
            Write-Output "Waiting for Packer instance to launch..."
            $instanceId = $null
            $ssmTimeout = (Get-Date).AddMinutes(5)
            while (-not $instanceId -and (Get-Date) -lt $ssmTimeout) {
                Start-Sleep -Seconds 10
                $reservation = Get-EC2Instance @AwsCredentialParams -Region $Region -Filter @(
                    @{Name = "tag:PackerBuildId"; Values = @($PackerBuildId)},
                    @{Name = "instance-state-name"; Values = @("running")}
                )
                if ($reservation.Instances) {
                    $instanceId = $reservation.Instances[0].InstanceId
                }
            }

            if (-not $instanceId) {
                Write-Warning "Could not find Packer instance within timeout. Check Packer logs for errors."
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
                        -InstanceInformationFilterList @{Key = "InstanceIds"; ValueSet = @($instanceId)}
                    if ($ssmInfo -and $ssmInfo.PingStatus -eq "Online") {
                        $ssmReady = $true
                    }
                } catch {
                    # SSM not ready yet, retry
                }
            }

            if (-not $ssmReady) {
                Write-Warning "SSM Agent did not come online within timeout. Check instance: $instanceId"
                return
            }
            Write-Output "SSM Agent online. Sending sysprep orchestration script..."

            # Build the on-instance script from the module's template files. The scripts live under
            # Templates\ (not Private\, so the module manifest does not dot-source them on import),
            # and are shipped verbatim: no backtick escaping, no here-string embedded in the module.
            # SSM writes the "commands" lines into a single .ps1 on the instance, so functions,
            # here-strings and exit codes all behave normally.
            $ModuleRoot = Split-Path (Get-Module PackerBaseAMI).Path -Parent
            $Orchestrator = Get-Content -Path (Join-Path $ModuleRoot 'Templates\Invoke-PackerBaseAMISysprep.ps1') -Raw
            $LauncherB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
                    (Get-Content -Path (Join-Path $ModuleRoot 'Templates\Invoke-PackerBaseAMISysprepLauncher.ps1') -Raw)))
            $XamlStubB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
                    (Get-Content -Path (Join-Path $ModuleRoot 'Templates\Register-XamlPackages.ps1') -Raw)))
            $Orchestrator = $Orchestrator.
                Replace('__SYSPREP_CONTEXT__', $SysprepExecutionContext).
                Replace('__BUILD_ID__', $PackerBuildId).
                Replace('__INSTALL_XAML__', $(if ($InstallXamlLogonMitigation) { 'True' } else { 'False' })).
                Replace('__LAUNCHER_B64__', $LauncherB64).
                Replace('__XAML_STUB_B64__', $XamlStubB64)

            # The orchestrator plus the embedded launcher/stub is ~65 KB, which would approach the
            # 64 KB SSM document limit once JSON-encoded. Gzip+base64 it (to ~23 KB) and send a
            # tiny bootstrap that decompresses and runs it in-process, so `exit 3010`/`exit 0`/
            # `exit 1` still propagate to the Run Command (verified: `& [ScriptBlock]::Create()`
            # preserves the exit code).
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
"@
            $SysprepCommands = [string[]]($Bootstrap -split '\r?\n')
            Write-Output "Sysprep orchestration payload: $([math]::Round(($SysprepCommands -join "`n").Length / 1KB, 1)) KB (compressed)."

            # executionTimeout must exceed the on-instance waits, and survive the exit-3010 reboot
            # in InteractiveAutoLogon mode (readiness + reboot + autologon + generalize).
            $ssmCommand = Send-SSMCommand @AwsCredentialParams -Region $Region `
                -InstanceId @($instanceId) `
                -DocumentName "AWS-RunPowerShellScript" `
                -Comment "PackerBaseAMI sysprep $PackerBuildId" `
                -Parameter @{
                    commands         = $SysprepCommands
                    executionTimeout = @('10800')
                }

            Write-Output "SSM Command sent (ID: $($ssmCommand.CommandId))."
            Write-Output "On-instance logs: C:\ProgramData\Amazon\EC2Launch\log\PackerBaseAMI-SSM.log and PackerBaseAMI-SysprepIdentity.log"
            if ($SysprepExecutionContext -eq 'InteractiveAutoLogon') {
                Write-Output "The instance will reboot once (one-shot autologon as Administrator) before Sysprep runs."
            }

            # Poll the Run Command to a terminal state. This lets the build FAIL CLOSED: if Sysprep
            # did not run correctly as the built-in Administrator we terminate the instance so Packer
            # halts without registering an AMI, rather than baking a broken or SYSTEM-sysprepped one.
            # Requires ssm:ListCommandInvocations (for Get-SSMCommandInvocation) in addition to
            # ssm:SendCommand; ec2:TerminateInstances is already in Packer's minimal policy.
            $terminalStatuses = @('Success', 'Failed', 'Cancelled', 'TimedOut')
            $invocation = $null
            $apiErrors = 0
            $pollTimeout = (Get-Date).AddMinutes(185)
            while ((Get-Date) -lt $pollTimeout) {
                Start-Sleep -Seconds 15
                try {
                    $invocation = Get-SSMCommandInvocation @AwsCredentialParams -Region $Region `
                        -CommandId $ssmCommand.CommandId -InstanceId $instanceId -Detail $true
                    $apiErrors = 0
                } catch {
                    # Do not silently loop forever if e.g. ssm:ListCommandInvocations is missing.
                    if ((++$apiErrors) -ge 8) {
                        Write-Warning "Get-SSMCommandInvocation failed $apiErrors times ($($_.Exception.Message)); stopping polling."
                        break
                    }
                    continue
                }
                if ($invocation -and $invocation.Status.Value -in $terminalStatuses) { break }
                $instanceState = (Get-EC2Instance @AwsCredentialParams -Region $Region -InstanceId $instanceId).Instances[0].State.Name.Value
                if ($instanceState -in @('stopping', 'stopped', 'terminated')) {
                    # On success the orchestrator reports Success (exit 0) and only then schedules a
                    # delayed shutdown, so re-read the status once before deciding: the instance can
                    # reach 'stopping' just as a Success result becomes readable. This avoids
                    # terminating a build that actually succeeded.
                    try {
                        $invocation = Get-SSMCommandInvocation @AwsCredentialParams -Region $Region `
                            -CommandId $ssmCommand.CommandId -InstanceId $instanceId -Detail $true
                    } catch { Write-Verbose "Final Get-SSMCommandInvocation failed: $($_.Exception.Message)" }
                    break
                }
            }

            if ($invocation) {
                Write-Output "Run Command status: $($invocation.Status.Value) ($($invocation.StatusDetails))"
                $invocation.CommandPlugins | ForEach-Object { if ($_.Output) { Write-Output $_.Output } }
            }

            if ($invocation -and $invocation.Status.Value -eq 'Success') {
                Write-Output "Verified on-instance: Sysprep ran as the built-in Administrator and the image is generalized."
                Write-Output "Packer (PID: $($PackerProcess.Id)) is waiting for shutdown, then will create the AMI."
            } else {
                $why = if ($invocation) { $invocation.Status.Value } else { 'unconfirmed' }
                Write-Error "Sysprep orchestration did not succeed ($why). Terminating build instance $instanceId so Packer halts without creating an AMI. Review C:\ProgramData\Amazon\EC2Launch\log\PackerBaseAMI-SysprepIdentity.log (retrieve by attaching the root volume to a helper instance)."
                try {
                    Remove-EC2Instance @AwsCredentialParams -Region $Region -InstanceId $instanceId -Force | Out-Null
                } catch {
                    Write-Warning "Failed to terminate instance ${instanceId}: $($_.Exception.Message). Terminate it manually so it does not become an AMI."
                }
            }
        }

        Write-Output "This process will take roughly 20 minutes to complete. 10 minutes if you chose not to encrypt."
    }
    End {

    }
}
