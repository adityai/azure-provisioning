# Key Vault private deployment plan

**Status:** Design and implementation only. No Azure resources are deployed by this project.

## Goal and architecture

Provision a Standard Azure Key Vault with public network access disabled, Azure RBAC authorization, purge protection, and configurable soft-delete retention. Place its private endpoint in a dedicated subnet and link the private DNS zone to the deployment VNet.

```text
Private client / workload
        |
        | Private DNS: <vault>.vault.azure.net
        v
VNet (10.60.0.0/16)
  +-- Private-endpoint subnet (10.60.1.0/27)
        |
        v
Private endpoint (group ID: vault)
        |
        v
Standard Key Vault (public access disabled, RBAC authorization)

Private DNS zone: privatelink.vaultcore.azure.net
  +-- VNet link (registration disabled)
```

Address ranges are examples. Check for overlap with connected and peered networks before deployment.

## Security and lifecycle

- The vault uses Azure RBAC authorization, not legacy access policies. No role assignments are created because this template does not assume the consuming principal. Grant only the necessary data-plane role (for example, Key Vault Secrets User for read-only secret access) at the narrowest appropriate scope.
- Public network access is disabled. Clients need private routing and DNS resolution through the linked VNet; additional VNets need a zone link or a centralized DNS forwarding design.
- Soft delete is enabled with a configurable retention period from 7 to 90 days. Purge protection is enabled and cannot be disabled after creation; deleted vaults and objects may remain recoverable until retention expires.
- The template creates no secrets and takes no secret values as parameters or outputs. Add secret material only through a separately authorized, secure process after deployment.

## Implementation sequence

1. Select the subscription and region; verify network ranges and private client connectivity.
2. Create the VNet and a private-endpoint-only subnet.
3. Create the Standard vault with RBAC authorization, soft delete, purge protection, and public access disabled.
4. Create `privatelink.vaultcore.azure.net`, link it to the VNet, and associate the zone with the private endpoint.
5. Grant the consuming identity the minimum required Key Vault data-plane role and verify private DNS and authorized access from the intended network.

## Acceptance checks

- Vault SKU is Standard, Azure RBAC authorization is enabled, public network access is disabled, purge protection is enabled, and retention is within 7–90 days.
- The private endpoint is approved and the DNS zone group points to `privatelink.vaultcore.azure.net`.
- Intended clients resolve the normal vault hostname to a private address and can access only the operations allowed by their RBAC roles.
- No secret values are present in inputs, outputs, or deployment logs.

## API versions

The template uses the latest stable resource API versions available in the Bicep resource catalog when authored: `Microsoft.KeyVault/vaults@2026-05-15`, `Microsoft.Network/virtualNetworks@2026-01-01`, `Microsoft.Network/privateEndpoints@2026-01-01`, and private DNS resources at `2024-06-01`.
