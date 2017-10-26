# PackerBaseAMI
#### Synopsis
>[PackerBaseAMI](https://github.com/RobBiddle/PackerBaseAMI) is a PowerShell module which automates the process of creating a Windows Base AMI for use with AWS EC2.

#### Description
[PackerBaseAMI](https://github.com/RobBiddle/PackerBaseAMI) is a PowerShell module which automates the process of creating a Windows Base AMI for use with AWS EC2.

There are a few problems associated with utilizing the Amazon provided Base Windows AMI images:

1. The Amazon provided Base Windows AMI images are frequently depricated and deregistered.
   - This causes problems if you are using those AMIs in CloudFormation stacks, as you may not be able to update the stack after the AMI is deregistered.  This problem is resolved by creating an new AMI based on the Amazon provided image.
   - The AMI produced by this module will remain in your account until you choose to remove it.

2. The Amazon provided Base Windows AMI images cannot be directly copied via the AWS API (cli / Powershell)
   - The Amazon recommended process is a manual one utilizing the web console via a browser, which is highly inefficient and not well suited to automation

3. The Amazon provided Base Windows AMI images are not encrypted. They can't be encrypted as they are based on snapshots owned by Amazon, which means that Amazon would have to share their private encryption keys in order for customer to use their encrypted images, which would render the encryption usless.
   - The AMI produced by this module will encrypt the snapshot for the new AMI by default, using the master key associated with your AWS account.

Upon importing the module, a single PowerShell cmdlet named **New-PackerBaseAMI** is exported which makes use of [AWSPowerShell](https://www.powershellgallery.com/packages/AWSPowerShell)

#### Table of Contents
- [Install](/#Install)
- [Example](/#Example)
- [Maintainer\(s\)](/#Maintainer)
- [Contributing](/#Contributing)
- [Credits](Credits)
- [License](License)

#### Install <a name="Install"></a>
- ##### Install PowerShell
  I suggest using the latest verison of [PowerShell](https://aka.ms/wmf5latest) if possible so that you can use PowerShellGet cmdlets
  Download the latest PowerShell here: https://aka.ms/wmf5latest

- ##### Install Packer
  You have two options:
   1. Install [Packer](https://packer.io) from the main site: [https://packer.io](https://packer.io)
   2. Or use Chocolatey to install Packer:
     * Install Chocolatey: [https://chocolatey.org/install](https://chocolatey.org/install)
     * Install Packer package via Chocolatey: 
        ```PowerShell
        choco install packer
        ```

- ##### Install [PackerBaseAMI](https://github.com/RobBiddle/PackerBaseAMI) & Requirements:
  (Assumes you have PowerShellGet and access to PowerShellGallery.com)

  - [AWSPowerShell](https://www.powershellgallery.com/packages/AWSPowerShell) PowerShell Module
      ```PowerShell
      Install-Module AWSPowerShell
      ```
  - [PackerBaseAMI](https://github.com/RobBiddle/PackerBaseAMI) PowerShell Module
      ```PowerShell
      Install-Module PackerBaseAMI
      ```

- ##### Import the PackerBaseAMI module
    ```PowerShell
    Import-Module PackerBaseAMI
    ```

#### Example <a name="Example"></a>

```PowerShell
New-PackerBaseAMI -AccountNumber 111111111111 -Alias ExampleAlias -BaseOS WINDOWS_2012R2_BASE -IamRole ExampleRoleName -Region us-east-1 -OutputDirectoryPath c:\example\directory
```

#### Maintainer(s) <a name="Maintainer"></a>
[Robert D. Biddle](https://github.com/RobBiddle) - https://github.com/RobBiddle

#### Contributing <a name="Contributing"></a>

1. Fork it!
2. Create your feature branch: `git checkout -b my-new-feature`
3. Commit your changes: `git commit -am 'Add some feature'`
4. Push to the branch: `git push origin my-new-feature`
5. Submit a pull request :D

#### Credits <a name="Credits"></a>
- [Upic Solutions](https://upicsolutions.org/) for sponsoring my time to develop this project.  This code is being used as part of our mission to help [United Ways](https://www.unitedway.org/) be the best community solution leaders, in an increasingly competitive environment, by providing state of the art business and technology solutions
- [Hashicorp](https://www.hashicorp.com/) for creating [Packer](https://packer.io) and other fantastic open source projects
- The [AWSPowerShell](https://www.powershellgallery.com/packages/AWSPowerShell) Devs for supporting all of us PowerShell users

#### License <a name="License"></a>
GNU General Public License v3.0
https://github.com/RobBiddle/PackerBaseAMI/LICENSE.txt
