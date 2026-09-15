# PackerBaseAMI

[![PowerShell Gallery Downloads](https://img.shields.io/powershellgallery/dt/PackerBaseAMI)](https://www.powershellgallery.com/packages/PackerBaseAMI/)

## Synopsis

> [PackerBaseAMI](https://github.com/RobBiddle/PackerBaseAMI) is a PowerShell module which automates the process of creating a Windows Base AMI for use with AWS EC2.

## Description

[PackerBaseAMI](https://github.com/RobBiddle/PackerBaseAMI) is a PowerShell module which automates the process of creating a Windows Base AMI for use with AWS EC2.

There are a few problems associated with utilizing the Amazon provided Base Windows AMI images:

1. The Amazon provided Base Windows AMI images are frequently deprecated and deregistered.
   - This causes problems if you are using those AMIs in CloudFormation stacks, as you may not be able to update the stack after the AMI is deregistered. This problem is resolved by creating an new AMI based on the Amazon provided image.
   - The AMI produced by this module will remain in your account until you choose to remove it.

2. The Amazon provided Base Windows AMI images cannot be directly copied via the AWS API (cli / Powershell)
   - The Amazon recommended process is a manual one utilizing the web console via a browser, which is highly inefficient and not well suited to automation

3. The Amazon provided Base Windows AMI images are not encrypted. They can't be encrypted as they are based on snapshots owned by Amazon, which means that Amazon would have to share their private encryption keys in order for customer to use their encrypted images, which would render the encryption useless.
   - The AMI produced by this module will encrypt the snapshot for the new AMI by default, using the master key associated with your AWS account.

Upon importing the module, a single PowerShell cmdlet named **New-PackerBaseAMI** is exported which makes use of [AWSPowerShell](https://www.powershellgallery.com/packages/AWSPowerShell)

## Table of Contents

- [PackerBaseAMI](#packerbaseami)
  - [Synopsis](#synopsis)
  - [Description](#description)
  - [Table of Contents](#table-of-contents)
  - [Install](#install)
  - [Windows Server 2022 / 2025 Requirements](#windows-server-2022--2025-requirements)
    - [Why Sysprep must not run as SYSTEM on Server 2025](#why-sysprep-must-not-run-as-system-on-server-2025)
    - [How the build runs Sysprep as the built-in Administrator](#how-the-build-runs-sysprep-as-the-built-in-administrator)
    - [Networking requirements for Windows Server 2022 / 2025 builds](#networking-requirements-for-windows-server-2022--2025-builds)
    - [IAM permissions for Windows Server 2022 / 2025 builds](#iam-permissions-for-windows-server-2022--2025-builds)
    - [Verifying a new Server 2025 AMI](#verifying-a-new-server-2025-ami)
    - [Repairing instances and AMIs already built](#repairing-instances-and-amis-already-built)
  - [GitHub Actions Usage](#github-actions-usage)
  - [Example](#example)
  - [Maintainer(s)](#maintainers)
  - [Contributing](#contributing)
  - [Credits](#credits)
  - [License](#license)
  - [Support](#support)

## Install

### Install PowerShell

I suggest using the latest version of [PowerShell](https://aka.ms/wmf5latest) if possible so that you can use PowerShellGet cmdlets.
Download the latest PowerShell here: <https://aka.ms/wmf5latest>

### Install Packer

You have two options:

1. Install [Packer](https://packer.io) from the main site: [https://packer.io](https://packer.io)
2. Or use Chocolatey to install Packer:
   - Install Chocolatey: [https://chocolatey.org/install](https://chocolatey.org/install)
   - Install Packer package via Chocolatey:

     ```PowerShell
     choco install packer
     ```

### Install [PackerBaseAMI](https://github.com/RobBiddle/PackerBaseAMI) & Requirements

(Assumes you have PowerShellGet and access to PowerShellGallery.com)

- [AWSPowerShell](https://www.powershellgallery.com/packages/AWSPowerShell) PowerShell Module

  ```PowerShell
  # If you want the old monolithic module:
  # Install-Module AWSPowerShell
  # Otherwise, if you want the new modularized modules with only the necessary cmdlets (recommended):
  Install-Module AWS.Tools.Common,AWS.Tools.EC2,AWS.Tools.SecurityToken,AWS.Tools.SimpleSystemsManagement
  ```

- [PackerBaseAMI](https://github.com/RobBiddle/PackerBaseAMI) PowerShell Module

  ```PowerShell
  Install-Module PackerBaseAMI
  ```

### Import the PackerBaseAMI module

```PowerShell
Import-Module PackerBaseAMI
```

## Windows Server 2022 / 2025 Requirements

Windows Server 2022 and 2025 use EC2Launch v2, whose first-boot `preReady` stage no longer runs UserData reliably (Server 2025 removed `wmic.exe`, which the `installEgpuManager` task depends on). So for 2022/2025 the module drives the build with **SSM Run Command** instead of UserData:

- The Packer template uses `communicator = "none"` with `disable_stop_instance = "true"`, so Packer just waits for the instance to reach the `stopped` state and then creates the AMI.
- The instance is tagged with a unique `PackerBuildId` so the module can find it after launch.
- After the SSM Agent comes online, the module sends an orchestration script that removes the `installEgpuManager` task (needs `wmic.exe`, gone in Server 2025), runs Sysprep **as the built-in Administrator**, verifies the image actually generalized, and reports back before shutdown.

### Why Sysprep must not run as SYSTEM on Server 2025

SSM `AWS-RunPowerShellScript` runs as `NT AUTHORITY\SYSTEM`. Microsoft does not support running Sysprep under the System account, and on Windows Server 2025 / Windows 11 24H2+ doing so **silently skips AppX registration for certain XAML packages**. The build succeeds and the AMI is created, but instances launched from it misbehave for users: the Start menu and Explorer crash and the Settings app fails to render. Crashes in the Office / Entra sign-in flow (which uses the Web Account Manager) have also been reported, although Microsoft's article does not list them. The symptoms can appear on first sign-in or later after a cumulative update. See Microsoft's article: <https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/sysprep-as-system-windows-11>.

Older Windows versions (2019, 2016, 2012) are not affected — they do not rely on these XAML packages — and they continue to build via UserData. Microsoft's "unsupported as Local System" guidance now spans Windows 10, Windows 11, and Windows Server 2022/2025, and there are field reports of Start-menu search breaking on Server 2022 instances built with a SYSTEM-context Sysprep, so **the module runs Sysprep as a non-SYSTEM administrator on both 2022 and 2025**.

### How the build runs Sysprep as the built-in Administrator

Because the Run Command itself is SYSTEM, the orchestration script hands Sysprep off to the built-in Administrator (RID 500). Two contexts are available, selected with `-SysprepExecutionContext`; if you do not specify one, the default is **`InteractiveAutoLogon` for Full (Desktop Experience) images of both 2022 and 2025**, and **`BatchLogon` for Core images**.

- **`InteractiveAutoLogon`** (default for Full images) — the context with a reported-working outcome on Server 2025. Pass 1 arms a one-shot `AutoAdminLogon` as the built-in Administrator, registers a `RunOnce` launcher, and reboots (via SSM `exit 3010`). After the reboot, pass 2 (SYSTEM) removes every autologon secret, restores the logon banner, and rotates the Administrator password; only then does the launcher start Sysprep in a **real interactive console session** as the Administrator, so the image can never be sealed with build-time autologon state. Pass 2 then confirms the result.
- **`BatchLogon`** (default for Core images; fallback for Full; not yet build-tested) — no reboot. This is AWS's own `AWSEC2-RunSysprep` pattern: a batch logon as the built-in Administrator (`LogonUser` + `LoadUserProfile` + `CreateProcessAsUser`) runs `ec2launch sysprep`. It is the default on Server Core, which has no Explorer shell for the `RunOnce` console launcher, and the fallback when `InteractiveAutoLogon` cannot work — for example an LSA-stored autologon password or an Exchange ActiveSync password policy that blocks autologon. (A `LegalNotice` logon banner does **not** require the fallback: the interactive path clears it for the one-shot autologon and restores it before Sysprep, so the banner is unchanged in the AMI.)

In both contexts the orchestration:

- waits until the image is genuinely ready to Sysprep (`ImageState = IMAGE_STATE_COMPLETE`, no servicing in progress, no pending reboot) before starting. In `InteractiveAutoLogon`, pass 1 leaves pending-reboot flags to its own reboot, and the launcher re-checks them afterwards;
- runs `ec2launch.exe sysprep --shutdown=false`, then **verifies the image generalized** (`ImageState = IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE`) before allowing the instance to shut down;
- checks that `sysprep.exe` ran as the built-in Administrator (never SYSTEM or any other account), and **fails the build** (killing the chain) otherwise;
- sets `CopyProfile = false` in the EC2Launch unattend file, so the build-time Administrator profile is not copied into the default profile of every future user. **This setting stays in the AMI**: if you later Sysprep an instance launched from it and rely on AWS's default `CopyProfile = true`, set it back in `C:\ProgramData\Amazon\EC2Launch\sysprep\unattend.xml` first;
- writes the evidence to `C:\ProgramData\Amazon\EC2Launch\log\PackerBaseAMI-SysprepIdentity.log` (markers, plus the `sysprep.exe` owner SID and session; the interactive path also records `whoami /all`), alongside the transcript `PackerBaseAMI-SSM.log` and the `ec2launch sysprep` output. These logs are kept in the image as a build record. The launcher script and the `C:\ProgramData\PackerBaseAMI` work folder are removed (the folder stays only with `-InstallXamlLogonMitigation`).

**Fail-closed:** the module polls the Run Command to a terminal state. Unlike earlier versions, the Run Command now finishes **`Success` or `Failed` before the instance shuts down**. Unless it positively reports `Success`, the module **terminates the build instance first and reports the error second**, so Packer halts without registering a broken or SYSTEM-sysprepped AMI. This covers a `Failed` result, a timeout, Packer exiting, an AWS API error, and an unreadable result. It also holds when the caller runs with `$ErrorActionPreference = 'Stop'` (for example a GitHub Actions `pwsh` step), where the error then fails the step. The full on-instance output is in the Systems Manager Run Command history under the command ID the module prints. On success, the instance powers off ~120 seconds later and Packer bakes the AMI.

**Build time budget:** with `communicator = "none"`, Packer starts waiting for the instance to stop as soon as it is running, and every later Packer step reuses the same temporary credentials. For 2022/2025 builds the module therefore requests a 4-hour role session and sizes Packer's wait (`aws_polling`) to the credential lifetime, keeping 30 minutes for AMI creation and encryption, with the wait bounded between 55 minutes and 3 hours. If the role's `MaxSessionDuration` is the default 1 hour, or the credentials come from role chaining, the module warns and falls back to a 1-hour session. Packer then keeps its previous 55-minute wait, which leaves little credential time for creating and encrypting the AMI, so a slow build can fail with `ExpiredToken`. Raise the role's maximum session duration to 4 hours to avoid this.

As before, to make the SSM-based build self-contained the module also attaches a **temporary IAM instance profile** granting `ssm:*`, `ssmmessages:*`, `ec2messages:*` (removing the dependency on Default Host Management Configuration), **prefers a public subnet**, and sets `associate_public_ip_address = "true"`.

> **Validated on Server 2022 and 2025.** Encrypted builds of `Windows_Server-2022-English-Full-Base` and `Windows_Server-2025-English-Full-Base` (`InteractiveAutoLogon`), and of `Windows_Server-2022-English-Core-Base` and `Windows_Server-2025-English-Core-Base` (`BatchLogon`), all completed with the Run Command reporting `Success`. In each, `sysprep.exe` was owned by the built-in Administrator (RID 500), never SYSTEM, and the image generalized. The builds took 37–58 minutes with a 1-hour role session. Earlier, on a fresh user profile on an instance launched from a Server 2025 Full AMI, the Start menu works and `MicrosoftWindows.Client.CBS`, `Microsoft.UI.Xaml.CBS`, and `MicrosoftWindows.Client.Core` all report `Status = Ok`. This also settled a point AWS documents ambiguously — whether `ec2launch.exe sysprep` runs `sysprep.exe` in the caller's session or hands it to the SYSTEM-context EC2Launch service: it runs in the caller's session. The orchestration still checks the owner of `sysprep.exe` and fails the build (producing no AMI) if it is ever SYSTEM; if you see `SYSPREP_OWNER_SYSTEM`, open an issue.

### Networking requirements for Windows Server 2022 / 2025 builds

The build instance must be able to reach the SSM API endpoints (`ssm`, `ssmmessages`, `ec2messages` on port 443). The default behavior above (public subnet + public IP) satisfies this. If your VPC has only private subnets, you must provide one of:

- A NAT gateway with a route from the chosen subnet to it, or
- VPC endpoints for `com.amazonaws.<region>.ssm`, `com.amazonaws.<region>.ssmmessages`, and `com.amazonaws.<region>.ec2messages` reachable from the chosen subnet.

Older Windows Server versions (2019, 2016, 2012) build via UserData and do not require SSM reachability.

### IAM permissions for Windows Server 2022 / 2025 builds

The IAM role used for the build must have the following permissions in addition to the existing EC2 and STS permissions:

SSM:

- `ssm:SendCommand`
- `ssm:DescribeInstanceInformation`
- `ssm:ListCommandInvocations` — **new in 1.1.6.** Used by `Get-SSMCommandInvocation` to poll the Run Command result so the build can fail closed. The module checks this permission before Packer starts and stops with a clear error if it is missing.

EC2 (for the fail-closed path):

- `ec2:TerminateInstances` — already part of Packer's minimal EBS policy; the module uses it to terminate the build instance if Sysprep did not succeed, so Packer registers no AMI.

IAM (for the temporary instance profile Packer creates and deletes around the build):

- `iam:CreateRole`, `iam:DeleteRole`
- `iam:CreateInstanceProfile`, `iam:DeleteInstanceProfile`, `iam:GetInstanceProfile`
- `iam:PutRolePolicy`, `iam:DeleteRolePolicy`
- `iam:AddRoleToInstanceProfile`, `iam:RemoveRoleFromInstanceProfile`
- `iam:PassRole`

Older Windows Server versions (2019, 2016, 2012) are unaffected and do not require these additional permissions.

### Verifying a new Server 2025 AMI

Because the "working build, broken instances" symptom is silent, verify a newly built Server 2025 AMI before trusting it. The most rigorous check builds two images from the same source AMI: image **A** with the old behavior (Sysprep as SYSTEM) and image **B** with this version, and confirms A reproduces the failure while B is clean — otherwise the test cannot tell the two apart.

On an instance launched from the AMI, sign in over RDP as the built-in Administrator, then as a **newly created** local user (the failure shows most clearly on fresh profiles), and check:

- `Get-AppxPackage MicrosoftWindows.Client.CBS, Microsoft.UI.Xaml.CBS, MicrosoftWindows.Client.Core | Format-Table Name, Version, Status` — all present with `Status = Ok`.
- The Start menu, taskbar search, and the Settings app open and render.
- The Office / Entra sign-in dialog completes without crashing.
- The Application event log has no `explorer.exe`, `StartMenuExperienceHost.exe`, `ShellHost.exe`, or `Microsoft.AAD.BrokerPlugin.exe` crash (event ID 1000) after first sign-in.
- The build record kept in the image, `C:\ProgramData\Amazon\EC2Launch\log\PackerBaseAMI-SysprepIdentity.log`, shows `SYSPREP_OWNER_OK` and `SYSPREP_GENERALIZED`, and an `OwnerSid` for `sysprep.exe` that is the built-in Administrator (ending in `-500`), **not** `S-1-5-18` (SYSTEM). An `InteractiveAutoLogon` build also shows `IDENTITY_OK` and a `whoami` for the Administrator; a `BatchLogon` build shows `BATCH_LAUNCHED`. The same evidence is in the build's Run Command output in Systems Manager.

Also confirm the AMI is usable at all: launch it with a key pair and confirm `Get-EC2PasswordData` returns the Administrator password and the console shows `Windows is ready`.

### Repairing instances and AMIs already built

Instances already built with the SYSTEM-context Sysprep can be repaired per user with Microsoft's remediation, which this module ships as `Templates\Register-XamlPackages.ps1`. Run it **in the affected user's own session** (AppX registration is per-user); it re-registers the three XAML packages (add `-IncludeBrokerPlugin` to also re-register the Office/Entra broker). If it registered anything it restarts the shell; add `-NoShellRestart` to skip that and sign out and back in instead:

```PowerShell
powershell.exe -ExecutionPolicy Bypass -File .\Register-XamlPackages.ps1 -IncludeBrokerPlugin
```

This fixes the current user, but a later cumulative update can re-trigger the problem, so the durable fix is to **rebuild the AMI** with this version. When building, you can also pass `-InstallXamlLogonMitigation` to bake into the AMI a per-user logon task that runs the same registration on every sign-in (defense in depth). The task only acts on Server 2025 Desktop Experience and stays idle while the build itself is running Sysprep. It runs alongside the shell rather than before it, so a user whose packages needed repair sees the shell restart once. It is **off by default**, so you can first confirm that the Sysprep-context change alone resolves the issue.

## GitHub Actions Usage

No special setup is required for GitHub Actions. The module handles the SSM Run Command internally using the same AWS credentials configured for the workflow:

```yaml
jobs:
  build-ami:
    runs-on: ubuntu-latest
    steps:
      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::123456789012:role/YourRole
          aws-region: us-east-1

      - name: Install Packer
        uses: hashicorp/setup-packer@main

      - name: Build AMI
        shell: pwsh
        run: |
          Install-Module AWS.Tools.Common,AWS.Tools.EC2,AWS.Tools.SecurityToken,AWS.Tools.SimpleSystemsManagement -Force
          Install-Module PackerBaseAMI -Force
          Import-Module PackerBaseAMI
          New-PackerBaseAMI -AccountNumber '111111111111' -BaseOS 'Windows_Server-2025-English-Full-Base' -IamRole 'YourRole' -Region 'us-east-1'
```

## Example

```PowerShell
New-PackerBaseAMI -AccountNumber '111111111111' -Alias ExampleAlias -BaseOS 'Windows_Server-2025-English-Full-Base' -IamRole 'ExampleRoleName' -Region 'us-east-1' -InstanceType 't3.medium' -OutputDirectoryPath 'c:\example\directory'
```

## Maintainer(s)

[Robert D. Biddle](https://github.com/RobBiddle) - <https://github.com/RobBiddle>

## Contributing

1. Fork it!
2. Create your feature branch: `git checkout -b my-new-feature`
3. Commit your changes: `git commit -am 'Add some feature'`
4. Push to the branch: `git push origin my-new-feature`
5. Create Issues / Submit a pull request

## Credits

- [Upic Solutions](https://upicsolutions.org/) for sponsoring my time to develop this project. This code is being used as part of our mission to help [United Ways](https://www.unitedway.org/) be the best community solution leaders, in an increasingly competitive environment, by providing state of the art business and technology solutions
- [Hashicorp](https://www.hashicorp.com/) for creating [Packer](https://packer.io) and other fantastic open source projects
- The [AWSPowerShell](https://www.powershellgallery.com/packages/AWSPowerShell) Devs for supporting all of us PowerShell users

## License

GNU General Public License v3.0
<https://github.com/RobBiddle/PackerBaseAMI/LICENSE.txt>

## Support

- Please :star:Star this repo if you found some of this code useful!
- If you're an unbelievably nice person and want to show your appreciation, I like beer ;-)
  - Send me :beer: money via LTC: MHJj5jaWFU2VeqEZXnLC4xaZdQ1Nu9NC48
  - Send me :beer: money via BTC: 38ieXk9rn2LJEsfimFWiyycUZZv5ABJPqM
  - Send me :beer: money via USD: <https://paypal.me/RobertBiddle>
