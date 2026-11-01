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
