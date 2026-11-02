targetScope = 'resourceGroup'

@minLength(1)
@maxLength(64)
param vnetName string

param location string

@minLength(1)
@maxLength(80)
param privateEndpointSubnetName string

@minLength(3)
@maxLength(24)
@description('Globally unique vault name containing only letters, numbers, and hyphens.')
param vaultName string

@allowed([
  'privatelink.vaultcore.azure.net'
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

@minValue(7)
@maxValue(90)
param softDeleteRetentionInDays int = 90

param vnetAddressPrefix string = '10.60.0.0/16'
param privateEndpointSubnetPrefix string = '10.60.1.0/27'

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
    softDeleteRetentionInDays: softDeleteRetentionInDays
    enablePurgeProtection: true
    publicNetworkAccess: 'Disabled'
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

resource privateEndpointDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2026-01-01' = {
  parent: privateEndpoint
  name: privateDnsZoneGroupName
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'keyVaultPrivateDnsZone'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
}

output vaultId string = keyVault.id
output vaultUri string = keyVault.properties.vaultUri
output privateDnsZoneId string = privateDnsZone.id
output privateEndpointId string = privateEndpoint.id
output vnetId string = vnet.id
