# Private Azure Blob Storage deployment plan

**Status:** Design only — no Azure resources have been created.

## Goal and architecture

Deploy an Azure StorageV2 account with a private blob container and private-only network access. The deployment creates a VNet, a dedicated private-endpoint subnet, a blob private endpoint, and the cloud-specific `privatelink.blob.<storage-suffix>` private DNS zone linked to that VNet.

```text
Private clients
  -> VNet / private endpoint subnet
  -> Storage account blob private endpoint
  -> private container (anonymous/public access disabled)

Private DNS zone: privatelink.blob.<storage-suffix>
```

## Security and configuration

- Storage account kind is `StorageV2`, with standard locally redundant storage (`Standard_LRS`) and Hot blob access tier.
- Public network access is disabled, the network ACL default action is Deny, anonymous blob access is disabled, HTTPS-only traffic is required, and TLS 1.2 is the minimum.
- The container is created with `publicAccess: None`.
- The private endpoint targets the `blob` subresource. Its DNS zone group provisions the private-link record, and a VNet link makes the zone resolvable from the deployment VNet.
- The example VNet address space (`10.60.0.0/16`) and subnet (`10.60.1.0/27`) are illustrative; check for overlap before deployment.
- Storage account names are globally unique, 3–24 lowercase letters or digits, and must be changed if unavailable.
- No credentials or access keys are stored in the sample parameters. Use Microsoft Entra ID and least-privilege data-plane roles where practical; manage any required key-based access outside this repository.

## Access and operations

Clients must have private routing to the VNet and resolve the storage account's normal `*.blob.core.windows.net` endpoint through the private DNS chain to the private endpoint IP. For clients outside the linked VNet, provide private connectivity and DNS forwarding or additional VNet links. Public internet access is intentionally unavailable.

## Acceptance checks

- Account reports StorageV2 and public network access disabled.
- `allowBlobPublicAccess` is false and the container's public access is `None`.
- The private endpoint connection targets `blob` and is approved.
- Private DNS resolves the account's blob endpoint to the private endpoint IP from an intended client network.
- HTTPS blob access succeeds with an authorized identity from that private network, and public access fails.

## References

- [Azure Storage private endpoints](https://learn.microsoft.com/azure/storage/common/storage-private-endpoints)
- [Configure Azure Storage firewalls and virtual networks](https://learn.microsoft.com/azure/storage/common/storage-network-security)
