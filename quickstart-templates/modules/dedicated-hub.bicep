// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

@description('The name of the parent community.')
@metadata({
  example: 'cmt-example-001'
})
param communityName string

@description('The name of the dedicated hub.')
@minLength(3)
@maxLength(30)
@metadata({
  example: 'dHub-external-001'
})
param dedicatedHubName string

@description('Designation for the dedicated hub.')
@metadata({
  example: 'Primary'
})
param designation string

@description('The location of the resource.')
param location string = resourceGroup().location

@description('Tags to be assigned to the dedicated hub.')
param tags object = {}

// Reference to existing parent community resource
resource community 'Microsoft.Mission/communities@2026-04-01' existing = {
  name: communityName
}

resource dedicatedHub 'Microsoft.Mission/communities/dedicatedHubs@2026-04-01' = {
  parent: community
  name: dedicatedHubName
  location: location
  tags: tags
  properties: {
    designation: designation
  }
}

@description('The resource ID of the created dedicated hub.')
output dedicatedHubResourceId string = dedicatedHub.id

@description('The name of the dedicated hub.')
output name string = dedicatedHub.name

@description('The location where the dedicated hub was deployed.')
output location string = dedicatedHub.location
