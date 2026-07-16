# Azure Virtual Enclaves (AVE)

Azure Virtual Enclaves accelerates and streamlines the deployment and management of secure, isolated, and compliant cloud environments for the most sensitive workloads. AVE is designed for commercial and air-gapped environments. [Learn more](https://aka.ms/ave/overview)

## Deploy

SACA

[![Deploy To Azure](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/deploytoazure.svg?sanitize=true)](
https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fazure%2Fvirtual-enclaves%2Fmain%2Fave-templates%2Fave-saca.json)

TRE

[![Deploy To Azure](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/deploytoazure.svg?sanitize=true)](
https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fazure%2Fvirtual-enclaves%2Fmain%2Fave-templates%2Fave-tre.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fazure%2Fvirtual-enclaves%2Fmain%2Fave-templates%2Fave-tre-createUiDefinition.json)

Demo Environment

[![Deploy To Azure](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/deploytoazure.svg?sanitize=true)](
https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fazure%2Fvirtual-enclaves%2Fmain%2Fave-templates%2Fave-demo.json)

<!-- /createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fvirtual-enclaves%2Fmain%2Fave-templates%2FdeploymentUI.json) -->

## Template Specs Deployment Script

For environments where portal-based deployment is not available or when deploying Mission Platform service catalog template specs programmatically, use the included PowerShell deploy script: [service-catalog/deployTemplateSpecs.ps1](./service-catalog/deployTemplateSpecs.ps1).

This script handles Azure authentication, installs any missing required PowerShell modules (`Az.Accounts`, `Az.Resources`), and publishes all 12 Bicep-based template specs to your subscription in parallel.

Template spec versions and release notes are managed centrally in [`service-catalog/versionManifest.json`](./service-catalog/versionManifest.json). To bump a version or update release notes, edit that file — no changes to the deploy script are needed.

### Downloading the Repository

To run the deploy script locally, you first need a copy of this repository on your machine. You can download it directly from GitHub without using Git:

1. Navigate to the repository on GitHub: [https://github.com/azure/virtual-enclaves](https://github.com/azure/virtual-enclaves)
2. Click the green **Code** button near the top right.
3. Select **Download ZIP**.
4. Extract the ZIP to a local folder.
5. Open a PowerShell terminal, navigate to the extracted folder, and run the deploy script:

```powershell
cd service-catalog
.\deployTemplateSpecs.ps1
```

### Parameters

| Parameter | Type | Description |
|---|---|---|
| `-Fast` | switch | Skips the context confirmation prompt and uses default resource group/location. |
| `-Pipeline` | switch | Fully headless mode for CI/CD pipelines — no interactive prompts. Errors immediately if no Azure context is active. |
| `-ResourceGroupName` | string | Overrides the default resource group (`rg-missionplatforms-templatespecs`). |
| `-Location` | string | Overrides the default location (`usgovvirginia`). |

### Fast Mode

Use `-Fast` to skip the Azure context confirmation and resource group selection prompts while still allowing interactive sign-in. This is useful for repeat runs where you have already verified the target subscription. The defaults (`rg-missionplatforms-templatespecs` / `usgovvirginia`) apply unless overridden:

```powershell
.\deployTemplateSpecs.ps1 -Fast
# or with overrides:
.\deployTemplateSpecs.ps1 -Fast -ResourceGroupName rg-myenv-templatespecs -Location eastus
```

### Pipeline / CI-CD Usage

Authenticate with a service principal before invoking the script, then pass `-Pipeline` to suppress all prompts:

```powershell
Connect-AzAccount -ServicePrincipal -TenantId $env:TENANT_ID -Credential $cred
cd service-catalog
.\deployTemplateSpecs.ps1 -Pipeline -ResourceGroupName rg-myenv-templatespecs -Location usgovvirginia
```

## Contributing

[Contributing guidance](./CONTRIBUTING.md)

## Telemetry
The templates in this repo may contain telemetry to track the usage of each template. This information helps support these templates. You can turn off telemetry by changing `enableTelemetry` to `false`. 

## Data collection
The software may collect information about you and your use of the software and send it to Microsoft. Microsoft may use this information to provide services and improve our products and services. You may turn off the telemetry as described in the repository. There are also some features in the software that may enable you and Microsoft to collect data from users of your applications. If you use these features, you must comply with applicable law, including providing appropriate notices to users of your applications together with a copy of Microsoft’s privacy statement. Our privacy statement is located at https://go.microsoft.com/fwlink/?LinkID=824704. You can learn more about data collection and use in the help documentation and our privacy statement. Your use of the software operates as your consent to these practices.

## Trademarks

This project may contain trademarks or logos for projects, products, or services. Authorized use of Microsoft 
trademarks or logos is subject to and must follow 
[Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/legal/intellectualproperty/trademarks/usage/general).
Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or imply Microsoft sponsorship.
Any use of third-party trademarks or logos are subject to those third-party's policies.
