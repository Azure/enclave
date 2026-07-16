// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

// Trusted Research Environment
@description('Name of the community (e.g. cmt-azure-enclave-tre-template-test1). Also added to the front of community resource names.')
@maxLength(26)
param communityName string = 'cmt-tre-hub'
@description('Prefix for the Enclave names (e.g. ve-azure-enclave-tre-template-test1)')
@maxLength(15)
param enclaveNamePrefix string = 've-tre'
@description('A integer unique to make the resources unique within the resource group. This enables easier multiple test deployments.')
@minLength(1)
@maxLength(3)
param uniqueNumber string = '1'
@description('Address space for the community network in CIDR notation.')
param addressSpace string = '10.0.0.0/16'
@description('The size of the enclave virtual networks.')
param networkSize string = 'small'
// param customCidrRange string = ''

@description('Allowed values: Gateway or ExpressRoute')
param transitOptionType string = 'Gateway'
@description('Name of the transit hub.')
param transitHubName string = 'th-external'
@description('Transit Hub scale units')
param scaleUnits int = 2
@description('Resource ID of the remote virtual network for peering through your transit hub.')
param remoteVirtualNetworkId string = ''
@description('Azure region for all resources.')
param location string = resourceGroup().location
@description('Enable/Disable usage telemetry for this template.')
param enableTelemetry bool = true

// Type definition for maintenance mode configuration
type maintenanceModeConfigurationType = {
  mode: ('Off' | 'General' | 'Advanced')
  justification: ('Off' | 'Networking' | 'Governance')
  principals: array
}

// Portal format example:
// {"mode": "Advanced", "principals": [{"id": "your-principal-id", "type": "User"}],"justification": "Networking"}
@description('Maintenance mode configuration for resources.')
param maintenanceModeConfig maintenanceModeConfigurationType = {
  mode: 'Off'
  justification: 'Off'
  principals: []
}

// ========================================
// VARIABLES
// ========================================

var uniqueCommunityName = '${communityName}-${uniqueNumber}'
var uniqueEnclaveNamePrefix = '${enclaveNamePrefix}-${uniqueNumber}'

// Governed services configuration
var governedServices = [
  { serviceId: 'AKS', option: 'Allow', enforcement: 'Enabled', policyAction: 'Enforce' }
  { serviceId: 'AppService', option: 'Allow', enforcement: 'Enabled', policyAction: 'Enforce' }
  { serviceId: 'ContainerRegistry', option: 'Allow', enforcement: 'Enabled', policyAction: 'Enforce' }
  { serviceId: 'CosmosDB', option: 'Allow', enforcement: 'Enabled', policyAction: 'Enforce' }
  { serviceId: 'KeyVault', option: 'Allow', enforcement: 'Enabled', policyAction: 'Enforce' }
  { serviceId: 'MicrosoftSQL', option: 'Allow', enforcement: 'Enabled', policyAction: 'Enforce' }
  { serviceId: 'Monitoring', option: 'NotApplicable', enforcement: 'Enabled', policyAction: 'Enforce' }
  { serviceId: 'PostgreSQL', option: 'Allow', enforcement: 'Enabled', policyAction: 'Enforce' }
  { serviceId: 'ServiceBus', option: 'Allow', enforcement: 'Enabled', policyAction: 'Enforce' }
  { serviceId: 'Storage', option: 'Allow', enforcement: 'Enabled', policyAction: 'Enforce' }
  { serviceId: 'AzureFirewalls', option: 'Allow', enforcement: 'Enabled', policyAction: 'Enforce' }
  { serviceId: 'Insights', option: 'Allow', enforcement: 'Enabled', policyAction: 'Enforce' }
  { serviceId: 'Logic', option: 'Allow', enforcement: 'Enabled', policyAction: 'Enforce' }
  { serviceId: 'PrivateDNSZones', option: 'Allow', enforcement: 'Enabled', policyAction: 'Enforce' }
  { serviceId: 'DataConnectors', option: 'Allow', enforcement: 'Enabled', policyAction: 'Enforce' }
]

// ========================================
// RESOURCES
// ========================================

#disable-next-line no-deployments-resources BCP081
resource aveTelemetry 'Microsoft.Resources/deployments@2024-03-01' = if (enableTelemetry) {
  name: take(
    'virtualenclaves.ave-tre.${replace('-..--..-', '.', '-')}.${substring(uniqueString(deployment().name, location), 0, 4)}',
    64
  )
  properties: {
    mode: 'Incremental'
    template: {
      '$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
      contentVersion: '1.0.0.0'
      resources: []
      outputs: {
        telemetry: {
          type: 'String'
          value: 'For more information, see https://aka.ms/avm/TelemetryInfo'
        }
      }
    }
  }
}

// Community:
module community 'modules/community.bicep' = {
  name: 'deploy-community-${uniqueCommunityName}'
  params: {
    #disable-next-line BCP334
    communityName: uniqueCommunityName
    addressSpace: addressSpace
    location: location
    tags: {
      department: 'CommunityOversightDept'
      company: 'CommunityOversight'
    }
    governedServiceList: governedServices
    maintenanceModeConfiguration: maintenanceModeConfig
  }
}

// Community Endpoint: Data Source
module communityEndpointDataSource 'modules/community-endpoint.bicep' = {
  name: 'deploy-ce-data-${uniqueNumber}'
  params: {
    communityName: community.outputs.name
    communityEndpointName: 'ce-data-source-${uniqueNumber}'
    location: location
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
    communityEndpointRuleCollection: communityEndpointRules.outputs.dataSourceEndpointRules
  }
}

// Transit Hub:
module transitHub 'modules/transit-hub.bicep' = {
  name: 'deploy-transithub-${transitHubName}'
  params: {
    communityName: community.outputs.name
    transitHubName: transitHubName
    location: location
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
    transitOption: {
      type: transitOptionType
      params: (((transitOptionType == 'Gateway') || (transitOptionType == 'ExpressRoute'))
        ? { scaleUnits: scaleUnits }
        : { remoteVirtualNetworkId: remoteVirtualNetworkId })
    }
  }
  dependsOn: [
    enclaveProj1
  ]
}

module communityEndpointRules 'endpoints/community-endpoint-rules.bicep' = {
  name: 'load-community-endpoint-rules-${uniqueNumber}'
  params: {
    transitHubResourceId: transitHub.outputs.transitHubResourceId
  }
}

// Community Endpoint: External
module communityEndpointExternal 'modules/community-endpoint.bicep' = {
  name: 'deploy-ce-external-${uniqueNumber}'
  params: {
    communityName: community.outputs.name
    communityEndpointName: 'ce-external-community-${uniqueNumber}'
    location: location
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
    communityEndpointRuleCollection: communityEndpointRules.outputs.externalCommunityEndpointRules
  }
}

// Community Endpoint: Default Portal
module communityEndpointDefaultPortal 'modules/community-endpoint.bicep' = {
  name: 'deploy-ce-defaultPortal-${uniqueNumber}'
  params: {
    communityName: community.outputs.name
    communityEndpointName: 'defaultPortal'
    location: location
    tags: {
      department: 'CommunityOversightDept'
      company: 'CommunityOversight'
    }
    communityEndpointRuleCollection: concat(
      communityEndpointRules.outputs.azurePortalEndpointRules,
      communityEndpointRules.outputs.serviceCatalogEndpointRules
    )
  }
}

// Community Endpoint: Windows Updates
module communityEndpointWindowsUpdates 'modules/community-endpoint.bicep' = {
  name: 'deploy-ce-win-updates-${uniqueNumber}'
  params: {
    communityName: community.outputs.name
    communityEndpointName: 'ce-win-updates-${uniqueNumber}'
    location: location
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
    communityEndpointRuleCollection: communityEndpointRules.outputs.windowsUpdateEndpointRules
  }
}

// Community Endpoint: Winget
module communityEndpointWinget 'modules/community-endpoint.bicep' = {
  name: 'deploy-ce-winget-${uniqueNumber}'
  params: {
    communityName: community.outputs.name
    communityEndpointName: 'ce-winget-${uniqueNumber}'
    location: location
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
    communityEndpointRuleCollection: communityEndpointRules.outputs.wingetEndpointRules
  }
}

// Enclaves with Workloads
// Enclave: Shared Services
module enclaveShared 'modules/enclave.bicep' = {
  name: 'deploy-enclave-${uniqueEnclaveNamePrefix}-shared'
  params: {
    communityResourceId: community.outputs.resourceId
    enclaveName: '${uniqueEnclaveNamePrefix}-shared'
    networkSize: networkSize
    location: location
    tags: {
      department: 'SharedServicesDept'
      company: 'SharedServicesCompany'
    }
    subnetConfigurationsList: [
      {
        subnetName: 'AppSubnet'
        networkPrefixSize: 26
      }
      {
        subnetName: 'WorkloadSubnet'
        networkPrefixSize: 26
      }
    ]
    deployWorkload: true
    workloadName: 'wl-shared-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
    workloadResourceGroupName: 'rg-shared-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
  }
}

// Enclave: Researcher 1
module enclaveProj1 'modules/enclave.bicep' = {
  name: 'deploy-enclave-${uniqueEnclaveNamePrefix}-proj1'
  params: {
    communityResourceId: community.outputs.resourceId
    enclaveName: '${uniqueEnclaveNamePrefix}-proj1'
    networkSize: networkSize
    location: location
    tags: {
      department: 'ResearchProject1Dept'
      company: 'ResearchProject1Company'
    }
    subnetConfigurationsList: [
      {
        subnetName: 'AppSubnet'
        networkPrefixSize: 26
      }
      {
        subnetName: 'WorkloadSubnet'
        networkPrefixSize: 26
      }
    ]
    deployWorkload: true
    workloadName: 'wl-project1-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
    workloadResourceGroupName: 'rg-project1-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
  }
}

// Enclave: Research Project 2
module enclaveProj2 'modules/enclave.bicep' = {
  name: 'deploy-enclave-${uniqueEnclaveNamePrefix}-proj2'
  params: {
    communityResourceId: community.outputs.resourceId
    enclaveName: '${uniqueEnclaveNamePrefix}-proj2'
    networkSize: networkSize
    location: location
    tags: {
      department: 'ResearchProject2Dept'
      company: 'ResearchProject2Company'
    }
    subnetConfigurationsList: [
      {
        subnetName: 'AppSubnet'
        networkPrefixSize: 26
      }
      {
        subnetName: 'WorkloadSubnet'
        networkPrefixSize: 26
      }
    ]
    deployWorkload: true
    workloadName: 'wl-project2-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
    workloadResourceGroupName: 'rg-project2-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
  }
}

// Enclave: Data Coordination Center
module enclaveDCC 'modules/enclave.bicep' = {
  name: 'deploy-enclave-${uniqueEnclaveNamePrefix}-DCC'
  params: {
    communityResourceId: community.outputs.resourceId
    enclaveName: '${uniqueEnclaveNamePrefix}-DCC'
    networkSize: networkSize
    location: location
    tags: {
      department: 'DataCoordinationCenterDept'
      company: 'DataCoordinationCenterCompany'
    }
    subnetConfigurationsList: [
      {
        subnetName: 'AppSubnet'
        networkPrefixSize: 26
      }
      {
        subnetName: 'WorkloadSubnet'
        networkPrefixSize: 26
      }
    ]
    deployWorkload: true
    workloadName: 'wl-DCC-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
    workloadResourceGroupName: 'rg-DCC-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
  }
}

// Enclave Endpoints
// Enclave Endpoint: Shared Services AVD
module enclaveEndpointShared 'modules/enclave-endpoint.bicep' = {
  name: 'deploy-ee-shared-${uniqueNumber}'
  params: {
    enclaveName: enclaveShared.outputs.name
    endpointName: 'ee-shared'
    location: location
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
    rules: [
      {
        endpointRuleName: 'AVD'
        destination: filter(enclaveShared.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
        ports: '53,88,135,138,139,389,445,464,636,686,3268-3269,5722,9389,49152-65535'
        protocols: [
          'TCP'
        ]
      }
    ]
  }
}

// Enclave Endpoint: Researcher Project 1
module enclaveEndpointProject1 'modules/enclave-endpoint.bicep' = {
  name: 'deploy-ee-project1-${uniqueNumber}'
  params: {
    enclaveName: enclaveProj1.outputs.name
    endpointName: 'ee-project1-data'
    location: location
    tags: {
      department: 'ResearchProject1Dept'
      company: 'ResearchProject1Company'
    }
    rules: [
      {
        endpointRuleName: 'Project1-Data'
        destination: filter(enclaveProj1.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
        ports: '443'
        protocols: [
          'TCP'
        ]
      }
    ]
  }
}

// ====================================================================
// ENCLAVE CONNECTIONS
// All connections are created together after all endpoints are ready
// ====================================================================

// -------------------defaultPortal Connections-------------------
// Connection: Shared Services enclave to defaultPortal endpoint
module connectionSharedToDefaultPortal 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-shared-portal-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveShared.outputs.enclaveResourceId
    destinationResourceId: communityEndpointDefaultPortal.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclaveShared.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-shared-portal-tre-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    enclaveEndpointShared
    enclaveEndpointProject1
  ]
}

// Connection: Project 1 enclave to defaultPortal endpoint
module connectionProj1ToDefaultPortal 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-proj1-portal-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveProj1.outputs.enclaveResourceId
    destinationResourceId: communityEndpointDefaultPortal.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclaveProj1.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-proj1-portal-tre-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    enclaveEndpointShared
    enclaveEndpointProject1
  ]
}

// Connection: Project 2 enclave to defaultPortal endpoint
module connectionProj2ToDefaultPortal 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-proj2-portal-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveProj2.outputs.enclaveResourceId
    destinationResourceId: communityEndpointDefaultPortal.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclaveProj2.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-proj2-portal-tre-${uniqueNumber}'
    tags: {
      department: 'mission'
      company: 'TBD'
    }
  }
  dependsOn: [
    enclaveEndpointShared
    enclaveEndpointProject1
  ]
}

// Connection: DCC enclave to defaultPortal endpoint
module connectionDCCToDefaultPortal 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-dcc-portal-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveDCC.outputs.enclaveResourceId
    destinationResourceId: communityEndpointDefaultPortal.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclaveDCC.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-dcc-portal-tre-${uniqueNumber}'
    tags: {
      department: 'mission'
      company: 'TBD'
    }
  }
  dependsOn: [
    enclaveEndpointShared
    enclaveEndpointProject1
  ]
}

// -------------------Project 1 Data Connections-------------------
// Connection: DCC Enclave to Researcher Project 1 Data endpoint
module connectionDCCToProject1Data 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-dcc-proj1-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveDCC.outputs.enclaveResourceId
    destinationResourceId: enclaveEndpointProject1.outputs.endpointId
    sourceAddressSpace: filter(enclaveDCC.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-dcc-proj1-tre-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    enclaveEndpointShared
    #disable-next-line no-unnecessary-dependson
    enclaveEndpointProject1
  ]
}

// -------------------Windows Update Connections-------------------
// Connection: Shared enclave to Windows Updates endpoint
module connectionSharedToWinUpdates 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-shared-winupd-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveShared.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWindowsUpdates.outputs.communityEndpointResourceId
    // use all enclave subnets plus managed address space /26 for Windows Update service tag
    sourceAddressSpace: '${join(map(enclaveShared.outputs.enclaveSubnetConfig, s => s.addressPrefix), ', ')}, ${split(enclaveShared.outputs.managedAddressSpace, '/')[0]}/26'
    location: location
    connectionName: 'ec-shared-winupd-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    enclaveEndpointShared
    enclaveEndpointProject1
  ]
}

// Connection: Project 1 enclave to Windows Updates endpoint
module connectionProj1ToWinUpdates 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-proj1-winupd-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveProj1.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWindowsUpdates.outputs.communityEndpointResourceId
    // use all enclave subnets plus managed address space /26 for Windows Update service tag
    sourceAddressSpace: '${join(map(enclaveProj1.outputs.enclaveSubnetConfig, s => s.addressPrefix), ', ')}, ${split(enclaveProj1.outputs.managedAddressSpace, '/')[0]}/26'
    location: location
    connectionName: 'ec-proj1-winupd-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    enclaveEndpointShared
    enclaveEndpointProject1
  ]
}

// Connection: Project 2 enclave to Windows Updates endpoint
module connectionProj2ToWinUpdates 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-proj2-winupd-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveProj2.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWindowsUpdates.outputs.communityEndpointResourceId
    // use all enclave subnets plus managed address space /26 for Windows Update service tag
    sourceAddressSpace: '${join(map(enclaveProj2.outputs.enclaveSubnetConfig, s => s.addressPrefix), ', ')}, ${split(enclaveProj2.outputs.managedAddressSpace, '/')[0]}/26'
    location: location
    connectionName: 'ec-proj2-winupd-${uniqueNumber}'
    tags: {
      department: 'mission'
      company: 'TBD'
    }
  }
  dependsOn: [
    enclaveEndpointShared
    enclaveEndpointProject1
  ]
}

// Connection: DCC enclave to Windows Updates endpoint
module connectionDCCToWinUpdates 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-dcc-winupd-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveDCC.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWindowsUpdates.outputs.communityEndpointResourceId
    // use all enclave subnets plus managed address space /26 for Windows Update service tag
    sourceAddressSpace: '${join(map(enclaveDCC.outputs.enclaveSubnetConfig, s => s.addressPrefix), ', ')}, ${split(enclaveDCC.outputs.managedAddressSpace, '/')[0]}/26'
    location: location
    connectionName: 'ec-dcc-winupd-${uniqueNumber}'
    tags: {
      department: 'mission'
      company: 'TBD'
    }
  }
  dependsOn: [
    enclaveEndpointShared
    enclaveEndpointProject1
  ]
}

// -------------------Winget Connections-------------------
// Connection: Shared enclave to Winget endpoint
module connectionSharedToWinget 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-shared-winget-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveShared.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWinget.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclaveShared.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-shared-winget-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    enclaveEndpointShared
    enclaveEndpointProject1
  ]
}

// Connection: Project 1 enclave to Winget endpoint
module connectionProj1ToWinget 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-proj1-winget-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveProj1.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWinget.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclaveProj1.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-proj1-winget-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    enclaveEndpointShared
    enclaveEndpointProject1
  ]
}

// Connection: Project 2 enclave to Winget endpoint
module connectionProj2ToWinget 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-proj2-winget-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveProj2.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWinget.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclaveProj2.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-proj2-winget-${uniqueNumber}'
    tags: {
      department: 'mission'
      company: 'TBD'
    }
  }
  dependsOn: [
    enclaveEndpointShared
    enclaveEndpointProject1
  ]
}

// Connection: DCC enclave to Winget endpoint
module connectionDCCToWinget 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-dcc-winget-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveDCC.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWinget.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclaveDCC.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-dcc-winget-${uniqueNumber}'
    tags: {
      department: 'mission'
      company: 'TBD'
    }
  }
  dependsOn: [
    enclaveEndpointShared
    enclaveEndpointProject1
  ]
}

// -------------------External Connections-------------------
// Connection: Shared enclave to external community endpoint
module connectionSharedToExternal 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-shared-external-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveShared.outputs.enclaveResourceId
    destinationResourceId: communityEndpointExternal.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclaveShared.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-shared-ext-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    enclaveEndpointShared
    enclaveEndpointProject1
  ]
}

// -------------------Transit Hub Connections-------------------
// Connection: Transithub to Shared enclave ADDS endpoint
module connectionExternalToShared 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-external-shared-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: transitHub.outputs.transitHubResourceId
    destinationResourceId: enclaveEndpointShared.outputs.endpointId
    sourceAddressSpace: '172.16.18.0/24'
    location: location
    connectionName: 'ec-ext-shared-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    #disable-next-line no-unnecessary-dependson
    enclaveEndpointShared
    enclaveEndpointProject1
  ]
}
