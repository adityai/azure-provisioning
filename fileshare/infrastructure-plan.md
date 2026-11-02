# Private Azure Files deployment plan

**Status:** Design only — no Azure resources have been created.

## Goal and architecture

Deploy a StorageV2 account with a private SMB file share and private-only network access. The deployment creates a VNet, a dedicated private-endpoint subnet, a file private endpoint, and the cloud-specific `privatelink.file.<storage-suffix>` private DNS zone linked to that VNet.

```text
SMB clients (TCP 445) on a private network
  -> VNet / private endpoint subnet
  -> Storage account file private endpoint
  -> private Azure file share

Private DNS zone: privatelink.file.<storage-suffix>
```

## Security and configuration

- Storage account kind is `StorageV2`, with standard locally redundant storage (`Standard_LRS`).
- Public network access is disabled, network ACLs default to Deny, anonymous blob access is disabled, HTTPS-only traffic is required, and TLS 1.2 is the minimum.
- The file share is configured for SMB and receives an explicit quota in GiB.
- The private endpoint targets the `file` subresource. A DNS zone group provisions the private-link record and a VNet link makes the zone resolvable from the deployment VNet.
- Example VNet/subnet ranges (`10.70.0.0/16`, `10.70.1.0/27`) are illustrative; check for overlap before deployment.
- Storage account names are globally unique, 3–24 lowercase letters or digits, and must be changed if unavailable.
- No credentials or access keys are stored in sample parameters. Use Microsoft Entra ID-based SMB authentication where configured; otherwise protect account keys outside this repository and grant only intended users access.

## SMB and DNS access

Clients need private routing to the endpoint, DNS resolution of the account's normal `*.file.core.windows.net` hostname to its private IP, and SMB connectivity over TCP port 445. On-premises and hub/spoke clients need suitable routing and DNS forwarding or additional VNet links. Public internet access is intentionally unavailable. Confirm that client networks and security controls permit SMB before deployment.

## Acceptance checks

- Account reports StorageV2 and public network access disabled.
- File endpoint targets the `file` subresource and its connection is approved.
- The private share exists with the requested quota and SMB protocol.
- Private DNS resolves the normal file endpoint name to the private endpoint IP.
- An authorized client can mount the share over SMB from an intended private network; public access fails.

## References

- [Azure Files private endpoints](https://learn.microsoft.com/azure/storage/files/storage-files-networking-endpoints)
- [Azure Files planning for an Azure file share deployment](https://learn.microsoft.com/azure/storage/files/storage-files-planning)
