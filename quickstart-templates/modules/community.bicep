// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

metadata name = 'Community Module'
metadata description = 'This module deploys a community resource which is the hub of the Azure Enclave hub and spoke architecture.'

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

type communityApprovalSettingsType = {
  @description('Approval configuration for community endpoint updates.')
  communityEndpointUpdate: approvalSettingConfigurationType?
  
  @description('Approval configuration for community maintenance mode.')
  communityMaintenanceMode: approvalSettingConfigurationType?
  
  @description('Approval configuration for connection creation.')
  connectionCreation: approvalSettingConfigurationType?
  
  @description('Approval configuration for connection updates.')
  connectionUpdate: approvalSettingConfigurationType?
  
  @description('Approval configuration for enclave creation.')
  enclaveCreation: approvalSettingConfigurationType?
  
  @description('Approval configuration for enclave endpoint updates.')
  enclaveEndpointUpdate: approvalSettingConfigurationType?
  
  @description('Approval configuration for enclave maintenance mode.')
  enclaveMaintenanceMode: approvalSettingConfigurationType?
}

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
  serviceId: ('AKS' | 'AppService' | 'AzureFirewalls' | 'ContainerRegistry' | 'CosmosDB' | 'DataConnectors' | 'Insights' | 'KeyVault' | 'Logic' | 'MicrosoftSQL' | 'Monitoring' | 'PostgreSQL' | 'PrivateDNSZones' | 'ServiceBus' | 'Storage')

  @description('The service option (Allow, Deny, ExceptionOnly, or NotApplicable).')
  option: ('Allow' | 'Deny' | 'ExceptionOnly' | 'NotApplicable')

  @description('The enforcement mode (Enabled or Disabled).')
  enforcement: ('Enabled' | 'Disabled')

  @description('The policy action (AuditOnly, Enforce, or None).')
  policyAction: ('AuditOnly' | 'Enforce' | 'None')
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

type diagnosticDestinationType = {
  @description('The destination type for diagnostics.')
  destinationType: ('CommunityWorkspace' | 'CustomWorkspace' | 'EnclaveWorkspace')

  @description('Log Analytics workspace resource ID. Required when destinationType is CustomWorkspace.')
  customWorkspaceResourceId: string?

  @description('Custom name for the diagnostic settings.')
  diagnosticSettingsName: string?
}

type monitoringSettingsType = {
  @description('List of diagnostic destinations.')
  diagnosticDestinations: diagnosticDestinationType[]

  @description('The destination for flow logs.')
  flowLogDestination: diagnosticDestinationType
}

@description('Monitoring settings for diagnostic and flow log destinations.')
@metadata({
  displayName: 'Monitoring Settings'
})
param monitoringSettings monitoringSettingsType = {
  diagnosticDestinations: [
    {
      destinationType: 'CommunityWorkspace'
    }
  ]
  flowLogDestination: {
    destinationType: 'CommunityWorkspace'
  }
}

@description('Approval settings for various actions on the community resources.')
@metadata({
  displayName: 'Approval Settings'
})
param approvalSettings communityApprovalSettingsType = {
  communityEndpointUpdate: {
    approvalPolicy: 'NotRequired'
    mandatoryApprovers: []
    minimumApproversRequired: 1
  }
  communityMaintenanceMode: {
    approvalPolicy: 'NotRequired'
    mandatoryApprovers: []
    minimumApproversRequired: 1
  }
  connectionCreation: {
    approvalPolicy: 'NotRequired'
    mandatoryApprovers: []
    minimumApproversRequired: 1
  }
  connectionUpdate: {
    approvalPolicy: 'NotRequired'
    mandatoryApprovers: []
    minimumApproversRequired: 1
  }
  enclaveCreation: {
    approvalPolicy: 'NotRequired'
    mandatoryApprovers: []
    minimumApproversRequired: 1
  }
  enclaveEndpointUpdate: {
    approvalPolicy: 'NotRequired'
    mandatoryApprovers: []
    minimumApproversRequired: 1
  }
  enclaveMaintenanceMode: {
    approvalPolicy: 'NotRequired'
    mandatoryApprovers: []
    minimumApproversRequired: 1
  }
}

resource community 'Microsoft.Mission/communities@2026-03-01-preview' = {
  name: communityName
  location: location
  tags: tags
  properties: {
    addressSpace: addressSpace
    maintenanceModeConfiguration: maintenanceModeConfiguration
    governedServiceList: governedServiceList
    monitoringSettings: monitoringSettings
    approvalSettings: {
      communityEndpointUpdate: approvalSettings.?communityEndpointUpdate
      communityMaintenanceMode: approvalSettings.?communityMaintenanceMode
      connectionCreation: approvalSettings.?connectionCreation
      connectionUpdate: approvalSettings.?connectionUpdate
      enclaveCreation: approvalSettings.?enclaveCreation
      enclaveEndpointUpdate: approvalSettings.?enclaveEndpointUpdate
      enclaveMaintenanceMode: approvalSettings.?enclaveMaintenanceMode
    }
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
