// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

// Community Endpoint Rule Sets
// Shared endpoint rule definitions for reuse across Azure Enclave templates.
// Each variable defines an array of endpoint rule objects compatible
// with the community-endpoint module's communityEndpointRuleCollection parameter.

// ========================================
// TYPE DEFINITION
// ========================================

type endpointRuleType = {
  @description('The name of the rule.')
  endpointRuleName: string

  @description('The type of destination (FQDN, FQDNTag, IP, IPAddress, PrivateNetwork, ServiceTag).')
  destinationType: string
  
  @description('The destination value (FQDN(s), tag name(s), CIDR(s)/IP(s), service tag(s), or private network range).')
  destination: string

  @description('The protocols allowed (HTTP, HTTPS, TCP, UDP).')
  protocols: array

  @description('The port number or range.')
  ports: string

  @description('Optional. Transit Hub Resource Id for PrivateNetwork destinations.')
  transitHubResourceId: string?
}

@description('Optional transit hub resource ID used by private network endpoint rules.')
param transitHubResourceId string = ''

// ========================================
// DEMOCOMMUNITY ENDPOINTS
// ========================================

var externalCommunityEndpointRules = [
  {
    endpointRuleName: 'ce-rule-external-community-dataplane'
    destinationType: 'PrivateNetwork'
    destination: '172.16.0.0/20'
    protocols: [
      'TCP'
      'UDP'
    ]
    ports: '443,80,3389,53'
    transitHubResourceId: transitHubResourceId
  }
  {
    endpointRuleName: 'ce-rule-external-community-admin-vm'
    destinationType: 'PrivateNetwork'
    destination: '172.16.40.0/23'
    protocols: [
      'TCP'
      'UDP'
    ]
    ports: '443,80,3389'
    transitHubResourceId: transitHubResourceId
  }
]

var dataSourceEndpointRules = [
  {
    endpointRuleName: 'ce-rule-data-source-https'
    destinationType: 'FQDN'
    #disable-next-line no-hardcoded-env-urls
    destination: 'bing.com'
    protocols: ['HTTPS']
    ports: '443'
  }
]

// ========================================
// AUTHENTICATION & IDENTITY
// ========================================

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

// ========================================
// AZURE PORTAL & MANAGEMENT
// ========================================

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

// ========================================
// AZURE RESOURCE APIS
// ========================================

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

// ========================================
// MICROSOFT GRAPH & EXTENSIONS
// ========================================

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

// ========================================
// MICROSOFT DOMAINS & CDN
// ========================================

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

// ========================================
// THIRD-PARTY & TELEMETRY
// ========================================

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

// ========================================
// COMBINED AZURE PORTAL ACCESS
// ========================================

var azurePortalEndpointRules = concat(
  authenticationEndpointRules,
  portalManagementEndpointRules,
  azureServiceEndpointRules,
  graphExtensionEndpointRules,
  microsoftCdnEndpointRules,
  thirdPartyEndpointRules
)

// ========================================
// WINDOWS UPDATE
// ========================================

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

// ========================================
// WINGET
// ========================================

var wingetEndpointRules = [
  {
    endpointRuleName: 'win-winget-https'
    destinationType: 'FQDN'
    #disable-next-line no-hardcoded-env-urls
    destination: 'github.com,*.github.com,objects.githubusercontent.com,*.azureedge.com,*.azurefd.net,*.sourceforge.net,sourceforge.net,settings-win.data.microsoft.com'
    protocols: ['HTTPS']
    ports: '443'
  }
  {
    endpointRuleName: 'win-winget-http'
    destinationType: 'FQDN'
    #disable-next-line no-hardcoded-env-urls
    destination: '*.digicert.com,adl.windows.com'
    protocols: ['HTTP']
    ports: '80'
  }
]

// ========================================
// SERVICE CATALOG
// ========================================

var serviceCatalogEndpointRules = [
  {
    endpointRuleName: 'service-catalog'
    destinationType: 'FQDN'
    #disable-next-line no-hardcoded-env-urls
    destination: 'veservicecatalogprod.z22.web.core.windows.net'
    protocols: ['HTTPS']
    ports: '443'
  }
]

@description('Community endpoint rules for the external private network endpoint.')
output externalCommunityEndpointRules array = externalCommunityEndpointRules

@description('Community endpoint rules for the data source endpoint.')
output dataSourceEndpointRules array = dataSourceEndpointRules

@description('Community endpoint rules for default portal access.')
output azurePortalEndpointRules array = azurePortalEndpointRules

@description('Community endpoint rules for Windows Update access.')
output windowsUpdateEndpointRules array = windowsUpdateEndpointRules

@description('Community endpoint rules for Winget access.')
output wingetEndpointRules array = wingetEndpointRules

@description('Community endpoint rules for Service Catalog access.')
output serviceCatalogEndpointRules array = serviceCatalogEndpointRules
