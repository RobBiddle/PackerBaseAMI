<#
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
function Confirm-AwsModulesAreInstalled {
    $legacyAwsModule = 'AWSPowerShell'
    $requiredAwsModules = 'AWS.Tools.Common', 'AWS.Tools.EC2', 'AWS.Tools.SecurityToken', 'AWS.Tools.SimpleSystemsManagement'
    $StartingErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "silentlycontinue"
    $AwsModulesFound = $true
    $legacyAwsModuleFound = $false

    # Check for the legacy AWSPowerShell module
    if (Get-Module -ListAvailable -Name $legacyAwsModule) {
        $legacyAwsModuleFound = $true
        Write-Warning "The legacy AWSPowerShell module is installed.  It is recommended to use the AWS.Tools modules instead."
    }

    # Check for the required AWS.Tools modules
    if (-not $legacyAwsModuleFound) {
        foreach ($module in $requiredAwsModules) {
            if (-not (Get-Module -ListAvailable -Name $module)) {
                $AwsModulesFound = $false
                Throw "Module $module not found. Please install the required AWS.Tools modules from the PowerShell Gallery"
            }
        }
    }

    $ErrorActionPreference = $StartingErrorActionPreference
    Return $AwsModulesFound
}