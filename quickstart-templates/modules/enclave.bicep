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

type mandatoryApproverType = {
  @description('The Entra ID of the approver.')
  approverEntraId: string
}

type approvalSettingConfigurationType = {
  @description('Approval policy (Required or NotRequired).')
  approvalPolicy: ('Required' | 'NotRequired')
  
  @description('List of mandatory approvers for this approval setting.')
  mandatoryApprovers: mandatoryApproverType[]
  
  @description('Minimum number of approvers required for this approval setting.')
  minimumApproversRequired: int
}

type enclaveApprovalSettingsType = {
  @description('Approval configuration for connection creation.')
  connectionCreation: approvalSettingConfigurationType?
  
  @description('Approval configuration for connection updates.')
  connectionUpdate: approvalSettingConfigurationType?
  
  @description('Approval configuration for enclave endpoint updates.')
  enclaveEndpointUpdate: approvalSettingConfigurationType?
  
  @description('Approval configuration for enclave maintenance mode.')
  enclaveMaintenanceMode: approvalSettingConfigurationType?
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

@description('Optional list of workload names to deploy. If provided, this list takes precedence over workloadName.')
param workloadNames array = []

param workloadResourceGroupName string = ''

var effectiveWorkloadResourceGroupName = empty(trim(workloadResourceGroupName)) ? 'wl-rg-${toLower(enclaveName)}-${substring(uniqueString(deployment().name, location), 0, 6)}' : trim(workloadResourceGroupName)
var effectiveWorkloadNames = length(workloadNames) > 0 ? workloadNames : [
  workloadName
]
var computedWorkloadResourceIds = [for wlName in effectiveWorkloadNames: '${enclave.id}/workloads/${wlName}']

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

@description('Approval settings for various actions on the enclave resources.')
@metadata({
  displayName: 'Approval Settings'
})
param approvalSettings enclaveApprovalSettingsType = {
  connectionCreation: {
    approvalPolicy: 'NotRequired'
    mandatoryApprovers: []
    minimumApproversRequired: 0
  }
  connectionUpdate: {
    approvalPolicy: 'NotRequired'
    mandatoryApprovers: []
    minimumApproversRequired: 0
  }
  enclaveEndpointUpdate: {
    approvalPolicy: 'NotRequired'
    mandatoryApprovers: []
    minimumApproversRequired: 0
  }
  enclaveMaintenanceMode: {
    approvalPolicy: 'NotRequired'
    mandatoryApprovers: []
    minimumApproversRequired: 0
  }
}

resource enclave 'Microsoft.Mission/virtualEnclaves@2026-03-01-preview' = {
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
    approvalSettings: {
      connectionCreation: approvalSettings.?connectionCreation
      connectionUpdate: approvalSettings.?connectionUpdate
      enclaveEndpointUpdate: approvalSettings.?enclaveEndpointUpdate
      enclaveMaintenanceMode: approvalSettings.?enclaveMaintenanceMode
    }
  }
}

resource workload 'Microsoft.Mission/virtualEnclaves/workloads@2026-03-01-preview' = [for wlName in effectiveWorkloadNames: if (deployWorkload) {
  parent: enclave
  name: wlName
  location: location
  tags: tags
  properties: {
    resourceGroupCollection: [
      '${subscription().id}/resourceGroups/${effectiveWorkloadResourceGroupName}'
    ]
  }
}]

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

@description('The resource ID of the first workload (if deployed).')
output workloadResourceId string = deployWorkload && length(effectiveWorkloadNames) > 0 ? '${enclave.id}/workloads/${effectiveWorkloadNames[0]}' : ''

@description('The resource IDs of deployed workloads (if deployed).')
output workloadResourceIds array = deployWorkload ? computedWorkloadResourceIds : []
