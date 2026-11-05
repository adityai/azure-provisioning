targetScope = 'resourceGroup'

@minLength(1)
@maxLength(64)
param vnetName string

param location string

@minLength(1)
@maxLength(80)
param integrationSubnetName string

@minLength(1)
@maxLength(80)
param privateEndpointSubnetName string

@minLength(1)
@maxLength(40)
param planName string

@minLength(3)
@maxLength(24)
@description('Globally unique Storage account name; lowercase letters and numbers only.')
param storageAccountName string

@minLength(2)
@maxLength(60)
@description('Globally unique Function App name; lowercase letters, numbers, and hyphens only.')
param functionAppName string

@minLength(1)
@maxLength(260)
param applicationInsightsName string = '${functionAppName}-appi'

@minLength(4)
@maxLength(63)
param logAnalyticsWorkspaceName string = take('${functionAppName}-logs', 63)

@minLength(3)
@maxLength(24)
@description('Globally unique vault name containing only letters, numbers, and hyphens.')
param vaultName string = take('kv${replace(toLower(functionAppName), '-', '')}', 24)

@allowed([
  'Python|3.11'
  'Python|3.12'
])
@description('Python runtime stack supported by the selected Functions hosting plan.')
param runtimeStack string

@allowed([
  'privatelink.azurewebsites.net'
])
param privateDnsZoneName string

@minLength(1)
@maxLength(80)
param vnetLinkName string

@minLength(1)
@maxLength(60)
param privateEndpointName string

@minLength(1)
@maxLength(80)
param privateDnsZoneGroupName string

@minLength(1)
@maxLength(20)
@allowed([
  'EP1'
  'EP2'
  'EP3'
])
param skuName string

@minLength(1)
@maxLength(30)
@allowed([
  'ElasticPremium'
])
param skuTier string

@minLength(1)
@maxLength(20)
@allowed([
  'EP1'
  'EP2'
  'EP3'
])
param skuSize string

@minLength(1)
@maxLength(10)
@allowed([
  'EP'
])
param skuFamily string

@minValue(1)
param skuCapacity int = 1

param vnetAddressPrefix string = '10.50.0.0/16'
param integrationSubnetPrefix string = '10.50.1.0/26'
param privateEndpointSubnetPrefix string = '10.50.2.0/24'

var storagePrivateLinkServices = [
  {
    suffix: 'blob'
    groupId: 'blob'
    zoneName: 'privatelink.blob.${environment().suffixes.storage}'
  }
  {
    suffix: 'file'
    groupId: 'file'
    zoneName: 'privatelink.file.${environment().suffixes.storage}'
  }
  {
    suffix: 'queue'
    groupId: 'queue'
    zoneName: 'privatelink.queue.${environment().suffixes.storage}'
  }
  {
    suffix: 'table'
    groupId: 'table'
    zoneName: 'privatelink.table.${environment().suffixes.storage}'
  }
]

var planSku = {
  name: skuName
  tier: skuTier
  size: skuSize
  family: skuFamily
  capacity: skuCapacity
}

var storageAccountKey = storageAccount.listKeys().keys[0].value
var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccountKey};EndpointSuffix=${environment().suffixes.storage}'
var contentShareName = take(toLower('content-${functionAppName}'), 63)

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
  }
}

resource integrationSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: integrationSubnetName
  properties: {
    addressPrefix: integrationSubnetPrefix
    delegations: [
      {
        name: 'functionAppDelegation'
        properties: {
          serviceName: 'Microsoft.Web/serverFarms'
        }
      }
    ]
  }
}

resource privateEndpointSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: privateEndpointSubnetName
  properties: {
    addressPrefix: privateEndpointSubnetPrefix
    privateEndpointNetworkPolicies: 'Disabled'
  }
}

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  properties: {
    retentionInDays: 30
    sku: {
      name: 'PerGB2018'
    }
  }
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: applicationInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    IngestionMode: 'LogAnalytics'
    WorkspaceResourceId: logAnalyticsWorkspace.id
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2026-05-15' = {
  name: vaultName
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
    publicNetworkAccess: 'Disabled'
  }
}

resource keyVaultPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.vaultcore.azure.net'
  location: 'global'
}

resource keyVaultPrivateDnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: keyVaultPrivateDnsZone
  name: take('kv-${vnetLinkName}', 80)
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource keyVaultPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: take('pe-${vaultName}', 80)
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'keyVaultPrivateLink'
        properties: {
          privateLinkServiceId: keyVault.id
          groupIds: [
            'vault'
          ]
        }
      }
    ]
  }
}

resource keyVaultPrivateEndpointDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: keyVaultPrivateEndpoint
  name: take('kv-${privateDnsZoneGroupName}', 80)
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'keyVaultPrivateDnsZone'
        properties: {
          privateDnsZoneId: keyVaultPrivateDnsZone.id
        }
      }
    ]
  }
}

resource appServicePlan 'Microsoft.Web/serverfarms@2022-03-01' = {
  name: planName
  location: location
  kind: 'linux'
  sku: planSku
  properties: {
    reserved: true
  }
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Disabled'
    supportsHttpsTrafficOnly: true
  }
}

resource storagePrivateDnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for service in storagePrivateLinkServices: {
  name: service.zoneName
  location: 'global'
}]

resource storagePrivateDnsVnetLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (service, i) in storagePrivateLinkServices: {
  parent: storagePrivateDnsZones[i]
  name: vnetLinkName
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}]

resource storagePrivateEndpoints 'Microsoft.Network/privateEndpoints@2024-05-01' = [for service in storagePrivateLinkServices: {
  name: take('${privateEndpointName}-storage-${service.suffix}', 80)
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'storage${service.suffix}PrivateLink'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            service.groupId
          ]
        }
      }
    ]
  }
}]

resource storagePrivateEndpointDnsGroups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = [for (service, i) in storagePrivateLinkServices: {
  parent: storagePrivateEndpoints[i]
  name: privateDnsZoneGroupName
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'storage${service.suffix}PrivateDnsZone'
        properties: {
          privateDnsZoneId: storagePrivateDnsZones[i].id
        }
      }
    ]
  }
}]

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: privateDnsZoneName
  location: 'global'
}

resource privateDnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: vnetLinkName
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource functionApp 'Microsoft.Web/sites@2022-03-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    publicNetworkAccess: 'Disabled'
    siteConfig: {
      alwaysOn: true
      ftpsState: 'Disabled'
      linuxFxVersion: runtimeStack
      minTlsVersion: '1.2'
    }
  }
  dependsOn: [
    storagePrivateEndpointDnsGroups
    storagePrivateDnsVnetLinks
  ]
}

resource appVnetIntegration 'Microsoft.Web/sites/networkConfig@2022-03-01' = {
  parent: functionApp
  name: 'virtualNetwork'
  properties: {
    subnetResourceId: integrationSubnet.id
    swiftSupported: true
  }
}

resource functionAppSettings 'Microsoft.Web/sites/config@2022-03-01' = {
  parent: functionApp
  name: 'appsettings'
  properties: {
    FUNCTIONS_EXTENSION_VERSION: '~4'
    FUNCTIONS_WORKER_RUNTIME: 'python'
    APPLICATIONINSIGHTS_CONNECTION_STRING: applicationInsights.properties.ConnectionString
    AzureWebJobsStorage: storageConnectionString
    WEBSITE_CONTENTAZUREFILECONNECTIONSTRING: storageConnectionString
    WEBSITE_CONTENTSHARE: contentShareName
    WEBSITE_CONTENTOVERVNET: '1'
  }
  dependsOn: [
    appVnetIntegration
    storagePrivateEndpointDnsGroups
  ]
}

resource functionPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: privateEndpointName
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'functionAppPrivateLink'
        properties: {
          privateLinkServiceId: functionApp.id
          groupIds: [
            'sites'
          ]
        }
      }
    ]
  }
}

resource functionPrivateEndpointDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: functionPrivateEndpoint
  name: privateDnsZoneGroupName
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'functionAppPrivateDnsZone'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
}

output functionAppDefaultHostname string = functionApp.properties.defaultHostName
output storageAccountId string = storageAccount.id
output privateDnsZoneId string = privateDnsZone.id
output vnetId string = vnet.id
output functionAppPlanSku string = planSku.name
