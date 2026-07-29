// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

@description('Name of the community (e.g. cmt-azure-enclave-demo-template-test1). Also added to the front of community resource names.')
@maxLength(26)
param communityName string = 'cmt-demo-hub'
@description('Prefix for the Enclave names (e.g. ve-azure-enclave-demo-template-test1)')
@maxLength(15)
param enclaveNamePrefix string = 've-demo'
@description('A integer unique to make the resources unique within the resource group. This enables easier multiple test deployments.')
@minLength(1)
@maxLength(3)
param uniqueNumber string = '1'
@description('Address space for the community network in CIDR notation.')
param addressSpace string = '10.0.0.0/16'
@description('The size of the enclave virtual networks.')
param networkSize string = 'small'
// param customCidrRange string = ''

@description('Allowed values: Gateway, ExpressRoute, or Peering. Gateway and ExpressRoute require scaleUnits parameter. Peering requires remoteVirtualNetworkId parameter.')
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
    'virtualenclaves.ave-demo-env.${replace('-..--..-', '.', '-')}.${substring(uniqueString(deployment().name, location), 0, 4)}',
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
// Enclave: Identity
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
        subnetName: 'AppSubnet'
        networkPrefixSize: 26
      }
      {
        subnetName: 'WorkloadSubnet'
        networkPrefixSize: 26
      }
    ]
    maintenanceModeConfiguration: maintenanceModeConfig
    deployWorkload: true
    workloadName: 'wl-id-ADDS-${uniqueNumber}'
    workloadResourceGroupName: 'rg-id-ADDS-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
  }
}

// Enclave: Collaboration
module enclaveCollab 'modules/enclave.bicep' = {
  name: 'deploy-enclave-${uniqueEnclaveNamePrefix}-collab'
  params: {
    communityResourceId: community.outputs.resourceId
    enclaveName: '${uniqueEnclaveNamePrefix}-collab'
    networkSize: networkSize
    location: location
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
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
    maintenanceModeConfiguration: maintenanceModeConfig
    deployWorkload: true
    workloadName: 'wl-collab-apps-${uniqueNumber}'
    workloadResourceGroupName: 'rg-collab-apps-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
  }
}

// Enclave: Desktop
module enclaveDesktop 'modules/enclave.bicep' = {
  name: 'deploy-enclave-${uniqueEnclaveNamePrefix}-desktop'
  params: {
    communityResourceId: community.outputs.resourceId
    enclaveName: '${uniqueEnclaveNamePrefix}-desktop'
    networkSize: networkSize
    location: location
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
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
    maintenanceModeConfiguration: maintenanceModeConfig
    deployWorkload: true
    workloadName: 'wl-desktops-${uniqueNumber}'
    workloadResourceGroupName: 'rg-desktops-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
  }
}

// Enclave: Platform
module enclavePlatform 'modules/enclave.bicep' = {
  name: 'deploy-enclave-${uniqueEnclaveNamePrefix}-platform'
  params: {
    communityResourceId: community.outputs.resourceId
    enclaveName: '${uniqueEnclaveNamePrefix}-platform'
    networkSize: networkSize
    location: location
    tags: {
      department: 'platforms'
      company: 'PrimeContractor'
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
    maintenanceModeConfiguration: maintenanceModeConfig
    deployWorkload: true
    workloadName: 'wl-platform-apps-${uniqueNumber}'
    workloadResourceGroupName: 'rg-platform-apps-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
  }
}

// Enclave: Weapon
module enclaveWeapon 'modules/enclave.bicep' = {
  name: 'deploy-enclave-${uniqueEnclaveNamePrefix}-weapon'
  params: {
    communityResourceId: community.outputs.resourceId
    enclaveName: '${uniqueEnclaveNamePrefix}-weapon'
    networkSize: networkSize
    location: location
    tags: {
      department: 'PewPewDept'
      company: 'WeaponContractor'
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
    maintenanceModeConfiguration: maintenanceModeConfig
    deployWorkload: true
    workloadName: 'wl-weapon-apps-${uniqueNumber}'
    workloadResourceGroupName: 'rg-weapon-apps-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
  }
}

// Enclave: SubKtr
module enclaveSubKtr 'modules/enclave.bicep' = {
  name: 'deploy-enclave-${uniqueEnclaveNamePrefix}-subktr'
  params: {
    communityResourceId: community.outputs.resourceId
    enclaveName: '${uniqueEnclaveNamePrefix}-subktr'
    networkSize: networkSize
    location: location
    tags: {
      department: 'SoftwareDevDept'
      company: 'Subcontractor'
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
    maintenanceModeConfiguration: maintenanceModeConfig
    deployWorkload: true
    workloadName: 'wl-subktr-apps-${uniqueNumber}'
    workloadResourceGroupName: 'rg-subktr-apps-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
  }
}

// Enclave: Cyber
module enclaveCyber 'modules/enclave.bicep' = {
  name: 'deploy-enclave-${uniqueEnclaveNamePrefix}-cyber'
  params: {
    communityResourceId: community.outputs.resourceId
    enclaveName: '${uniqueEnclaveNamePrefix}-cyber'
    networkSize: networkSize
    location: location
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
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
    maintenanceModeConfiguration: maintenanceModeConfig
    deployWorkload: true
    workloadName: 'wl-cyber-apps-${uniqueNumber}'
    workloadResourceGroupName: 'rg-cyber-apps-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
  }
}

// Enclave: Offline
module enclaveOffline 'modules/enclave.bicep' = {
  name: 'deploy-enclave-${uniqueEnclaveNamePrefix}-offline'
  params: {
    communityResourceId: community.outputs.resourceId
    enclaveName: '${uniqueEnclaveNamePrefix}-offline'
    networkSize: networkSize
    location: location
    tags: {
      department: 'SensitiveDataDept'
      company: 'R&D_Collaboration'
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
    maintenanceModeConfiguration: maintenanceModeConfig
    deployWorkload: true
    workloadName: 'wl-offline-apps-${uniqueNumber}'
    workloadResourceGroupName: 'rg-offline-apps-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
  }
}

// Enclave Endpoints
// Enclave Endpoint: Identity enclave ADDS
module enclaveIdentity_endpointName_1_v2 'modules/enclave-endpoint.bicep' = {
  name: 'deploy-ee-identity-adds-${uniqueNumber}'
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
        destination: filter(enclaveIdentity.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
        ports: '53,88,135,138,139,389,445,464,636,686,3268-3269,5722,9389,49152-65535'
        protocols: [
          'TCP'
        ]
      }
      {
        endpointRuleName: 'ADDS-UDP'
        destination: filter(enclaveIdentity.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
        ports: '53,389'
        protocols: [
          'UDP'
        ]
      }
    ]
  }
}

// Enclave Endpoint: Platform from Weapon
module ep_enclavePlatform_from_weapon 'modules/enclave-endpoint.bicep' = {
  name: 'deploy-ee-plat-from-weap-${uniqueNumber}'
  params: {
    enclaveName: enclavePlatform.outputs.name
    endpointName: 'ee-platform-from-weapon'
    location: location
    tags: {
      department: 'platforms'
      company: 'primeContractor'
    }
    rules: [
      {
        endpointRuleName: 'inbound-to-platform'
        destination: filter(enclavePlatform.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
        ports: '443'
        protocols: [
          'TCP'
        ]
      }
    ]
  }
}

// Enclave Endpoint: Weapon from Platform
module ep_enclaveWeapon_from_platform 'modules/enclave-endpoint.bicep' = {
  name: 'deploy-ee-weap-from-plat-${uniqueNumber}'
  params: {
    enclaveName: enclaveWeapon.outputs.name
    endpointName: 'ee-weapon-from-platform'
    location: location
    tags: {
      department: 'pewPewDept'
      company: 'weaponContractor'
    }
    rules: [
      {
        endpointRuleName: 'inbound-to-weapon'
        destination: filter(enclaveWeapon.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
        ports: '443'
        protocols: [
          'TCP'
        ]
      }
    ]
  }
}

// Enclave Endpoint: Weapon from SubKtr
module ep_enclaveWeapon_from_subktr 'modules/enclave-endpoint.bicep' = {
  name: 'deploy-ee-weap-from-sub-${uniqueNumber}'
  params: {
    enclaveName: enclaveWeapon.outputs.name
    endpointName: 'ee-weapon-from-subktr'
    location: location
    tags: {
      department: 'pewPewDept'
      company: 'weaponContractor'
    }
    rules: [
      {
        endpointRuleName: 'inbound-to-weapon'
        destination: filter(enclaveWeapon.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
        ports: '443'
        protocols: [
          'TCP'
        ]
      }
    ]
  }
}

// Enclave Endpoint: SubKtr from Weapon
module ep_enclaveSubKtr_from_weapon 'modules/enclave-endpoint.bicep' = {
  name: 'deploy-ee-sub-from-weap-${uniqueNumber}'
  params: {
    enclaveName: enclaveSubKtr.outputs.name
    endpointName: 'ee-subktr-from-weapon'
    location: location
    tags: {
      department: 'softwareDevDept'
      company: 'subContractor'
    }
    rules: [
      {
        endpointRuleName: 'inbound-to-subktr'
        destination: filter(enclaveSubKtr.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
        ports: '443'
        protocols: [
          'TCP'
        ]
      }
    ]
  }
}

// Enclave Endpoint: Cyber inbound to Identity
module ep_enclaveIdentity_cyber 'modules/enclave-endpoint.bicep' = {
  name: 'deploy-ee-identity-cyber-${uniqueNumber}'
  params: {
    enclaveName: enclaveIdentity.outputs.name
    endpointName: 'ee-identity-cyber'
    location: location
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
    rules: [
      {
        endpointRuleName: 'cyber-inbound'
        destination: filter(enclaveIdentity.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
        ports: '443'
        protocols: [
          'TCP'
        ]
      }
    ]
  }
}

// Enclave Endpoint: Cyber inbound to Desktop
module ep_enclaveDesktop_cyber 'modules/enclave-endpoint.bicep' = {
  name: 'deploy-ee-desktop-cyber-${uniqueNumber}'
  params: {
    enclaveName: enclaveDesktop.outputs.name
    endpointName: 'ee-desktop-cyber'
    location: location
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
    rules: [
      {
        endpointRuleName: 'cyber-inbound'
        destination: filter(enclaveDesktop.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
        ports: '443'
        protocols: [
          'TCP'
        ]
      }
    ]
  }
}

// Enclave Endpoint: Cyber inbound to Collab
module ep_enclaveCollab_cyber 'modules/enclave-endpoint.bicep' = {
  name: 'deploy-ee-collab-cyber-${uniqueNumber}'
  params: {
    enclaveName: enclaveCollab.outputs.name
    endpointName: 'ee-collab-cyber'
    location: location
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
    rules: [
      {
        endpointRuleName: 'cyber-inbound'
        destination: filter(enclaveCollab.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
        ports: '443'
        protocols: [
          'TCP'
        ]
      }
    ]
  }
}

// Enclave Endpoint: Cyber inbound to Platform
module ep_enclavePlatform_cyber 'modules/enclave-endpoint.bicep' = {
  name: 'deploy-ee-platform-cyber-${uniqueNumber}'
  params: {
    enclaveName: enclavePlatform.outputs.name
    endpointName: 'ee-platform-cyber'
    location: location
    tags: {
      department: 'platforms'
      company: 'primeContractor'
    }
    rules: [
      {
        endpointRuleName: 'cyber-inbound'
        destination: filter(enclavePlatform.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
        ports: '443'
        protocols: [
          'TCP'
        ]
      }
    ]
  }
}

// Enclave Endpoint: Cyber inbound to Weapon
module ep_enclaveWeapon_cyber 'modules/enclave-endpoint.bicep' = {
  name: 'deploy-ee-weapon-cyber-${uniqueNumber}'
  params: {
    enclaveName: enclaveWeapon.outputs.name
    endpointName: 'ee-weapon-cyber'
    location: location
    tags: {
      department: 'pewPewDept'
      company: 'weaponContractor'
    }
    rules: [
      {
        endpointRuleName: 'cyber-inbound'
        destination: filter(enclaveWeapon.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
        ports: '443'
        protocols: [
          'TCP'
        ]
      }
    ]
  }
}

// Enclave Endpoint: Cyber inbound to SubKtr
module ep_enclaveSubKtr_cyber 'modules/enclave-endpoint.bicep' = {
  name: 'deploy-ee-subktr-cyber-${uniqueNumber}'
  params: {
    enclaveName: enclaveSubKtr.outputs.name
    endpointName: 'ee-subktr-cyber'
    location: location
    tags: {
      department: 'softwareDevDept'
      company: 'subContractor'
    }
    rules: [
      {
        endpointRuleName: 'cyber-inbound'
        destination: filter(enclaveSubKtr.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
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

// -------------------External Connections-------------------
// Connection: Collaboration enclave to external community endpoint
module ec_collab_to_external 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-coll-ext-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCollab.outputs.enclaveResourceId
    destinationResourceId: communityEndpointExternal.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclaveCollab.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-coll-ext-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// -------------------defaultPortal Connections-------------------
// Connection: Collaboration enclave to defaultPortal endpoint
module ec_collab_to_defaultPortal_cm_ep 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-coll-portal-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCollab.outputs.enclaveResourceId
    destinationResourceId: communityEndpointDefaultPortal.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclaveCollab.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-coll-portal-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: Desktop enclave to defaultPortal endpoint
module ec_desktop_to_defaultPortal_cm_ep 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-desk-portal-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveDesktop.outputs.enclaveResourceId
    destinationResourceId: communityEndpointDefaultPortal.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclaveDesktop.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-desk-portal-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: Platform enclave to defaultPortal endpoint
module ec_platform_to_defaultPortal_cm_ep 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-plat-portal-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclavePlatform.outputs.enclaveResourceId
    destinationResourceId: communityEndpointDefaultPortal.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclavePlatform.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-plat-portal-${uniqueNumber}'
    tags: {
      department: 'platforms'
      company: 'primeContractor'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: Weapon enclave to defaultPortal endpoint
module ec_weapon_to_defaultPortal_cm_ep 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-weap-portal-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveWeapon.outputs.enclaveResourceId
    destinationResourceId: communityEndpointDefaultPortal.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclaveWeapon.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-weap-portal-${uniqueNumber}'
    tags: {
      department: 'pewPewDept'
      company: 'weaponContractor'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: SubKtr enclave to defaultPortal endpoint
module ec_subktr_to_defaultPortal_cm_ep 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-sub-portal-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveSubKtr.outputs.enclaveResourceId
    destinationResourceId: communityEndpointDefaultPortal.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclaveSubKtr.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-sub-portal-${uniqueNumber}'
    tags: {
      department: 'softwareDevDept'
      company: 'subContractor'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: Cyber enclave to defaultPortal endpoint
module ec_cyber_to_defaultPortal_cm_ep 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-cyber-portal-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCyber.outputs.enclaveResourceId
    destinationResourceId: communityEndpointDefaultPortal.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclaveCyber.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-cyber-portal-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// -------------------Identity Connections-------------------
// Connection: Collaboration enclave to Identity enclave ADDS endpoint
module ec_collab_to_identity_adds 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-coll-idadds-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCollab.outputs.enclaveResourceId
    destinationResourceId: enclaveIdentity_endpointName_1_v2.outputs.endpointId
    sourceAddressSpace: filter(enclaveCollab.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-coll-idadds-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: Desktop enclave to Identity enclave ADDS endpoint
module ec_desktop_to_identity_adds 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-desk-idadds-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveDesktop.outputs.enclaveResourceId
    destinationResourceId: enclaveIdentity_endpointName_1_v2.outputs.endpointId
    sourceAddressSpace: filter(enclaveDesktop.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-desk-idadds-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: Platform enclave to Identity enclave ADDS endpoint
module ec_platform_to_identity_adds 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-plat-idadds-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclavePlatform.outputs.enclaveResourceId
    destinationResourceId: enclaveIdentity_endpointName_1_v2.outputs.endpointId
    sourceAddressSpace: filter(enclavePlatform.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-plat-idadds-${uniqueNumber}'
    tags: {
      department: 'platforms'
      company: 'primeContractor'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: Weapon enclave to Identity enclave ADDS endpoint
module ec_weapon_to_identity_adds 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-weap-idadds-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveWeapon.outputs.enclaveResourceId
    destinationResourceId: enclaveIdentity_endpointName_1_v2.outputs.endpointId
    sourceAddressSpace: filter(enclaveWeapon.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-weap-idadds-${uniqueNumber}'
    tags: {
      department: 'pewPewDept'
      company: 'weaponContractor'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: SubKtr enclave to Identity enclave ADDS endpoint
module ec_subktr_to_identity_adds 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-sub-idadds-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveSubKtr.outputs.enclaveResourceId
    destinationResourceId: enclaveIdentity_endpointName_1_v2.outputs.endpointId
    sourceAddressSpace: filter(enclaveSubKtr.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-sub-idadds-${uniqueNumber}'
    tags: {
      department: 'softwareDevDept'
      company: 'subContractor'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: Cyber enclave to Identity enclave ADDS endpoint
module ec_cyber_to_identity_adds 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-cyber-idadds-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCyber.outputs.enclaveResourceId
    destinationResourceId: enclaveIdentity_endpointName_1_v2.outputs.endpointId
    sourceAddressSpace: filter(enclaveCyber.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-cyber-idadds-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// -------------------Cyber Enclave Connections-------------------
// Connection: Cyber enclave to identity endpoint
module ec_cyber_to_identity 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-cyber-id-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCyber.outputs.enclaveResourceId
    destinationResourceId: ep_enclaveIdentity_cyber.outputs.endpointId
    sourceAddressSpace: filter(enclaveCyber.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-cyber-id-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: Cyber enclave to desktop endpoint
module ec_cyber_to_desktop 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-cyber-desk-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCyber.outputs.enclaveResourceId
    destinationResourceId: ep_enclaveDesktop_cyber.outputs.endpointId
    sourceAddressSpace: filter(enclaveCyber.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-cyber-desk-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: Cyber enclave to collab endpoint
module ec_cyber_to_collab 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-cyber-coll-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCyber.outputs.enclaveResourceId
    destinationResourceId: ep_enclaveCollab_cyber.outputs.endpointId
    sourceAddressSpace: filter(enclaveCyber.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-cyber-coll-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: Cyber enclave to platform endpoint
module ec_cyber_to_platform 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-cyber-plat-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCyber.outputs.enclaveResourceId
    destinationResourceId: ep_enclavePlatform_cyber.outputs.endpointId
    sourceAddressSpace: filter(enclaveCyber.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-cyber-plat-${uniqueNumber}'
    tags: {
      department: 'platforms'
      company: 'primeContractor'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: Cyber enclave to weapon endpoint
module ec_cyber_to_weapon 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-cyber-weap-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCyber.outputs.enclaveResourceId
    destinationResourceId: ep_enclaveWeapon_cyber.outputs.endpointId
    sourceAddressSpace: filter(enclaveCyber.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-cyber-weap-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: Cyber enclave to SubKtr endpoint
module ec_cyber_to_subktr 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-cyber-sub-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCyber.outputs.enclaveResourceId
    destinationResourceId: ep_enclaveSubKtr_cyber.outputs.endpointId
    sourceAddressSpace: filter(enclaveCyber.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-cyber-sub-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
  ]
}

// -------------------Data Connections-------------------
// Connection: Desktop enclave to data source community endpoint
module ec_desktop_to_cm_ep_bingOutlook 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-desk-data-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveDesktop.outputs.enclaveResourceId
    destinationResourceId: communityEndpointDataSource.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclaveDesktop.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-desk-data-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// -------------------Windows Update Connections-------------------
// Connection: Identity Windows Update
module ec_identity_to_cm_ep_win_update 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-id-winupd-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveIdentity.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWindowsUpdates.outputs.communityEndpointResourceId
    sourceAddressSpace: '${join(map(enclaveIdentity.outputs.enclaveSubnetConfig, s => s.addressPrefix), ', ')}, ${split(enclaveIdentity.outputs.managedAddressSpace, '/')[0]}/26'
    location: location
    connectionName: 'ec-id-winupd-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWinget
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: Collaboration Windows Update
module ec_collab_to_cm_ep_win_update 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-coll-winupd-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCollab.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWindowsUpdates.outputs.communityEndpointResourceId
    sourceAddressSpace: '${join(map(enclaveCollab.outputs.enclaveSubnetConfig, s => s.addressPrefix), ', ')}, ${split(enclaveCollab.outputs.managedAddressSpace, '/')[0]}/26'
    location: location
    connectionName: 'ec-coll-winupd-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWinget
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: Desktop Windows Update
module ec_desktop_to_cm_ep_win_update 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-desk-winupd-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveDesktop.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWindowsUpdates.outputs.communityEndpointResourceId
    sourceAddressSpace: '${join(map(enclaveDesktop.outputs.enclaveSubnetConfig, s => s.addressPrefix), ', ')}, ${split(enclaveDesktop.outputs.managedAddressSpace, '/')[0]}/26'
    location: location
    connectionName: 'ec-desk-winupd-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWinget
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: Platform Windows Update
module ec_platform_to_cm_ep_win_update 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-plat-winupd-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclavePlatform.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWindowsUpdates.outputs.communityEndpointResourceId
    sourceAddressSpace: '${join(map(enclavePlatform.outputs.enclaveSubnetConfig, s => s.addressPrefix), ', ')}, ${split(enclavePlatform.outputs.managedAddressSpace, '/')[0]}/26'
    location: location
    connectionName: 'ec-plat-winupd-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWinget
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: Weapon Windows Update
module ec_weapon_to_cm_ep_win_update 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-weap-winupd-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveWeapon.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWindowsUpdates.outputs.communityEndpointResourceId
    sourceAddressSpace: '${join(map(enclaveWeapon.outputs.enclaveSubnetConfig, s => s.addressPrefix), ', ')}, ${split(enclaveWeapon.outputs.managedAddressSpace, '/')[0]}/26'
    location: location
    connectionName: 'ec-weap-winupd-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWinget
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: SubKtr Windows Update
module ec_subktr_to_cm_ep_win_update 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-sub-winupd-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveSubKtr.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWindowsUpdates.outputs.communityEndpointResourceId
    sourceAddressSpace: '${join(map(enclaveSubKtr.outputs.enclaveSubnetConfig, s => s.addressPrefix), ', ')}, ${split(enclaveSubKtr.outputs.managedAddressSpace, '/')[0]}/26'
    location: location
    connectionName: 'ec-sub-winupd-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWinget
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: Cyber Windows Update
module ec_cyber_to_cm_ep_win_update 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-cyber-winupd-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCyber.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWindowsUpdates.outputs.communityEndpointResourceId
    sourceAddressSpace: '${join(map(enclaveCyber.outputs.enclaveSubnetConfig, s => s.addressPrefix), ', ')}, ${split(enclaveCyber.outputs.managedAddressSpace, '/')[0]}/26'
    location: location
    connectionName: 'ec-cyber-winupd-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWinget
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}
// -------------------Winget Connections-------------------
// Connection: Identity to Winget
module ec_identity_to_cm_ep_winget 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-id-winget-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveIdentity.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWinget.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclaveIdentity.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-id-winget-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: Collaboration Winget
module ec_collab_to_cm_ep_winget 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-coll-winget-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCollab.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWinget.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclaveCollab.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-coll-winget-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: Desktop Winget
module ec_desktop_to_cm_ep_winget 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-desk-winget-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveDesktop.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWinget.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclaveDesktop.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-desk-winget-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: Platform Winget
module ec_platform_to_cm_ep_winget 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-plat-winget-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclavePlatform.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWinget.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclavePlatform.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-plat-winget-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: Weapon Winget
module ec_weapon_to_cm_ep_winget 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-weap-winget-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveWeapon.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWinget.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclaveWeapon.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-weap-winget-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: SubKtr Winget
module ec_subktr_to_cm_ep_winget 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-sub-winget-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveSubKtr.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWinget.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclaveSubKtr.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-sub-winget-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: Cyber Winget
module ec_cyber_to_cm_ep_winget 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-cyber-winget-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCyber.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWinget.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclaveCyber.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-cyber-winget-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}
// -------------------Enclave to Enclave Connections-------------------
// Connection: Platform enclave to Weapon enclave
module ec_platform_to_weapon 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-plat-weap-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclavePlatform.outputs.enclaveResourceId
    destinationResourceId: ep_enclaveWeapon_from_platform.outputs.endpointId
    sourceAddressSpace: filter(enclavePlatform.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-plat-weap-${uniqueNumber}'
    tags: {
      department: 'platforms'
      company: 'primeContractor'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: Weapon enclave to Platform enclave
module ec_weapon_to_platform 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-weap-plat-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveWeapon.outputs.enclaveResourceId
    destinationResourceId: ep_enclavePlatform_from_weapon.outputs.endpointId
    sourceAddressSpace: filter(enclaveWeapon.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-weap-plat-${uniqueNumber}'
    tags: {
      department: 'pewPewDept'
      company: 'weaponContractor'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: Weapon enclave to SubKtr enclave
module ec_weapon_to_subktr 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-weap-sub-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveWeapon.outputs.enclaveResourceId
    destinationResourceId: ep_enclaveSubKtr_from_weapon.outputs.endpointId
    sourceAddressSpace: filter(enclaveWeapon.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-weap-sub-${uniqueNumber}'
    tags: {
      department: 'pewPewDept'
      company: 'weaponContractor'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: SubKtr enclave to Weapon enclave
module ec_subktr_to_weapon 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-sub-weap-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveSubKtr.outputs.enclaveResourceId
    destinationResourceId: ep_enclaveWeapon_from_subktr.outputs.endpointId
    sourceAddressSpace: filter(enclaveSubKtr.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    location: location
    connectionName: 'ec-sub-weap-${uniqueNumber}'
    tags: {
      department: 'softwareDevDept'
      company: 'subContractor'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// -------------------Transit Hub Connections-------------------
// Connection: Transithub to Identity enclave ADDS endpoint
module ec_external_to_identity_adds 'modules/enclave-connection.bicep' = {
  name: 'deploy-ec-ext-idadds-${uniqueNumber}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: transitHub.outputs.transitHubResourceId
    destinationResourceId: enclaveIdentity_endpointName_1_v2.outputs.endpointId
    sourceAddressSpace: '172.16.18.0/24'
    location: location
    connectionName: 'ec-ext-idadds-${uniqueNumber}'
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    ep_enclavePlatform_from_weapon
    ep_enclaveWeapon_from_platform
    ep_enclaveWeapon_from_subktr
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}
