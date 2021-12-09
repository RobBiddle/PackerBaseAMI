<#
.Synopsis
    Create a Windows Base AMI using Packer, Encrypted by default
.DESCRIPTION
    Create a Windows Base AMI using Packer, Encrypted by default
.EXAMPLE
   New-PackerBaseAMI -AccountNumber '111111111111' -Alias 'ExampleAlias' -BaseOS 'Windows_Server-2019-English-Full-Base' -IamRole 'ExampleRoleName' -Region 'us-east-1' -OutputDirectoryPath 'c:\example\directory'
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
        $BaseOS = 'Windows_Server-2022-English-Full-Base',

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
        $AwsProfileName = $AwsProfileName
    )

    Begin {
        Confirm-PackerIsInstalled | Out-Null
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
        if (Get-Command Get-EC2ImageByName -ErrorAction SilentlyContinue) {
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
        $subnetId = (Get-EC2Subnet @AwsCredentialParams  -Region $Region | Where-Object VpcId -eq $vpcId | Select-Object -First 1).SubnetId
        if ($DoNotEncrypt) {
            $encrypt_boot = "false"
        }
        else {
            $encrypt_boot = "true"
        }

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

        # Build the Packer Template
        $builders = [PSCustomObject]@{
            type                  = "amazon-ebs"
            communicator          = "none"
            disable_stop_instance = "true"
            encrypt_boot          = $encrypt_boot
            region                = $Region
            Vpc_Id                = $vpcId
            Subnet_Id             = $subnetId
            instance_type         = "t2.medium"
            source_ami            = $AmiToPack.ImageId
            ami_name              = $NewAMIName
            user_data_file        = $UserDataFile
        }
        $PackerTemplate = [PSCustomObject]@{
            builders = @($builders)
        }

        # Export the Packer Template to a JSON file
        $PackerTemplate | ConvertTo-Json -Depth 10 | Out-File $OutputDirectoryPath\temptemplate.json -Encoding default -Force
        $PackerTemplateJsonFilePath = (Get-Item $OutputDirectoryPath\temptemplate.json).FullName

        # Run Packer
        Write-Output "Starting Packer Process using Template: $PackerTemplateJsonFilePath"
        $PackerArgs = "build $PackerTemplateJsonFilePath"
        $PackerProcess = Start-Process -FilePath (Get-PackerExecutable).FullName `
            -ArgumentList $PackerArgs `
            -RedirectStandardOutput "$OutputDirectoryPath\$NewAMIName-$RunDateTime-Log.txt" `
            -RedirectStandardError "$OutputDirectoryPath\$NewAMIName-$RunDateTime-Errors.txt" `
            -PassThru -WindowStyle Hidden;
        Write-Output "Packer Process ID: $($PackerProcess.Id)"
        Write-Output "Logfiles will be prefixed with $NewAMIName-$RunDateTime and located in $((Get-Item $OutputDirectoryPath).FullName)"
        Write-Output "This process will take roughly 20 minutes to compete.  10 minutes if you chose not to encrypt."
    }
    End {

    }
}
