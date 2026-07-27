// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

// Azure Virtual Enclave Deployment Template

// Allow deployments to different subscriptions and resource groups
targetScope = 'subscription'

// ========================================
// TYPE DEFINITIONS
// ========================================

type subnetConfigurationType = {
  subnetName: string
  networkPrefixSize: int
}

type governedServiceType = {
  serviceId: string
  option: string
  enforcement: string
  policyAction: string
}

// ========================================
// GENERAL PARAMETERS
// ========================================

@description('Prefix for resource naming.')
@minLength(1)
@maxLength(6)
@metadata({
  example: 'ae'
})
param prefix string

@description('Suffix for resource naming.')
@minLength(1)
@maxLength(6)
@metadata({
  example: 'prod'
})
param suffix string

@description('Azure region for all resources.')
@metadata({
  example: 'eastus'
})
param location string = deployment().location

@description('Subscription ID for community resources.')
param communitySubscriptionId string = subscription().subscriptionId

@description('Resource group name for community resources.')
param communityResourceGroupName string = 'rg-${prefix}-community-${suffix}'

@description('Subscription ID for enclave resources.')
param enclaveSubscriptionId string = subscription().subscriptionId

@description('Tags to apply to all resources.')
param tags object = {
  'created-by': 'Mrs. Admin'
  'deploy-type': 'production'
}

// ========================================
// COMMUNITY PARAMETERS
// ========================================

@description('Address space for the community network in CIDR notation.')
param communityAddressSpace string = '10.0.0.0/16'

@description('Maintenance mode for the community.')
@allowed(['Off', 'General', 'Advanced'])
param communityMaintenanceModeMode string = 'Off'

@description('Maintenance mode justification for the community.')
@allowed(['Off', 'Networking', 'Governance'])
param communityMaintenanceModeJustification string = 'Off'

@description('List of principal objects for community maintenance mode access. Off example: "principals":[]}. On example: "principals":[{"id":"<your-user-object-id>","type":"User"}]}.')
param communityMaintenanceModePrincipals array = []

// ========================================
// ENCLAVE PARAMETERS
// ========================================

@description('Name for the enclave resource.')
param enclaveLabel string = 'WebApp'

@description('Name for the enclave resource.')
@minLength(3)
@maxLength(30)
param enclaveName string = 've-${prefix}-${enclaveLabel}-${suffix}'

@description('Resource group name for the first enclave.')
param enclave1ResourceGroupName string = 'rg-ve-${prefix}-${enclaveLabel}-${suffix}'

@description('Network size for the enclave virtual network.')
@allowed(['small', 'medium', 'large', 'custom'])
param networkSize string = 'small'

@description('Subnet configurations for the enclave.')
@minLength(1)
@metadata({
  example: [
    { subnetName: 'appSubnet', networkPrefixSize: 26 }
    { subnetName: 'workloadSubnet', networkPrefixSize: 26 }
  ]
})
param enclaveSubnetConfigurations subnetConfigurationType[] = [
  { subnetName: 'appSubnet', networkPrefixSize: 26 }
  { subnetName: 'workloadSubnet', networkPrefixSize: 26 }
]

@description('Maintenance mode for the enclave.')
@allowed(['Off', 'General', 'Advanced'])
param enclaveMaintenanceModeMode string = 'Off'

@description('Maintenance mode justification for the enclave.')
@allowed(['Off', 'Networking', 'Governance'])
param enclaveMaintenanceModeJustification string = 'Off'

@description('List of principal objects for enclave maintenance mode access. Off example: "principals":[]}. On example: "principals":[{"id":"<your-user-object-id>","type":"User"}]}.')
param enclaveMaintenanceModePrincipals array = []

// ========================================
// WORKLOAD PARAMETERS
// ========================================

@description('Whether to deploy a workload within the enclave.')
param deployWorkload bool = true

@description('Whether to append a unique suffix to resource names to avoid conflicts.')
param appendUniqueNameSuffix bool = true

@description('Name for the workload resource (only used if deployWorkload is true).')
@minLength(3)
@maxLength(30)
param workloadName string = 'wl-${prefix}-${enclaveLabel}-${suffix}'

@description('Resource group name for the workload (only used if deployWorkload is true).')
param workloadResourceGroupName string = appendUniqueNameSuffix 
  ? 'wl-rg-${prefix}-${enclaveLabel}-${suffix}-${substring(uniqueString(deployment().name, location), 0, 4)}'
  : 'wl-rg-${prefix}-${enclaveLabel}-${suffix}'

// ========================================
// TRANSIT HUB PARAMETERS
// ========================================

@description('Whether to deploy a transit hub for on-premises/remote connectivity.')
param deployTransitHub bool = false

@description('Resource ID of the remote virtual network for peering through your transit hub.')
@metadata({
  example: '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example/providers/Microsoft.Network/virtualNetworks/vnet-example'
})
param transitHubRemoteVnetId string = ''

@description('Type of connection for the transit hub.')
@allowed(['Gateway', 'ExpressRoute', 'Peering'])
param transitHubConnectionType string = 'Gateway'

@description('Source address space for remote connections (CIDR notation, comma-separated for multiple ranges).')
@metadata({
  example: '172.16.0.0/23'
})
param remoteSourceAddressSpace string = '172.16.0.0/23'

// ========================================
// VARIABLES
// ========================================

// Governed services configuration
var governedServices = [
  { serviceId: 'AKS', option: 'Allow', enforcement: 'Enabled', policyAction: 'Enforce' }
  { serviceId: 'AppService', option: 'Allow', enforcement: 'Enabled', policyAction: 'Enforce' }
  { serviceId: 'ContainerRegistry', option: 'Allow', enforcement: 'Enabled', policyAction: 'Enforce' }
  { serviceId: 'CosmosDB', option: 'Allow', enforcement: 'Enabled', policyAction: 'Enforce' }
  { serviceId: 'KeyVault', option: 'Allow', enforcement: 'Enabled', policyAction: 'Enforce' }
  { serviceId: 'MicrosoftSQL', option: 'Allow', enforcement: 'Enabled', policyAction: 'Enforce' }
  { serviceId: 'Monitoring', option: 'NotApplicable', enforcement: 'Enabled', policyAction: 'Enforce' }
  { serviceId: 'PostgreSQL', option: 'Allow', enforcement: 'Enabled', policyAction: 'Enforce' }
  { serviceId: 'ServiceBus', option: 'Allow', enforcement: 'Enabled', policyAction: 'Enforce' }
  { serviceId: 'Storage', option: 'Allow', enforcement: 'Enabled', policyAction: 'Enforce' }
  { serviceId: 'AzureFirewalls', option: 'Allow', enforcement: 'Enabled', policyAction: 'Enforce' }
  { serviceId: 'Insights', option: 'Allow', enforcement: 'Enabled', policyAction: 'Enforce' }
  { serviceId: 'Logic', option: 'Allow', enforcement: 'Enabled', policyAction: 'Enforce' }
  { serviceId: 'PrivateDNSZones', option: 'Allow', enforcement: 'Enabled', policyAction: 'Enforce' }
  { serviceId: 'DataConnectors', option: 'Allow', enforcement: 'Enabled', policyAction: 'Enforce' }
]

// Transit option based on connection type
var transitOptions = transitHubConnectionType == 'Peering'
  ? {
      type: transitHubConnectionType
      params: {
        remoteVirtualNetworkId: transitHubRemoteVnetId
      }
    }
  : {
      type: transitHubConnectionType
      params: {
        scaleUnits: 2
      }
    }

// Community Endpoint Rule Collections
// Authentication & Identity
var authenticationEndpointRules = [
  {
    endpointRuleName: 'auth-microsoft'
    destinationType: 'FQDN'
    #disable-next-line no-hardcoded-env-urls
    destination: 'login.microsoftonline.com,*.msft.sts.microsoft.com,*.aadcdn.msftauth.net,*.aadcdn.msftauthimages.net,*.aadcdn.msauthimages.net,*.logincdn.msftauth.net,login.live.com,*.msauth.net,microsoftonline-p.com,*.microsoftonline-p.com,*.live.com,*.microsoftonline.com,*.microsoftonlinesupport.net,autologon.microsoftazuread-sso.com,clientconfig.passport.net,hrd.svc.cloud.microsoft'
    protocols: ['HTTPS']
    ports: '443'
  }
  {
    endpointRuleName: 'auth-mfa'
    destinationType: 'FQDN'
    #disable-next-line no-hardcoded-env-urls
    destination: 'pfd.phonefactor.net,pfd2.phonefactor.net,css.phonefactor.net'
    protocols: ['HTTPS']
    ports: '443'
  }
  {
    endpointRuleName: 'auth-certs'
    destinationType: 'FQDN'
    #disable-next-line no-hardcoded-env-urls
    destination: '*.digicert.com,www.microsoft.com,crl.microsoft.com'
    protocols: ['HTTP']
    ports: '80'
  }
]

// Azure Portal & Management
var portalManagementEndpointRules = [
  {
    endpointRuleName: 'portal-core'
    destinationType: 'FQDN'
    #disable-next-line no-hardcoded-env-urls
    destination: '*.portal.azure.com,*.hosting.portal.azure.net,*.reactblade.portal.azure.net,*reactblade-ms.portal.azure.net,afd-v2.hosting-ms.portal.azure.net,shell.azure.com,management.azure.com'
    protocols: ['HTTPS']
    ports: '443'
  }
  {
    endpointRuleName: 'portal-services'
    destinationType: 'FQDN'
    #disable-next-line no-hardcoded-env-urls
    destination: 'gallery.azure.com,marketplacedataprovider.azure.com,marketplaceemail.azure.com,catalogapi.azure.com,catalogartifact.azureedge.net'
    protocols: ['HTTPS']
    ports: '443'
  }
]

// Azure Resource APIs
var azureServiceEndpointRules = [
  {
    endpointRuleName: 'services-data-analytics'
    destinationType: 'FQDN'
    #disable-next-line no-hardcoded-env-urls
    destination: '*.asazure.windows.net,asazure.windows.net,*.database.windows.net,datalake.azure.net,cosmos.azure.com,dev.azuresynapse.net,kusto.windows.net,help.kusto.windows.net'
    protocols: ['HTTPS']
    ports: '443'
  }
  {
    endpointRuleName: 'services-compute-integration'
    destinationType: 'FQDN'
    #disable-next-line no-hardcoded-env-urls
    destination: 'appservice.azure.com,*.azurewebsites.net,batch.azure.com,functions.azure.com,logic.azure.com,eventhubs.azure.net,servicebus.azure.net,servicebus.windows.net,*.servicebus.windows.net'
    protocols: ['HTTPS']
    ports: '443'
  }
  {
    endpointRuleName: 'services-ai-iot'
    destinationType: 'FQDN'
    #disable-next-line no-hardcoded-env-urls
    destination: 'cognitiveservices.azure.com,digitaltwins.azure.net,sphere.azure.net,quantum.azure.com'
    protocols: ['HTTPS']
    ports: '443'
  }
  {
    endpointRuleName: 'services-governance-security'
    destinationType: 'FQDN'
    #disable-next-line no-hardcoded-env-urls
    destination: 'purview.azure.com,informationprotection.azure.com,api.aadrm.com,identitygovernance.azure.com,iga.azure.com,elm.iga.azure.com,mspim.azure.com,api.azrbac.mspim.azure.com,*.access.mcas.ms,cxcs.microsoft.net'
    protocols: ['HTTPS']
    ports: '443'
  }
  {
    endpointRuleName: 'services-monitoring-storage'
    destinationType: 'FQDN'
    #disable-next-line no-hardcoded-env-urls
    destination: '*.applicationinsights.azure.com,monitor.azure.com,api.loganalytics.io,changeanalysis.azure.com,storage.azure.com,storage.azure.net,*core.windows.net,vault.azure.net,search.azure.com,adl.windows.com'
    protocols: ['HTTPS']
    ports: '443'
  }
  {
    endpointRuleName: 'services-misc'
    destinationType: 'FQDN'
    #disable-next-line no-hardcoded-env-urls
    destination: '*.azconfig.io,*.aad.azure.com,*.aadconnecthealth.azure.com,ad.azure.com,adf.azure.com,*.arc.azure.net,bastion.azure.com,config.office.com,media.azure.net,rest.media.azure.net,network.azure.com,dev.azure.com,*.wvd.microsoft.com,enterpriseregistration.windows.net,ecs.office.com,asmconfigfiles-prod.azure-api.net'
    protocols: ['HTTPS']
    ports: '443'
  }
]

// Microsoft Graph & Extensions
var graphExtensionEndpointRules = [
  {
    endpointRuleName: 'graph-apis'
    destinationType: 'FQDN'
    #disable-next-line no-hardcoded-env-urls
    destination: '*.graph.windows.net,*.graph.microsoft.com,graph.microsoft.com'
    protocols: ['HTTPS']
    ports: '443'
  }
  {
    endpointRuleName: 'azure-extensions'
    destinationType: 'FQDN'
    #disable-next-line no-hardcoded-env-urls
    destination: '*.ext.azure.com'
    protocols: ['HTTPS']
    ports: '443'
  }
]

// Microsoft Domains & CDN
var microsoftCdnEndpointRules = [
  {
    endpointRuleName: 'microsoft-domains'
    destinationType: 'FQDN'
    #disable-next-line no-hardcoded-env-urls
    destination: '*microsoft.com,*azure.com,*.msn.com,*.msn.cn,go.microsoft.com,aka.ms,learn.microsoft.com,privacy.microsoft.com,azure.status.microsoft,packages.microsoft.com,www.msftconnecttest.com,client.wns.windows.com,www.bing.com'
    protocols: ['HTTPS']
    ports: '443'
  }
  {
    endpointRuleName: 'cdn-edge'
    destinationType: 'FQDN'
    #disable-next-line no-hardcoded-env-urls
    destination: '*.azureedge.net,*.akamaized.net,static.edge.microsoftapp.net,*config.edge.skype.com,outlookmobile-office365-tas.msedge.net'
    protocols: ['HTTPS']
    ports: '443'
  }
]

// Third-Party & Telemetry
var thirdPartyEndpointRules = [
  {
    endpointRuleName: 'third-party-services'
    destinationType: 'FQDN'
    #disable-next-line no-hardcoded-env-urls
    destination: 'clients2.google.com,clients2.googleusercontent.com,www.googleapis.com,bing.com'
    protocols: ['HTTPS']
    ports: '443'
  }
  {
    endpointRuleName: 'telemetry-reporting'
    destinationType: 'FQDN'
    #disable-next-line no-hardcoded-env-urls
    destination: 'query.prod.cms.rt.microsoft.com,identity.nel.measure.office.net,deff.nelreports.net'
    protocols: ['HTTPS']
    ports: '443'
  }
]

// Combined collection for Azure Portal access
var azurePortalEndpointRules = concat(
  authenticationEndpointRules,
  portalManagementEndpointRules,
  azureServiceEndpointRules,
  graphExtensionEndpointRules,
  microsoftCdnEndpointRules,
  thirdPartyEndpointRules
)

var windowsUpdateEndpointRules = [
  {
    endpointRuleName: 'win-updates-https'
    destinationType: 'FQDNTag'
    #disable-next-line no-hardcoded-env-urls
    destination: 'windowsupdate'
    protocols: [
      'HTTPS'
    ]
    ports: '443'
  }
  {
    endpointRuleName: 'win-updates-http'
    destinationType: 'FQDNTag'
    #disable-next-line no-hardcoded-env-urls
    destination: 'windowsupdate'
    protocols: [
      'HTTP'
    ]
    ports: '80'
  }
]

var wingetEndpointRules = [
  {
    endpointRuleName: 'win-winget-https'
    destinationType: 'FQDN'
    #disable-next-line no-hardcoded-env-urls
    destination: 'github.com,*.github.com,objects.githubusercontent.com,*.azureedge.com,*.azurefd.net,*.sourceforge.net,sourceforge.net,settings-win.data.microsoft.com'
    protocols: ['HTTPS']
    ports: '443'
  }
]

// ========================================
// MODULES
// ========================================

// Create resource group for community resources
module communityResourceGroup './modules/newResourceGroup.bicep' = {
  scope: subscription(communitySubscriptionId)
  params: {
    resourceGroupName: communityResourceGroupName
    location: location
    resourceGroupTags: tags
  }
}

module community './modules/community.bicep' = {
  scope: resourceGroup(communitySubscriptionId, communityResourceGroupName)
  name: 'cmt-${prefix}-com-${suffix}'
  params: {
    communityName: 'cmt-${prefix}-com-${suffix}'
    addressSpace: communityAddressSpace
    location: location
    tags: tags
    maintenanceModeConfiguration: {
      mode: communityMaintenanceModeMode
      justification: communityMaintenanceModeJustification
      principals: communityMaintenanceModePrincipals
    }
    governedServiceList: governedServices
  }
  dependsOn: [
    communityResourceGroup
  ]
}

module communityEndpointMsftAzure './modules/community-endpoint.bicep' = {
  scope: resourceGroup(communitySubscriptionId, communityResourceGroupName)
  params: {
    communityEndpointName: 'ce-${prefix}-msftAz-${suffix}'
    communityName: community.outputs.name
    communityEndpointRuleCollection: azurePortalEndpointRules
    location: location
  }
}

module communityEndpointWinUpdate './modules/community-endpoint.bicep' = {
  scope: resourceGroup(communitySubscriptionId, communityResourceGroupName)
  params: {
    communityEndpointName: 'ce-${prefix}-winupd-${suffix}'
    communityName: community.outputs.name
    communityEndpointRuleCollection: windowsUpdateEndpointRules
    location: location
  }
}

module communityEndpointWinget './modules/community-endpoint.bicep' = {
  scope: resourceGroup(communitySubscriptionId, communityResourceGroupName)
  params: {
    communityEndpointName: 'ce-${prefix}-winget-${suffix}'
    communityName: community.outputs.name
    communityEndpointRuleCollection: wingetEndpointRules
    location: location
  }
}

module enc1ResourceGroup './modules/newResourceGroup.bicep' = {
  scope: subscription(enclaveSubscriptionId)
  params: {
    resourceGroupName: enclave1ResourceGroupName
    location: location
    resourceGroupTags: tags
  }
}

module enclave1 './modules/enclave.bicep' = {
  scope: resourceGroup(enclaveSubscriptionId, enclave1ResourceGroupName)
  name: enclaveName
  params: {
    enclaveName: enclaveName
    communityResourceId: community.outputs.resourceId
    tags: tags
    location: location
    networkSize: networkSize
    subnetConfigurationsList: enclaveSubnetConfigurations
    maintenanceModeConfiguration: {
      mode: enclaveMaintenanceModeMode
      justification: enclaveMaintenanceModeJustification
      principals: enclaveMaintenanceModePrincipals
    }
    deployWorkload: deployWorkload
    workloadName: workloadName
    workloadResourceGroupName: workloadResourceGroupName
  }
  dependsOn: [
    enc1ResourceGroup
  ]
}

// Enclave-derived variables (computed from module outputs)
// Includes enclave user specified subnets and management subnet
var enclave1SourceAddressSpaceAllSubnets = '${join(map(enclave1.outputs.enclaveSubnetConfig, s => s.addressPrefix), ', ')}, ${split(enclave1.outputs.managedAddressSpace, '/')[0]}/26'
// Use the first configured subnet for single-subnet connection flows
var enclave1SourceAddressSpaceOneSubnet = enclave1.outputs.enclaveSubnetConfig[0].addressPrefix

module enclaveEndpointWebApp './modules/enclave-endpoint.bicep' = {
  scope: resourceGroup(enclaveSubscriptionId, enclave1ResourceGroupName)
  params: {
    enclaveName: enclave1.outputs.name
    endpointName: 'ee-${prefix}-${enclaveLabel}-${suffix}'
    location: location
    rules: [
      {
        endpointRuleName: 'enclave-web-app-subnet'
        destination: enclave1.outputs.enclaveSubnetConfig[0].addressPrefix
        ports: '443'
        protocols: [
          'TCP'
        ]
      }
    ]
  }
}

module enclaveConnectionMsftAzure './modules/enclave-connection.bicep' = {
  scope: resourceGroup(enclaveSubscriptionId, enclave1ResourceGroupName)
  name: 'ec-${prefix}-msftAz-${suffix}'
  params: {
    connectionName: 'ec-${prefix}-msftAz-${suffix}'
    sourceResourceId: enclave1.outputs.enclaveResourceId
    destinationResourceId: communityEndpointMsftAzure.outputs.communityEndpointResourceId
    sourceAddressSpace: enclave1SourceAddressSpaceAllSubnets
    communityResourceId: community.outputs.resourceId
    location: location
    tags: tags
  }
}

module enclaveConnectionWinUpdate './modules/enclave-connection.bicep' = {
  scope: resourceGroup(enclaveSubscriptionId, enclave1ResourceGroupName)
  name: 'ec-${prefix}-winUpdate-${suffix}'
  params: {
    connectionName: 'ec-${prefix}-winUpdate-${suffix}'
    sourceResourceId: enclave1.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWinUpdate.outputs.communityEndpointResourceId
    sourceAddressSpace: enclave1SourceAddressSpaceAllSubnets
    communityResourceId: community.outputs.resourceId
    location: location
    tags: tags
  }
}

module enclaveConnectionWinget './modules/enclave-connection.bicep' = {
  scope: resourceGroup(enclaveSubscriptionId, enclave1ResourceGroupName)
  params: {
    connectionName: 'ec-${prefix}-winget-${suffix}'
    sourceResourceId: enclave1.outputs.enclaveResourceId
    destinationResourceId: communityEndpointWinget.outputs.communityEndpointResourceId
    sourceAddressSpace: enclave1SourceAddressSpaceOneSubnet
    communityResourceId: community.outputs.resourceId
    location: location
    tags: tags
  }
}

module enclaveConnectionWebApp './modules/enclave-connection.bicep' = {
  scope: resourceGroup(enclaveSubscriptionId, enclave1ResourceGroupName)
  params: {
    connectionName: 'ec-${prefix}-${enclaveLabel}-${suffix}'
    sourceResourceId: enclave1.outputs.enclaveResourceId
    destinationResourceId: enclaveEndpointWebApp.outputs.endpointId
    sourceAddressSpace: enclave1SourceAddressSpaceOneSubnet
    communityResourceId: community.outputs.resourceId
    location: location
    tags: tags
  }
}

module transitHub './modules/transit-hub.bicep' = if (deployTransitHub) {
  scope: resourceGroup(communitySubscriptionId, communityResourceGroupName)
  params: {
    transitHubName: 'tHub-${prefix}-onprem-${suffix}'
    communityName: community.outputs.name
    transitOption: transitOptions
    location: location
    tags: tags
  }
  dependsOn: [
    enclave1 // Required: VWAN hub for enclave must be deployed before transit hub
  ]
}

module transitHubInboundConnection './modules/enclave-connection.bicep' = if (deployTransitHub) {
  scope: resourceGroup(communitySubscriptionId, communityResourceGroupName)
  params: {
    connectionName: 'ec-${prefix}-thub-${suffix}'
    sourceResourceId: transitHub!.outputs.transitHubResourceId
    destinationResourceId: enclaveEndpointWebApp.outputs.endpointId
    sourceAddressSpace: remoteSourceAddressSpace // Address space to connect to on remote side, comma separated list of CIDRs
    communityResourceId: community.outputs.resourceId
    location: location
    tags: tags
  }
}

// ========================================
// OUTPUTS
// ========================================

@description('The resource ID of the deployed community.')
output communityResourceId string = community.outputs.resourceId

@description('The name of the deployed community.')
output communityName string = community.outputs.name

@description('The resource ID of the deployed enclave.')
output enclaveResourceId string = enclave1.outputs.enclaveResourceId

@description('The name of the deployed enclave.')
output enclaveName string = enclave1.outputs.name

@description('The address space of the enclave.')
output enclaveAddressSpace string = enclave1.outputs.enclaveAddressSpace

@description('The subnet configurations of the enclave.')
output enclaveSubnetConfig array = enclave1.outputs.enclaveSubnetConfig

@description('The resource ID of the transit hub.')
output transitHubResourceId string = deployTransitHub ? transitHub!.outputs.transitHubResourceId : ''

@description('The resource ID of the enclave endpoint.')
output enclaveEndpointResourceId string = enclaveEndpointWebApp.outputs.endpointId

@description('The resource ID of the workload (if deployed).')
output workloadResourceId string = enclave1.outputs.workloadResourceId

@description('Array of all community endpoint resource IDs.')
output communityEndpointIds array = [
  communityEndpointMsftAzure.outputs.communityEndpointResourceId
  communityEndpointWinUpdate.outputs.communityEndpointResourceId
  communityEndpointWinget.outputs.communityEndpointResourceId
]

@description('Array of all enclave connection resource IDs.')
output enclaveConnectionIds array = [
  enclaveConnectionMsftAzure.outputs.enclaveConnectionId
  enclaveConnectionWinUpdate.outputs.enclaveConnectionId
  enclaveConnectionWinget.outputs.enclaveConnectionId
  enclaveConnectionWebApp.outputs.enclaveConnectionId
]

