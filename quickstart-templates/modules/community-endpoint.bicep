// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

type endpointProtocolType =
  | 'AH'
  | 'ANY'
  | 'ESP'
  | 'HTTP'
  | 'HTTPS'
  | 'ICMP'
  | 'TCP'
  | 'UDP'

type endpointDestinationType =
  | 'FQDN'
  | 'FQDNTag'
  | 'IPAddress'
  | 'PrivateNetwork'
  | 'ServiceTag'
  | 'IP'

type endpointRuleType = {
  @description('The name of the rule.')
  endpointRuleName: string

  @description('Destination type for the rule (for example FQDN, FQDNTag, IPAddress, PrivateNetwork, ServiceTag).')
  destinationType: endpointDestinationType

  @description('Destination value. Can include comma-separated FQDNs, FQDN tags, CIDRs/IPs, service tags, or private network ranges.')
  destination: string

  @description('Allowed protocols for this rule.')
  protocols: endpointProtocolType[]

  @description('Port list or range. Supports comma-separated ports and hyphen-delimited ranges.')
  ports: string

  @description('Optional. Transit Hub Resource Id for PrivateNetwork destinations.')
  transitHubResourceId: string?
}

@description('The name of the community.')
param communityName string

@description('The name of the community endpoint.')
@minLength(3)
@maxLength(30)
param communityEndpointName string

@description('The rule collection for the community endpoint.')
@metadata({
  example: [
    {
      endpointRuleName: 'example-rule'
      destinationType: 'FQDN'
      destination: '*.example.com'
      protocols: ['HTTPS']
      ports: '443'
    }
    {
      endpointRuleName: 'example-service-tag'
      destinationType: 'ServiceTag'
      destination: 'AzureDatabricks,Storage,EventHub,Sql'
      protocols: ['TCP']
      ports: '443'
    }
    {
      endpointRuleName: 'example-private-network'
      destinationType: 'PrivateNetwork'
      destination: '172.16.0.0/20'
      protocols: ['TCP', 'UDP']
      ports: '443,80,53'
      transitHubResourceId: '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.Mission/transitHubs/example-transit-hub'
    }
  ]
})
param communityEndpointRuleCollection endpointRuleType[]

@description('The location of the resource.')
param location string = resourceGroup().location

@description('Optional. Tags to apply to the community endpoint.')
param tags object = {}

// Reference to existing parent community resource
#disable-next-line BCP081
resource community 'Microsoft.Mission/communities@2025-05-01-preview' existing = {
  name: communityName
}

// Disable BCP081 as Microsoft.Mission/communities/communityEndpoints is a preview resource type
#disable-next-line BCP081
resource communityEndpoint 'Microsoft.Mission/communities/communityEndpoints@2025-05-01-preview' = {
  parent: community
  name: communityEndpointName
  location: location
  tags: tags
  properties: {
    ruleCollection: communityEndpointRuleCollection
  }
}

@description('The resource ID of the community endpoint.')
output communityEndpointResourceId string = communityEndpoint.id

@description('The name of the community endpoint.')
output name string = communityEndpoint.name

@description('The location where the community endpoint was deployed.')
output location string = communityEndpoint.location
