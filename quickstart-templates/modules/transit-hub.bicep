// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

type transitOptionType = {
  @description('The type of transit connection (Gateway, ExpressRoute, or Peering).')
  type: ('Gateway' | 'ExpressRoute' | 'Peering')
  
  @description('Parameters specific to the transit type.')
  params: object
}

@description('The name of the parent community.')
@metadata({
  example: 'cmt-example-001'
})
param communityName string

@description('The name of the transit hub.')
@minLength(3)
@maxLength(30)
@metadata({
  example: 'tHub-onprem-001'
})
param transitHubName string

@description('The transit option configuration object.')
@metadata({
  example: {
    type: 'Gateway'
    params: {
      scaleUnits: 2
    }
  }
})
param transitOption transitOptionType

@description('The location of the resource.')
param location string = resourceGroup().location

@description('Tags to be assigned to the transit hub.')
param tags object = {}

// Reference to existing parent community resource
#disable-next-line BCP081
resource community 'Microsoft.Mission/communities@2026-03-01-preview' existing = {
  name: communityName
}

// Disable BCP081 as Microsoft.Mission/communities/transitHubs is a preview resource type
#disable-next-line BCP081
resource transitHub 'Microsoft.Mission/communities/transitHubs@2026-03-01-preview' = {
  parent: community
  name: transitHubName
  location: location
  tags: tags
  properties: {
    transitOption: transitOption
  }
}

@description('The resource ID of the created transit hub.')
output transitHubResourceId string = transitHub.id

@description('The name of the transit hub.')
output name string = transitHub.name

@description('The location where the transit hub was deployed.')
output location string = transitHub.location

@description('The transit option configuration used.')
output transitOption transitOptionType = transitOption
