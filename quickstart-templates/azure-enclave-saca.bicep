// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

// Secure Azure Computing Architecture (SACA)
@description('Name of the community (e.g. cmt-azure-enclave-demo-template-test1). Also added to the front of community resource names.')
@maxLength(26)
param communityName string = 'cmt-saca-hub'
@description('Prefix for the Enclave names (e.g. ve-azure-enclave-demo-template-test1)')
@maxLength(15)
param enclaveNamePrefix string = 've-saca'
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
    'virtualenclaves.ave-saca.${replace('-..--..-', '.', '-')}.${substring(uniqueString(deployment().name, location), 0, 4)}',
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
    enclaveIdentity
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
    communityEndpointName: 'ce-win-winget-${uniqueNumber}'
    location: location
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
    communityEndpointRuleCollection: communityEndpointRules.outputs.wingetEndpointRules
  }
}

// Enclaves with Workloads
// Enclave: Identity (Tier 0)
module enclaveIdentity 'modules/enclave.bicep' = {
  name: 'deploy-enclave-${uniqueEnclaveNamePrefix}-identity'
  params: {
    communityResourceId: community.outputs.resourceId
    enclaveName: '${uniqueEnclaveNamePrefix}-identity'
    networkSize: networkSize
    location: location
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
    subnetConfigurationsList: [
      {
        subnetName: 'WorkloadSubnet'
        networkPrefixSize: 23
      }
    ]
    maintenanceModeConfiguration: maintenanceModeConfig
    deployWorkload: true
    workloadNames: [
      'wl-id-ADDS-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
    ]
    workloadResourceGroupName: 'rg-id-ADDS-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
  }
}

// Enclave: Operations (Tier 1)
module enclaveOperations 'modules/enclave.bicep' = {
  name: 'deploy-enclave-${uniqueEnclaveNamePrefix}-operations'
  params: {
    communityResourceId: community.outputs.resourceId
    enclaveName: '${uniqueEnclaveNamePrefix}-operations'
    networkSize: networkSize
    location: location
    tags: {
      department: 'CommunityOpsDept'
      company: 'CommunityOversight'
    }
    subnetConfigurationsList: [
      {
        subnetName: 'WorkloadSubnet'
        networkPrefixSize: 23
      }
    ]
    maintenanceModeConfiguration: maintenanceModeConfig
    deployWorkload: true
    workloadNames: [
      'wl-operations-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
    ]
    workloadResourceGroupName: 'rg-operations-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
  }
}

// Enclave: Shared Services (Tier 2)
module enclaveShared 'modules/enclave.bicep' = {
  name: 'deploy-enclave-${uniqueEnclaveNamePrefix}-shared'
  params: {
    communityResourceId: community.outputs.resourceId
    enclaveName: '${uniqueEnclaveNamePrefix}-shared'
    networkSize: networkSize
    location: location
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
    subnetConfigurationsList: [
      {
        subnetName: 'WorkloadSubnet'
        networkPrefixSize: 23
      }
    ]
    maintenanceModeConfiguration: maintenanceModeConfig
    deployWorkload: true
    workloadNames: [
      'wl-shared-apps-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
    ]
    workloadResourceGroupName: 'rg-shared-apps-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
  }
}

// Enclave: Mission Workload (Tier 3)
module enclaveMission 'modules/enclave.bicep' = {
  name: 'deploy-enclave-${uniqueEnclaveNamePrefix}-mission'
  params: {
    communityResourceId: community.outputs.resourceId
    enclaveName: '${uniqueEnclaveNamePrefix}-mission'
    networkSize: networkSize
    location: location
    tags: {
      department: 'mission'
      company: 'TBD'
    }
    subnetConfigurationsList: [
      {
        subnetName: 'WorkloadSubnet'
        networkPrefixSize: 26
      }
      {
        subnetName: 'appSubnet'
        networkPrefixSize: 26
      }
    ]
    maintenanceModeConfiguration: maintenanceModeConfig
    deployWorkload: true
    workloadNames: [
      'wl-mission-apps-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
    ]
    workloadResourceGroupName: 'rg-mission-apps-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
  }
}

var missionWorkloadSubnetCidr = reference(resourceId('Microsoft.Mission/virtualEnclaves', '${uniqueEnclaveNamePrefix}-mission'), '2025-05-01-preview').enclaveVirtualNetwork.subnetConfigurations[0].addressPrefix

// Enclave Endpoints
// Enclave Endpoint: Identity enclave ADDS 
module enclaveEndpointIdentity 'modules/enclave-endpoint.bicep' = {
  name: 'deploy-ee-identity-${uniqueNumber}'
  params: {
    enclaveName: enclaveIdentity.outputs.name
    endpointName: 'ee-ADDS'
    location: location
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
    rules: [
      {
        endpointRuleName: 'ADDS-TCP'
        destination: enclaveIdentity.outputs.enclaveAddressSpace
        ports: '53,88,135,138,139,389,445,464,636,686,3268-3269,5722,9389,49152-65535'
        protocols: [
          'TCP'
        ]
      }
      {
        endpointRuleName: 'ADDS-UDP'
        destination: enclaveIdentity.outputs.enclaveAddressSpace
        ports: '53,389'
        protocols: [
          'UDP'
        ]
      }
    ]
  }
}

// ====================================================================
// ENCLAVE CONNECTIONS
// All connections are created together after all endpoints are ready
// ====================================================================

// -------------------External Connections-------------------
// Connection: Shared enclave to external community endpoint
module connectionSharedToExternal 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-shared-ext-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveShared.outputs.enclaveResourceId
    destinationResourceId: communityEndpointExternal.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclaveShared.outputs.enclaveSubnetConfigResolved, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-shared-ext-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    enclaveEndpointIdentity
  ]
}

// -------------------defaultPortal Connections-------------------
// Connection: Identity enclave to defaultPortal endpoint
module connectionIdentityToDefaultPortal 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-id-portal-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveIdentity.outputs.enclaveResourceId
    destinationResourceId: communityEndpointDefaultPortal.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclaveIdentity.outputs.enclaveSubnetConfigResolved, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-id-portal-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    enclaveEndpointIdentity
  ]
}

// Connection: Shared enclave to defaultPortal endpoint
module connectionSharedToDefaultPortal 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-shared-portal-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveShared.outputs.enclaveResourceId
    destinationResourceId: communityEndpointDefaultPortal.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclaveShared.outputs.enclaveSubnetConfigResolved, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-shared-portal-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    enclaveEndpointIdentity
  ]
}

// Connection: Operations enclave to defaultPortal endpoint
module connectionOperationsToDefaultPortal 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-ops-portal-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveOperations.outputs.enclaveResourceId
    destinationResourceId: communityEndpointDefaultPortal.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclaveOperations.outputs.enclaveSubnetConfigResolved, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-ops-portal-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    enclaveEndpointIdentity
  ]
}

// Connection: Mission enclave to defaultPortal endpoint
module connectionMissionToDefaultPortal 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-mission-portal-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveMission.outputs.enclaveResourceId
    destinationResourceId: communityEndpointDefaultPortal.outputs.communityEndpointResourceId
    sourceAddressSpace: missionWorkloadSubnetCidr
    location: location
    connectionName: 'ec-mission-portal-${uniqueNumber}'
    tags: {
      department: 'mission'
      company: 'TBD'
    }
  }
  dependsOn: [
    enclaveEndpointIdentity
  ]
}

// -------------------Identity ADDS Connections-------------------
// Connection: Shared enclave to Identity enclave ADDS endpoint
module connectionSharedToIdentityAdds 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-shared-id-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveShared.outputs.enclaveResourceId
    destinationResourceId: enclaveEndpointIdentity.outputs.endpointId
    sourceAddressSpace: filter(enclaveShared.outputs.enclaveSubnetConfigResolved, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-shared-id-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    #disable-next-line no-unnecessary-dependson
    enclaveEndpointIdentity
  ]
}

// Connection: Operations enclave to Identity enclave ADDS endpoint
module connectionOperationsToIdentityAdds 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-ops-id-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveOperations.outputs.enclaveResourceId
    destinationResourceId: enclaveEndpointIdentity.outputs.endpointId
    sourceAddressSpace: filter(enclaveOperations.outputs.enclaveSubnetConfigResolved, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-ops-id-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    #disable-next-line no-unnecessary-dependson
    enclaveEndpointIdentity
  ]
}

// Connection: Mission enclave to Identity enclave ADDS endpoint
module connectionMissionToIdentityAdds 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-mission-id-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveMission.outputs.enclaveResourceId
    destinationResourceId: enclaveEndpointIdentity.outputs.endpointId
    sourceAddressSpace: missionWorkloadSubnetCidr
    location: location
    connectionName: 'ec-mission-id-${uniqueNumber}'
    tags: {
      department: 'mission'
      company: 'TBD'
    }
  }
  dependsOn: [
    #disable-next-line no-unnecessary-dependson
    enclaveEndpointIdentity
  ]
}

// -------------------Windows Updates Connections-------------------
// Connection: Identity enclave to Windows Updates endpoint
module connectionIdentityToWinUpdates 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-id-winupd-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveIdentity.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWindowsUpdates.outputs.communityEndpointResourceId
    sourceAddressSpace: '${join(map(enclaveIdentity.outputs.enclaveSubnetConfigResolved, s => s.addressPrefix), ', ')}, ${split(enclaveIdentity.outputs.managedAddressSpace, '/')[0]}/26'
    location: location
    connectionName: 'ec-id-winupd-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    enclaveEndpointIdentity
  ]
}

// Connection: Operations enclave to Windows Updates endpoint
module connectionOperationsToWinUpdates 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-ops-winupd-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveOperations.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWindowsUpdates.outputs.communityEndpointResourceId
    sourceAddressSpace: '${join(map(enclaveOperations.outputs.enclaveSubnetConfigResolved, s => s.addressPrefix), ', ')}, ${split(enclaveOperations.outputs.managedAddressSpace, '/')[0]}/26'
    location: location
    connectionName: 'ec-ops-winupd-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    enclaveEndpointIdentity
  ]
}

// Connection: Shared enclave to Windows Updates endpoint
module connectionSharedToWinUpdates 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-shared-winupd-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveShared.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWindowsUpdates.outputs.communityEndpointResourceId
    sourceAddressSpace: '${join(map(enclaveShared.outputs.enclaveSubnetConfigResolved, s => s.addressPrefix), ', ')}, ${split(enclaveShared.outputs.managedAddressSpace, '/')[0]}/26'
    location: location
    connectionName: 'ec-shared-winupd-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    enclaveEndpointIdentity
  ]
}

// Connection: Mission enclave to Windows Updates endpoint
module connectionMissionToWinUpdates 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-mission-winupd-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveMission.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWindowsUpdates.outputs.communityEndpointResourceId
    sourceAddressSpace: missionWorkloadSubnetCidr
    location: location
    connectionName: 'ec-mission-winupd-${uniqueNumber}'
    tags: {
      department: 'mission'
      company: 'TBD'
    }
  }
  dependsOn: [
    enclaveEndpointIdentity
  ]
}

// -------------------Winget Connections-------------------
// Connection: Identity enclave to Winget endpoint
module connectionIdentityToWinget 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-id-winget-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveIdentity.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWinget.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclaveIdentity.outputs.enclaveSubnetConfigResolved, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-id-winget-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    enclaveEndpointIdentity
  ]
}

// Connection: Operations enclave to Winget endpoint
module connectionOperationsToWinget 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-ops-winget-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveOperations.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWinget.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclaveOperations.outputs.enclaveSubnetConfigResolved, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-ops-winget-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    enclaveEndpointIdentity
  ]
}

// Connection: Shared enclave to Winget endpoint
module connectionSharedToWinget 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-shared-winget-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveShared.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWinget.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclaveShared.outputs.enclaveSubnetConfigResolved, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-shared-winget-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    enclaveEndpointIdentity
  ]
}

// Connection: Mission enclave to Winget endpoint
module connectionMissionToWinget 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-mission-winget-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveMission.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWinget.outputs.communityEndpointResourceId
    sourceAddressSpace: missionWorkloadSubnetCidr
    location: location
    connectionName: 'ec-mission-winget-${uniqueNumber}'
    tags: {
      department: 'mission'
      company: 'TBD'
    }
  }
  dependsOn: [
    enclaveEndpointIdentity
  ]
}

// -------------------Data Source Connections-------------------
// Connection: Shared enclave to Bing&Outlook community endpoint
module connectionSharedToDataSource 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-shared-data-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveShared.outputs.enclaveResourceId
    destinationResourceId: communityEndpointDataSource.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclaveShared.outputs.enclaveSubnetConfigResolved, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-shared-data-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    enclaveEndpointIdentity
  ]
}

// -------------------Transit Hub Connections-------------------
// Connection: Transithub to Identity enclave ADDS endpoint
module connectionExternalToIdentityAdds 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-ext-id-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: transitHub.outputs.transitHubResourceId
    destinationResourceId: enclaveEndpointIdentity.outputs.endpointId
    sourceAddressSpace: '172.16.18.0/24'
    location: location
    connectionName: 'ec-ext-id-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    #disable-next-line no-unnecessary-dependson
    enclaveEndpointIdentity
  ]
}


