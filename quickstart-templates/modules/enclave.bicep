// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

// Type definitions
type maintenanceModeConfigurationType = {
  @description('The mode of the maintenance mode configuration.')
  mode: ('Off' | 'General' | 'Advanced')
  
  @description('The justification for the maintenance mode configuration.')
  justification: ('Off' | 'Networking' | 'Governance')
  
  @description('The principals for the maintenance mode configuration.')
  principals: array
}

type subnetConfigurationType = {
  @description('The name of the subnet.')
  subnetName: string
  
  @description('The network prefix size for the subnet.')
  networkPrefixSize: int
}

@description('The resource ID of the community resource.')
@metadata({
  example: '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example/providers/Microsoft.Mission/communities/cmt-example'
})
param communityResourceId string

@description('The name of the enclave.')
@minLength(3)
@maxLength(30)
@metadata({
  example: 've-example-001'
})
param enclaveName string

@description('The size of the enclave virtual network.')
@allowed([
  'small'
  'medium'
  'large'
  'custom'
])
@metadata({
  example: 'small'
})
param networkSize string = 'small'

@description('Location for all resources.')
param location string = resourceGroup().location

@description('The maintenance mode configuration for the enclave.')
param maintenanceModeConfiguration maintenanceModeConfigurationType = {
  mode: 'Off'
  justification: 'Off'
  principals: []
}

@description('Set to true to deploy a workload in the enclave.')
@metadata({
  displayName: 'Deploy Workload'
})
param deployWorkload bool = true

@description('The name of the workload resource.')
@minLength(3)
@maxLength(30)
param workloadName string = 'workload'

param workloadResourceGroupName string = 'rg-wl-default-name'

@description('Tags to be assigned to the enclave resource.')
param tags object = {}

@description('The list of subnet configurations for the enclave virtual network.')
@metadata({
  displayName: 'Subnet Configurations'
  example: [
    {
      subnetName: 'appSubnet'
      networkPrefixSize: 26
    }
    {
      subnetName: 'dataSubnet'
      networkPrefixSize: 26
    }
  ]
})
param subnetConfigurationsList subnetConfigurationType[]

// Disable BCP081 as Microsoft.Mission/virtualenclaves is a preview resource type
#disable-next-line BCP081
resource enclave 'Microsoft.Mission/virtualenclaves@2025-05-01-preview' = {
  name: enclaveName
  location: location
  tags: tags
  properties: {
    communityResourceId: communityResourceId
    enclaveVirtualNetwork: {
      networkSize: networkSize
      subnetConfigurations: subnetConfigurationsList
    }
    maintenanceModeConfiguration: maintenanceModeConfiguration
  }
}

// Disable BCP081 as Microsoft.Mission/virtualEnclaves/workloads is a preview resource type
#disable-next-line BCP081
resource workload 'Microsoft.Mission/virtualEnclaves/workloads@2025-05-01-preview' = if (deployWorkload) {
  parent: enclave
  name: workloadName
  location: location
  tags: tags
  properties: {
    resourceGroupCollection: [
      '${subscription().id}/resourcegroups/${workloadResourceGroupName}'
    ]
  }
}

// AVM-compliant outputs
@description('The resource ID of the enclave.')
output enclaveResourceId string = enclave.id

@description('The name of the enclave.')
output name string = enclave.name

@description('The location where the enclave was deployed.')
output location string = enclave.location

@description('The enclave address space of the enclave.')
output enclaveAddressSpace string = enclave.properties.enclaveAddressSpaces.enclaveAddressSpace

@description('The managedaddress space of the enclave.')
output managedAddressSpace string = enclave.properties.enclaveAddressSpaces.managedAddressSpace

@description('The subnet configurations of the enclave virtual network.')
output enclaveSubnetConfig array = enclave.properties.enclaveVirtualNetwork.subnetConfigurations

@description('The current maintenance mode configuration.')
output maintenanceModeConfiguration maintenanceModeConfigurationType = maintenanceModeConfiguration

@description('The resource ID of the workload (if deployed).')
output workloadResourceId string = deployWorkload ? workload.id : ''
