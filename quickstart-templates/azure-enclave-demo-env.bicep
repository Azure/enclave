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

// Enclaves
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
    allowSubnetCommunication: true
    maintenanceModeConfiguration: maintenanceModeConfig
    includeApprovalSettings: false
    deployWorkload: true
    workloadNames: [
      'wl-id-ADDS-${uniqueNumber}'
    ]
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
    allowSubnetCommunication: true
    maintenanceModeConfiguration: maintenanceModeConfig
    includeApprovalSettings: false
    deployWorkload: true
    workloadNames: [
      'wl-collab-apps-${uniqueNumber}'
    ]
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
    allowSubnetCommunication: true
    maintenanceModeConfiguration: maintenanceModeConfig
    includeApprovalSettings: false
    deployWorkload: true
    workloadNames: [
      'wl-desktops-${uniqueNumber}'
    ]
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
    workloadTags: {
      department: 'platforms'
      company: 'primeContractor'
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
    allowSubnetCommunication: true
    maintenanceModeConfiguration: maintenanceModeConfig
    includeApprovalSettings: false
    deployWorkload: true
    workloadNames: [
      'wl-platform-apps-${uniqueNumber}'
    ]
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
    workloadTags: {
      department: 'pewPewDept'
      company: 'weaponContractor'
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
    allowSubnetCommunication: true
    maintenanceModeConfiguration: maintenanceModeConfig
    includeApprovalSettings: false
    deployWorkload: true
    workloadNames: [
      'wl-weapon-apps-${uniqueNumber}'
    ]
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
    workloadTags: {
      department: 'softwareDevDept'
      company: 'subContractor'
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
    allowSubnetCommunication: true
    maintenanceModeConfiguration: maintenanceModeConfig
    includeApprovalSettings: false
    deployWorkload: true
    workloadNames: [
      'wl-subktr-apps-${uniqueNumber}'
    ]
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
    allowSubnetCommunication: true
    maintenanceModeConfiguration: maintenanceModeConfig
    includeApprovalSettings: false
    deployWorkload: true
    workloadNames: [
      'wl-cyber-apps-${uniqueNumber}'
    ]
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
    workloadTags: {
      department: 'sensitiveDataDept'
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
    allowSubnetCommunication: true
    maintenanceModeConfiguration: maintenanceModeConfig
    includeApprovalSettings: false
    deployWorkload: true
    workloadNames: [
      'wl-offline-apps-${uniqueNumber}'
    ]
    workloadResourceGroupName: 'rg-offline-apps-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
  }
}

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
    includeUpdateMode: false
  }
}

// Enclave Endpoint: Platform to Weapon
module ep_enclavePlatform_from_weapon 'modules/enclave-endpoint.bicep' = {
  name: 'deploy-ee-platform-from-weapon-${uniqueNumber}'
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
    includeUpdateMode: false
  }
}

// Enclave Endpoint: Weapon from Platform
module ep_enclaveWeapon_from_platform 'modules/enclave-endpoint.bicep' = {
  name: 'deploy-ee-weapon-from-platform-${uniqueNumber}'
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
    includeUpdateMode: false
  }
}

// Enclave Endpoint: Weapon from SubKtr
module ep_enclaveWeapon_from_subktr 'modules/enclave-endpoint.bicep' = {
  name: 'deploy-ee-weapon-from-subktr-${uniqueNumber}'
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
    includeUpdateMode: false
  }
}

// Enclave Endpoint: SubKtr from Weapon
module ep_enclaveSubKtr_from_weapon 'modules/enclave-endpoint.bicep' = {
  name: 'deploy-ee-subktr-from-weapon-${uniqueNumber}'
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
    includeUpdateMode: false
  }
}

// Enclave Endpoint: Cyber inbound
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
    includeUpdateMode: false
  }
}

// Enclave Endpoint: Cyber inbound
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
    includeUpdateMode: false
  }
}

// Enclave Endpoint: Cyber inbound
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
    includeUpdateMode: false
  }
}

// Enclave Endpoint: Cyber inbound
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
    includeUpdateMode: false
  }
}

// Enclave Endpoint: Cyber inbound
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
    includeUpdateMode: false
  }
}

// Enclave Endpoint: Cyber inbound
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
    includeUpdateMode: false
  }
}

// ====================================================================
// ENCLAVE CONNECTIONS
// All connections are created together after all endpoints are ready
// ====================================================================

// -------------------External Connections-------------------
// Connection: Collaboration enclave to external community endpoint
#disable-next-line BCP081
resource ec_collab_to_external 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-collab-to-external-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCollab.outputs.enclaveResourceId
    sourceCidr: filter(enclaveCollab.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: communityEndpointExternal.outputs.communityEndpointResourceId
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
#disable-next-line BCP081
resource ec_collab_to_defaultPortal_cm_ep 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-collab-to-defaultPortal-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCollab.outputs.enclaveResourceId
    sourceCidr: filter(enclaveCollab.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: communityEndpointDefaultPortal.outputs.communityEndpointResourceId
  }
  dependsOn: [
    communityEndpointExternal
    #disable-next-line no-unnecessary-dependson
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

// Connection: Desktop enclave to defaultPortal endpoint
#disable-next-line BCP081
resource ec_desktop_to_defaultPortal_cm_ep 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-desktop-to-defaultPortal-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveDesktop.outputs.enclaveResourceId
    sourceCidr: filter(enclaveDesktop.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: communityEndpointDefaultPortal.outputs.communityEndpointResourceId
  }
  dependsOn: [
    communityEndpointExternal
    #disable-next-line no-unnecessary-dependson
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

// Connection: Platform enclave to defaultPortal endpoint
#disable-next-line BCP081
resource ec_platform_to_defaultPortal_cm_ep 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-platform-to-defaultPortal-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'platforms'
    company: 'primeContractor'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclavePlatform.outputs.enclaveResourceId
    sourceCidr: filter(enclavePlatform.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: communityEndpointDefaultPortal.outputs.communityEndpointResourceId
  }
  dependsOn: [
    communityEndpointExternal
    #disable-next-line no-unnecessary-dependson
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

// Connection: Weapon enclave to defaultPortal endpoint
#disable-next-line BCP081
resource ec_weapon_to_defaultPortal_cm_ep 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-weapon-to-defaultPortal-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'pewPewDept'
    company: 'weaponContractor'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveWeapon.outputs.enclaveResourceId
    sourceCidr: filter(enclaveWeapon.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: communityEndpointDefaultPortal.outputs.communityEndpointResourceId
  }
  dependsOn: [
    communityEndpointExternal
    #disable-next-line no-unnecessary-dependson
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

// Connection: SubKtr enclave to defaultPortal endpoint
#disable-next-line BCP081
resource ec_subktr_to_defaultPortal_cm_ep 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-subktr-to-defaultPortal-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'softwareDevDept'
    company: 'subContractor'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveSubKtr.outputs.enclaveResourceId
    sourceCidr: filter(enclaveSubKtr.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: communityEndpointDefaultPortal.outputs.communityEndpointResourceId
  }
  dependsOn: [
    communityEndpointExternal
    #disable-next-line no-unnecessary-dependson
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

// Connection: Cyber enclave to defaultPortal endpoint
#disable-next-line BCP081
resource ec_cyber_to_defaultPortal_cm_ep 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-cyber-to-defaultPortal-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCyber.outputs.enclaveResourceId
    sourceCidr: filter(enclaveCyber.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: communityEndpointDefaultPortal.outputs.communityEndpointResourceId
  }
  dependsOn: [
    communityEndpointExternal
    #disable-next-line no-unnecessary-dependson
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

// -------------------Identity Connections-------------------
// Connection: Collaboration enclave to Identity enclave ADDS endpoint
#disable-next-line BCP081
resource ec_collab_to_identity_adds 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-collab-to-identity-adds-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCollab.outputs.enclaveResourceId
    sourceCidr: filter(enclaveCollab.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: enclaveIdentity_endpointName_1_v2.outputs.endpointId
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    #disable-next-line no-unnecessary-dependson
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

// Connection: Desktop enclave to Identity enclave ADDS endpoint
#disable-next-line BCP081
resource ec_desktop_to_identity_adds 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-desktop-to-identity-adds-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveDesktop.outputs.enclaveResourceId
    sourceCidr: filter(enclaveDesktop.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: enclaveIdentity_endpointName_1_v2.outputs.endpointId
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    #disable-next-line no-unnecessary-dependson
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

// Connection: Platform enclave to Identity enclave ADDS endpoint
#disable-next-line BCP081
resource ec_platform_to_identity_adds 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-platform-to-identity-adds-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'platforms'
    company: 'primeContractor'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclavePlatform.outputs.enclaveResourceId
    sourceCidr: filter(enclavePlatform.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: enclaveIdentity_endpointName_1_v2.outputs.endpointId
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    #disable-next-line no-unnecessary-dependson
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

// Connection: Weapon enclave to Identity enclave ADDS endpoint
#disable-next-line BCP081
resource ec_weapon_to_identity_adds 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-weapon-to-identity-adds-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'pewPewDept'
    company: 'weaponContractor'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveWeapon.outputs.enclaveResourceId
    sourceCidr: filter(enclaveWeapon.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: enclaveIdentity_endpointName_1_v2.outputs.endpointId
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    #disable-next-line no-unnecessary-dependson
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

// Connection: SubKtr enclave to Identity enclave ADDS endpoint
#disable-next-line BCP081
resource ec_subktr_to_identity_adds 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-subktr-to-identity-adds-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'softwareDevDept'
    company: 'subContractor'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveSubKtr.outputs.enclaveResourceId
    sourceCidr: filter(enclaveSubKtr.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: enclaveIdentity_endpointName_1_v2.outputs.endpointId
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    #disable-next-line no-unnecessary-dependson
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

// Connection: Cyber enclave to Identity enclave ADDS endpoint
#disable-next-line BCP081
resource ec_cyber_to_identity_adds 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-cyber-to-identity-adds-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCyber.outputs.enclaveResourceId
    sourceCidr: filter(enclaveCyber.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: enclaveIdentity_endpointName_1_v2.outputs.endpointId
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    #disable-next-line no-unnecessary-dependson
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

// -------------------Cyber Enclave Connections-------------------
// Connection: Cyber enclave to identity endpoint
#disable-next-line BCP081
resource ec_cyber_to_identity 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-cyber-to-identity-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCyber.outputs.enclaveResourceId
    sourceCidr: filter(enclaveCyber.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: ep_enclaveIdentity_cyber.outputs.endpointId
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
    #disable-next-line no-unnecessary-dependson
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: Cyber enclave to desktop endpoint
#disable-next-line BCP081
resource ec_cyber_to_desktop 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-cyber-to-desktop-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCyber.outputs.enclaveResourceId
    sourceCidr: filter(enclaveCyber.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: ep_enclaveDesktop_cyber.outputs.endpointId
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
    #disable-next-line no-unnecessary-dependson
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: Cyber enclave to collab endpoint
#disable-next-line BCP081
resource ec_cyber_to_collab 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-cyber-to-collab-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCyber.outputs.enclaveResourceId
    sourceCidr: filter(enclaveCyber.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: ep_enclaveCollab_cyber.outputs.endpointId
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
    #disable-next-line no-unnecessary-dependson
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: Cyber enclave to platform endpoint
#disable-next-line BCP081
resource ec_cyber_to_platform 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-cyber-to-platform-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'platforms'
    company: 'primeContractor'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCyber.outputs.enclaveResourceId
    sourceCidr: filter(enclaveCyber.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: ep_enclavePlatform_cyber.outputs.endpointId
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
    #disable-next-line no-unnecessary-dependson
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: Cyber enclave to weapon endpoint
#disable-next-line BCP081
resource ec_cyber_to_weapon 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-cyber-to-weapon-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCyber.outputs.enclaveResourceId
    sourceCidr: filter(enclaveCyber.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: ep_enclaveWeapon_cyber.outputs.endpointId
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
    #disable-next-line no-unnecessary-dependson
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: Cyber enclave to SubKtr endpoint
#disable-next-line BCP081
resource ec_cyber_to_subktr 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-cyber-to-subktr-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCyber.outputs.enclaveResourceId
    sourceCidr: filter(enclaveCyber.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: ep_enclaveSubKtr_cyber.outputs.endpointId
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
    #disable-next-line no-unnecessary-dependson
    ep_enclaveSubKtr_cyber
  ]
}

// -------------------Data Connections-------------------
// Connection: Desktop enclave to Bing&Outlook community endpoint
#disable-next-line BCP081
resource ec_desktop_to_cm_ep_bingOutlook 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-desktop-to-ce-bing-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveDesktop.outputs.enclaveResourceId
    sourceCidr: filter(enclaveDesktop.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: communityEndpointDataSource.outputs.communityEndpointResourceId
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    #disable-next-line no-unnecessary-dependson
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

// -------------------Windows Update Connections-------------------
// Connection: Identity Windows Update
#disable-next-line BCP081
resource ec_identity_to_cm_ep_win_update 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-identity-to-ce-win-update-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveIdentity.outputs.enclaveResourceId
    sourceCidr: '${join(map(enclaveIdentity.outputs.enclaveSubnetConfig, s => s.addressPrefix), ', ')}, ${split(enclaveIdentity.outputs.managedAddressSpace, '/')[0]}/26'
    destinationEndpointId: communityEndpointWindowsUpdates.outputs.communityEndpointResourceId
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    #disable-next-line no-unnecessary-dependson
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

// Connection: Collaboration Windows Update
#disable-next-line BCP081
resource ec_collab_to_cm_ep_win_update 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-collab-to-ce-win-update-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCollab.outputs.enclaveResourceId
    sourceCidr: '${join(map(enclaveCollab.outputs.enclaveSubnetConfig, s => s.addressPrefix), ', ')}, ${split(enclaveCollab.outputs.managedAddressSpace, '/')[0]}/26'
    destinationEndpointId: communityEndpointWindowsUpdates.outputs.communityEndpointResourceId
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    #disable-next-line no-unnecessary-dependson
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

// Connection: Desktop Windows Update
#disable-next-line BCP081
resource ec_desktop_to_cm_ep_win_update 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-desktop-to-ce-win-update-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveDesktop.outputs.enclaveResourceId
    sourceCidr: '${join(map(enclaveDesktop.outputs.enclaveSubnetConfig, s => s.addressPrefix), ', ')}, ${split(enclaveDesktop.outputs.managedAddressSpace, '/')[0]}/26'
    destinationEndpointId: communityEndpointWindowsUpdates.outputs.communityEndpointResourceId
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    #disable-next-line no-unnecessary-dependson
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

// Connection: Platform Windows Update
#disable-next-line BCP081
resource ec_platform_to_cm_ep_win_update 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-platform-to-ce-win-update-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclavePlatform.outputs.enclaveResourceId
    sourceCidr: '${join(map(enclavePlatform.outputs.enclaveSubnetConfig, s => s.addressPrefix), ', ')}, ${split(enclavePlatform.outputs.managedAddressSpace, '/')[0]}/26'
    destinationEndpointId: communityEndpointWindowsUpdates.outputs.communityEndpointResourceId
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    #disable-next-line no-unnecessary-dependson
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

// Connection: Weapon Windows Update
#disable-next-line BCP081
resource ec_weapon_to_cm_ep_win_update 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-weapon-to-ce-win-update-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveWeapon.outputs.enclaveResourceId
    sourceCidr: '${join(map(enclaveWeapon.outputs.enclaveSubnetConfig, s => s.addressPrefix), ', ')}, ${split(enclaveWeapon.outputs.managedAddressSpace, '/')[0]}/26'
    destinationEndpointId: communityEndpointWindowsUpdates.outputs.communityEndpointResourceId
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    #disable-next-line no-unnecessary-dependson
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

// Connection: SubKtr Windows Update
#disable-next-line BCP081
resource ec_subktr_to_cm_ep_win_update 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-subktr-to-ce-win-update-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveSubKtr.outputs.enclaveResourceId
    sourceCidr: '${join(map(enclaveSubKtr.outputs.enclaveSubnetConfig, s => s.addressPrefix), ', ')}, ${split(enclaveSubKtr.outputs.managedAddressSpace, '/')[0]}/26'
    destinationEndpointId: communityEndpointWindowsUpdates.outputs.communityEndpointResourceId
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    #disable-next-line no-unnecessary-dependson
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

// Connection: Cyber Windows Update
#disable-next-line BCP081
resource ec_cyber_to_cm_ep_win_update 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-cyber-to-ce-win-update-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCyber.outputs.enclaveResourceId
    sourceCidr: '${join(map(enclaveCyber.outputs.enclaveSubnetConfig, s => s.addressPrefix), ', ')}, ${split(enclaveCyber.outputs.managedAddressSpace, '/')[0]}/26'
    destinationEndpointId: communityEndpointWindowsUpdates.outputs.communityEndpointResourceId
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    #disable-next-line no-unnecessary-dependson
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

// // Connection: Offline Windows Update
// #disable-next-line BCP081
// resource ec_offline_to_cm_ep_win_update 'microsoft.mission/enclaveconnections@2026-04-01' = {
//   name: 'ec-offline-to-ce-win-update-${uniqueNumber}'
//   location: location
//   tags: {
//     department: 'CommunitySharedServices'
//     company: 'CommunityOversight'
//   }
//   properties: {
//     communityResourceId: community.outputs.resourceId
//     sourceResourceId: enclaveOffline.outputs.enclaveResourceId
//     sourceCidr: '${join(map(enclaveOffline.outputs.enclaveSubnetConfig, s => s.addressPrefix), ', ')}, ${split(enclaveOffline.outputs.managedAddressSpace, '/')[0]}/26'
//     destinationEndpointId: communityName_windows_updates.outputs.communityEndpointResourceId
//   }
// }

// -------------------Winget Connections-------------------
// Connection: Identity to Winget
#disable-next-line BCP081
resource ec_identity_to_cm_ep_winget 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-identity-to-ce-winget-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveIdentity.outputs.enclaveResourceId
    sourceCidr: filter(enclaveIdentity.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: communityEndpointWinget.outputs.communityEndpointResourceId
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    #disable-next-line no-unnecessary-dependson
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

// Connection: Collaboration Winget
#disable-next-line BCP081
resource ec_collab_to_cm_ep_winget 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-collab-to-ce-winget-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCollab.outputs.enclaveResourceId
    sourceCidr: filter(enclaveCollab.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: communityEndpointWinget.outputs.communityEndpointResourceId
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    #disable-next-line no-unnecessary-dependson
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

// Connection: Desktop Winget
#disable-next-line BCP081
resource ec_desktop_to_cm_ep_winget 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-desktop-to-ce-winget-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveDesktop.outputs.enclaveResourceId
    sourceCidr: filter(enclaveDesktop.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: communityEndpointWinget.outputs.communityEndpointResourceId
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    #disable-next-line no-unnecessary-dependson
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

// Connection: Platform Winget
#disable-next-line BCP081
resource ec_platform_to_cm_ep_winget 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-platform-to-ce-winget-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclavePlatform.outputs.enclaveResourceId
    sourceCidr: filter(enclavePlatform.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: communityEndpointWinget.outputs.communityEndpointResourceId
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    #disable-next-line no-unnecessary-dependson
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

// Connection: Weapon Winget
#disable-next-line BCP081
resource ec_weapon_to_cm_ep_winget 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-weapon-to-ce-winget-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveWeapon.outputs.enclaveResourceId
    sourceCidr: filter(enclaveWeapon.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: communityEndpointWinget.outputs.communityEndpointResourceId
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    #disable-next-line no-unnecessary-dependson
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

// Connection: SubKtr Winget
#disable-next-line BCP081
resource ec_subktr_to_cm_ep_winget 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-subktr-to-ce-winget-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveSubKtr.outputs.enclaveResourceId
    sourceCidr: filter(enclaveSubKtr.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: communityEndpointWinget.outputs.communityEndpointResourceId
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    #disable-next-line no-unnecessary-dependson
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

// Connection: Cyber Winget
#disable-next-line BCP081
resource ec_cyber_to_cm_ep_winget 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-cyber-to-ce-winget-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCyber.outputs.enclaveResourceId
    sourceCidr: filter(enclaveCyber.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: communityEndpointWinget.outputs.communityEndpointResourceId
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    #disable-next-line no-unnecessary-dependson
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

// // Connection: Offline Winget
// #disable-next-line BCP081
// resource ec_offline_to_cm_ep_winget 'microsoft.mission/enclaveconnections@2026-04-01' = {
//   name: 'ec-offline-to-ce-winget-${uniqueNumber}'
//   location: location
//   tags: {
//     department: 'CommunitySharedServices'
//     company: 'CommunityOversight'
//   }
//   properties: {
//     communityResourceId: community.outputs.resourceId
//     sourceResourceId: enclaveOffline.outputs.enclaveResourceId
//     sourceCidr: ((stage >= 5)
//       ? filter(enclaveOffline.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
//)
//     destinationEndpointId: communityName_winget.outputs.communityEndpointResourceId
//   }
// }

// -------------------Enclave to Enclave Connections-------------------
// Connection: Platform enclave to Weapon enclave
#disable-next-line BCP081
resource ec_platform_to_weapon 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-platform-to-weapon-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'platforms'
    company: 'primeContractor'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclavePlatform.outputs.enclaveResourceId
    sourceCidr: filter(enclavePlatform.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: ep_enclaveWeapon_from_platform.outputs.endpointId
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    ep_enclavePlatform_from_weapon
    #disable-next-line no-unnecessary-dependson
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

// Connection: Weapon enclave to Platform enclave
#disable-next-line BCP081
resource ec_weapon_to_platform 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-weapon-to-platform-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'pewPewDept'
    company: 'weaponContractor'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveWeapon.outputs.enclaveResourceId
    sourceCidr: filter(enclaveWeapon.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: ep_enclavePlatform_from_weapon.outputs.endpointId
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    enclaveIdentity_endpointName_1_v2
    #disable-next-line no-unnecessary-dependson
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

// Connection: Weapon enclave to SubKtr enclave
#disable-next-line BCP081
resource ec_weapon_to_subktr 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-weapon-to-subktr-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'pewPewDept'
    company: 'weaponContractor'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveWeapon.outputs.enclaveResourceId
    sourceCidr: filter(enclaveWeapon.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: ep_enclaveSubKtr_from_weapon.outputs.endpointId
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
    #disable-next-line no-unnecessary-dependson
    ep_enclaveSubKtr_from_weapon
    ep_enclaveIdentity_cyber
    ep_enclaveDesktop_cyber
    ep_enclaveCollab_cyber
    ep_enclavePlatform_cyber
    ep_enclaveWeapon_cyber
    ep_enclaveSubKtr_cyber
  ]
}

// Connection: SubKtr enclave to Weapon enclave
#disable-next-line BCP081
resource ec_subktr_to_weapon 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-subktr-to-weapon-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'softwareDevDept'
    company: 'subContractor'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveSubKtr.outputs.enclaveResourceId
    sourceCidr: filter(enclaveSubKtr.outputs.enclaveSubnetConfig, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: ep_enclaveWeapon_from_subktr.outputs.endpointId
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
    #disable-next-line no-unnecessary-dependson
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

// -------------------Transit Hub Connections-------------------
// Connection: Transithub to Identity enclave ADDS endpoint
#disable-next-line BCP081
resource ec_external_to_identity_adds 'microsoft.mission/enclaveconnections@2026-04-01' = {
  name: 'ec-external-to-identity-adds-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: transitHub.outputs.transitHubResourceId
    sourceCidr: '172.16.18.0/24'
    destinationEndpointId: enclaveIdentity_endpointName_1_v2.outputs.endpointId
  }
  dependsOn: [
    communityEndpointExternal
    communityEndpointDefaultPortal
    communityEndpointWindowsUpdates
    communityEndpointWinget
    communityEndpointDataSource
    #disable-next-line no-unnecessary-dependson
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
