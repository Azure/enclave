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
#disable-next-line BCP081
resource enclaveIdentity 'Microsoft.Mission/virtualenclaves@2025-05-01-preview' = {
  name: '${uniqueEnclaveNamePrefix}-identity'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    enclaveVirtualNetwork: {
      networkSize: networkSize
      subnetConfigurations: [
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
    }
    maintenanceModeConfiguration: maintenanceModeConfig
  }
}

// Enclave: Collaboration
#disable-next-line BCP081
resource enclaveCollab 'Microsoft.Mission/virtualenclaves@2025-05-01-preview' = {
  name: '${uniqueEnclaveNamePrefix}-collab'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    enclaveVirtualNetwork: {
      networkSize: networkSize
      subnetConfigurations: [
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
    }
    maintenanceModeConfiguration: maintenanceModeConfig
  }
}

// Enclave: Desktop
#disable-next-line BCP081
resource enclaveDesktop 'Microsoft.Mission/virtualenclaves@2025-05-01-preview' = {
  name: '${uniqueEnclaveNamePrefix}-desktop'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    enclaveVirtualNetwork: {
      networkSize: networkSize
      subnetConfigurations: [
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
    }
    maintenanceModeConfiguration: maintenanceModeConfig
  }
}

// Enclave: Platform
#disable-next-line BCP081
resource enclavePlatform 'Microsoft.Mission/virtualenclaves@2025-05-01-preview' = {
  name: '${uniqueEnclaveNamePrefix}-platform'
  location: location
  tags: {
    department: 'platforms'
    company: 'PrimeContractor'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    enclaveVirtualNetwork: {
      networkSize: networkSize
      subnetConfigurations: [
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
    }
    maintenanceModeConfiguration: maintenanceModeConfig
  }
}

// Enclave: Weapon
#disable-next-line BCP081
resource enclaveWeapon 'Microsoft.Mission/virtualenclaves@2025-05-01-preview' = {
  name: '${uniqueEnclaveNamePrefix}-weapon'
  location: location
  tags: {
    department: 'PewPewDept'
    company: 'WeaponContractor'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    enclaveVirtualNetwork: {
      networkSize: networkSize
      subnetConfigurations: [
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
    }
    maintenanceModeConfiguration: maintenanceModeConfig
  }
}

// Enclave: SubKtr
#disable-next-line BCP081
resource enclaveSubKtr 'Microsoft.Mission/virtualenclaves@2025-05-01-preview' = {
  name: '${uniqueEnclaveNamePrefix}-subktr'
  location: location
  tags: {
    department: 'SoftwareDevDept'
    company: 'Subcontractor'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    enclaveVirtualNetwork: {
      networkSize: networkSize
      subnetConfigurations: [
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
    }
    maintenanceModeConfiguration: maintenanceModeConfig
  }
}

// Enclave: Cyber
#disable-next-line BCP081
resource enclaveCyber 'Microsoft.Mission/virtualenclaves@2025-05-01-preview' = {
  name: '${uniqueEnclaveNamePrefix}-cyber'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    enclaveVirtualNetwork: {
      networkSize: networkSize
      subnetConfigurations: [
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
    }
    maintenanceModeConfiguration: maintenanceModeConfig
  }
}

// Enclave: Offline
#disable-next-line BCP081
resource enclaveOffline 'Microsoft.Mission/virtualenclaves@2025-05-01-preview' = {
  name: '${uniqueEnclaveNamePrefix}-offline'
  location: location
  tags: {
    department: 'SensitiveDataDept'
    company: 'R&D_Collaboration'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    enclaveVirtualNetwork: {
      networkSize: networkSize
      subnetConfigurations: [
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
    }
    maintenanceModeConfiguration: maintenanceModeConfig
  }
}

// -------------------Workloads-------------------
// Workload: Identity enclave
#disable-next-line BCP081
resource wl_enclaveIdentity_adds 'Microsoft.Mission/virtualEnclaves/workloads@2025-05-01-preview' = {
  name: 'wl-id-ADDS-${uniqueNumber}'
  parent: enclaveIdentity
  properties: {
    resourceGroupCollection: [
      '${subscription().id}/resourcegroups/rg-id-ADDS-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
    ]
  }
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
}

// Workload: Desktop enclave
#disable-next-line BCP081
resource wl_enclaveDesktop_desktop 'Microsoft.Mission/virtualEnclaves/workloads@2025-05-01-preview' = {
  name: 'wl-desktops-${uniqueNumber}'
  parent: enclaveDesktop
  properties: {
    resourceGroupCollection: [
      '${subscription().id}/resourcegroups/rg-desktops-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
    ]
  }
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
}

// Workload: Collab enclave
#disable-next-line BCP081
resource wl_enclaveCollab_apps 'Microsoft.Mission/virtualEnclaves/workloads@2025-05-01-preview' = {
  name: 'wl-collab-apps-${uniqueNumber}'
  parent: enclaveCollab
  properties: {
    resourceGroupCollection: [
      '${subscription().id}/resourcegroups/rg-collab-apps-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
    ]
  }
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
}

// Workload: Platform enclave
#disable-next-line BCP081
resource wl_enclavePlatform_apps 'Microsoft.Mission/virtualEnclaves/workloads@2025-05-01-preview' = {
  name: 'wl-platform-apps-${uniqueNumber}'
  parent: enclavePlatform
  properties: {
    resourceGroupCollection: [
      '${subscription().id}/resourcegroups/rg-platform-apps-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
    ]
  }
  location: location
  tags: {
    department: 'platforms'
    company: 'primeContractor'
  }
}

// Workload: Weapon enclave
#disable-next-line BCP081
resource wl_enclaveWeapon_apps 'Microsoft.Mission/virtualEnclaves/workloads@2025-05-01-preview' = {
  name: 'wl-weapon-apps-${uniqueNumber}'
  parent: enclaveWeapon
  properties: {
    resourceGroupCollection: [
      '${subscription().id}/resourcegroups/rg-weapon-apps-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
    ]
  }
  location: location
  tags: {
    department: 'pewPewDept'
    company: 'weaponContractor'
  }
}

// Workload: SubKtr enclave
#disable-next-line BCP081
resource wl_enclaveSubKtr_apps 'Microsoft.Mission/virtualEnclaves/workloads@2025-05-01-preview' = {
  name: 'wl-subktr-apps-${uniqueNumber}'
  parent: enclaveSubKtr
  properties: {
    resourceGroupCollection: [
      '${subscription().id}/resourcegroups/rg-subktr-apps-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
    ]
  }
  location: location
  tags: {
    department: 'softwareDevDept'
    company: 'subContractor'
  }
}

// Workload: Cyber enclave
#disable-next-line BCP081
resource wl_enclaveCyber_apps 'Microsoft.Mission/virtualEnclaves/workloads@2025-05-01-preview' = {
  name: 'wl-cyber-apps-${uniqueNumber}'
  parent: enclaveCyber
  properties: {
    resourceGroupCollection: [
      '${subscription().id}/resourcegroups/rg-cyber-apps-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
    ]
  }
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
}

// Workload: Offline enclave
#disable-next-line BCP081
resource wl_enclaveOffline_apps 'Microsoft.Mission/virtualEnclaves/workloads@2025-05-01-preview' = {
  name: 'wl-offline-apps-${uniqueNumber}'
  parent: enclaveOffline
  properties: {
    resourceGroupCollection: [
      '${subscription().id}/resourcegroups/rg-offline-apps-${uniqueNumber}-${substring(uniqueString(deployment().name, location), 0, 4)}'
    ]
  }
  location: location
  tags: {
    department: 'sensitiveDataDept'
    company: 'R&D_Collaboration'
  }
}

// Enclave Endpoint: Identity enclave ADDS
#disable-next-line BCP081
resource enclaveIdentity_endpointName_1_v2 'Microsoft.Mission/virtualEnclaves/enclaveEndpoints@2025-05-01-preview' = {
  name: 'ee-ADDS'
  parent: enclaveIdentity
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    ruleCollection: [
      {
        endpointRuleName: 'ADDS-TCP'
        destination: filter(enclaveIdentity.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
        ports: '53,88,135,138,139,389,445,464,636,686,3268-3269,5722,9389,49152-65535'
        protocols: [
          'TCP'
        ]
      }
      {
        endpointRuleName: 'ADDS-UDP'
        destination: filter(enclaveIdentity.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
        ports: '53,389'
        protocols: [
          'UDP'
        ]
      }
    ]
  }
}

// Enclave Endpoint: Platform to Weapon
#disable-next-line BCP081
resource ep_enclavePlatform_from_weapon 'Microsoft.Mission/virtualEnclaves/enclaveEndpoints@2025-05-01-preview' = {
  name: 'ee-platform-from-weapon'
  parent: enclavePlatform
  location: location
  tags: {
    department: 'platforms'
    company: 'primeContractor'
  }
  properties: {
    ruleCollection: [
      {
        endpointRuleName: 'inbound-to-platform'
        destination: filter(enclavePlatform.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
        ports: '443'
        protocols: [
          'TCP'
        ]
      }
    ]
  }
}

// Enclave Endpoint: Weapon from Platform
#disable-next-line BCP081
resource ep_enclaveWeapon_from_platform 'Microsoft.Mission/virtualEnclaves/enclaveEndpoints@2025-05-01-preview' = {
  name: 'ee-weapon-from-platform'
  parent: enclaveWeapon
  location: location
  tags: {
    department: 'pewPewDept'
    company: 'weaponContractor'
  }
  properties: {
    ruleCollection: [
      {
        endpointRuleName: 'inbound-to-weapon'
        destination: filter(enclaveWeapon.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
        ports: '443'
        protocols: [
          'TCP'
        ]
      }
    ]
  }
}

// Enclave Endpoint: Weapon from SubKtr
#disable-next-line BCP081
resource ep_enclaveWeapon_from_subktr 'Microsoft.Mission/virtualEnclaves/enclaveEndpoints@2025-05-01-preview' = {
  name: 'ee-weapon-from-subktr'
  parent: enclaveWeapon
  location: location
  tags: {
    department: 'pewPewDept'
    company: 'weaponContractor'
  }
  properties: {
    ruleCollection: [
      {
        endpointRuleName: 'inbound-to-weapon'
        destination: filter(enclaveWeapon.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
        ports: '443'
        protocols: [
          'TCP'
        ]
      }
    ]
  }
}

// Enclave Endpoint: SubKtr from Weapon
#disable-next-line BCP081
resource ep_enclaveSubKtr_from_weapon 'Microsoft.Mission/virtualEnclaves/enclaveEndpoints@2025-05-01-preview' = {
  name: 'ee-subktr-from-weapon'
  parent: enclaveSubKtr
  location: location
  tags: {
    department: 'softwareDevDept'
    company: 'subContractor'
  }
  properties: {
    ruleCollection: [
      {
        endpointRuleName: 'inbound-to-subktr'
        destination: filter(enclaveSubKtr.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
        ports: '443'
        protocols: [
          'TCP'
        ]
      }
    ]
  }
}

// Enclave Endpoint: Cyber inbound
#disable-next-line BCP081
resource ep_enclaveIdentity_cyber 'Microsoft.Mission/virtualEnclaves/enclaveEndpoints@2025-05-01-preview' = {
  name: 'ee-identity-cyber'
  parent: enclaveIdentity
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    ruleCollection: [
      {
        endpointRuleName: 'cyber-inbound'
        destination: filter(enclaveIdentity.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
        ports: '443'
        protocols: [
          'TCP'
        ]
      }
    ]
  }
}

// Enclave Endpoint: Cyber inbound
#disable-next-line BCP081
resource ep_enclaveDesktop_cyber 'Microsoft.Mission/virtualEnclaves/enclaveEndpoints@2025-05-01-preview' = {
  name: 'ee-desktop-cyber'
  parent: enclaveDesktop
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    ruleCollection: [
      {
        endpointRuleName: 'cyber-inbound'
        destination: filter(enclaveDesktop.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
        ports: '443'
        protocols: [
          'TCP'
        ]
      }
    ]
  }
}

// Enclave Endpoint: Cyber inbound
#disable-next-line BCP081
resource ep_enclaveCollab_cyber 'Microsoft.Mission/virtualEnclaves/enclaveEndpoints@2025-05-01-preview' = {
  name: 'ee-collab-cyber'
  parent: enclaveCollab
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    ruleCollection: [
      {
        endpointRuleName: 'cyber-inbound'
        destination: filter(enclaveCollab.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
        ports: '443'
        protocols: [
          'TCP'
        ]
      }
    ]
  }
}

// Enclave Endpoint: Cyber inbound
#disable-next-line BCP081
resource ep_enclavePlatform_cyber 'Microsoft.Mission/virtualEnclaves/enclaveEndpoints@2025-05-01-preview' = {
  name: 'ee-platform-cyber'
  parent: enclavePlatform
  location: location
  tags: {
    department: 'platforms'
    company: 'primeContractor'
  }
  properties: {
    ruleCollection: [
      {
        endpointRuleName: 'cyber-inbound'
        destination: filter(enclavePlatform.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
        ports: '443'
        protocols: [
          'TCP'
        ]
      }
    ]
  }
}

// Enclave Endpoint: Cyber inbound
#disable-next-line BCP081
resource ep_enclaveWeapon_cyber 'Microsoft.Mission/virtualEnclaves/enclaveEndpoints@2025-05-01-preview' = {
  name: 'ee-weapon-cyber'
  parent: enclaveWeapon
  location: location
  tags: {
    department: 'pewPewDept'
    company: 'weaponContractor'
  }
  properties: {
    ruleCollection: [
      {
        endpointRuleName: 'cyber-inbound'
        destination: filter(enclaveWeapon.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
        ports: '443'
        protocols: [
          'TCP'
        ]
      }
    ]
  }
}

// Enclave Endpoint: Cyber inbound
#disable-next-line BCP081
resource ep_enclaveSubKtr_cyber 'Microsoft.Mission/virtualEnclaves/enclaveEndpoints@2025-05-01-preview' = {
  name: 'ee-subktr-cyber'
  parent: enclaveSubKtr
  location: location
  tags: {
    department: 'softwareDevDept'
    company: 'subContractor'
  }
  properties: {
    ruleCollection: [
      {
        endpointRuleName: 'cyber-inbound'
        destination: filter(enclaveSubKtr.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
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
#disable-next-line BCP081
resource ec_collab_to_external 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-collab-to-external-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCollab.id
    sourceCidr: filter(enclaveCollab.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
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
resource ec_collab_to_defaultPortal_cm_ep 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-collab-to-defaultPortal-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCollab.id
    sourceCidr: filter(enclaveCollab.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
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
resource ec_desktop_to_defaultPortal_cm_ep 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-desktop-to-defaultPortal-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveDesktop.id
    sourceCidr: filter(enclaveDesktop.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
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
resource ec_platform_to_defaultPortal_cm_ep 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-platform-to-defaultPortal-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'platforms'
    company: 'primeContractor'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclavePlatform.id
    sourceCidr: filter(enclavePlatform.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
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
resource ec_weapon_to_defaultPortal_cm_ep 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-weapon-to-defaultPortal-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'pewPewDept'
    company: 'weaponContractor'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveWeapon.id
    sourceCidr: filter(enclaveWeapon.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
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
resource ec_subktr_to_defaultPortal_cm_ep 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-subktr-to-defaultPortal-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'softwareDevDept'
    company: 'subContractor'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveSubKtr.id
    sourceCidr: filter(enclaveSubKtr.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
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
resource ec_cyber_to_defaultPortal_cm_ep 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-cyber-to-defaultPortal-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCyber.id
    sourceCidr: filter(enclaveCyber.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
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
resource ec_collab_to_identity_adds 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-collab-to-identity-adds-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCollab.id
    sourceCidr: filter(enclaveCollab.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: enclaveIdentity_endpointName_1_v2.id
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
resource ec_desktop_to_identity_adds 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-desktop-to-identity-adds-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveDesktop.id
    sourceCidr: filter(enclaveDesktop.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: enclaveIdentity_endpointName_1_v2.id
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
resource ec_platform_to_identity_adds 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-platform-to-identity-adds-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'platforms'
    company: 'primeContractor'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclavePlatform.id
    sourceCidr: filter(enclavePlatform.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: enclaveIdentity_endpointName_1_v2.id
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
resource ec_weapon_to_identity_adds 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-weapon-to-identity-adds-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'pewPewDept'
    company: 'weaponContractor'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveWeapon.id
    sourceCidr: filter(enclaveWeapon.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: enclaveIdentity_endpointName_1_v2.id
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
resource ec_subktr_to_identity_adds 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-subktr-to-identity-adds-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'softwareDevDept'
    company: 'subContractor'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveSubKtr.id
    sourceCidr: filter(enclaveSubKtr.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: enclaveIdentity_endpointName_1_v2.id
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
resource ec_cyber_to_identity_adds 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-cyber-to-identity-adds-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCyber.id
    sourceCidr: filter(enclaveCyber.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: enclaveIdentity_endpointName_1_v2.id
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
resource ec_cyber_to_identity 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-cyber-to-identity-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCyber.id
    sourceCidr: filter(enclaveCyber.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: ep_enclaveIdentity_cyber.id
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
resource ec_cyber_to_desktop 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-cyber-to-desktop-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCyber.id
    sourceCidr: filter(enclaveCyber.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: ep_enclaveDesktop_cyber.id
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
resource ec_cyber_to_collab 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-cyber-to-collab-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCyber.id
    sourceCidr: filter(enclaveCyber.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: ep_enclaveCollab_cyber.id
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
resource ec_cyber_to_platform 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-cyber-to-platform-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'platforms'
    company: 'primeContractor'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCyber.id
    sourceCidr: filter(enclaveCyber.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: ep_enclavePlatform_cyber.id
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
resource ec_cyber_to_weapon 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-cyber-to-weapon-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCyber.id
    sourceCidr: filter(enclaveCyber.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: ep_enclaveWeapon_cyber.id
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
resource ec_cyber_to_subktr 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-cyber-to-subktr-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCyber.id
    sourceCidr: filter(enclaveCyber.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: ep_enclaveSubKtr_cyber.id
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
resource ec_desktop_to_cm_ep_bingOutlook 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-desktop-to-ce-bing-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveDesktop.id
    sourceCidr: filter(enclaveDesktop.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
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
resource ec_identity_to_cm_ep_win_update 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-identity-to-ce-win-update-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveIdentity.id
    sourceCidr: '${join(map(enclaveIdentity.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.addressPrefix), ', ')}, ${split(enclaveIdentity.properties.enclaveAddressSpaces.managedAddressSpace, '/')[0]}/26'
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
resource ec_collab_to_cm_ep_win_update 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-collab-to-ce-win-update-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCollab.id
    sourceCidr: '${join(map(enclaveCollab.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.addressPrefix), ', ')}, ${split(enclaveCollab.properties.enclaveAddressSpaces.managedAddressSpace, '/')[0]}/26'
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
resource ec_desktop_to_cm_ep_win_update 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-desktop-to-ce-win-update-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveDesktop.id
    sourceCidr: '${join(map(enclaveDesktop.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.addressPrefix), ', ')}, ${split(enclaveDesktop.properties.enclaveAddressSpaces.managedAddressSpace, '/')[0]}/26'
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
resource ec_platform_to_cm_ep_win_update 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-platform-to-ce-win-update-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclavePlatform.id
    sourceCidr: '${join(map(enclavePlatform.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.addressPrefix), ', ')}, ${split(enclavePlatform.properties.enclaveAddressSpaces.managedAddressSpace, '/')[0]}/26'
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
resource ec_weapon_to_cm_ep_win_update 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-weapon-to-ce-win-update-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveWeapon.id
    sourceCidr: '${join(map(enclaveWeapon.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.addressPrefix), ', ')}, ${split(enclaveWeapon.properties.enclaveAddressSpaces.managedAddressSpace, '/')[0]}/26'
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
resource ec_subktr_to_cm_ep_win_update 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-subktr-to-ce-win-update-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveSubKtr.id
    sourceCidr: '${join(map(enclaveSubKtr.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.addressPrefix), ', ')}, ${split(enclaveSubKtr.properties.enclaveAddressSpaces.managedAddressSpace, '/')[0]}/26'
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
resource ec_cyber_to_cm_ep_win_update 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-cyber-to-ce-win-update-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCyber.id
    sourceCidr: '${join(map(enclaveCyber.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.addressPrefix), ', ')}, ${split(enclaveCyber.properties.enclaveAddressSpaces.managedAddressSpace, '/')[0]}/26'
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
// resource ec_offline_to_cm_ep_win_update 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
//   name: 'ec-offline-to-ce-win-update-${uniqueNumber}'
//   location: location
//   tags: {
//     department: 'CommunitySharedServices'
//     company: 'CommunityOversight'
//   }
//   properties: {
//     communityResourceId: community.outputs.resourceId
//     sourceResourceId: enclaveOffline.id
//     sourceCidr: '${join(map(enclaveOffline.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.addressPrefix), ', ')}, ${split(enclaveOffline.properties.enclaveAddressSpaces.managedAddressSpace, '/')[0]}/26'
//     destinationEndpointId: communityName_windows_updates.outputs.communityEndpointResourceId
//   }
// }

// -------------------Winget Connections-------------------
// Connection: Identity to Winget
#disable-next-line BCP081
resource ec_identity_to_cm_ep_winget 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-identity-to-ce-winget-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveIdentity.id
    sourceCidr: filter(enclaveIdentity.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
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
resource ec_collab_to_cm_ep_winget 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-collab-to-ce-winget-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCollab.id
    sourceCidr: filter(enclaveCollab.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
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
resource ec_desktop_to_cm_ep_winget 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-desktop-to-ce-winget-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveDesktop.id
    sourceCidr: filter(enclaveDesktop.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
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
resource ec_platform_to_cm_ep_winget 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-platform-to-ce-winget-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclavePlatform.id
    sourceCidr: filter(enclavePlatform.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
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
resource ec_weapon_to_cm_ep_winget 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-weapon-to-ce-winget-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveWeapon.id
    sourceCidr: filter(enclaveWeapon.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
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
resource ec_subktr_to_cm_ep_winget 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-subktr-to-ce-winget-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveSubKtr.id
    sourceCidr: filter(enclaveSubKtr.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
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
resource ec_cyber_to_cm_ep_winget 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-cyber-to-ce-winget-${uniqueNumber}'
  location: location
  tags: {
    department: 'CommunitySharedServices'
    company: 'CommunityOversight'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveCyber.id
    sourceCidr: filter(enclaveCyber.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
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
// resource ec_offline_to_cm_ep_winget 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
//   name: 'ec-offline-to-ce-winget-${uniqueNumber}'
//   location: location
//   tags: {
//     department: 'CommunitySharedServices'
//     company: 'CommunityOversight'
//   }
//   properties: {
//     communityResourceId: community.outputs.resourceId
//     sourceResourceId: enclaveOffline.id
//     sourceCidr: ((stage >= 5)
//       ? filter(enclaveOffline.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
//)
//     destinationEndpointId: communityName_winget.outputs.communityEndpointResourceId
//   }
// }

// -------------------Enclave to Enclave Connections-------------------
// Connection: Platform enclave to Weapon enclave
#disable-next-line BCP081
resource ec_platform_to_weapon 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-platform-to-weapon-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'platforms'
    company: 'primeContractor'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclavePlatform.id
    sourceCidr: filter(enclavePlatform.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: ep_enclaveWeapon_from_platform.id
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
resource ec_weapon_to_platform 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-weapon-to-platform-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'pewPewDept'
    company: 'weaponContractor'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveWeapon.id
    sourceCidr: filter(enclaveWeapon.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: ep_enclavePlatform_from_weapon.id
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
resource ec_weapon_to_subktr 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-weapon-to-subktr-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'pewPewDept'
    company: 'weaponContractor'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveWeapon.id
    sourceCidr: filter(enclaveWeapon.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: ep_enclaveSubKtr_from_weapon.id
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
resource ec_subktr_to_weapon 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
  name: 'ec-subktr-to-weapon-demo-${uniqueNumber}'
  location: location
  tags: {
    department: 'softwareDevDept'
    company: 'subContractor'
  }
  properties: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveSubKtr.id
    sourceCidr: filter(enclaveSubKtr.properties.enclaveVirtualNetwork.subnetConfigurations, s => s.subnetName == 'WorkloadSubnet')[0].addressPrefix
    destinationEndpointId: ep_enclaveWeapon_from_subktr.id
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
resource ec_external_to_identity_adds 'microsoft.mission/enclaveconnections@2025-05-01-preview' = {
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
    destinationEndpointId: enclaveIdentity_endpointName_1_v2.id
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
