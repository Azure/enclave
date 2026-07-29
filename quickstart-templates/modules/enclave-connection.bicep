// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

@description('The resource ID of the community.')
@metadata({
  example: '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example/providers/Microsoft.Mission/communities/cmt-example'
})
param communityResourceId string

@description('The resource ID of the source resource (enclave or transit hub).')
@metadata({
  example: '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example/providers/Microsoft.Mission/enclaves/ve-example'
})
param sourceResourceId string

@description('The resource ID of the destination resource (endpoint).')
@metadata({
  example: '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example/providers/Microsoft.Mission/communities/cmt-example/communityEndpoints/endpoint-example'
})
param destinationResourceId string

@description('The source address space in CIDR notation (comma-separated for multiple ranges).')
@metadata({
  example: '10.1.0.0/24,10.2.0.0/24'
})
param sourceAddressSpace string

@description('The Azure region for the resource.')
param location string = resourceGroup().location

@description('The name of the enclave connection.')
@minLength(3)
@maxLength(30)
param connectionName string

@description('Tags to be assigned to the enclave connection.')
param tags object = {}

resource enclaveConnection 'Microsoft.Mission/enclaveConnections@2026-03-01-preview' = {
  name: connectionName
  location: location
  tags: tags
  properties: {
    communityResourceId: communityResourceId
    sourceResourceId: sourceResourceId
    sourceCidr: sourceAddressSpace
    destinationEndpointId: destinationResourceId
  }
}

@description('The resource ID of the created enclave connection.')
output enclaveConnectionId string = enclaveConnection.id

@description('The name of the enclave connection.')
output name string = enclaveConnection.name

@description('The location where the enclave connection was deployed.')
output location string = enclaveConnection.location

@description('The source CIDR notation used in the connection.')
output sourceCidr string = enclaveConnection.properties.sourceCidr

@description('The community resource ID associated with the connection.')
output communityResourceId string = enclaveConnection.properties.communityResourceId
