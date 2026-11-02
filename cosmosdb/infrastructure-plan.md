# Cosmos DB private deployment plan

**Status:** Design and implementation only. No Azure resources are deployed by this project.

## Goal and architecture

Provision an Azure Cosmos DB for NoSQL account with public network access disabled, a private endpoint, and a private DNS zone linked to a dedicated VNet. Create a serverless SQL database and container with a configurable partition-key path.

```text
Private client / workload
        |
        | Private DNS: <account>.documents.azure.com
        v
VNet (10.50.0.0/16)
  +-- Private-endpoint subnet (10.50.1.0/27)
        |
        v
Private endpoint (group ID: Sql)
        |
        v
Cosmos DB for NoSQL account
  +-- Serverless SQL database
        +-- Container (configured partition-key path)

Private DNS zone: privatelink.documents.azure.com
  +-- VNet link (registration disabled)
```

The address ranges are examples; check for overlap with peered VNets, VPNs, and on-premises networks before deployment.

## Security and access

- The account's public network access and local/key-based authentication are disabled. The template does not output or request account keys.
- Grant the application's managed identity or user-assigned identity the minimum required **Cosmos DB data-plane** role, such as the built-in Cosmos DB Built-in Data Reader or Data Contributor role, at the narrowest suitable account/database/container scope. Azure management-plane permissions alone do not grant document access.
- With local authentication disabled, clients must use Microsoft Entra ID token authentication and Cosmos DB data-plane RBAC. Configure the role assignment separately for the intended principal; this template deliberately does not assume an identity.
- Private DNS links only the VNet in this deployment. Other client VNets need their own link or a centrally managed DNS forwarding design, as well as private network routing.
- Serverless is appropriate for intermittent or variable traffic. Confirm region availability, account limits, workload behavior, and serverless pricing before deployment.

## Implementation sequence

1. Select the subscription and region; validate address-space non-overlap and serverless availability.
2. Create the VNet and dedicated private-endpoint subnet.
3. Create the NoSQL account with serverless capability, public access disabled, and local authentication disabled.
4. Create the SQL database and container with the configured partition-key path and no provisioned throughput.
5. Create `privatelink.documents.azure.com`, link it to the VNet, and associate it with the account private endpoint.
6. Assign data-plane RBAC to the consuming identity and test DNS, routing, and Entra-authenticated queries from the private network.

## Acceptance checks

- The account has serverless capability, public network access disabled, and local authentication disabled.
- The SQL database and container exist; the container uses the configured partition key.
- The private endpoint is approved and its zone group uses `privatelink.documents.azure.com`.
- A client on the linked VNet resolves the account's normal endpoint privately and can access data using an explicitly assigned data-plane role.
- No account keys or secret values are exposed as deployment outputs or committed in input files.

## API versions

The template uses the latest stable resource API versions available in the Bicep resource catalog when authored: `Microsoft.DocumentDB/databaseAccounts@2026-03-15`, the nested SQL database/container resource types at `2026-03-15`, `Microsoft.Network/virtualNetworks@2026-01-01`, `Microsoft.Network/privateEndpoints@2026-01-01`, and private DNS resources at `2024-06-01`.
