targetScope = 'subscription'

metadata name = 'Resource Group Creation'
metadata description = 'Creates a new resource group at the subscription scope with configurable location and tags.'
metadata owner = 'Azure/module-maintainers'

@description('The name of the resource group to create.')
@minLength(1)
@maxLength(90)
param resourceGroupName string

@description('The Azure region where the resource group will be created.')
param location string

@description('Optional. Tags to apply to the resource group.')
param resourceGroupTags object = {}

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  location: location
  name: resourceGroupName
  tags: resourceGroupTags
}

@description('The resource ID of the created resource group.')
output resourceGroupId string = resourceGroup.id

@description('The name of the created resource group.')
output name string = resourceGroup.name

@description('The location of the created resource group.')
output location string = resourceGroup.location
