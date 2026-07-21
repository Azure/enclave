// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

// Azure Enclave Docs Tutorial: A modular template for Azure Enclave
metadata name = 'Azure Enclave Tutorial Template'
metadata description = 'Tutorial template demonstrating Azure Enclave deployment using modular components'

// ========================================
// PARAMETERS
// ========================================

@description('The name of the community.')
@minLength(3)
@maxLength(30)
param communityName string = 'cmt-fabrikam'

@description('The address space for the community in CIDR notation.')
param addressSpace string = '10.0.0.0/16'

@description('The size of the enclave virtual networks.')
@allowed([
  'small'
  'medium'
  'large'
])
param networkSize string = 'small'

@description('The name of the community endpoint.')
@minLength(3)
@maxLength(30)
param communityEndpointName string = 'ce-fabrikam-website'

@description('The destination FQDN for the community endpoint rule.')
param communityEndpointDestination string = '*microsoft.com'

@description('The name of the WebApp enclave.')
@minLength(3)
@maxLength(30)
param enclaveWebAppName string = 've-Enclave-WebApp'

@description('The name of the DMZ enclave.')
@minLength(3)
@maxLength(30)
param enclaveDMZName string = 've-Enclave-DMZ'

@description('The name of the first workload.')
@minLength(3)
@maxLength(30)
param workloadFrontendName string = 'wl-webapp-frontend'

@description('The name of the second workload.')
@minLength(3)
@maxLength(30)
param workloadBackendName string = 'wl-webapp-backend'

@description('The name of the enclave endpoint.')
@minLength(3)
@maxLength(30)
param enclaveEndpointName string = 'ee-MyService'

@description('The port for the enclave endpoint rule.')
param enclaveEndpointPort string = '443'

@description('The name of the enclave connection.')
@minLength(3)
@maxLength(30)
param enclaveConnectionName string = 'ec-fabrikam-external'

@description('Location for all resources.')
param location string = resourceGroup().location

@description('Enable/Disable usage telemetry for this template.')
param enableTelemetry bool = true

// ========================================
// TELEMETRY
// ========================================

// Telemetry
#disable-next-line no-deployments-resources BCP081
resource aveTelemetry 'Microsoft.Resources/deployments@2024-03-01' = if (enableTelemetry) {
  name: take(
    'virtualenclaves.ave-tutorial.${replace('-..--..-', '.', '-')}.${substring(uniqueString(deployment().name, location), 0, 4)}',
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

// Deploy Community
module community 'modules/community.bicep' = {
  name: 'deploy-community-${communityName}'
  params: {
    communityName: communityName
    addressSpace: addressSpace
    location: location
    tags: {}
    governedServiceList: []
  }
}

// Deploy Community Endpoint for external website access
module communityEndpoint 'modules/community-endpoint.bicep' = {
  name: 'deploy-community-endpoint-${communityEndpointName}'
  params: {
    communityName: community.outputs.name
    communityEndpointName: communityEndpointName
    location: location
    tags: {
      department: 'CommunitySharedServices'
      company: 'CommunityOversight'
    }
    communityEndpointRuleCollection: [
      {
        endpointRuleName: 'Website-Rule'
        destinationType: 'FQDN'
        destination: communityEndpointDestination
        protocols: [
          'HTTPS'
        ]
        ports: '443'
      }
    ]
  }
  dependsOn: [
    enclaveWebApp
  ]
}

// Deploy Enclave: Enclave-WebApp
module enclaveWebApp 'modules/enclave.bicep' = {
  name: 'deploy-enclave-${enclaveWebAppName}'
  params: {
    communityResourceId: community.outputs.resourceId
    enclaveName: enclaveWebAppName
    networkSize: networkSize
    location: location
    tags: {}
    subnetConfigurationsList: [
      {
        subnetName: 'mySubnet'
        networkPrefixSize: 26
      }
      {
        subnetName: 'WorkloadSubnet'
        networkPrefixSize: 26
      }
    ]
    deployWorkload: false
  }
}

// Deploy Enclave: Enclave-DMZ
module enclaveDMZ 'modules/enclave.bicep' = {
  name: 'deploy-enclave-${enclaveDMZName}'
  params: {
    communityResourceId: community.outputs.resourceId
    enclaveName: enclaveDMZName
    networkSize: networkSize
    location: location
    tags: {}
    subnetConfigurationsList: [
      {
        subnetName: 'mySubnet'
        networkPrefixSize: 26
      }
      {
        subnetName: 'WorkloadSubnet'
        networkPrefixSize: 26
      }
    ]
    deployWorkload: false
  }
}

// Deploy Workloads for Enclave-WebApp
// Note: Workloads are deployed as separate resources since the enclave module
// doesn't support multiple workload deployments
#disable-next-line BCP081
resource wl_webapp_frontend 'Microsoft.Mission/virtualEnclaves/workloads@2025-05-01-preview' = {
  name: '${enclaveWebAppName}/${workloadFrontendName}'
  location: location
  properties: {}
  dependsOn: [
    enclaveWebApp
  ]
}

#disable-next-line BCP081
resource wl_webapp_backend 'Microsoft.Mission/virtualEnclaves/workloads@2025-05-01-preview' = {
  name: '${enclaveWebAppName}/${workloadBackendName}'
  location: location
  properties: {}
  dependsOn: [
    enclaveWebApp
  ]
}

// Deploy Enclave Endpoint for WebApp enclave
module enclaveEndpoint 'modules/enclave-endpoint.bicep' = {
  name: 'deploy-enclave-endpoint-${enclaveEndpointName}'
  params: {
    enclaveName: enclaveWebApp.outputs.name
    endpointName: enclaveEndpointName
    location: location
    tags: {}
    rules: [
      {
        endpointRuleName: 'WebAppEndpointRules'
        destination: filter(enclaveWebApp.outputs.enclaveSubnetConfig, s => s.subnetName == 'mySubnet')[0].addressPrefix
        ports: enclaveEndpointPort
        protocols: [
          'ANY'
        ]
      }
    ]
  }
}

// Deploy Enclave Connection: WebApp to external community endpoint
module enclaveConnection 'modules/enclave-connection.bicep' = {
  name: 'deploy-connection-${enclaveConnectionName}'
  params: {
    communityResourceId: community.outputs.resourceId
    sourceResourceId: enclaveWebApp.outputs.enclaveResourceId
    destinationResourceId: communityEndpoint.outputs.communityEndpointResourceId
    sourceAddressSpace: filter(enclaveWebApp.outputs.enclaveSubnetConfig, s => s.subnetName == 'mySubnet')[0].addressPrefix
    location: location
    connectionName: enclaveConnectionName
    tags: {}
  }
}

// Outputs
@description('The resource ID of the community.')
output communityId string = community.outputs.resourceId

@description('The resource ID of the Enclave-WebApp.')
output enclaveWebAppId string = enclaveWebApp.outputs.enclaveResourceId

@description('The resource ID of the Enclave-DMZ.')
output enclaveDMZId string = enclaveDMZ.outputs.enclaveResourceId

@description('The resource ID of the community endpoint.')
output communityEndpointId string = communityEndpoint.outputs.communityEndpointResourceId

@description('The resource ID of the enclave endpoint.')
output enclaveEndpointId string = enclaveEndpoint.outputs.endpointId

@description('The resource ID of the enclave connection.')
output enclaveConnectionId string = enclaveConnection.outputs.enclaveConnectionId
