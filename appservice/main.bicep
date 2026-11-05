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

@allowed([
  'Linux'
  'Windows'
])
param operatingSystem string

@minLength(1)
@maxLength(100)
@description('App Service stack version, such as NODE|20-lts or DOTNET|8.0.')
param runtimeStack string

@minLength(2)
@maxLength(60)
@description('Must be globally unique and contain only lowercase letters, numbers, and hyphens.')
param webAppName string

@minLength(1)
@maxLength(260)
param applicationInsightsName string = '${webAppName}-appi'

@minLength(4)
@maxLength(63)
param logAnalyticsWorkspaceName string = take('${webAppName}-logs', 63)

@minLength(3)
@maxLength(24)
@description('Globally unique vault name containing only letters, numbers, and hyphens.')
param vaultName string = take('kv${replace(toLower(webAppName), '-', '')}', 24)

@allowed([
  'privatelink.azurewebsites.net'
])
param privateDnsZoneName string

@minLength(1)
@maxLength(80)
param vnetLinkName string

@minLength(1)
@maxLength(80)
param privateEndpointName string

@minLength(1)
@maxLength(80)
param privateDnsZoneGroupName string

@minLength(1)
@maxLength(20)
param skuName string

@minLength(1)
@maxLength(30)
param skuTier string

@minLength(1)
@maxLength(20)
param skuSize string

@minLength(1)
@maxLength(10)
param skuFamily string

@minValue(1)
param skuCapacity int = 1

param vnetAddressPrefix string = '10.40.0.0/16'
param integrationSubnetPrefix string = '10.40.1.0/26'
param privateEndpointSubnetPrefix string = '10.40.2.0/27'

var isLinux = operatingSystem == 'Linux'
var planSku = {
  name: skuName
  tier: skuTier
  size: skuSize
  family: skuFamily
  capacity: skuCapacity
}
var appSiteConfig = union(
  {
    ftpsState: 'Disabled'
    minTlsVersion: '1.2'
    appSettings: [
      {
        name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
        value: applicationInsights.properties.ConnectionString
      }
    ]
  },
  isLinux
    ? {
        linuxFxVersion: runtimeStack
      }
    : {
        windowsFxVersion: runtimeStack
      }
)

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
        name: 'appServiceDelegation'
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
  kind: isLinux ? 'linux' : 'app'
  sku: planSku
  properties: {
    reserved: isLinux
  }
}

resource webApp 'Microsoft.Web/sites@2022-03-01' = {
  name: webAppName
  location: location
  kind: isLinux ? 'app,linux' : 'app'
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    publicNetworkAccess: 'Disabled'
    siteConfig: appSiteConfig
  }
}

resource appVnetIntegration 'Microsoft.Web/sites/networkConfig@2022-03-01' = {
  parent: webApp
  name: 'virtualNetwork'
  properties: {
    subnetResourceId: integrationSubnet.id
    swiftSupported: true
  }
}

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

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: privateEndpointName
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'appServicePrivateLink'
        properties: {
          privateLinkServiceId: webApp.id
          groupIds: [
            'sites'
          ]
        }
      }
    ]
  }
}

resource privateEndpointDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: privateEndpoint
  name: privateDnsZoneGroupName
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'appServicePrivateDnsZone'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
}

output webAppDefaultHostname string = webApp.properties.defaultHostName
output privateDnsZoneId string = privateDnsZone.id
output vnetId string = vnet.id
output appServicePlanSku string = planSku.name
output appOperatingSystem string = operatingSystem
