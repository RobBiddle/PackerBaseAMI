<#
.Synopsis
    Obtains Temporary Credentials for AWS using an IAM Role
.DESCRIPTION
    Retrieves AWS Credentials from a stored profile and uses these to obtain temporary credentials for the specified AWS account, using the specified IAM Rolke.
    If a pofile name is not specified you will be prompted via an Out-Grid GUI selection box to pick from a list of your stored profiles.
    If no profile is found instructions for creating one will be printed to the screen.

    - AccountNumber (This is the AWS Account Number)
    - Alias (Human friendly name for the account)
    - AwsProfileName (Name of the stored AWS Credential Profile to use)
    - Region (Region used by accunt.  If more than one Region is in use add an additional complete entry for each account&region pair )
    - IamRole (This is the name of the AWS IAM Role to use with this account)
.EXAMPLE
    Get-AwsTemporaryCredential -AccountNumber 111111111111 -Alias ExampleFriendlyName -Region us-east-1 -IamRole ExampleRole -AwsProfileName ExampleProfileName 
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
function Get-AwsTemporaryCredential {
    Param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $false, ParameterSetName = "Set 1")]
        [String]
        $AccountNumber,
        [Parameter(Mandatory = $false, ValueFromPipelineByPropertyName = $false, ParameterSetName = "Set 1")]
        [String]
        $Alias = $Alias,
        [Parameter(Mandatory = $false, ValueFromPipelineByPropertyName = $false, ParameterSetName = "Set 1")]
        [String]
        $AwsProfileName = $AwsProfileName,
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $false, ParameterSetName = "Set 1")]
        [String]
        $Region,
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $false, ParameterSetName = "Set 1")]
        [String]
        $IamRole
    )
    function Get-MyAwsCredentials {
        param
        (
            [String]
            $AwsProfileName
        )     
        if (!($AwsProfileName)) {
            if ((Get-AWSCredentials -ListProfileDetail)) {
                if ((Get-AWSCredentials -ListProfileDetail).Count -GT 1) {
                    $AwsProfileName = (Get-AWSCredentials -ListProfileDetail).ProfileName | Out-GridView -Title "Choose an AWS Credential Profile" -PassThru
                }
                Else {
                    $AwsProfileName = (Get-AWSCredentials -ListProfileDetail).ProfileName[0]
                }
                $AwsProfile = Get-AWSCredentials -ProfileName $AwsProfileName
            }
            Else {
                if ([Environment]::UserInteractive) {
                    Write-Host "No stored AWS Access Key credentials were found!" -ForegroundColor Yellow
                    Write-Host "To add a new profile to the AWS SDK store, call Set-AWSCredentials as follows:" -ForegroundColor Yellow
                    Write-Host "Set-AWSCredentials -AccessKey AKIAIOSFODNN7EXAMPLE -SecretKey wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY -StoreAs MyProfileNam" -ForegroundColor Yellow
                    Return $null
                }
                Else { 
                    Write-Output "No stored AWS Access Key credentials were found!"
                    Write-Output "To add a new profile to the AWS SDK store, call Set-AWSCredentials as follows:"
                    Write-Output "Set-AWSCredentials -AccessKey AKIAIOSFODNN7EXAMPLE -SecretKey wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY -StoreAs MyProfileNam"
                    Throw "No stored AWS Access Key credentials were found!"
                }
            }
        }
        Else {
            $AwsProfile = Get-AWSCredentials -ProfileName $AwsProfileName
        }
        $Script:AwsAccessKey = $AwsProfile.GetCredentials().AccessKey
        $Script:AwsSecretKey = $AwsProfile.GetCredentials().SecretKey
        Write-Verbose "Your AWS Credentials have been stored in the following variables: "
        Write-Verbose 'VARIABLE: $AwsProfile - This is an AWS Credential Object'
        Write-Verbose 'VARIABLE: $AwsAccessKey - This is Your AccessKey as Plain Text String'
        Write-Verbose 'VARIABLE: $AwsSecretKey - This is Your SecretKey Plain Text String'
        Return $AwsProfile
    }

    if (!($Alias)) {
        $Alias = $AccountNumber
    }

    # Load stored credentials
    $AwsProfile = Get-MyAwsCredentials -AwsProfileName $AwsProfileName
    
    # Check if the credentials are of type AssumeRoleAWSCredentials
    if ($AwsProfile -is [Amazon.Runtime.AssumeRoleAWSCredentials]) {
        Write-Verbose "AssumeRoleAWSCredentials detected, skipping Initialize-AWSDefaults"
    } else {
        Initialize-AWSDefaults -Credential $AwsProfile
    }

    # Obtain Temporary Credentials
    $AwsTemporaryCredentials = New-Object -TypeName psobject
    $AwsTemporaryCredentials | Add-Member -MemberType NoteProperty -Name "AccountNumber" -Value $AccountNumber
    $AwsTemporaryCredentials | Add-Member -MemberType NoteProperty -Name "Region" -Value $Region
    $AwsTemporaryCredentials | Add-Member -MemberType NoteProperty -Name "RoleName" -Value $IamRole
    $AwsTemporaryCredentials | Add-Member -MemberType NoteProperty -Name "Credentials" -Value (Use-STSRole -RoleArn "arn:aws:iam::$($AccountNumber):role/$($IamRole)" -RoleSessionName "$($Alias)" -Credential $AwsProfile.SourceCredentials ).Credentials
    Return $AwsTemporaryCredentials
}
