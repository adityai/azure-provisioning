targetScope = 'resourceGroup'

@minLength(1)
@maxLength(64)
param vnetName string

param location string

@minLength(1)
@maxLength(80)
param privateEndpointSubnetName string

@minLength(3)
@maxLength(44)
@description('Globally unique Cosmos DB account name: lowercase letters, numbers, and hyphens.')
param accountName string

@minLength(1)
@maxLength(255)
param databaseName string

@minLength(1)
@maxLength(255)
param containerName string

@minLength(2)
@maxLength(256)
@description('Container partition key path, for example /weatherStationId.')
param partitionKeyPath string

@allowed([
  'privatelink.documents.azure.com'
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

param vnetAddressPrefix string = '10.50.0.0/16'
param privateEndpointSubnetPrefix string = '10.50.1.0/27'

resource vnet 'Microsoft.Network/virtualNetworks@2026-01-01' = {
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

resource privateEndpointSubnet 'Microsoft.Network/virtualNetworks/subnets@2026-01-01' = {
  parent: vnet
  name: privateEndpointSubnetName
  properties: {
    addressPrefix: privateEndpointSubnetPrefix
    privateEndpointNetworkPolicies: 'Disabled'
  }
}

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2026-03-15' = {
  name: accountName
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    capabilities: [
      {
        name: 'EnableServerless'
      }
    ]
    publicNetworkAccess: 'Disabled'
    disableLocalAuth: true
  }
}

resource sqlDatabase 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2026-03-15' = {
  parent: cosmosAccount
  name: databaseName
  properties: {
    resource: {
      id: databaseName
    }
  }
}

resource sqlContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2026-03-15' = {
  parent: sqlDatabase
  name: containerName
  properties: {
    resource: {
      id: containerName
      partitionKey: {
        paths: [
          partitionKeyPath
        ]
        kind: 'Hash'
      }
    }
  }
}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: privateDnsZoneName
  location: 'global'
}

resource privateDnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
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

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2026-01-01' = {
  name: privateEndpointName
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'cosmosDbPrivateLink'
        properties: {
          privateLinkServiceId: cosmosAccount.id
          groupIds: [
            'Sql'
          ]
        }
      }
    ]
  }
}

resource privateEndpointDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2026-01-01' = {
  parent: privateEndpoint
  name: privateDnsZoneGroupName
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'cosmosDbPrivateDnsZone'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
}

output accountId string = cosmosAccount.id
output accountName string = cosmosAccount.name
output databaseName string = sqlDatabase.name
output containerName string = sqlContainer.name
output privateDnsZoneId string = privateDnsZone.id
output privateEndpointId string = privateEndpoint.id
output vnetId string = vnet.id
