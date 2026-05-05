# PackerBaseAMI

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
  - [Windows Server 2025 Requirements](#windows-server-2025-requirements)
    - [Networking requirements for Windows Server 2025 builds](#networking-requirements-for-windows-server-2025-builds)
    - [IAM permissions for Windows Server 2025 builds](#iam-permissions-for-windows-server-2025-builds)
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

## Windows Server 2025 Requirements

Windows Server 2025 removed the `wmic.exe` utility, which EC2Launch v2 depends on during instance initialization. This causes EC2Launch v2 to fail at its `preReady` stage, which prevents UserData from executing and stops the instance from shutting down after sysprep.

To work around this, the module uses a different build strategy for Windows Server 2025:

- **SSM Run Command** is used instead of UserData to execute commands on the instance
- After Packer launches the instance, the module waits for the SSM Agent to come online, then **removes the `installEgpuManager` task** from the EC2Launch v2 configuration — this is the specific task that depends on `wmic.exe`
- EC2Launch v2 then runs sysprep and shuts down the instance
- The Packer template uses `communicator = "none"` with `disable_stop_instance = "true"`, so Packer waits for the instance to shut down on its own after sysprep completes
- The instance is tagged with a unique `PackerBuildId` so the module can find it after launch

SSM Agent runs as an independent Windows service that starts on boot regardless of EC2Launch v2 status. The config change persists in the AMI, so instances launched from it will not hit the same issue. The `installEgpuManager` task is only relevant for Elastic Graphics (eGPU) instances and is safe to remove for standard workloads.

> **Note: the SSM Run Command will stay in "In Progress" until it times out — this is expected.** The last step of the SSM payload triggers `ec2launch.exe sysprep --shutdown=true`, which shuts down the OS (and the SSM Agent with it) before the agent can report completion to the Run Command API. SSM leaves the command in `InProgress` until its delivery timeout fires (default 1 hour) and then transitions it to `DeliveryTimedOut`. The actual success signal is the build instance reaching the `stopped` state and Packer creating the AMI from its root volume — not the Run Command status. This is a well-known consequence of running Send-SSMCommand payloads that reboot or shut down the target.

To make the SSM-based build self-contained, the module also:

- Attaches a **temporary IAM instance profile** to the build instance (created and deleted by Packer for the duration of the build) granting `ssm:*`, `ssmmessages:*`, and `ec2messages:*`. This removes the dependency on Default Host Management Configuration (DHMC) being enabled in the account.
- **Prefers a public subnet** when selecting where to launch the build instance, falling back to any subnet whose AZ supports the chosen instance type. This is so the SSM Agent has a network path to reach the SSM endpoints.
- Sets `associate_public_ip_address = "true"` so the build instance gets a public IP even if the subnet's default doesn't auto-assign one.

### Networking requirements for Windows Server 2025 builds

The build instance must be able to reach the SSM API endpoints (`ssm`, `ssmmessages`, `ec2messages` on port 443). The default behavior above (public subnet + public IP) satisfies this. If your VPC has only private subnets, you must provide one of:

- A NAT gateway with a route from the chosen subnet to it, or
- VPC endpoints for `com.amazonaws.<region>.ssm`, `com.amazonaws.<region>.ssmmessages`, and `com.amazonaws.<region>.ec2messages` reachable from the chosen subnet.

Older Windows Server versions (2022, 2019, 2016, 2012) build via UserData and do not require SSM reachability.

### IAM permissions for Windows Server 2025 builds

The IAM role used for the build must have the following permissions in addition to the existing EC2 and STS permissions:

SSM:

- `ssm:SendCommand`
- `ssm:DescribeInstanceInformation`

IAM (for the temporary instance profile Packer creates and deletes around the build):

- `iam:CreateRole`, `iam:DeleteRole`
- `iam:CreateInstanceProfile`, `iam:DeleteInstanceProfile`, `iam:GetInstanceProfile`
- `iam:PutRolePolicy`, `iam:DeleteRolePolicy`
- `iam:AddRoleToInstanceProfile`, `iam:RemoveRoleFromInstanceProfile`
- `iam:PassRole`

Older Windows Server versions (2022, 2019, 2016, 2012) are unaffected and do not require these additional permissions.

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
