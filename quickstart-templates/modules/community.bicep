// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

metadata name = 'Community Module'
metadata description = 'This module deploys a community resource which is the hub of the Azure Enclave hub and spoke architecture.'

@description('The name of the community resource.')
@minLength(3)
@maxLength(30)
param communityName string

@description('The address space for the community in CIDR notation.')
@metadata({
  example: '10.0.0.0/16'
})
param addressSpace string = '10.0.0.0/16'

@description('Location for all resources.')
param location string = resourceGroup().location

@description('Tags to be assigned to the community resource.')
@metadata({
  tabGroup: 'Tags'
})
param tags object = {}

type maintenanceModeConfigurationType = {
  @description('The mode of the maintenance mode configuration for the community.')
  mode: ('Off' | 'General' | 'Advanced')
  
  @description('The justification for the maintenance mode configuration for the community.')
  justification: ('Off' | 'Networking' | 'Governance')
  
  @description('The principals for the maintenance mode configuration for the community.')
  principals: array
}

type governedServiceType = {
  @description('The service identifier.')
  serviceId: string
  
  @description('The service option (Allow, Deny, NotApplicable).')
  option: string
  
  @description('The enforcement mode (Enabled, Disabled).')
  enforcement: string
  
  @description('The policy action (Enforce, Audit).')
  policyAction: string
}

@description('The maintenance mode configuration for the community.')
@metadata({
  displayName: 'Maintenance Mode Configuration'
})
param maintenanceModeConfiguration maintenanceModeConfigurationType = {
  mode: 'Off'
  justification: 'Off'
  principals: []
}

@description('The list of governed services for the community.')
@metadata({
  displayName: 'Governed Services'
})
param governedServiceList governedServiceType[]

// Disable BCP081 as Microsoft.Mission/communities is a preview resource type
#disable-next-line BCP081
resource community 'Microsoft.Mission/communities@2026-03-01-preview' = {
  name: communityName
  location: location
  tags: tags
  properties: {
    addressSpace: addressSpace
    maintenanceModeConfiguration: maintenanceModeConfiguration
    governedServiceList: governedServiceList
  }
}

@description('The resource ID of the community.')
output resourceId string = community.id

@description('The name of the community.')
output name string = community.name

@description('The location where the community was deployed.')
output location string = community.location

@description('The address prefixes of the community.')
output addressPrefixes string = addressSpace

@description('The current maintenance mode configuration.')
output maintenanceModeConfiguration maintenanceModeConfigurationType = maintenanceModeConfiguration
