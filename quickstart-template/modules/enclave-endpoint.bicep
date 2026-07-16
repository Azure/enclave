// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

type enclaveEndpointRuleType = {
  @description('The name of the rule.')
  endpointRuleName: string
  
  @description('The destination IP address or CIDR range.')
  destination: string
  
  @description('The port number or range.')
  ports: string
  
  @description('The protocols allowed (TCP, UDP, ICMP).')
  protocols: array
}

@description('The name of the parent enclave resource.')
@metadata({
  example: 've-example-001'
})
param enclaveName string

@description('The name of the endpoint.')
@minLength(3)
@maxLength(30)
@metadata({
  example: 'endpoint-webapp'
})
param endpointName string

@description('The location of the resource.')
param location string = resourceGroup().location

@description('The rule collection for the enclave endpoint.')
@metadata({
  example: [
    {
      endpointRuleName: 'allow-web-traffic'
      destination: '10.1.0.0/24'
      ports: '443'
      protocols: ['TCP']
    }
  ]
})
param rules enclaveEndpointRuleType[]

@description('Optional. Tags to apply to the enclave endpoint.')
param tags object = {}

// Reference to existing parent enclave resource
#disable-next-line BCP081
resource enclave 'Microsoft.Mission/virtualEnclaves@2025-05-01-preview' existing = {
  name: enclaveName
}

// Disable BCP081 as Microsoft.Mission/virtualEnclaves/enclaveEndpoints is a preview resource type
#disable-next-line BCP081
resource enclaveEndpoint 'Microsoft.Mission/virtualEnclaves/enclaveEndpoints@2025-05-01-preview' = {
  parent: enclave
  name: endpointName
  location: location
  tags: tags
  properties: {
    ruleCollection: rules
  }
}

@description('The resource ID of the enclave endpoint.')
output endpointId string = enclaveEndpoint.id

@description('The name of the enclave endpoint.')
output name string = enclaveEndpoint.name

@description('The location where the enclave endpoint was deployed.')
output location string = enclaveEndpoint.location
