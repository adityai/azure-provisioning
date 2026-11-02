targetScope = 'resourceGroup'

param location string

@minLength(3)
@maxLength(63)
@description('Globally unique SQL logical server name; lowercase letters, numbers, and hyphens.')
param serverName string

@minLength(1)
@maxLength(128)
param databaseName string

@minLength(1)
@maxLength(128)
param adminLogin string

@secure()
@minLength(8)
@maxLength(128)
param adminPassword string

@minLength(1)
@maxLength(64)
param vnetName string

@minLength(1)
@maxLength(80)
param privateEndpointSubnetName string

@minLength(1)
@maxLength(80)
param privateEndpointName string

@minLength(1)
@maxLength(80)
param privateDnsVnetLinkName string

@minLength(1)
@maxLength(20)
param databaseSkuName string = 'S0'

@minLength(1)
@maxLength(20)
param databaseSkuTier string = 'Standard'

@minValue(1)
param databaseSkuCapacity int = 10

param vnetAddressPrefix string = '10.60.0.0/16'
param privateEndpointSubnetPrefix string = '10.60.1.0/24'

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

resource privateEndpointSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: privateEndpointSubnetName
  properties: {
    addressPrefix: privateEndpointSubnetPrefix
    privateEndpointNetworkPolicies: 'Disabled'
  }
}

resource sqlServer 'Microsoft.Sql/servers@2023-08-01' = {
  name: serverName
  location: location
  properties: {
    administratorLogin: adminLogin
    administratorLoginPassword: adminPassword
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
  }
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-08-01' = {
  parent: sqlServer
  name: databaseName
  location: location
  sku: {
    name: databaseSkuName
    tier: databaseSkuTier
    capacity: databaseSkuCapacity
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    maxSizeBytes: 268435456000
    zoneRedundant: false
  }
}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.${environment().suffixes.sqlServerHostname}'
  location: 'global'
}

resource privateDnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: privateDnsVnetLinkName
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource sqlPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: privateEndpointName
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'sqlServerPrivateLink'
        properties: {
          privateLinkServiceId: sqlServer.id
          groupIds: [
            'sqlServer'
          ]
        }
      }
    ]
  }
}

resource sqlPrivateEndpointDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: sqlPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'sqlPrivateDnsZone'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
}

output sqlServerFullyQualifiedDomainName string = sqlServer.properties.fullyQualifiedDomainName
output sqlDatabaseId string = sqlDatabase.id
output privateDnsZoneId string = privateDnsZone.id
output vnetId string = vnet.id
